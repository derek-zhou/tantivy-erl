defmodule Tantivy do
  @moduledoc """
  Documentation for `Tantivy`.
  """
  @default_limit 100

  require Logger
  use GenServer

  defstruct port: nil,
            seq: 0,
            map: %{}

  @doc false
  @spec start(String.t()) :: GenServer.on_start()
  def start(name: name, command: command) do
    GenServer.start(__MODULE__, command, name: name)
  end

  @doc false
  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(name: name, command: command) do
    GenServer.start_link(__MODULE__, command, name: name)
  end

  @doc """
  add one or more document to the database
  """
  @spec add(GenServer.server(), map | list) :: :ok
  def add(server, doc) when is_map(doc), do: cast(server, %{add: true}, [doc])
  def add(server, docs) when is_list(docs), do: cast(server, %{add: true}, docs)

  @doc """
  remove a document from the database
  """
  @spec remove(GenServer.server(), integer) :: :ok
  def remove(server, id), do: cast(server, %{remove: id})

  @doc """
  update a document from the database
  """
  @spec update(GenServer.server(), integer, map) :: :ok
  def update(server, id, doc), do: cast(server, %{remove: id}, [doc])

  @doc """
  perform a query with default option
  """
  @spec search(GenServer.server(), String.t()) :: list
  def search(server, query), do: call(server, %{search: query, limit: @default_limit})

  @doc """
  perform a query with options
  """
  @spec search(GenServer.server(), String.t(), integer) :: list
  def search(server, query, limit), do: call(server, %{search: query, limit: limit})

  defp call(server, request) do
    server
    |> GenServer.call(Jason.encode!(request))
    |> Enum.map(&Jason.decode!(&1))
  end

  defp cast(server, request) do
    GenServer.cast(server, {Jason.encode!(request), []})
  end

  defp cast(server, request, list) do
    GenServer.cast(server, {Jason.encode!(request), Enum.map(list, &Jason.encode!(&1))})
  end

  # server side
  @impl true
  def init(command) do
    Process.flag(:trap_exit, true)
    Logger.info("port server to #{command} booting")
    port = Port.open({:spawn, command}, [{:packet, 4}, :binary])
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
  # <<"P", 0, 0, 0>> for oneway message: Posted request without data
  # <<"p", 0, 0, 0>> for oneway message: Posted request with data
  # <<"R", seq :: 24>> for message needing a reply: Request without data
  # <<"r", seq :: 24>> for message needing a reply: Request with data
  # <<"D", 0, 0, 0>> data packet following request end of request 
  # <<"d", 0, 0, 0>> data packet following request, end of request
  # <<"C", seq :: 24>> for reply to a previous request: Completion, end of reply
  # <<"c", seq :: 24>> for reply to a previous request: Completion, to be continued

  @impl true
  def handle_cast({command, []}, %__MODULE__{port: port} = state) do
    Port.command(port, [<<"P", 0, 0, 0>> | command])
    {:noreply, state}
  end

  def handle_cast({command, list}, %__MODULE__{port: port} = state) do
    Port.command(port, [<<"p", 0, 0, 0>> | command])
    send_data(port, list)
    {:noreply, state}
  end

  @impl true
  def handle_call(data, from, %__MODULE__{port: port, seq: seq, map: map} = state) do
    case Map.has_key?(map, seq) do
      true ->
        raise("sequence number #{seq} still not released")

      false ->
        Port.command(port, [<<"R", seq::24>> | data])
        {:noreply, %{state | seq: next_seq(seq), map: Map.put(map, seq, {from, []})}}
    end
  end

  @impl true
  def handle_info(
        {port, {:data, <<"C", seq::24, data::binary>>}},
        %__MODULE__{port: port, map: map} = state
      ) do
    case byte_size(data) do
      0 -> {:noreply, %{state | map: deliver_msg(map, seq)}}
      _ -> {:noreply, %{state | map: map |> receive_data(data, seq) |> deliver_msg(seq)}}
    end
  end

  @impl true
  def handle_info(
        {port, {:data, <<"c", seq::24, data::binary>>}},
        %__MODULE__{port: port, map: map} = state
      ) do
    {:noreply, %{state | map: receive_data(map, data, seq)}}
  end

  defp send_data(port, [head]), do: Port.command(port, [<<"D", 0, 0, 0>> | head])

  defp send_data(port, [head | tail]) do
    Port.command(port, [<<"d", 0, 0, 0>> | head])
    send_data(port, tail)
  end

  # legal sequence number is 0 ~ 2^24-1
  defp next_seq(0xFF_FFFF), do: 0
  defp next_seq(seq), do: seq + 1

  defp flush_port(port, map) do
    receive do
      {port, {:data, <<"c", seq::24, data::binary>>}} ->
        flush_port(port, receive_data(map, data, seq))

      {port, {:data, <<"C", seq::24, data::binary>>}} ->
        map =
          case byte_size(data) do
            0 -> deliver_msg(map, seq)
            _ -> map |> receive_data(data, seq) |> deliver_msg(seq)
          end

        case Enum.empty?(map) do
          true -> :ok
          false -> flush_port(port, map)
        end

      _ ->
        flush_port(port, map)
    end
  end

  defp deliver_msg(map, seq) do
    {from, buf} = Map.fetch!(map, seq)
    GenServer.reply(from, Enum.reverse(buf))
    Map.delete(map, seq)
  end

  def receive_data(map, data, seq) do
    {from, buf} = Map.fetch!(map, seq)
    %{map | seq => {from, [data | buf]}}
  end
end
