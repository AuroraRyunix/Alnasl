defmodule AlnaslWeb.BoardsClockTest do
  @moduledoc """
  The clock beside a board, on the Boards page, before any game is linked:
  the arbiter checking a hall wants to see it is plugged in and talking.
  """

  use AlnaslWeb.SiteCase

  alias Alnasl.BoardServer

  defp still(name) do
    {:ok, board} =
      Boards.create(%{
        name: name,
        driver: "simulator",
        port: "sim-" <> name,
        options: %{"moves" => ~w(e4 e5), "speed" => 1, "start_delay_ms" => 600_000}
      })

    board
  end

  defp say(board, event) do
    send(BoardServer.whereis(board.id), {:driver, board.id, event})
    _ = Boards.snapshot(board.id)
  end

  test "a stopped clock shows both times on an unlinked board", %{conn: conn} do
    board = still("clocked")
    say(board, {:clock, %{white_ms: 5_400_000, black_ms: 5_390_000, running: :none}})

    {:ok, view, _html} = live(conn, ~p"/boards")
    assert has_element?(view, "#board-clock-#{board.id}", "1:30:00")
    assert has_element?(view, "#board-clock-#{board.id}", "1:29:50")
    refute has_element?(view, "#board-no-clock-#{board.id}")
  end

  test "a clock switched off takes its times with it", %{conn: conn} do
    board = still("unclocked")
    say(board, {:clock, %{white_ms: 5_400_000, black_ms: 5_390_000, running: :none}})
    say(board, {:info, %{clock: false}})

    {:ok, view, _html} = live(conn, ~p"/boards")
    refute has_element?(view, "#board-clock-#{board.id}")
  end
end
