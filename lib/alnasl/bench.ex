defmodule Alnasl.Bench do
  @moduledoc """
  The tracker's proof bench: plays games through the simulator with faults and
  says what the tracker made of each. The tests assert on it, `mix
  alnasl.bench` prints it, and the Recordings page uses `judge/2` for a dry
  run of a capture.

  ## Verdicts

  For one game, comparing the moves the tracker ended with to the moves that
  were really played:

  - `:exact` - the same moves, the tracker ended in sync, and it saw every
    one of them;
  - `:reconstructed_right` - the same moves, some of them worked out from
    the position because they were not seen one by one, each time with one
    path only (marked `:recovered`, shown orange);
  - `:guessed_right` - the same moves, and somewhere there was more than
    one path and the tracker took the right one (marked `:guessed`, red);
  - `:reconstructed_wrong`, `:guessed_wrong` - the moves differ from the
    game, and the place where they first differ is such a marked move;
  - `:assumed` - every move went from and to the squares it did in the
    game, and the one thing that differs is what a pawn became, at a
    promotion marked `:assumed`: the new piece was never on the board to
    be read, and the box said it took the usual one;
  - `:flagged` - the moves differ, and the place is marked otherwise: a
    piece not seen, a takeback reported there;
  - `:alarm` - the tracker stopped, raised out-of-sync, and what it emitted
    until then is right;
  - `:unnoticed` - the moves differ at a move the simulator had the board
    misread (`:between`), nothing marks it or anything after it, and
    nothing could: see `unnoticed/3`;
  - `:warned` - the moves differ and nothing marks the place, but the
    clock says moves are missing, and the tile says so: "Move missing?"
    stands at the end (more presses than moves, by two). Moves nobody saw,
    in a position that came round again, leave nothing else behind;
  - `:silent` - the moves differ and nothing marks the place, or moves are
    missing with no alarm and no warning. **This is the one that must
    never happen.**
  """

  alias Alnasl.{Pgn, Session, Tracker}
  alias Alnasl.Simulator.Script

  @type verdict ::
          :exact
          | :reconstructed_right
          | :reconstructed_wrong
          | :guessed_right
          | :guessed_wrong
          | :assumed
          | :flagged
          | :alarm
          | :unnoticed
          | :warned
          | :silent

  @doc """
  Plays `sans` with the simulator options `sim` through a tracker with
  options `tracker`. Returns a map: `:verdict`, `:alarms` (times the status
  became out-of-sync), `:corrections`, `:recovered` (plies), `:stats` (the
  tracker's search statistics), `:log` (the faults played), `:session`, `:out`.
  """
  def play(sans, sim \\ %{}, tracker \\ []) do
    script = Script.build(sans, sim)
    {session, out} = Session.run(Session.new(tracker), script.events)
    # The game as the simulator played it: `:promotion_capture` ends it early.
    sans = script.sans

    session
    |> judge(out, sans)
    |> then(fn judged ->
      from = if is_tuple(judged.difference), do: elem(judged.difference, 0), else: 0
      later = session.tracker.plies |> Enum.drop(from) |> Enum.flat_map(& &1.flags)
      unnoticed(judged, script.log, later)
    end)
    |> Map.merge(%{log: script.log, session: session, out: out, duration_ms: script.duration_ms})
  end

  # A piece set down between two squares and read on the wrong one, where
  # the game first differs - and nothing marked. The board said so and
  # never took it back: every move after it was legal with the piece where
  # it was read. No reading tells this game from the one played, so it is
  # counted, and not as the tracker's silence.
  defp unnoticed(%{verdict: verdict, difference: {ply, _mine, _truth}} = judged, log, later)
       when verdict in [:silent, :warned] do
    cond do
      {ply, :between} not in log -> judged
      # It was found out after all, and what the box then made of it is
      # marked - wrongly, since the misread move stands.
      :guessed in later -> %{judged | verdict: :guessed_wrong}
      :recovered in later -> %{judged | verdict: :reconstructed_wrong}
      true -> %{judged | verdict: :unnoticed}
    end
  end

  defp unnoticed(judged, _log, _later), do: judged

  @doc "The verdict on a finished run, given the moves that were really played."
  def judge(session, out, truth) do
    tr = session.tracker
    mine = Tracker.sans(tr)
    difference = Pgn.first_difference(mine, truth)

    marks = tr.plies |> Enum.flat_map(& &1.flags) |> Enum.uniq()

    verdict =
      cond do
        difference == :same and tr.status == :out_of_sync -> :alarm
        difference == :same and :guessed in marks -> :guessed_right
        difference == :same and :recovered in marks -> :reconstructed_right
        difference == :same -> :exact
        prefix?(mine, truth) and tr.status == :out_of_sync -> :alarm
        prefix?(mine, truth) -> :silent
        assumed?(tr, truth, elem(difference, 0)) -> :assumed
        true -> wrong(tr, out, elem(difference, 0))
      end
      |> warned(session)

    %{
      verdict: verdict,
      difference: difference,
      alarms: Enum.count(out, &match?({_t, {:status, :out_of_sync, _}}, &1)),
      corrections: Enum.count(out, &match?({_t, {:correction, _, _, _}}, &1)),
      takebacks: Enum.count(out, &match?({_t, {:correction, _, _, :takeback}}, &1)),
      recovered: Enum.count(tr.plies, &(:recovered in &1.flags)),
      guessed: Enum.count(tr.plies, &(:guessed in &1.flags)),
      # Alarms that say what the board shows: a move out of turn, a move
      # that is not one.
      named: Enum.count(out, &match?({_t, {:status, :out_of_sync, {_kind, %{}}}}, &1)),
      # Marked moves that are not the move the game has at that place.
      recovered_wrong: marked_wrong(tr.plies, truth, :recovered),
      guessed_wrong: marked_wrong(tr.plies, truth, :guessed),
      assumed: Enum.count(tr.plies, &(:assumed in &1.flags)),
      warnings: Enum.count(out, &match?({_t, {:warning, _, _, _}}, &1)),
      stats: tr.stats
    }
  end

  defp marked_wrong(plies, truth, mark) do
    plies
    |> Enum.zip(truth ++ List.duplicate(nil, length(plies)))
    |> Enum.count(fn {ply, san} ->
      mark in ply.flags and Pgn.first_difference([ply.san], [san || ""]) != :same and
        not (:assumed in ply.flags and unpromoted(ply.san) == unpromoted(san || ""))
    end)
  end

  # Every move from and to the squares of the game's, and the first that
  # differs is a promotion the box said it assumed: what differs is what
  # the pawn became, and whatever that piece later did under its other name.
  defp assumed?(tr, truth, ply) do
    with true <- length(tr.plies) == length(truth),
         %{flags: flags} <- Enum.at(tr.plies, ply - 1),
         true <- :assumed in flags,
         {:ok, pos} <- Alnasl.Chess.parse_fen(tr.start_fen),
         {:ok, squares} <- squares(pos, truth) do
      squares == Enum.map(tr.plies, &{&1.from, &1.to})
    else
      _no -> false
    end
  end

  defp squares(pos, sans) do
    sans
    |> Enum.reduce_while({pos, []}, fn san, {pos, acc} ->
      case Alnasl.Chess.parse_san(pos, san) do
        {:ok, move} -> {:cont, {Alnasl.Chess.apply_move(pos, move), [{move.from, move.to} | acc]}}
        {:error, _} -> {:halt, :error}
      end
    end)
    |> case do
      {_pos, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp unpromoted(san), do: String.replace(san, ~r/=[QRBN]|[+#!?]+$/, "")

  # Unmarked, but with "Move missing?" on the tile when the game ended.
  defp warned(:silent, %{missing?: true}), do: :warned
  defp warned(verdict, _session), do: verdict

  defp prefix?(short, long),
    do: Pgn.first_difference(short, Enum.take(long, length(short))) == :same

  # The tracker's game leaves the real one at `ply`. How is that place
  # marked? The ply there, or one of the few before it when a whole
  # reconstructed run is off; or a takeback reported that cut the game at
  # or before it.
  defp wrong(tr, out, ply) do
    flags =
      tr.plies
      |> Enum.slice(max(ply - 4, 0)..(ply - 1)//1)
      |> Enum.flat_map(& &1.flags)

    cut? =
      Enum.any?(out, fn
        {_t, {:correction, keep, _plies, :takeback}} -> keep < ply
        _other -> false
      end)

    cond do
      :guessed in flags -> :guessed_wrong
      :recovered in flags -> :reconstructed_wrong
      flags -- [:long_gap] != [] or cut? -> :flagged
      tr.status == :out_of_sync -> :alarm
      true -> :silent
    end
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
      guessed: results |> Enum.map(& &1.guessed) |> Enum.sum(),
      named: results |> Enum.map(& &1.named) |> Enum.sum(),
      named_games: Enum.count(results, &(&1.named > 0)),
      recovered_wrong: results |> Enum.map(& &1.recovered_wrong) |> Enum.sum(),
      guessed_wrong: results |> Enum.map(& &1.guessed_wrong) |> Enum.sum(),
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
  `matrix/4` for thousands of games: the same runs and the same seeds, but
  nothing of a run is kept beyond a few numbers - a tracker holds every
  position of its game, and ten thousand of them do not fit in one summary.
  The runs that did not end `:exact` are kept as `failures`, slim, with
  what it takes to play one again (`index`, `seed`, the faults played).

  `opts`: `:seed_base` (added to every seed: another sample of the same
  games), `:concurrency` (default: the schedulers online).
  """
  def scale(games, sim, tracker \\ [], passes \\ 1, opts \\ []) do
    base = opts[:seed_base] || 0
    games = Enum.with_index(games, 1)

    empty = %{
      games: 0,
      faulted: 0,
      plies: 0,
      verdicts: %{},
      alarms: 0,
      corrections: 0,
      recovered: 0,
      guessed: 0,
      named: 0,
      named_games: 0,
      recovered_wrong: 0,
      guessed_wrong: 0,
      faults: 0,
      searches: 0,
      max_nodes: 0,
      max_search_ms: 0.0,
      budget_hits: 0,
      failures: [],
      bad: []
    }

    for(pass <- 1..passes, {game, index} <- games, do: {pass, game, index})
    |> Task.async_stream(
      fn {pass, game, index} ->
        options = if is_function(sim), do: sim.({index, pass}), else: sim
        seed = base + index * 1000 + pass
        r = play(game.moves, Map.put(Map.new(options), :seed, seed), tracker)

        %{
          index: index,
          pass: pass,
          seed: seed,
          verdict: r.verdict,
          difference: r.difference,
          alarms: r.alarms,
          corrections: r.corrections,
          recovered: r.recovered,
          guessed: r.guessed,
          named: r.named,
          recovered_wrong: r.recovered_wrong,
          guessed_wrong: r.guessed_wrong,
          plies: length(r.session.tracker.plies),
          log: r.log,
          stats: r.stats
        }
      end,
      timeout: :infinity,
      ordered: false,
      max_concurrency: opts[:concurrency] || System.schedulers_online()
    )
    |> Enum.reduce(empty, fn {:ok, r}, acc ->
      acc =
        Enum.reduce(
          ~w(alarms corrections recovered guessed named recovered_wrong guessed_wrong plies)a,
          acc,
          fn key, acc -> %{acc | key => Map.fetch!(acc, key) + Map.fetch!(r, key)} end
        )

      %{
        acc
        | games: acc.games + 1,
          faulted: acc.faulted + if(r.log == [], do: 0, else: 1),
          verdicts: Map.update(acc.verdicts, r.verdict, 1, &(&1 + 1)),
          named_games: acc.named_games + if(r.named > 0, do: 1, else: 0),
          faults: acc.faults + length(r.log),
          searches: acc.searches + r.stats.searches,
          max_nodes: max(acc.max_nodes, r.stats.max_nodes),
          max_search_ms: max(acc.max_search_ms, r.stats.max_us / 1000),
          budget_hits: acc.budget_hits + r.stats.budget_hits,
          failures:
            if(r.verdict == :exact,
              do: acc.failures,
              else: [Map.delete(r, :stats) | acc.failures]
            ),
          bad:
            if(r.verdict == :silent,
              do: [{r.index, r.seed, r.difference, r.log} | acc.bad],
              else: acc.bad
            )
      }
    end)
    |> then(fn acc ->
      %{
        acc
        | failures: Enum.sort_by(acc.failures, &{&1.index, &1.pass}),
          bad: Enum.sort(acc.bad)
      }
    end)
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
      ] ++ hall(bullet, fast)
  end

  # What hands in a hall do besides the above (`Alnasl.Simulator.Script`,
  # "Faults"): j'adoube on the opponent's time, a piece knocked onto the
  # square beside it and put back, the next hand lifting its piece before
  # this move has landed, the clock's lever knocked back and pressed again.
  defp hall(bullet, fast) do
    new = [:adjust, :knock_over, :overlap, :press_back]
    benign = [:hover, :lift, :knock, :swap, :clock_miss, :leave_pawn, :takeback, :slide]

    [
      {"j'adoube on the opponent's time 20%", :hall, %{faults: %{adjust: 0.2}}, []},
      {"knocked onto the next square, put back 10%", :hall, %{faults: %{knock_over: 0.1}}, []},
      {"the next hand lifts before the move lands 20%", :hall, %{faults: %{overlap: 0.2}}, []},
      {"the lever knocked back and pressed again 10%", :hall, %{faults: %{press_back: 0.1}}, []},
      {"the four of them 5% + the benign faults 5%", :hall,
       %{faults: Map.new(new ++ benign, &{&1, 0.05})}, []},
      {"bullet + the four of them 10%; preset", :hall_bullet,
       Map.update!(bullet, :faults, &Map.merge(&1, Map.new(new, fn f -> {f, 0.1} end))), fast}
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
        {"a piece not seen for 1-5 plies, 5%", :unseen, %{faults: %{unseen: 0.05}}},
        {"the same, no clock", :unseen, %{faults: %{unseen: 0.05}, clock: false}},
        {"the same + the benign faults 5%", :unseen,
         %{faults: Map.new(benign, &{&1, 0.05}) |> Map.put(:unseen, 0.05)}},
        {"a piece set down between squares, 5%", :between, %{faults: %{between: 0.05}}},
        {"set down between squares, no clock", :between,
         %{faults: %{between: 0.05}, clock: false}},
        {"missed 10% (one ply at a time)", :gap2, %{faults: %{missed: 0.1}}},
        {"missed 10% + the others 5%", :gap2,
         %{faults: Map.new(benign ++ [:takeback, :slide], &{&1, 0.05}) |> Map.put(:missed, 0.1)}},
        {"unplugged for 2 plies, twice", :gap2, %{unplug: [{9, 2}, {21, 2}]}},
        {"missed 25%, up to 3 plies in a row", :long,
         %{faults: %{missed: 0.25}, missed_streak: 3}},
        {"unplugged for 3 plies", :long, %{unplug: [{11, 3}]}},
        {"unplugged for 8 plies", :lost, %{unplug: [{11, 8}]}},
        {"a move out of turn at ply 12, taken back", :named, %{out_of_turn_at: 12}},
        {"an illegal move at ply 12, taken back", :named, %{illegal_back_at: 12}},
        {"an illegal move at ply 12, played on", :illegal, %{illegal_at: 12}},
        {"promotion taken at once, pawn left", :promotion,
         %{promotion_capture: :pawn_left, promote_as: :cycle}},
        {"promotion taken at once, pawn left, no clock", :promotion,
         %{promotion_capture: :pawn_left, promote_as: :cycle, clock: false}},
        {"promotion taken at once, piece read <250 ms", :promotion_seen,
         %{promotion_capture: :quick, promote_as: :cycle, clock: false}},
        {"crosstalk: a piece reads empty, 5%", :crosstalk, %{faults: %{mask: 0.05}}},
        {"crosstalk: a piece reads empty, 15%", :crosstalk, %{faults: %{mask: 0.15}}},
        {"crosstalk: a piece reads as another, 5%", :crosstalk, %{faults: %{mistype: 0.05}}},
        {"crosstalk: a piece reads as another, 15%", :crosstalk, %{faults: %{mistype: 0.15}}},
        {"crosstalk both 10% + the benign faults 5%", :crosstalk,
         %{faults: Map.new(benign, &{&1, 0.05}) |> Map.merge(%{mask: 0.1, mistype: 0.1})}},
        {"crosstalk both 10%, no clock", :crosstalk,
         %{faults: %{mask: 0.1, mistype: 0.1}, clock: false}},
        {"a dead square (reads empty) from ply 10", :dead, %{dead_square: {10, :off}}},
        {"a stuck square (keeps its piece) from ply 10", :stuck, %{dead_square: {10, :stuck}}},
        {"a stuck square + the benign faults 5%", :stuck,
         %{faults: Map.new(benign, &{&1, 0.05}), dead_square: {10, :stuck}}}
      ]
  end
end
