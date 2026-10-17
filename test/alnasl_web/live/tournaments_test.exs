defmodule AlnaslWeb.TournamentsTest do
  @moduledoc """
  The link with OpenPairings and several tournaments on one box, as the
  arbiter meets them: the Tournaments section of Setup, the Round page with
  a tournament under the other, the board whose pairing changed, the
  Boards page, the Outbox.
  """

  use AlnaslWeb.SiteCase

  import Alnasl.LinkHelpers

  alias Alnasl.{FakeOpenPairings, OpenPairings, Tables, Tournaments}
  alias Alnasl.Tournaments.Link

  setup do
    pairing_program()
  end

  defp festival do
    FakeOpenPairings.add_tournament(17, group: "Festival", label: "Open", name: "Open", boards: 3)

    FakeOpenPairings.add_tournament(18,
      group: "Festival",
      label: "U12",
      name: "U12",
      boards: 2,
      openresults: nil
    )

    FakeOpenPairings.group_code("Festival")
  end

  defp add(view, code),
    do: view |> form("#code-form", link: %{code: code}) |> render_submit()

  # Two boards per tournament, on tables 1-2 and 3-4.
  defp hall do
    {:ok, _link, _} = OpenPairings.add_code(festival())
    open = by_remote(17)
    u12 = by_remote(18)

    boards =
      for n <- 1..4 do
        board = fake_dgt("FAKE#{n}")
        {:ok, board} = Tables.set_table(board, n)
        board
      end

    {:ok, _} = Tournaments.assign_tables(open, 1, 2)
    {:ok, _} = Tournaments.assign_tables(u12, 3, 4)
    %{open: again(open), u12: again(u12), boards: Enum.map(boards, &Boards.get!(&1.id))}
  end

  describe "Setup: tournaments" do
    test "a connect code is pasted once: its tournaments appear with what came with them", %{
      conn: conn
    } do
      code = festival()
      {:ok, view, html} = live(conn, ~p"/setup/tournaments")
      assert has_element?(view, "#setup-tournaments")
      # Before any code there is the box's own tournament, and that is all.
      assert has_element?(view, "#tournament-#{own().id}")
      assert html =~ "No pairing program"

      render_patch(view, ~p"/setup/connections")
      assert has_element?(view, "#setup-connections") and has_element?(view, "#code-form")
      html = add(view, code)
      assert html =~ "The code is accepted: 2 tournament(s)"

      # The code is a secret: it is not on the page, in the field or out of it.
      refute html =~ FakeOpenPairings.secret(code)
      link = Repo.one!(Link)
      assert has_element?(view, "#link-#{link.id}", "Festival")
      assert has_element?(view, "#link-state-#{link.id}", "Connected")
      assert has_element?(view, "#link-line-#{link.id}", "0.0.0-fake")

      open = by_remote(17)
      u12 = by_remote(18)
      render_patch(view, ~p"/setup/tournaments?open=#{open.id}")
      render_patch(view, ~p"/setup/tournaments?open=#{u12.id}")
      assert has_element?(view, "#tournament-#{open.id}", "Open")
      assert has_element?(view, "#tournament-line-#{open.id}", "6 player(s)")
      assert has_element?(view, "#tournament-line-#{open.id}", "3 board(s) in round 1")
      assert has_element?(view, "#tournament-line-#{open.id}", "90min+30sec/move")

      # The results page came with the code; its key is a hint and no more.
      assert has_element?(view, "#tournament-results-#{open.id}", "slug-17")
      assert has_element?(view, "#tournament-results-#{open.id}", "It came with the code")
      refute render(view) =~ FakeOpenPairings.relay_key(17)

      assert has_element?(
               view,
               "#tournament-results-#{u12.id}",
               "Not published on a results site"
             )
    end

    test "what goes wrong is said in words: not a code, a wrong code, nobody home", %{conn: conn} do
      FakeOpenPairings.add_tournament(17)
      {:ok, view, _html} = live(conn, ~p"/setup/connections")

      assert add(view, "") =~ "Paste the connect code first"
      assert add(view, "https://pairings.test/api/boards/v1") =~ "the part after the # is missing"

      wrong = FakeOpenPairings.root() <> "#" <> "oplt" <> "_" <> String.duplicate("q", 30)
      html = add(view, wrong)
      assert html =~ "does not know this code" and html =~ "withdrawn"
      refute html =~ String.duplicate("q", 30)
      assert Repo.aggregate(Link, :count) == 0

      FakeOpenPairings.mode(:down)
      html = add(view, FakeOpenPairings.code(17))
      assert html =~ "The code is kept, but could not be checked"
      assert html =~ "Is OpenPairings running?"
      link = Repo.one!(Link)
      assert has_element?(view, "#link-state-#{link.id}", "No answer")
      assert has_element?(view, "#link-why-#{link.id}")
    end

    test "test connection tells a withdrawn code from a server that is not there, and says what is not published",
         %{conn: conn} do
      code = festival()
      {:ok, link, _} = OpenPairings.add_code(code)
      {:ok, view, _html} = live(conn, ~p"/setup/connections")
      test = fn -> view |> element("#test-link-#{link.id}") |> render_click() end

      test.()
      eventually_html(view, fn _ -> has_element?(view, "#link-test-#{link.id}") end)
      assert has_element?(view, "#link-check-#{link.id}-server .state.ok")
      assert has_element?(view, "#link-check-#{link.id}-code .state.ok")
      assert has_element?(view, "#link-check-#{link.id}-tournaments", "2 tournament(s)")

      assert has_element?(
               view,
               "#link-found-#{link.id}-0",
               "its results page and relay key came with it"
             )

      assert has_element?(view, "#link-found-#{link.id}-1", "not published on a results site")

      FakeOpenPairings.mode(:down)
      test.()

      html =
        eventually_html(view, fn _ ->
          has_element?(view, "#link-check-#{link.id}-server .state.bad")
        end)

      assert html =~ "OpenPairings cannot be reached" and html =~ "Not tested"

      FakeOpenPairings.mode(:ok)
      FakeOpenPairings.withdraw(code)
      test.()

      html =
        eventually_html(view, fn _ ->
          has_element?(view, "#link-check-#{link.id}-code .state.bad")
        end)

      assert html =~ "withdrawn"
      assert has_element?(view, "#link-check-#{link.id}-server .state.ok")
    end

    test "a refused code says so, can be tried again, and can be taken off the box", %{conn: conn} do
      FakeOpenPairings.add_tournament(17, name: "Open")
      code = FakeOpenPairings.code(17)
      {:ok, link, [tournament]} = OpenPairings.add_code(code)
      FakeOpenPairings.withdraw(code)
      poll()

      {:ok, view, _html} = live(conn, ~p"/setup/connections")
      assert has_element?(view, "#link-state-#{link.id}", "Code refused")
      assert has_element?(view, "#link-why-#{link.id}", "Alnasl has stopped asking")

      assert view |> element("#retry-link-#{link.id}") |> render_click() =~
               "refuses the connect code"

      view |> element("#remove-link-#{link.id}") |> render_click()
      refute has_element?(view, "#link-#{link.id}")
      render_patch(view, ~p"/setup/tournaments")
      refute has_element?(view, "#tournament-#{tournament.id}")
      assert has_element?(view, "#tournament-#{own().id}")
      assert Repo.aggregate(Link, :count) == 0
    end

    test "tables are given to a tournament as a range; rounds starting by themselves can be switched off",
         %{conn: conn} do
      {:ok, _link, _} = OpenPairings.add_code(festival())
      u12 = by_remote(18)
      board = fake_dgt("FAKE1")
      {:ok, _} = Tables.set_table(board, 5)

      {:ok, view, _html} = live(conn, ~p"/setup/tournaments?open=#{u12.id}")
      assert has_element?(view, "#tournament-boards-#{u12.id}", "0 board(s)")

      html =
        view
        |> form("#tables-form-#{u12.id}", tables: %{from: "5", to: "8"})
        |> render_submit()

      assert html =~ "Tables 5-8 play in U12: table 5 is its board 1"
      assert has_element?(view, "#tournament-boards-#{u12.id}", "1 board(s)")
      board = Boards.get!(board.id)
      assert {board.tournament_id, board.round, board.board_no} == {u12.id, 1, 1}

      assert view
             |> form("#tables-form-#{u12.id}", tables: %{from: "8", to: "5"})
             |> render_submit() =~ "Give the first and the last table"

      assert has_element?(view, "#auto-start-#{u12.id}[aria-pressed=true]")
      view |> element("#auto-start-#{u12.id}") |> render_click()
      assert has_element?(view, "#auto-start-#{u12.id}[aria-pressed=false]")
      refute again(u12).auto_start
      # The box's own tournament has no pairing program to start a round for it.
      refute has_element?(view, "#auto-start-#{own().id}")
    end

    test "a tournament that appears while the page is open is there without a reload", %{
      conn: conn
    } do
      FakeOpenPairings.add_tournament(17, group: "Festival", label: "Open")
      {:ok, _link, _} = OpenPairings.add_code(FakeOpenPairings.group_code("Festival"))
      {:ok, view, _html} = live(conn, ~p"/setup")

      FakeOpenPairings.add_tournament(18, group: "Festival", label: "U12")
      poll()

      eventually_html(view, fn _ ->
        has_element?(view, "#tournament-#{by_remote(18).id}", "U12")
      end)
    end

    test "each tournament has its own Lichess round", %{conn: conn} do
      {:ok, _link, _} = OpenPairings.add_code(festival())
      open = by_remote(17)
      {:ok, view, _html} = live(conn, ~p"/setup/results")

      view
      |> form("#lichess-tournament-form", %{tournament_id: to_string(open.id)})
      |> render_change()

      view
      |> form("#lichess-form",
        lichess: %{round: "AbCd1234", token: "lip" <> "_" <> "sometoken", round_no: "1"}
      )
      |> render_submit()

      assert %{lichess_round_id: "AbCd1234", lichess_round: 1} = again(open)
      assert own().lichess_round_id in [nil, ""]
      refute Tournaments.lichess_configured?(own())
    end
  end

  describe "Round: several tournaments" do
    test "each has its own part of the page, its own tiles, round and names", %{conn: conn} do
      %{open: open, u12: u12} = hall()
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#tournament-filter")
      assert has_element?(view, "#round-head-t#{open.id}", "Open")
      assert has_element?(view, "#round-head-t#{u12.id}", "U12")

      # Board 1 exists twice, and the tiles say whose it is.
      assert has_element?(view, "#tile-t#{open.id}-1") and
               has_element?(view, "#tile-t#{u12.id}-1")

      assert has_element?(view, "#tile-tournament-t#{open.id}-1", "Open")
      assert has_element?(view, "#tile-white-t#{open.id}-1", "IM Open Player 1")
      assert has_element?(view, "#tile-white-t#{open.id}-1 .rating", "2001")
      assert has_element?(view, "#tile-black-t#{u12.id}-2", "U12 Player 4")
      assert has_element?(view, "#round-tc-t#{open.id}", "90min+30sec/move")
      # The Open has three boards paired and two electronic boards: the third
      # pairing is counted, not drawn.
      refute has_element?(view, "#tile-t#{open.id}-3")
      assert has_element?(view, "#round-unplaced-t#{open.id}", "1 pairing without a board here")

      # "Ready for round N?" is asked of each.
      assert has_element?(view, "#round-ready-t#{open.id}")
      assert has_element?(view, "#round-ready-t#{u12.id}")

      # One tournament alone.
      view |> element("#filter-#{u12.id}") |> render_click()
      assert_patch(view, ~p"/t/#{u12.id}")
      assert has_element?(view, "#tile-t#{u12.id}-1")
      refute has_element?(view, "#tile-t#{open.id}-1")
      assert has_element?(view, "#filter-#{u12.id}[aria-current=true]")
    end

    test "a round paired in OpenPairings appears by itself, for that tournament only", %{
      conn: conn
    } do
      %{open: open, u12: u12, boards: [a, _b, c, _d]} = hall()
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#round-head-t#{open.id}", "Round 1")

      FakeOpenPairings.finish_round(17, 1)
      FakeOpenPairings.pair(17, 2, 2)
      poll()

      eventually_html(view, fn _ -> has_element?(view, "#round-head-t#{open.id}", "Round 2") end)
      assert has_element?(view, "#round-head-t#{u12.id}", "Round 1")
      assert Boards.get!(a.id).round == 2 and Boards.get!(c.id).round == 1
      assert has_element?(view, "#tile-white-t#{open.id}-1", "IM Open Player 1")
    end

    test "'Start round' is one tournament's, and stays there as the fallback", %{conn: conn} do
      %{open: open, u12: u12, boards: [a, _b, c, _d]} = hall()
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#next-round-t#{u12.id}") |> render_click()
      assert Boards.get!(c.id).round == 2 and Boards.get!(a.id).round == 1
      assert again(u12).round == 2 and again(open).round == 1

      # The pairing program is still on round 1: said, with the way back.
      assert has_element?(view, "#round-behind-t#{u12.id}", "OpenPairings is on round 1")
      view |> element("#follow-t#{u12.id}") |> render_click()
      assert Boards.get!(c.id).round == 1
      refute has_element?(view, "#round-behind-t#{u12.id}")
    end

    test "a result from the tile's menu goes to the right tournament's board 1", %{conn: conn} do
      %{open: open, u12: u12} = hall()
      eventually(fn -> Games.current(u12.id, 1, 1) end)
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#tile-result-t#{u12.id}-1-1-0") |> render_click()
      assert %{status: "finished", result: "1-0"} = Games.current(u12.id, 1, 1)
      assert %{status: "live"} = Games.current(open.id, 1, 1)
    end

    test "a tournament the pairing program no longer lists says so, and its boards stay", %{
      conn: conn
    } do
      %{u12: u12} = hall()
      FakeOpenPairings.update(18, &%{&1 | group: nil})
      poll()

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#round-gone-t#{u12.id}", "no longer lists this tournament")
      assert has_element?(view, "#tile-t#{u12.id}-1")
    end
  end

  describe "a pairing that changed under a game" do
    test "the tile says so, and the board's page asks what the game is", %{conn: conn} do
      %{open: open, boards: [a | _]} = hall()
      eventually(fn -> Boards.snapshot(a.id).status == :waiting_start end)
      play_on("FAKE1", a.id, ~w(e4 e5))

      FakeOpenPairings.boards(17, 1, fn [one | rest] ->
        [%{one | "white" => one["black"], "black" => one["white"]} | rest]
      end)

      poll()

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#tile-pairing-t#{open.id}-1", "Pairing changed")
      assert has_element?(view, "#round-flagged-t#{open.id}", "1 board(s)")
      # The names the game had are still on the tile.
      assert has_element?(view, "#tile-white-t#{open.id}-1", "IM Open Player 1")

      {:ok, game_view, html} = live(conn, ~p"/t/#{open.id}/round/1/board/1")
      assert has_element?(game_view, "#pairing-changed")
      assert html =~ "IM Open Player 1 - Open Player 2"
      assert html =~ "Open Player 2 - IM Open Player 1"

      html = game_view |> element("#pairing-adopt") |> render_click()
      assert html =~ "The moves stand"
      refute has_element?(game_view, "#pairing-changed")
      assert %{pairing_flag: nil, white: "Open Player 2"} = game = Games.current(open.id, 1, 1)
      assert Games.sans(game) == ~w(e4 e5)

      eventually_html(view, fn _ -> not has_element?(view, "#tile-pairing-t#{open.id}-1") end)
    end

    test "'set it aside' begins again on the board and keeps the old game below", %{conn: conn} do
      %{open: open, boards: [a | _]} = hall()
      eventually(fn -> Boards.snapshot(a.id).status == :waiting_start end)
      play_on("FAKE1", a.id, ~w(d4 d5))
      FakeOpenPairings.pair(17, 1, 3)
      poll()

      {:ok, view, html} = live(conn, ~p"/t/#{open.id}/round/1/board/1")
      assert html =~ "no longer has a game on this board" or has_element?(view, "#pairing-adopt")

      html = view |> element("#pairing-set-aside") |> render_click()
      assert html =~ "The game is set aside"
      refute has_element?(view, "#pairing-changed")
      assert has_element?(view, "#game-here-1") and has_element?(view, "#game-here-2")
      assert [%{local: true}, %{local: false, game_no: 2}] = Games.history(open.id, 1, 1)
    end
  end

  describe "the box's own tournament" do
    test "names are said by hand on the board's page, and are on the tile and in the PGN", %{
      conn: conn
    } do
      own_put(document: nil)
      fake_dgt("FAKE1", %{round: 1, board_no: 1})
      eventually(fn -> Games.get(1, 1) end)
      {:ok, view, _html} = live(conn, ~p"/round/1/board/1")
      assert has_element?(view, "#names-form")

      view
      |> form("#names-form", names: %{white: "Anna Example", black: "Bert Example"})
      |> render_submit()

      assert %{white: "Anna Example", black: "Bert Example"} = game = Games.get(1, 1)
      assert Games.pgn(game) =~ ~s([White "Anna Example"])
      assert %{white: "Anna Example"} = Tournaments.board(own().id, 1, 1)

      {:ok, round, _html} = live(conn, ~p"/")
      assert has_element?(round, "#tile-white-1", "Anna Example")
      # One tournament: no filter, no tournament on the tile, the old ids.
      refute has_element?(round, "#tournament-filter")
      refute has_element?(round, "#tile-tournament-1")
    end

    test "a linked tournament's names are not typed on the box", %{conn: conn} do
      %{open: open} = hall()
      eventually(fn -> Games.current(open.id, 1, 1) end)
      {:ok, view, _html} = live(conn, ~p"/t/#{open.id}/round/1/board/1")
      refute has_element?(view, "#names-form")
    end
  end

  describe "Boards and Outbox" do
    test "one board is put in a tournament by hand; the page is about one tournament at a time",
         %{
           conn: conn
         } do
      %{open: open, u12: u12, boards: [a | _]} = hall()
      {:ok, view, _html} = live(conn, ~p"/boards")

      assert has_element?(view, "#boards-tournament")
      assert has_element?(view, "#link-form-#{a.id}")

      view
      |> form("#tournament-form-#{a.id}", %{tournament_id: to_string(u12.id)})
      |> render_change()

      assert Boards.get!(a.id).tournament_id == u12.id
      # It is another tournament's board now: said, not offered for linking here.
      assert has_element?(view, "#elsewhere-#{a.id}", "U12")

      view
      |> form("#boards-tournament-form", %{tournament_id: to_string(u12.id)})
      |> render_change()

      assert has_element?(view, "#link-form-#{a.id}")
      assert has_element?(view, "#round-checks", "Ready for round #{again(u12).round}")
      assert again(open).round == 1
    end

    test "OpenPairings is a destination with its own line, switch and 'send now'", %{conn: conn} do
      %{open: open} = hall()
      game = eventually(fn -> Games.current(open.id, 1, 1) end)
      FakeOpenPairings.plant(17, game.remote_game, 9_000_000_000_000_000)

      {game, _} = Games.apply_event(game, {:moves, [%{san: "e4", flags: [], clock: nil}]}, 1)
      Outbox.enqueue(game, nil, false)

      {:ok, view, _html} = live(conn, ~p"/outbox")
      assert has_element?(view, "#dest-openpairings", "OpenPairings")
      assert has_element?(view, "#dest-waiting-openpairings", "1 waiting")
      assert has_element?(view, "#dest-by-openpairings-#{open.id}", "Open: 1 waiting")
      assert has_element?(view, "#dest-send-openpairings")
      assert has_element?(view, "#link-target-#{open.id}", "slug-17")

      # The pairing program holds something newer: listed, and the arbiter's to overrule.
      assert {:empty, 0} = Alnasl.Destination.OpenPairings.deliver()
      {:ok, view, _html} = live(conn, ~p"/outbox")
      assert has_element?(view, "#pairing-refused", "holds a newer report")
      view |> element("#force-pairing") |> render_click()
      assert {:empty, 1} = Alnasl.Destination.OpenPairings.deliver()
      assert %{"moves" => ["e4"]} = FakeOpenPairings.game(17, game.remote_game)

      view |> element("#dest-toggle-openpairings") |> render_click()
      assert has_element?(view, "#dest-state-openpairings", "Switched off")
      refute Alnasl.Destination.enabled?(Alnasl.Destination.OpenPairings)
    end
  end
end
