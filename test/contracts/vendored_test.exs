defmodule Alnasl.Contracts.VendoredTest do
  @moduledoc """
  The vendored copies themselves: whole, as their providers list them, and
  each example fitting its own schema. A copy somebody "fixed" by hand
  fails here before it fails anywhere more confusing; `mix contracts.check`
  (CI, daily) says when the provider has moved on.
  """

  use ExUnit.Case, async: true

  alias Alnasl.Contract

  test "contracts.json lists exactly the vendored directories" do
    listed =
      Path.join(Contract.root(), "contracts.json")
      |> File.read!()
      |> Jason.decode!()
      |> Enum.map(&{String.downcase(&1["repo"]), &1["name"]})
      |> Enum.sort()

    present =
      for dir <- Path.wildcard(Path.join(Contract.root(), "*/*")), File.dir?(dir) do
        {dir |> Path.dirname() |> Path.basename(), Path.basename(dir)}
      end

    assert listed == Enum.sort(present)
    assert length(listed) == length(Contract.contracts())
  end

  test "a $ref into common.schema.json is followed, from the vendored copy" do
    # An error code OpenResults never sends is refused through the $ref;
    # a validator that skipped the reference would let it pass.
    assert {:error, _} =
             Contract.validate(:publish, "error.response", %{"error" => "nope", "detail" => ""})

    assert {:error, _} = Contract.validate(:bridge, "welcome", %{"type" => "welcome", "v" => 2})
  end

  for contract <- [:link, :bridge, :publish] do
    @contract contract

    test "#{contract}: index.json lists every file there is, and nothing else" do
      index = Contract.read!(@contract, "index.json")
      assert index["version"] == 1
      assert index["files"] == Contract.files(@contract)
    end

    test "#{contract}: every example fits its schema, and every schema has one" do
      examples = Contract.examples(@contract)

      for {schema, name, data} <- examples do
        assert schema, "example #{name} belongs to no schema"
        Contract.assert_valid!(@contract, schema, data)
      end

      for schema <- Contract.schemas(@contract) do
        assert Enum.any?(examples, &(elem(&1, 0) == schema)), "#{schema} has no example"
      end
    end
  end
end
