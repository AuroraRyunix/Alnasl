defmodule Alnasl.Tracker.Search do
  @moduledoc """
  Which legal moves turn the position we are sure of into the board we see?

  The tracker asks this when the board shows something that is not one legal
  move away: a move went by unseen, so there are two or more to find. The
  search is depth-first with iterative deepening - every sequence of 1 ply,
  then 2, up to `max_depth` - and stops at the first depth that has an answer,
  returning every answer of that length. The shortest explanation wins;
  `docs/design.md` says what that rule cannot see.

  It walks pseudo-legal moves (cheap) and proves the sequences it finds with
  the real legality check afterwards. What keeps it bounded:

  - a board can only lose pieces, and each ply takes at most one;
  - each ply of a side puts at most one of its pieces on a new square (two
    when it castles, once), so a side that still needs more arrivals than it
    has plies left is a dead branch;
  - in the last two plies each side has one move left, and that move must
    start on a square that still differs from the target;
  - a node budget and a time budget, after which the search gives up and
    says so.

  ## Guided by what was seen

  With `:touch` (a list of squares) only moves that start AND end on one of
  them are tried. The tracker passes every square that read differently at
  any moment since the position it is sure of: a move that was made while
  the board was being read changed both its squares in some reading, so
  nothing that was seen is left out - and the walk becomes a handful of
  moves a ply instead of thirty, which is what lets it go ten plies deep.
  What it cannot find is a move one of whose squares was never read
  differently: a capture and its recapture on one square between two scans.

  ## Evidence

  With `:evidence` (a list of squares) a move is tried only when the piece
  that makes it LEFT a square the readings saw change - its square is in
  the list - or has already moved earlier in the same line. A piece that
  stood on its square in every reading did not move: a bishop that never
  left f1 does not go to a6 and back to let the other side move twice.
  This is the widest search the tracker makes of a board it was connected
  to. Without `:touch` and without `:evidence` every legal move is tried:
  only for a stretch in which the board was not heard at all.

  ## Never out and back

  One side moving a piece from A to B and, with its very next move, from B
  back to A, taking nothing either way, is not a line: it is two tempi
  spent on nothing, which is what a search reaches for when the truth is
  that somebody moved out of turn. No walk returns one.

  (`out_and_back: true` asks for them all the same. The tracker does, once,
  to count: a game may really have a king stepping aside and back, and when
  such a line exists beside the one line found, that one is not the only
  explanation and must not be marked as if it were.)

  The board compared is the PHYSICAL one (`phys`): what the sensors should
  show, which differs from the position only where a pawn was left standing
  on its promotion square.
  """

  alias Alnasl.Chess

  @type step :: {Chess.move(), [atom()]}
  @type found :: %{steps: [step()], pos: Chess.position(), phys: tuple()}

  @doc """
  `{:ok, [found], nodes}` with every shortest sequence of `min_depth..max_depth`
  plies from `pos` that makes the board read `target` (an empty list when
  there is none), or `{:budget, nodes}` when the node budget ran out first.

  Options: `:min_depth` (1), `:max_depth` (4), `:max_nodes` (200_000),
  `:max_ms` (no limit), `:touch` and `:evidence` (see above; `nil` for
  no such limit),
  `:unseen` (squares whose piece the board does not show),
  `:promotion_default` (`:q`, the piece assumed when a pawn is left on its
  last rank; `nil` to never assume).
  """
  @spec find(Chess.position(), tuple(), tuple(), keyword()) ::
          {:ok, [found()], non_neg_integer()} | {:budget, non_neg_integer()}
  def find(pos, phys, target, opts \\ []) do
    min = Keyword.get(opts, :min_depth, 1)
    max = Keyword.get(opts, :max_depth, 4)

    ctx = %{
      target: target,
      max_nodes: Keyword.get(opts, :max_nodes, 200_000),
      default: Keyword.get(opts, :promotion_default, :q),
      # Squares on which the position has a piece the board does not show.
      unseen: Keyword.get(opts, :unseen, []),
      touch: touch(Keyword.get(opts, :touch)),
      evidence: Keyword.get(opts, :evidence),
      out_and_back: Keyword.get(opts, :out_and_back, false),
      until:
        case Keyword.get(opts, :max_ms) do
          nil -> nil
          ms -> System.monotonic_time(:millisecond) + ms
        end
    }

    Process.put(:alnasl_search_nodes, 0)

    try do
      found =
        Enum.find_value(min..max//1, [], fn depth ->
          if feasible?(pos.turn, phys, depth, target) do
            case dfs(pos, phys, depth, [], [], ctx) do
              [] -> nil
              found -> found
            end
          end
        end)

      {:ok, found, Process.get(:alnasl_search_nodes)}
    catch
      :alnasl_search_budget -> {:budget, Process.get(:alnasl_search_nodes)}
    after
      Process.delete(:alnasl_search_nodes)
    end
  end

  @doc """
  What the board shows after `move`: every way the sensors may read it, each
  with the flags that reading earns. One way for every move but a promotion
  to the default piece, which may also be a pawn left on the last rank
  (`[:assumed]`).
  """
  @spec outcomes(tuple(), Chess.move(), Chess.colour(), atom() | nil) :: [{tuple(), [atom()]}]
  def outcomes(phys, move, colour, default) do
    # Nothing on the square it leaves: a piece the board had lost sight of.
    piece = elem(phys, move.from) || {colour, move.piece}

    base =
      phys
      |> put_elem(move.from, nil)
      |> then(fn board ->
        case move.kind do
          :ep ->
            put_elem(board, move.to + if(colour == :w, do: 8, else: -8), nil)

          :castle_k ->
            board |> put_elem(move.to + 1, nil) |> put_elem(move.to - 1, {colour, :r})

          :castle_q ->
            board |> put_elem(move.to - 2, nil) |> put_elem(move.to + 1, {colour, :r})

          _plain ->
            board
        end
      end)

    cond do
      move.promo == nil ->
        [{put_elem(base, move.to, piece), []}]

      move.promo == default ->
        [
          {put_elem(base, move.to, {colour, move.promo}), []},
          {put_elem(base, move.to, {colour, :p}), [:assumed]}
        ]

      true ->
        [{put_elem(base, move.to, {colour, move.promo}), []}]
    end
  end

  defp touch(nil), do: nil
  defp touch(squares), do: squares |> Enum.uniq() |> Enum.sort() |> List.to_tuple()

  # --- the walk ----------------------------------------------------------------

  # `moved`: where the pieces that have moved in this line now stand.
  defp dfs(pos, phys, remaining, acc, moved, ctx) do
    count_node(ctx)
    squares = differing(phys, ctx.target)

    if remaining == 1 do
      if length(squares) > 4, do: [], else: last_ply(pos, phys, squares, acc, moved, ctx)
    else
      moves =
        cond do
          remaining == 2 ->
            pos
            |> Chess.moves_from(own(squares, phys, pos.turn) ++ unseen(pos, phys, ctx))
            |> touching(ctx)

          ctx.touch ->
            pos |> Chess.moves_from(Tuple.to_list(ctx.touch)) |> touching(ctx)

          ctx.evidence ->
            Chess.moves_from(pos, Enum.uniq(ctx.evidence ++ moved))

          true ->
            Chess.pseudo_legal_moves(pos)
        end
        |> admissible(acc, moved, ctx)

      them = if pos.turn == :w, do: :b, else: :w

      Enum.flat_map(moves, fn move ->
        # The cheap test first: most moves leave a board that the plies left
        # can no longer repair, and never get as far as the legality check.
        alive =
          phys
          |> outcomes(move, pos.turn, ctx.default)
          |> Enum.filter(fn {board, _flags} ->
            feasible?(them, board, remaining - 1, ctx.target)
          end)

        if alive != [] and Chess.legal?(pos, move) do
          next = Chess.apply_move(pos, move)

          Enum.flat_map(alive, fn {board, flags} ->
            dfs(
              next,
              board,
              remaining - 1,
              [{move, flags} | acc],
              [move.to | List.delete(moved, move.from)],
              ctx
            )
          end)
        else
          []
        end
      end)
    end
  end

  defp last_ply(pos, phys, squares, acc, moved, ctx) do
    for move <-
          pos
          |> Chess.moves_from(own(squares, phys, pos.turn) ++ unseen(pos, phys, ctx))
          |> touching(ctx)
          |> admissible(acc, moved, ctx),
        move.to in squares,
        {board, flags} <- outcomes(phys, move, pos.turn, ctx.default),
        board == ctx.target,
        Chess.legal?(pos, move) do
      %{
        steps: Enum.reverse([{move, flags} | acc]),
        pos: Chess.apply_move(pos, move),
        phys: board
      }
    end
  end

  defp own(squares, phys, colour),
    do: Enum.filter(squares, &match?({^colour, _}, elem(phys, &1)))

  # A piece the board does not show may be the one that moved: its square
  # reads empty before and after, so it is not among those that differ.
  defp unseen(pos, phys, ctx),
    do: for(sq <- ctx.unseen, elem(phys, sq) == nil, elem(pos.board, sq) != nil, do: sq)

  # The moves a line may go on with: by a piece the readings saw leave its
  # square (or one that has moved in this line already), and not the
  # mover's last move undone.
  defp admissible(moves, acc, moved, ctx) do
    moves =
      case ctx.evidence do
        nil -> moves
        squares -> Enum.filter(moves, &(&1.from in squares or &1.from in moved))
      end

    case acc do
      [_theirs, {mine, _flags} | _] when mine.capture == nil and not ctx.out_and_back ->
        Enum.reject(moves, &(&1.from == mine.to and &1.to == mine.from and &1.capture == nil))

      _first_move ->
        moves
    end
  end

  defp touching(moves, %{touch: nil}), do: moves

  defp touching(moves, %{touch: touch}) do
    squares = Tuple.to_list(touch)
    Enum.filter(moves, &(&1.from in squares and &1.to in squares))
  end

  defp differing(a, b), do: for(i <- 0..63, elem(a, i) != elem(b, i), do: i)

  defp count_node(ctx) do
    nodes = Process.get(:alnasl_search_nodes) + 1
    Process.put(:alnasl_search_nodes, nodes)
    if nodes > ctx.max_nodes, do: throw(:alnasl_search_budget)

    if ctx.until && rem(nodes, 256) == 0 && System.monotonic_time(:millisecond) > ctx.until,
      do: throw(:alnasl_search_budget)
  end

  # Can `remaining` plies still get from `phys` to `target`? Necessary
  # conditions only - a branch that fails one is dead, one that passes may
  # still be. `us` moves first, so it has the larger half of the plies.
  defp feasible?(us, phys, remaining, target) do
    ours = div(remaining + 1, 2)
    theirs = div(remaining, 2)

    {lost_us, lost_them, arrive_us, arrive_them} =
      Enum.reduce(0..63, {0, 0, 0, 0}, fn i, {lu, lt, au, at} = acc ->
        now = elem(phys, i)
        want = elem(target, i)

        if now == want do
          acc
        else
          {lu, lt} = tally(now, us, {lu, lt}, 1)
          {lu, lt} = tally(want, us, {lu, lt}, -1)

          case want do
            {^us, _} -> {lu, lt, au + 1, at}
            {_, _} -> {lu, lt, au, at + 1}
            nil -> {lu, lt, au, at}
          end
        end
      end)

    lost_us >= 0 and lost_them >= 0 and lost_us <= theirs and lost_them <= ours and
      arrive_us <= ours + min(ours, 1) and arrive_them <= theirs + min(theirs, 1)
  end

  defp tally(nil, _us, counts, _by), do: counts
  defp tally({us, _}, us, {lu, lt}, by), do: {lu + by, lt}
  defp tally({_them, _}, _us, {lu, lt}, by), do: {lu, lt + by}
end
