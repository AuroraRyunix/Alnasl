defmodule Alnasl.FairPlay.Keep do
  @moduledoc """
  The owner's extension of the retention of one tournament
  (`fair_play_keeps`): its analysis and audit rows stay until `keep_until`,
  for a reason written down. At most 365 days after the tournament's last
  round (`Alnasl.FairPlay.Retention`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "fair_play_keeps" do
    field :tournament_id, :integer
    field :keep_until, :utc_datetime
    field :reason, :string
    field :set_by, :string
    timestamps(type: :utc_datetime)
  end

  def changeset(keep, attrs) do
    keep
    |> cast(attrs, [:keep_until, :reason, :set_by])
    |> update_change(:reason, &String.trim/1)
    |> validate_required([:keep_until, :reason])
    |> validate_length(:reason, max: 1000)
    |> unique_constraint(:tournament_id)
  end
end
