defmodule Alnasl.Bridges.Bridge do
  @moduledoc """
  An Arkab bridge this box has let in: its name for itself (`uid`), what
  it is called, the hash of its key, and the highest event number taken
  from it (`seen_seq`). `revoked_at` is set when it is removed here; the
  row stays so that the bridge, dialling in later, is told to forget this
  server instead of being merely turned away. `hall_id` is the hall its
  boards are in (`Alnasl.Halls`).
  """

  use Ecto.Schema

  schema "bridges" do
    field :uid, :string
    field :name, :string
    field :software, :string
    field :key_hash, :string, redact: true
    field :seen_seq, :integer, default: 0
    field :last_connected_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :hall_id, :integer
    timestamps(type: :utc_datetime)
  end
end
