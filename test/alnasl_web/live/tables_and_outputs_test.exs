defmodule AlnaslWeb.TablesAndOutputsTest do
  @moduledoc """
  The pages about which board is which - Boards, the two phone pages, the
  label sheet - and the pages about where the games go: the Lichess card on
  Setup and the destinations on Outbox.
  """

  use AlnaslWeb.SiteCase

  alias Alnasl.{Destination, FakeLichess, Finder, Tables}
  alias Alnasl.Destination.LichessBroadcast
  alias Arkab.Dgt.Emulator
  alias Arkab.Transport.Fake

  setup do
    Finder.reset()
    Application.put_env(:alnasl, :lan_addresses, ["192.168.1.20"])

    on_exit(fn ->
      Application.delete_env(:alnasl, :lan_addresses)
      Application.delete_env(:alnasl, :lan?)
      Finder.reset()
    end)

    :ok
  end

  # A simulator board that stands still: nothing touches it but the test.
  defp still(name, attrs \\ %{}) do
    {:ok, board} =
      Boards.create(
        Map.merge(
          %{
            name: name,
            driver: "simulator",
            port: "sim-" <> name,
            options: %{"moves" => ~w(e4 e5), "speed" => 1, "start_delay_ms" => 600_000}
          },
          attrs
        )
      )

    board
  end

  defp dgt(port, serial, attrs \\ %{}) do
    start_supervised!({Fake, port: port, device: {Emulator, Emulator.new(serial: serial)}},
      id: port
    )

    {:ok, board} =
      Boards.create(Map.merge(%{name: "DGT " <> port, driver: "dgt_serial", port: port}, attrs))

    eventually(fn -> Boards.get!(board.id).serial == serial end)
    eventually(fn -> Boards.snapshot(board.id).raw != nil end)
    Boards.get!(board.id)
  end

  defp from_elsewhere(conn), do: %{conn | remote_ip: {192, 168, 1, 50}}

  describe "Boards: table numbers" do
    test "a new board asks for a number; the board of the round follows it; it can be remapped and put back",
         %{conn: conn} do
      a = still("a")
      b = still("b")
      {:ok, view, _html} = live(conn, ~p"/boards")

      assert has_element?(view, "#new-board-#{a.id}", "New board")
      assert has_element?(view, "#checks-not-ready")
      assert has_element?(view, "#checks-list li.warn", "has no table number yet")

      view |> form("#table-form-#{a.id}", %{table_no: "1"}) |> render_change()
      assert %{table_no: 1, round: 1, board_no: 1} = Boards.get!(a.id)
      refute has_element?(view, "#new-board-#{a.id}")
      assert has_element?(view, "#table-#{a.id}[value='1']")

      view |> form("#table-form-#{b.id}", %{table_no: "2"}) |> render_change()
      assert has_element?(view, "#checks-ready")

      # For this round table 1 plays board 3.
      view |> form("#link-form-#{a.id}", %{board_no: "3"}) |> render_change()
      assert %{table_no: 1, board_no: 3} = Boards.get!(a.id)
      assert has_element?(view, "#remapped-#{a.id}", "table 1 plays board 3")
      assert has_element?(view, "#checks-list", "plays board 3 this round")
      # Which leaves board 1 of the round without a board: said, and not ready.
      assert has_element?(
               view,
               "#checks-list li.warn",
               "Board 1 of the round has no electronic board"
             )

      assert has_element?(view, "#checks-not-ready")

      view |> element("#back-to-table-#{a.id}") |> render_click()
      assert Boards.get!(a.id).board_no == 1
      refute has_element?(view, "#remapped-#{a.id}")
      assert has_element?(view, "#checks-ready")

      # Swap two for the round, and put everything back.
      view |> form("#swap-form", swap: %{a: a.id, b: b.id}) |> render_submit()
      assert {Boards.get!(a.id).board_no, Boards.get!(b.id).board_no} == {2, 1}
      assert {Boards.get!(a.id).table_no, Boards.get!(b.id).table_no} == {1, 2}
      view |> element("#clear-remaps") |> render_click()
      assert {Boards.get!(a.id).board_no, Boards.get!(b.id).board_no} == {1, 2}

      assert view |> form("#swap-form", swap: %{a: a.id, b: a.id}) |> render_submit() =~
               "two different boards"

      # Emptying the field takes the sticker away.
      view |> form("#table-form-#{a.id}", %{table_no: ""}) |> render_change()
      assert Boards.get!(a.id).table_no == nil
    end

    test "numbering in connection order sets table and board at once", %{conn: conn} do
      a = still("a")
      b = still("b")
      {:ok, view, _html} = live(conn, ~p"/boards")

      html = view |> form("#link-in-order-form", order: %{first: "3"}) |> render_submit()
      assert html =~ "numbered 3-4"
      assert %{table_no: 3, board_no: 3} = Boards.get!(a.id)
      assert %{table_no: 4, board_no: 4} = Boards.get!(b.id)
    end

    test "the serial is the identity shown, and a known board on another port is not a second row",
         %{conn: conn} do
      board = dgt("FAKE-P1", "06310", %{name: "Top board"})
      Tables.set_table(board, 5)
      {:ok, view, _html} = live(conn, ~p"/boards")
      assert has_element?(view, "#identity-#{board.id}", "serial 06310")

      Boards.disconnect(Boards.get!(board.id))
      stop_supervised!("FAKE-P1")

      start_supervised!(
        {Fake, port: "FAKE-P2", device: {Emulator, Emulator.new(serial: "06310")}},
        id: "FAKE-P2"
      )

      view |> element("#rescan") |> render_click()
      view |> form("#add-board-form", board: %{driver: "dgt_serial"}) |> render_change()
      assert has_element?(view, "#add-known-note")

      view
      |> form("#add-board-form", board: %{driver: "dgt_serial", port: "FAKE-P2", name: ""})
      |> render_submit()

      eventually(fn -> match?([%{port: "FAKE-P2", table_no: 5}], Boards.list()) end)

      # One row, the one it always was - on its new port, with its number.
      eventually_html(view, fn html ->
        rows = html |> LazyHTML.from_fragment() |> LazyHTML.query("#boards-table tbody tr")

        Enum.count(rows) == 1 and has_element?(view, "#board-#{board.id}", "Top board") and
          has_element?(view, "#board-#{board.id}", "FAKE-P2") and
          has_element?(view, "#table-#{board.id}[value='5']")
      end)
    end
  end

  describe "Boards: which board is this?" do
    test "in find mode the touched board lights up, with the time, and is scrolled to", %{
      conn: conn
    } do
      a = still("a")
      b = still("b")
      {:ok, view, _html} = live(conn, ~p"/boards")

      # Not asked: a touch changes nothing on the page.
      Finder.touch(a.id)
      _ = Finder.state()
      refute has_element?(view, "#touched-#{a.id}")
      refute has_element?(view, "#find-banner")

      view |> element("#find-toggle") |> render_click()
      assert has_element?(view, "#find-banner")
      assert has_element?(view, "#find-toggle[aria-pressed='true']")

      Finder.touch(b.id)
      assert_push_event(view, "boards:found", %{id: id})
      assert id == "board-#{b.id}"
      assert has_element?(view, "tr#board-#{b.id}.found")
      assert has_element?(view, "#touched-#{b.id}", "touched")
      refute has_element?(view, "tr#board-#{a.id}.found")

      # Several boards touched: the newest is the one lit.
      Finder.touch(a.id)
      assert_push_event(view, "boards:found", %{id: _})
      assert has_element?(view, "tr#board-#{a.id}.found")
      refute has_element?(view, "tr#board-#{b.id}.found")

      view |> element("#find-toggle") |> render_click()
      refute has_element?(view, "#find-banner")
      refute has_element?(view, "tr.found")
    end

    test "'Show me' names the serial to look for, and a touch says right or wrong", %{conn: conn} do
      a = dgt("FAKE-S1", "06310")
      b = dgt("FAKE-S2", "07777")
      Tables.set_table(a, 7)
      {:ok, view, _html} = live(conn, ~p"/boards")

      view |> element("#show-me-#{a.id}") |> render_click()
      assert has_element?(view, "#seeking-banner", "table 7 · serial 06310")
      assert has_element?(view, "tr#board-#{a.id}.sought")

      # A real touch on the wrong board.
      set_pieces("FAKE-S2", Position.start() |> put_elem(52, nil))
      eventually_html(view, fn _ -> has_element?(view, "#seeking-missed", b.name) end)

      set_pieces("FAKE-S1", Position.start() |> put_elem(52, nil))

      html =
        eventually_html(view, fn _ -> not has_element?(view, "#seeking-banner") end)

      assert html =~ "That is the one"

      view |> element("#show-me-#{b.id}") |> render_click()
      view |> element("#stop-seeking") |> render_click()
      refute has_element?(view, "#seeking-banner")
    end
  end

  describe "the phone" do
    test "Boards and Setup show the address to open, as text and as a QR code, and what to know about the PIN",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/boards")
      assert has_element?(view, "#phone-access-urls li", "http://192.168.1.20:4002/boards/number")
      assert has_element?(view, "#phone-access-qr svg[role=img] rect")
      # No PIN: the hint to set one before the hall fills up.
      assert has_element?(view, "#phone-access-pin-hint", "Set a PIN")
      # The test box listens to itself only, and says so.
      assert has_element?(view, "#phone-access-local-only")

      Application.put_env(:alnasl, :lan?, true)
      Settings.set_pin("2468")
      {:ok, view, _html} = live(conn, ~p"/setup")
      assert has_element?(view, "#setup-phone-access-urls li", "http://192.168.1.20:4002/")
      assert has_element?(view, "#setup-phone-access-qr svg")
      assert has_element?(view, "#setup-phone-access-pin-set")
      refute has_element?(view, "#setup-phone-access-pin-hint")
      refute has_element?(view, "#setup-phone-access-local-only")

      Application.put_env(:alnasl, :lan_addresses, [])
      {:ok, view, _html} = live(conn, ~p"/boards")
      assert has_element?(view, "#phone-access-none")
    end

    test "the QR code is a real one: square, with its three corner marks" do
      assert %{size: size, cells: cells} =
               AlnaslWeb.Access.qr("http://192.168.1.20:4040/boards/number")

      modules = size - 8
      assert modules >= 21 and rem(modules - 21, 4) == 0
      dark = MapSet.new(cells)
      # The finder patterns: a 7x7 dark frame in three corners, quiet zone of four around.
      for {ox, oy} <- [{4, 4}, {size - 11, 4}, {4, size - 11}], i <- 0..6 do
        assert {ox + i, oy} in dark and {ox, oy + i} in dark
        assert {ox + i, oy + 6} in dark and {ox + 6, oy + i} in dark
      end

      assert Enum.all?(cells, fn {x, y} -> x >= 4 and y >= 4 and x < size - 4 and y < size - 4 end)

      assert AlnaslWeb.Access.qr("a") != AlnaslWeb.Access.qr("b")
    end

    test "numbering by touch on a phone-sized page: big number, flash with serial, keys under the thumb",
         %{conn: conn} do
      a = dgt("FAKE-W1", "06310")
      b = still("b")
      {:ok, view, _html} = live(conn, ~p"/boards/number")

      assert has_element?(view, "#walk[phx-hook]")

      assert has_element?(
               view,
               "#walk-sound[phx-update=ignore] #walk-mute[data-mute][data-state]"
             )

      for state <- ~w(on off tap blocked),
          do: assert(has_element?(view, "#walk-mute [data-for=#{state}]"))

      assert has_element?(view, "#walk-start-form #walk-first[inputmode=numeric]")
      assert has_element?(view, "#walk-count", "0 of 2")
      refute has_element?(view, "#walk-keys")

      view |> form("#walk-start-form", walk: %{first: "5"}) |> render_submit()
      assert has_element?(view, "#walk-next", "5")
      assert has_element?(view, "#walk-flash-none")

      for id <- ~w(walk-undo walk-skip walk-stop),
          do: assert(has_element?(view, "#walk-keys ##{id}"))

      assert has_element?(view, "#walk-undo[disabled]")

      # A second device - the box's own screen - opened mid-run sees the same run.
      {:ok, kiosk, _html} = live(conn, ~p"/boards/number")
      assert has_element?(kiosk, "#walk-next", "5")

      # A piece is lifted on the real board.
      set_pieces("FAKE-W1", Position.start() |> put_elem(52, nil))
      assert_push_event(view, "walk:buzz", %{kind: "assigned"}, 2_000)
      assert has_element?(view, "#walk-flash-5.ok", "Table 5")
      assert has_element?(view, "#walk-flash-5", "serial 06310")
      assert has_element?(view, "#walk-next", "6")
      assert has_element?(view, "#walk-done-#{a.id}", "5")
      assert %{table_no: 5, board_no: 5} = Boards.get!(a.id)
      eventually_html(kiosk, fn _ -> has_element?(kiosk, "#walk-next", "6") end)
      assert has_element?(kiosk, "#walk-flash-5", "serial 06310")

      # The piece goes back: no second number, and the phone says why.
      set_pieces("FAKE-W1", Position.start())
      assert_push_event(view, "walk:buzz", %{kind: "already"}, 2_000)
      assert has_element?(view, "#walk-flash-again-5", "Already table 5")
      assert has_element?(view, "#walk-next", "6")

      # The phone drops off the Wi-Fi and comes back: a fresh page, the same run.
      {:ok, back, _html} = live(conn, ~p"/boards/number")
      assert has_element?(back, "#walk-next", "6")
      assert has_element?(back, "#walk-done-#{a.id}", "5")

      back |> element("#walk-skip") |> render_click()
      assert has_element?(back, "#walk-next", "7")
      eventually_html(view, fn _ -> has_element?(view, "#walk-next", "7") end)
      back |> element("#walk-undo") |> render_click()
      assert has_element?(back, "#walk-next", "6")
      back |> element("#walk-undo") |> render_click()
      assert has_element?(back, "#walk-next", "5")
      assert Boards.get!(a.id).table_no == nil

      # Both boards touched: the run ends by itself and says so.
      Finder.touch(b.id)
      assert_push_event(back, "walk:buzz", %{kind: "assigned"}, 2_000)
      Finder.touch(a.id)
      eventually_html(back, fn _ -> has_element?(back, "#walk-flash-complete") end)
      assert has_element?(back, "#walk-start")
      assert has_element?(back, "#walk-count", "2 of 2")
      assert {Boards.get!(b.id).table_no, Boards.get!(a.id).table_no} == {5, 6}

      # Stop is a stop for everybody.
      back |> form("#walk-start-form", walk: %{first: "1"}) |> render_submit()
      eventually_html(view, fn _ -> has_element?(view, "#walk-keys") end)
      view |> element("#walk-stop") |> render_click()
      eventually_html(back, fn _ -> has_element?(back, "#walk-start") end)

      # And the Boards page says when a run is on.
      Finder.start_wizard(1)
      {:ok, boards, _html} = live(conn, ~p"/boards")
      assert has_element?(boards, "#wizard-banner")
    end

    test "'Which board is this?' on the phone: touch a board, read its number", %{conn: conn} do
      a = still("a", %{round: 1, board_no: 3, table_no: 7})
      b = still("b")
      {:ok, view, _html} = live(conn, ~p"/boards/find")
      assert has_element?(view, "#walk-found-none")
      assert has_element?(view, "#walk-tab-find[aria-current='true']")

      Finder.touch(a.id)
      assert_push_event(view, "walk:buzz", %{kind: "touch"})
      assert has_element?(view, "#walk-found.fresh #walk-found-number", "3")
      assert has_element?(view, "#walk-found-sticker", "table 7 · slot sim-a")
      assert has_element?(view, "#walk-found-open")

      Finder.touch(b.id, System.system_time(:millisecond) + 5)
      assert_push_event(view, "walk:buzz", %{kind: "touch"})
      assert has_element?(view, "#walk-found-number", "?")
      assert has_element?(view, "#walk-found", "New board")
      # The one before is still there, with its time.
      assert has_element?(view, "#walk-recent-#{a.id}", "table 7")

      view |> element("#walk-tab-number") |> render_click()
      assert_patch(view, ~p"/boards/number")
      assert has_element?(view, "#walk-start")
    end

    test "the Boards table turns into cards on a phone: every row's cells carry the names the card layout is drawn from",
         %{conn: conn} do
      a = still("a")
      still("b")
      {:ok, view, _html} = live(conn, ~p"/boards")

      for cell <- ~w(b-name b-reads b-state b-signal b-start b-table b-link act) do
        assert has_element?(view, "#board-#{a.id} td.#{cell}"), "no #{cell} cell on the row"
      end

      # The cells that have no heading of their own in the card carry one.
      for cell <- ~w(b-state b-signal b-start b-link) do
        assert has_element?(view, "#board-#{a.id} td.#{cell}[data-label]")
      end

      # The ids the rest of the tests (and the thumb) go by survive the card.
      for id <- [
            "table-#{a.id}",
            "link-#{a.id}",
            "show-me-#{a.id}",
            "toggle-#{a.id}",
            "flip-#{a.id}",
            "delete-#{a.id}"
          ] do
        assert has_element?(view, "#board-#{a.id} ##{id}")
      end
    end

    test "a spectator's phone gets the PIN question, not the numbering", %{conn: conn} do
      board = still("a")
      Settings.set_pin("2468")
      far = from_elsewhere(conn)

      for path <- [~p"/boards/number", ~p"/boards/find", ~p"/boards", ~p"/files/labels"] do
        assert redirected_to(get(far, path)) == ~p"/unlock"
      end

      assert {:error, {:redirect, %{to: "/unlock"}}} = live(far, ~p"/boards/number")
      assert Finder.state().wizard == nil
      assert Boards.get!(board.id).table_no == nil

      # With the PIN it is the arbiter's phone.
      inside = far |> post(~p"/unlock", %{pin: "2468"}) |> recycle() |> from_elsewhere()
      {:ok, view, _html} = live(inside, ~p"/boards/number")
      view |> form("#walk-start-form", walk: %{first: "1"}) |> render_submit()
      Finder.touch(board.id)
      eventually(fn -> Boards.get!(board.id).table_no == 1 end)

      # The box itself is never asked.
      assert {:ok, _view, _html} = live(conn, ~p"/boards/number")
    end
  end

  describe "labels" do
    test "a printable sheet: table number and serial per board", %{conn: conn} do
      empty = conn |> get(~p"/files/labels") |> html_response(200)
      assert empty =~ ~s(id="labels-empty")

      a = dgt("FAKE-L1", "06310")
      Tables.set_table(a, 7)
      _unnumbered = still("spare")

      doc = conn |> get(~p"/files/labels") |> html_response(200) |> LazyHTML.from_document()
      label = LazyHTML.query(doc, "#labels-sheet #label-#{a.id}")
      assert LazyHTML.text(LazyHTML.query(label, ".label-number")) == "7"
      assert LazyHTML.text(LazyHTML.query(label, ".label-id")) == "serial 06310"
      assert Enum.count(LazyHTML.query(doc, "#labels-sheet .label")) == 1
      assert LazyHTML.text(LazyHTML.query(doc, "#labels-without")) =~ "1 board(s)"

      {:ok, view, _html} = live(conn, ~p"/boards")
      assert has_element?(view, "#print-labels[href='/files/labels']")
    end
  end

  describe "Round" do
    test "a tile shows the board number big and the physical board small", %{conn: conn} do
      a = dgt("FAKE-R1", "06310")
      Tables.set_table(a, 7)
      Tables.remap(Boards.get!(a.id), 3)

      {:ok, view, _html} = live(conn, ~p"/round/1")
      assert has_element?(view, "#tile-3 .tile-no", "3")
      assert has_element?(view, "#tile-sticker-3", "table 7 · serial 06310")
    end
  end

  describe "Lichess" do
    setup do
      start_supervised!(FakeLichess)
      Application.put_env(:alnasl, :lichess_req_options, plug: &FakeLichess.call/1)
      Settings.put("lichess_url", FakeLichess.base())
      on_exit(fn -> FakeLichess.uninstall() end)
      :ok
    end

    test "Setup: the round as a link, the token typed once and never shown again, a test in words",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")
      assert has_element?(view, "#setup-lichess #lichess-form")
      refute Destination.enabled?(LichessBroadcast)

      form = fn fields -> form(view, "#lichess-form", lichess: fields) end

      good = %{
        round: "https://lichess.org/broadcast/test-open/round-1/#{FakeLichess.round_id()}",
        token: FakeLichess.token(),
        round_no: "1",
        enabled: "true"
      }

      # Tested before anything is saved.
      form.(good) |> render_submit(%{"intent" => "test"})
      eventually_html(view, fn _ -> has_element?(view, "#lichess-test-result") end)
      assert has_element?(view, "#lichess-check-account .state.ok")
      assert has_element?(view, "#lichess-check-account", "belongs to Arbiter")
      assert has_element?(view, "#lichess-check-scope .state.ok")
      assert has_element?(view, "#lichess-check-round", "Round 1")
      assert own().lichess_token in [nil, ""]
      assert FakeLichess.pushes() == []

      form.(%{good | token: "lip_wrong"}) |> render_submit(%{"intent" => "test"})

      eventually_html(view, fn _ ->
        has_element?(view, "#lichess-check-account .state.bad", "Token")
      end)

      assert has_element?(view, "#lichess-check-account", "does not know this token")

      FakeLichess.scopes("challenge:read")
      form.(good) |> render_submit(%{"intent" => "test"})

      eventually_html(view, fn _ ->
        has_element?(view, "#lichess-check-scope", "lacks the study:write permission")
      end)

      FakeLichess.scopes("study:write")

      assert form.(%{good | round: "round one"}) |> render_submit() =~ "not a Lichess round"
      assert own().lichess_round_id in [nil, ""]

      html = form.(good) |> render_submit()
      assert own().lichess_round_id == FakeLichess.round_id()
      assert own().lichess_token == FakeLichess.token()
      assert Destination.enabled?(LichessBroadcast)
      # Only the ends of the token are ever shown.
      assert html =~ "lip_...cdef"
      refute html =~ FakeLichess.token()
      refute render(view) =~ FakeLichess.token()
      assert has_element?(view, "#lichess-round[value='#{FakeLichess.round_id()}']")

      # An empty token field keeps the stored one.
      form.(%{good | token: "", enabled: "false"}) |> render_submit()
      assert own().lichess_token == FakeLichess.token()
      refute Destination.enabled?(LichessBroadcast)

      view |> element("#clear-lichess") |> render_click()
      assert own().lichess_token == ""
      refute has_element?(view, "#clear-lichess")
    end

    test "Outbox: each destination with its own line, its own switch and its own 'send now'", %{
      conn: conn
    } do
      FakeLichess.install()
      {:ok, view, _html} = live(conn, ~p"/outbox")

      assert has_element?(view, "#destinations #dest-openresults", "Results server")
      assert has_element?(view, "#dest-lichess", "Lichess broadcast")
      assert has_element?(view, "#dest-waiting-lichess", "0 waiting")

      game = Games.ensure(1, 1)
      {game, _} = Games.apply_event(game, {:moves, [%{san: "e4", flags: [], clock: nil}]}, 1_000)
      Outbox.enqueue(game, nil, false)
      eventually_html(view, fn _ -> has_element?(view, "#dest-waiting-lichess", "1 waiting") end)
      assert has_element?(view, "#dest-waiting-openresults", "1 waiting")

      # One goes out; the other keeps what it has.
      assert {:empty, 1} = LichessBroadcast.deliver()
      eventually_html(view, fn _ -> has_element?(view, "#dest-waiting-lichess", "0 waiting") end)
      assert has_element?(view, "#dest-waiting-openresults", "1 waiting")

      # Nothing waits for Lichess just now: the button cannot do anything, and
      # says so beside it - and pressed anyway, the answer is the same.
      assert has_element?(view, "#dest-send-lichess[disabled]")
      assert has_element?(view, "#dest-send-why-lichess", "Nothing is waiting")

      assert render_click(view, "dest_send", %{"id" => "lichess"}) =~
               "Lichess broadcast: Nothing is waiting."

      view |> element("#dest-toggle-lichess") |> render_click()
      refute Destination.enabled?(LichessBroadcast)
      assert has_element?(view, "#dest-state-lichess", "Switched off")
      assert has_element?(view, "#dest-send-lichess[disabled]")
      view |> element("#dest-toggle-lichess") |> render_click()
      assert Destination.enabled?(LichessBroadcast)

      view |> element("#dest-toggle-openresults") |> render_click()
      refute Destination.enabled?(Alnasl.Destination.OpenResults)
      assert has_element?(view, "#dest-state-openresults", "Switched off")
      view |> element("#dest-toggle-openresults") |> render_click()

      own_put(lichess_token: "")
      {:ok, view, _html} = live(conn, ~p"/outbox")
      assert has_element?(view, "#dest-state-lichess", "Not set up")
    end
  end

  test "Help explains which board is which, the phone, and Lichess both ways - in both languages",
       %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/help")

    for id <- ~w(help-which help-phone help-lichess),
        do: assert(has_element?(view, "##{id}"))

    assert html =~ "Number the boards with your phone"
    assert html =~ "/live/&lt;round&gt;/pgn"

    Settings.put("locale", "nl")
    {:ok, _view, html} = live(conn, ~p"/help")
    assert html =~ "Welk bord is welk"
    assert html =~ "Nummer de borden met je telefoon"
    assert html =~ "Uitzenden op Lichess"
  end
end
