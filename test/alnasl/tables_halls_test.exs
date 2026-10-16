defmodule Alnasl.TablesHallsTest do
  @moduledoc """
  A serial is a board, a row is a hall's. The same physical board turning
  up in another hall is a new board there, and the first hall keeps its
  row, its table and its game; carried between two bridges of one hall it
  is recognised as before.
  """

  use Alnasl.HallCase

  # A bridge stopped at the end of a test may grumble; not news.
  @moduletag :capture_log

  alias Alnasl.{Bridges, Halls, Tables}
  alias Alnasl.Halls.Hall
  alias Arkab.Dgt.Emulator
  alias Arkab.Transport.Fake

  defp hall(name) do
    hall = Repo.insert!(%Hall{name: name, own: false})
    Halls.local_tournament(hall)
    hall
  end

  defp bridge(hall, uid) do
    {:ok, join} = Bridges.create_join(DateTime.utc_now(:second), hall.id)

    {:ok, %{bridge: bridge}} =
      Bridges.redeem(join.code, %{"v" => 1, "bridge" => uid, "name" => uid, "software" => "arkab"})

    bridge
  end

  test "the same board in another hall is a new row there; the first hall's is left alone" do
    start_supervised!({Fake, port: "FAKE-A", device: {Emulator, Emulator.new(serial: "06310")}},
      id: "FAKE-A"
    )

    {:ok, own_row} = Boards.create(%{name: "Top board", driver: "dgt_serial", port: "FAKE-A"})
    eventually(fn -> Boards.get!(own_row.id).serial == "06310" end)
    {:ok, _} = Tables.set_table(Boards.get!(own_row.id), 3)
    play_on("FAKE-A", own_row.id, ~w(e4 e5))

    # The board is carried to the hall next door, which has a bridge.
    Boards.disconnect(Boards.get!(own_row.id))
    stop_supervised!("FAKE-A")

    b = hall("Annex")
    {:ok, there} = Bridges.board_row(bridge(b, "annex-pi"), "COM1")
    assert there.hall_id == b.id

    assert Tables.recognise(there.id, there.port, there.address, "06310") == :new

    assert length(Boards.list()) == 2
    mine = Boards.get!(own_row.id)
    assert %{port: "FAKE-A", table_no: 3, board_no: 3, name: "Top board"} = mine
    assert mine.hall_id == Halls.own_id()
    assert Games.sans(Games.get(1, 3)) == ~w(e4 e5)
    refute Boards.snapshot(mine.id).connected?

    fresh = Boards.get!(there.id)
    assert fresh.hall_id == b.id and fresh.serial == "06310"
    assert fresh.table_no == nil and fresh.board_no == nil
    assert fresh.tournament_id == Halls.local_tournament(b).id

    # And the same board, read on both sides at once, is no clash in either hall.
    refute Enum.any?(Tables.checks(1), &match?({:same_serial, _, _}, &1.what))

    refute Enum.any?(
             Tables.checks(Halls.local_tournament(b).id, 1),
             &match?({:same_serial, _, _}, &1.what)
           )

    # The way back: the bridge's row is not taken back to the box's port either.
    assert Tables.recognise(fresh.id) == :new
    assert Boards.get!(own_row.id).port == "FAKE-A"
  end

  test "carried between two bridges of one hall it is recognised and keeps its table" do
    b = hall("Annex")
    {:ok, first} = Bridges.board_row(bridge(b, "pi-one"), "COM1")
    {:ok, first} = Boards.update(first, %{serial: "06310"})
    {:ok, first} = Tables.set_table(first, 5)
    assert first.table_no == 5

    {:ok, second} = Bridges.board_row(bridge(b, "pi-two"), "COM2")
    refute Boards.snapshot(first.id).connected?

    assert {:exchanged, owner} = Tables.recognise(second.id, second.port, second.address, "06310")
    assert owner.id == first.id
    moved = Boards.get!(first.id)
    assert moved.port == second.port and moved.table_no == 5 and moved.hall_id == b.id
  end
end
