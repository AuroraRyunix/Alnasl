defmodule Alnasl.Repo.Migrations.TournamentPlacements do
  use Ecto.Migration

  # A tournament stops being in one hall on one run of tables. It is placed
  # (`Alnasl.Placements`): in hall H, tables from-to, the first of them
  # playing its board `first_board`. Boards 1-8 in the main hall and 9-16
  # in the annex are two placements of one tournament; the Open on tables
  # 1-8 and the under-twelves on 9-16 are one placement each in one hall.
  #
  # Every tournament the box has becomes exactly one placement: its hall,
  # the range it had (none stays none: every table of the hall no other
  # range holds) and board 1 on its first table - which is what it already
  # meant. `tournaments.hall_id` stays, as the hall the tournament comes
  # from; the range moves out of the row.
  def up do
    create table(:tournament_placements) do
      add :tournament_id, references(:tournaments, on_delete: :delete_all), null: false
      add :hall_id, :integer, null: false
      add :table_from, :integer
      add :table_to, :integer
      add :first_board, :integer, null: false, default: 1
      timestamps(type: :utc_datetime)
    end

    create unique_index(:tournament_placements, [:tournament_id, :hall_id])
    create index(:tournament_placements, [:hall_id])

    execute("""
    INSERT INTO tournament_placements
      (tournament_id, hall_id, table_from, table_to, first_board, inserted_at, updated_at)
    SELECT t.id,
           COALESCE(t.hall_id, (SELECT id FROM halls WHERE own = 1 ORDER BY id LIMIT 1)),
           t.table_from,
           CASE WHEN t.table_from IS NULL THEN NULL ELSE COALESCE(t.table_to, t.table_from) END,
           1, datetime('now'), datetime('now')
    FROM tournaments t
    WHERE COALESCE(t.hall_id, (SELECT id FROM halls WHERE own = 1 ORDER BY id LIMIT 1)) IS NOT NULL
    """)

    alter table(:tournaments) do
      remove :table_from
      remove :table_to
    end
  end

  def down do
    alter table(:tournaments) do
      add :table_from, :integer
      add :table_to, :integer
    end

    # Back to one range a tournament: the one in its own hall.
    execute("""
    UPDATE tournaments SET
      table_from = (SELECT p.table_from FROM tournament_placements p
                    WHERE p.tournament_id = tournaments.id AND p.hall_id = tournaments.hall_id),
      table_to = (SELECT p.table_to FROM tournament_placements p
                  WHERE p.tournament_id = tournaments.id AND p.hall_id = tournaments.hall_id)
    """)

    drop table(:tournament_placements)
  end
end
