defmodule Alnasl.FairPlay.Stats do
  @moduledoc """
  One player's screening numbers for one event, from the counted plies
  (`Alnasl.FairPlay.Selection`) and a calibrated model
  (`Alnasl.FairPlay.Model`). The formulas are the plan's (§5):

    * scaled loss, as Regan scales it: the centipawn loss divided by
      `1 + |eval|/100`, in pawns, capped at 5.00 - a pawn thrown away in a
      level position is worth more than a pawn thrown away while two
      pawns up;
    * **MM**: `(Σ match − Σ p) / sqrt(Σ p(1−p))`, a match being the
      engine's first choice and `p` the model's chance of it;
    * **EV**: the same, a match being any move within 0.01 of the best;
    * **ASD**: `(Σ E[d] − Σ d) / sqrt(Σ Var[d])`: positive when the player
      lost less than their rating predicts;
    * **combined**: `w·z / sqrt(wᵀ R w)`, with `R` the three tests'
      correlation measured in calibration. They are far from independent
      (a player who matches the engine also loses little), so adding them
      up as if they were would shout about every good day.

  Below 40 counted moves there is no score (`:too_few_moves`); without a
  model there is no score either (`:uncalibrated`), and the raw counts are
  still there to look at. The interval is `score ± 1.96`: under the model a
  z-score has unit variance whatever its mean, so that is the 95% interval
  of the player's true standing - which is to say, a score of 2.4 from 40
  moves is not very different from a score of 0.5.

  Nothing here knows about players' names, tournaments or the database: it
  is arithmetic over records.
  """

  alias Alnasl.FairPlay.{Model, Selection}

  @min_moves 40
  @cap 5.0

  @doc "The fewest counted moves that get a score."
  def min_moves, do: @min_moves

  @doc """
  The screening numbers of one player's plies in one event. `records` may
  hold skipped plies too: they are counted per reason and otherwise left
  out. `model` is `nil` when there is none.
  """
  @spec player([map()], Model.t() | nil) :: map()
  def player(records, model) do
    counted = Enum.filter(records, &Selection.counted?/1)
    n = length(counted)
    losses = Enum.map(counted, &scaled_loss/1)

    raw = %{
      counted: n,
      skipped: Selection.counts(records).skipped,
      matches: Enum.count(counted, &engine_match?/1),
      ev_matches: Enum.count(counted, &ev_match?/1),
      mm_share: share(Enum.count(counted, &engine_match?/1), n),
      avg_loss: if(n > 0, do: Enum.sum(losses) / n),
      expected_mm_share: nil,
      expected_avg_loss: nil,
      mm_z: nil,
      ev_z: nil,
      asd_z: nil,
      score: nil,
      interval: nil,
      reason: nil
    }

    cond do
      model == nil -> %{raw | reason: :uncalibrated}
      n == 0 -> %{raw | reason: :too_few_moves}
      true -> scored(raw, counted, losses, model)
    end
  end

  defp scored(raw, counted, losses, model) do
    n = raw.counted
    p = Enum.map(counted, &Model.p_match(model, &1))
    q = Enum.map(counted, &Model.p_ev(model, &1))
    moments = Enum.map(counted, &Model.loss_moments(model, &1))

    mm_z = binomial_z(raw.matches, p)
    ev_z = binomial_z(raw.ev_matches, q)
    asd_z = asd_z(losses, moments)
    score = combined([mm_z, ev_z, asd_z], model.weights, model.correlation)

    numbers = %{
      raw
      | expected_mm_share: Enum.sum(p) / n,
        expected_avg_loss: (moments |> Enum.map(&elem(&1, 0)) |> Enum.sum()) / n,
        mm_z: mm_z,
        ev_z: ev_z,
        asd_z: asd_z
    }

    if n < @min_moves,
      do: %{numbers | reason: :too_few_moves},
      else: %{numbers | score: score, interval: score && {score - 1.96, score + 1.96}}
  end

  defp share(_k, 0), do: nil
  defp share(k, n), do: k / n

  # --- the pieces --------------------------------------------------------------

  @doc "Scaled loss of a counted ply, in pawns, 0.00 to 5.00."
  @spec scaled_loss(map()) :: float()
  def scaled_loss(%{best: [%{cp: best} | _], played_cp: played}) do
    loss = max(best - played, 0) / 100
    min(loss / (1 + abs(best) / 100), @cap)
  end

  @doc "The gap from the best move to the second, scaled the same way; 5.00 when there is no second."
  @spec scaled_gap(map()) :: float()
  def scaled_gap(%{best: [%{cp: best}, %{cp: second} | _]}),
    do: min(max(best - second, 0) / 100 / (1 + abs(best) / 100), @cap)

  def scaled_gap(_record), do: @cap

  @doc "The engine's first choice was played."
  def engine_match?(%{rank: rank}), do: rank == 1

  @doc "The move played is within 0.01 of the best (an equal-top-value move)."
  def ev_match?(%{best: [%{cp: best} | _], played_cp: played}), do: played >= best - 1

  @doc "`(Σ x − Σ p) / sqrt(Σ p(1−p))`; nil when the variance is nil."
  @spec binomial_z(number(), [float()]) :: float() | nil
  def binomial_z(observed, ps) do
    variance = Enum.reduce(ps, 0.0, &(&1 * (1 - &1) + &2))
    if variance > 0, do: (observed - Enum.sum(ps)) / :math.sqrt(variance)
  end

  @doc "`(Σ E[d] − Σ d) / sqrt(Σ Var[d])` over `losses` and `[{mean, var}]`."
  @spec asd_z([float()], [{float(), float()}]) :: float() | nil
  def asd_z(losses, moments) do
    expected = moments |> Enum.map(&elem(&1, 0)) |> Enum.sum()
    variance = moments |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    if variance > 0, do: (expected - Enum.sum(losses)) / :math.sqrt(variance)
  end

  @doc """
  `w·z / sqrt(wᵀ R w)`: the weighted sum of the z-scores over its own
  standard deviation. Nil when any of them is.
  """
  @spec combined([float() | nil], [number()], [[number()]]) :: float() | nil
  def combined(zs, weights, correlation) do
    if Enum.any?(zs, &is_nil/1) do
      nil
    else
      numerator = zs |> Enum.zip(weights) |> Enum.map(fn {z, w} -> z * w end) |> Enum.sum()

      variance =
        for {row, wi} <- Enum.zip(correlation, weights),
            {r, wj} <- Enum.zip(row, weights),
            reduce: 0.0,
            do: (acc -> acc + wi * wj * r)

      if variance > 0, do: numerator / :math.sqrt(variance)
    end
  end
end
