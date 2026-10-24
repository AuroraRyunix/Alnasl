defmodule Alnasl.FairPlay.Union do
  @moduledoc """
  The score is the larger of two z's, and the larger of two z's is not a z.

  The event score and the per-game scan (`Alnasl.FairPlay.Scan`) are each
  measured against their own honest null, and on the held-out games each
  comes out very nearly standard normal. The report used to show the
  larger of the two as it was. A normal player then scored 0.29 on
  average instead of 0, and was over 2 about one time in 36 instead of
  one in 44: two looks at the same moves, and the report took the better
  one every time without saying it had had two goes. That is a
  multiplicity, and the scan already corrects for its own (Šidák, over
  the games); this corrects for the second one.

      m     = max(event, scan)
      p     = P(max(E, S) >= m)  for E, S standard normal with correlation ρ_g
            = 2·(1 − Φ(m)) − P(E >= m, S >= m)
      score = Φ⁻¹(1 − p)

  `ρ_g` is how strongly the two hang together for a player-event whose scan
  looked at `g` games: with one game they are nearly the same number, with
  nine much less so. It is measured in the fit, by the same cross-fit as
  everything else the null is made of (`Alnasl.FairPlay.Model`), on
  player-events with a score: per `g` from 1 to 5 and for 6 or more,
  falling back to all of them where a group has fewer than #{30}.

  An honest player-event's score is then, as nearly as the corpus can tell,
  standard normal again: centred, with a spread of one and a tail no
  heavier than the normal's. The ranking hardly moves - the score is a
  monotone function of the larger of the two for a given `g` - so it
  catches what it caught before at the same false-positive rate; what
  changes is that the number means what a z means.

  The joint tail is one integral, `∫_m^∞ φ(x) (1 − Φ((m − ρx)/√(1 − ρ²))) dx`,
  by Simpson's rule. The report and the benchmark ask it for millions of
  scores, so for each `ρ` the score is tabulated once on a grid of `m`
  (`#{-4.0}` to `#{10.0}` by #{0.02}) and read off it; beyond the grid the
  score keeps the grid's last distance from `m`.
  """

  alias Alnasl.FairPlay.Scan

  @groups 6
  @min 30
  @lo -4.0
  @hi 10.0
  @step 0.02

  @type t :: %{
          groups: %{pos_integer() => {float(), non_neg_integer()}},
          all: {float(), non_neg_integer()}
        }

  @doc "The group of a scan over `g` games: 1 to 5, and 6 for six or more."
  def group(g) when is_integer(g) and g >= 1, do: min(g, @groups)

  @doc """
  The correlations from `{event, scan, games}` of honest player-events with
  a score: `%{groups: %{g => {rho, n}}, all: {rho, n}}`. Nil with fewer
  than #{30} pairs in all: nothing to correct with, and the score stays
  the larger of the two.
  """
  @spec fit([{float(), float(), pos_integer()}]) :: t() | nil
  def fit(pairs) when length(pairs) < @min, do: nil

  def fit(pairs) do
    %{
      groups:
        pairs
        |> Enum.group_by(fn {_e, _s, g} -> group(g) end)
        |> Map.new(fn {g, ps} -> {g, correlation(ps)} end),
      all: correlation(pairs)
    }
  end

  defp correlation(pairs) do
    n = length(pairs)
    xs = Enum.map(pairs, &elem(&1, 0))
    ys = Enum.map(pairs, &elem(&1, 1))
    mx = Enum.sum(xs) / n
    my = Enum.sum(ys) / n

    {sxy, sxx, syy} =
      Enum.zip_reduce(xs, ys, {0.0, 0.0, 0.0}, fn x, y, {a, b, c} ->
        {a + (x - mx) * (y - my), b + (x - mx) * (x - mx), c + (y - my) * (y - my)}
      end)

    rho = if sxx > 0 and syy > 0, do: sxy / :math.sqrt(sxx * syy), else: 1.0
    {rho, n}
  end

  @doc "The correlation used for a scan over `g` games."
  def rho(%{groups: groups, all: {all, _}}, g) do
    case groups[group(g)] do
      {rho, n} when n >= @min -> rho
      _ -> all
    end
  end

  @doc """
  The score of a player-event from its event score, its scan and the games
  the scan looked at. Without a scan, or without correlations (`nil`), the
  larger of the two as it is: one number needs no correction, and a model
  fitted before this has none to give.
  """
  def score(event, nil, _games, _union), do: event
  def score(event, scan, _games, nil), do: max(event, scan)
  def score(event, scan, games, union), do: z(max(event, scan), rho(union, games))

  @doc "`Φ⁻¹(1 − P(max(E, S) >= m))` for standard normals `E`, `S` of correlation `rho`, from the table."
  def z(m, rho) do
    curve = curve(rho)
    last = tuple_size(curve) - 1

    cond do
      m <= @lo ->
        elem(curve, 0) + (m - @lo)

      m >= @hi ->
        elem(curve, last) + (m - @hi)

      true ->
        position = (m - @lo) / @step
        i = min(trunc(position), last - 1)
        f = position - i
        elem(curve, i) * (1 - f) + elem(curve, i + 1) * f
    end
  end

  @doc "`P(max(E, S) >= m)`, computed rather than read off the table."
  def p_max(m, rho) do
    rho = rho |> max(-0.99) |> min(0.999)
    single = Scan.upper(m)
    # Never under the single tail (the max is at least as likely as either)
    # and never quite 1, which has no z.
    (2 * single - joint(m, rho)) |> max(single) |> min(1 - 1.0e-12)
  end

  # P(E >= m, S >= m) = ∫_m^∞ φ(x)·(1 − Φ((m − ρx)/σ)) dx, σ = √(1 − ρ²), over
  # [m, m + 10] by Simpson's rule: past that φ has nothing left to give.
  defp joint(m, rho) do
    sigma = :math.sqrt(1 - rho * rho)
    n = 400
    h = 10.0 / n

    f = fn x ->
      :math.exp(-x * x / 2) / :math.sqrt(2 * :math.pi()) * Scan.upper((m - rho * x) / sigma)
    end

    sum =
      Enum.reduce(0..n, 0.0, fn i, acc ->
        weight =
          cond do
            i == 0 or i == n -> 1
            rem(i, 2) == 1 -> 4
            true -> 2
          end

        acc + weight * f.(m + i * h)
      end)

    sum * h / 3
  end

  # The table for one ρ, kept for the life of the node: the same model asks
  # for the same seven or so correlations over and over.
  defp curve(rho) do
    key = {__MODULE__, Float.round(rho / 1, 6)}

    case :persistent_term.get(key, nil) do
      nil ->
        points = round((@hi - @lo) / @step)

        curve =
          0..points
          |> Enum.map(fn i -> Scan.inverse_upper(p_max(@lo + i * @step, rho)) end)
          |> List.to_tuple()

        :persistent_term.put(key, curve)
        curve

      curve ->
        curve
    end
  end

  @doc "As json: `%{\"groups\" => %{\"1\" => [rho, n], ...}, \"all\" => [rho, n]}`."
  def to_json(nil), do: nil

  def to_json(%{groups: groups, all: {rho, n}}),
    do: %{
      "groups" => Map.new(groups, fn {g, {r, k}} -> {Integer.to_string(g), [r, k]} end),
      "all" => [rho, n]
    }

  @doc "From json; nil for a model without it."
  def from_json(%{"groups" => groups, "all" => [rho, n]}),
    do: %{
      groups: Map.new(groups, fn {g, [r, k]} -> {String.to_integer(g), {r / 1, k}} end),
      all: {rho / 1, n}
    }

  def from_json(_none), do: nil
end
