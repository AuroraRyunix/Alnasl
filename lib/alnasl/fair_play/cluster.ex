defmodule Alnasl.FairPlay.Cluster do
  @moduledoc """
  How far apart the three tests' sums can honestly be, when the moves of a
  game are not independent of each other and the games of an event are
  not independent either. The arithmetic behind the variance in
  `Alnasl.FairPlay.Stats`.

  ## What is summed

  Every counted ply `i` of a player-event has, for each test `k` (MM, EV,
  ASD), a residual `e_ki` (what happened minus what the model expected:
  `match − p`, `ev − q`, `E[d] − d`) and a model standard deviation `s_ki`
  (`√(p(1−p))`, `√(q(1−q))`, `√Var[d]`). The test's statistic is the sum
  `T_k = Σ_i e_ki`, and `z_k = T_k / √V_kk`.

  ## The variance, by game

  The old score took `V_kk = Σ_i s_ki²`: every move independent of every
  other, which they are not. A player who is having a good game is having
  it for the whole game, and a good day lasts for more than one game. So
  the plies are grouped in games `g`, the games in the player-event, and
  the covariance of the three sums is assembled from three levels of an
  exchangeable correlation (a working correlation, in GEE's words):

      V = R0 ∘ M0 + W ∘ M1 + B ∘ M2

      M0 = Σ_i s_i s_iᵀ                       (a ply with itself)
      M1 = Σ_g s_g s_gᵀ − M0                  (two plies of one game)
      M2 = s_e s_eᵀ − Σ_g s_g s_gᵀ            (two plies of two games of the event)

  with `s_g = Σ_{i∈g} s_i`, `s_e = Σ_g s_g`, `∘` the element-wise product
  and `R0`, `W`, `B` three 3×3 matrices of correlations: `R0` between the
  tests on one ply (its diagonal the move-level dispersion, one when the
  model's own variances are right), `W` between two plies of one game,
  `B` between two plies of different games of one player in one event.
  All zero but `R0`'s diagonal is the old score; that is also what a model
  without these parameters gets (`default/0`).

  It scales by itself: a player-event of nine games of thirty moves gets
  the variance of nine games of thirty moves, and one of five long games
  gets the variance of five long games. A single global covariance of the
  z-scores, as before, gave every player-event the inflation of the
  average one.

  ## Where `R0`, `W` and `B` come from

  From residual sums of games, pooled over many player-events, by the
  method of moments. For each pair of tests `(k, l)`:

      R0_kl = Σ_i e_ki e_li / Σ_i s_ki s_li
      W_kl  = Σ_g (S_gk S_gl − Σ_{i∈g} e_ki e_li) / Σ_g (s_gk s_gl − Σ_{i∈g} s_ki s_li)
      B_kl  = Σ_e (T_ek T_el − Σ_g S_gk S_gl) / Σ_e (s_ek s_el − Σ_g s_gk s_gl)

  `S_g` being the residual sums of game `g` and `T_e` those of the
  player-event: each numerator is the sum of the cross-products of the
  residuals of the pairs that level describes, each denominator what that
  sum would be with a correlation of one. A diagonal of `W` or `B` below
  zero is set to zero: a negative within-game correlation would shrink
  the variance, and the error, if any, should be on the player's side.

  The products are about zero, not about the mean, on purpose: on games
  the regression did not see, a model whose expectations are off by a
  little shows that as residuals that do not average out, and it should
  pay for it in a wider variance rather than have it subtracted away. And
  they must be games the regression did not see (`Alnasl.FairPlay.Model`
  cross-fits them): on its own games a fitted model's residuals are a
  little too small, which would make the variance a little too small, and
  every tail probability after it a little too optimistic.

  ## Why not the textbook sandwich

  The cluster-robust ("sandwich") variance of one player's own sum is
  `Σ_g S_g S_gᵀ`, from their own games. With five to nine games that is a
  t-statistic with four to eight degrees of freedom, whose tails are far
  heavier than the normal's; and a player who really does match the
  engine game after game inflates their own denominator with exactly the
  signal the test is looking for. So the per-game sums are used where
  there are thousands of them, to estimate how strongly a game hangs
  together, and each player-event's variance is then built from its own
  shape with those numbers.
  """

  @k 3

  @type vec :: [float()]
  @type mat :: [[float()]]
  @type params :: %{r0: mat(), within: mat(), between: mat()}

  @doc "Independent plies: `R0 = I`, `W = B = 0`. The old score."
  @spec default() :: params()
  def default, do: %{r0: identity(), within: zeros(), between: zeros()}

  @doc """
  The sums of one player-event, from its plies: each a map with `:game`
  (anything that tells games apart; `nil` puts the ply in one game with
  every other ply without one), `:e` and `:s` (three numbers each).
  """
  @spec accumulate([map()]) :: map()
  def accumulate(plies) do
    games =
      plies
      |> Enum.group_by(& &1[:game])
      |> Map.values()
      |> Enum.map(fn ps ->
        %{
          s: vsum(Enum.map(ps, & &1.s)),
          e: vsum(Enum.map(ps, & &1.e)),
          ee: msum(Enum.map(ps, &outer(&1.e, &1.e))),
          ss: msum(Enum.map(ps, &outer(&1.s, &1.s)))
        }
      end)

    %{
      t: vsum(Enum.map(games, & &1.e)),
      se: vsum(Enum.map(games, & &1.s)),
      e0: msum(Enum.map(games, & &1.ee)),
      m0: msum(Enum.map(games, & &1.ss)),
      eg: msum(Enum.map(games, &outer(&1.e, &1.e))),
      mg: msum(Enum.map(games, &outer(&1.s, &1.s))),
      games: length(games)
    }
  end

  @doc "The covariance `V` of the three sums of a player-event (`accumulate/1`)."
  @spec variance(map(), params()) :: mat()
  def variance(acc, %{r0: r0, within: w, between: b}) do
    m1 = msub(acc.mg, acc.m0)
    m2 = msub(outer(acc.se, acc.se), acc.mg)
    madd(madd(hadamard(r0, acc.m0), hadamard(w, m1)), hadamard(b, m2))
  end

  @doc """
  The three z-scores of a player-event and the correlation matrix between
  them: `{[z_mm, z_ev, z_asd], correlation}`. A z is `nil` when its
  variance is not positive (no plies, or every `p` zero or one).
  """
  @spec z_scores(map(), params()) :: {[float() | nil], mat()}
  def z_scores(acc, params) do
    v = variance(acc, params)
    d = for i <- 0..(@k - 1), do: at(v, i, i)

    zs =
      Enum.zip_with(acc.t, d, fn t, var -> if var > 0, do: t / :math.sqrt(var) end)

    corr =
      for i <- 0..(@k - 1) do
        for j <- 0..(@k - 1) do
          di = Enum.at(d, i)
          dj = Enum.at(d, j)

          if di > 0 and dj > 0,
            do: at(v, i, j) / :math.sqrt(di * dj),
            else: if(i == j, do: 1.0, else: 0.0)
        end
      end

    {zs, corr}
  end

  @doc """
  `R0`, `W` and `B` by the method of moments, from the sums of many
  player-events (`accumulate/1`) that the model was not fitted on.
  Too little to estimate a level from (its denominators all zero): that
  level's default.
  """
  @spec fit([map()]) :: params()
  def fit(accs) do
    zero = zeros()

    {n0, d0, n1, d1, n2, d2} =
      Enum.reduce(accs, {zero, zero, zero, zero, zero, zero}, fn a, {n0, d0, n1, d1, n2, d2} ->
        {
          madd(n0, a.e0),
          madd(d0, a.m0),
          madd(n1, msub(a.eg, a.e0)),
          madd(d1, msub(a.mg, a.m0)),
          madd(n2, msub(outer(a.t, a.t), a.eg)),
          madd(d2, msub(outer(a.se, a.se), a.mg))
        }
      end)

    %{
      r0: ratio(n0, d0, identity()),
      within: ratio(n1, d1, zero) |> floor_diagonal(),
      between: ratio(n2, d2, zero) |> floor_diagonal()
    }
  end

  @doc "As json: `%{\"r0\" => ..., \"within\" => ..., \"between\" => ...}`."
  def to_json(%{r0: r0, within: w, between: b}),
    do: %{"r0" => r0, "within" => w, "between" => b}

  @doc "From json; `nil` for a model without them."
  def from_json(%{"r0" => r0, "within" => w, "between" => b}),
    do: %{r0: floats(r0), within: floats(w), between: floats(b)}

  def from_json(_none), do: nil

  # --- three by three ------------------------------------------------------------

  defp floats(m), do: Enum.map(m, fn row -> Enum.map(row, &(&1 / 1)) end)

  defp identity,
    do: for(i <- 0..(@k - 1), do: for(j <- 0..(@k - 1), do: if(i == j, do: 1.0, else: 0.0)))

  defp zeros, do: List.duplicate(List.duplicate(0.0, @k), @k)

  defp at(m, i, j), do: m |> Enum.at(i) |> Enum.at(j)

  defp vsum([]), do: List.duplicate(0.0, @k)
  defp vsum(vs), do: Enum.reduce(vs, fn v, acc -> Enum.zip_with(v, acc, &(&1 + &2)) end)

  defp msum([]), do: zeros()
  defp msum(ms), do: Enum.reduce(ms, &madd/2)

  defp outer(a, b), do: for(x <- a, do: for(y <- b, do: x * y))

  defp madd(a, b), do: Enum.zip_with(a, b, fn r, s -> Enum.zip_with(r, s, &(&1 + &2)) end)
  defp msub(a, b), do: Enum.zip_with(a, b, fn r, s -> Enum.zip_with(r, s, &(&1 - &2)) end)
  defp hadamard(a, b), do: Enum.zip_with(a, b, fn r, s -> Enum.zip_with(r, s, &(&1 * &2)) end)

  defp ratio(num, den, default) do
    for {{nr, dr}, fr} <- Enum.zip(Enum.zip(num, den), default) do
      for {{n, d}, f} <- Enum.zip(Enum.zip(nr, dr), fr), do: if(d > 0, do: n / d, else: f)
    end
  end

  defp floor_diagonal(m) do
    for {row, i} <- Enum.with_index(m) do
      for {x, j} <- Enum.with_index(row), do: if(i == j, do: max(x, 0.0), else: x)
    end
  end
end
