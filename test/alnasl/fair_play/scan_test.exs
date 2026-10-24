defmodule Alnasl.FairPlay.ScanTest do
  use ExUnit.Case, async: true

  alias Alnasl.FairPlay.{Cluster, Model, Scan, Stats}

  # A coin of a model: every move a coin flip for both matches, every ply
  # expected to lose 0.20 with variance 0.04.
  defp coin_model(scan) do
    %Model{
      match: [0.0, 0.0, 0.0, 0.0, 0.0],
      ev: [0.0, 0.0, 0.0, 0.0, 0.0],
      loss: %{cells: %{}, bands: %{}, global: {0.2, 0.04, 1000}},
      scan: scan
    }
  end

  defp standard, do: Map.new(~w(20-29 30-44 45+), &{&1, {0.0, 1.0, 1000}})

  defp record(game, round, match?) do
    %{
      game: game,
      round: round,
      rating: 2000,
      best: [%{move: "a1a1", cp: 50}, %{move: "b1b1", cp: 40}],
      # A miss loses 0.30 at +0.50: 0.20 scaled, exactly what is expected.
      played_cp: if(match?, do: 50, else: 20),
      rank: if(match?, do: 1, else: 2),
      near_count: 1,
      material: 60,
      skip: nil
    }
  end

  # A game of 25 counted moves: `matches` of them the engine's choice.
  defp game(id, matches), do: for(i <- 1..25, do: record(id, id, i <= matches))

  test "lengths: too short is not scanned, then three buckets" do
    assert Scan.bucket(19) == nil
    assert Scan.bucket(20) == "20-29"
    assert Scan.bucket(44) == "30-44"
    assert Scan.bucket(45) == "45+"
  end

  test "Šidák: one game is itself, more games make the same maximum less surprising" do
    assert_in_delta Scan.sidak(2.5, 1), 2.5, 1.0e-6
    assert Scan.sidak(3.0, 9) < Scan.sidak(3.0, 3)
    assert Scan.sidak(3.0, 3) < 3.0

    p = 1 - :math.pow(1 - Scan.upper(4.0), 9)
    assert_in_delta Scan.upper(Scan.sidak(4.0, 9)), p, 1.0e-12

    # Far in the tail the small-p branch takes over without a jump, and the cap holds.
    assert Scan.sidak(7.9, 9) > Scan.sidak(7.0, 9)
    assert Scan.sidak(50.0, 1) == Scan.sidak(8.0, 1)
    assert_in_delta Scan.inverse_upper(Scan.upper(1.7)), 1.7, 1.0e-9
  end

  test "the honest single-game scores per length: mean and spread, short games left out" do
    cal = Scan.fit([{:a, 25, 1.0}, {:b, 25, 3.0}, {:c, 35, 0.0}, {:d, 10, 99.0}])
    assert {2.0, sd, 2} = cal["20-29"]
    assert_in_delta sd, :math.sqrt(2.0), 1.0e-12
    assert cal["30-44"] == {0.0, 0.0, 1}
    refute Map.has_key?(cal, "45+")

    assert cal |> Scan.to_json() |> Jason.encode!() |> Jason.decode!() |> Scan.from_json() == cal
    assert Scan.from_json(nil) == nil
  end

  test "a game's own score is the three tests over that game alone" do
    plies = Stats.residuals(game(1, 25), coin_model(nil))
    [{1, 25, s}] = Scan.game_scores(plies, Cluster.default())
    # MM and EV: 12.5 / 2.5 each; ASD: 25 × 0.20 / sqrt(25 × 0.04). All 5.
    assert_in_delta s, 15 / :math.sqrt(3), 1.0e-9

    assert Scan.z(plies, Cluster.default(), nil) == nil
    assert Scan.z(Enum.take(plies, 19), Cluster.default(), standard()) == nil
    assert {z, 1} = Scan.z(plies, Cluster.default(), standard())
    assert_in_delta z, 8.0, 1.0e-6
  end

  test "the score: one engine game among honest ones is decided by the scan" do
    records = game(1, 12) ++ game(2, 12) ++ game(3, 12) ++ game(4, 25)

    numbers = Stats.player(records, coin_model(standard()))
    assert numbers.scan > numbers.event_score
    assert numbers.score == numbers.scan
    assert numbers.decided_by == :game
    assert numbers.scan_game == 4
    # No interval around a maximum of four games.
    assert numbers.interval == nil

    # The same moves, a model without a scan: the event score, as before.
    plain = Stats.player(records, coin_model(nil))
    assert plain.score == plain.event_score and plain.event_score == numbers.event_score
    assert plain.decided_by == :event and plain.scan == nil
    assert plain.interval == {plain.score - 1.96, plain.score + 1.96}
  end

  test "the score: an even event is decided by the event" do
    numbers = Stats.player(Enum.flat_map(1..4, &game(&1, 12)), coin_model(standard()))
    assert is_number(numbers.scan) and numbers.scan < numbers.event_score
    assert numbers.score == numbers.event_score and numbers.decided_by == :event
  end

  test "with the model's correlations the larger of the two is corrected for being the larger" do
    records = game(1, 12) ++ game(2, 12) ++ game(3, 12) ++ game(4, 25)
    union = %{groups: %{4 => {0.6, 500}}, all: {0.7, 2000}}
    model = %{coin_model(standard()) | union: union}

    numbers = Stats.player(records, model)

    assert {_z, 4, 4} =
             Scan.result(Stats.residuals(records, model), Cluster.default(), standard())

    assert numbers.decided_by == :game and numbers.scan_game == 4
    assert_in_delta numbers.score, Alnasl.FairPlay.Union.z(numbers.scan, 0.6), 1.0e-12
    assert numbers.score < numbers.scan

    # An even event: the event decides, corrected all the same, with its interval.
    even = Stats.player(Enum.flat_map(1..4, &game(&1, 12)), model)
    assert even.decided_by == :event and even.score < even.event_score
    assert even.interval == {even.score - 1.96, even.score + 1.96}
  end

  test "too few moves: neither the event nor a game gets a score" do
    numbers = Stats.player(game(1, 25), coin_model(standard()))
    assert numbers.reason == :too_few_moves
    assert numbers.score == nil and numbers.scan == nil and numbers.decided_by == nil
  end
end
