defmodule Alnasl.FairPlay.Scan do
  @moduledoc """
  The per-game scan: one engine game hidden among honest ones.

  The event score (`Alnasl.FairPlay.Stats`) adds up every game of a
  player-event. One game played by an engine among nine is a ninth of the
  signal under all nine games' noise, and it drowns: the synthetic-cheat
  benchmark caught it in 3% of events of six games or more
  (`docs/fair-play-calibration-run.md`, §8). So each game of at least
  #{20} counted plies is also scored on its own, with the same three tests
  and weights, and the question becomes how surprising the most surprising
  of them is *given how many there were*:

      p_game = 1 − Φ((s_g − m_L) / sd_L)
      p_scan = 1 − (1 − min_g p_game)^G
      scan   = Φ⁻¹(1 − p_scan)

  `s_g` is the game's own score (`Alnasl.FairPlay.Cluster` over that game
  alone: the within-game correlation, no between-game term), `m_L` and
  `sd_L` the mean and spread of honest single-game scores of that length
  (20-29, 30-44, 45 or more counted plies), `G` the games scanned. Šidák's
  correction treats the games as independent, which the between-game
  correlation the calibration measures (a few thousandths) very nearly
  makes them. The standardised game score is capped at 8: past that it is
  arithmetic about the tail of a tail.

  ## Where `m_L` and `sd_L` come from

  From honest games the regression did not see: `Alnasl.FairPlay.Model`
  measures them in its cross-fit, on the same residuals as the
  correlations (`fit/1` over `game_scores/2`). They go into the model
  file as `"scan"`; a model without them has no scan, and the score is the
  event score alone.

  ## How it enters the score

  The player's score is the larger of the event score and the scan
  (`Alnasl.FairPlay.Stats`). Both are z's of their own null, so the
  larger of two is a little more often over any line than either: the
  held-out false-positive table measures exactly that score, so what the
  report says about rarity stays measured, not assumed. On the 6,626
  held-out player-events of the second model the count at 3.0 did not
  move (4).
  """

  alias Alnasl.FairPlay.{Cluster, Stats}

  @min 20
  @cap 8.0

  @doc "The fewest counted plies a game needs to be scanned."
  def min_plies, do: @min

  @doc "The length bucket of a game of `n` counted plies; nil when it is too short to scan."
  def bucket(n) when n < @min, do: nil
  def bucket(n) when n < 30, do: "20-29"
  def bucket(n) when n < 45, do: "30-44"
  def bucket(_n), do: "45+"

  @doc """
  Each game's own score from a player-event's plies (`:game`, `:e`, `:s`,
  the shipped three first): `[{game, counted plies, score}]`. Games whose
  score has no spread are left out.
  """
  def game_scores(plies, dispersion) do
    plies
    |> Enum.group_by(& &1.game)
    |> Enum.flat_map(fn {game, ps} ->
      {zs, corr} = ps |> Cluster.accumulate() |> Cluster.z_scores(dispersion)
      three = fn list -> Enum.take(list, 3) end

      case Stats.combined(three.(zs), [1.0, 1.0, 1.0], corr |> three.() |> Enum.map(three)) do
        s when is_number(s) -> [{game, length(ps), s}]
        nil -> []
      end
    end)
  end

  @doc """
  Mean and spread of honest single-game scores per length bucket
  (`game_scores/2` of honest player-events): `%{bucket => {mean, sd, n}}`.
  """
  def fit(scores) do
    scores
    |> Enum.flat_map(fn {_game, n, s} -> if b = bucket(n), do: [{b, s}], else: [] end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {b, xs} ->
      n = length(xs)
      mean = Enum.sum(xs) / n
      var = Enum.reduce(xs, 0.0, &((&1 - mean) * (&1 - mean) + &2)) / max(n - 1, 1)
      {b, {mean, :math.sqrt(var), n}}
    end)
  end

  @doc """
  The scan of a player-event's plies, `{z, game}` - the game being the one
  that stands out most - or nil when no game is long enough or nothing is
  calibrated for its length.
  """
  def z(plies, dispersion, calibration) do
    case result(plies, dispersion, calibration) do
      {z, game, _scanned} -> {z, game}
      nil -> nil
    end
  end

  @doc """
  The scan as `z/3` gives it, and how many games it looked at:
  `{z, game, scanned}`, or nil. `Alnasl.FairPlay.Union` wants the count.
  """
  def result(_plies, _dispersion, nil), do: nil

  def result(plies, dispersion, calibration) do
    standard =
      for {game, n, s} <- game_scores(plies, dispersion),
          b = bucket(n),
          {mean, sd, _} <- [calibration[b]],
          sd > 0,
          do: {(s - mean) / sd, game}

    case standard do
      [] ->
        nil

      xs ->
        {top, game} = Enum.max_by(xs, &elem(&1, 0))
        {sidak(top, length(xs)), game, length(xs)}
    end
  end

  @doc "The z of the largest of `g` independent standard normals being `top` or more."
  def sidak(top, g) do
    p1 = upper(min(top, @cap))
    # 1 − (1 − p1)^g, without losing a tiny p1 to 1 − p1 rounding to 1.
    p = if p1 < 1.0e-10, do: g * p1, else: 1 - :math.pow(1 - p1, g)
    inverse_upper(p)
  end

  @doc "`1 − Φ(x)`."
  def upper(x), do: 0.5 * :math.erfc(x / :math.sqrt(2))

  @doc "`Φ⁻¹(1 − p)`, by bisection: slow, exact enough, and no table to get wrong."
  def inverse_upper(p) when p <= 0, do: @cap * 2
  def inverse_upper(p) when p >= 1, do: -@cap * 2

  def inverse_upper(p) do
    {lo, hi} =
      Enum.reduce(1..100, {-@cap * 2, @cap * 2}, fn _, {lo, hi} ->
        mid = (lo + hi) / 2
        if upper(mid) > p, do: {mid, hi}, else: {lo, mid}
      end)

    (lo + hi) / 2
  end

  @doc "As json: `%{bucket => [mean, sd, n]}`."
  def to_json(nil), do: nil
  def to_json(cal), do: Map.new(cal, fn {b, {m, sd, n}} -> {b, [m, sd, n]} end)

  @doc "From json; nil for a model without a scan."
  def from_json(%{} = j), do: Map.new(j, fn {b, [m, sd, n]} -> {b, {m / 1, sd / 1, n}} end)
  def from_json(_none), do: nil
end
