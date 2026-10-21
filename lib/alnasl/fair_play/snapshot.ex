defmodule Alnasl.FairPlay.Snapshot do
  @moduledoc """
  The frozen copy a deleted analysis leaves (`fair_play_snapshots`): the
  report's players and their numbers as they were, who deleted the analysis,
  when, and why if they said. It is the owner's alone, like the report it
  came from, and goes when the tournament's retention ends
  (`Alnasl.FairPlay.Retention`), not before.
  """
  use Ecto.Schema

  schema "fair_play_snapshots" do
    field :hall_id, :integer
    field :tournament_id, :integer
    field :title, :string
    field :deleted_by, :string
    field :deleted_by_id, :integer
    field :deleted_at, :utc_datetime
    field :reason, :string
    field :moves, :integer, default: 0
    field :report, :string
    timestamps(type: :utc_datetime)
  end

  @doc "The players of the frozen report: `[%{\"name\", \"score\", ...}]`."
  def players(%__MODULE__{report: json}) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _bad -> []
    end
  end
end
