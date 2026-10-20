defmodule Alnasl.FairPlayFixtures do
  @moduledoc """
  Games for the fair-play tests: a legal game of random moves (deterministic
  for a seed), a tournament with a pairing document that gives ratings, a
  game stored the way the tracker stores one, and a fake engine function.
  """

  alias Alnasl.{Chess, Games, Repo, Tournaments}
  alias Alnasl.FairPlay.Setting

  @doc "`n` legal SANs of random play from the start position, the same ones for the same seed."
  def random_sans(n, seed \\ 1) do
    :rand.seed(:exsss, {seed, seed * 7, seed * 13})
    {:ok, pos} = Chess.parse_fen(Chess.start_fen())
    walk(pos, n, [])
  end

  defp walk(_pos, 0, acc), do: Enum.reverse(acc)

  defp walk(pos, n, acc) do
    case Chess.legal_moves(pos) do
      [] ->
        Enum.reverse(acc)

      moves ->
        move = Enum.random(moves)
        walk(Chess.apply_move(pos, move), n - 1, [Chess.san(pos, move) | acc])
    end
  end

  @doc "A tournament of this box's own with a document: players 1 (white) and 2 (black), rated, one game on board 1 of round 1."
  def rated_tournament(white_rating \\ 2100, black_rating \\ 2000) do
    document = %{
      "players" => [
        %{"id" => 1, "name" => "White Player", "rating" => white_rating},
        %{"id" => 2, "name" => "Black Player", "rating" => black_rating}
      ],
      "rounds" => [
        %{
          "number" => 1,
          "boards" => [
            %{"board" => 1, "white" => 1, "black" => 2, "game" => "g1", "kind" => "game"}
          ]
        }
      ]
    }

    Tournaments.update!(Tournaments.default(), %{document: Jason.encode!(document)})
  end

  @doc "A game on board `board` of round `round` with these `sans`, stored as the tracker does."
  def game(tournament, sans, opts \\ []) do
    round = Keyword.get(opts, :round, 1)
    board = Keyword.get(opts, :board, 1)

    game =
      Games.ensure(tournament.id, round, board, %{
        white: "White Player",
        black: "Black Player",
        remote_white: 1,
        remote_black: 2
      })

    plies = Enum.map(sans, &%{san: &1, flags: Keyword.get(opts, :flags, []), clock: nil})
    {game, _} = Games.apply_event(game, {:moves, plies}, System.os_time(:millisecond))
    game
  end

  @doc "Appends plies to a stored game."
  def more(game, sans, flags \\ []) do
    plies = Enum.map(sans, &%{san: &1, flags: flags, clock: nil})
    {game, _} = Games.apply_event(game, {:moves, plies}, System.os_time(:millisecond))
    game
  end

  @doc """
  An engine function that says the move played is the best one by a hair,
  with three others behind it, and tells the test process which positions
  it was asked about.
  """
  def engine(test_pid \\ self()) do
    fn position, played ->
      send(test_pid, {:asked, length(position.moves), played})

      {:ok,
       %{
         best: [
           %{move: played, cp: 30},
           %{move: "a2a3", cp: 20},
           %{move: "b2b3", cp: 10},
           %{move: "c2c3", cp: 0}
         ],
         played_cp: 30
       }}
    end
  end

  @doc "Every `{:asked, ply_count, move}` waiting in the mailbox, in order."
  def asked do
    receive do
      {:asked, count, move} -> [{count, move} | asked()]
    after
      0 -> []
    end
  end

  def setting(attrs \\ %{}) do
    struct!(
      %Setting{
        hall_id: Alnasl.Halls.own_id(),
        enabled: true,
        engine_id: "sf19",
        engine_path: "/engine",
        engine_version: "19",
        engine_bench: 2_497_913,
        nodes: 1_000_000
      },
      attrs
    )
  end

  @doc "Switches fair play on in the hall with an engine file that exists (the fake one)."
  def switch_on(hall_id, path) do
    Repo.insert!(
      %Setting{
        hall_id: hall_id,
        enabled: true,
        engine_id: "sf19",
        engine_path: path,
        engine_version: "19",
        engine_bench: 2_497_913,
        nodes: 1_000
      },
      on_conflict: :replace_all,
      conflict_target: :hall_id
    )
  end
end
