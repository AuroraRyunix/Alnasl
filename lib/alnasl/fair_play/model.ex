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
      best, and the material left. The rating is not one straight line: a
      linear spline with a knot every 200 points from 1200 to 2600, so a
      1300 player is not assumed to be a 2500 player with the sign
      flipped, and the rating also bends the effect of the gap and of the
      number of good moves (a strong player finds the one good move more
      reliably than a weak one; that is rather the point of a rating).
      Ratings under 1000 are not scored at all
      (`Alnasl.FairPlay.Selection`, `:low_rating`). Fitted by Newton's
      method (IRLS) with a whisker of ridge, so a perfectly separable
      corner of the data gives a large coefficient rather than an
      infinite one;
    * the mean and variance of the scaled loss per rating band (200
      points) and position type (how many other moves are within 0.30:
      none, one, two or more), falling back to the band, then to all
      plies, where a cell has fewer than 30 plies;
    * how strongly the tests hang together within a ply, within a game
      and across the games of one player-event (`dispersion/1`, the
      `R0`, `W` and `B` of `Alnasl.FairPlay.Cluster`), from which each
      player-event's variance is built from its own games. Moves of one
      game are not independent, and a player's form on the day is not in
      the rating. The single global covariance of the z-scores that stood
      here before gave every player-event the inflation of the average
      one, and was measured on the very games the regression was fitted
      on;
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

  alias Alnasl.FairPlay.{Cluster, Selection, Stats}

  @type t :: %__MODULE__{}

  defstruct engine: nil,
            bench: nil,
            nodes: nil,
            match: nil,
            ev: nil,
            loss: %{cells: %{}, bands: %{}, global: {0.0, 0.0, 0}},
            dispersion: nil,
            weights: [1.0, 1.0, 1.0],
            false_positives: nil,
            meta: %{}

  @min_cell 30
  # The knots of the rating spline: a hinge `max(rating − knot, 0)/400`
  # each, on top of the straight line.
  @knots [1200, 1400, 1600, 1800, 2000, 2200, 2400, 2600]
  @feature_names ~w(intercept rating) ++
                   Enum.map(@knots, &"rating>#{&1}") ++
                   ~w(scaled_gap near_count material rating*scaled_gap rating*near_count)
  @attribution "Parameters derived from Lichess broadcast games (database.lichess.org), " <>
                 "licensed CC BY-SA 4.0; this file is under the same licence."

  # --- prediction --------------------------------------------------------------

  @doc """
  The features of a ply, in the order of `feature_names/0`: `1`, the
  rating as `(rating − 2000)/400`, a hinge `max(rating − k, 0)/400` per
  knot `k` (1200, 1400, ... 2600), the scaled gap, the near count (at most
  3), material/78, and the rating times the gap and times the near count.
  Scaled so the coefficients come out of comparable size, which Newton's
  method appreciates.
  """
  @spec features(map()) :: [float()]
  def features(record) do
    r = (record.rating - 2000) / 400
    gap = Stats.scaled_gap(record)
    near = min(record.near_count || 0, 3) / 1

    [1.0, r] ++
      Enum.map(@knots, &(max(record.rating - &1, 0) / 400)) ++
      [gap, near, record.material / 78, r * gap, r * near]
  end

  def feature_names, do: @feature_names

  @doc """
  The correlations `Alnasl.FairPlay.Cluster` builds a player-event's
  variance from; independent plies (`Cluster.default/0`) for a model
  without them.
  """
  def dispersion(%__MODULE__{dispersion: %{} = params}), do: params
  def dispersion(%__MODULE__{}), do: Cluster.default()

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

    %{model | dispersion: dispersion_of(events, model)}
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

  # The correlations of `Alnasl.FairPlay.Cluster`, from the residual sums
  # of every player-event's games.
  defp dispersion_of(events, model) do
    events
    |> Enum.map(&(&1 |> Stats.residuals(model) |> Cluster.accumulate()))
    |> Cluster.fit()
  end

  # --- files -------------------------------------------------------------------

  @doc "Where the model of an engine lives: `priv/fair_play/model-<engine>.json`."
  def path(engine_id, dir \\ nil),
    do:
      Path.join(dir || Application.app_dir(:alnasl, "priv/fair_play"), "model-#{engine_id}.json")

  @doc "The model of an engine, or `{:error, :missing}` until one is calibrated."
  @spec load(String.t(), String.t() | nil) :: {:ok, t()} | {:error, :missing | term()}
  def load(engine_id, dir \\ nil) do
    case read(path(engine_id, dir)) do
      {:error, :enoent} -> {:error, :missing}
      other -> other
    end
  end

  @doc "The model in the json file at `path`, wherever it is."
  @spec read(String.t()) :: {:ok, t()} | {:error, term()}
  def read(path) do
    with {:ok, text} <- File.read(path),
         {:ok, json} <- Jason.decode(text),
         do: from_json(json)
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
      "dispersion" => m.dispersion && Cluster.to_json(m.dispersion),
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
       dispersion: Cluster.from_json(j["dispersion"]),
       weights: j["weights"],
       false_positives: j["false_positives"],
       meta: j["meta"] || %{}
     }}
  end

  def from_json(_other), do: {:error, :unknown_format}
end
