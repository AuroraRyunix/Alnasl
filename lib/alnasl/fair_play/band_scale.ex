defmodule Alnasl.FairPlay.BandScale do
  @moduledoc """
  Per-band empirical thresholds: an optional variant of the calibration,
  not what the report uses. It exists to answer one question - would the
  false positives come out flatter across rating bands if each band were
  judged against its own spread of honest scores rather than one line at
  3 - and it is only ever reported beside the plain score
  (`Alnasl.FairPlay.Calibration`, `--band-thresholds`).

  ## Location and scale, not a quantile

  The obvious per-band threshold is each band's 99.86th percentile of
  honest scores (1 in 700). That needs thousands of player-events per
  band to estimate, and the bands that need it most have dozens. So each
  band gets a location and a scale instead - the mean and standard
  deviation of its scores - and a player-event is judged by
  `(score − mean_b) / sd_b` against the same 3. Equivalently, band `b`'s
  threshold is `mean_b + 3 · sd_b`.

  A band with few player-events is pulled towards all of them:

      mean_b' = (n_b · mean_b + k · mean) / (n_b + k)
      var_b'  = ((n_b − 1) · var_b + k · var) / (n_b − 1 + k)

  with `k = 50` pseudo-events, so a band of 17 is mostly the overall
  spread and a band of 1,500 is mostly its own. `k` was chosen before
  anything was measured and is not tuned: a test set that picks its own
  thresholds has stopped being one.

  ## Three sets, never two

  The scale is measured on player-events that neither fitted the model
  nor are counted in the false-positive table: the calibration splits its
  training events once more, by a hash of the event, into a fitting share
  and a threshold share. The held-out test events are the same ones the
  plain score is judged on, so the two tables compare like with like - on
  a model fitted on fewer games, which is the price of the third set and
  is said so beside the result.
  """

  alias Alnasl.FairPlay.Model

  @k 50

  @doc "The pseudo-event count the bands are shrunk with."
  def k, do: @k

  @doc """
  The location and scale per band from `{band, score}` pairs:
  `%{bands: %{band => {mean, sd, n}}, global: {mean, sd, n}}`.
  """
  @spec fit([{integer() | nil, float()}]) :: map()
  def fit(scored) do
    scores = Enum.map(scored, &elem(&1, 1))
    {mean, var, n} = moments(scores)

    bands =
      scored
      |> Enum.reject(&is_nil(elem(&1, 0)))
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {band, xs} ->
        {m, v, nb} = moments(xs)
        shrunk_mean = (nb * m + @k * mean) / (nb + @k)
        shrunk_var = (max(nb - 1, 0) * v + @k * var) / (max(nb - 1, 0) + @k)
        {band, {shrunk_mean, :math.sqrt(shrunk_var), nb}}
      end)

    %{bands: bands, global: {mean, :math.sqrt(var), n}}
  end

  @doc "A score on its band's scale: `(score − mean_b) / sd_b`; the overall scale for a band never seen."
  @spec adjust(map(), integer() | nil, float()) :: float()
  def adjust(%{bands: bands, global: global}, band, score) do
    {mean, sd, _n} = Map.get(bands, band, global)
    if sd > 0, do: (score - mean) / sd, else: score
  end

  @doc "What the plain threshold `t` becomes in band `band`: `mean_b + t · sd_b`."
  def threshold(%{bands: bands, global: global}, band, t) do
    {mean, sd, _n} = Map.get(bands, band, global)
    mean + t * sd
  end

  @doc "As json, for the model's meta."
  def to_json(%{bands: bands, global: {m, sd, n}}) do
    %{
      "k" => @k,
      "global" => [m, sd, n],
      "bands" => Map.new(bands, fn {b, {m, sd, n}} -> {Integer.to_string(b), [m, sd, n]} end)
    }
  end

  @doc "The band of a player-event: their rating's, as the model bands it."
  def band_of(records) do
    case Enum.find(records, &is_integer(&1[:rating])) do
      %{rating: r} -> Model.band(r)
      nil -> nil
    end
  end

  defp moments([]), do: {0.0, 1.0, 0}

  defp moments(xs) do
    n = length(xs)
    mean = Enum.sum(xs) / n

    var =
      if n > 1, do: Enum.reduce(xs, 0.0, &((&1 - mean) * (&1 - mean) + &2)) / (n - 1), else: 1.0

    {mean, var, n}
  end
end
