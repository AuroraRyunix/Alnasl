defmodule Alnasl.Repo.Migrations.FairPlayTables do
  use Ecto.Migration

  # Fair-play screening (`Alnasl.FairPlay`, docs/plan-fair-play.md, section 6).
  # Everything here is the hall owner's and nobody else's: see
  # `Alnasl.FairPlay.Access`. Off by default: a hall without a row has it off.
  def change do
    # Per hall: switched on or not, and the engine this machine has for it.
    create table(:fair_play_settings) do
      add :hall_id, :integer, null: false
      add :enabled, :boolean, null: false, default: false
      add :engine_id, :string
      add :engine_path, :string
      add :engine_version, :string
      add :engine_bench, :integer
      add :nodes, :integer, null: false, default: 1_000_000
      timestamps(type: :utc_datetime)
    end

    create unique_index(:fair_play_settings, [:hall_id])

    # One row per analysed ply of a game. `prefix_hash` says which moves led
    # here: a row whose hash is not the game's any more (a rewritten move
    # before it) is stale and thrown away.
    create table(:fair_play_moves) do
      add :tournament_id, :integer, null: false
      add :game_id, :integer, null: false
      add :round, :integer, null: false
      add :board_no, :integer, null: false
      add :ply, :integer, null: false
      add :colour, :string, null: false
      add :move_number, :integer, null: false
      add :player_key, :string, null: false
      add :player_name, :string
      add :san, :string, null: false
      add :played_uci, :string, null: false
      add :fen, :string, null: false
      add :prefix_hash, :string, null: false
      # JSON: [%{"move", "cp"}], the engine's best lines.
      add :best, :text
      add :played_cp, :integer
      add :rank, :integer
      add :gap, :integer
      add :near_count, :integer
      add :material, :integer
      add :clock_before_ms, :integer
      add :rating, :integer
      add :skip, :string
      add :engine_id, :string
      add :engine_version, :string
      add :bench, :integer
      add :nodes, :integer
      timestamps(type: :utc_datetime)
    end

    create unique_index(:fair_play_moves, [:game_id, :ply])
    create index(:fair_play_moves, [:tournament_id, :round])

    # The owner's extension of the retention of one tournament.
    create table(:fair_play_keeps) do
      add :tournament_id, :integer, null: false
      add :keep_until, :utc_datetime, null: false
      add :reason, :text, null: false
      add :set_by, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:fair_play_keeps, [:tournament_id])

    # Who opened which report, and when. `user_email` stays when the account goes.
    create table(:fair_play_views) do
      add :tournament_id, :integer, null: false
      add :user_id, :integer
      add :user_email, :string
      add :round, :integer
      add :player_key, :string
      add :at, :utc_datetime, null: false
    end

    create index(:fair_play_views, [:tournament_id, :at])
  end
end
