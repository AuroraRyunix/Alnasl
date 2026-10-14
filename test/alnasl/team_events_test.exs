defmodule Alnasl.TeamEventsTest do
  @moduledoc """
  A team event from the pairing program: boards that know their match, a
  hall whose tables keep a match together, the "ready or not" list that
  speaks of matches, the PGN tags of a team game, and what each place the
  games go to is sent for one.
  """

  use Alnasl.HallCase

  import Alnasl.LinkHelpers

  alias Alnasl.{FakeOpenPairings, Games, Tables, Tournaments}
  alias Alnasl.Destination.{LichessBroadcast, OpenPairings, OpenResults}

  # Four teams, four boards a match: two matches, boards 1-8 of the round.
  setup do
    pairing_program()
    FakeOpenPairings.add_team_tournament(40, name: "Interclub")
    {:ok, _link, _found} = Alnasl.OpenPairings.add_code(FakeOpenPairings.code(40))
    {:ok, event: by_remote(40)}
  end

  defp game(tournament, board, round \\ 1) do
    pairing = Tournaments.board(tournament.id, round, board)
    Games.ensure(tournament.id, round, board, Games.pairing_attrs(pairing))
  end

  defp play(game, sans) do
    Enum.reduce(sans, game, fn san, game ->
      {game, _replace?} =
        Games.apply_event(game, {:moves, [%{san: san, flags: []}]}, 1_791_700_000_000)

      Alnasl.Outbox.enqueue(game, nil, false)
    end)
  end

  describe "the pairings" do
    test "each board knows its match, its place in it and the two players' teams", %{event: event} do
      assert Tournaments.team_event?(event)
      assert Tournaments.boards_per_match(event) == 4

      boards = Tournaments.boards(event.id, 1)
      assert length(boards) == 8

      sixth = Enum.find(boards, &(&1.board == 6))
      assert sixth.match == %{number: 2, board: 2, team_a: "Team 3", team_b: "Team 4"}
      # Team A has White on the odd boards of a match: board 2 is Team B's.
      assert {sixth.white_team, sixth.black_team} == {"Team 4", "Team 3"}

      refute Tournaments.team_event?(Tournaments.default())
      assert Tournaments.boards(Tournaments.default().id, 1) |> Enum.all?(&(&1.match == nil))
    end
  end

  describe "tables" do
    # The pairing program numbered the round the other way round: match 2 is
    # boards 1-4, match 1 boards 5-8. The tables follow the matches.
    defp renumbered do
      FakeOpenPairings.boards(40, 1, fn boards ->
        Enum.map(boards, fn b ->
          board = if b["match"]["number"] == 1, do: b["board"] + 4, else: b["board"] - 4
          %{b | "board" => board, "label" => to_string(board)}
        end)
      end)

      poll()
    end

    test "keeping each match together counts the tables match by match", %{event: event} do
      renumbered()
      {:ok, event} = Tournaments.assign_tables(Tournaments.get!(event.id), 1, 8)
      assert event.keep_matches

      # Table 1 is board 1 of match 1, which the round calls board 5.
      assert Tournaments.board_of_table(event, 1) == 5
      assert Tournaments.board_of_table(event, 4) == 8
      assert Tournaments.board_of_table(event, 5) == 1
      # A place beyond the matches stands for the number it would have.
      assert Tournaments.board_of_table(event, 9) == 9

      plain = Tournaments.update!(event, %{keep_matches: false})
      assert Tournaments.board_of_table(plain, 1) == 1
    end

    test "numbering the boards by touching gives each table its place in a match", %{
      event: event
    } do
      renumbered()
      {:ok, _} = Tournaments.assign_tables(Tournaments.get!(event.id), 1, 8)

      # What the Finder does as the arbiter lifts a piece on table after table.
      boards =
        for n <- 1..6 do
          board = fake_dgt("TEAM#{n}")
          {:ok, board} = Tables.set_table(board, n)
          Boards.get!(board.id)
        end

      assert Enum.map(boards, &{&1.tournament_id, &1.board_no}) ==
               [{event.id, 5}, {event.id, 6}, {event.id, 7}, {event.id, 8}] ++
                 [{event.id, 1}, {event.id, 2}]

      # Table 6 plays board 2 of match 2: its names are that board's.
      sixth = List.last(boards)
      eventually(fn -> Boards.snapshot(sixth.id).white == "Interclub T4 P2" end)
    end

    test "a new round keeps the matches on their tables", %{event: event} do
      {:ok, _} = Tournaments.assign_tables(Tournaments.get!(event.id), 1, 8)

      board = fake_dgt("TEAM5")
      {:ok, board} = Tables.set_table(board, 5)
      assert Boards.get!(board.id).board_no == 5

      FakeOpenPairings.pair_teams(40, 2)
      # Round 2 numbers match 1 as boards 5-8.
      FakeOpenPairings.boards(40, 2, fn boards ->
        Enum.map(boards, fn b ->
          board = if b["match"]["number"] == 1, do: b["board"] + 4, else: b["board"] - 4
          %{b | "board" => board}
        end)
      end)

      poll()
      board = Boards.get!(board.id)
      # Table 5 is board 1 of match 2, which round 2 calls board 1.
      assert {board.round, board.board_no} == {2, 1}
    end

    test "the ready list names a missing board by its match, and a match followed in part", %{
      event: event
    } do
      {:ok, _} = Tournaments.assign_tables(Tournaments.get!(event.id), 1, 8)

      for n <- [1, 2, 4, 5] do
        board = fake_dgt("TEAM#{n}")
        {:ok, _} = Tables.set_table(board, n)
      end

      whats = event.id |> Tables.checks(1) |> Enum.map(& &1.what)

      assert {:gap_match, 3, 1, 3} in whats
      refute Enum.any?(whats, &match?({:gap, _}, &1))
      assert {:part_match, 1, 3, 4} in whats
      assert {:part_match, 2, 1, 4} in whats

      assert AlnaslWeb.TableWords.check(%{level: :warn, what: {:gap_match, 3, 1, 3}})
             |> elem(1) =~ "match 1, board 3"
    end
  end

  describe "a team game going out" do
    test "its PGN carries the teams, and Round is round and board", %{event: event} do
      game = event |> game(6) |> play(~w(d4 d5))
      pgn = Games.pgn(game)

      assert pgn =~ ~s([Round "1.6"])
      assert pgn =~ ~s([Board "6"])
      assert pgn =~ ~s([WhiteTeam "Team 4"])
      assert pgn =~ ~s([BlackTeam "Team 3"])

      lichess = LichessBroadcast.pgn(game)
      assert lichess =~ ~s([WhiteTeam "Team 4"]) and lichess =~ ~s([Round "1.6"])
    end

    test "an individual tournament's PGN is as it was", %{event: _event} do
      open = linked(17, name: "Open", boards: 2)
      pgn = open |> game(1) |> play(~w(e4)) |> Games.pgn()
      assert pgn =~ ~s([Round "1"])
      refute pgn =~ "Team"
    end

    test "the pairing program gets it by its game id, the results site by round and board", %{
      event: event
    } do
      game = event |> game(6) |> play(~w(d4 d5))

      assert {:empty, 1} = OpenPairings.deliver()

      assert %{"white" => 40_014, "black" => 40_010, "moves" => ["d4", "d5"]} =
               FakeOpenPairings.game(40, "g40r1m2b2")

      assert FakeOpenPairings.game(40, "g40r1m2b2")["pgn"] =~ ~s([WhiteTeam "Team 4"])

      # The results site keys a live game by the round and the board as it
      # numbers them, through the round: board 6, not "match 2, board 2".
      entry = Enum.find(Alnasl.Outbox.list("pending"), &(&1.game_id == game.id))
      assert entry.tournament_id == event.id
      assert %{"round" => 1, "board" => 6} = Jason.decode!(entry.body)
      refute Jason.decode!(entry.body) |> Map.has_key?("match")
      assert game.board_no == 6
      assert OpenResults.id() == "openresults"
    end
  end
end
