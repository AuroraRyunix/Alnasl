defmodule Alnasl.FairPlay.Model do
  @moduledoc """
  What a player of a given rating is expected to do, as fitted on real
  games: the parameters behind `Alnasl.FairPlay.Stats`.

  Three parts, all fitted by `fit/2` from the per-ply records of
  `Alnasl.FairPlay.Analyzer`, and nothing else kept (no games, no names):

    * two logistic models, the chance of playing the engine's first choice
      (`match`) and of playing a move within 0.01 of it (`ev`), each from
      the same features (`features/1`): the rating, the scaled gap from the
      best move to the second, how many other moves are within 0.30 of the
      best, and the material left. Fitted by Newton's method (IRLS) with a
      whisker of ridge, so a perfectly separable corner of the data gives
      a large coefficient rather than an infinite one;
    * the mean and variance of the scaled loss per rating band (200
      points) and position type (how many other moves are within 0.30:
      none, one, two or more), falling back to the band, then to all
      plies, where a cell has fewer than 30 plies;
    * the correlation of the three z-scores across the calibration's
      player-events, and their **covariance** (second moments about zero),
      which `Stats.combined/3` divides by (`dispersion/1`). The covariance
      and not the correlation, because the z-scores are not unit-variance
      in real life: moves of one game are not independent, and a player's
      form on the day is not in the rating. Dividing by the correlation
      assumes a variance of one that the data do not have, and every
      tail probability that follows from it is too small. Phase 1 did
      that; a model without a covariance (a file from then) still falls
      back to the correlation;
    * the held-out false-positive table (`false_positives`): for each
      threshold, how many normal player-events scored that high, with a
      95% interval. Written by the fit (`Alnasl.FairPlay.Calibration`),
      read by the report. `nil` in a model fitted without one.

  A model belongs to one engine build and one node count: the json says
  which, and a model fitted on one is not used with another.

  Saved as `priv/fair_play/model-<engine>.json`. The parameters are derived
  from Lichess broadcast games (database.lichess.org, CC BY-SA 4.0), and
  the file says so.
  """

  alias Alnasl.FairPlay.{Selection, Stats}

  @type t :: %__MODULE__{}

  defstruct engine: nil,
            bench: nil,
            nodes: nil,
            match: nil,
            ev: nil,
            loss: %{cells: %{}, bands: %{}, global: {0.0, 0.0, 0}},
            correlation: [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]],
            covariance: nil,
            weights: [1.0, 1.0, 1.0],
            false_positives: nil,
            meta: %{}

  @min_cell 30
  @feature_names ~w(intercept rating scaled_gap near_count material)
  @attribution "Parameters derived from Lichess broadcast games (database.lichess.org), " <>
                 "licensed CC BY-SA 4.0; this file is under the same licence."

  # --- prediction --------------------------------------------------------------

  @doc """
  The features of a ply: `[1, (rating − 2000)/400, scaled gap, near count
  (at most 3), material/78]`. Scaled so the coefficients come out of
  comparable size, which Newton's method appreciates.
  """
  @spec features(map()) :: [float()]
  def features(record) do
    [
      1.0,
      (record.rating - 2000) / 400,
      Stats.scaled_gap(record),
      min(record.near_count || 0, 3) / 1,
      record.material / 78
    ]
  end

  def feature_names, do: @feature_names

  @doc """
  The matrix `Stats.combined/3` divides by: the covariance of the three
  z-scores when the model has one, else their correlation (a model from
  before there was one).
  """
  def dispersion(%__MODULE__{covariance: [_ | _] = covariance}), do: covariance
  def dispersion(%__MODULE__{correlation: correlation}), do: correlation

  @doc "The model's chance that this ply is the engine's first choice."
  def p_match(%__MODULE__{match: beta}, record), do: logistic(dot(beta, features(record)))

  @doc "The model's chance that this ply is within 0.01 of the best."
  def p_ev(%__MODULE__{ev: beta}, record), do: logistic(dot(beta, features(record)))

  @doc "`{mean, variance}` of the scaled loss expected at this ply."
  def loss_moments(%__MODULE__{loss: loss}, record) do
    band = band(record.rating)

    {mean, var, _n} =
      case loss.cells[cell(band, kind(record))] do
        {_, _, n} = found when n >= @min_cell ->
          found

        _ ->
          case loss.bands[band] do
            {_, _, n} = found when n >= @min_cell -> found
            _ -> loss.global
          end
      end

    {mean, var}
  end

  @doc "The 200-point band a rating is in, from 1000 to 2800."
  def band(rating), do: rating |> div(200) |> Kernel.*(200) |> max(1000) |> min(2800)

  @doc "The position type: how many other moves were within 0.30 of the best (2 means two or more)."
  def kind(record), do: min(record.near_count || 0, 2)

  defp cell(band, kind), do: "#{band}:#{kind}"

  defp logistic(x) when x >= 0, do: 1 / (1 + :math.exp(-x))
  defp logistic(x), do: :math.exp(x) / (1 + :math.exp(x))

  defp dot(a, b), do: a |> Enum.zip(b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)

  # --- fitting -----------------------------------------------------------------

  @doc """
  Fits a model from player-events: each a list of one player's records in
  one event. Skipped plies are ignored. Options: `:engine`, `:bench`,
  `:nodes` (stored as they are), `:meta` (a map, merged into the json's
  meta), `:lambda` (ridge, default 1.0e-4).
  """
  @spec fit([[map()]], keyword()) :: t()
  def fit(events, opts \\ []) do
    counted = events |> List.flatten() |> Enum.filter(&Selection.counted?/1)
    rows = Enum.map(counted, &features/1)
    lambda = Keyword.get(opts, :lambda, 1.0e-4)

    model = %__MODULE__{
      engine: opts[:engine],
      bench: opts[:bench],
      nodes: opts[:nodes],
      match:
        logistic_fit(
          rows,
          Enum.map(counted, &if(Stats.engine_match?(&1), do: 1, else: 0)),
          lambda
        ),
      ev: logistic_fit(rows, Enum.map(counted, &if(Stats.ev_match?(&1), do: 1, else: 0)), lambda),
      loss: loss_table(counted),
      meta:
        Map.merge(
          %{
            "plies" => length(counted),
            "player_events" => length(events),
            "attribution" => @attribution
          },
          opts[:meta] || %{}
        )
    }

    {correlation, covariance} = dispersion_of(events, model)
    %{model | correlation: correlation, covariance: covariance}
  end

  @doc """
  Logistic regression by Newton's method: `rows` are feature lists, `ys`
  zeros and ones. Returns the coefficients. Stops when no coefficient
  moves by more than 1e-9, or after 50 steps.
  """
  @spec logistic_fit([[float()]], [0 | 1], float()) :: [float()]
  def logistic_fit([], _ys, _lambda), do: List.duplicate(0.0, length(@feature_names))

  def logistic_fit([first | _] = rows, ys, lambda) do
    k = length(first)
    newton(rows, ys, lambda, List.duplicate(0.0, k), 50)
  end

  defp newton(_rows, _ys, _lambda, beta, 0), do: beta

  defp newton(rows, ys, lambda, beta, steps) do
    k = length(beta)
    zero_h = for _ <- 1..k, do: List.duplicate(0.0, k)

    {gradient, hessian} =
      rows
      |> Enum.zip(ys)
      |> Enum.reduce({List.duplicate(0.0, k), zero_h}, fn {x, y}, {g, h} ->
        p = logistic(dot(beta, x))
        w = p * (1 - p)
        g = Enum.zip_with(g, x, fn gi, xi -> gi + (y - p) * xi end)

        h =
          Enum.zip_with(h, x, fn row, xi ->
            Enum.zip_with(row, x, fn hij, xj -> hij + w * xi * xj end)
          end)

        {g, h}
      end)

    # The ridge: it keeps the matrix invertible and the coefficients finite.
    gradient = Enum.zip_with(gradient, beta, fn g, b -> g - lambda * b end)

    hessian =
      hessian
      |> Enum.with_index()
      |> Enum.map(fn {row, i} -> List.update_at(row, i, &(&1 + lambda)) end)

    step = solve(hessian, gradient)
    beta = Enum.zip_with(beta, step, &(&1 + &2))

    if Enum.all?(step, &(abs(&1) < 1.0e-9)),
      do: beta,
      else: newton(rows, ys, lambda, beta, steps - 1)
  end

  @doc "Solves `a x = b` by Gaussian elimination with partial pivoting. Small systems only."
  @spec solve([[float()]], [float()]) :: [float()]
  def solve(a, b) do
    n = length(b)
    m = Enum.zip_with(a, b, fn row, bi -> List.to_tuple(row ++ [bi]) end) |> List.to_tuple()

    m =
      Enum.reduce(0..(n - 1), m, fn col, m ->
        pivot = Enum.max_by(col..(n - 1), &abs(elem(elem(m, &1), col)))
        m = swap(m, col, pivot)
        p = elem(elem(m, col), col)

        if p == 0 do
          m
        else
          Enum.reduce((col + 1)..(n - 1)//1, m, fn r, m ->
            factor = elem(elem(m, r), col) / p
            row = elem(m, r)
            prow = elem(m, col)
            new = for j <- 0..n, into: [], do: elem(row, j) - factor * elem(prow, j)
            put_elem(m, r, List.to_tuple(new))
          end)
        end
      end)

    Enum.reduce((n - 1)..0//-1, %{}, fn i, x ->
      row = elem(m, i)
      sum = Enum.reduce((i + 1)..(n - 1)//1, 0.0, fn j, s -> s + elem(row, j) * x[j] end)
      p = elem(row, i)
      Map.put(x, i, if(p == 0, do: 0.0, else: (elem(row, n) - sum) / p))
    end)
    |> then(fn x -> for i <- 0..(n - 1), do: x[i] end)
  end

  defp swap(m, i, i), do: m
  defp swap(m, i, j), do: m |> put_elem(i, elem(m, j)) |> put_elem(j, elem(m, i))

  defp loss_table(counted) do
    with_loss = Enum.map(counted, &{&1, Stats.scaled_loss(&1)})

    %{
      cells:
        with_loss
        |> Enum.group_by(fn {r, _} -> cell(band(r.rating), kind(r)) end, &elem(&1, 1))
        |> Map.new(fn {key, losses} -> {key, moments(losses)} end),
      bands:
        with_loss
        |> Enum.group_by(fn {r, _} -> band(r.rating) end, &elem(&1, 1))
        |> Map.new(fn {key, losses} -> {key, moments(losses)} end),
      global: with_loss |> Enum.map(&elem(&1, 1)) |> moments()
    }
  end

  defp moments([]), do: {0.0, 0.0, 0}

  defp moments(xs) do
    n = length(xs)
    mean = Enum.sum(xs) / n
    var = Enum.reduce(xs, 0.0, &((&1 - mean) * (&1 - mean) + &2)) / max(n - 1, 1)
    {mean, var, n}
  end

  # The three z-scores of every player-event with as many counted moves
  # as the report wants before it shows a score, and from them their
  # Pearson correlations and their covariance about zero. About zero, not
  # about their mean: a z-score is supposed to have mean zero, and a model
  # whose scores drift off it should pay for that in a wider spread rather
  # than have it subtracted away. Too few events, or a test with no spread:
  # the identity and no covariance, which is the honest "don't know".
  defp dispersion_of(events, model) do
    zs =
      for records <- events,
          numbers = Stats.player(records, model),
          numbers.counted >= Stats.min_moves(),
          z = [numbers.mm_z, numbers.ev_z, numbers.asd_z],
          Enum.all?(z, &is_number/1),
          do: z

    if length(zs) < 3 do
      {model.correlation, nil}
    else
      columns = zs |> Enum.zip() |> Enum.map(&Tuple.to_list/1)
      n = length(zs)

      {for(a <- columns, do: for(b <- columns, do: pearson(a, b))),
       for(
         a <- columns,
         do: for(b <- columns, do: Enum.zip_reduce(a, b, 0.0, &(&1 * &2 + &3)) / n)
       )}
    end
  end

  defp pearson(a, b) do
    n = length(a)
    ma = Enum.sum(a) / n
    mb = Enum.sum(b) / n
    cov = Enum.zip_reduce(a, b, 0.0, fn x, y, s -> s + (x - ma) * (y - mb) end)
    va = Enum.reduce(a, 0.0, &((&1 - ma) * (&1 - ma) + &2))
    vb = Enum.reduce(b, 0.0, &((&1 - mb) * (&1 - mb) + &2))
    if va > 0 and vb > 0, do: cov / :math.sqrt(va * vb), else: if(a == b, do: 1.0, else: 0.0)
  end

  # --- files -------------------------------------------------------------------

  @doc "Where the model of an engine lives: `priv/fair_play/model-<engine>.json`."
  def path(engine_id, dir \\ nil),
    do:
      Path.join(dir || Application.app_dir(:alnasl, "priv/fair_play"), "model-#{engine_id}.json")

  @doc "The model of an engine, or `{:error, :missing}` until one is calibrated."
  @spec load(String.t(), String.t() | nil) :: {:ok, t()} | {:error, :missing | term()}
  def load(engine_id, dir \\ nil) do
    case File.read(path(engine_id, dir)) do
      {:ok, text} -> with {:ok, json} <- Jason.decode(text), do: from_json(json)
      {:error, :enoent} -> {:error, :missing}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Writes a model to `path` as json."
  def save(%__MODULE__{} = model, path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode_to_iodata!(to_json(model), pretty: true))
  end

  def to_json(%__MODULE__{} = m) do
    triple = fn {mean, var, n} -> [mean, var, n] end

    %{
      "format" => 1,
      "engine" => m.engine,
      "bench" => m.bench,
      "nodes" => m.nodes,
      "features" => @feature_names,
      "match" => m.match,
      "ev" => m.ev,
      "loss" => %{
        "cells" => Map.new(m.loss.cells, fn {k, v} -> {k, triple.(v)} end),
        "bands" => Map.new(m.loss.bands, fn {k, v} -> {Integer.to_string(k), triple.(v)} end),
        "global" => triple.(m.loss.global)
      },
      "correlation" => m.correlation,
      "covariance" => m.covariance,
      "weights" => m.weights,
      "false_positives" => m.false_positives,
      "meta" => m.meta
    }
  end

  def from_json(%{"format" => 1} = j) do
    triple = fn [mean, var, n] -> {mean / 1, var / 1, n} end

    {:ok,
     %__MODULE__{
       engine: j["engine"],
       bench: j["bench"],
       nodes: j["nodes"],
       match: Enum.map(j["match"], &(&1 / 1)),
       ev: Enum.map(j["ev"], &(&1 / 1)),
       loss: %{
         cells: Map.new(j["loss"]["cells"], fn {k, v} -> {k, triple.(v)} end),
         bands: Map.new(j["loss"]["bands"], fn {k, v} -> {String.to_integer(k), triple.(v)} end),
         global: triple.(j["loss"]["global"])
       },
       correlation: j["correlation"],
       covariance: j["covariance"],
       weights: j["weights"],
       false_positives: j["false_positives"],
       meta: j["meta"] || %{}
     }}
  end

  def from_json(_other), do: {:error, :unknown_format}
end
