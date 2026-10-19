defmodule AlnaslWeb.SignalTest do
  @moduledoc """
  The Signal column of the Boards page: a loop board's answered against
  missed (a bridge's one-a-second answer counts for as many as it says), a
  board on a port of its own by how often it dropped.
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
  end

  defp stats(board), do: Boards.snapshot(board.id).stats

  test "an answer that stands for many counts as many, and a plain one as one" do
    board = still("bridged")
    say(board, {:poll, :ok, 59})
    say(board, {:poll, :ok})
    say(board, {:poll, :missed})
    assert %{polls_ok: 60, polls_missed: 1} = stats(board)
  end

  test "a loop board shows a percentage of what it answered, not of what was sent",
       %{conn: conn} do
    board = still("loop")
    say(board, {:info, %{loop_number: 12_799}})
    say(board, {:poll, :ok, 95})
    for _ <- 1..5, do: say(board, {:poll, :missed})
    _ = stats(board)

    {:ok, view, _html} = live(conn, ~p"/boards")
    assert has_element?(view, "#board-#{board.id} td.b-signal .meter")
    assert render(view) =~ "95%"
  end

  test "a board on a port of its own shows how often it dropped, not a percentage",
       %{conn: conn} do
    board = still("alone")
    for _ <- 1..10, do: say(board, {:poll, :ok})
    say(board, {:poll, :missed})
    say(board, {:poll, :missed})
    _ = stats(board)

    {:ok, view, _html} = live(conn, ~p"/boards")
    refute has_element?(view, "#board-#{board.id} td.b-signal .meter")
    assert has_element?(view, "#board-#{board.id} td.b-signal", "dropped 2 times")
  end
end
