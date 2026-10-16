defmodule Alnasl.PlacementsMigrationTest do
  @moduledoc """
  A box upgraded to placements seats its boards exactly as before: every
  tournament becomes one placement - its hall, its range or none, board 1
  on its first table - and every table plays the board it played. Run
  against a database of its own, made as the version before would have
  left it.
  """

  use ExUnit.Case, async: false

  alias Alnasl.{Placements, Repo, Tables, Tournaments}

  @placements 20_261_016_215_805
  @path Path.expand("../../priv/repo/migrations", __DIR__)

  setup do
    file =
      Path.join(
        System.tmp_dir!(),
        "alnasl-placements-#{System.os_time()}-#{System.unique_integer([:positive])}.db"
      )

    {:ok, pid} =
      Repo.start_link(
        name: nil,
        database: file,
        pool: DBConnection.ConnectionPool,
        pool_size: 1,
        log: false
      )

    Repo.put_dynamic_repo(pid)
    Code.put_compiler_option(:ignore_module_conflict, true)

    on_exit(fn ->
      Code.put_compiler_option(:ignore_module_conflict, false)
      for suffix <- ["", "-wal", "-shm"], do: File.rm(file <> suffix)
    end)

    Ecto.Migrator.run(Repo, @path, :up, to_exclusive: @placements, dynamic_repo: pid, log: false)
    {:ok, pid: pid}
  end

  defp tournament(id, name, hall_id, from, to) do
    Repo.query!(
      """
      INSERT INTO tournaments (id, kind, name, hall_id, table_from, table_to, remote_id,
        gone, auto_start, round, inserted_at, updated_at)
      VALUES (?, 'linked', ?, ?, ?, ?, ?, 0, 1, 1, datetime('now'), datetime('now'))
      """,
      [id, name, hall_id, from, to, id]
    )
  end

  test "every tournament becomes one placement, and every table plays the board it did",
       %{pid: pid} do
    [[own]] = Repo.query!("SELECT id FROM halls WHERE own = 1").rows

    Repo.query!(
      "INSERT INTO halls (name, own, inserted_at, updated_at) VALUES ('Annex', 0, datetime('now'), datetime('now'))"
    )

    [[annex]] = Repo.query!("SELECT id FROM halls WHERE own = 0").rows

    # Two tournaments sharing the own hall, one without a range, one in the
    # annex with a single table, and one from before halls.
    tournament(2, "Open", own, 1, 8)
    tournament(3, "U12", own, 9, 16)
    tournament(4, "Blitz", own, nil, nil)
    tournament(5, "Annex", annex, 5, nil)
    tournament(6, "Old", nil, 3, 4)

    Ecto.Migrator.run(Repo, @path, :up, all: true, dynamic_repo: pid, log: false)

    rows =
      Repo.query!(
        "SELECT tournament_id, hall_id, table_from, table_to, first_board FROM tournament_placements ORDER BY tournament_id"
      ).rows

    assert rows == [
             [1, own, nil, nil, 1],
             [2, own, 1, 8, 1],
             [3, own, 9, 16, 1],
             [4, own, nil, nil, 1],
             [5, annex, 5, 5, 1],
             [6, own, 3, 4, 1]
           ]

    # The ranges are not on the tournaments any more.
    columns = Repo.query!("PRAGMA table_info(tournaments)").rows |> Enum.map(&Enum.at(&1, 1))
    refute "table_from" in columns

    # The same tables, the same boards.
    seat = fn tid, hall, table ->
      Tables.home_board(%{table_no: table, tournament_id: tid, hall_id: hall})
    end

    assert seat.(2, own, 5) == 5
    assert seat.(3, own, 9) == 1
    assert seat.(3, own, 16) == 8
    assert seat.(3, own, 8) == nil
    assert seat.(4, own, 3) == 3
    assert seat.(5, annex, 5) == 1
    assert seat.(5, annex, 6) == 2
    assert seat.(6, own, 4) == 2

    assert Tournaments.for_table(12, own).id == 3
    assert Tournaments.for_table(5, annex).id == 5
    assert Tournaments.for_table(5, own).id == 2
    assert Tournaments.for_table(20, own) == nil

    assert Enum.map(Placements.list(3), & &1.hall_id) == [own]
  end
end
