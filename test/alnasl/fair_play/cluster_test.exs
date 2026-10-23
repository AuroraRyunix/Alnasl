defmodule Alnasl.FairPlay.ClusterTest do
  use ExUnit.Case, async: true

  alias Alnasl.FairPlay.Cluster

  # Player-events of `games` games of `moves` plies, every test a coin
  # (p = 0.5) on the face of it, but a game has a mood: with probability
  # sqrt(`corr`) a ply copies the game's own coin instead of flipping its
  # own. That makes two plies of one game correlated by exactly `corr`,
  # and plies of different games independent.
  defp events(n, games, moves, corr, seed) do
    :rand.seed(:exsss, seed)
    rho = :math.sqrt(corr)

    for _ <- 1..n do
      for g <- 1..games, mood = flip(), _ <- 1..moves do
        x = if :rand.uniform() < rho, do: mood, else: flip()
        e = x - 0.5
        %{game: g, e: [e, e, e], s: [0.5, 0.5, 0.5]}
      end
    end
  end

  defp flip, do: if(:rand.uniform() < 0.5, do: 1.0, else: 0.0)

  defp variance_of(xs) do
    n = length(xs)
    Enum.reduce(xs, 0.0, &(&1 * &1 + &2)) / n
  end

  defp mm_zs(events, params),
    do:
      Enum.map(events, fn plies ->
        {[z | _], _} = plies |> Cluster.accumulate() |> Cluster.z_scores(params)
        z
      end)

  test "the default is the independent formula" do
    plies = [
      %{game: 1, e: [0.5, 0.5, 0.1], s: [0.5, 0.5, 0.2]},
      %{game: 1, e: [0.5, 0.5, 0.1], s: [0.5, 0.5, 0.2]},
      %{game: 2, e: [-0.5, 0.5, 0.0], s: [0.5, 0.5, 0.2]},
      %{game: 2, e: [0.5, -0.5, 0.2], s: [0.5, 0.5, 0.2]}
    ]

    {[mm, ev, asd], corr} = plies |> Cluster.accumulate() |> Cluster.z_scores(Cluster.default())

    # (Σ e) / sqrt(Σ s²): 1.0 / sqrt(4 × 0.25), 1.0 / 1, 0.4 / sqrt(4 × 0.04)
    assert_in_delta mm, 1.0, 1.0e-12
    assert_in_delta ev, 1.0, 1.0e-12
    assert_in_delta asd, 1.0, 1.0e-12
    assert corr == [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
  end

  test "a game that hangs together: the variance by hand" do
    # Two games of two plies, s = 0.5 everywhere: M0 = 4 × 0.25 = 1,
    # M1 = 2 × (1.0² ) − 1 = 1, M2 = 2.0² − 2 = 2.
    plies = for g <- [1, 2], _ <- 1..2, do: %{game: g, e: [0.0, 0.0, 0.0], s: [0.5, 0.5, 0.5]}
    acc = Cluster.accumulate(plies)

    params = %{
      r0: [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]],
      within: [[0.5, 0.0, 0.0], [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]],
      between: [[0.25, 0.0, 0.0], [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]
    }

    [[v | _] | _] = Cluster.variance(acc, params)
    # 1 × 1 + 0.5 × 1 + 0.25 × 2
    assert_in_delta v, 2.0, 1.0e-12
  end

  test "clustered plies: the independent variance is overconfident, the fitted one is not" do
    # Five games of 30 plies with a within-game correlation of 0.2. The
    # independent formula says sd = sqrt(150 × 0.25); the truth is
    # sqrt(150 × 0.25 × (1 + 29 × 0.2)), so its z-scores spread about 2.6
    # times too wide (variance 6.8).
    training = events(600, 5, 30, 0.2, {1, 2, 3})
    test = events(600, 5, 30, 0.2, {4, 5, 6})

    params = training |> Enum.map(&Cluster.accumulate/1) |> Cluster.fit()

    [[r0 | _] | _] = params.r0
    [[w | _] | _] = params.within
    [[b | _] | _] = params.between
    assert_in_delta r0, 1.0, 0.05
    assert_in_delta w, 0.2, 0.03
    assert_in_delta b, 0.0, 0.03

    naive = test |> mm_zs(Cluster.default()) |> variance_of()
    fitted = test |> mm_zs(params) |> variance_of()

    assert naive > 4.5
    assert_in_delta fitted, 1.0, 0.2

    # And the tails: at 3, the independent formula flags a good share of
    # honest player-events, the clustered one about the normal 0.13%.
    over = fn zs -> Enum.count(zs, &(&1 >= 3)) end
    assert over.(mm_zs(test, Cluster.default())) > 30
    assert over.(mm_zs(test, params)) <= 5
  end

  test "it scales with the player-event's shape, not the average one's" do
    params =
      events(600, 5, 30, 0.2, {7, 8, 9}) |> Enum.map(&Cluster.accumulate/1) |> Cluster.fit()

    # Nine short games and three long ones, both judged by the same
    # correlations and both close to unit variance.
    short = events(600, 9, 10, 0.2, {10, 11, 12}) |> mm_zs(params) |> variance_of()
    long = events(600, 3, 50, 0.2, {13, 14, 15}) |> mm_zs(params) |> variance_of()

    assert_in_delta short, 1.0, 0.2
    assert_in_delta long, 1.0, 0.2
  end

  test "a negative within-game correlation is not believed" do
    # One ply up, the next down, every game: the sums cancel.
    plies =
      for g <- 1..50, i <- 1..10 do
        e = if rem(i, 2) == 0, do: 0.5, else: -0.5
        %{game: g, e: [e, e, e], s: [0.5, 0.5, 0.5]}
      end

    params = Cluster.fit([Cluster.accumulate(plies)])
    [[w | _] | _] = params.within
    assert w == 0.0
  end

  test "json, there and back" do
    params = events(50, 3, 10, 0.3, {1, 1, 1}) |> Enum.map(&Cluster.accumulate/1) |> Cluster.fit()

    assert params
           |> Cluster.to_json()
           |> Jason.encode!()
           |> Jason.decode!()
           |> Cluster.from_json() == params

    assert Cluster.from_json(nil) == nil
  end

  test "any number of tests; an empty player-event does not decide how many" do
    plies =
      for g <- 1..3,
          i <- 1..4,
          do: %{game: g, e: List.duplicate(i / 10, 6), s: List.duplicate(0.5, 6)}

    params = Cluster.fit([Cluster.accumulate([]), Cluster.accumulate(plies)])
    assert length(params.r0) == 6 and Enum.all?(params.within, &(length(&1) == 6))

    {zs, corr} = plies |> Cluster.accumulate() |> Cluster.z_scores(Cluster.default(6))
    assert length(zs) == 6 and length(corr) == 6
  end
end
