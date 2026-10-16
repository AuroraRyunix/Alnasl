defmodule Alnasl.Bridges.Join do
  @moduledoc """
  A join code: shown once as a link and a QR code, good for fifteen
  minutes and one bridge.
  """

  use Ecto.Schema

  schema "bridge_joins" do
    field :code, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime
    field :bridge_id, :integer
    # The hall the bridge goes into.
    field :hall_id, :integer
    timestamps(type: :utc_datetime)
  end
end
