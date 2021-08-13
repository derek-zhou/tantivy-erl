defmodule Tantivy do
  @moduledoc """
  Documentation for `Tantivy`.
  """

  require Logger
  use GenServer

  defstruct port: nil,
            seq: 0,
            map: %{}

  @doc false
  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(name: name, command: command) do
    GenServer.start_link(__MODULE__, command, name: name)
  end

  @doc """
  add a document to the database
  """
  @spec add(GenServer.server(), integer, map) :: :ok
  def add(server, id, doc) do
    cast(server, {:add, id, doc})
  end

  @doc """
  remove a document from the database
  """
  @spec remove(GenServer.server(), integer) :: :ok
  def remove(server, id) do
    cast(server, %{command: :remove, id: id})
  end

  @doc """
  update a document to a new version
  """
  @spec update(GenServer.server(), integer, map) :: :ok
  def update(server, id, doc) do
    cast(server, %{command: :update, id: id, doc: doc})
  end

  @doc """
  perform a query with default option
  """
  @spec search(GenServer.server(), String.t()) :: list
  def search(server, query) do
    call(server, %{command: :search, query: query, opts: default_search_opts()})
  end

  @doc """
  perform a query with options
  """
  @spec search(GenServer.server(), binary, keyword) :: list
  def search(server, query, opts) do
    opts = Enum.reduce(opts, default_search_opts(), fn {k, v}, a -> Map.put(a, k, v) end)
    call(server, %{command: :search, query: query, opts: opts})
  end

  defp call(server, request) do
    Jason.decode!(GenServer.call(server, Jason.encode!(request)))
  end

  defp cast(server, request) do
    GenServer.cast(server, Jason.encode!(request))
  end

  defp default_search_opts() do
    case Application.get_env(:tantivy, :default_search_opts) do
      nil -> %{limit: 25}
      v -> v
    end
  end

  # server side
  @impl true
  def init(command) do
    Process.flag(:trap_exit, true)
    Logger.notice("port server to #{command} booting")
    port = Port.open({:spawn, Command}, [{:packet, 4}, :binary])
    {:ok, %__MODULE__{port: port}}
  end

  @impl true
  def terminate(_reason, %__MODULE__{port: port, map: map}) do
    case Enum.empty?(map) do
      true -> :ok
      false -> flush_port(port, map)
    end
  end

  # each message has a 4 byte prefix:
  # <<"P", 0, 0, 0>> for oneway message: Posted Write
  # <<"R", seq :: 24>> for message needing a reply: Request
  # <<"C", seq :: 24>> for reply to a previous request: Completion

  @impl true
  def handle_cast(data, %__MODULE__{port: port} = state) do
    Port.command(port, [<<"P", 0, 0, 0>> | data])
    {:noreply, state}
  end

  @impl true
  def handle_call(data, from, %__MODULE__{port: port, seq: seq, map: map} = state) do
    case Map.has_key?(map, seq) do
      true ->
        raise("sequence number #{seq} still not released")

      false ->
        Port.command(port, [<<"R", seq::24>> | data])
        {:noreply, %{state | seq: next_seq(seq), map: %{map | seq => from}}}
    end
  end

  @impl true
  def handle_info(
        {port, {:data, <<"C", seq::24, data::binary>>}},
        %__MODULE__{port: port, map: map} = state
      ) do
    {:noreply, %{state | map: deliver_msg(seq, data, map)}}
  end

  # legal sequence number is 0 ~ 2^24-1
  defp next_seq(0xFF_FFFF), do: 0
  defp next_seq(seq), do: seq + 1

  defp flush_port(port, map) do
    receive do
      {port, {:data, <<"C", seq::24, data::binary>>}} ->
        map = deliver_msg(seq, data, map)

        case Enum.empty?(map) do
          true -> :ok
          false -> flush_port(port, map)
        end

      _ ->
        flush_port(port, map)
    end
  end

  defp deliver_msg(seq, data, map) do
    map |> Map.fetch!(seq) |> GenServer.reply(data)
    Map.delete(map, seq)
  end
end
