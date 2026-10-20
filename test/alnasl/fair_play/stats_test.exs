defmodule Alnasl.FairPlay.StatsTest do
  use ExUnit.Case, async: true

  alias Alnasl.FairPlay.{Model, Stats}

  defp record(attrs) do
    Map.merge(
      %{
        rating: 2000,
        best: [%{move: "a1a1", cp: 50}, %{move: "b1b1", cp: 40}],
        played_cp: 50,
        rank: 1,
        near_count: 1,
        material: 60,
        skip: nil
      },
      Map.new(attrs)
    )
  end

  defp match, do: record(rank: 1, played_cp: 50)
  defp miss, do: record(rank: 2, played_cp: 40)

  # Everything a coin flip, every ply expected to lose 0.20 with variance 0.04.
  defp coin_model do
    %Model{
      match: [0.0, 0.0, 0.0, 0.0, 0.0],
      ev: [0.0, 0.0, 0.0, 0.0, 0.0],
      loss: %{cells: %{}, bands: %{}, global: {0.2, 0.04, 1000}}
    }
  end

  describe "the pieces, by hand" do
    test "scaled loss" do
      # 1.00 lost at +1.50: 1.00 / 2.50.
      assert Stats.scaled_loss(record(best: [%{move: "a", cp: 150}], played_cp: 50)) == 0.4
      # A move that loses nothing loses nothing, whatever the eval.
      assert Stats.scaled_loss(record(best: [%{move: "a", cp: -250}], played_cp: -250)) == 0.0
      # Nine pawns at 0.00 is capped at five.
      assert Stats.scaled_loss(record(best: [%{move: "a", cp: 0}], played_cp: -900)) == 5.0
    end

    test "MM and EV: (Σ match − Σ p) / sqrt(Σ p(1−p))" do
      # 3 matches where 2 were expected, variance 4 × 0.25 = 1.
      assert Stats.binomial_z(3, [0.5, 0.5, 0.5, 0.5]) == 1.0
      # 1 match, expected 0.2 + 0.8 = 1.0: exactly as expected.
      assert Stats.binomial_z(1, [0.2, 0.8]) == 0.0
      assert Stats.binomial_z(0, []) == nil
    end

    test "ASD: (Σ E[d] − Σ d) / sqrt(Σ Var[d])" do
      # Expected 0.5, lost 0.3, variance 0.04: 0.2 / 0.2.
      assert_in_delta Stats.asd_z([0.1, 0.2], [{0.3, 0.02}, {0.2, 0.02}]), 1.0, 1.0e-12
    end

    test "combined: w·z / sqrt(wᵀ R w)" do
      identity = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
      assert_in_delta Stats.combined([1.0, 1.0, 1.0], [1, 1, 1], identity), :math.sqrt(3), 1.0e-12

      # Correlated tests count for less: wᵀRw = 3 + 6 × 0.5 = 6.
      half = [[1, 0.5, 0.5], [0.5, 1, 0.5], [0.5, 0.5, 1]]
      assert_in_delta Stats.combined([1.0, 1.0, 1.0], [1, 1, 1], half), 3 / :math.sqrt(6), 1.0e-12

      assert Stats.combined([1.0, nil, 1.0], [1, 1, 1], identity) == nil
    end
  end

  describe "a player" do
    test "known input, known z-scores" do
      records = List.duplicate(match(), 30) ++ List.duplicate(miss(), 10)
      numbers = Stats.player(records, coin_model())

      assert numbers.counted == 40
      assert numbers.matches == 30
      assert numbers.mm_share == 0.75
      assert numbers.expected_mm_share == 0.5

      # (30 − 20) / sqrt(10)
      assert_in_delta numbers.mm_z, 3.162278, 1.0e-6
      # A miss here is 0.10 behind, so not an equal-top move either.
      assert_in_delta numbers.ev_z, 3.162278, 1.0e-6
      # (40 × 0.20 − 10 × 0.10/1.50) / sqrt(40 × 0.04) = 7.333333 / 1.264911
      assert_in_delta numbers.asd_z, 5.797509, 1.0e-6
      # (3.162278 + 3.162278 + 5.797509) / sqrt(3)
      assert_in_delta numbers.score, 6.998677, 1.0e-6

      {low, high} = numbers.interval
      assert_in_delta low, 6.998677 - 1.96, 1.0e-6
      assert_in_delta high, 6.998677 + 1.96, 1.0e-6
      assert numbers.reason == nil
    end

    test "below 40 counted moves: numbers, but no score" do
      records =
        List.duplicate(match(), 29) ++ List.duplicate(miss(), 10) ++ [record(skip: :opening)]

      numbers = Stats.player(records, coin_model())
      assert numbers.counted == 39
      assert numbers.skipped == %{opening: 1}
      assert is_float(numbers.mm_z)
      assert numbers.score == nil
      assert numbers.reason == :too_few_moves
    end

    test "the score is scaled by the measured covariance, when the model has one" do
      records = List.duplicate(match(), 30) ++ List.duplicate(miss(), 10)

      # Every test twice as spread as its formula says, and independent:
      # the same z-scores, a score half as large.
      wide = %{coin_model() | covariance: [[4.0, 0.0, 0.0], [0.0, 4.0, 0.0], [0.0, 0.0, 4.0]]}
      plain = Stats.player(records, coin_model())
      scaled = Stats.player(records, wide)

      assert scaled.mm_z == plain.mm_z
      assert_in_delta scaled.score, plain.score / 2, 1.0e-9

      # A model from before there was a covariance divides by its correlation.
      assert Model.dispersion(coin_model()) == coin_model().correlation
    end

    test "without a model: the raw counts and no score" do
      records = List.duplicate(match(), 50) ++ [record(skip: :decided), record(skip: :decided)]
      numbers = Stats.player(records, nil)

      assert %{counted: 50, matches: 50, score: nil, mm_z: nil, reason: :uncalibrated} = numbers
      assert numbers.skipped == %{decided: 2}
      assert numbers.avg_loss == 0.0
    end
  end
end
