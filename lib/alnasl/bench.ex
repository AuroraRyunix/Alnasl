defmodule Alnasl.Bench do
  @moduledoc """
  The tracker's proof bench: plays games through the simulator with faults and
  says what the tracker made of each. The tests assert on it, `mix
  alnasl.bench` prints it, and the Recordings page uses `judge/2` for a dry
  run of a capture.

  ## Verdicts

  For one game, comparing the moves the tracker ended with to the moves that
  were really played:

  - `:exact` - the same moves, and the tracker ended in sync;
  - `:ambiguous` - the tracker stopped at a point where several move
    sequences explain the board, raised it, and the true continuation is one
    of the candidates it kept following. Nothing wrong was emitted;
  - `:alarm` - the tracker stopped, raised out-of-sync, and what it emitted
    until then is right;
  - `:flagged` - the moves differ from the game, and the tracker said so at
    the point of difference: the ply there is flagged `:recovered` or
    `:assumed`, or it reported a takeback there;
  - `:silent` - the moves differ and nothing was said, or moves are missing
    with no alarm. **This is the one that must never happen.**
  """

  alias Alnasl.{Pgn, Session, Tracker}
  alias Alnasl.Simulator.Script

  @type verdict :: :exact | :ambiguous | :alarm | :flagged | :silent

  @doc """
  Plays `sans` with the simulator options `sim` through a tracker with
  options `tracker`. Returns a map: `:verdict`, `:alarms` (times the status
  became out-of-sync), `:corrections`, `:recovered` (plies), `:stats` (the
  tracker's search statistics), `:log` (the faults played), `:session`, `:out`.
  """
  def play(sans, sim \\ %{}, tracker \\ []) do
    script = Script.build(sans, sim)
    {session, out} = Session.run(Session.new(tracker), script.events)

    session
    |> judge(out, sans)
    |> Map.merge(%{log: script.log, session: session, out: out, duration_ms: script.duration_ms})
  end

  @doc "The verdict on a finished run, given the moves that were really played."
  def judge(session, out, truth) do
    tr = session.tracker
    mine = Tracker.sans(tr)
    difference = Pgn.first_difference(mine, truth)

    verdict =
      cond do
        difference == :same and tr.status in [:live, :waiting_start, :settling] ->
          :exact

        difference == :same ->
          :alarm

        prefix?(mine, truth) and tr.status == :out_of_sync and tr.candidates != [] ->
          if Enum.any?(Tracker.candidates(tr), &prefix?(mine ++ &1, truth)),
            do: :ambiguous,
            else: :alarm

        prefix?(mine, truth) and tr.status == :out_of_sync ->
          :alarm

        prefix?(mine, truth) ->
          :silent

        true ->
          {ply, _mine, _truth} = difference
          if said_so?(tr, out, ply), do: :flagged, else: :silent
      end

    %{
      verdict: verdict,
      difference: difference,
      alarms: Enum.count(out, &match?({_t, {:status, :out_of_sync, _}}, &1)),
      corrections: Enum.count(out, &match?({_t, {:correction, _, _, _}}, &1)),
      takebacks: Enum.count(out, &match?({_t, {:correction, _, _, :takeback}}, &1)),
      recovered: Enum.count(tr.plies, &(:recovered in &1.flags)),
      assumed: Enum.count(tr.plies, &(:assumed in &1.flags)),
      warnings: Enum.count(out, &match?({_t, {:warning, _, _, _}}, &1)),
      stats: tr.stats
    }
  end

  defp prefix?(short, long),
    do: Pgn.first_difference(short, Enum.take(long, length(short))) == :same

  # Did the tracker mark the place where its game leaves the real one? Either
  # the ply there (or one before it, when a whole recovered run is off) is
  # flagged, or a takeback was reported that cut the game at or before it.
  defp said_so?(tr, out, ply) do
    flagged? =
      tr.plies
      |> Enum.slice(max(ply - 4, 0)..(ply - 1)//1)
      |> Enum.any?(&(&1.flags -- [:long_gap] != []))

    cut? =
      Enum.any?(out, fn
        {_t, {:correction, keep, _plies, :takeback}} -> keep < ply
        _other -> false
      end)

    flagged? or cut?
  end

  @doc """
  Plays every game in `games` (`Alnasl.Pgn` games) `passes` times with `sim`
  (a function of `{game_index, pass}` to simulator options, or a map) and
  tallies the verdicts.
  """
  def matrix(games, sim, tracker \\ [], passes \\ 1) do
    runs =
      for(pass <- 1..passes, {game, index} <- Enum.with_index(games, 1), do: {pass, game, index})
      |> Task.async_stream(
        fn {pass, game, index} ->
          options = if is_function(sim), do: sim.({index, pass}), else: sim
          options = Map.put_new(Map.new(options), :seed, index * 1000 + pass)
          {index, play(game.moves, options, tracker)}
        end,
        timeout: :infinity,
        ordered: true
      )
      |> Enum.map(fn {:ok, run} -> run end)

    results = Enum.map(runs, &elem(&1, 1))

    %{
      games: length(results),
      plies: results |> Enum.map(&length(&1.session.tracker.plies)) |> Enum.sum(),
      verdicts: Enum.frequencies_by(results, & &1.verdict),
      alarms: results |> Enum.map(& &1.alarms) |> Enum.sum(),
      corrections: results |> Enum.map(& &1.corrections) |> Enum.sum(),
      recovered: results |> Enum.map(& &1.recovered) |> Enum.sum(),
      faults: results |> Enum.map(&length(&1.log)) |> Enum.sum(),
      searches: results |> Enum.map(& &1.stats.searches) |> Enum.sum(),
      max_nodes: results |> Enum.map(& &1.stats.max_nodes) |> Enum.max(fn -> 0 end),
      max_search_ms: (results |> Enum.map(& &1.stats.max_us) |> Enum.max(fn -> 0 end)) / 1000,
      budget_hits: results |> Enum.map(& &1.stats.budget_hits) |> Enum.sum(),
      bad: for({index, r} <- runs, r.verdict == :silent, do: {index, r.difference, r.log}),
      runs: Enum.map(runs, fn {index, r} -> {index, Map.drop(r, [:out])} end)
    }
  end

  @doc """
  The fault mixes the bench reports on, as `{name, kind, simulator options,
  tracker options}`. The last three are fast play
  (`Alnasl.Simulator.Script.profile(:bullet)`): at speed alone, with the
  tracker as it comes and with the Setup page's "Bullet / fast play"; and
  with the hands of a time scramble, with that preset.
  """
  def suites do
    bullet = Script.profile(:bullet)
    fast = Map.to_list(Tracker.preset(:bullet))

    for({name, kind, sim} <- classical(), do: {name, kind, sim, []}) ++
      [
        {"bullet speed, no faults, default settings", :fast_default,
         Map.put(bullet, :faults, %{}), []},
        {"bullet speed, no faults, fast-play preset", :fast_clean, Map.put(bullet, :faults, %{}),
         fast},
        {"bullet: slams, knocks, missed plies; preset", :bullet, bullet, fast}
      ]
  end

  defp classical do
    benign = [:hover, :lift, :knock, :swap, :clock_miss, :leave_pawn]

    [{"clean, with a clock", :exact, %{}}, {"clean, no clock", :exact, %{clock: false}}] ++
      for(fault <- benign, do: {"#{fault} 20%", :exact, %{faults: %{fault => 0.2}}}) ++
      [
        {"takeback 20%", :exact, %{faults: %{takeback: 0.2}}},
        {"slide 30%", :exact, %{faults: %{slide: 0.3}}},
        {"all of the above, 8% each", :exact,
         %{faults: Map.new(benign ++ [:takeback, :slide], &{&1, 0.08})}},
        {"missed 10% (one ply at a time)", :gap2, %{faults: %{missed: 0.1}}},
        {"missed 10% + the others 5%", :gap2,
         %{faults: Map.new(benign ++ [:takeback, :slide], &{&1, 0.05}) |> Map.put(:missed, 0.1)}},
        {"unplugged for 2 plies, twice", :gap2, %{unplug: [{9, 2}, {21, 2}]}},
        {"missed 25%, up to 3 plies in a row", :long,
         %{faults: %{missed: 0.25}, missed_streak: 3}},
        {"unplugged for 3 plies", :long, %{unplug: [{11, 3}]}},
        {"unplugged for 8 plies", :lost, %{unplug: [{11, 8}]}},
        {"an illegal move at ply 12, played on", :illegal, %{illegal_at: 12}}
      ]
  end
end
