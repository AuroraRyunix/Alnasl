defmodule AlnaslWeb.Choice do
  @moduledoc """
  Which of several lines was played? Asked the way a person can answer.

  The tracker took one of several legal ways from one position to another
  and marked its moves as a guess (`Alnasl.Tracker.alternatives/2`). Nine
  lines of six moves side by side is a wall of letters, and the arbiter who
  picks one from it picks the wrong one - that happened. So the lines are
  asked about one move at a time:

  - the moves every remaining line begins with are not asked about;
  - at the first move where they differ, each move that some line plays
    there is an option, drawn on a small board with its two squares
    marked - in the order the tracker ranks the lines, so the likeliest is
    first, and the one the game has now says so;
  - an answer leaves only the lines that play it there, and the question
    moves on - until one line is left.

  Pure: `ask/2` takes the alternatives and the answers so far and returns
  what to show.
  """

  alias Alnasl.{Chess, Position}

  @doc """
  What to show for `alt` (the map of `Alnasl.Tracker.alternatives/2`) after
  the answers `picked` (a list of SAN, one per question answered):

      %{
        settled: [san],        # the line so far: answers, and moves not asked about
        left: integer,         # how many lines still fit
        line: [san] | nil,     # the one line left, when it is down to one
        changed: [boolean],    # per move of `line`: differs from the game as it stands
        number: ply | nil,     # the ply (1-based, in the game) being asked about
        white?: boolean,       # whose move that is
        options: [%{san, left, position, squares, standing?}]
      }
  """
  def ask(%{options: options, current: current, from: from, fen: fen}, picked) do
    {settled, left} = settle(options, [], picked)

    case left do
      [line] ->
        %{
          settled: line,
          left: 1,
          line: line,
          changed: changed(line, current),
          number: nil,
          white?: true,
          options: []
        }

      lines ->
        at = length(settled)
        {:ok, replayed} = Chess.replay(fen, settled)
        before = if replayed == [], do: fen, else: List.last(replayed).fen
        {:ok, pos} = Chess.parse_fen(before)
        standing = Enum.at(current, at)
        on_course? = List.starts_with?(current, settled)
        options_in_order = lines

        options =
          lines
          |> Enum.group_by(&Enum.at(&1, at))
          |> Enum.map(fn {san, with_it} ->
            {:ok, [ply]} = Chess.replay(before, [san])

            %{
              san: san,
              left: length(with_it),
              position: ply.fen |> Position.from_fen() |> Position.to_text(),
              squares: Chess.last_squares(before, san),
              standing?: on_course? and san == standing
            }
          end)
          # In the order of the best line that plays each: the tracker
          # ranks the lines, and the likeliest answer comes first.
          |> Enum.sort_by(fn option ->
            Enum.find_index(options_in_order, &(Enum.at(&1, at) == option.san)) || 0
          end)

        %{
          settled: settled,
          left: length(lines),
          line: nil,
          changed: [],
          number: from + at,
          white?: pos.turn == :w,
          options: options
        }
    end
  end

  # Follows the lines as far as they agree, takes the next answer where
  # they do not, and goes on: `{the line so far, the lines that still fit}`.
  defp settle(lines, settled, picked) do
    at = length(settled)

    case lines |> Enum.map(&Enum.at(&1, at)) |> Enum.uniq() do
      [nil] ->
        {settled, lines}

      [one] ->
        settle(lines, settled ++ [one], picked)

      _several ->
        case picked do
          [] ->
            {settled, lines}

          [answer | rest] ->
            case Enum.filter(lines, &(Enum.at(&1, at) == answer)) do
              [] -> {settled, lines}
              fit -> settle(fit, settled ++ [answer], rest)
            end
        end
    end
  end

  defp changed(line, current) do
    longest = max(length(line), length(current))
    padded = current ++ List.duplicate(nil, longest)
    line |> Enum.zip(padded) |> Enum.map(fn {mine, theirs} -> mine != theirs end)
  end
end
