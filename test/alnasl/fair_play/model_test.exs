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

  test "fit recovers the match model from synthetic plies, and keeps loss moments by band" do
    beta = [0.2, 0.6, 1.5, -0.4, -0.5]
    plies = synthetic(beta, 20_000, {1, 2, 3})
    # 400 player-events of 50 plies each.
    events = Enum.chunk_every(plies, 50)

    model = Model.fit(events, engine: "sf19", bench: 2_497_913, nodes: 1_000_000)

    for {want, got} <- Enum.zip(beta, model.match), do: assert_in_delta(got, want, 0.15)

    # Every match is also an equal-top move here and nothing else is.
    for {a, b} <- Enum.zip(model.match, model.ev), do: assert_in_delta(a, b, 1.0e-9)

    # The loss table: a 1600 player at near count 0 expects what such plies lost.
    cell =
      Enum.filter(plies, &(Model.band(&1.rating) == 1600 and Model.kind(&1) == 0))

    mean = (cell |> Enum.map(&Stats.scaled_loss/1) |> Enum.sum()) / length(cell)
    {got_mean, _var} = Model.loss_moments(model, %{rating: 1650, near_count: 0})
    assert_in_delta got_mean, mean, 1.0e-12

    # MM and EV are the same test here, so their correlation is one.
    [[1.0, mm_ev | _] | _] = model.correlation
    assert_in_delta mm_ev, 1.0, 1.0e-9

    # The covariance the score divides by: plies drawn from the model
    # itself are independent, so the MM z-score has a variance near one
    # here - and the combined score is scaled by this, not by the identity.
    assert [[mm_var | _] | _] = model.covariance
    assert_in_delta mm_var, 1.0, 0.3
    assert Model.dispersion(model) == model.covariance

    # And a normal player-event scores normally.
    numbers = Stats.player(hd(events), model)
    assert abs(numbers.mm_z) < 4
  end

  @tag :tmp_dir
  test "saved and loaded, and missing until calibrated", %{tmp_dir: dir} do
    assert Model.load("sf19", dir) == {:error, :missing}

    model =
      Model.fit([synthetic([0.0, 0.5, 1.0, 0.0, 0.0], 500, {3, 2, 1})],
        engine: "sf19",
        nodes: 1000
      )

    Model.save(model, Model.path("sf19", dir))

    assert {:ok, loaded} = Model.load("sf19", dir)
    assert loaded.match == model.match
    assert loaded.loss == model.loss
    assert loaded.engine == "sf19"
    assert loaded.covariance == model.covariance
    assert loaded.meta["attribution"] =~ "CC BY-SA 4.0"
  end

  test "the shipped location" do
    assert Model.path("sf19")
           |> String.replace("\\", "/")
           |> String.ends_with?("priv/fair_play/model-sf19.json")
  end
end
