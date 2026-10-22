defmodule Alnasl.FairPlay.Report do
  @moduledoc """
  What the owner sees: the stored analysis (`Alnasl.FairPlay.Move`) turned
  into one line per player (`build/2`) and, for one player, the positions
  worth looking at (`key_positions/2`). Pure arithmetic over rows already
  loaded: nothing here reads the database, and nothing here checks who is
  asking - the caller has asked `Alnasl.FairPlay.Access` already, which
  is why every way to the rows is in `Alnasl.FairPlay`, behind it.

  ## The line of a player

  `Alnasl.FairPlay.Stats.player/2` over all the player's plies, plus:

    * `verdict` - `:very_unusual` above a score of 5, `:closer_look` from
      2, else `nil`. Words for the screen, not a finding: the manual says
      what to do with them, and the report says on every page that this is
      not the method FIDE has approved;
    * `name`, `key`, `rating` (the player's most recent) and `games`.

  Players are sorted by score, highest first; those without a score
  (uncalibrated, or too few moves) after them, by counted moves.

  ## The model

  `model/1` loads the calibration file of the hall's engine
  (`priv/fair_play/model-<engine>.json`) and returns it only when it was
  fitted on the engine, bench and node count the analysis was made with.
  Until there is one, `nil`: the report shows the counts and no score. The
  directory can be changed with `config :alnasl, :fair_play_model_dir`.

  ## Key positions

  Of the moves the player matched (the engine's first choice), those where
  the engine's first choice stood out most: the largest scaled gap between
  the best move and the second. Only moves, no verdicts: a human looks.
  """

  alias Alnasl.Chess
  alias Alnasl.FairPlay.{Analyzer, Model, Move, Selection, Setting, Stats}
  alias Alnasl.Position

  @closer_look 2.0
  @very_unusual 5.0
  @key_positions 8

  @doc "The score from which the screen says \"worth a closer look\"."
  def closer_look, do: @closer_look

  @doc "The score above which the screen says \"statistically very unusual\"."
  def very_unusual, do: @very_unusual

  @doc """
  The calibrated model that fits the analysis in `setting`, or `nil`.
  """
  @spec model(struct()) :: Model.t() | nil
  def model(%Setting{engine_id: id} = setting) when is_binary(id) do
    dir = Application.get_env(:alnasl, :fair_play_model_dir)

    case Model.load(id, dir) do
      {:ok, %Model{nodes: nodes, bench: bench} = model}
      when nodes == setting.nodes and bench == setting.engine_bench ->
        model

      _missing_or_other ->
        nil
    end
  end

  def model(_setting), do: nil

  @doc "One line per player, best score first."
  @spec build([struct()], Model.t() | nil) :: [map()]
  def build(rows, model) do
    opponents = opponent_ratings(rows)

    rows
    |> Enum.group_by(& &1.player_key)
    |> Enum.map(fn {key, rows} -> player(key, rows, model, opponents) end)
    |> Enum.sort_by(&{&1.score == nil, -(&1.score || 0), -&1.counted, &1.name})
  end

  @doc """
  Who played whom at what rating, from all the rows of a report: the
  model wants the opponent's rating beside each move, and the rows only
  carry the mover's. Pass it to `player/4` when that player's rows have
  been picked out of the rest.
  """
  def opponent_ratings(rows) do
    for row <- rows, is_integer(row.rating), into: %{} do
      {{row.__struct__, row.game_id, row.colour}, row.rating}
    end
  end

  @doc "One player's line from their rows, and the opponents' ratings (`opponent_ratings/1`)."
  def player(key, rows, model, opponents \\ %{}) do
    rows = Enum.sort_by(rows, &{&1.round, &1.game_id, &1.ply})

    records =
      Enum.map(rows, fn row ->
        other = if row.colour == "white", do: "black", else: "white"

        row
        |> Move.to_record()
        |> Map.put(:opponent_rating, opponents[{row.__struct__, row.game_id, other}])
      end)

    numbers = Stats.player(records, model)
    last = List.last(rows)

    numbers
    |> Map.merge(%{
      key: key,
      name: last.player_name || key,
      rating: rows |> Enum.map(& &1.rating) |> Enum.reject(&is_nil/1) |> List.last(),
      # A board game and an uploaded one can share an id: they are in
      # different tables.
      games: rows |> Enum.map(&{&1.__struct__, &1.game_id}) |> Enum.uniq() |> length(),
      verdict: verdict(numbers.score)
    })
  end

  @doc "`:very_unusual` above 5, `:closer_look` from 2, else `nil`."
  def verdict(score) when is_number(score) and score > @very_unusual, do: :very_unusual
  def verdict(score) when is_number(score) and score >= @closer_look, do: :closer_look
  def verdict(_score), do: nil

  # --- one player --------------------------------------------------------------

  @doc """
  The positions to look at for one player's rows: the moves they matched
  where the engine's choice stood out most, with the position before the move,
  the move played and the engine's lines in SAN.
  """
  @spec key_positions([struct()], pos_integer()) :: [map()]
  def key_positions(rows, count \\ @key_positions) do
    rows
    |> Enum.map(&Move.to_record/1)
    |> Enum.filter(&(Selection.counted?(&1) and &1.rank == 1))
    |> Enum.sort_by(&{-Stats.scaled_gap(&1), &1.round, &1.ply})
    |> Enum.take(count)
    |> Enum.map(&position/1)
  end

  defp position(record) do
    played_san = record.san

    %{
      round: record.round,
      board_no: record.board_no,
      move_number: record.move_number,
      colour: record.colour,
      fen: record.fen,
      board: board(record.fen),
      last: last(record.fen, played_san),
      played: played_san,
      played_cp: record.played_cp,
      gap: Stats.scaled_gap(record),
      lines: Enum.map(record.best, &%{san: san(record.fen, &1.move), cp: &1.cp})
    }
  end

  defp board(fen) do
    case Position.from_fen(fen) do
      nil -> nil
      board -> Position.to_text(board)
    end
  end

  defp last(fen, san) do
    Chess.last_squares(fen, san)
  rescue
    _error -> nil
  end

  @doc "A UCI move as SAN in the position `fen`; the UCI text when it does not fit."
  def san(fen, uci) do
    with {:ok, pos} <- Chess.parse_fen(fen),
         %{} = move <- Enum.find(Chess.legal_moves(pos), &(Analyzer.uci(&1) == uci)) do
      Chess.san(pos, move)
    else
      _no -> uci
    end
  end

  @doc """
  An evaluation for people: `+0.30`, `-1.25`, or `mate` when the number is a
  forced mate (the engine's scale puts those beyond 9 000).
  """
  def pawns(nil), do: ""
  def pawns(cp) when abs(cp) >= 9_000, do: "mate"

  def pawns(cp) do
    sign = if cp < 0, do: "-", else: "+"
    abs = abs(cp)

    "#{sign}#{div(abs, 100)}.#{abs |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end
end
