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

      # The permit agrees for the annex's own placement, even looking at the
      # hall where the account only watches.
      assert AlnaslWeb.Permit.allowed?(
               account,
               AlnaslWeb.SetupLive,
               "placement_save",
               %{"place" => %{"t" => "#{open.id}", "hall" => "#{b.id}", "from" => "1"}},
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

    test "the best role is for the annex's share; the tournament, the main hall and its boards are not",
         %{a: a, b: b, open: open} do
      {:ok, _, _} = Placements.add(open, b.id)
      blitz = tournament("Blitz", b.id, 4)
      account = scope(%{a.id => "viewer", b.id => "arbiter"}, a)
      allowed? = &AlnaslWeb.Permit.allowed?(account, &1, &2, &3, %{})

      # Tournament-wide and credentials: the home hall (the main hall) says.
      for event <- ~w(remove_tournament auto_start) do
        refute allowed?.(AlnaslWeb.SetupLive, event, %{"id" => "#{open.id}"})
      end

      refute allowed?.(AlnaslWeb.RoundLive, "next_round", %{"t" => "#{open.id}"})

      refute AlnaslWeb.Permit.allowed?(account, AlnaslWeb.SetupLive, "clear_lichess", %{}, %{
               lichess: open
             })

      # Board 3 is in the main hall, board 11 in the annex.
      refute allowed?.(AlnaslWeb.RoundLive, "result", %{
               "t" => "#{open.id}",
               "board" => "3",
               "result" => "1-0"
             })

      assert allowed?.(AlnaslWeb.RoundLive, "result", %{
               "t" => "#{open.id}",
               "board" => "11",
               "result" => "1-0"
             })

      refute allowed?.(AlnaslWeb.RoundLive, "new_game", %{"t" => "#{open.id}", "board" => "3"})

      # The annex's own tournament is the annex's to run.
      assert allowed?.(AlnaslWeb.RoundLive, "next_round", %{"t" => "#{blitz.id}"})

      # Standing in the main hall, the annex's tournament does not take its tables.
      refute allowed?.(AlnaslWeb.SetupLive, "assign_tables", %{
               "tables" => %{"id" => "#{blitz.id}", "from" => "1", "to" => "8"}
             })

      refute allowed?.(AlnaslWeb.SetupLive, "seat_tables", %{
               "seat" => %{"id" => "#{blitz.id}", "from" => "1", "to" => "8"}
             })

      # Standing in the annex, it does.
      in_b = scope(%{a.id => "viewer", b.id => "arbiter"}, b)

      assert AlnaslWeb.Permit.allowed?(
               in_b,
               AlnaslWeb.SetupLive,
               "assign_tables",
               %{
                 "tables" => %{"id" => "#{blitz.id}", "from" => "1", "to" => "8"}
               },
               %{}
             )
    end

    test "PGN: a game for board N needs the role where board N is played", %{
      a: a,
      b: b,
      open: open
    } do
      {:ok, _, _} = Placements.add(open, b.id)
      # An arbiter of the annex, a viewer in the main hall, standing in the annex.
      account = scope(%{a.id => "viewer", b.id => "arbiter"}, b)
      pgn = AlnaslWeb.PgnLive
      page = %{tid: open.id, stored: [], games: [], targets: %{1 => 3, 2 => 11}, confirm: nil}
      allowed? = &AlnaslWeb.Permit.allowed?(account, pgn, &1, &2, Map.merge(page, &3))

      # Board 3 is the main hall's, board 11 the annex's.
      refute allowed?.("attach", %{}, %{confirm: {1, 3, nil}})
      assert allowed?.("attach", %{}, %{confirm: {2, 11, nil}})

      refute allowed?.("ask_attach", %{"index" => "1"}, %{})
      assert allowed?.("ask_attach", %{"index" => "2"}, %{})

      refute allowed?.("simulate", %{"index" => "1"}, %{})
      assert allowed?.("simulate", %{"index" => "2"}, %{})

      # Without a board chosen a simulator takes the next free number, 1:
      # the main hall's, and so is the run "Play them all" would take.
      refute allowed?.("simulate", %{"index" => "3"}, %{})
      refute allowed?.("simulate_all", %{}, %{games: [{:game, 1}, {:game, 2}]})

      # An arbiter of the main hall may do it there.
      main = scope(%{a.id => "arbiter"}, a)
      assert AlnaslWeb.Permit.allowed?(main, pgn, "attach", %{}, %{page | confirm: {1, 3, nil}})
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

  describe "what adding, merging and deleting leave behind" do
    setup do
      a = Halls.own()
      b = hall("Annex")
      open = tournament("Open", a.id)
      {:ok, _} = Tournaments.assign_tables(open, 1, 8, a.id)
      %{a: a, b: b, open: Tournaments.get!(open.id)}
    end

    test "a hall added does not land on a table where another tournament is playing", %{
      b: b,
      open: open
    } do
      # The annex plays the U12 on every table, no range: table 1 has a game on.
      u12 = tournament("U12", b.id, 4)
      busy = board(b.id, "busy")

      {:ok, busy} =
        Boards.update(busy, %{table_no: 1, tournament_id: u12.id, round: 1, board_no: 1})

      game = Alnasl.Games.ensure(u12.id, 1, 1, %{})
      moves = for san <- ~w(e4 e5 Nf3), do: %{san: san, flags: [], clock: nil}
      {_game, _} = Alnasl.Games.apply_event(game, {:moves, moves}, 1_000)

      # The suggestion starts after the U12's tables...
      assert %{table_from: 2} = Placements.suggest(open, b.id)

      # ...and asking for its table anyway is refused, in so many words.
      assert {:error, :busy, %{id: id}} =
               Placements.add(open, b.id, %{table_from: 1, table_to: 8})

      assert id == busy.id
      assert Placements.in_hall(open, b.id) == nil
      assert %{tournament_id: tid, board_no: 1} = Boards.get!(busy.id)
      assert tid == u12.id
      assert AlnaslWeb.TableWords.busy(Boards.get!(busy.id)) =~ "U12"
    end

    test "a hall whose own tournament is played next door is not deleted from under it", %{
      a: a,
      b: b
    } do
      local = Halls.local_tournament(b)
      assert Halls.leftovers(b).tournaments == 0

      {:ok, _, _} = Placements.add(local, a.id, %{table_from: 20, table_to: 21})
      assert Halls.leftovers(b).tournaments == 1

      owner = scope(%{b.id => "owner"}, b)
      assert {:error, {:not_empty, _}} = Halls.delete(owner, b)
    end

    test "a hall that moves over in a merge plays its new boards at once", %{b: b, open: open} do
      link =
        Repo.insert!(%Alnasl.Tournaments.Link{
          root: "http://annex.example/api/boards/v1",
          secret: "s",
          kind: "tournament",
          hall_id: b.id
        })

      # The annex's own row of the Open, counted from board 1 on its tables 1-8.
      later = tournament("Open", b.id)
      later = later |> Ecto.Changeset.change(link_id: link.id) |> Repo.update!()
      {:ok, _} = Tournaments.assign_tables(later, 1, 8, b.id)

      there = board(b.id, "there")
      {:ok, _} = Tables.set_table(there, 2)
      assert %{board_no: 2} = Boards.get!(there.id)

      :ok = Alnasl.OpenPairings.Duplicates.merge(Tournaments.get!(later.id), open)

      # Boards 1-8 are the main hall's: the annex's table 2 is board 10 now.
      assert %{first_board: 9} = Placements.in_hall(open, b.id)
      assert %{tournament_id: tid, round: 1, board_no: 10} = Boards.get!(there.id)
      assert tid == open.id
      assert Tables.home_board(Boards.get!(there.id)) == 10
    end
  end
end
