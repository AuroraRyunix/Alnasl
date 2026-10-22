defmodule Alnasl.FairPlay.PowerTest do
  use ExUnit.Case, async: true

  alias Alnasl.FairPlay.{Calibration, Model, Power, Selection, Stats}

  @moduletag :tmp_dir

  # One label ply as the label files hold it: four MultiPV lines 0, 25, 60
  # and 150 cp under the best, the played move one of them or a blunder
  # outside them (rank nil).
  defp label_ply(ply, colour, rating, choice) do
    top = rem(ply * 37, 160) - 80
    best = for {d, i} <- Enum.with_index([0, 25, 60, 150]), do: ["m#{ply}x#{i}", top - d]

    {uci, played, rank} =
      case choice do
        :blunder -> {"blunder", top - 300, nil}
        i -> {"m#{ply}x#{i}", top - Enum.at([0, 25, 60, 150], i), i + 1}
      end

    %{
      "ply" => ply,
      "colour" => colour,
      "rating" => rating,
      "uci" => uci,
      "best" => best,
      "played_cp" => played,
      "rank" => rank,
      "near" => 1,
      "material" => 60,
      "clock" => 3_600_000 - ply * 20_000
    }
  end

  # A game of `moves` plies a side after an opening of 16 skipped plies;
  # how often each side finds the best move depends on its rating.
  defp label_game(id, event, white, black, moves) do
    {wr, br} = {rating(white), rating(black)}

    plies =
      for ply <- 1..(16 + 2 * moves) do
        colour = if rem(ply, 2) == 1, do: "white", else: "black"
        rating = if colour == "white", do: wr, else: br

        if ply <= 16 do
          %{"ply" => ply, "colour" => colour, "skip" => "opening"}
        else
          label_ply(ply, colour, rating, choice(rating))
        end
      end

    %{
      "id" => id,
      "event" => event,
      "white" => white,
      "black" => black,
      "white_elo" => wr,
      "black_elo" => br,
      "engine" => %{"id" => "sf19", "name" => "Stockfish 19", "bench" => 2_497_913, "nodes" => 1},
      "plies" => plies
    }
  end

  defp rating("P" <> n), do: 1500 + rem(String.to_integer(n) * 131, 900)

  defp choice(rating) do
    u = :rand.uniform()
    top = 0.25 + (rating - 1500) / 3000

    cond do
      u < top -> 0
      u < top + 0.25 -> 1
      u < top + 0.45 -> 2
      u < top + 0.55 -> 3
      true -> :blunder
    end
  end

  defp corpus(events, players, rounds, moves) do
    :rand.seed(:exsss, {7, 8, 9})

    for e <- 1..events,
        round <- 1..rounds,
        board <- 0..(div(players, 2) - 1) do
      seats =
        Enum.map(0..(players - 1), &"P#{e * 10 + rem(&1 + round * (2 * board + 1), players)}")

      white = Enum.at(seats, 2 * board)
      black = Enum.at(seats, 2 * board + 1)
      label_game("g#{e}-#{round}-#{board}", "Open #{e}", white, black, moves)
    end
  end

  defp one_event do
    :rand.seed(:exsss, {1, 2, 3})
    games = for g <- 1..4, do: label_game("g#{g}", "Solo", "P1", "P2", 30)
    games |> Calibration.keyed_player_events() |> Enum.find(fn {{_, p}, _} -> p == "P1" end)
  end

  test "an engine choice is the label's own line: move, value, rank and loss" do
    {_, records} = one_event()
    record = Enum.find(records, &(Selection.counted?(&1) and &1.rank != 1))

    for i <- 0..3 do
      line = Enum.at(record.best, i)
      chosen = Power.engine_choice(record, i)
      assert chosen.played_cp == line.cp
      assert chosen.rank == i + 1
      assert chosen.played_uci == line.move
      assert Stats.engine_match?(chosen) == (i == 0)
      assert Stats.scaled_loss(chosen) == Stats.scaled_loss(%{record | played_cp: line.cp})
      # The position is untouched: what the model expects stays the same.
      assert Model.features(Map.put(chosen, :think, nil)) ==
               Model.features(Map.put(record, :think, nil))
    end
  end

  test "naive: that share of the counted moves become the first choice, nothing else moves" do
    {_, records} = one_event()
    counted = Enum.count(records, &Selection.counted?/1)

    {:ok, all} = Power.inject(records, {:naive, 1.0}, :s)
    assert Enum.all?(Enum.filter(all, &Selection.counted?/1), &(&1.rank == 1))
    # Skipped plies are left alone.
    assert Enum.reject(all, &Selection.counted?/1) == Enum.reject(records, &Selection.counted?/1)

    {:ok, some} = Power.inject(records, {:naive, 0.2}, :s)
    assert Enum.count(some, &Map.has_key?(&1, :played_uci)) == round(0.2 * counted)
    assert Enum.all?(some, &(not Map.has_key?(&1, :played_uci) or &1.rank == 1))

    assert {:ok, ^records} = Power.inject(records, {:naive, 0.0}, :s)
  end

  test "the same seed makes the same cheat, another seed another" do
    {_, records} = one_event()
    assert Power.inject(records, {:naive, 0.3}, :a) == Power.inject(records, {:naive, 0.3}, :a)
    assert Power.inject(records, {:naive, 0.3}, :a) != Power.inject(records, {:naive, 0.3}, :b)
  end

  test "selective: the player's worst moves are the ones replaced" do
    {_, records} = one_event()
    counted = Enum.filter(records, &Selection.counted?/1)
    m = round(0.1 * length(counted))

    {:ok, cheat} = Power.inject(records, {:selective, 0.1}, :s)

    replaced =
      for {before, now} <- Enum.zip(records, cheat), Map.has_key?(now, :played_uci), do: before

    assert length(replaced) == m

    worst_left =
      (counted -- replaced) |> Enum.map(&Stats.scaled_loss/1) |> Enum.max()

    assert Enum.all?(replaced, &(Stats.scaled_loss(&1) >= worst_left))
    assert Enum.all?(cheat, &(not Map.has_key?(&1, :played_uci) or &1.rank == 1))
  end

  test "camouflaged: a line within the window, by lot, and so not always the first" do
    {_, records} = one_event()

    {:ok, cheat} = Power.inject(records, {:camouflaged, 1.0}, :s, window: 40)
    counted = Enum.filter(cheat, &Selection.counted?/1)

    # Lines are 0, 25, 60 and 150 under the best: only the first two are in a 40 cp window.
    assert Enum.all?(counted, &(&1.rank in [1, 2]))
    assert Enum.any?(counted, &(&1.rank == 2)) and Enum.any?(counted, &(&1.rank == 1))

    {:ok, strict} = Power.inject(records, {:camouflaged, 1.0}, :s, window: 0)
    assert strict |> Enum.filter(&Selection.counted?/1) |> Enum.all?(&(&1.rank == 1))
  end

  test "whole games: every counted move of k games, the rest as played" do
    {_, records} = one_event()

    {:ok, cheat} = Power.inject(records, {:whole_games, 2}, :s)
    by_game = cheat |> Enum.filter(&Selection.counted?/1) |> Enum.group_by(& &1.game)

    cheated = for {g, ps} <- by_game, Enum.all?(ps, &Map.has_key?(&1, :played_uci)), do: g
    honest = for {g, ps} <- by_game, not Enum.any?(ps, &Map.has_key?(&1, :played_uci)), do: g

    assert length(cheated) == 2 and length(honest) == 2

    # Four games: cheating in four of them leaves nothing to hide among.
    assert Power.inject(records, {:whole_games, 4}, :s) == :not_applicable
  end

  test "the benchmark scores an honest event exactly as the report does" do
    games = corpus(4, 4, 3, 30)
    model = Model.fit(Calibration.keyed_events(games))
    {{event, player}, records} = games |> Calibration.keyed_player_events() |> hd()

    result = Power.evaluate({{event, player}, records}, model, [{:naive, 0.5}], [])
    numbers = Stats.player(records, model)
    {[mm, ev, asd], _corr} = result.honest

    assert_in_delta mm, numbers.mm_z, 1.0e-9
    assert_in_delta ev, numbers.ev_z, 1.0e-9
    assert_in_delta asd, numbers.asd_z, 1.0e-9

    # And a cheat moves every test the right way.
    {cheat, _} = result.cheats[{:naive, 0.5}]
    assert Enum.zip_with(cheat, [mm, ev, asd], &(&1 > &2)) == [true, true, true]
  end

  test "a run: cheats only in held-out events, tables at each threshold, variants judged on the final half",
       %{tmp_dir: dir} do
    labels = Path.join(dir, "labels.jsonl")
    File.write!(labels, Enum.map_join(corpus(8, 4, 3, 30), "\n", &Jason.encode!/1))
    out = Path.join(dir, "power.json")
    me = self()

    {:ok, summary} =
      Power.run([labels],
        holdout: 0.5,
        rates: [0.1, 0.5],
        games: [1],
        out: out,
        log: &send(me, {:line, &1})
      )

    {:ok, games, _} = Calibration.read_labels([labels])
    held = Enum.count(games, &Calibration.held_out?(Calibration.holdout_key(&1), 0.5))
    assert summary.held_out_games == held
    assert summary.events > 0
    assert summary.tune_events + summary.final_events == summary.events

    assert Enum.map(summary.power, & &1.scenario) ==
             [
               "naive 10%",
               "naive 50%",
               "selective 10%",
               "selective 50%",
               "camouflaged 10%",
               "camouflaged 50%",
               "whole games 1"
             ]

    for p <- summary.power, row <- p.rows do
      assert row.threshold in Power.thresholds()
      assert row.low <= row.rate and row.rate <= row.high
    end

    naive = Enum.find(summary.power, &(&1.scenario == "naive 50%"))
    assert Enum.all?(naive.delta_z, &(&1 > 0))

    # Engine moves are worth something: more of them, no fewer caught.
    for {a, b} <- Enum.zip(naive.rows, hd(summary.power).rows), do: assert(a.above >= b.above)

    v = summary.variants
    assert length(v.rows) == 9
    assert "fitted" in Enum.map(v.rows, & &1.variant)
    assert length(v.fitted_weights) == 3
    assert is_binary(v.verdict)

    assert_received {:line, "fair_play power: " <> _}
    assert_received {:line, "verdict: " <> _}
    assert %{"power" => [_ | _], "variants" => %{"rows" => _}} = Jason.decode!(File.read!(out))
  end

  test "the budget threshold lets through at most the budget's share of honest events" do
    events = for s <- 1..200, do: %{honest: s / 1, band: 1800}
    scorer = fn score, _band -> score end
    t = Power.budget_threshold(events, scorer, 0.05)
    assert Enum.count(events, &(&1.honest >= t)) == 10
  end

  test "the command line says what it wants" do
    assert ExUnit.CaptureIO.capture_io(:stderr, fn ->
             assert {:error, :usage} = Power.main([], halt: false)
           end) =~ "usage"
  end
end
