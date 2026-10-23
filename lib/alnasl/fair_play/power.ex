defmodule Alnasl.FairPlay.Power do
  @moduledoc """
  How many cheaters the fair-play score would catch, and not only how many
  honest players it would accuse: a synthetic-cheat benchmark over the
  calibration's label files.

  The false-positive table (`Alnasl.FairPlay.FalsePositives`) answers one
  half of the question. A score that never flags anybody passes it with
  honours. This module answers the other half, with the only cheaters a
  corpus of broadcast games can honestly supply: made-up ones.

  ## Method

    1. Read the labels, split off the held-out events exactly as
       `mix fair_play.fit` does (the same `--holdout`, the same hash), and
       fit the model on the rest - or read the model fitted that way
       (`--model`). Cheating is injected only into held-out player-events,
       which the model never saw.
    2. Each held-out player-event with a score is taken as honest (the
       false-positive table assumes the same), scored as it is, and then
       scored again once per cheating scenario: chosen counted plies have
       the played move replaced by one of the engine's MultiPV lines from
       the label, `played_cp` and `rank` set from that line, so the loss
       and both matches are exactly what that move would have scored.
       What the model expects of a ply (`p`, `q`, the loss moments) does
       not depend on the move played, so only the residuals change.
    3. The held-out events are split once more, by a hash of the event
       (`"power:"`), into a **tuning** half and a **final** half. Anything
       that is chosen - weights, a threshold for a false-positive budget,
       per-band scales - is chosen on the tuning half and reported on the
       final half, which is never used to choose anything.

  ## The cheaters (`inject/4`)

    * `{:naive, rate}` - the engine's first choice on that share of the
      counted moves, picked at random. A share of those were the first
      choice anyway, which is also true of real cheats;
    * `{:selective, rate}` - the first choice on the moves where it matters:
      the player's worst moves first (the largest scaled loss), and among
      equal ones the positions with the fewest good alternatives. The
      "one move a game" cheat, at 3-5%;
    * `{:camouflaged, rate}` - on random moves, a line picked by lot among
      those within `window` centipawns (40) of the best, the best
      included: built to keep the match rate down;
    * `{:whole_games, k}` - every counted move of `k` games, picked by lot,
      top choice, in an event of more than `k` games (so there is an honest
      game left to hide among). Events with `k` games or fewer do not take
      part in that scenario.

  ## What this cannot see

  Later plies stay as recorded. A cheater's engine move would have changed
  the opponent's reply and everything after it; here the game carries on
  as if the human move had been played. The positions, the clock and the
  time spent on the move are the honest player's: a cheater who waits for
  the phone to buzz spends time differently, and the `think` feature would
  see it, or not. The engine is the labelling engine at its node count -
  a cheater's engine is stronger or weaker, deeper or shallower. And the
  "honest" events are whatever the broadcasts contained.
  """

  alias Alnasl.FairPlay.{BandScale, Calibration, FalsePositives, Model, Probes, Selection, Stats}

  @thresholds [2.0, 2.5, 3.0, 3.5]
  @rates [0.05, 0.1, 0.2, 0.3, 0.5]
  @whole_games [1, 2, 3]
  @window 40
  @reference_rate 0.2
  @realistic_max_rate 0.3
  @nominal 3.0

  @type profile ::
          {:naive | :selective | :camouflaged, float()} | {:whole_games, pos_integer()}

  @doc "The thresholds the power table is read at."
  def thresholds, do: @thresholds

  # --- the command line ----------------------------------------------------------

  @switches [
    holdout: :float,
    model: :string,
    rates: :string,
    games: :string,
    window: :integer,
    seed: :integer,
    tune: :float,
    budget: :float,
    limit: :integer,
    out: :string
  ]

  @doc """
  `main(args)`: `run/2` from a command line. Options: `--holdout F` (the
  fit's; 0.2), `--model FILE` (a model fitted with that holdout; without
  one it is fitted here, on the same training events), `--rates
  0.05,0.1,...`, `--games 1,2,3` (the `k` of the whole-game cheat),
  `--window CP` (40), `--seed N` (1), `--tune F` (the tuning share of the
  held-out events, 0.5), `--budget F` (the false-positive budget a
  threshold is set to on the tuning half, 0.01), `--limit N` (only N
  held-out player-events, for a quick look), `--out FILE` (everything,
  as json).
  """
  def main(argv \\ System.argv(), opts \\ [halt: true]) do
    {parsed, paths, invalid} = OptionParser.parse(argv, strict: @switches)

    result =
      cond do
        invalid != [] -> {:error, {:bad_arguments, invalid}}
        paths == [] -> {:error, :usage}
        true -> parsed |> options() |> then(&run(paths, &1))
      end

    case result do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        IO.puts(:stderr, "fair_play power: " <> describe(reason))
        if opts[:halt], do: System.halt(1), else: {:error, reason}
    end
  end

  defp options(parsed) do
    Enum.map(parsed, fn
      {:rates, text} -> {:rates, numbers(text, &Float.parse/1)}
      {:games, text} -> {:games, numbers(text, &Integer.parse/1)}
      other -> other
    end)
  end

  defp numbers(text, parse) do
    text
    |> String.split(",", trim: true)
    |> Enum.map(fn part ->
      {n, ""} = parse.(String.trim(part))
      n
    end)
  end

  defp describe(:usage),
    do: "usage: mix fair_play.power --holdout F [--model FILE] [options] label-files..."

  defp describe({:model, path, why}), do: "cannot read the model #{path}: #{inspect(why)}"
  defp describe(:no_events), do: "no held-out player-event has a score; nothing to measure"
  defp describe(other), do: inspect(other)

  # --- the run ---------------------------------------------------------------------

  @doc """
  The whole benchmark over label files; prints the tables and returns
  `{:ok, summary}` (`summarise/2`'s map, plus how the model came about).
  """
  def run(paths, opts) do
    holdout = Keyword.get(opts, :holdout, 0.2)
    log = Keyword.get(opts, :log, &IO.puts/1)

    with {:ok, games, meta} <- Calibration.read_labels(paths),
         {held, train} =
           Enum.split_with(games, &Calibration.held_out?(Calibration.holdout_key(&1), holdout)),
         {:ok, model, how} <- model(opts, train, meta) do
      scenarios = scenarios(opts)
      probes = Probes.fit(Calibration.keyed_events(train), model, opts)

      results =
        held
        |> Calibration.keyed_player_events()
        |> limit(opts[:limit])
        |> Task.async_stream(&evaluate(&1, model, probes, scenarios, opts),
          max_concurrency: System.schedulers_online(),
          ordered: true,
          timeout: :infinity
        )
        |> Enum.flat_map(fn
          {:ok, nil} -> []
          {:ok, result} -> [result]
        end)

      if results == [] do
        {:error, :no_events}
      else
        summary =
          results
          |> summarise(
            Keyword.merge(opts,
              scenarios: scenarios,
              weights: model.weights,
              scan: model.scan != nil
            )
          )
          |> Map.merge(%{
            scan_calibration: Map.new(probes.scan, fn {b, {m, sd, n}} -> {b, [m, sd, n]} end),
            model: how,
            holdout: holdout,
            held_out_games: length(held),
            fitted_games: length(train)
          })

        Enum.each(format(summary), log)
        if out = opts[:out], do: File.write!(out, Jason.encode_to_iodata!(summary, pretty: true))
        {:ok, summary}
      end
    end
  end

  defp model(opts, train, meta) do
    case opts[:model] do
      nil ->
        model =
          Model.fit(Calibration.keyed_events(train),
            engine: meta["id"],
            bench: meta["bench"],
            nodes: meta["nodes"]
          )

        {:ok, model, "fitted here on the #{length(train)} training games"}

      path ->
        case Model.read(path) do
          {:ok, model} -> {:ok, model, "read from #{path}"}
          {:error, why} -> {:error, {:model, path, why}}
        end
    end
  end

  # A quick look takes a fixed sample, by hash, not the alphabet's first.
  defp limit(events, nil), do: events

  defp limit(events, n),
    do: events |> Enum.sort_by(&:crypto.hash(:sha256, inspect(elem(&1, 0)))) |> Enum.take(n)

  @doc "The scenarios of a run: every profile at every rate, and the whole-game cheats."
  def scenarios(opts \\ []) do
    rates = Keyword.get(opts, :rates, @rates)

    for(kind <- [:naive, :selective, :camouflaged], rate <- rates, do: {kind, rate / 1}) ++
      for k <- Keyword.get(opts, :games, @whole_games), do: {:whole_games, k}
  end

  @doc "A scenario as people read it: `\"selective 10%\"`, `\"whole games 2\"`."
  def label({:whole_games, k}), do: "whole games #{k}"
  def label({kind, rate}), do: "#{kind} #{round(rate * 100)}%"

  # --- injection -------------------------------------------------------------------

  @doc """
  One player-event's records with the profile's cheating injected, by a
  generator seeded from `seed` (the same seed, the same cheat). Only
  counted plies are touched (`Alnasl.FairPlay.Selection.counted?/1`); the
  others, and everything after a replaced ply, stay as recorded.
  `:not_applicable` for a whole-game cheat in an event without more games
  than it cheats in. Options: `:window` (centipawns, 40).
  """
  @spec inject([map()], profile(), term(), keyword()) :: {:ok, [map()]} | :not_applicable
  def inject(records, profile, seed, opts \\ []) do
    window = Keyword.get(opts, :window, @window)
    counted = for {r, i} <- Enum.with_index(records), Selection.counted?(r), do: {r, i}

    case pick(profile, counted, rng(seed)) do
      :not_applicable ->
        :not_applicable

      {chosen, rng} ->
        {replaced, _rng} =
          Enum.map_reduce(chosen, rng, fn {record, i}, rng ->
            {line, rng} = line(profile, record, window, rng)
            {{i, engine_choice(record, line)}, rng}
          end)

        replaced = Map.new(replaced)

        {:ok, records |> Enum.with_index() |> Enum.map(fn {r, i} -> Map.get(replaced, i, r) end)}
    end
  end

  @doc """
  The record as if the engine's line `i` (0 is the first choice) had been
  played: the move, its value and its rank from the label's own MultiPV
  lines, so the loss and both matches follow from them.
  """
  def engine_choice(%{best: best} = record, i) do
    %{move: move, cp: cp} = Enum.at(best, i)
    record |> Map.put(:played_cp, cp) |> Map.put(:rank, i + 1) |> Map.put(:played_uci, move)
  end

  defp pick({kind, rate}, counted, rng) when kind in [:naive, :camouflaged] do
    {shuffled, rng} = shuffle(counted, rng)
    {Enum.take(shuffled, share(rate, length(counted))), rng}
  end

  # The worst moves first; among equals, the fewest good alternatives; then by lot.
  defp pick({:selective, rate}, counted, rng) do
    {keyed, rng} =
      Enum.map_reduce(counted, rng, fn {record, _} = x, rng ->
        {u, rng} = :rand.uniform_s(rng)
        {{{-Stats.scaled_loss(record), record.near_count || 0, u}, x}, rng}
      end)

    chosen =
      keyed
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.take(share(rate, length(counted)))
      |> Enum.map(&elem(&1, 1))

    {chosen, rng}
  end

  defp pick({:whole_games, k}, counted, rng) do
    games = counted |> Enum.group_by(fn {r, _} -> r[:game] end) |> Enum.sort()

    if length(games) <= k do
      :not_applicable
    else
      {shuffled, rng} = shuffle(games, rng)
      {shuffled |> Enum.take(k) |> Enum.flat_map(&elem(&1, 1)), rng}
    end
  end

  defp share(rate, n), do: round(rate * n)

  defp line({:camouflaged, _}, %{best: [%{cp: top} | _] = best}, window, rng) do
    near = for {%{cp: cp}, i} <- Enum.with_index(best), cp >= top - window, do: i
    {u, rng} = :rand.uniform_s(length(near), rng)
    {Enum.at(near, u - 1), rng}
  end

  defp line(_profile, _record, _window, rng), do: {0, rng}

  defp shuffle(list, rng) do
    {keyed, rng} =
      Enum.map_reduce(list, rng, fn x, rng ->
        {u, rng} = :rand.uniform_s(rng)
        {{u, x}, rng}
      end)

    {keyed |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)), rng}
  end

  defp rng(seed) do
    <<a::32, b::32, c::32, _::binary>> =
      :crypto.hash(:sha256, inspect(seed, limit: :infinity, printable_limit: :infinity))

    :rand.seed_s(:exsss, {a + 1, b + 1, c + 1})
  end

  # --- scoring ---------------------------------------------------------------------

  @doc """
  One held-out player-event, honest and under every scenario: `nil` when it
  has no score (fewer than 40 counted moves), else a map of `:event`,
  `:player`, `:half` (`:tune` or `:final`), `:band`, `:counted`, `:games`,
  `:honest` (`Alnasl.FairPlay.Probes.observe/2`: the six z's, their
  correlation and the scan) and `:cheats` (scenario => the same, without
  the scenarios that do not apply).
  """
  def evaluate({{event, player}, records}, model, probes, scenarios, opts) do
    counted = records |> Model.prepare() |> Enum.filter(&Selection.counted?/1)
    n = length(counted)

    with true <- n >= Stats.min_moves(),
         expected = Probes.expectations(counted, model, probes),
         observe = &(&1 |> Probes.plies(expected) |> Probes.observe(probes)),
         honest = observe.(counted),
         score when is_number(score) <- shipped(honest, model.weights, model.scan != nil) do
      seed = Keyword.get(opts, :seed, 1)

      cheats =
        for scenario <- scenarios,
            {:ok, injected} <- [inject(counted, scenario, {seed, event, player, scenario}, opts)],
            into: %{},
            do: {scenario, observe.(injected)}

      split = if event, do: "event:" <> event, else: "game:" <> to_string(hd(counted)[:game])

      %{
        event: event,
        player: player,
        half:
          if(Calibration.in_share?("power:", split, Keyword.get(opts, :tune, 0.5)),
            do: :tune,
            else: :final
          ),
        band: BandScale.band_of(records),
        counted: n,
        games: counted |> Enum.map(& &1[:game]) |> Enum.uniq() |> length(),
        honest: honest,
        cheats: cheats
      }
    else
      _ -> nil
    end
  end

  @doc """
  The report's score from an observation: the event score with the
  model's weights, or the scan when that is larger and the model has one
  (`Alnasl.FairPlay.Stats`).
  """
  def shipped(obs, weights, scan?) do
    event = Probes.score(obs, pad(weights))

    cond do
      not is_number(event) -> nil
      scan? and is_number(obs.scan) -> max(event, obs.scan)
      true -> event
    end
  end

  @doc "A weight vector of the shipped three, as six: the probes' weights zero."
  def pad(weights), do: weights ++ List.duplicate(0.0, length(Probes.tests()) - length(weights))

  # --- the summary -----------------------------------------------------------------

  @named [
    {"default", [1.0, 1.0, 1.0]},
    {"MM only", [1.0, 0.0, 0.0]},
    {"EV only", [0.0, 1.0, 0.0]},
    {"ASD only", [0.0, 0.0, 1.0]},
    {"MM-heavy", [2.0, 1.0, 1.0]},
    {"ASD-heavy", [1.0, 1.0, 2.0]},
    {"MM+ASD", [1.0, 0.0, 1.0]}
  ]

  # The probes (`Alnasl.FairPlay.Probes`), in its order: MM, EV, ASD,
  # error avoidance, blunder avoidance, hard ASD.
  @probed [
    {"+error", [1.0, 1.0, 1.0, 1.0, 0.0, 0.0]},
    {"+blunder", [1.0, 1.0, 1.0, 0.0, 1.0, 0.0]},
    {"+hard ASD", [1.0, 1.0, 1.0, 0.0, 0.0, 1.0]},
    {"hard ASD for ASD", [1.0, 1.0, 0.0, 0.0, 0.0, 1.0]},
    {"+error+hard ASD", [1.0, 1.0, 1.0, 1.0, 0.0, 1.0]},
    {"error only", [0.0, 0.0, 0.0, 1.0, 0.0, 0.0]},
    {"hard ASD only", [0.0, 0.0, 0.0, 0.0, 0.0, 1.0]}
  ]

  # The scan is added to the event score as `max(score, scan − offset)`:
  # the offset is what keeps the union from flagging more honest players
  # than the score alone.
  @scan_offsets [0.0, 0.5, 1.0]

  @grid [0.0, 0.5, 1.0, 2.0, 3.0]

  @doc """
  The tables from `evaluate/4`'s results. Options: `:scenarios`,
  `:weights` (the model's, the default), `:budget` (0.01).

    * `false_positives` - the honest scores of all the events, at
      `thresholds/0`, with exact 95% intervals;
    * `power` - per scenario, the share of the cheating player-events
      scoring at least each threshold, the same way, and the mean shift of
      each test's z (MM, EV, ASD) the cheat caused: which test noticed;
    * `breakdown` - at 3.0, per profile at 20% (and one whole game), by
      counted moves, games and rating, with the honest events of the same
      cell beside it;
    * `variants` - weights and per-band thresholds, chosen and set on the
      tuning half, reported on the final half (`variants/3`).
  """
  def summarise(results, opts) do
    scenarios = Keyword.fetch!(opts, :scenarios)
    weights = Keyword.get(opts, :weights, [1.0, 1.0, 1.0])
    budget = Keyword.get(opts, :budget, 0.01)
    scan? = Keyword.get(opts, :scan, false)
    score = &shipped(&1, weights, scan?)

    %{
      events: length(results),
      tune_events: Enum.count(results, &(&1.half == :tune)),
      final_events: Enum.count(results, &(&1.half == :final)),
      budget: budget,
      false_positives: rows(Enum.map(results, &score.(&1.honest))),
      power:
        for scenario <- scenarios do
          applicable = Enum.filter(results, &Map.has_key?(&1.cheats, scenario))

          %{
            scenario: label(scenario),
            events: length(applicable),
            rows: rows(Enum.map(applicable, &score.(&1.cheats[scenario]))),
            honest_rows: rows(Enum.map(applicable, &score.(&1.honest))),
            delta_z: delta_z(applicable, scenario)
          }
        end,
      breakdown: breakdown(results, scenarios, score),
      scan: scan?,
      variants: variants(results, scenarios, budget, scan?)
    }
  end

  defp rows(scores) do
    n = length(scores)

    for t <- @thresholds do
      k = Enum.count(scores, &(&1 >= t))
      {low, high} = FalsePositives.interval(k, n)
      %{threshold: t, above: k, events: n, rate: if(n > 0, do: k / n), low: low, high: high}
    end
  end

  # The mean change of each z, and of the scan, over the events where both
  # sides have one.
  defp delta_z(results, scenario) do
    zs = fn obs -> obs.zs ++ [obs.scan] end

    results
    |> Enum.map(fn r -> Enum.zip(zs.(r.cheats[scenario]), zs.(r.honest)) end)
    |> Enum.zip_with(fn pairs ->
      case for({a, b} <- pairs, is_number(a) and is_number(b), do: a - b) do
        [] -> nil
        ds -> Enum.sum(ds) / length(ds)
      end
    end)
    |> case do
      [] -> List.duplicate(nil, length(Probes.tests()) + 1)
      means -> means
    end
  end

  # --- by event length and rating ------------------------------------------------

  defp breakdown(results, scenarios, score) do
    reference =
      Enum.filter(scenarios, fn
        {:whole_games, k} -> k == 1
        {_kind, rate} -> rate == @reference_rate
      end)

    for scenario <- reference,
        {dimension, bucket} <- [
          {"counted moves", &moves_bucket/1},
          {"games", &games_bucket/1},
          {"rating", &rating_bucket/1}
        ] do
      cells =
        results
        |> Enum.filter(&Map.has_key?(&1.cheats, scenario))
        |> Enum.group_by(bucket)
        |> Enum.sort_by(fn {name, _} -> bucket_order(name) end)
        |> Enum.map(fn {name, rs} ->
          n = length(rs)
          hit = Enum.count(rs, &(score.(&1.cheats[scenario]) >= @nominal))
          fp = Enum.count(rs, &(score.(&1.honest) >= @nominal))
          %{bucket: name, events: n, detected: hit, rate: hit / n, honest_above: fp}
        end)

      %{scenario: label(scenario), by: dimension, cells: cells}
    end
  end

  defp moves_bucket(%{counted: n}) when n < 100, do: "40-99"
  defp moves_bucket(%{counted: n}) when n < 200, do: "100-199"
  defp moves_bucket(_), do: "200+"

  defp games_bucket(%{games: g}) when g <= 2, do: "1-2"
  defp games_bucket(%{games: g}) when g <= 5, do: "3-5"
  defp games_bucket(_), do: "6+"

  defp rating_bucket(%{band: b}) when is_integer(b) and b < 1600, do: "<1600"
  defp rating_bucket(%{band: b}) when is_integer(b) and b < 2000, do: "1600-1999"
  defp rating_bucket(%{band: b}) when is_integer(b) and b < 2400, do: "2000-2399"
  defp rating_bucket(_), do: "2400+"

  defp bucket_order(name),
    do:
      Enum.find_index(
        ~w(40-99 100-199 200+ 1-2 3-5 6+ <1600 1600-1999 2000-2399 2400+),
        &(&1 == name)
      )

  # --- variants --------------------------------------------------------------------

  @doc """
  The scenarios the variants are judged on: the ones a cheater who wants
  to keep playing would use - selective and camouflaged up to 30%, and a
  single whole game. A naive 50% engine user is caught by everything and
  says nothing about the difference between two scores.
  """
  def realistic?({kind, rate}) when kind in [:selective, :camouflaged],
    do: rate <= @realistic_max_rate

  def realistic?({:whole_games, k}), do: k == 1
  def realistic?(_scenario), do: false

  @doc """
  Each variant, judged two ways, both on the **final** half:

    * at the threshold that spends the false-positive `budget` on the
      tuning half's honest events (the same budget for every variant, so
      power is compared at equal cost); the false-positive rate it then
      has on the final half is reported beside it;
    * at the report's own 3.0 - the threshold the gate is about - with
      its false positives on the final half and on all the held-out events.

  Power is pooled over the realistic scenarios (`realistic?/1`), and each
  variant's difference from the default is paired (the same events, the
  same cheats) with a 95% interval over events. The variants: the named
  weight vectors, the per-band thresholds of `Alnasl.FairPlay.BandScale`
  with their scales measured on the tuning half's honest scores, and
  `fitted` - the weight vector of a coarse grid with the most realistic
  power at the budget threshold *on the tuning half* - the probes of
  `Alnasl.FairPlay.Probes` as weights over six tests, and the per-game
  scan as `max(event, scan − offset)`. With `scan?` (the model has a scan,
  so the shipped score uses it) the default is the event score or the
  scan, every weighting is judged with the scan, and "no scan" is a
  variant. `verdict` says whether any of them beats the default on the
  final half at both thresholds without more false positives at 3.0, and
  picks among several by the tuning half.
  """
  def variants(results, scenarios, budget, scan? \\ false) do
    realistic = Enum.filter(scenarios, &realistic?/1)
    tune = Enum.filter(results, &(&1.half == :tune))
    final = Enum.filter(results, &(&1.half == :final))

    event = fn w ->
      w = pad(w)
      fn obs, _band -> number(Probes.score(obs, w)) end
    end

    scanned = fn scorer, offset ->
      fn obs, band -> max(scorer.(obs, band), number(obs.scan && obs.scan - offset)) end
    end

    # With a scan in the shipped score, every weighting is judged with it:
    # the question is then what the event part adds, not whether a score
    # without the scan misses whole games (it does).
    by_weights = if scan?, do: &scanned.(event.(&1), 0.0), else: event

    fitted_weights =
      grid()
      |> Enum.max_by(fn w ->
        scorer = by_weights.(w)
        t = budget_threshold(tune, scorer, budget)
        {pooled_power(tune, realistic, scorer, t) || 0.0, -distance(w, [1.0, 1.0, 1.0])}
      end)

    default = by_weights.([1.0, 1.0, 1.0])
    scale = tune |> Enum.map(&{&1.band, default.(&1.honest, &1.band)}) |> BandScale.fit()

    banded = fn zc, band -> BandScale.adjust(scale, band, default.(zc, band)) end

    candidates =
      Enum.map(@named, fn {name, w} -> {name, w, by_weights.(w)} end) ++
        [
          {"fitted", fitted_weights, by_weights.(fitted_weights)},
          {"per-band thresholds", [1.0, 1.0, 1.0], banded}
        ] ++
        Enum.map(@probed, fn {name, w} -> {name, w, by_weights.(w)} end) ++
        scan_rows(scan?, event.([1.0, 1.0, 1.0]), scanned) ++
        [{"scan only", [], fn obs, _band -> number(obs.scan) end}]

    judged =
      Enum.map(candidates, fn {name, w, scorer} ->
        judge(name, w, scorer, default, results, tune, final, realistic, budget)
      end)

    %{
      realistic: Enum.map(realistic, &label/1),
      fitted_weights: fitted_weights,
      rows: judged,
      verdict: verdict(judged)
    }
  end

  defp scan_rows(true, event, scanned) do
    [{"no scan", [1.0, 1.0, 1.0], event}] ++
      for d <- tl(@scan_offsets), do: {"scan, offset #{d}", [1.0, 1.0, 1.0], scanned.(event, d)}
  end

  defp scan_rows(false, event, scanned),
    do: for(d <- @scan_offsets, do: {"scan, offset #{d}", [1.0, 1.0, 1.0], scanned.(event, d)})

  defp judge(name, w, scorer, default, all, tune, final, realistic, budget) do
    t_budget = budget_threshold(tune, scorer, budget)
    t_default = budget_threshold(tune, default, budget)

    %{
      variant: name,
      weights: w,
      tune_threshold: t_budget,
      tune_power: pooled_power(tune, realistic, scorer, t_budget),
      tune_fp_at_3: honest_rate(tune, scorer, @nominal),
      tune_power_at_3: pooled_power(tune, realistic, scorer, @nominal),
      tune_diff_at_3: paired(tune, realistic, scorer, @nominal, default, @nominal),
      final_fp_at_budget: honest_rate(final, scorer, t_budget),
      final_power_at_budget: pooled_power(final, realistic, scorer, t_budget),
      final_diff_at_budget: paired(final, realistic, scorer, t_budget, default, t_default),
      final_fp_at_3: honest_rate(final, scorer, @nominal),
      all_fp_at_3: honest_rate(all, scorer, @nominal),
      final_power_at_3: pooled_power(final, realistic, scorer, @nominal),
      final_diff_at_3: paired(final, realistic, scorer, @nominal, default, @nominal),
      final_power_by_scenario_at_3: by_scenario(final, realistic, scorer, @nominal),
      final_power_by_scenario_at_budget: by_scenario(final, realistic, scorer, t_budget),
      final_one_game_by_games_at_3:
        for bucket <- ~w(1-2 3-5 6+) do
          s = {:whole_games, 1}

          applicable =
            Enum.filter(final, &(Map.has_key?(&1.cheats, s) and games_bucket(&1) == bucket))

          %{
            games: bucket,
            events: length(applicable),
            rate: share_at(applicable, &scorer.(&1.cheats[s], &1.band), @nominal)
          }
        end
    }
  end

  defp by_scenario(events, scenarios, scorer, t) do
    Enum.map(scenarios, fn s ->
      applicable = Enum.filter(events, &Map.has_key?(&1.cheats, s))
      %{scenario: label(s), rate: share_at(applicable, &scorer.(&1.cheats[s], &1.band), t)}
    end)
  end

  # No score is no flag: nil compares above every number in Erlang's order,
  # which is the wrong way round for a threshold.
  defp number(x) when is_number(x), do: x
  defp number(_none), do: -1.0e9

  defp grid do
    for a <- @grid, b <- @grid, c <- @grid, a + b + c > 0 do
      top = Enum.max([a, b, c])
      Enum.map([a, b, c], &Float.round(&1 / top, 6))
    end
    |> Enum.uniq()
  end

  defp distance(a, b), do: a |> Enum.zip_with(b, &((&1 - &2) * (&1 - &2))) |> Enum.sum()

  # The lowest threshold at which at most `budget` of the honest events score.
  @doc false
  def budget_threshold(events, scorer, budget) do
    scores = events |> Enum.map(&scorer.(&1.honest, &1.band)) |> Enum.sort(:desc)
    allowed = floor(budget * length(scores))

    case Enum.at(scores, allowed) do
      nil -> @nominal
      score -> score + 1.0e-9
    end
  end

  defp honest_rate(events, scorer, t) do
    n = length(events)
    k = Enum.count(events, &(scorer.(&1.honest, &1.band) >= t))
    {low, high} = FalsePositives.interval(k, n)
    %{above: k, events: n, rate: if(n > 0, do: k / n), low: low, high: high}
  end

  defp share_at([], _score, _t), do: nil
  defp share_at(events, score, t), do: Enum.count(events, &(score.(&1) >= t)) / length(events)

  defp pooled_power(events, scenarios, scorer, t) do
    pairs =
      for r <- events, s <- scenarios, Map.has_key?(r.cheats, s), do: scorer.(r.cheats[s], r.band)

    if pairs == [], do: nil, else: Enum.count(pairs, &(&1 >= t)) / length(pairs)
  end

  # Per event, the variant's detections minus the default's over the same
  # cheats; the mean over events, with a normal 95% interval.
  defp paired(events, scenarios, scorer, t, default, t_default) do
    diffs =
      for r <- events,
          applicable = Enum.filter(scenarios, &Map.has_key?(r.cheats, &1)),
          applicable != [] do
        hits = fn f, th ->
          Enum.count(applicable, &(f.(r.cheats[&1], r.band) >= th)) / length(applicable)
        end

        hits.(scorer, t) - hits.(default, t_default)
      end

    n = length(diffs)

    if n < 2 do
      %{diff: nil, low: nil, high: nil}
    else
      mean = Enum.sum(diffs) / n
      sd = :math.sqrt(Enum.reduce(diffs, 0.0, &((&1 - mean) * (&1 - mean) + &2)) / (n - 1))
      half = 1.96 * sd / :math.sqrt(n)
      %{diff: mean, low: mean - half, high: mean + half}
    end
  end

  defp verdict(judged) do
    default = Enum.find(judged, &(&1.variant == "default"))

    winners =
      Enum.filter(judged, fn v ->
        v.variant != "default" and is_number(v.final_diff_at_budget.low) and
          v.final_diff_at_budget.low > 0 and is_number(v.final_diff_at_3.low) and
          v.final_diff_at_3.low > 0 and v.all_fp_at_3.above <= default.all_fp_at_3.above
      end)

    case winners do
      [] ->
        "keep the default: no variant is shown to catch more on the final half at both " <>
          "thresholds without more false positives at 3.0"

      _ ->
        # Which of several winners: the tuning half says, not the final one.
        best = Enum.max_by(winners, & &1.tune_diff_at_3.diff)

        "candidate: #{best.variant} #{inspect(best.weights)} catches more on the final half " <>
          "at both thresholds, with no more false positives at 3.0 on the held-out events"
    end
  end

  # --- printing --------------------------------------------------------------------

  @doc false
  def format(s) do
    pct = fn
      nil -> "-"
      x -> :erlang.float_to_binary(x * 100, decimals: 1) <> "%"
    end

    pct2 = fn x -> :erlang.float_to_binary(x * 100, decimals: 2) <> "%" end

    two = fn
      nil -> "-"
      x -> :erlang.float_to_binary(x / 1, decimals: 2)
    end

    cell = fn r -> "#{pct.(r.rate)} (#{pct.(r.low)}-#{pct.(r.high)})" end
    pad = fn text, n -> String.pad_trailing(text, n) end
    header = Enum.map_join(@thresholds, "", &pad.(">= #{&1}", 22))

    [
      "fair_play power: model #{s.model}; holdout #{s.holdout}, #{s.held_out_games} games held out, " <>
        "#{s.events} player-events with a score (tuning #{s.tune_events}, final #{s.final_events})",
      "the score: " <>
        if(s.scan,
          do: "the larger of the event score and the per-game scan",
          else: "the event score (the model has no scan calibration)"
        ),
      "",
      "detection (share of cheating player-events at or over; 95% exact) and the mean change in each z:",
      pad.("scenario", 18) <>
        pad.("events", 8) <> header <> "dMM   dEV   dASD  dERR  dBLN  dHASD dSCAN",
      pad.("honest (FP)", 18) <>
        pad.("#{s.events}", 8) <>
        Enum.map_join(s.false_positives, "", fn r ->
          pad.("#{r.above}, " <> pct2.(r.rate), 22)
        end)
    ] ++
      Enum.map(s.power, fn p ->
        pad.(p.scenario, 18) <>
          pad.("#{p.events}", 8) <>
          Enum.map_join(p.rows, "", &pad.(cell.(&1), 22)) <>
          Enum.map_join(p.delta_z, " ", &pad.(two.(&1), 5))
      end) ++
      ["", "at 3.0, by event (detected/events, honest at 3.0 in the same cell):"] ++
      Enum.map(s.breakdown, fn b ->
        "  #{pad.(b.scenario, 16)} by #{pad.(b.by, 14)}" <>
          Enum.map_join(b.cells, "  ", fn c ->
            "#{c.bucket}: #{pct.(c.rate)} of #{c.events} (#{c.honest_above})"
          end)
      end) ++
      format_variants(s.variants, s.budget, pct, two, pad)
  end

  defp format_variants(v, budget, pct, two, pad) do
    diff = fn
      %{diff: nil} -> "-"
      d -> "#{two.(d.diff * 100)} (#{two.(d.low * 100)} to #{two.(d.high * 100)}) pts"
    end

    fp = fn r -> "#{r.above}/#{r.events}" end

    [
      "",
      "VARIANTS - chosen and thresholded on the tuning half, reported on the final half.",
      "realistic scenarios pooled: " <> Enum.join(v.realistic, ", "),
      "fitted weights (grid, tuning half): #{inspect(v.fitted_weights)}",
      "(a) at the threshold spending #{pct.(budget)} false positives on the tuning half:",
      pad.("  variant", 22) <>
        pad.("weights", 31) <>
        pad.("thr", 7) <> pad.("FP final", 13) <> pad.("power", 9) <> "vs default"
    ] ++
      Enum.map(v.rows, fn r ->
        pad.("  " <> r.variant, 22) <>
          pad.(Enum.map_join(r.weights, ",", &two.(&1)), 31) <>
          pad.(two.(r.tune_threshold), 7) <>
          pad.(fp.(r.final_fp_at_budget), 13) <>
          pad.(pct.(r.final_power_at_budget), 9) <> diff.(r.final_diff_at_budget)
      end) ++
      [
        "(b) at 3.0, the report's threshold:",
        pad.("  variant", 22) <>
          pad.("FP tune", 11) <>
          pad.("tune", 8) <>
          pad.("FP final", 11) <> pad.("FP all", 11) <> pad.("power", 9) <> "vs default"
      ] ++
      Enum.map(v.rows, fn r ->
        pad.("  " <> r.variant, 22) <>
          pad.(fp.(r.tune_fp_at_3), 11) <>
          pad.(pct.(r.tune_power_at_3), 8) <>
          pad.(fp.(r.final_fp_at_3), 11) <>
          pad.(fp.(r.all_fp_at_3), 11) <>
          pad.(pct.(r.final_power_at_3), 9) <> diff.(r.final_diff_at_3)
      end) ++
      per_scenario(v.rows, :final_power_by_scenario_at_3, "(c) at 3.0", pct, pad) ++
      per_scenario(
        v.rows,
        :final_power_by_scenario_at_budget,
        "(d) at the budget threshold",
        pct,
        pad
      ) ++
      [
        "(e) one whole game at 3.0, final half, by games in the event:",
        pad.("  variant", 22) <>
          Enum.map_join(hd(v.rows).final_one_game_by_games_at_3, "", fn c ->
            pad.("#{c.games} (#{c.events})", 14)
          end)
      ] ++
      Enum.map(v.rows, fn r ->
        pad.("  " <> r.variant, 22) <>
          Enum.map_join(r.final_one_game_by_games_at_3, "", &pad.(pct.(&1.rate), 14))
      end) ++
      ["verdict: " <> v.verdict]
  end

  defp per_scenario(rows, key, title, pct, pad) do
    [
      title <> ", final half, per realistic scenario:",
      pad.("  variant", 22) <>
        Enum.map_join(Map.fetch!(hd(rows), key), "", &pad.(&1.scenario, 17))
    ] ++
      Enum.map(rows, fn r ->
        pad.("  " <> r.variant, 22) <>
          Enum.map_join(Map.fetch!(r, key), "", &pad.(pct.(&1.rate), 17))
      end)
  end
end
