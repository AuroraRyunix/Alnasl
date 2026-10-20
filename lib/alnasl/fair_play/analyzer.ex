defmodule Alnasl.FairPlay.Analyzer do
  @moduledoc """
  Turns one game into one record per ply: the position, the move played
  (as UCI), the engine's best lines there, what the played move cost, and
  whether the ply counts (`Alnasl.FairPlay.Selection`).

  The engine is a function, not a process, so this module can be tested
  without one and so the live queue and the calibration task can each hand
  in whatever engine they hold (`Alnasl.FairPlay.Uci.engine_fun/2`):

      engine.(%{start_fen: fen | nil, moves: [uci]}, played_uci)
      #=> {:ok, %{best: [%{move, cp}], played_cp: cp}} | {:error, reason}

  The position goes to the engine as the start position and the moves, not
  as a FEN, so the engine knows which positions have been seen: a move that
  repeats into a draw is priced as one. The calibration does it the same
  way, which is the point.

  The work is in two steps, because the live queue needs them apart:
  `prepare/1` replays the game with `Alnasl.Chess` (no chess library: the
  box already has a move generator it trusts) and applies every skip rule
  that needs no engine; `evaluate/4` asks the engine about the plies that
  are still counted and applies the rest. A skipped ply never costs a
  search. `analyse/3` is both.

  ## The game

      %{
        start_fen: fen | nil,
        plies: [%{san: "Nf3", flags: [atom], clock: %{white_ms, black_ms} | nil}
                | %{san: "Nf3", flags: [atom], clock_ms: ms | nil}],
        white_rating: integer | nil,
        black_rating: integer | nil,
        result_confirmed: boolean
      }

  A ply's clock is either the board clock's reading when the move was
  taken (both sides, as `Alnasl.Games.plies/1` has it) or the mover's own
  time after the move (a PGN's `[%clk]`). The mover's time *before* the
  move is then the previous ply's reading of the mover's side, or the
  mover's own time after their previous move. Increments are ignored: a
  player with 59 s and a 30 s increment is still a player with 59 s.

  `from_game/2` builds this from a stored `Alnasl.Games.Game`.
  """

  alias Alnasl.Chess
  alias Alnasl.FairPlay.Selection

  @type engine_line :: %{move: String.t(), cp: integer()}

  @type ply_record :: %{
          ply: pos_integer(),
          colour: :white | :black,
          move_number: pos_integer(),
          side_ply: pos_integer(),
          fen: String.t(),
          fen_key: String.t(),
          san: String.t(),
          played_uci: String.t(),
          legal_count: non_neg_integer(),
          rating: integer() | nil,
          flags: [atom()],
          material: non_neg_integer(),
          clock_before_ms: non_neg_integer() | nil,
          best: [engine_line()] | nil,
          played_cp: integer() | nil,
          rank: pos_integer() | nil,
          gap: integer() | nil,
          near_count: non_neg_integer() | nil,
          skip: Selection.reason() | nil
        }

  @values %{p: 1, n: 3, b: 3, r: 5, q: 9, k: 0}

  # "Within 0.30 of the best" (plan, §5).
  @near_cp 30

  @doc "Both steps: `prepare/1`, then `evaluate/4` on every ply still counted."
  @spec analyse(map(), function(), keyword()) ::
          {:ok, [ply_record()]} | {:error, {pos_integer(), String.t()} | String.t()}
  def analyse(game, engine, opts \\ []) do
    with {:ok, records} <- prepare(game) do
      {:ok, evaluate(game, records, engine, opts)}
    end
  end

  @doc """
  Replays the game and builds the records, with every skip rule applied
  that needs no engine. `{:error, {ply, message}}` names the first move
  that is not legal: the tracker should never store one, but a PGN may.
  """
  @spec prepare(map()) ::
          {:ok, [ply_record()]} | {:error, {pos_integer(), String.t()} | String.t()}
  def prepare(game) do
    start = game[:start_fen] || Chess.start_fen()

    with {:ok, pos} <- Chess.parse_fen(start),
         {:ok, records} <- replay(pos, game) do
      {:ok, Selection.before_engine(records, result_confirmed: game[:result_confirmed] == true)}
    end
  end

  defp replay(pos, game) do
    plies = Enum.with_index(game.plies || [], 1)

    plies
    |> Enum.reduce_while({:ok, pos, %{white: 0, black: 0}, [], nil}, fn {ply, index},
                                                                        {:ok, pos, sides, acc,
                                                                         prev} ->
      legal = Chess.legal_moves(pos)

      case Chess.parse_san(pos, ply.san) do
        {:ok, move} ->
          colour = if pos.turn == :w, do: :white, else: :black
          sides = Map.update!(sides, colour, &(&1 + 1))

          record = %{
            ply: index,
            colour: colour,
            move_number: pos.fullmove,
            side_ply: sides[colour],
            fen: Chess.to_fen(pos),
            fen_key: fen_key(pos, legal),
            san: Chess.san(pos, move),
            played_uci: uci(move),
            legal_count: length(legal),
            rating: rating(game, colour),
            flags: ply[:flags] || [],
            material: material(pos),
            clock_before_ms: clock_before(colour, prev, acc),
            best: nil,
            played_cp: nil,
            rank: nil,
            gap: nil,
            near_count: nil,
            skip: nil
          }

          {:cont,
           {:ok, Chess.apply_move(pos, move), sides,
            [Map.put(record, :clock, own_clock(ply, colour)) | acc], ply}}

        {:error, message} ->
          {:halt, {:error, {index, message}}}
      end
    end)
    |> case do
      {:ok, _pos, _sides, acc, _prev} ->
        {:ok, acc |> Enum.reverse() |> Enum.map(&Map.delete(&1, :clock))}

      error ->
        error
    end
  end

  defp rating(game, :white), do: positive(game[:white_rating])
  defp rating(game, :black), do: positive(game[:black_rating])

  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(_), do: nil

  # The mover's own time after this move, as far as this ply says.
  defp own_clock(ply, colour) do
    case ply do
      %{clock: %{} = clock} -> clock[if(colour == :white, do: :white_ms, else: :black_ms)]
      %{clock_ms: ms} -> ms
      _ -> nil
    end
  end

  # Before the move: the previous ply's board-clock reading of the mover's
  # side, which is when their clock started running; failing that, the
  # mover's own time after their previous move.
  defp clock_before(colour, prev, acc) do
    key = if colour == :white, do: :white_ms, else: :black_ms

    from_board =
      case prev do
        %{clock: %{} = clock} -> Map.get(clock, key)
        _ -> nil
      end

    from_board ||
      case Enum.find(acc, &(&1.colour == colour)) do
        %{clock: ms} -> ms
        nil -> nil
      end
  end

  @doc "A move as UCI: from, to, and the promotion piece. Castling is the king's move (`e1g1`)."
  @spec uci(Chess.move()) :: String.t()
  def uci(move) do
    Chess.name(move.from) <>
      Chess.name(move.to) <> if(move.promo, do: Atom.to_string(move.promo), else: "")
  end

  @doc """
  What makes two positions the same for repetition: placement, side to
  move, castling, and the en-passant square only when a pawn can actually
  take there (as the Laws count it, and unlike a FEN, which notes it after
  every double step).
  """
  def fen_key(pos, legal \\ nil) do
    legal = legal || Chess.legal_moves(pos)
    [placement, turn, castling, _ep | _] = pos |> Chess.to_fen() |> String.split(" ")
    ep = if Enum.any?(legal, &(&1.kind == :ep)), do: Chess.name(pos.ep), else: "-"
    Enum.join([placement, turn, castling, ep], " ")
  end

  @doc "Material on the board in pawns (P 1, N 3, B 3, R 5, Q 9), both sides: 78 at the start."
  def material(pos) do
    pos.board
    |> Tuple.to_list()
    |> Enum.reduce(0, fn
      nil, sum -> sum
      {_colour, kind}, sum -> sum + @values[kind]
    end)
  end

  # --- the engine --------------------------------------------------------------

  @doc """
  Asks the engine about the plies still counted that have no answer yet
  (or only those in `only: [ply]`), fills in `best`, `played_cp`, `rank`,
  `gap` and `near_count`, and applies the rules that need them. A failed
  search leaves the ply skipped as `:no_analysis`: better a ply not counted
  than a ply counted on nothing.
  """
  @spec evaluate(map(), [ply_record()], function(), keyword()) :: [ply_record()]
  def evaluate(game, records, engine, opts \\ []) do
    only = Keyword.get(opts, :only)
    start = game[:start_fen]

    {done, _moves} =
      Enum.map_reduce(records, [], fn record, moves_before ->
        wanted? =
          record.skip == nil and record.best == nil and (only == nil or record.ply in only)

        record =
          if wanted? do
            position = %{start_fen: start, moves: Enum.reverse(moves_before)}

            record
            |> with_engine(engine.(position, record.played_uci))
            |> Selection.after_engine()
          else
            record
          end

        {record, [record.played_uci | moves_before]}
      end)

    done
  end

  defp with_engine(record, {:ok, %{best: [_ | _] = best} = answer}) do
    played_cp =
      case Enum.find(best, &(&1.move == record.played_uci)) do
        %{cp: cp} -> cp
        nil -> answer[:played_cp]
      end

    [%{cp: top} | others] = best
    index = Enum.find_index(best, &(&1.move == record.played_uci))

    %{
      record
      | best: best,
        played_cp: played_cp,
        rank: index && index + 1,
        gap:
          case others do
            [%{cp: second} | _] -> top - second
            [] -> nil
          end,
        near_count: Enum.count(others, &(&1.cp >= top - @near_cp)),
        skip: if(played_cp == nil, do: :no_analysis)
    }
  end

  defp with_engine(record, _error_or_empty), do: %{record | skip: :no_analysis}

  # --- from the database -------------------------------------------------------

  @doc """
  The game as `analyse/3` wants it, from a stored game and the two ratings
  (`nil` when a player has none). The result counts as confirmed once the
  arbiter has set a real one.
  """
  def from_game(%Alnasl.Games.Game{} = game, ratings) do
    %{
      start_fen: game.start_fen,
      plies:
        game
        |> Alnasl.Games.plies()
        |> Enum.map(&%{san: &1.san, flags: &1.flags, clock: &1.clock}),
      white_rating: ratings[:white],
      black_rating: ratings[:black],
      result_confirmed: game.result in ["1-0", "0-1", "1/2-1/2"]
    }
  end
end
