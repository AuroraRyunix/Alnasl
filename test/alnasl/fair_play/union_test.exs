defmodule Alnasl.FairPlay.UnionTest do
  use ExUnit.Case, async: true

  alias Alnasl.FairPlay.{Scan, Union}

  test "the tail of the larger of two correlated normals, as scipy has it" do
    # scipy.stats.multivariate_normal, 1 − cdf([m, m]) with correlation rho
    assert_in_delta Union.p_max(3.0, 0.6), 0.0025601407888, 1.0e-11
    assert_in_delta Union.p_max(3.5, 0.834), 4.0471217040838e-4, 1.0e-11
    assert_in_delta Union.p_max(2.0, 0.7), 0.0381386804046, 1.0e-10
    # independent: 1 − Φ(m)²
    single = Scan.upper(2.0)
    assert_in_delta Union.p_max(2.0, 0.0), 1 - (1 - single) * (1 - single), 1.0e-10
  end

  test "the table reads what the integral says, and the score is below the larger of the two" do
    for {m, rho} <- [{3.0, 0.6}, {3.5, 0.834}, {-1.0, 0.6}, {6.3, 0.75}] do
      assert_in_delta Union.z(m, rho), Scan.inverse_upper(Union.p_max(m, rho)), 1.0e-4
      assert Union.z(m, rho) < m
    end

    # Nearly the same number twice is nearly one look.
    assert Union.z(3.0, 0.999) > 2.95
    # Off the grid, the grid's last distance from m.
    assert_in_delta Union.z(12.0, 0.6) - 12.0, Union.z(10.0, 0.6) - 10.0, 1.0e-12
  end

  test "honest pairs come out standard normal again" do
    rho = 0.7
    rng = :rand.seed_s(:exsss, {1, 2, 3})

    {scores, _} =
      Enum.map_reduce(1..20_000, rng, fn _, rng ->
        {a, rng} = :rand.normal_s(rng)
        {b, rng} = :rand.normal_s(rng)
        e = a
        s = rho * a + :math.sqrt(1 - rho * rho) * b
        {Union.z(max(e, s), rho), rng}
      end)

    n = length(scores)
    mean = Enum.sum(scores) / n
    sd = :math.sqrt(Enum.reduce(scores, 0.0, &((&1 - mean) * (&1 - mean) + &2)) / (n - 1))
    assert_in_delta mean, 0.0, 0.03
    assert_in_delta sd, 1.0, 0.03
    # and over 2 as often as a z is: 2.28%
    assert_in_delta Enum.count(scores, &(&1 >= 2)) / n, 0.0228, 0.004
  end

  test "the score: no scan, the event; no correlations, the larger; else corrected" do
    union = %{groups: %{1 => {0.8, 100}, 2 => {0.5, 10}}, all: {0.6, 110}}
    assert Union.score(1.5, nil, nil, union) == 1.5
    assert Union.score(1.5, 2.5, 3, nil) == 2.5
    assert_in_delta Union.score(1.5, 2.5, 1, union), Union.z(2.5, 0.8), 1.0e-12
    # a group of ten is too few to trust: all of them
    assert Union.rho(union, 2) == 0.6
    assert Union.rho(union, 9) == 0.6
  end

  test "fitted per number of games scanned, six and more together" do
    rng = :rand.seed_s(:exsss, {4, 5, 6})

    {pairs, _} =
      Enum.map_reduce(1..600, rng, fn i, rng ->
        {a, rng} = :rand.normal_s(rng)
        {b, rng} = :rand.normal_s(rng)
        games = rem(i, 8) + 1
        rho = if games == 1, do: 0.9, else: 0.5
        {{a, rho * a + :math.sqrt(1 - rho * rho) * b, games}, rng}
      end)

    union = Union.fit(pairs)
    assert Map.keys(union.groups) |> Enum.sort() == [1, 2, 3, 4, 5, 6]
    assert {rho1, 75} = union.groups[1]
    assert_in_delta rho1, 0.9, 0.06
    assert {_, 225} = union.groups[6]
    assert Union.fit(Enum.take(pairs, 29)) == nil

    assert union |> Union.to_json() |> Jason.encode!() |> Jason.decode!() |> Union.from_json() ==
             union

    assert Union.from_json(nil) == nil
  end
end
