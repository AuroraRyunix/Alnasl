defmodule Alnasl.Halls.Hall do
  @moduledoc """
  A place with boards. `own` is the hall of the box's own serial ports;
  there is exactly one, made when the box was upgraded to halls. Every other
  hall is boards that arrive through bridges.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "halls" do
    field :name, :string
    field :own, :boolean, default: false
    timestamps(type: :utc_datetime)
  end

  def changeset(hall, attrs) do
    hall
    |> cast(attrs, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 80)
  end
end
