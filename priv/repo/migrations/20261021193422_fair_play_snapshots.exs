defmodule Alnasl.Repo.Migrations.FairPlaySnapshots do
  use Ecto.Migration

  # A tournament's fair-play analysis deleted on request leaves a frozen copy
  # of what its report said (`Alnasl.FairPlay.Snapshot`): who deleted it,
  # when, why. Kept under the same retention as the report was.
  def change do
    create table(:fair_play_snapshots) do
      add :hall_id, :integer, null: false
      add :tournament_id, :integer, null: false
      add :title, :string
      add :deleted_by, :string
      add :deleted_by_id, :integer
      add :deleted_at, :utc_datetime, null: false
      add :reason, :text
      add :moves, :integer, null: false, default: 0
      # JSON: the report's players as they were, one map each.
      add :report, :text, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:fair_play_snapshots, [:tournament_id])
  end
end
