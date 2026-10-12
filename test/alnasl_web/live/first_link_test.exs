defmodule AlnaslWeb.FirstLinkTest do
  @moduledoc """
  The first minutes after a connect code: the boards are put in the
  tournament (or the one question is asked), a board outside is said so,
  the statuses are about the tournament in use, "Send now" answers, and the
  bar shows the connection to the box and where the data is kept.
  """

  use AlnaslWeb.SiteCase

  import Alnasl.LinkHelpers

  alias Alnasl.{Destination, FakeOpenPairings, Seating, Tables, Tournaments}
  alias Alnasl.Destination.{LichessBroadcast, OpenPairings, OpenResults}

  setup do
    pairing_program()
  end

  defp add(view, code),
    do: view |> form("#code-form", link: %{code: code}) |> render_submit()

  # A board in the box's own tournament with a table number.
  defp numbered(n) do
    board = fake_dgt("FAKE#{n}")
    {:ok, board} = Tables.set_table(board, n)
    board
  end

  # ... and a game under way on it.
  defp playing(board, sans \\ ~w(e4 e5 Nf3)) do
    own = own()
    game = Games.ensure(own.id, 1, board.board_no, %{})
    moves = for san <- sans, do: %{san: san, flags: [], clock: nil}
    {game, _} = Games.apply_event(game, {:moves, moves}, 1_000)
    Boards.refresh_games(own.id)
    game
  end

  defp one_tournament(opts \\ []) do
    FakeOpenPairings.add_tournament(17, Keyword.merge([boards: 3, name: "Open"], opts))
    FakeOpenPairings.code(17)
  end

  describe "after a code" do
    test "one tournament, an unused own tournament: every board plays there, said and undoable",
         %{conn: conn} do
      a = numbered(1)
      b = numbered(2)
      code = one_tournament()

      {:ok, view, _html} = live(conn, ~p"/setup")
      html = add(view, code)
      assert html =~ "now play in Open"

      open = by_remote(17)
      assert Boards.get!(a.id).tournament_id == open.id
      assert Boards.get!(b.id).tournament_id == open.id
      assert {Boards.get!(a.id).round, Boards.get!(a.id).board_no} == {1, 1}
      assert {open.table_from, open.table_to} == {1, 2}
      assert Seating.outside() == []

      assert has_element?(view, "#auto-notice", "All 2 boards now play in Open")

      view |> element("#auto-undo") |> render_click()
      refute has_element?(view, "#auto-notice")
      assert Boards.get!(a.id).tournament_id == own().id
      assert again(open).table_from == nil
    end

    test "a board without a table number gets the next free one", %{conn: conn} do
      board = fake_dgt("FAKE9")
      code = one_tournament()
      {:ok, view, _html} = live(conn, ~p"/setup")
      add(view, code)

      board = Boards.get!(board.id)
      assert board.tournament_id == by_remote(17).id
      assert board.table_no == 1 and board.board_no == 1
    end

    test "a group: the question is asked right there, with ranges filled in", %{conn: conn} do
      for n <- 1..4, do: numbered(n)

      FakeOpenPairings.add_tournament(17,
        group: "Festival",
        label: "Open",
        name: "Open",
        boards: 2
      )

      FakeOpenPairings.add_tournament(18, group: "Festival", label: "U12", name: "U12", boards: 2)

      {:ok, view, _html} = live(conn, ~p"/setup")
      html = add(view, FakeOpenPairings.group_code("Festival"))
      assert html =~ "Say below which tables play in which"

      open = by_remote(17)
      u12 = by_remote(18)
      assert has_element?(view, "#seat-ask", "Which tables play in Open, U12?")
      assert has_element?(view, "#seat-from-#{open.id}[value='1']")
      assert has_element?(view, "#seat-to-#{open.id}[value='2']")
      assert has_element?(view, "#seat-from-#{u12.id}[value='3']")
      assert has_element?(view, "#seat-to-#{u12.id}[value='4']")
      # Nothing was decided for him.
      assert Enum.all?(Boards.list(), &(&1.tournament_id == own().id))

      view
      |> form("#seat-form-#{open.id}", seat: %{id: open.id, from: "1", to: "2"})
      |> render_submit()

      view
      |> form("#seat-form-#{u12.id}", seat: %{id: u12.id, from: "3", to: "4"})
      |> render_submit()

      assert Enum.count(Boards.list(), &(&1.tournament_id == open.id)) == 2
      assert Enum.count(Boards.list(), &(&1.tournament_id == u12.id)) == 2
      refute has_element?(view, "#seat-ask")
    end

    test "a tournament with no boards on this box can be left alone", %{conn: conn} do
      for n <- 1..2, do: numbered(n)
      FakeOpenPairings.add_tournament(17, group: "F", boards: 1)
      FakeOpenPairings.add_tournament(18, group: "F", boards: 1)
      {:ok, view, _html} = live(conn, ~p"/setup")
      add(view, FakeOpenPairings.group_code("F"))
      u = by_remote(18)

      view |> element("#seat-decline-#{u.id}") |> render_click()
      refute has_element?(view, "#seat-form-#{u.id}")
      assert has_element?(view, "#seat-form-#{by_remote(17).id}")
    end

    test "a game under way keeps the board in the question, and goes with it as the pairing's game",
         %{conn: conn} do
      board = numbered(1)
      playing(board)
      code = one_tournament()

      {:ok, view, _html} = live(conn, ~p"/setup")
      add(view, code)
      open = by_remote(17)

      # Not decided by itself: the question is asked.
      assert has_element?(view, "#seat-ask")
      assert Boards.get!(board.id).tournament_id == own().id

      html =
        view
        |> form("#seat-form-#{open.id}", seat: %{id: open.id, from: "1", to: "1"})
        |> render_submit()

      assert html =~ "The game under way (3 moves) is board 1 of round 1 there now"

      game = Games.current(open.id, 1, 1)
      assert Games.sans(game) == ~w(e4 e5 Nf3)
      assert game.remote_game == "g17r1b1s0"
      assert game.white =~ "Open Player 1"
      assert Games.current(own().id, 1, 1) == nil

      # And it is owed to OpenPairings, in full.
      assert OpenPairings.pending_count() == 1
      assert {:empty, 1} = OpenPairings.deliver()
      assert FakeOpenPairings.game(17, "g17r1b1s0")["moves"] == ~w(e4 e5 Nf3)
    end
  end

  describe "a board outside" do
    setup %{conn: conn} do
      code = one_tournament()
      {:ok, _link, _} = Alnasl.OpenPairings.add_code(code)
      open = by_remote(17)
      # A board put in the box's own tournament by hand, after the code.
      {:ok, board} =
        Boards.create(%{
          name: "Stray",
          driver: "simulator",
          port: "sim-1",
          options: %{},
          tournament_id: own().id
        })

      {:ok, board} = Tables.set_table(board, 1)
      %{open: open, board: board, conn: conn}
    end

    test "is said in words on every page, with one tap to put it right", %{
      conn: conn,
      open: open,
      board: board
    } do
      {:ok, view, _html} = live(conn, ~p"/outbox")
      assert has_element?(view, "#outside-#{board.id}", "Stray is not playing in Open")

      view |> element("#put-#{board.id}-#{open.id}") |> render_click()
      refute has_element?(view, "#outside-banner")
      moved = Boards.get!(board.id)
      assert {moved.tournament_id, moved.round, moved.board_no} == {open.id, 1, 1}
    end

    test "the Boards page, the Round tile and 'Ready for round N?' say it too", %{
      conn: conn,
      board: board
    } do
      {:ok, view, _html} = live(conn, ~p"/boards")
      assert has_element?(view, "#board-outside-#{board.id}", "not playing in Open")
      assert has_element?(view, "#checks-not-ready")
      assert has_element?(view, "#checks-list", "not playing in Open")

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "[id^='tile-outside-']", "Not playing in Open")
    end

    test "a game under way: the moves are offered as the pairing's, or the board starts fresh", %{
      conn: conn,
      open: open,
      board: board
    } do
      playing(board)
      {:ok, view, _html} = live(conn, ~p"/boards")

      assert has_element?(
               view,
               "#put-#{board.id}-#{open.id}",
               "these moves are board 1 of round 1"
             )

      assert has_element?(view, "#put-fresh-#{board.id}-#{open.id}")

      html = view |> element("#put-#{board.id}-#{open.id}") |> render_click()
      assert html =~ "is board 1 of round 1 there now"
      assert Games.sans(Games.current(open.id, 1, 1)) == ~w(e4 e5 Nf3)
    end

    test "start fresh: the game is closed without a result and kept where it was", %{
      conn: conn,
      open: open,
      board: board
    } do
      playing(board)
      {:ok, view, _html} = live(conn, ~p"/boards")

      html = view |> element("#row-put-fresh-#{board.id}-#{open.id}") |> render_click()
      assert html =~ "closed without a result"

      old = Games.current(own().id, 1, 1)
      assert old.status == "finished" and old.result == "*"
      assert Games.sans(old) == ~w(e4 e5 Nf3)
      refute Games.begun?(Games.current(open.id, 1, 1))
    end

    test "a board added later joins the only linked tournament while the own one is unused", %{
      open: open
    } do
      {:ok, board} =
        Boards.create(%{name: "Later", driver: "simulator", port: "sim-2", options: %{}})

      assert board.tournament_id == open.id
    end
  end

  describe "a board added later" do
    test "stays in the box's own tournament when that has been used" do
      one = one_tournament()
      {:ok, _link, _} = Alnasl.OpenPairings.add_code(one)
      board = numbered(1)
      playing(board)

      {:ok, later} =
        Boards.create(%{name: "Later", driver: "simulator", port: "sim-2", options: %{}})

      assert later.tournament_id == own().id
    end
  end

  describe "the statuses" do
    test "are about the tournament in use: no 'Not set up' for the unused own one", %{conn: conn} do
      one = one_tournament()
      {:ok, _link, _} = Alnasl.OpenPairings.add_code(one)
      # The own tournament has no results page either.
      own_put(server_url: "", slug: "", relay_key: "")

      {:ok, view, _html} = live(conn, ~p"/outbox")
      assert has_element?(view, "#head-pairing", "OpenPairings: connected")
      assert has_element?(view, "#head-results", "Results site: ready")
      refute has_element?(view, "#link-state", "Not set up")
      refute has_element?(view, "#link-panel", "Not set up")
      assert has_element?(view, "#linked-link-state-#{hd(Tournaments.links()).id}", "Connected")
      assert has_element?(view, "#linked-results-#{by_remote(17).id}", "Results site")
    end

    test "no relay key: a warning with the action spelled out, cleared when the key arrives", %{
      conn: conn
    } do
      FakeOpenPairings.add_tournament(17, boards: 2, name: "Open")
      FakeOpenPairings.update(17, fn t -> put_in(t.openresults["relay_key"], nil) end)
      {:ok, _link, _} = Alnasl.OpenPairings.add_code(FakeOpenPairings.code(17))
      open = by_remote(17)
      assert open.relay_key == ""

      {:ok, setup, _} = live(conn, ~p"/setup")

      assert has_element?(
               setup,
               "#tournament-nokey-#{open.id}",
               "In OpenPairings: Settings > Live boards > The results site"
             )

      assert has_element?(setup, "#head-results", "Results site: no relay key yet")
      {:ok, outbox, _} = live(conn, ~p"/outbox")
      assert has_element?(outbox, "#linked-results-line-#{open.id}", "No relay key yet")
      refute has_element?(outbox, "#link-panel", "Not set up")

      # OpenPairings saves a key: the box takes it at its next poll.
      FakeOpenPairings.update(17, fn t -> put_in(t.openresults["relay_key"], "orrk_fake_new") end)
      poll()
      assert again(open).relay_key == "orrk_fake_new"
      refute has_element?(setup, "#tournament-nokey-#{open.id}")
      assert has_element?(setup, "#head-results", "Results site: ")
      refute has_element?(setup, "#head-results", "no relay key")

      # And a key that is rotated replaces the stored one.
      FakeOpenPairings.update(17, fn t -> put_in(t.openresults["relay_key"], "orrk_fake_rot") end)
      poll()
      assert again(open).relay_key == "orrk_fake_rot"
    end

    test "a game recorded before the key arrived is queued in full once it can go" do
      FakeOpenPairings.add_tournament(17, boards: 2, name: "Open")
      FakeOpenPairings.update(17, fn t -> put_in(t.openresults["relay_key"], nil) end)
      board = numbered(1)
      playing(board)
      {:ok, _link, found} = Alnasl.OpenPairings.add_code(FakeOpenPairings.code(17))
      open = by_remote(17)
      assert Seating.after_code(found) |> elem(0) == :ask
      {:ok, _open, [%{outcome: :adopted}]} = Seating.assign_range(open, 1, 1)

      assert Alnasl.Outbox.pending_by_tournament() == %{}

      FakeOpenPairings.update(17, fn t -> put_in(t.openresults["relay_key"], "orrk_fake_new") end)
      poll()

      assert Alnasl.Outbox.pending_by_tournament() == %{open.id => 1}
      assert [entry] = Alnasl.Outbox.list("pending")
      assert entry.replace and entry.plies == 3
    end
  end

  describe "Send now" do
    test "answers truthfully when there is nothing to do, and says why beside a disabled button",
         %{conn: conn} do
      one = one_tournament(openresults: nil)
      {:ok, _link, _} = Alnasl.OpenPairings.add_code(one)
      own_put(server_url: "", slug: "", relay_key: "", lichess_round_id: nil, lichess_token: nil)

      {:ok, view, _html} = live(conn, ~p"/outbox")

      assert has_element?(view, "#dest-send-openpairings[disabled]")
      assert has_element?(view, "#dest-send-why-openpairings", "Nothing is waiting")
      assert has_element?(view, "#dest-send-lichess[disabled]")
      assert has_element?(view, "#dest-send-why-lichess", "Stays off until a round and a token")
      assert has_element?(view, "#dest-send-openresults[disabled]")
      assert has_element?(view, "#send-now[disabled]")
      assert has_element?(view, "#auto-note", "Sending is automatic")

      # Pressed anyway (a stale page), each answers in words.
      assert render_click(view, "dest_send", %{"id" => "openpairings"}) =~ "Nothing is waiting"
      assert render_click(view, "dest_send", %{"id" => "lichess"}) =~ "Stays off until"
      assert render_click(view, "send_now", %{}) =~ "Nothing to send."
    end

    test "no relay key: the reason names the tournament and where to fix it", %{conn: conn} do
      FakeOpenPairings.add_tournament(17, boards: 2, name: "Open")
      FakeOpenPairings.update(17, fn t -> put_in(t.openresults["relay_key"], nil) end)
      {:ok, _link, _} = Alnasl.OpenPairings.add_code(FakeOpenPairings.code(17))
      own_put(server_url: "", slug: "", relay_key: "")

      {:ok, view, _html} = live(conn, ~p"/outbox")
      assert has_element?(view, "#dest-send-openresults[disabled]")

      assert has_element?(
               view,
               "#dest-send-why-openresults",
               "OpenPairings has no relay key for Tournament 17"
             ) or
               has_element?(view, "#dest-send-why-openresults", "no relay key")
    end

    test "a board outside: OpenPairings says that is why nothing is reported", %{conn: conn} do
      {:ok, _link, _} = Alnasl.OpenPairings.add_code(one_tournament())
      own_put(server_url: "", slug: "", relay_key: "")

      {:ok, board} =
        Boards.create(%{
          name: "Stray",
          driver: "simulator",
          port: "sim-1",
          options: %{},
          tournament_id: own().id
        })

      assert board.tournament_id == own().id
      {:ok, view, _html} = live(conn, ~p"/outbox")

      assert has_element?(
               view,
               "#dest-send-why-openpairings",
               "not playing in a linked tournament"
             )
    end

    test "something waiting: the press says how much, and then what went", %{conn: conn} do
      FakeOpenPairings.add_tournament(17, boards: 2, name: "Open")
      board = numbered(1)
      playing(board)
      {:ok, _link, found} = Alnasl.OpenPairings.add_code(FakeOpenPairings.code(17))
      open = by_remote(17)
      assert {:ask, _} = Seating.after_code(found)
      {:ok, _, _} = Seating.assign_range(open, 1, 1)

      {:ok, view, _html} = live(conn, ~p"/outbox")
      assert has_element?(view, "#dest-waiting-openpairings", "1 waiting")
      refute has_element?(view, "#dest-send-openpairings[disabled]")

      html = view |> element("#dest-send-openpairings") |> render_click()
      assert html =~ "OpenPairings: 1 waiting, trying now."

      # (No sender runs in the tests: the batch is delivered by hand.)
      assert {:empty, 1} = OpenPairings.deliver()
      send(view.pid, {:report, "openpairings", 1})
      assert render(view) =~ "OpenPairings: 1 sent. Nothing is waiting now."
    end

    test "still waiting: the report says how much went and how much is left", %{conn: conn} do
      FakeOpenPairings.add_tournament(17, boards: 2, name: "Open")
      board = numbered(1)
      playing(board)
      {:ok, _link, found} = Alnasl.OpenPairings.add_code(FakeOpenPairings.code(17))
      open = by_remote(17)
      assert {:ask, _} = Seating.after_code(found)
      {:ok, _, _} = Seating.assign_range(open, 1, 1)

      {:ok, view, _html} = live(conn, ~p"/outbox")
      view |> element("#dest-send-openpairings") |> render_click()
      send(view.pid, {:report, "openpairings", 1})
      assert render(view) =~ "OpenPairings: 0 sent, 1 still waiting."
    end
  end

  describe "sending is on by itself" do
    test "the defaults: results site and OpenPairings on, Lichess off" do
      assert Destination.enabled?(OpenResults)
      assert Destination.enabled?(OpenPairings)
      refute Destination.enabled?(LichessBroadcast)
    end

    test "linking a tournament changes none of them, and an explicit off stays" do
      Destination.set_enabled(OpenResults, false)
      {:ok, _link, _} = Alnasl.OpenPairings.add_code(one_tournament())
      refute Destination.enabled?(OpenResults)
      assert Destination.enabled?(OpenPairings)
      refute Destination.enabled?(LichessBroadcast)
    end

    test "a box with settings from before is on unless something was switched off" do
      Alnasl.Settings.put("box_name", "Hall A")
      Alnasl.Settings.put("locale", "nl")
      assert Destination.enabled?(OpenResults) and Destination.enabled?(OpenPairings)
      Alnasl.Settings.put(Destination.enabled_key(OpenPairings), false)
      refute Destination.enabled?(OpenPairings)
    end
  end

  describe "the bar and Setup" do
    test "'Live · N ms' is in the bar and the box answers its question", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ ~s(id="live-pill")
      assert has_element?(view, "#live-pill[phx-hook='LivePill']")
      assert render_hook(view, "live_ping", %{}) =~ "live-pill"
    end

    test "'This copy of Alnasl' says the version, how it was started, and where the data is",
         %{conn: conn} do
      numbered(1)
      {:ok, view, _html} = live(conn, ~p"/setup")
      assert has_element?(view, "#about-version", Alnasl.Updates.current_version())
      assert has_element?(view, "#about-kind", "From source")
      assert has_element?(view, "#about-data", Path.expand(Alnasl.Paths.data()))
      assert has_element?(view, "#about-counts", "1 board")
      assert has_element?(view, "#about-note", "has a data folder of its own")
    end
  end
end
