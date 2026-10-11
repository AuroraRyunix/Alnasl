defmodule Alnasl.Settings.Setting do
  @moduledoc "One setting: a key and its JSON value."
  use Ecto.Schema

  @primary_key {:key, :string, autogenerate: false}
  schema "settings" do
    field :value, :string
  end
end
