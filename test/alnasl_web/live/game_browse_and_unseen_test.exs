defmodule AlnaslWeb.GameBrowseAndUnseenTest do
  @moduledoc """
  A board's page: stepping back through the moves while the game goes on,
  and the warning for a piece that is not seen where it stands.
  """

  use AlnaslWeb.SiteCase

  setup %{conn: conn} do
    board = fake_dgt("FAKE1", %{round: 1, board_no: 3})
    eventually(fn -> Boards.snapshot(board.id).connected? end)
    play_on("FAKE1", board.id, ~w(d4 d5 Nc3 Nf6 Nf3))
    {:ok, view, _html} = live(conn, ~p"/round/1/board/3")
    {:ok, board: board, view: view}
  end

  defp position(sans), do: Position.to_text(List.last(boards_after(sans)))

  describe "looking back" do
    test "the page follows the game until asked otherwise", %{view: view} do
      assert has_element?(view, "#move-nav")
      assert has_element?(view, "#board-certain")
      refute has_element?(view, "#looking-back")
      assert has_element?(view, "#move-list[data-follow=true]")
      assert has_element?(view, "#nav-live[disabled]")
      assert has_element?(view, "#nav-forward[disabled]")
      assert has_element?(view, "#ply-5[aria-current=true]")
    end

    test "Left and Right step through the moves, Home and End go to the ends", %{view: view} do
      render_hook(view, "nav", %{"to" => "back"})
      assert has_element?(view, "#looking-back #board-at")
      assert has_element?(view, "#ply-4.at[aria-current=true]")
      refute has_element?(view, "#ply-5.at")
      assert has_element?(view, "#nav-at", "4 of 5")
      assert has_element?(view, "#move-list[data-follow=false]")

      render_hook(view, "nav", %{"to" => "back"})
      assert has_element?(view, "#ply-3.at")

      render_hook(view, "nav", %{"to" => "start"})
      assert has_element?(view, "#nav-at", "0 of 5")
      refute has_element?(view, ".ply.at")
      assert has_element?(view, "#nav-back[disabled]")
      # Further back than the start is the start.
      render_hook(view, "nav", %{"to" => "back"})
      assert has_element?(view, "#nav-at", "0 of 5")

      render_hook(view, "nav", %{"to" => "forward"})
      assert has_element?(view, "#ply-1.at")

      render_hook(view, "nav", %{"to" => "live"})
      refute has_element?(view, "#looking-back")
      assert has_element?(view, "#move-list[data-follow=true]")

      # Forward onto the last move is live again, not "looking at the last move".
      render_hook(view, "nav", %{"to" => "back"})
      render_hook(view, "nav", %{"to" => "forward"})
      refute has_element?(view, "#looking-back")
    end

    test "the buttons do the same, for a phone", %{view: view} do
      view |> element("#nav-back") |> render_click()
      assert has_element?(view, "#ply-4.at")
      view |> element("#nav-start") |> render_click()
      assert has_element?(view, "#nav-at", "0 of 5")
      view |> element("#nav-forward") |> render_click()
      assert has_element?(view, "#ply-1.at")
      view |> element("#nav-live") |> render_click()
      refute has_element?(view, "#looking-back")
    end

    test "a click on a move shows the position after it; on the last one, the game", %{view: view} do
      view |> element("#ply-2") |> render_click()
      assert has_element?(view, "#ply-2.at")
      assert has_element?(view, "#looking-back #board-at")
      assert has_element?(view, "#nav-at", "2 of 5")

      view |> element("#ply-5") |> render_click()
      refute has_element?(view, "#looking-back")
    end

    test "moves that arrive while looking back are listed, and the board stays where it is", %{
      view: view,
      board: board
    } do
      view |> element("#ply-2") |> render_click()
      play_on("FAKE1", board.id, ~w(Nc6), ~w(d4 d5 Nc3 Nf6 Nf3))

      eventually_html(view, fn _ -> has_element?(view, "#ply-6") end)
      assert has_element?(view, "#ply-2.at")
      assert has_element?(view, "#nav-at", "2 of 6")
      assert has_element?(view, "#looking-back")
      refute has_element?(view, "#nav-live[disabled]")

      view |> element("#nav-live") |> render_click()
      assert has_element?(view, "#ply-6[aria-current=true]")
      refute has_element?(view, "#looking-back")
    end

    test "a game cut shorter than the move being looked at is shown live again", %{
      view: view,
      board: board
    } do
      view |> element("#ply-4") |> render_click()
      Boards.undo(board.id)
      Boards.undo(board.id)
      eventually_html(view, fn _ -> not has_element?(view, "#ply-4") end)
      refute has_element?(view, "#looking-back")
    end

    test "the keys are the list's own hook, and fields keep theirs", %{view: view} do
      # The hook is on the list; it leaves keys typed into a field alone
      # (in the browser - here it is enough that it is the hook, not a
      # window binding that cannot tell).
      assert has_element?(view, "#move-list[phx-hook]")
      refute render(view) =~ "phx-window-keydown"
    end
  end

  describe "a piece not seen" do
    setup %{board: board, view: view} do
      # The knight is taken off f3, and Black plays ...Nc6 all the same.
      played = ~w(d4 d5 Nc3 Nf6 Nf3)
      f3 = Position.square_index("f3")
      {:ok, now} = Position.from_text(position(played))
      gone = put_elem(now, f3, nil)
      set_pieces("FAKE1", gone)
      eventually(fn -> Boards.snapshot(board.id).raw == Position.to_text(gone) end)

      {:ok, after_nc6} = Position.from_text(position(played ++ ["Nc6"]))
      set_pieces("FAKE1", put_elem(after_nc6, f3, nil))
      eventually(fn -> length(Boards.snapshot(board.id).plies) == 6 end)
      eventually_html(view, fn _ -> has_element?(view, "#ply-6") end)
      {:ok, f3: f3, bare: put_elem(after_nc6, f3, nil), whole: after_nc6}
    end

    test "the game goes on, live, with the warning on the board's page", %{
      view: view,
      board: board
    } do
      assert sans(board.id) == ~w(d4 d5 Nc3 Nf6 Nf3 Nc6)
      assert has_element?(view, "#game-state[data-state=live]")
      assert has_element?(view, "#game-unseen-0", "knight not seen on f3")
      assert has_element?(view, "#unseen-help[role=status]")
      refute has_element?(view, "#state-help[role=alert]")
      # A plain move in the list: the warning is said once, above.
      refute has_element?(view, "#ply-6 .flag")
      assert "piece.unseen" in log_kinds()
    end

    test "the move is sent on like any other", %{board: _board} do
      assert Outbox.drain() == :empty
      assert FakeIngest.game(1, 3).moves == ~w(d4 d5 Nc3 Nf6 Nf3 Nc6)
    end

    test "on the Round tile and in the Boards list too", %{conn: conn, board: board} do
      {:ok, round, _html} = live(conn, ~p"/round/1")
      assert has_element?(round, "#tile-3 #tile-unseen-3", "not seen on f3")
      assert has_element?(round, "#tile-3 [data-state=live]")

      {:ok, boards, _html} = live(conn, ~p"/boards")
      assert has_element?(boards, "#unseen-#{board.id}", "not seen on f3")
    end

    test "gone when the piece is seen again", %{view: view, board: board, whole: whole} do
      set_pieces("FAKE1", whole)
      eventually(fn -> Boards.snapshot(board.id).unseen == [] end)
      eventually_html(view, fn _ -> not has_element?(view, "#game-unseen-0") end)
      refute has_element?(view, "#unseen-help")
      assert "piece.accounted" in log_kinds()
    end

    test "gone when it comes down as its own move", %{view: view, board: board, bare: bare} do
      # White's turn: the knight lands on e5.
      set_pieces("FAKE1", put_elem(bare, Position.square_index("e5"), {:w, :n}))
      eventually(fn -> List.last(sans(board.id)) == "Ne5" end)
      eventually_html(view, fn _ -> not has_element?(view, "#game-unseen-0") end)
      assert has_element?(view, "#game-state[data-state=live]")
    end
  end

  test "Setup has the switch, on by default, and a board plays by it", %{conn: conn} do
    {:ok, setup, _html} = live(conn, ~p"/setup/advanced")
    assert has_element?(setup, "#tracker-unseen[checked]")
    assert has_element?(setup, "#tracker-unseen-note")

    setup
    |> form("#tracker-form", tracker: %{unseen_piece: "false"})
    |> render_submit()

    assert Settings.get("tracker")["unseen_piece"] == false
    refute Keyword.fetch!(Settings.tracker_opts(), :unseen_piece)
    {:ok, setup, _html} = live(conn, ~p"/setup/advanced")
    refute has_element?(setup, "#tracker-unseen[checked]")
  end
end
