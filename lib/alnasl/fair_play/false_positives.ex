defmodule Alnasl.FairPlay.FalsePositives do
  @moduledoc """
  How often a normal player-event scores at least so high: the table the
  calibration measures on games it did not fit on, and the sentence the
  report makes of it.

  ## The table

  For each threshold `t` in `thresholds/0` (2.0 to 5.0 by halves): of the
  `n` held-out player-events with a score (at least
  `Alnasl.FairPlay.Stats.min_moves/0` counted moves), how many scored `t`
  or more (`k`), the share `k / n`, and its exact 95% interval
  (Clopper-Pearson). Exact rather than the normal approximation because
  the interesting rows are the ones with `k` of 0, 1 or 2, where the
  approximation gives intervals below zero and confidence it has not got.

  Every held-out player-event is taken to be normal. Some of them may not
  be, which makes the rates a little too high, never too low: the error is
  on the side of the player.

  ## The sentence

  `describe/2` turns a score into what the report shows beside it: the
  row of the highest threshold the score reaches, as "about 1 in N", with
  the interval, or - when no held-out event got that high - "fewer than
  about 1 in N", N being where the interval ends. Below the lowest
  threshold there is nothing to say; without a table, `:not_measured`;
  without a model, `:uncalibrated`. Never a number nobody measured.

  Stored in the model's json as

      "false_positives": {"events": n, "min_moves": 40, "confidence": 0.95,
                          "rows": [{"threshold": 2.0, "above": k, "events": n,
                                    "rate": r, "low": l, "high": h}, ...]}
  """

  @thresholds [2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0]
  @confidence 0.95

  @doc "The thresholds of the table."
  def thresholds, do: @thresholds

  @doc """
  The table from the scores of `n` held-out player-events, as the json
  stores it (string keys).
  """
  @spec table([float()]) :: map()
  def table(scores) do
    n = length(scores)

    rows =
      for t <- @thresholds do
        k = Enum.count(scores, &(&1 >= t))
        {low, high} = interval(k, n)

        %{
          "threshold" => t,
          "above" => k,
          "events" => n,
          "rate" => if(n > 0, do: k / n),
          "low" => low,
          "high" => high
        }
      end

    %{
      "events" => n,
      "min_moves" => Alnasl.FairPlay.Stats.min_moves(),
      "confidence" => @confidence,
      "rows" => rows
    }
  end

  @doc """
  The row of the table at threshold `t`, or `nil`.
  """
  def row(%{"rows" => rows}, t), do: Enum.find(rows, &(&1["threshold"] == t))
  def row(_none, _t), do: nil

  @doc """
  What to say beside a score:

    * `nil` - no score, or a score below the lowest threshold;
    * `:uncalibrated` - there is no model;
    * `:not_measured` - the model has no table;
    * `%{threshold, above, events, one_in, low_one_in, high_one_in}` -
      "about 1 in `one_in`" (from 1 in `low_one_in` to 1 in
      `high_one_in`, 95%). When none got that high `one_in` and
      `high_one_in` are `nil`, and it is "fewer than about 1 in
      `low_one_in`".
  """
  def describe(_model, nil), do: nil
  def describe(nil, _score), do: :uncalibrated

  def describe(%{false_positives: %{"rows" => [_ | _] = rows}}, score) when is_number(score) do
    case rows |> Enum.filter(&(&1["threshold"] <= score)) |> List.last() do
      nil ->
        nil

      %{"events" => 0} ->
        :not_measured

      row ->
        %{
          threshold: row["threshold"],
          above: row["above"],
          events: row["events"],
          one_in: one_in(row["rate"]),
          # A high rate is a small N: the interval's ends swap.
          low_one_in: one_in(row["high"]),
          high_one_in: one_in(row["low"])
        }
    end
  end

  def describe(_model, _score), do: :not_measured

  @doc """
  `1 / rate`, rounded to two significant digits from 100 on (`1 in 2,400`,
  not `1 in 2,439`: the third digit is noise). `nil` for a rate of zero.
  """
  def one_in(rate) when is_number(rate) and rate > 0 do
    n = 1 / rate

    cond do
      n < 100 -> round(n)
      true -> round_significant(n, 2)
    end
  end

  def one_in(_zero), do: nil

  defp round_significant(x, digits) do
    magnitude = :math.pow(10, floor(:math.log10(x)) - digits + 1)
    round(Float.round(x / magnitude) * magnitude)
  end

  # --- Clopper-Pearson ---------------------------------------------------------

  @doc """
  The exact (Clopper-Pearson) two-sided interval of a binomial share: `k`
  successes in `n` trials, at `confidence`. `{0.0, 1.0}` for no trials.
  """
  @spec interval(non_neg_integer(), non_neg_integer(), float()) :: {float(), float()}
  def interval(k, n, confidence \\ @confidence)
  def interval(_k, 0, _confidence), do: {0.0, 1.0}

  def interval(k, n, confidence) when k >= 0 and k <= n do
    alpha = (1 - confidence) / 2

    low = if k == 0, do: 0.0, else: bisect(fn p -> 1 - cdf(k - 1, n, p) - alpha end)
    high = if k == n, do: 1.0, else: bisect(fn p -> alpha - cdf(k, n, p) end)
    {low, high}
  end

  # The root in (0, 1) of an increasing function of p, to 1e-12.
  defp bisect(f), do: bisect(f, 0.0, 1.0, 200)

  defp bisect(_f, lo, hi, 0), do: (lo + hi) / 2

  defp bisect(f, lo, hi, steps) do
    mid = (lo + hi) / 2

    cond do
      hi - lo < 1.0e-12 -> mid
      f.(mid) < 0 -> bisect(f, mid, hi, steps - 1)
      true -> bisect(f, lo, mid, steps - 1)
    end
  end

  @doc "P(X ≤ k) for X ~ Binomial(n, p), summed in logs so a tiny p does not underflow early."
  def cdf(k, _n, _p) when k < 0, do: 0.0
  def cdf(k, n, _p) when k >= n, do: 1.0
  def cdf(_k, _n, p) when p <= 0, do: 1.0
  def cdf(_k, _n, p) when p >= 1, do: 0.0

  def cdf(k, n, p) do
    lp = :math.log(p)
    lq = :math.log(1 - p)

    {sum, _log_choose} =
      Enum.reduce(0..k, {0.0, 0.0}, fn i, {sum, log_choose} ->
        term = :math.exp(log_choose + i * lp + (n - i) * lq)
        {sum + term, log_choose + :math.log(n - i) - :math.log(i + 1)}
      end)

    min(sum, 1.0)
  end
end
