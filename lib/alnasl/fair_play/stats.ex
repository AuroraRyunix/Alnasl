defmodule Alnasl.FairPlay.Stats do
  @moduledoc """
  One player's screening numbers for one event, from the counted plies
  (`Alnasl.FairPlay.Selection`) and a calibrated model
  (`Alnasl.FairPlay.Model`). The formulas are the plan's (§5):

    * scaled loss, as Regan scales it: the centipawn loss divided by
      `1 + |eval|/100`, in pawns, capped at 5.00 - a pawn thrown away in a
      level position is worth more than a pawn thrown away while two
      pawns up;
    * **MM**: `(Σ match − Σ p) / sqrt(V)`, a match being the engine's
      first choice and `p` the model's chance of it;
    * **EV**: the same, a match being any move within 0.01 of the best;
    * **ASD**: `(Σ E[d] − Σ d) / sqrt(V)`: positive when the player lost
      less than their rating predicts;
    * **combined**: `w·z / sqrt(wᵀ C w)`, with `C` the correlation of the
      three tests in this player-event. They are far from independent (a
      player who matches the engine also loses little), so adding them up
      as if they were would shout about every good day.

  `V` is not `Σ p(1−p)`: that is the variance of moves that have nothing
  to do with each other, and the moves of one game, and the games of one
  event, have a great deal to do with each other. The variances and the
  correlation `C` come from `Alnasl.FairPlay.Cluster`, which builds them
  from this player-event's own games and the within-game and between-game
  correlations the calibration measured (`Model.dispersion/1`). The
  formulas `binomial_z/2` and `asd_z/2` remain as the independent
  special case, and a model without those correlations gets exactly them.

  ## The score: the event, or one game

  `event_score` is the combined z over the whole player-event. `scan` is
  the per-game scan of `Alnasl.FairPlay.Scan`: how unusual the most
  unusual game is, corrected for how many games there were, as a z.
  The **score** is the larger of the two, and `decided_by` says which
  (`:event` or `:game`, `scan_game` being that game). One engine game in
  a nine-game event barely moves the event score; it moves the scan a
  great deal. A model without a scan calibration gives the event score
  alone. The interval is the event score's, so it is only given when the
  event decides: a range around a maximum of several games would be a
  different and less honest number.

  Below 40 counted moves there is no score (`:too_few_moves`); without a
  model there is no score either (`:uncalibrated`), and the raw counts are
  still there to look at. The interval is `score ± 1.96`: the combined
  score is scaled to unit variance over normal player-events, so that is
  roughly the 95% interval of the player's true standing - which is to
  say, a score of 2.4 from 40 moves is not very different from a score of
  0.5. What a score means in false positives is not read off a normal
  table but measured, on games held out of the fit
  (`Alnasl.FairPlay.Model`, `false_positives`).

  Nothing here knows about players' names, tournaments or the database: it
  is arithmetic over records.
  """

  alias Alnasl.FairPlay.{Cluster, Model, Scan, Selection}

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
    counted = records |> Model.prepare() |> Enum.filter(&Selection.counted?/1)
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
      event_score: nil,
      scan: nil,
      scan_game: nil,
      decided_by: nil,
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
    plies = residuals(counted, losses, model)

    {[mm_z, ev_z, asd_z] = zs, correlation} =
      plies |> Cluster.accumulate() |> Cluster.z_scores(Model.dispersion(model))

    event = combined(zs, model.weights, correlation)
    {scan, scan_game} = Scan.z(plies, Model.dispersion(model), model.scan) || {nil, nil}
    {score, decided_by} = decide(event, scan)

    numbers = %{
      raw
      | expected_mm_share: (plies |> Enum.map(& &1.p) |> Enum.sum()) / n,
        expected_avg_loss: (plies |> Enum.map(& &1.expected_loss) |> Enum.sum()) / n,
        mm_z: mm_z,
        ev_z: ev_z,
        asd_z: asd_z
    }

    if n < @min_moves do
      %{numbers | reason: :too_few_moves}
    else
      %{
        numbers
        | event_score: event,
          scan: scan,
          scan_game: scan_game,
          score: score,
          decided_by: decided_by,
          interval: if(decided_by == :event, do: {event - 1.96, event + 1.96})
      }
    end
  end

  # The larger of the two; the event on a tie, and the event when the scan
  # has nothing to say. No event score, no score: the scan is a second
  # look at the same moves, not a way round too few of them.
  defp decide(event, scan) when is_number(event) and is_number(scan) and scan > event,
    do: {scan, :game}

  defp decide(event, _scan) when is_number(event), do: {event, :event}
  defp decide(_event, _scan), do: {nil, nil}

  @doc """
  The counted plies of `records` as `Alnasl.FairPlay.Cluster` takes them:
  per ply its `:game`, the three residuals `:e` (match − p, ev − q,
  E[d] − d) and the three model standard deviations `:s`, plus `:p` and
  `:expected_loss`. Skipped plies are left out.
  """
  @spec residuals([map()], Model.t()) :: [map()]
  def residuals(records, model) do
    counted = records |> Model.prepare() |> Enum.filter(&Selection.counted?/1)
    residuals(counted, Enum.map(counted, &scaled_loss/1), model)
  end

  defp residuals(counted, losses, model) do
    Enum.zip_with(counted, losses, fn record, loss ->
      p = Model.p_match(model, record)
      q = Model.p_ev(model, record)
      {mean, var} = Model.loss_moments(model, record)

      %{
        game: record[:game],
        p: p,
        expected_loss: mean,
        e: [indicator(engine_match?(record)) - p, indicator(ev_match?(record)) - q, mean - loss],
        s: [:math.sqrt(p * (1 - p)), :math.sqrt(q * (1 - q)), :math.sqrt(max(var, 0.0))]
      }
    end)
  end

  defp indicator(true), do: 1.0
  defp indicator(false), do: 0.0

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

  @doc """
  `(Σ x − Σ p) / sqrt(Σ p(1−p))`, as if every move were independent of
  every other; nil when the variance is nil. What `player/2` gives with a
  model that has no within-game correlation.
  """
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
  `w·z / sqrt(wᵀ C w)`: the weighted sum of the z-scores over its own
  standard deviation, `C` being their correlation. Nil when any of them
  is, or when `C` says the sum has no spread.
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
