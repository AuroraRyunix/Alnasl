defmodule Alnasl.PlacementsTest do
  @moduledoc """
  Where tournaments are played: one tournament over two halls (boards 1-8
  in one, 9-16 in the other), two tournaments in one hall (tables 1-8 and
  9-16, as always), what is refused, and who sees and changes what when a
  tournament is in more than one hall.
  """

  use Alnasl.DataCase, async: false

  alias Alnasl.{Boards, Halls, Placements, Tables, Tournaments}
  alias Alnasl.Accounts.Scope
  alias Alnasl.Halls.Hall
  alias Alnasl.Tournaments.Tournament

  defp hall(name) do
    hall = Repo.insert!(%Hall{name: name, own: false})
    Halls.local_tournament(hall)
    hall
  end

  # A linked tournament of `boards` boards in round 1, from `hall`.
  defp tournament(name, hall_id, boards \\ 16) do
    t = Repo.insert!(%Tournament{kind: "linked", name: name, hall_id: hall_id, remote_id: 1})

    {:ok, t} =
      Tournaments.import_snapshot(t, %{
        "tournament" => %{"name" => name},
        "players" => for(n <- 1..(boards * 2), do: %{"no" => n, "name" => "Player #{n}"}),
        "rounds" => [
          %{
            "number" => 1,
            "boards" =>
              for(b <- 1..boards, do: %{"board" => b, "white" => 2 * b - 1, "black" => 2 * b})
          }
        ]
      })

    t
  end

  # A board row, no process behind it.
  defp board(hall_id, name) do
    {:ok, board} =
      Boards.create(%{
        name: name,
        driver: "simulator",
        port: "sim-#{name}",
        enabled: false,
        hall_id: hall_id
      })

    board
  end

  defp scope(roles, hall) do
    halls = for id <- Map.keys(roles), do: Halls.get(id)
    %Scope{user: %Alnasl.Accounts.User{id: 1}, roles: roles, halls: halls, hall: hall}
  end

  describe "one tournament, two halls" do
    setup do
      a = Halls.own()
      b = hall("Annex")
      open = tournament("Open", a.id)
      {:ok, _} = Tournaments.assign_tables(open, 1, 8, a.id)
      %{a: a, b: b, open: Tournaments.get!(open.id)}
    end

    test "the hall added takes the boards after the first hall's, on its own first tables", %{
      a: a,
      b: b,
      open: open
    } do
      assert {:ok, placement, []} = Placements.add(open, b.id)
      assert %{hall_id: hall_id, table_from: 1, table_to: 8, first_board: 9} = placement
      assert hall_id == b.id

      # Tables to boards, in each hall.
      assert Tournaments.board_of_table(open, 1, nil, a.id) == 1
      assert Tournaments.board_of_table(open, 8, nil, a.id) == 8
      assert Tournaments.board_of_table(open, 1, nil, b.id) == 9
      assert Tournaments.board_of_table(open, 8, nil, b.id) == 16

      # And boards to tables: board 12 is table 4 of the annex.
      assert Placements.place_of(open, 3) == {a.id, 3}
      assert Placements.place_of(open, 12) == {b.id, 4}
      assert Placements.place_of(open, 17) == nil

      # A table of either hall is the tournament's there, and nowhere else.
      assert Tournaments.for_table(4, b.id).id == open.id
      assert Tournaments.for_table(4, a.id).id == open.id
    end

    test "boards given a table in each hall feed the right board of the round", %{
      a: a,
      b: b,
      open: open
    } do
      {:ok, _, _} = Placements.add(open, b.id)
      here = board(a.id, "here")
      there = board(b.id, "there")

      {:ok, _} = Tables.set_table(here, 3)
      {:ok, _} = Tables.set_table(there, 3)

      assert %{tournament_id: tid, round: 1, board_no: 3} = Boards.get!(here.id)
      assert tid == open.id
      assert %{tournament_id: ^tid, round: 1, board_no: 11} = Boards.get!(there.id)
      assert Tables.home_board(Boards.get!(there.id)) == 11

      # The annex's table 3 is no clash with the main hall's table 3.
      refute Enum.any?(Tables.checks(open.id, 1), &match?({:duplicate_table, _, _}, &1.what))
    end

    test "a board already on a table of the new hall joins when the hall is added", %{
      b: b,
      open: open
    } do
      there = board(b.id, "there")
      {:ok, _} = Tables.set_table(there, 2)
      assert Boards.get!(there.id).tournament_id == Halls.local_tournament(b).id

      {:ok, _, _} = Placements.add(open, b.id)
      assert %{board_no: 10} = Boards.get!(there.id)
      assert Boards.get!(there.id).tournament_id == open.id
    end

    test "two placements of one tournament never hold the same board", %{
      a: a,
      b: b,
      open: open
    } do
      {:ok, _, _} = Placements.add(open, b.id)

      assert {:error, :boards} =
               Placements.put(open, b.id, %{table_from: 1, table_to: 8, first_board: 5})

      # Nor through the old question: tables 1-10 here would be boards 9-10 twice.
      assert {:error, :boards} = Tournaments.assign_tables(open, 1, 10, a.id)
      assert Tournaments.tables(open, a.id) == {1, 8}
    end

    test "the last hall cannot go; another can, and its boards go home", %{
      a: a,
      b: b,
      open: open
    } do
      assert {:error, :last} = Placements.remove(Placements.in_hall(open, a.id))

      {:ok, _, _} = Placements.add(open, b.id)
      there = board(b.id, "there")
      {:ok, _} = Tables.set_table(there, 1)
      assert Boards.get!(there.id).tournament_id == open.id

      assert :ok = Placements.remove(Placements.in_hall(open, b.id))
      assert Placements.halls_of(open) == [a.id]
      assert %{board_no: nil} = Boards.get!(there.id)
      assert Boards.get!(there.id).tournament_id == Halls.local_tournament(b).id

      assert {:error, :last} = Placements.remove(Placements.in_hall(open, a.id))
    end

    test "a hall the tournament is in already is not added twice", %{a: a, open: open} do
      assert {:error, :already} = Placements.add(open, a.id)
    end
  end

  describe "two tournaments, one hall" do
    setup do
      own = Halls.own_id()
      open = tournament("Open", own, 8)
      u12 = tournament("U12", own, 8)
      {:ok, _} = Tournaments.assign_tables(open, 1, 8)
      {:ok, _} = Tournaments.assign_tables(u12, 9, 16)
      %{own: own, open: Tournaments.get!(open.id), u12: Tournaments.get!(u12.id)}
    end

    test "tables 1-8 and 9-16, table 9 being the second one's board 1", ctx do
      %{open: open, u12: u12} = ctx

      assert Tournaments.board_of_table(open, 5) == 5
      assert Tournaments.board_of_table(u12, 9) == 1
      assert Tournaments.board_of_table(u12, 16) == 8
      assert Tournaments.board_of_table(u12, 8) == nil
      assert Tournaments.for_table(12).id == u12.id
      assert Tournaments.for_table(3).id == open.id
      assert Tournaments.for_table(17) == nil

      b = board(ctx.own, "b")
      {:ok, _} = Tables.set_table(b, 10)
      assert %{board_no: 2} = Boards.get!(b.id)
      assert Boards.get!(b.id).tournament_id == u12.id
    end

    test "a placement's tables another tournament holds are refused", %{own: own, u12: u12} do
      assert {:error, :tables, other} =
               Placements.put(u12, own, %{table_from: 5, table_to: 12})

      assert other.name == "Open"
      assert Tournaments.tables(u12) == {9, 16}
    end

    test "the old question still takes the tables over, as it always did", ctx do
      %{open: open, u12: u12} = ctx
      {:ok, _} = Tournaments.assign_tables(u12, 7, 16)
      assert Tournaments.tables(open) == {nil, nil}
      assert Tournaments.tables(u12) == {7, 16}
    end
  end

  describe "who sees and changes it" do
    setup do
      a = Halls.own()
      b = hall("Annex")
      c = hall("Cellar")
      open = tournament("Open", a.id)
      {:ok, _} = Tournaments.assign_tables(open, 1, 8, a.id)
      %{a: a, b: b, c: c, open: Tournaments.get!(open.id)}
    end

    test "listed and openable in every hall it is placed in", %{a: a, b: b, open: open} do
      in_b = scope(%{b.id => "viewer"}, b)
      refute Halls.sees?(in_b, open)
      refute Enum.any?(Halls.here(in_b, Tournaments.list()), &(&1.id == open.id))

      {:ok, _, _} = Placements.add(open, b.id)
      assert Halls.sees?(in_b, open)
      assert Enum.any?(Halls.here(in_b, Tournaments.list()), &(&1.id == open.id))
      assert Enum.any?(Halls.active(in_b), &(&1.id == open.id))
      assert Enum.any?(Halls.visible(in_b, Tournaments.list()), &(&1.id == open.id))

      # Still in the first hall too.
      in_a = scope(%{a.id => "viewer"}, a)
      assert Enum.any?(Halls.here(in_a, Tournaments.list()), &(&1.id == open.id))
    end

    test "the role for it is the highest in any of its halls", %{a: a, b: b, open: open} do
      {:ok, _, _} = Placements.add(open, b.id)
      account = scope(%{a.id => "viewer", b.id => "arbiter"}, a)

      assert Placements.role(account, open) == "arbiter"
      assert Placements.can?(account, :arbiter, open)
      refute Placements.can?(account, :owner, open)

      # The permit agrees, even looking at the hall where the account only watches.
      assert AlnaslWeb.Permit.allowed?(
               account,
               AlnaslWeb.SetupLive,
               "auto_start",
               %{"id" => "#{open.id}"},
               %{}
             )

      watcher = scope(%{a.id => "viewer"}, a)

      refute AlnaslWeb.Permit.allowed?(
               watcher,
               AlnaslWeb.SetupLive,
               "auto_start",
               %{"id" => "#{open.id}"},
               %{}
             )
    end

    test "a hall can be added only where the account is arbiter or owner", ctx do
      %{a: a, b: b, c: c, open: open} = ctx
      account = scope(%{a.id => "arbiter", b.id => "owner", c.id => "viewer"}, a)
      assert Enum.map(Placements.addable_halls(account, open), & &1.id) == [b.id]

      admin = %Scope{user: %Alnasl.Accounts.User{id: 1}, admin?: true, hall: a}
      assert Enum.map(Placements.addable_halls(admin, open), & &1.id) == [b.id, c.id]

      # Nor through a hand-made event naming the cellar.
      refute AlnaslWeb.Permit.allowed?(
               account,
               AlnaslWeb.SetupLive,
               "placement_add",
               %{"t" => "#{open.id}", "hall" => "#{c.id}"},
               %{}
             )

      assert AlnaslWeb.Permit.allowed?(
               account,
               AlnaslWeb.SetupLive,
               "placement_add",
               %{"t" => "#{open.id}", "hall" => "#{b.id}"},
               %{}
             )
    end
  end
end
