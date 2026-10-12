defmodule AlnaslWeb.FileController do
  @moduledoc "Files to take away: the PGN of a game or of a round, and a raw capture."

  use AlnaslWeb, :controller

  alias Alnasl.{Games, Recorder}
  alias AlnaslWeb.Scope

  def game(conn, %{"round" => round, "board" => board} = params) do
    with {round, ""} <- Integer.parse(round),
         {board, ""} <- Integer.parse(board),
         %{} = game <- one(Scope.tournament(params).id, round, board, params["game"]) do
      download(
        conn,
        Games.pgn(game),
        "round-#{round}-" <> Games.pgn_name(game),
        "application/x-chess-pgn"
      )
    else
      _missing -> send_resp(conn, 404, "no such game")
    end
  end

  def round(conn, %{"round" => round} = params) do
    case Integer.parse(round) do
      {round, ""} ->
        download(
          conn,
          Games.round_pgn(Scope.tournament(params).id, round),
          "round-#{round}.pgn",
          "application/x-chess-pgn"
        )

      _bad ->
        send_resp(conn, 404, "no such round")
    end
  end

  def capture(conn, %{"board" => board, "name" => name}) do
    with {board, ""} <- Integer.parse(board),
         %{path: path} <- Recorder.find(board, name) do
      Recorder.flush()

      conn
      |> put_resp_content_type("application/x-ndjson")
      |> put_resp_header("content-disposition", ~s(attachment; filename="board-#{board}-#{name}"))
      |> send_file(200, path)
    else
      _missing -> send_resp(conn, 404, "no such capture")
    end
  end

  # `?game=2`: an earlier (or later) game on that board; without it, the
  # one being played.
  defp one(tournament, round, board, nil), do: Games.current(tournament, round, board)

  defp one(tournament, round, board, number) do
    case Integer.parse(number) do
      {game_no, ""} -> Games.fetch(tournament, round, board, game_no)
      _bad -> nil
    end
  end

  defp download(conn, text, filename, type) do
    conn
    |> put_resp_content_type(type)
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> send_resp(200, text)
  end
end
