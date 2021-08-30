defmodule TantivyTest do
  use ExUnit.Case
  doctest Tantivy

  setup_all do
    Tantivy.start(
      name: DUT,
      command: "tantivy port -i test-index/"
    )

    :ok
    on_exit(fn -> GenServer.stop(DUT) end)
  end

  # right now there is no way to enforce barrier in a read-after-write situation, so the test
  # may fail and is for illustration only
  test "simple write read" do
    Tantivy.remove(DUT, 0)
    Tantivy.add(DUT, %{id: 0, title: "test"})
    assert Tantivy.search(DUT, "test") == [%{"id" => [0]}]
  end
end
