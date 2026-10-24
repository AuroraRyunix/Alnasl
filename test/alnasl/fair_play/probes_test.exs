defmodule Alnasl.FairPlay.ProbesTest do
  use ExUnit.Case, async: true

  alias Alnasl.FairPlay.{Calibration, Model, Power, Probes, Selection, Stats}

  # Label games as the power benchmark's tests make them: four MultiPV
  # lines 0, 25, 60 and 150 cp under the best, or a 300 cp blunder.
  defp label_game(id, event, white, black, moves) do
    plies =
      for ply <- 1..(16 + 2 * moves) do
        colour = if rem(ply, 2) == 1, do: "white", else: "black"
        rating = if colour == "white", do: rating(white), else: rating(black)

        if ply <= 16 do
          %{"ply" => ply, "colour" => colour, "skip" => "opening"}
        else
          top = rem(ply * 37, 160) - 80
          best = for {d, i} <- Enum.with_index([0, 25, 60, 150]), do: ["m#{ply}x#{i}", top - d]

          {played, rank} =
            case choice(rating) do
              :blunder -> {top - 300, nil}
              i -> {top - Enum.at([0, 25, 60, 150], i), i + 1}
            end

          %{
            "ply" => ply,
            "colour" => colour,
            "rating" => rating,
            "best" => best,
            "played_cp" => played,
            "rank" => rank,
            "near" => rem(ply, 3),
            "material" => 60,
            "clock" => 3_600_000 - ply * 20_000
          }
        end
      end

    %{
      "id" => id,
      "event" => event,
      "white" => white,
      "black" => black,
      "white_elo" => rating(white),
      "black_elo" => rating(black),
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

  defp corpus(events, rounds) do
    :rand.seed(:exsss, {3, 1, 4})

    for e <- 1..events, round <- 1..rounds, board <- 0..1 do
      seats = Enum.map(0..3, &"P#{e * 10 + rem(&1 + round * (2 * board + 1), 4)}")

      label_game(
        "g#{e}-#{round}-#{board}",
        "Open #{e}",
        Enum.at(seats, 2 * board),
        Enum.at(seats, 2 * board + 1),
        30
      )
    end
  end

  setup_all do
    keyed = corpus(12, 4) |> Calibration.keyed_events()
    model = Model.fit(keyed)
    %{keyed: keyed, model: model, probes: Probes.fit(keyed, model)}
  end

  defp counted(records), do: records |> Model.prepare() |> Enum.filter(&Selection.counted?/1)

  defp observe(records, model, probes) do
    counted = counted(records)
    counted |> Probes.plies(Probes.expectations(counted, model, probes)) |> Probes.observe(probes)
  end

  test "the first three sums are the report's, to the digit", %{
    keyed: keyed,
    model: model,
    probes: probes
  } do
    {_, records} = hd(keyed)
    numbers = Stats.player(records, model)
    obs = observe(records, model, probes)

    assert [mm, ev, asd, _, _, _] = obs.zs
    assert_in_delta mm, numbers.mm_z, 1.0e-9
    assert_in_delta ev, numbers.ev_z, 1.0e-9
    assert_in_delta asd, numbers.asd_z, 1.0e-9
    assert_in_delta Probes.score(obs, [1.0, 1.0, 1.0, 0.0, 0.0, 0.0]), numbers.event_score, 1.0e-9

    # And the benchmark's score is the report's, union correction and all.
    assert_in_delta Alnasl.FairPlay.Power.shipped(
                      obs,
                      model.weights,
                      model.scan != nil,
                      model.union
                    ),
                    numbers.score,
                    1.0e-9

    # The model's 3×3 block, the probes' own for the rest.
    for level <- [:r0, :within, :between], i <- 0..2, j <- 0..2 do
      assert probes.dispersion[level] |> Enum.at(i) |> Enum.at(j) ==
               Model.dispersion(model)[level] |> Enum.at(i) |> Enum.at(j)
    end

    assert length(probes.dispersion.r0) == 6
  end

  test "errors and blunders by the scaled loss; a cheat that never errs scores above the honest",
       %{keyed: keyed, model: model, probes: probes} do
    record = %{best: [%{cp: 0, move: "a"}], played_cp: -60}
    assert Probes.error?(record) and not Probes.blunder?(record)
    assert Probes.blunder?(%{record | played_cp: -100})
    refute Probes.error?(%{record | played_cp: -40})

    {_, records} = hd(keyed)
    honest = observe(records, model, probes)
    {:ok, cheat} = Power.inject(counted(records), {:camouflaged, 1.0}, :s, window: 40)
    cheat = observe(cheat, model, probes)

    [_, _, _, err, bln, hard] = Enum.zip_with(cheat.zs, honest.zs, &(&1 - &2))
    assert err > 0 and bln > 0 and hard > 0
  end

  test "hard ASD weighs a ply by the chance of an error there, over its mean", %{
    model: model,
    probes: probes,
    keyed: keyed
  } do
    {_, records} = hd(keyed)
    counted = counted(records)
    expected = Probes.expectations(counted, model, probes)

    for {x, ply} <- Enum.zip(expected, Probes.plies(counted, expected)) do
      assert_in_delta x.hard, x.pe / probes.hardness, 1.0e-12
      assert_in_delta Enum.at(ply.e, 5), x.hard * Enum.at(ply.e, 2), 1.0e-12
      assert_in_delta Enum.at(ply.s, 5), x.hard * Enum.at(ply.s, 2), 1.0e-12
    end
  end

  test "a score ignores the tests it gives no weight, even without a z" do
    obs = %{zs: [2.0, nil, 1.0], corr: [[1.0, 0.0, 0.5], [0.0, 1.0, 0.0], [0.5, 0.0, 1.0]]}
    assert_in_delta Probes.score(obs, [1.0, 0.0, 1.0]), 3.0 / :math.sqrt(3.0), 1.0e-12
    assert Probes.score(obs, [1.0, 1.0, 1.0]) == nil
  end

  test "the scan finds one engine game among honest ones; the event score dilutes it",
       %{keyed: keyed, model: model, probes: probes} do
    # Every bucket a game of 30 counted plies can land in is calibrated.
    assert {_mean, sd, n} = probes.scan["30-44"]
    assert sd > 0 and n > 10

    {_, records} =
      Enum.max_by(keyed, fn {_, rs} -> rs |> Enum.map(& &1.game) |> Enum.uniq() |> length() end)

    honest = observe(records, model, probes)
    {:ok, cheat} = Power.inject(counted(records), {:whole_games, 1}, :s)
    cheat = observe(cheat, model, probes)

    assert is_number(honest.scan) and cheat.scan > honest.scan + 2
  end
end
