# Tantivy

Tantivy is a Elixir library that wraps the [tantivy full text search library](https://github.com/tantivy-search/tantivy) using an Erlang port.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `tantivy` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:tantivy, "~> 0.1.0"}
  ]
end
```

A GenServer also needs to be started as part of your supervision tree:

``` elixir
  def start(_type, _args) do
    children = [
	  ...
      # start the full text index server
      {Tantivy, name: MyApp.MyIndex, command: my_index_command()},
	  ...
    ]
...

  defp my_index_command do
    config = Application.fetch_env!(:my_app, MyApp.MyIndex)
    dir = Keyword.fetch!(config, :dir)
    command = Keyword.get(config, :command) || "tantivy"
    "#{command} port -i #{dir}"
  end

```

And in your `config.exs`, to configure the index dir:

``` elixir
# full text search
config :my_app, MyApp.MyIndex, dir: "#{System.get_env("HOME")}/#{Mix.env()}-index/"

```

It is supposed to be used together with a [forked version of tantivy-cli](https://github.com/derek-zhou/tantivy-cli). Please make sure use the `erlang-port` branch.

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/tantivy](https://hexdocs.pm/tantivy).

## Usage

You must define a document schema before hand, as outlined in the `tantivy-cli` documentation [here:](https://github.com/derek-zhou/tantivy-cli#creating-the-index--new). Right now it is required to have a unsigned interger field called `id`. If you use a relational database such as PostgreSQL, the auto-increment primary key will be a perfect fit. Please note that this limitation is from this wrapper, not tantivy itself.

As shown in the previous example, the Elixir part will launch a GenServer that communicate with a external process via a port. All requests will be forwarded to the external `tantivy` process. Although the GenServer serialize requests; the wire protocol is designed with a split command/completion style so requests will be executed in parallel on the other sie of the port, and completed out of order. Therefore, multiple searching operations can be outstanding, maximizing the throughput.

### Adding a document

A document is a map conforming to the previously defined schema. You can add documents one by one or pass a list:


``` elixir
alias MyApp.MyIndex

Tantivy.add(MyIndex, %{id: 1, title: title})
Tantivy.add(MyIndex, [doc0, doc1])

```

The above function is fully async, and will return `:ok` immediately. Right now there is no way to capture failure.

### Deleting a document

You can only delete document one at a time, with the passed `id`.

``` elixir
alias MyApp.MyIndex

Tantivy.remove(MyIndex, 1)

```

This function will delete all documents with the same `id`. Again, delete is fully async.

### Update a document

`Update` is fused delete then add:

``` elixir
alias MyApp.MyIndex

Tantivy.remove(MyIndex, 1, %{id: 1, title: title})

```

Again, update is fully async.

### Search

This is where all the fun begin:

``` elixir
alias MyApp.MyIndex

list = Tantivy.search(MyIndex, query)

```

`query` is a query string as defined by tantivy. The query syntax is very simple: A query like `Joe Biden` means any document that contains `Joe` _or_ `Biden`. To seach for `Joe` _and_ `Biden`, you have to use `+Joe +Biden`. Or you can search for `"Joe Biden"`, which means any documents with `Joe` and `Biden` in consequtive positions. For more detail, please consult [tantivy documentation](https://docs.rs/tantivy/0.16.0/tantivy/query/struct.QueryParser.html)

Search will return a list of documents as seen by tantivy. It is recommended _not_ to store anything in tantivy except `id`, and use other storage such as a database. IF you only store `id`, the returning document list will be something like:

``` elixir
[%{id: [1]}, ...]
```

Please keep in mind that each field will be associated with a list of values. Tantivy allows multiple value per field and will return a list regardless what you put in.

## Credits

Huge thanks to the wonderful [Tantivy](https://github.com/tantivy-search/tantivy) full text search engine library. This wrapper only exposes the minimal amount of functionality that I need for myself. It does not do justice to the underneath Rust library. If you need something else, feel free to send my PRs.
