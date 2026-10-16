defmodule AlnaslWeb.PagesTest do
  @moduledoc "Boards, Setup, Outbox, PGN, Recordings, Log, Help and the door: each page's main actions."

  use AlnaslWeb.SiteCase

  alias Alnasl.{Log, Pgn}

  describe "Look" do
    test "the theme picker is in the rail and in Setup, with every theme", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")
      keys = AlnaslWeb.Layouts.themes() |> Enum.map(&elem(&1, 0))

      for id <- ~w(theme-picker theme-grid), key <- keys do
        assert has_element?(view, "##{id} [data-theme-opt=#{key}]")
      end
    end

    test "the favicon is the mark, and the page loads the theme before it paints", %{conn: conn} do
      conn = get(conn, "/favicon.svg")
      assert response_content_type(conn, :xml) =~ "svg"
      assert response(conn, 200) =~ "<svg"
      assert get(build_conn(), "/") |> html_response(200) =~ "/assets/js/theme.js"
    end
  end

  describe "Boards" do
    test "a simulator board is added from the form, linked, turned, disconnected and removed", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/boards")
      assert has_element?(view, "#boards-empty")

      view
      |> form("#add-board-form",
        board: %{driver: "simulator", name: "Table 1", game: "3", speed: "50", faults: "mild"}
      )
      |> render_submit()

      [board] = Boards.list()
      assert board.name == "Table 1" and board.driver == "simulator"

      assert %{"game" => 3, "speed" => 50, "faults" => %{"lift" => _}} =
               Alnasl.Boards.Board.options(board)

      assert has_element?(view, "#board-#{board.id}", "Table 1")
      assert Boards.running?(board.id)

      view |> form("#link-form-#{board.id}", %{board_no: "2"}) |> render_change()
      assert %{round: 1, board_no: 2} = Boards.get!(board.id)
      assert has_element?(view, "#open-#{board.id}")

      view |> form("#link-form-#{board.id}", %{board_no: ""}) |> render_change()
      assert Boards.get!(board.id).board_no == nil

      view |> element("#flip-#{board.id}") |> render_click()
      assert Boards.get!(board.id).flipped

      view |> element("#toggle-#{board.id}") |> render_click()
      refute Boards.get!(board.id).enabled
      eventually(fn -> not Boards.running?(board.id) end)
      view |> element("#toggle-#{board.id}") |> render_click()
      assert Boards.get!(board.id).enabled

      view |> element("#delete-#{board.id}") |> render_click()
      assert Boards.list() == []
      assert has_element?(view, "#boards-empty")
    end

    test "a real board needs a port and nothing else: no address is asked for, anywhere",
         %{conn: conn} do
      start_supervised!(
        {Arkab.Transport.Fake,
         port: "FAKE7", device: {Arkab.Dgt.Emulator, Arkab.Dgt.Emulator.new()}}
      )

      {:ok, view, _html} = live(conn, ~p"/boards")
      assert has_element?(view, "#ports-table", "FAKE7")

      view |> form("#add-board-form", board: %{driver: "dgt_serial"}) |> render_change()
      assert has_element?(view, "#add-loop-note")
      refute has_element?(view, "#add-address")
      refute has_element?(view, "#bus-warning")
      refute render(view) =~ "not verified"

      assert view
             |> form("#add-board-form", board: %{driver: "dgt_serial", port: ""})
             |> render_submit() =~ "Choose the serial port"

      view
      |> form("#add-board-form", board: %{driver: "dgt_serial", port: "FAKE7", name: "Top board"})
      |> render_submit()

      [board] = Boards.list()
      assert board.port == "FAKE7"

      eventually_html(view, fn _ ->
        has_element?(view, "#board-state-#{board.id}[data-state=unlinked]")
      end)

      eventually_html(view, fn _ -> has_element?(view, "#start-ok-#{board.id}") end)
      eventually_html(view, fn html -> html =~ "serial 12345" end)
    end

    test "a port with two boards on it is a loop: one Add, a row for each, and their numbers in small print",
         %{conn: conn} do
      loop = [
        Arkab.Dgt.Emulator.new(serial: "06310", version: "1.9"),
        Arkab.Dgt.Emulator.new(serial: "40730", version: "4.0", address: 12_799)
      ]

      start_supervised!({Arkab.Transport.Fake, port: "FAKE8", device: {Arkab.Dgt.Emulator, loop}})

      {:ok, view, _html} = live(conn, ~p"/boards")
      view |> form("#add-board-form", board: %{driver: "dgt_serial"}) |> render_change()

      html =
        view
        |> form("#add-board-form", board: %{driver: "dgt_serial", port: "FAKE8"})
        |> render_submit()

      assert html =~ "That port is a loop"
      assert [old, new] = Enum.sort_by(Boards.list(), & &1.address)
      assert {old.driver, old.address, new.address} == {"dgt_bus", 6310, 12_799}

      assert has_element?(view, "#loop-number-#{old.id}", "06310")
      assert has_element?(view, "#loop-number-#{new.id}", "12799")

      # The old board is known by its serial number, as a single board is.
      eventually_html(view, fn _ -> has_element?(view, "#identity-#{old.id}", "serial 06310") end)
      # The new one says no serial number on a loop, and the page says what to do.
      eventually_html(view, fn _ -> has_element?(view, "#loop-no-serial-#{new.id}") end)
      refute has_element?(view, "#loop-no-serial-#{old.id}")

      # One of them is taken off the loop: said in words, on its own row.
      Arkab.Transport.Fake.update("FAKE8", fn [first, _second] -> {<<>>, [first]} end)
      eventually_html(view, fn _ -> has_element?(view, "#loop-absent-#{new.id}") end)
      refute has_element?(view, "#loop-absent-#{old.id}")
    end

    test "a loop added as one board says so, and one tap reads it as a loop", %{conn: conn} do
      loop = [
        Arkab.Dgt.Emulator.new(serial: "06310", version: "1.9"),
        Arkab.Dgt.Emulator.new(serial: "40730", version: "4.0", address: 12_799)
      ]

      start_supervised!({Arkab.Transport.Fake, port: "FAKE9", device: {Arkab.Dgt.Emulator, loop}})

      {:ok, row} =
        Boards.create(%{name: "Board 1", driver: "dgt_serial", port: "FAKE9", options: %{}})

      {:ok, view, _html} = live(conn, ~p"/boards")

      eventually_html(view, fn _ -> has_element?(view, "#is-a-loop-#{row.id}") end)
      assert has_element?(view, "#is-a-loop-#{row.id}", "it is a loop")

      html = view |> element("#read-as-loop-#{row.id}") |> render_click()
      assert html =~ "That port is a loop"
      refute has_element?(view, "#board-#{row.id}")
      assert Enum.map(Boards.list(), & &1.address) |> Enum.sort() == [6310, 12_799]
    end

    test "the start-position check takes the clock in: right is pieces and clock, and a clock the wrong way is said in words",
         %{conn: conn} do
      a = fake_dgt("FAKE1")
      b = fake_dgt("FAKE2")
      {:ok, view, _html} = live(conn, ~p"/boards")

      # No clock: the pieces alone decide, as before.
      eventually_html(view, fn _ ->
        has_element?(view, "#start-ok-#{a.id}") and has_element?(view, "#start-ok-#{b.id}")
      end)

      refute has_element?(view, "#start-clock-ok-#{a.id}")

      set_clock("FAKE1", {:still, :white})
      set_clock("FAKE2", {:still, :black})

      eventually_html(view, fn _ ->
        has_element?(view, "#start-clock-ok-#{a.id}") and
          has_element?(view, "#start-clock-#{b.id}")
      end)

      refute has_element?(view, "#start-ok-#{b.id}")

      assert has_element?(
               view,
               "#board-#{b.id}",
               "Clock not in starting position: Black's side would run first - the clock is turned or the lever is the wrong way"
             )

      # Pieces wrong as well: the clock is one more line of the same list.
      set_pieces("FAKE2", Position.start() |> put_elem(3, {:b, :k}) |> put_elem(4, {:b, :q}))
      eventually_html(view, fn _ -> has_element?(view, "#start-wrong-#{b.id}") end)
      assert has_element?(view, "li#start-clock-#{b.id}", "Black's side would run first")

      # Nowhere on the page is there anything to swap the clock's sides with.
      html = render(view)
      refute html =~ "clock_white"
      refute html =~ ~r/swap.{0,20}clock|clock.{0,20}swap/i
    end

    test "the start-position check names what is wrong, and a row of boards is linked in one go",
         %{conn: conn} do
      a = fake_dgt("FAKE1")
      b = fake_dgt("FAKE2")
      set_pieces("FAKE2", Position.start() |> put_elem(3, {:b, :k}) |> put_elem(4, {:b, :q}))
      {:ok, view, _html} = live(conn, ~p"/boards")

      eventually_html(view, fn _ ->
        has_element?(view, "#start-ok-#{a.id}") and has_element?(view, "#start-wrong-#{b.id}")
      end)

      assert has_element?(
               view,
               "#board-#{b.id}",
               "black queen and black king are swapped (d8, e8)"
             )

      view |> form("#link-in-order-form", order: %{first: "3"}) |> render_submit()
      assert {Boards.get!(a.id).board_no, Boards.get!(b.id).board_no} == {3, 4}
    end
  end

  describe "Setup" do
    test "test connection asks the server and says in words how each step went", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")
      form = fn params -> form(view, "#server-form", server: params) end

      good = %{
        server_url: "http://results.test",
        tournament: FakeIngest.slug(),
        relay_key: FakeIngest.key()
      }

      form.(good) |> render_submit(%{"intent" => "test"})
      html = eventually_html(view, fn _ -> has_element?(view, "#test-result") end)

      assert html =~ "The server answers." and html =~ "relay key is accepted"

      # The box does not read the tournament from the results server any
      # more: the test is the address and the key.
      refute has_element?(view, "#check-tournament")

      assert has_element?(view, "#check-key .state.ok")

      form.(%{good | relay_key: "orrk_wrong"}) |> render_submit(%{"intent" => "test"})

      assert eventually_html(view, fn _ -> has_element?(view, "#check-key .state.bad") end) =~
               "does not accept this relay key"

      form.(%{good | tournament: "nope"}) |> render_submit(%{"intent" => "test"})

      assert eventually_html(view, fn html -> html =~ "belongs to another tournament" end) =~
               "belongs to another tournament"

      form.(%{good | tournament: ""}) |> render_submit(%{"intent" => "test"})

      assert eventually_html(view, fn html -> html =~ "No tournament is filled in" end) =~
               "No tournament is filled in"

      FakeIngest.mode(:down)
      form.(good) |> render_submit(%{"intent" => "test"})
      html = eventually_html(view, fn _ -> has_element?(view, "#check-server .state.bad") end)
      assert html =~ "nothing is listening at that address"

      # Testing saved nothing.
      assert own().relay_key == FakeIngest.key()
    end

    test "a pasted link is taken apart, and the stored key is never shown again", %{conn: conn} do
      own_put(server_url: "", slug: "", relay_key: "")
      {:ok, view, html} = live(conn, ~p"/setup")
      assert html =~ "It starts with orrk_"

      html =
        view
        |> form("#server-form",
          server: %{
            server_url: "",
            tournament: "http://results.test/t/test-open/live/3",
            relay_key: FakeIngest.key()
          }
        )
        |> render_submit()

      assert own().server_url == "http://results.test"
      assert own().slug == "test-open"
      assert html =~ "Saved."
      refute html =~ FakeIngest.key()
      assert html =~ "orrk_...cdef"

      # An empty key field keeps the key.
      view
      |> form("#server-form",
        server: %{server_url: "results.test", tournament: "test-open", relay_key: ""}
      )
      |> render_submit()

      assert own().relay_key == FakeIngest.key()
      assert own().server_url == "https://results.test"

      assert view
             |> form("#server-form", server: %{server_url: "", tournament: "", relay_key: ""})
             |> render_submit() =~ "Give the server"
    end

    test "the box: name, language, round, and whether mate is offered without the arbiter", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/setup")

      view
      |> form("#box-form",
        box: %{
          box_name: "Hall B",
          locale: "nl",
          round: "3",
          auto_suggest: "true",
          capture_cap_mb: "200",
          clock_heartbeat_s: "30"
        }
      )
      |> render_submit()

      assert_redirect(view, ~p"/setup")

      assert own().round == 3

      assert Settings.get_many(~w(box_name locale auto_suggest capture_cap_mb clock_heartbeat_s)) ==
               %{
                 "box_name" => "Hall B",
                 "locale" => "nl",
                 "auto_suggest" => true,
                 "capture_cap_mb" => 200,
                 "clock_heartbeat_s" => 30
               }

      {:ok, view, html} = live(conn, ~p"/setup")
      assert has_element?(view, "#brand", "Hall B")
      assert html =~ "Borden" and html =~ "Opslaan"
    end

    test "a PIN is set and removed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")
      assert has_element?(view, "#pin-state", "No PIN")
      assert view |> form("#pin-form", door: %{pin: "12"}) |> render_submit() =~ "at least 4"
      view |> form("#pin-form", door: %{pin: "2468"}) |> render_submit()

      assert Settings.pin_set?() and Settings.pin_valid?("2468") and
               not Settings.pin_valid?("1111")

      assert has_element?(view, "#pin-state", "A PIN is set")
      refute Jason.encode!(Settings.get("pin")) =~ "2468"

      view |> element("#clear-pin") |> render_click()
      refute Settings.pin_set?()
    end

    test "the tracker's patience is saved, bounded, and reset", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      view
      |> form("#tracker-form",
        tracker: %{
          settle_ms: "250",
          search_depth: "99",
          promotion_default: "n",
          takeback: "false"
        }
      )
      |> render_submit()

      opts = Settings.tracker_opts()

      assert opts[:settle_ms] == 250 and opts[:search_depth] == 12 and
               opts[:promotion_default] == :n and opts[:takeback] == false

      view |> element("#reset-tracker") |> render_click()
      assert Settings.tracker_opts() == []
    end

    test "\"Bullet / fast play\" moves the settings that belong together, and leaves the search depth alone",
         %{conn: conn} do
      assert Alnasl.Tracker.defaults().search_depth == 8
      {:ok, view, _html} = live(conn, ~p"/setup")
      refute has_element?(view, "#preset-bullet-on")
      assert has_element?(view, "#tracker-depth-note")

      view |> form("#tracker-form", tracker: %{search_depth: "3"}) |> render_submit()
      view |> element("#preset-bullet") |> render_click()
      assert has_element?(view, "#preset-bullet-on")

      opts = Settings.tracker_opts()
      assert opts[:settle_ms] == 150 and opts[:takeback] == false
      assert opts[:search_depth] == 3
      # The waits for a castle and a promotion are not part of it.
      assert opts[:castle_hold_ms] == 150 and opts[:promotion_hold_ms] == 200

      view |> element("#reset-tracker") |> render_click()
      refute has_element?(view, "#preset-bullet-on")
      assert Settings.tracker_opts() == []
    end
  end

  describe "Outbox" do
    test "says what waits and why, on every page, and sends when asked", %{conn: conn} do
      start_supervised!(Outbox)
      FakeIngest.mode(:down)
      {:ok, _} = Boards.attach_pgn(1, 2, hd(elem(Pgn.load("1. e4 e5 2. Nf3 Nc6 1/2-1/2"), 0)))

      {:ok, view, _html} = live(conn, ~p"/outbox")
      html = eventually_html(view, fn _ -> has_element?(view, "#offline-banner") end)
      assert html =~ "Nothing is lost"
      assert has_element?(view, "#waiting-table tr", "result 1/2-1/2")
      assert has_element?(view, "#last-error", "cannot be reached")
      assert has_element?(view, "#waiting-count", "1")

      # The banner is on the other pages too.
      {:ok, help, _html} = live(conn, ~p"/help")
      assert has_element?(help, "#offline-banner")
      assert has_element?(help, "#nav-outbox .count", "1")

      FakeIngest.mode(:ok)
      view |> element("#send-now") |> render_click()

      eventually_html(view, fn _ ->
        has_element?(view, "#sent-table tr", "result 1/2-1/2") and
          not has_element?(view, "#offline-banner")
      end)

      assert has_element?(view, "#link-word", "Connected")
      assert FakeIngest.game(1, 2).moves == ~w(e4 e5 Nf3 Nc6)

      view |> element("#prune") |> render_click()
      refute has_element?(view, "#sent-table")
    end

    test "a refused key is said in words, and what the server refused is listed", %{conn: conn} do
      start_supervised!(Outbox)
      game = Games.ensure(1, 1)

      Repo.insert!(%Alnasl.Outbox.Entry{
        game_id: game.id,
        round: 1,
        board_no: 1,
        seq: 1,
        plies: 1,
        body: Jason.encode!(%{round: 1, board: 1, moves: ["Ke4"]})
      })

      Outbox.kick()

      {:ok, view, _html} = live(conn, ~p"/outbox")
      eventually_html(view, fn _ -> has_element?(view, "#rejected-table") end)
      assert has_element?(view, "#rejected-table", "calls a move in it illegal")

      own_put(relay_key: "orrk_wrong")
      Games.ensure(1, 2) |> Outbox.enqueue(nil, true)
      html = eventually_html(view, fn _ -> has_element?(view, "#offline-banner.bad") end)
      assert html =~ "refuses this box"
      assert has_element?(view, "#last-error", "does not accept the relay key")
    end
  end

  describe "PGN" do
    @pgn """
    [White "Anderssen"]
    [Black "Kieseritzky"]
    [Result "1-0"]

    1. e4 e5 2. f4 exf4 3. Bc4 Qh4+ 4. Kf1 b5 1-0

    [White "Wrong"]
    [Black "Game"]

    1. e4 Ke5 *
    """

    test "games are read and checked; a bad one is named and can do nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/pgn")
      html = view |> form("#paste-form", paste: %{text: @pgn}) |> render_submit()
      assert has_element?(view, "#read-1", "Anderssen - Kieseritzky")
      refute has_element?(view, "#read-2")
      assert has_element?(view, "#pgn-problems", "Wrong - Game")
      assert html =~ "ply 2"

      assert view |> form("#paste-form", paste: %{text: "   "}) |> render_submit() =~
               "No game was found"
    end

    test "a file is uploaded", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/pgn")

      upload =
        file_input(view, "#upload-form", :pgn, [
          %{name: "round.pgn", content: @pgn, type: "application/x-chess-pgn"}
        ])

      render_upload(upload, "round.pgn")
      view |> form("#upload-form") |> render_submit()
      assert has_element?(view, "#read-1", "Anderssen - Kieseritzky")
    end

    test "a game is compared with a board, attached after asking, and exported", %{conn: conn} do
      board = fake_dgt("FAKE1", %{round: 1, board_no: 2})
      eventually(fn -> Boards.snapshot(board.id).connected? end)
      play_on("FAKE1", board.id, ~w(e4 e5 f4 exf4 Bc4 Qe7))

      {:ok, view, _html} = live(conn, ~p"/pgn")
      view |> form("#paste-form", paste: %{text: @pgn}) |> render_submit()
      assert view |> element("#compare-1") |> render_click() =~ "Choose the board to compare with"

      view |> form("#target-form-1", %{board_no: "2"}) |> render_change()
      view |> element("#compare-1") |> render_click()

      assert has_element?(
               view,
               "#verdict-1",
               "move 3 (Black): the board has Qe7, this PGN has Qh4+"
             )

      view |> element("#attach-1") |> render_click()
      assert has_element?(view, "#attach-confirm", "already has a game of 3 move(s)")
      view |> element("#attach-no") |> render_click()
      refute has_element?(view, "#attach-confirm")
      assert Games.sans(Games.get(1, 2)) == ~w(e4 e5 f4 exf4 Bc4 Qe7)

      view |> element("#attach-1") |> render_click()
      view |> element("#attach-yes") |> render_click()
      assert Games.sans(Games.get(1, 2)) == ~w(e4 e5 f4 exf4 Bc4 Qh4+ Kf1 b5)
      assert Boards.get!(board.id).board_no == nil
      assert has_element?(view, "#stored-2", "Player 3 - Player 4")
      assert Outbox.drain() == :empty
      assert %{status: "finished", result: "1-0"} = FakeIngest.game(1, 2)

      view |> element("#compare-1") |> render_click()
      assert has_element?(view, "#verdict-1 .state.ok")

      body = conn |> get(~p"/files/round/1/board/2") |> response(200)
      assert body =~ ~s([White "Player 3"]) and body =~ "3. Bc4 Qh4+ 4. Kf1 b5 1-0"
      assert conn |> get(~p"/files/round/1") |> response(200) =~ ~s([Board "2"])
      assert conn |> get(~p"/files/round/1/board/9") |> response(404)
    end

    test "games are played on simulator boards", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/pgn")
      view |> form("#paste-form", paste: %{text: @pgn}) |> render_submit()
      view |> form("#target-form-1", %{board_no: "4"}) |> render_change()
      assert view |> element("#simulate-1") |> render_click() =~ "is playing that game on board 4"

      [board] = Boards.list()
      assert %{driver: "simulator", round: 1, board_no: 4} = board
      assert Alnasl.Boards.Board.options(board)["moves"] == ~w(e4 e5 f4 exf4 Bc4 Qh4+ Kf1 b5)
      eventually(fn -> sans(board.id) == ~w(e4 e5 f4 exf4 Bc4 Qh4+ Kf1 b5) end, 20_000)

      view |> element("#simulate-all") |> render_click()
      assert length(Boards.list()) == 2
      view |> element("#clear-games") |> render_click()
      refute has_element?(view, "#read-games")
    end
  end

  describe "Recordings" do
    test "a capture is listed, replayed through the tracker as a dry run, exported and deleted",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/recordings")
      assert has_element?(view, "#captures-empty") or has_element?(view, "#captures-table")

      board = fake_dgt("FAKE1", %{round: 1, board_no: 1})
      eventually(fn -> Boards.snapshot(board.id).connected? end)
      play_on("FAKE1", board.id, ~w(e4 e5 Nf3))
      Boards.note(board, "three moves, on purpose")

      view |> element("#refresh-captures") |> render_click()
      [capture | _] = Enum.filter(Recorder.list(), &(&1.board_id == board.id))
      key = "#{board.id}-#{Path.rootname(capture.name)}"
      assert has_element?(view, "#capture-#{key}", "DGT FAKE1")

      view |> element("#dry-#{key}") |> render_click()
      assert has_element?(view, "#report-count", "3")
      assert has_element?(view, "#report-alarms", "never")
      assert has_element?(view, "#report-moves", "f3")
      assert has_element?(view, "#dry-run", "three moves, on purpose")
      view |> element("#close-report") |> render_click()
      refute has_element?(view, "#dry-run")

      # Nothing was saved or sent by the dry run.
      assert Games.sans(Games.get(1, 1)) == ~w(e4 e5 Nf3)

      assert view |> element("#fixture-#{key}") |> render_click() =~ "Exported as a test fixture"
      fixture = Path.join(Alnasl.Paths.fixtures(), "board-#{key}.jsonl")
      assert {:ok, %{moves: ["e4", "e5", "Nf3"]}} = Recorder.dry_run(fixture, settle_ms: 40)
      File.rm!(fixture)

      assert conn |> get(~p"/files/capture/#{board.id}/#{capture.name}") |> response(200) =~
               ~s("k":"pos")

      assert conn |> get(~p"/files/capture/#{board.id}/nope.jsonl") |> response(404)

      Boards.stop(board)
      view |> element("#delete-#{key}") |> render_click()
      refute has_element?(view, "#capture-#{key}")
    end
  end

  describe "Log" do
    test "reads as sentences, filters, and grows while you look", %{conn: conn} do
      Log.add(:info, "board.connected", %{}, %{round: 1, board_no: 7})
      Log.add(:warn, "move.recovered", %{moves: ["Nf3", "Nc6"]}, %{round: 1, board_no: 7})
      Log.add(:error, "board.out_of_sync", %{why: ":unexplained"}, %{round: 1, board_no: 2})
      Log.add(:info, "repair.undo", %{move: "Nf3", by: "arbiter"}, %{round: 1, board_no: 2})

      {:ok, view, html} = live(conn, ~p"/log")
      assert html =~ "Reconstructed, not seen one by one (one line fits): Nf3 Nc6"
      assert html =~ "Arbiter at the box: last move (Nf3) taken back."
      assert has_element?(view, "#log-lines li.error", "Out of sync")
      assert has_element?(view, "#log-lines .where", "R1 board 7")

      html =
        view
        |> form("#log-filter", filter: %{level: "error", kind: "", board: ""})
        |> render_change()

      assert html =~ "Out of sync" and not (html =~ "Reconstructed, not seen")

      html =
        view
        |> form("#log-filter", filter: %{level: "", kind: "repair.", board: ""})
        |> render_change()

      assert html =~ "taken back" and not (html =~ "Out of sync")

      html =
        view |> form("#log-filter", filter: %{level: "", kind: "", board: "7"}) |> render_change()

      assert html =~ "The board answers." and not (html =~ "taken back")

      Log.add(:info, "board.resumed", %{}, %{round: 1, board_no: 7})
      Log.add(:info, "board.resumed", %{}, %{round: 1, board_no: 3})
      html = eventually_html(view, fn html -> html =~ "Back in sync." end)
      assert length(Regex.scan(~r/Back in sync\./, html)) == 1

      view |> element("#log-clear") |> render_click()
      assert render(view) =~ "taken back"
    end

    test "every kind the box writes has a sentence" do
      kinds =
        ~w(board.added board.removed board.connected board.disconnected board.driver_failed board.linked board.unlinked
           board.moved board.flipped board.out_of_sync board.resumed move.recovered move.guessed move.assumed move.corrected
           clock.move_missing clock.wrong_side clock.side_ok result.suggested result.set result.reopened repair.undo repair.append repair.edit
           repair.set_fen repair.resync repair.choose repair.paused repair.resumed pgn.attached outbox.offline
           outbox.online outbox.blocked outbox.conflict outbox.server_ahead door.unlocked door.refused setup.saved
           destination.offline destination.online destination.blocked destination.enabled destination.disabled
           table.set table.cleared table.moved table.remapped table.swapped board.recognised
           board.other_serial board.replaced piece.unseen piece.accounted game.new game.switched move.rewritten move.out_of_turn move.illegal
           link.added link.removed link.ok link.unreachable link.unauthorized link.unsupported link.connect_failed
           tournament.added tournament.back tournament.gone tournament.tables table.tournament
           tournament.elsewhere tournament.code_replaced tournament.merged tournament.merge_failed
           round.started pairing.changed pairing.gone pairing.board_moved pairing.adopted
           pairing.set_aside destination.forced update.requested loop.read loop.joined
           seating.joined seating.undone table.game_carried table.game_fresh table.game_left
           bridge.joined bridge.removed bridge.moved hall.created account.first account.invited
           account.joined account.made account.temporary_password account.refused)

      for kind <- kinds do
        sentence = AlnaslWeb.Words.log(%Alnasl.Log.Event{kind: kind, data: "{}"})
        assert sentence != kind, "#{kind} has no sentence"
      end

      # And every kind written anywhere in the code is in that list.
      written =
        for file <- Path.wildcard("lib/**/*.ex"),
            [_, kind] <- Regex.scan(~r/Log\.add\(\s*:\w+,\s*"([a-z_.]+)"/, File.read!(file)),
            uniq: true,
            do: kind

      assert written -- kinds == []
    end
  end

  test "Help is there, in both languages", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/help")
    assert has_element?(view, "#manual-index")
    assert html =~ "The Alnasl user manual"

    {:ok, view, html} = live(conn, ~p"/help/getting-started")
    assert has_element?(view, "#before-the-round")
    assert html =~ "Before the round"

    Settings.put("locale", "nl")
    {:ok, _view, html} = live(conn, ~p"/help/getting-started")
    assert html =~ "Voor de ronde"
  end

  describe "the door" do
    defp from_elsewhere(conn), do: %{conn | remote_ip: {192, 168, 1, 50}}

    test "the box itself is always let in; another machine only with the PIN, when one is set", %{
      conn: conn
    } do
      assert conn |> from_elsewhere() |> get(~p"/help") |> html_response(200)

      Settings.set_pin("2468")
      assert conn |> get(~p"/help") |> html_response(200)
      assert {:ok, _view, _html} = live(conn, ~p"/help")

      far = from_elsewhere(conn)
      assert redirected_to(get(far, ~p"/help")) == ~p"/unlock"
      assert redirected_to(get(far, ~p"/files/round/1")) == ~p"/unlock"
      assert far |> get(~p"/unlock") |> html_response(200) =~ "unlock-form"

      wrong = post(far, ~p"/unlock", %{pin: "0000"})
      assert html_response(wrong, 401) =~ "That is not the PIN."

      opened = post(far, ~p"/unlock", %{pin: "2468"})
      assert redirected_to(opened) == ~p"/"
      inside = opened |> recycle() |> from_elsewhere()
      assert inside |> get(~p"/help") |> html_response(200)
      assert {:ok, _view, _html} = live(inside, ~p"/help")

      locked = inside |> get(~p"/lock") |> recycle() |> from_elsewhere()
      assert redirected_to(get(locked, ~p"/help")) == ~p"/unlock"
      kinds = Enum.map(Log.list(), & &1.kind)
      assert "door.unlocked" in kinds and "door.refused" in kinds
    end

    test "the language switch is one link, and it is the box's language", %{conn: conn} do
      conn = conn |> put_req_header("referer", "http://localhost/boards") |> get(~p"/locale/nl")
      assert redirected_to(conn) == "/boards"
      assert Settings.get("locale") == "nl"
      assert redirected_to(get(build_conn(), ~p"/locale/xx")) == "/"
      assert Settings.get("locale") == "nl"
    end
  end
end
