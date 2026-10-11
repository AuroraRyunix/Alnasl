defmodule Alnasl.Position do
  @moduledoc """
  What a board reports: 64 squares, each a piece or nothing. No side to move,
  no castling rights - a board does not know those.

  The same layout as `Alnasl.Chess`: a 64-tuple, index 0 = a8 through
  63 = h1, each entry `nil` or `{colour, kind}`. As text it is 64 characters,
  FEN letters and `.` for an empty square, which is how the capture files and
  the database hold it.
  """

  alias Alnasl.Chess

  @type t :: tuple()

  @letters %{
    {:w, :p} => ?P,
    {:w, :n} => ?N,
    {:w, :b} => ?B,
    {:w, :r} => ?R,
    {:w, :q} => ?Q,
    {:w, :k} => ?K,
    {:b, :p} => ?p,
    {:b, :n} => ?n,
    {:b, :b} => ?b,
    {:b, :r} => ?r,
    {:b, :q} => ?q,
    {:b, :k} => ?k
  }
  @pieces Map.new(@letters, fn {piece, letter} -> {letter, piece} end)

  @doc "The starting position, as a board."
  def start, do: Chess.start().board

  @doc "A board with nothing on it."
  def empty, do: Tuple.duplicate(nil, 64)

  @doc "The board of a FEN, or `nil` when it is not one."
  def from_fen(fen) do
    case Chess.parse_fen(fen) do
      {:ok, pos} -> pos.board
      _error -> nil
    end
  end

  @doc "64 characters: FEN letters, `.` for empty."
  def to_text(board) when is_tuple(board) do
    for i <- 0..63, into: "" do
      case elem(board, i) do
        nil -> "."
        piece -> <<Map.fetch!(@letters, piece)>>
      end
    end
  end

  @doc "Reads what `to_text/1` writes. `:error` for anything else."
  def from_text(<<text::binary-size(64)>>) do
    squares =
      for <<c <- text>> do
        cond do
          c == ?. -> nil
          is_map_key(@pieces, c) -> Map.fetch!(@pieces, c)
          true -> :bad
        end
      end

    if :bad in squares, do: :error, else: {:ok, List.to_tuple(squares)}
  end

  def from_text(_other), do: :error

  @doc "The piece-placement field of a FEN."
  def placement(board) do
    0..7
    |> Enum.map_join("/", fn row ->
      0..7
      |> Enum.map(&elem(board, row * 8 + &1))
      |> Enum.chunk_by(&is_nil/1)
      |> Enum.map_join(fn
        [nil | _] = gap -> Integer.to_string(length(gap))
        pieces -> for piece <- pieces, into: "", do: <<Map.fetch!(@letters, piece)>>
      end)
    end)
  end

  @doc """
  A FEN for a board that is all there is to go on: a position set by hand
  from what the sensors read.

  A board does not know who may still castle, so the convention of every
  board editor is used: a side may castle wherever its king and that rook
  stand on their home squares. That offers a right a king or rook has in
  fact lost by moving and going back; the arbiter can strike it from the
  text before it is used. No en passant square, and the move counters
  start over. `turn` is the side to move (`:w` unless somebody knows).
  """
  def fen(board, turn \\ :w) do
    rights =
      for {king, rook, colour, letter} <- [
            {60, 63, :w, "K"},
            {60, 56, :w, "Q"},
            {4, 7, :b, "k"},
            {4, 0, :b, "q"}
          ],
          elem(board, king) == {colour, :k} and elem(board, rook) == {colour, :r},
          into: "",
          do: letter

    "#{placement(board)} #{turn} #{if rights == "", do: "-", else: rights} - 0 1"
  end

  @doc "The board as seen from the other side: a board plugged in turned round."
  def rotate(board), do: board |> Tuple.to_list() |> Enum.reverse() |> List.to_tuple()

  @doc "The squares on which two boards differ."
  def diff(a, b), do: for(i <- 0..63, elem(a, i) != elem(b, i), do: i)

  @doc "How many pieces stand on the board."
  def count(board), do: Enum.count(Tuple.to_list(board), & &1)

  @doc """
  Is `seen` the board `expected` with one or two pieces lifted and nothing
  else changed? A hand holding a piece, or a piece knocked off.
  """
  def in_hand?(expected, seen) do
    case diff(expected, seen) do
      [] -> false
      squares when length(squares) <= 2 -> Enum.all?(squares, &(elem(seen, &1) == nil))
      _more -> false
    end
  end

  @doc """
  What is wrong with `seen` when `expected` was wanted, in words an arbiter
  can act on: `[{:swapped, piece_a, square_a, piece_b, square_b} |
  {:wrong, square, expected_piece, seen_piece}]`. Two pieces standing on each
  other's squares are one finding, not two.
  """
  def problems(expected, seen) do
    squares = diff(expected, seen)

    {swaps, used} =
      Enum.reduce(squares, {[], MapSet.new()}, fn a, {found, used} = acc ->
        partner =
          Enum.find(squares, fn b ->
            b > a and b not in used and a not in used and
              elem(expected, a) != nil and elem(expected, b) != nil and
              elem(expected, a) == elem(seen, b) and elem(expected, b) == elem(seen, a)
          end)

        if partner,
          do:
            {[{:swapped, elem(expected, a), a, elem(expected, partner), partner} | found],
             used |> MapSet.put(a) |> MapSet.put(partner)},
          else: acc
      end)

    wrong =
      for sq <- squares, sq not in used, do: {:wrong, sq, elem(expected, sq), elem(seen, sq)}

    Enum.reverse(swaps) ++ wrong
  end

  @doc "`\"e4\"` for square index 36."
  def square_name(i), do: Chess.name(i)

  @doc "The square index of `\"e4\"`, or `nil`."
  def square_index(<<f, r>>) when f in ?a..?h and r in ?1..?8, do: (?8 - r) * 8 + (f - ?a)
  def square_index(_other), do: nil
end
