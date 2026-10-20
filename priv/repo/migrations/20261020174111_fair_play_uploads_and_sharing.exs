defmodule Alnasl.Repo.Migrations.FairPlayUploadsAndSharing do
  use Ecto.Migration

  # Fair play, phase 2 (docs/plan-fair-play.md): games uploaded as PGN, the
  # owner's grants to named accounts, and an audit that is about more than
  # tournaments. Like everything of fair play, the hall owner's alone
  # (`Alnasl.FairPlay.Access`), and under the same retention.
  def up do
    # An uploaded PGN file: what was uploaded, by whom, and what of it could
    # be read. The file itself is not kept; its games are, below.
    create table(:fair_play_uploads) do
      add :hall_id, :integer, null: false
      # A tournament of the hall the games belong to, when they do: their
      # rows then count in its report and live as long as it does.
      add :tournament_id, :integer
      add :name, :string, null: false
      add :filename, :string
      add :byte_size, :integer
      add :sha256, :string
      add :uploaded_by, :string
      add :uploaded_by_id, :integer
      add :accepted, :integer, null: false, default: 0
      add :rejected, :integer, null: false, default: 0
      # JSON: [%{"game", "white", "black", "message", "kind"}], the problems
      # per game (refused, or accepted without a rating).
      add :problems, :text
      add :keep_until, :utc_datetime
      add :keep_reason, :text
      add :keep_set_by, :string
      timestamps(type: :utc_datetime)
    end

    create index(:fair_play_uploads, [:hall_id])
    create index(:fair_play_uploads, [:tournament_id])

    # One game of an upload, as read: tags, moves and clocks.
    create table(:fair_play_upload_games) do
      add :upload_id, :integer, null: false
      add :number, :integer, null: false
      add :event, :string
      add :date, :string
      add :round, :integer
      add :board, :integer
      add :white, :string
      add :black, :string
      add :white_elo, :integer
      add :black_elo, :integer
      add :white_fide_id, :integer
      add :black_fide_id, :integer
      add :result, :string
      add :start_fen, :string
      # SAN, one space between moves; clocks as JSON (ms after the move, or null).
      add :moves, :text, null: false
      add :clocks, :text
      # "waiting", "done", "failed", or "duplicate" (played on the boards too).
      add :status, :string, null: false, default: "waiting"
      add :error, :string
      timestamps(type: :utc_datetime)
    end

    create index(:fair_play_upload_games, [:upload_id, :status])

    # The analysis of an uploaded game: the same as fair_play_moves, for
    # games that have no row in `games`.
    create table(:fair_play_upload_moves) do
      add :upload_id, :integer, null: false
      add :tournament_id, :integer
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

    create unique_index(:fair_play_upload_moves, [:game_id, :ply])
    create index(:fair_play_upload_moves, [:upload_id])
    create index(:fair_play_upload_moves, [:tournament_id, :round])

    # The owner lets a named account see a report, or all of the hall's.
    # Explicit, expiring, revocable; a grant is never passed on.
    create table(:fair_play_grants) do
      add :hall_id, :integer, null: false
      # Neither: the hall's fair play, every report of it. One of them: that report.
      add :tournament_id, :integer
      add :upload_id, :integer
      add :user_id, :integer, null: false
      add :user_email, :string
      add :granted_by, :string
      add :expires_at, :utc_datetime, null: false
      add :revoked_at, :utc_datetime
      add :revoked_by, :string
      timestamps(type: :utc_datetime)
    end

    create index(:fair_play_grants, [:user_id])
    create index(:fair_play_grants, [:hall_id])

    # The audit grows up: still every opening of a report, now also every
    # grant, revocation, upload and round analysed on demand, and about
    # uploads and the hall as well as tournaments. SQLite cannot make a
    # column nullable in place, so the table is rebuilt with its rows.
    create table(:fair_play_views_new) do
      add :hall_id, :integer
      add :tournament_id, :integer
      add :upload_id, :integer
      add :user_id, :integer
      add :user_email, :string
      add :action, :string, null: false, default: "view"
      add :round, :integer
      add :player_key, :string
      add :detail, :string
      add :at, :utc_datetime, null: false
    end

    execute """
    INSERT INTO fair_play_views_new (id, tournament_id, user_id, user_email, action, round, player_key, at)
    SELECT id, tournament_id, user_id, user_email, 'view', round, player_key, at FROM fair_play_views
    """

    drop table(:fair_play_views)
    rename table(:fair_play_views_new), to: table(:fair_play_views)
    create index(:fair_play_views, [:tournament_id, :at])
    create index(:fair_play_views, [:upload_id, :at])
    create index(:fair_play_views, [:hall_id, :at])
  end

  def down do
    execute "DELETE FROM fair_play_views WHERE tournament_id IS NULL"

    create table(:fair_play_views_old) do
      add :tournament_id, :integer, null: false
      add :user_id, :integer
      add :user_email, :string
      add :round, :integer
      add :player_key, :string
      add :at, :utc_datetime, null: false
    end

    execute """
    INSERT INTO fair_play_views_old (id, tournament_id, user_id, user_email, round, player_key, at)
    SELECT id, tournament_id, user_id, user_email, round, player_key, at FROM fair_play_views
    WHERE action = 'view'
    """

    drop table(:fair_play_views)
    rename table(:fair_play_views_old), to: table(:fair_play_views)
    create index(:fair_play_views, [:tournament_id, :at])

    drop table(:fair_play_grants)
    drop table(:fair_play_upload_moves)
    drop table(:fair_play_upload_games)
    drop table(:fair_play_uploads)
  end
end
