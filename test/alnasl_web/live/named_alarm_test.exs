defmodule AlnaslWeb.NamedAlarmTest do
  @moduledoc """
  A move out of turn and a move that is not legal: said by name on the
  board's page, on the Round tile and in the log, and gone when the piece
  is back.
  """

  use AlnaslWeb.SiteCase

  setup %{conn: conn} do
    board = fake_dgt("FAKE1", %{round: 1, board_no: 3})
    eventually(fn -> Boards.snapshot(board.id).connected? end)
    played = play_on("FAKE1", board.id, ~w(e4 e5))
    {:ok, view, _html} = live(conn, ~p"/round/1/board/3")
    {:ok, board: board, view: view, now: List.last(boards_after(played))}
  end

  defp sq(name), do: Position.square_index(name)

  defp move(board, from, to),
    do: board |> put_elem(sq(to), elem(board, sq(from))) |> put_elem(sq(from), nil)

  test "Black's knight to c6 with White to move: named, nothing added, gone when it is back", %{
    conn: conn,
    view: view,
    board: board,
    now: now
  } do
    set_pieces("FAKE1", move(now, "b8", "c6"))

    eventually_html(view, fn _ -> has_element?(view, "#game-state[data-state=out_of_sync]") end)

    assert has_element?(
             view,
             "#state-help[role=alert]",
             "Black moved (Nc6), but it is White's turn"
           )

    assert has_element?(view, "#state-help #alarm-missing-move")
    assert sans(board.id) == ~w(e4 e5)
    assert "move.out_of_turn" in log_kinds()
    refute "board.out_of_sync" in log_kinds()

    {:ok, round, _html} = live(conn, ~p"/round/1")
    assert has_element?(round, "#tile-alarm-3", "Black moved (Nc6)")

    {:ok, log, _html} = live(conn, ~p"/log")
    assert render(log) =~ "Out of turn: Black moved Nc6 (b8-c6) with White to move"

    # "A move is missing before this": to where moves are typed.
    view |> element("#alarm-missing-move") |> render_click()
    assert_push_event(view, "alnasl:go", %{to: "type-moves-form"})

    set_pieces("FAKE1", now)
    eventually_html(view, fn _ -> has_element?(view, "#game-state[data-state=live]") end)
    refute has_element?(view, "#alarm-missing-move")
    assert sans(board.id) == ~w(e4 e5)
    assert Enum.all?(Boards.snapshot(board.id).plies, &(&1.flags == []))
    assert "board.resumed" in log_kinds()
  end

  test "a bishop through its own pawn: the piece, the squares, and why", %{
    conn: conn,
    view: view,
    board: board,
    now: now
  } do
    set_pieces("FAKE1", move(now, "c1", "g5"))

    eventually_html(view, fn _ ->
      has_element?(view, "#state-help", "A move that is not legal: white bishop c1-g5")
    end)

    assert has_element?(view, "#state-help", "Something stands in its way")
    assert "move.illegal" in log_kinds()
    assert sans(board.id) == ~w(e4 e5)

    {:ok, round, _html} = live(conn, ~p"/round/1")
    assert has_element?(round, "#tile-alarm-3", "white bishop c1-g5")

    {:ok, log, _html} = live(conn, ~p"/log")
    assert render(log) =~ "Not a legal move: white bishop c1-g5"

    set_pieces("FAKE1", now)
    eventually_html(view, fn _ -> has_element?(view, "#game-state[data-state=live]") end)
    play_on("FAKE1", board.id, ~w(Nf3), ~w(e4 e5))
    assert sans(board.id) == ~w(e4 e5 Nf3)
  end

  test "two moves in one reading, by pieces that both left their squares, are not an alarm at all",
       %{
         view: view,
         board: board,
         now: now
       } do
    # The board shows Black's Nc6, and White's Nf3 before it, in one reading.
    set_pieces("FAKE1", now |> move("g1", "f3") |> move("b8", "c6"))
    eventually(fn -> sans(board.id) == ~w(e4 e5 Nf3 Nc6) end)
    # Both pieces were seen to leave their squares: found, not asked.
    assert has_element?(view, "#game-state")
  end

  test "in Dutch", %{view: _view, board: _board, now: now, conn: conn} do
    Settings.put("locale", "nl")
    set_pieces("FAKE1", move(now, "b8", "c6"))
    {:ok, view, _html} = live(conn, ~p"/round/1/board/3")

    eventually_html(view, fn _ ->
      has_element?(view, "#state-help", "Zwart heeft gezet (Nc6), maar wit is aan zet")
    end)
  end
end
