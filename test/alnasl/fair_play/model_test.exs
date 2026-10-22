defmodule Alnasl.FairPlay.ModelTest do
  use ExUnit.Case, async: true

  alias Alnasl.FairPlay.{Model, Stats}

  defp logistic(x), do: 1 / (1 + :math.exp(-x))
  defp dot(a, b), do: a |> Enum.zip(b) |> Enum.map(fn {x, y} -> x * y end) |> Enum.sum()

  # Plies whose chance of matching is exactly the logistic of `beta` over
  # their features, drawn from a seeded generator.
  defp synthetic(beta, n, seed) do
    :rand.seed(:exsss, seed)

    for _ <- 1..n do
      gap = Enum.random(0..250)

      base = %{
        rating: 1400 + :rand.uniform(1200),
        best: [%{move: "a1a1", cp: 0}, %{move: "b1b1", cp: -gap}],
        near_count: :rand.uniform(4) - 1,
        material: 20 + :rand.uniform(58),
        skip: nil
      }

      if :rand.uniform() < logistic(dot(beta, Model.features(base))),
        do: Map.merge(base, %{rank: 1, played_cp: 0}),
        else: Map.merge(base, %{rank: 2, played_cp: -gap - 30})
    end
  end

  test "solves a small linear system" do
    [x, y, z] = Model.solve([[0.0, 2.0, 1.0], [1.0, 1.0, 1.0], [2.0, 1.0, 3.0]], [7.0, 6.0, 13.0])
    assert_in_delta x, 1.0, 1.0e-12
    assert_in_delta y, 2.0, 1.0e-12
    assert_in_delta z, 3.0, 1.0e-12
  end

  test "logistic regression recovers known coefficients" do
    :rand.seed(:exsss, {7, 7, 7})
    beta = [-0.5, 1.2, -0.8]

    {rows, ys} =
      for _ <- 1..20_000 do
        x = [1.0, :rand.normal(), :rand.uniform() * 2]
        {x, if(:rand.uniform() < logistic(dot(beta, x)), do: 1, else: 0)}
      end
      |> Enum.unzip()

    fitted = Model.logistic_fit(rows, ys, 1.0e-6)

    for {want, got} <- Enum.zip(beta, fitted), do: assert_in_delta(got, want, 0.08)
  end

  # Coefficients by name, zero where not named.
  defp beta(named), do: Enum.map(Model.feature_names(), &Map.get(named, &1, 0.0))

  test "fit recovers the match model from synthetic plies, and keeps loss moments by band" do
    # A rating effect that bends at 1600, and a gap that matters more to
    # a stronger player.
    beta =
      beta(%{
        "intercept" => 0.2,
        "rating" => 0.6,
        "rating>1600" => -0.5,
        "scaled_gap" => 1.5,
        "near_count" => -0.4,
        "material" => -0.5,
        "rating*scaled_gap" => 0.3
      })

    plies = synthetic(beta, 20_000, {1, 2, 3})
    # 400 player-events of 50 plies each.
    events = Enum.chunk_every(plies, 50)

    model = Model.fit(events, engine: "sf19", bench: 2_497_913, nodes: 1_000_000)

    # The chances it predicts are the chances the plies were drawn with;
    # the spline's coefficients one by one are too collinear to compare.
    errors =
      for ply <- Enum.take(plies, 1000),
          do: abs(Model.p_match(model, ply) - logistic(dot(beta, Model.features(ply))))

    assert Enum.sum(errors) / 1000 < 0.015
    assert Enum.max(errors) < 0.08

    # Every match is also an equal-top move here and nothing else is.
    for {a, b} <- Enum.zip(model.match, model.ev), do: assert_in_delta(a, b, 1.0e-9)

    # The loss table: a 1600 player at near count 0 expects what such plies lost.
    cell =
      Enum.filter(plies, &(Model.band(&1.rating) == 1600 and Model.kind(&1) == 0))

    mean = (cell |> Enum.map(&Stats.scaled_loss/1) |> Enum.sum()) / length(cell)
    {got_mean, _var} = Model.loss_moments(model, %{rating: 1650, near_count: 0})
    assert_in_delta got_mean, mean, 1.0e-12

    # The correlations the variance is built from: plies drawn from the
    # model itself are independent, so the move-level dispersion of MM is
    # one and two plies of one player-event are uncorrelated. MM and EV
    # are the same test here, so they correlate fully on a ply.
    %{r0: [[mm_var, mm_ev | _] | _], within: [[within | _] | _]} = Model.dispersion(model)
    assert_in_delta mm_var, 1.0, 0.05
    assert_in_delta mm_ev, 1.0, 0.05
    assert_in_delta within, 0.0, 0.02

    # And a normal player-event scores normally.
    numbers = Stats.player(hd(events), model)
    assert abs(numbers.mm_z) < 4
  end

  test "the correlations are measured on events the regression did not see" do
    # Two halves of the events that disagree completely: in one, players
    # match 90% of the time, in the other 10%. Fitted on all of them the
    # model says 50% and its own residuals look perfectly ordinary. Judged
    # across the halves, it is wrong by 0.8 every time - which is what the
    # variance must hear about.
    :rand.seed(:exsss, {5, 5, 5})

    events =
      for i <- 1..80 do
        key = "event #{i}"
        chance = if Model.fold(key) == 0, do: 0.9, else: 0.1

        records =
          for g <- 1..4, _ <- 1..15 do
            gap = 40

            base = %{
              game: g,
              rating: 2000,
              best: [%{move: "a1a1", cp: 0}, %{move: "b1b1", cp: -gap}],
              near_count: 0,
              material: 60,
              skip: nil
            }

            if :rand.uniform() < chance,
              do: Map.merge(base, %{rank: 1, played_cp: 0}),
              else: Map.merge(base, %{rank: 2, played_cp: -gap})
          end

        {key, records}
      end

    model = Model.fit(events)

    # The fitted chance is the average of the two halves...
    assert_in_delta Model.p_match(model, hd(elem(hd(events), 1))), 0.5, 0.05

    # ...and the move-level dispersion is what a 0.9 looks like where 0.1
    # is true: E[(x − 0.9)²] / 0.09 = 0.73 / 0.09, about 8, not about 1.
    %{r0: [[mm | _] | _]} = Model.dispersion(model)
    assert mm > 5

    # The split is the same every time, and both halves get events.
    folds = Enum.map(events, &Model.fold(elem(&1, 0)))
    assert folds == Enum.map(events, &Model.fold(elem(&1, 0)))
    assert Enum.sort(Enum.uniq(folds)) == [0, 1]
    assert model.meta["dispersion"] =~ "cross-fitted"
  end

  test "too few events to cross-fit: no correlations, and the independent formula" do
    model = Model.fit([synthetic(beta(%{"rating" => 0.5}), 200, {9, 9, 9})])
    assert model.dispersion == nil
    assert Model.dispersion(model) == Alnasl.FairPlay.Cluster.default()
  end

  @tag :tmp_dir
  test "saved and loaded, and missing until calibrated", %{tmp_dir: dir} do
    assert Model.load("sf19", dir) == {:error, :missing}

    model =
      Model.fit([synthetic(beta(%{"rating" => 0.5, "scaled_gap" => 1.0}), 500, {3, 2, 1})],
        engine: "sf19",
        nodes: 1000
      )

    Model.save(model, Model.path("sf19", dir))

    assert {:ok, loaded} = Model.load("sf19", dir)
    assert loaded.match == model.match
    assert loaded.loss == model.loss
    assert loaded.engine == "sf19"
    assert loaded.dispersion == model.dispersion
    assert loaded.meta["attribution"] =~ "CC BY-SA 4.0"
  end

  test "the shipped location" do
    assert Model.path("sf19")
           |> String.replace("\\", "/")
           |> String.ends_with?("priv/fair_play/model-sf19.json")
  end
end
