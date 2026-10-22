defmodule Alnasl.Contract do
  @moduledoc """
  The other programs' contracts, as vendored in `priv/contracts/vendor/`
  (`mix contracts.sync`), for the tests: their schemas resolved without the
  network, their examples, and a check that something fits.

  A contract is named by its provider and directory, as
  `priv/contracts/vendor/contracts.json` lists it:

  | | |
  |---|---|
  | `:link` | OpenPairings' `alnasl-link-v1`: the board link Alnasl calls |
  | `:bridge` | Arkab's `bridge-protocol-v1`: the bridge's socket, its join, the DGT serial opening |
  | `:publish` | OpenResults' `publish-v1`: where the moves go |

  A schema's `$ref` to `common.schema.json` is a URL on GitHub once its
  `$id` is applied. `resolve/1` is ex_json_schema's remote resolver
  (`config/test.exs`) and answers every such URL from the vendored copy, so
  a test never asks GitHub what the file beside it says.
  """

  import ExUnit.Assertions

  @root Path.expand("../../priv/contracts/vendor", __DIR__)
  @contracts %{
    link: {"openpairings", "alnasl-link-v1"},
    bridge: {"arkab", "bridge-protocol-v1"},
    publish: {"openresults", "publish-v1"}
  }

  def root, do: @root
  def contracts, do: Map.keys(@contracts)

  def dir(contract) do
    {repo, name} = Map.fetch!(@contracts, contract)
    Path.join([@root, repo, name])
  end

  @doc "Every file of the vendored copy, relative and sorted, `index.json` left out."
  def files(contract) do
    dir = dir(contract)

    Path.wildcard(Path.join(dir, "**/*"))
    |> Enum.reject(&File.dir?/1)
    |> Enum.map(&Path.relative_to(&1, dir))
    |> Enum.reject(&(&1 == "index.json"))
    |> Enum.sort()
  end

  def read!(contract, file),
    do: contract |> dir() |> Path.join(file) |> File.read!() |> Jason.decode!()

  @doc "An example by its name: `example(:publish, \"error.response.board-not-published\")`."
  def example(contract, name), do: read!(contract, "examples/#{name}.json")

  @doc "The names of the schemas: `\"error.response\"` for `error.response.schema.json`."
  def schemas(contract) do
    for file <- files(contract),
        String.ends_with?(file, ".schema.json"),
        file != "common.schema.json",
        do: String.replace_suffix(file, ".schema.json", "")
  end

  @doc """
  `[{schema, name, data}]` for every example. `x.json` and `x.<variant>.json`
  belong to schema `x`; a schema name may hold dots itself
  (`error.response`), so the longest schema that fits wins.
  """
  def examples(contract) do
    schemas = contract |> schemas() |> Enum.sort_by(&(-String.length(&1)))

    for "examples/" <> file <- files(contract) do
      name = String.replace_suffix(file, ".json", "")
      schema = Enum.find(schemas, &(name == &1 or String.starts_with?(name, &1 <> ".")))
      {schema, name, read!(contract, "examples/" <> file)}
    end
  end

  @doc "The examples of one schema: `[{name, data}]`."
  def examples(contract, schema),
    do: for({^schema, name, data} <- examples(contract), do: {name, data})

  @doc "The schema `name` of `contract`, resolved."
  def schema(contract, name) do
    key = {__MODULE__, contract, name}

    case :persistent_term.get(key, nil) do
      nil ->
        root = ExJsonSchema.Schema.resolve(read!(contract, "#{name}.schema.json"))
        :persistent_term.put(key, root)
        root

      root ->
        root
    end
  end

  @doc "`:ok`, or `{:error, [{message, path}]}`."
  def validate(contract, name, data),
    do: ExJsonSchema.Validator.validate(schema(contract, name), data)

  @doc """
  Asserts that `data` fits schema `name` and returns it as JSON would: a
  map with atom or string keys, or JSON text, is put through JSON first, as
  the wire would.
  """
  def assert_valid!(contract, name, data) do
    json =
      if is_binary(data),
        do: Jason.decode!(data),
        else: data |> Jason.encode!() |> Jason.decode!()

    case validate(contract, name, json) do
      :ok ->
        json

      {:error, errors} ->
        flunk("""
        does not fit #{contract}: #{name}.schema.json:
        #{Enum.map_join(errors, "\n", fn {message, path} -> "  #{path}: #{message}" end)}
        in: #{Jason.encode!(json)}
        """)
    end
  end

  @doc false
  # ex_json_schema's remote resolver: `https://raw.githubusercontent.com/
  # teapot-chess/<Repo>/main/priv/contracts/<name>/<file>`, answered from the
  # vendored copy. Anything else is not ours to fetch, and is refused.
  def resolve(url) do
    case URI.parse(url) do
      %URI{host: "raw.githubusercontent.com", path: path} ->
        ["", "teapot-chess", repo, "main", "priv", "contracts", name, file] =
          String.split(path, "/")

        [@root, String.downcase(repo), name, file]
        |> Path.join()
        |> File.read!()
        |> Jason.decode!()

      _other ->
        raise ArgumentError, "a contract refers to #{url}, which is not vendored"
    end
  end
end
