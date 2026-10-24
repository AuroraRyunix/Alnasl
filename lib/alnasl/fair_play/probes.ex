defmodule Alnasl.FairPlay.Probes do
  @moduledoc """
  Tests the report does not use, tried out by the synthetic-cheat
  benchmark (`Alnasl.FairPlay.Power`) on the profiles the shipped score
  is blind to. Each is a sum over counted plies like the three shipped
  ones, so `Alnasl.FairPlay.Cluster` gives it a per-game variance and its
  correlation with the others, and any weighting of the lot is a proper
  z (`score/2`).

  ## The six sums, in this order (`tests/0`)

    1. **MM**, 2. **EV**, 3. **ASD** - the shipped three, exactly as
       `Alnasl.FairPlay.Stats` computes them;
    4. **error avoidance**: `P(error) − error`, an error being a scaled
       loss of #{0.5} or more, `P(error)` a logistic model on the model's
       own features (`Alnasl.FairPlay.Model.features/1`). Positive when
       the player made fewer errors than their rating and these positions
       predict. A near-best cheat never makes one;
    5. **blunder avoidance**: the same at a scaled loss of 1.0;
    6. **hard ASD**: the ASD residual weighted by how hard the position is,
       `P(error)` over its mean on the training plies. A move within 40 cp
       of the best is unremarkable where everybody finds one and
       remarkable where people usually go wrong; the plain ASD weighs both
       alike.

  The error threshold (0.5) and the blunder threshold (1.0) were picked
  before anything was measured, round numbers either side of where a club
  player calls a move a mistake.

  The benchmark also scores the per-game scan (`Alnasl.FairPlay.Scan`),
  calibrated here on the same cross-fitted residuals, so a model file
  without one can still be judged with it.

  ## Fitted without peeking (`fit/3`)

  Everything is fitted on the training events only. The two logistic
  models on all of them. The six-way correlations and the honest
  single-game scores are **cross-fitted**, as `Alnasl.FairPlay.Model`
  does its own: the training events split in two by the same hash, the
  model and the probes fitted on each half, the residuals of the other
  half measured. The 3×3 block of the shipped tests is then replaced by
  the model's own, so the first three z's are the report's to the digit.
  """

  alias Alnasl.FairPlay.{Cluster, Model, Scan, Selection, Stats}

  @tests [:mm, :ev, :asd, :error, :blunder, :hard_asd]
  @error 0.5
  @blunder 1.0

  defstruct error: nil, blunder: nil, hardness: 1.0, dispersion: nil, scan: nil

  @type t :: %__MODULE__{}

  @doc "The sums, in the order of every z and weight vector here."
  def tests, do: @tests

  @doc "A ply is an error at a scaled loss of 0.5 or more."
  def error?(record), do: Stats.scaled_loss(record) >= @error

  @doc "A blunder at 1.0 or more."
  def blunder?(record), do: Stats.scaled_loss(record) >= @blunder

  # --- fitting -------------------------------------------------------------------

  @doc """
  The probes for `model`, from the keyed training player-events it was
  fitted on (`Alnasl.FairPlay.Calibration.keyed_events/1`). Options:
  `:lambda` (the ridge, as the model's).
  """
  @spec fit([{term(), [map()]}], Model.t(), keyword()) :: t()
  def fit(keyed, model, opts \\ []) do
    halves = Enum.split_with(keyed, &(Model.fold(elem(&1, 0)) == 0))
    whole = Task.async(fn -> logistic(Enum.map(keyed, &elem(&1, 1)), opts) end)

    {cross, games} =
      case halves do
        {a, b} when length(a) >= 2 and length(b) >= 2 ->
          [on_a, on_b] =
            [a, b]
            |> Enum.map(fn half -> Task.async(fn -> half_fit(half, opts) end) end)
            |> Task.await_many(:infinity)

          plies = Enum.map(b, &plies_of(&1, on_a)) ++ Enum.map(a, &plies_of(&1, on_b))
          dispersion = plies |> Enum.map(&Cluster.accumulate/1) |> Cluster.fit()
          {dispersion, plies}

        _ ->
          {Cluster.default(length(@tests)), []}
      end

    dispersion = with_block(cross, Model.dispersion(model))

    scan = games |> Enum.flat_map(&Scan.game_scores(&1, dispersion)) |> Scan.fit()

    %{Task.await(whole, :infinity) | dispersion: dispersion, scan: scan}
  end

  defp half_fit(half, opts) do
    records = Enum.map(half, &elem(&1, 1))
    regression = Task.async(fn -> Model.regression(records, opts) end)
    probes = logistic(records, opts)
    {Task.await(regression, :infinity), probes}
  end

  defp plies_of({_key, records}, {model, probes}) do
    counted = records |> Model.prepare() |> Enum.filter(&Selection.counted?/1)
    plies(counted, expectations(counted, model, probes))
  end

  defp logistic(events, opts) do
    counted = events |> Enum.flat_map(&Model.prepare/1) |> Enum.filter(&Selection.counted?/1)
    rows = Enum.map(counted, &Model.features/1)
    lambda = Keyword.get(opts, :lambda, 1.0e-4)
    ys = fn pred -> Enum.map(counted, &if(pred.(&1), do: 1, else: 0)) end

    error = Task.async(fn -> Model.logistic_fit(rows, ys.(&error?/1), lambda) end)
    blunder = Model.logistic_fit(rows, ys.(&blunder?/1), lambda)
    error = Task.await(error, :infinity)

    hardness =
      case rows do
        [] -> 1.0
        _ -> Enum.reduce(rows, 0.0, &(logistic_p(error, &1) + &2)) / length(rows)
      end

    %__MODULE__{error: error, blunder: blunder, hardness: max(hardness, 1.0e-6)}
  end

  # The model's 3×3 in the top left corner: the shipped tests stay the shipped tests.
  defp with_block(params, shipped) do
    Map.new(params, fn {level, m} ->
      small = Map.fetch!(shipped, level)

      {level,
       for {row, i} <- Enum.with_index(m) do
         for {x, j} <- Enum.with_index(row),
             do: if(i < 3 and j < 3, do: small |> Enum.at(i) |> Enum.at(j), else: x)
       end}
    end)
  end

  # --- per ply -------------------------------------------------------------------

  @doc """
  What the model and the probes expect of each counted ply; none of it
  depends on the move played, so a cheat is scored by its residuals alone.
  """
  def expectations(counted, model, %__MODULE__{} = probes) do
    Enum.map(counted, fn record ->
      x = Model.features(record)
      {mean, var} = Model.loss_moments(model, record)
      pe = logistic_p(probes.error, x)

      %{
        game: record[:game],
        p: Model.p_match(model, record),
        q: Model.p_ev(model, record),
        mean: mean,
        sd: :math.sqrt(max(var, 0.0)),
        pe: pe,
        pb: logistic_p(probes.blunder, x),
        hard: pe / probes.hardness
      }
    end)
  end

  @doc "The counted plies as `Alnasl.FairPlay.Cluster` sums them: six residuals and six spreads."
  def plies(counted, expected) do
    Enum.zip_with(counted, expected, fn record, x ->
      loss = Stats.scaled_loss(record)
      w = x.hard

      %{
        game: x.game,
        e: [
          indicator(Stats.engine_match?(record)) - x.p,
          indicator(Stats.ev_match?(record)) - x.q,
          x.mean - loss,
          x.pe - indicator(loss >= @error),
          x.pb - indicator(loss >= @blunder),
          w * (x.mean - loss)
        ],
        s: [
          bernoulli(x.p),
          bernoulli(x.q),
          x.sd,
          bernoulli(x.pe),
          bernoulli(x.pb),
          w * x.sd
        ]
      }
    end)
  end

  @doc """
  A player-event's six z's, their correlation, the scan and how many games
  it looked at: `%{zs: [...], corr: [[...]], scan: float | nil, scanned:
  integer | nil}`.
  """
  def observe(plies, %__MODULE__{} = probes) do
    {zs, corr} = plies |> Cluster.accumulate() |> Cluster.z_scores(probes.dispersion)

    {scan, scanned} =
      case Scan.result(plies, probes.dispersion, probes.scan) do
        {z, _game, scanned} -> {z, scanned}
        nil -> {nil, nil}
      end

    %{zs: zs, corr: corr, scan: scan, scanned: scanned}
  end

  @doc """
  `w·z / sqrt(wᵀ C w)` over the tests with a weight other than zero, so a
  test that is not used cannot spoil a score by having no z.
  """
  def score(%{zs: zs, corr: corr}, weights) do
    used = for {w, i} <- Enum.with_index(weights), w != 0, do: i
    pick = fn list -> Enum.map(used, &Enum.at(list, &1)) end
    Stats.combined(pick.(zs), pick.(weights), corr |> pick.() |> Enum.map(pick))
  end

  # --- small things ----------------------------------------------------------------

  defp logistic_p(beta, x) do
    t = beta |> Enum.zip(x) |> Enum.reduce(0.0, fn {b, v}, acc -> acc + b * v end)
    if t >= 0, do: 1 / (1 + :math.exp(-t)), else: :math.exp(t) / (1 + :math.exp(t))
  end

  defp bernoulli(p), do: :math.sqrt(p * (1 - p))

  defp indicator(true), do: 1.0
  defp indicator(false), do: 0.0
end
