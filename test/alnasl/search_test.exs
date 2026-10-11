defmodule Alnasl.Tracker.SearchTest do
  @moduledoc """
  The recovery search: that it finds what is there, and that it is bounded
  when nothing is. The worst case is a board no sequence explains - the
  search has to exhaust every depth before it may say so.
  """

  use ExUnit.Case, async: true

  alias Alnasl.{Chess, Pgn, Position}
  alias Alnasl.Tracker.Search

  @moduletag timeout: 600_000

  defp after_sans(sans) do
    {:ok, plies} = Chess.replay(Chess.start_fen(), sans)
    {:ok, pos} = Chess.parse_fen(List.last(plies).fen)
    pos
  end

  test "finds the one sequence, and every sequence when there are several" do
    start = Chess.start()
    target = after_sans(~w(e4 e5 Qh5)).board
    assert {:ok, [found], _nodes} = Search.find(start, start.board, target, max_depth: 4)
    assert length(found.steps) == 3
    assert found.phys == target

    # d4, Nf6, c4 - or c4 first.
    target = after_sans(~w(d4 Nf6 c4)).board
    assert {:ok, found, _nodes} = Search.find(start, start.board, target, max_depth: 4)
    assert length(found) == 2
  end

  test "the shortest explanation is the one returned" do
    start = Chess.start()
    target = after_sans(~w(Nf3)).board
    assert {:ok, [%{steps: [_one]}], _} = Search.find(start, start.board, target, max_depth: 4)
  end

  test "gives up at the node budget and says so" do
    start = Chess.start()
    garbage = start.board |> put_elem(36, {:w, :q}) |> put_elem(28, {:b, :q})
    target = after_sans(~w(e4 e5 Nf3 Nc6 Bb5 a6)).board
    assert {:ok, [], _} = Search.find(start, start.board, garbage, max_depth: 4)
    assert {:budget, nodes} = Search.find(start, start.board, target, max_depth: 6, max_nodes: 20)
    assert nodes > 20
  end

  test "is bounded on boards nothing explains: worst case over 400 scrambled positions" do
    :rand.seed(:exsss, {4, 7, 11})
    games = Pgn.all_bundled()

    times =
      for n <- 1..400 do
        game = Enum.random(games)
        sans = Enum.take(game.moves, :rand.uniform(length(game.moves)))
        {:ok, plies} = Chess.replay(Chess.start_fen(), sans)
        {:ok, pos} = Chess.parse_fen(List.last(plies).fen)
        target = scramble(pos.board, rem(n, 3) + 1)
        started = System.monotonic_time(:microsecond)
        result = Search.find(pos, pos.board, target, max_depth: 4)
        us = System.monotonic_time(:microsecond) - started
        nodes = elem(result, tuple_size(result) - 1)
        refute match?({:budget, _}, result)
        {us, nodes}
      end

    {worst_us, _} = Enum.max_by(times, &elem(&1, 0))
    {_, worst_nodes} = Enum.max_by(times, &elem(&1, 1))
    mean_us = (times |> Enum.map(&elem(&1, 0)) |> Enum.sum()) / length(times)

    IO.puts(
      "\n  search, depth 4, 400 scrambled boards: worst #{Float.round(worst_us / 1000, 1)} ms, " <>
        "mean #{Float.round(mean_us / 1000, 1)} ms, worst #{worst_nodes} nodes"
    )

    assert worst_us < 5_000_000
    assert worst_nodes < 200_000
  end

  # Moves `count` random pieces (never a king) to random empty squares.
  defp scramble(board, count) do
    Enum.reduce(1..count, board, fn _i, board ->
      from = Enum.random(for i <- 0..63, match?({_, kind} when kind != :k, elem(board, i)), do: i)
      to = Enum.random(for i <- 8..55, elem(board, i) == nil, do: i)
      board |> put_elem(to, elem(board, from)) |> put_elem(from, nil)
    end)
  end

  test "outcomes: a promotion to the default piece may read as a pawn left standing" do
    {:ok, pos} = Chess.parse_fen("8/4P1k1/8/8/8/8/6K1/8 w - - 0 1")
    queen = Enum.find(Chess.legal_moves(pos), &(&1.promo == :q))
    knight = Enum.find(Chess.legal_moves(pos), &(&1.promo == :n))
    assert [{as_queen, []}, {as_pawn, [:assumed]}] = Search.outcomes(pos.board, queen, :w, :q)
    assert elem(as_queen, 4) == {:w, :q} and elem(as_pawn, 4) == {:w, :p}
    assert [{_, []}] = Search.outcomes(pos.board, knight, :w, :q)
    assert [{_, []}] = Search.outcomes(pos.board, queen, :w, nil)
    assert Position.count(as_pawn) == 3
  end
end
