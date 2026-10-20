defmodule Alnasl.FairPlay.Selection do
  @moduledoc """
  Which moves count (`docs/plan-fair-play.md`, §4), as pure functions over
  the records of `Alnasl.FairPlay.Analyzer`.

  A move is left out when it says nothing about the player, or when we are
  not sure it was played:

  | reason | the move |
  |---|---|
  | `:unrated` | by a player with no rating: no expectation to compare with |
  | `:tracker_guessed` | the tracker guessed it (red), or guessed any move before it in this game: after a wrong guess every position is fiction. A promotion piece the board never saw (`:assumed`) counts as a guess |
  | `:tracker_rewritten` | the tracker rewrote it, and the arbiter has not yet confirmed the game's result |
  | `:opening` | moves 1-8 of either side: book, not thought |
  | `:repetition` | from a position that stood on the board before |
  | `:forced` | the only legal move, or the best one is 2.00 or more better than the second |
  | `:time_trouble` | under 60 s on the mover's clock before it, when the clock is known |
  | `:decided` | the best line is beyond ±3.00 before the move: winning more is not suspicious |
  | `:no_analysis` | the engine gave no answer |

  Each skipped ply carries one reason, the first in that order: data
  doubts first, then what needs no engine, then what does. Reconstructed
  plies (`:recovered`, orange) do count: exactly one line of moves led to
  the position the board showed, so the moves are certain; only their
  timing is not, and the clock rule only reads the clock.
  """

  @type reason ::
          :unrated
          | :tracker_guessed
          | :tracker_rewritten
          | :opening
          | :repetition
          | :forced
          | :time_trouble
          | :decided
          | :no_analysis

  @reasons [
    :unrated,
    :tracker_guessed,
    :tracker_rewritten,
    :opening,
    :repetition,
    :forced,
    :time_trouble,
    :decided,
    :no_analysis
  ]

  @opening_moves 8
  @decided_cp 300
  @forced_gap_cp 200
  @time_trouble_ms 60_000

  @doc "Every reason, in the order they are tried."
  def reasons, do: @reasons

  @doc """
  The rules that need no engine, over a whole game's records in order.
  `result_confirmed: true` once the arbiter has confirmed the result.
  """
  @spec before_engine([map()], keyword()) :: [map()]
  def before_engine(records, opts \\ []) do
    confirmed? = Keyword.get(opts, :result_confirmed, false)

    {marked, _state} =
      Enum.map_reduce(records, %{guessed?: false, seen: MapSet.new()}, fn record, state ->
        guessed? = state.guessed? or guessed?(record)
        repeated? = MapSet.member?(state.seen, record.fen_key)

        skip =
          cond do
            record.skip != nil -> record.skip
            unrated?(record) -> :unrated
            guessed? -> :tracker_guessed
            rewritten?(record) and not confirmed? -> :tracker_rewritten
            opening?(record) -> :opening
            repeated? -> :repetition
            only_move?(record) -> :forced
            time_trouble?(record) -> :time_trouble
            true -> nil
          end

        {%{record | skip: skip},
         %{guessed?: guessed?, seen: MapSet.put(state.seen, record.fen_key)}}
      end)

    marked
  end

  @doc "The rules that need the engine's answer, for one record that has it."
  @spec after_engine(map()) :: map()
  def after_engine(%{skip: nil} = record) do
    cond do
      decided?(record) -> %{record | skip: :decided}
      forced_by_gap?(record) -> %{record | skip: :forced}
      true -> record
    end
  end

  def after_engine(record), do: record

  @doc "How many plies count, and how many were left out for each reason."
  @spec counts([map()]) :: %{counted: non_neg_integer(), skipped: %{reason() => pos_integer()}}
  def counts(records) do
    %{
      counted: Enum.count(records, &counted?/1),
      skipped: records |> Enum.reject(&counted?/1) |> Enum.frequencies_by(& &1.skip)
    }
  end

  @doc "A ply counts when nothing ruled it out and the engine has priced it."
  def counted?(%{skip: nil, best: [_ | _], played_cp: cp}) when is_integer(cp), do: true
  def counted?(_record), do: false

  # --- the rules, one by one ---------------------------------------------------

  def unrated?(record), do: not (is_integer(record.rating) and record.rating > 0)
  def guessed?(record), do: :guessed in record.flags or :assumed in record.flags
  def rewritten?(record), do: :rewritten in record.flags
  # By the move number, not by counting: a game set up at move 40 has no opening.
  def opening?(record), do: record.move_number <= @opening_moves
  def only_move?(record), do: record.legal_count <= 1

  def time_trouble?(%{clock_before_ms: ms}) when is_integer(ms), do: ms < @time_trouble_ms
  def time_trouble?(_unknown), do: false

  def decided?(%{best: [%{cp: cp} | _]}), do: abs(cp) > @decided_cp
  def decided?(_record), do: false

  def forced_by_gap?(%{best: [%{cp: first}, %{cp: second} | _]}),
    do: first - second >= @forced_gap_cp

  def forced_by_gap?(_record), do: false
end
