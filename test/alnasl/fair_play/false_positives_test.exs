defmodule Alnasl.FairPlay.FalsePositivesTest do
  use ExUnit.Case, async: true

  alias Alnasl.FairPlay.{FalsePositives, Model}

  describe "Clopper-Pearson, against published values" do
    test "none in a hundred: 0 to 1 − 0.025^(1/100)" do
      {low, high} = FalsePositives.interval(0, 100)
      assert low == 0.0
      assert_in_delta high, 1 - :math.pow(0.025, 1 / 100), 1.0e-9
      assert_in_delta high, 0.03622, 1.0e-5
    end

    test "five in a hundred: 0.01643 to 0.11284" do
      {low, high} = FalsePositives.interval(5, 100)
      assert_in_delta low, 0.016432, 1.0e-5
      assert_in_delta high, 0.112835, 1.0e-5
    end

    test "all of them, and nothing at all" do
      {low, high} = FalsePositives.interval(10, 10)
      assert_in_delta low, :math.pow(0.025, 1 / 10), 1.0e-9
      assert high == 1.0
      assert FalsePositives.interval(0, 0) == {0.0, 1.0}
    end

    test "a tiny rate in a big sample does not underflow into nonsense" do
      {low, high} = FalsePositives.interval(2, 20_000)
      # Exact values: 1.211e-5 and 3.613e-4.
      assert_in_delta low, 1.211e-5, 1.0e-7
      assert_in_delta high, 3.613e-4, 1.0e-6
    end

    test "the binomial distribution function" do
      assert_in_delta FalsePositives.cdf(0, 2, 0.5), 0.25, 1.0e-12
      assert_in_delta FalsePositives.cdf(1, 2, 0.5), 0.75, 1.0e-12
      assert FalsePositives.cdf(2, 2, 0.5) == 1.0
      assert FalsePositives.cdf(-1, 2, 0.5) == 0.0
    end
  end

  describe "the table" do
    test "counts scores at or above each threshold" do
      scores = [0.1, 2.0, 2.4, 3.1, 5.2] ++ List.duplicate(0.0, 95)
      table = FalsePositives.table(scores)

      assert table["events"] == 100
      assert table["min_moves"] == 40

      above = Map.new(table["rows"], &{&1["threshold"], &1["above"]})
      assert above == %{2.0 => 4, 2.5 => 2, 3.0 => 2, 3.5 => 1, 4.0 => 1, 4.5 => 1, 5.0 => 1}

      row = FalsePositives.row(table, 2.0)
      assert row["rate"] == 0.04
      assert row["low"] < 0.04 and row["high"] > 0.04
    end

    test "no events: no rates, and intervals that say nothing" do
      table = FalsePositives.table([])
      assert table["events"] == 0
      assert Enum.all?(table["rows"], &(&1["rate"] == nil and &1["high"] == 1.0))
    end
  end

  describe "the sentence beside a score" do
    defp model(scores), do: %Model{false_positives: FalsePositives.table(scores)}

    test "about 1 in N, from the highest threshold the score reaches" do
      # 50 of 1000 at 2.0 or more, 10 of them at 3.0 or more.
      m = model(List.duplicate(0.0, 950) ++ List.duplicate(2.2, 40) ++ List.duplicate(3.3, 10))

      assert %{threshold: 2.0, one_in: 20, above: 50, events: 1000} =
               FalsePositives.describe(m, 2.4)

      said = FalsePositives.describe(m, 3.4)
      assert %{threshold: 3.0, one_in: 100, above: 10} = said
      # The interval: a higher rate is a smaller N.
      assert said.low_one_in < 100 and said.high_one_in > 100
    end

    test "none that high: fewer than 1 in N, N where the interval ends" do
      m = model(List.duplicate(0.0, 3000))
      said = FalsePositives.describe(m, 5.6)

      assert %{threshold: 5.0, above: 0, one_in: nil, high_one_in: nil} = said
      # 1 / (1 − 0.025^(1/3000)) ≈ 813
      assert said.low_one_in == 810
    end

    test "below the lowest threshold, without a score, a model or a table" do
      m = model(List.duplicate(0.0, 100))
      assert FalsePositives.describe(m, 1.9) == nil
      assert FalsePositives.describe(m, nil) == nil
      assert FalsePositives.describe(nil, 3.0) == :uncalibrated
      assert FalsePositives.describe(%Model{}, 3.0) == :not_measured
      assert FalsePositives.describe(model([]), 3.0) == :not_measured
    end

    test "1 in N is rounded to what the data can carry" do
      assert FalsePositives.one_in(1 / 81) == 81
      assert FalsePositives.one_in(1 / 2439) == 2400
      assert FalsePositives.one_in(0.0) == nil
    end
  end
end
