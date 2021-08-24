defmodule TantivyTest do
  use ExUnit.Case
  doctest Tantivy

  setup_all do
    Tantivy.start(
      name: DUT,
      command:
        "/home/derek/projects/tantivy-cli/target/release/tantivy port -i /home/derek/test-index/"
    )

    :ok
    on_exit(fn -> GenServer.stop(DUT) end)
  end

  test "simple write read" do
    Tantivy.remove(DUT, 0)
    Tantivy.add(DUT, %{id: 0, title: "test"})
    assert Tantivy.search(DUT, "test") == [%{"id" => [0]}]
  end
end
