defmodule Alnasl.FairPlay.Calibration do
  @moduledoc """
  Calibration: from Lichess broadcast games to `priv/fair_play/model-sf19.json`.

  Two steps, because the heavy one runs on several machines that know
  nothing of each other:

    1. **label** - stream the PGN, keep the standard-time-control games
       with both players rated, keep this machine's shard of them, analyse
       every ply (`Alnasl.FairPlay.Analyzer` with Stockfish over UCI), and
       append one json line per game. Every machine reads the same input
       and keeps the games whose id hashes to its shard, so the shards are
       disjoint and together they are everything, with no coordinator.
       Resumable: on a restart it reads what is already in its file, skips
       those games, and appends.
    2. **fit** - merge the shards' files, refuse to mix engines, bench
       numbers or node counts (a model belongs to exactly one), split off
       the held-out **events** by hash, fit `Alnasl.FairPlay.Model`, and
       print and store the held-out false-positive table
       (`Alnasl.FairPlay.FalsePositives`) and the per-band check.

  The split is by event, not by game. A player-event is the unit the
  report scores and the false-positive table counts, and a split by game
  cuts every event in five: the held-out "player-events" were then a
  couple of games each, which is not what the report ever shows, and their
  other games had been fitted on. Phase 1 split by game; that was wrong.

  `calibrate/2` is both on one machine.

  It runs without the server: no Repo, no endpoint, nothing but the
  engine processes and this one. The machines that do the work have the
  Linux release and no Elixir, so the entry point is `main/1`, which a
  release reaches through `eval`:

      bin/alnasl eval "Alnasl.FairPlay.Calibration.main()" label \\
        --engine /opt/sf19/stockfish-linux-x86-64-universal \\
        --shard 1/4 --out /data/labels-1.jsonl \\
        /data/lichess_db_broadcast_2024-*.pgn.zst

      bin/alnasl eval "Alnasl.FairPlay.Calibration.main()" fit \\
        --holdout 0.2 --out model-sf19.json /data/labels-*.jsonl

  In a checkout, `mix fair_play.label`, `mix fair_play.fit` and
  `mix fair_play.calibrate` take the same arguments.
  See `docs/fair-play-calibration.md` for the whole run.

  ## Options

  label: `--engine PATH` (the binary), `--engine-arg ARG` (repeatable),
  `--engine-id sf19`, `--shard K/N` (1/1), `--engines E` (schedulers
  online), `--nodes N` (1 000 000), `--games N` (stop once the file holds
  N games), `--min-base SECONDS` (3600), `--out FILE`, and `--bench N` to
  record N as the bench instead of running it (for a test engine that has
  none; a real run should let it be measured).

  fit: `--holdout FRACTION` (0.2), `--out FILE`, `--engine-id sf19`.

  calibrate: everything above, plus `--labels FILE` (default `OUT.labels.jsonl`).
  """

  alias Alnasl.FairPlay.{
    Analyzer,
    Engines,
    FalsePositives,
    Installer,
    Model,
    Selection,
    Stats,
    Uci
  }

  # The plan's gate: more than about 1 in 700 normal player-events over 3.
  @gate 1 / 700
  @gate_threshold 3.0

  # --- the command line ----------------------------------------------------------

  @switches [
    engine: :string,
    engine_arg: :keep,
    engine_id: :string,
    shard: :string,
    engines: :integer,
    nodes: :integer,
    games: :integer,
    min_base: :integer,
    out: :string,
    labels: :string,
    holdout: :float,
    bench: :integer
  ]

  @doc """
  `main(["label" | args])`, `main(["fit" | args])` or
  `main(["calibrate" | args])`; prints what happened. Halts with status 1
  on an error when run from a release (`halt: true`).
  """
  def main(argv \\ System.argv(), opts \\ [halt: true]) do
    result =
      case argv do
        [command | args] when command in ~w(label fit calibrate) ->
          {parsed, paths, invalid} = OptionParser.parse(args, strict: @switches)

          if invalid != [] do
            {:error, {:bad_arguments, invalid}}
          else
            run(command, paths, options(parsed))
          end

        _ ->
          {:error, :usage}
      end

    case result do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        IO.puts(:stderr, "fair_play: " <> describe(reason))
        if opts[:halt], do: System.halt(1), else: {:error, reason}
    end
  end

  defp run("label", paths, opts), do: label(paths, opts)
  defp run("fit", paths, opts), do: fit(paths, opts)
  defp run("calibrate", paths, opts), do: calibrate(paths, opts)

  defp options(parsed) do
    Enum.flat_map(parsed, fn
      {:engine_arg, arg} -> [engine_args: arg]
      {:shard, text} -> [shard: text]
      other -> [other]
    end)
    |> then(fn opts ->
      case Keyword.get_values(opts, :engine_args) do
        [] -> opts
        args -> opts |> Keyword.delete(:engine_args) |> Keyword.put(:engine_args, args)
      end
    end)
  end

  defp describe(:usage),
    do:
      "usage: main([\"label\" | \"fit\" | \"calibrate\", options..., files...]); " <>
        "see Alnasl.FairPlay.Calibration"

  defp describe({:mixed_engines, seen}),
    do: "the label files come from different engines, benches or node counts: #{inspect(seen)}"

  defp describe({:bad_shard, text}),
    do: "--shard must be K/N with 1 <= K <= N, not #{inspect(text)}"

  defp describe({:bench_failed, why}), do: "the engine's bench failed: #{inspect(why)}"

  defp describe({:bench_mismatch, want, got}),
    do: "the engine's bench is #{got}, not #{want}: not the build this model is for"

  defp describe(other), do: inspect(other)

  # --- label ---------------------------------------------------------------------

  @doc """
  Analyses this shard's games of `paths` (`.pgn` or `.pgn.zst`) into the
  json-lines file `opts[:out]`. Returns `{:ok, %{done, new, skipped}}`.

  Besides the command-line options: `:engine_fun` (an Analyzer engine
  function used instead of starting engines, for tests) with
  `:engine_meta` (what to record as the engine), and `:log` (a one-arity
  function for progress lines, default `IO.puts/1`).
  """
  def label(paths, opts) do
    out = Keyword.fetch!(opts, :out)
    log = Keyword.get(opts, :log, &IO.puts/1)
    nodes = Keyword.get(opts, :nodes, 1_000_000)
    workers = Keyword.get(opts, :engines, System.schedulers_online())
    min_base = Keyword.get(opts, :min_base, 3600)

    with {:ok, {k, n}} <- shard(Keyword.get(opts, :shard, "1/1")),
         {:ok, meta, pool} <- engines(opts, nodes, workers) do
      try do
        done = resume(out)
        limit = opts[:games]
        wanted = if limit, do: max(limit - MapSet.size(done), 0), else: :infinity

        log.(
          "fair_play label: shard #{k}/#{n}, #{workers} engines, #{nodes} nodes, " <>
            "#{MapSet.size(done)} games already in #{out}"
        )

        {:ok, file} = File.open(out, [:append, :binary])
        started = System.monotonic_time(:millisecond)

        {new, positions} =
          try do
            paths
            |> games()
            |> Stream.filter(&standard?(&1, min_base))
            |> Stream.map(&Map.put(&1, :id, game_id(&1)))
            |> Stream.filter(&(shard_of(&1.id, n) == k))
            |> Stream.reject(&MapSet.member?(done, &1.id))
            |> then(fn s -> if wanted == :infinity, do: s, else: Stream.take(s, wanted) end)
            |> Task.async_stream(&label_game(&1, pool, meta, nodes),
              max_concurrency: workers,
              ordered: false,
              timeout: :infinity
            )
            |> Enum.reduce({0, 0}, fn {:ok, {line, searched}}, {count, positions} ->
              IO.binwrite(file, [line, ?\n])
              count = count + 1
              positions = positions + searched

              if rem(count, 50) == 0,
                do: log.("fair_play label: " <> progress(count, positions, started, workers))

              {count, positions}
            end)
          after
            File.close(file)
          end

        log.(
          "fair_play label: done, #{new} new games, #{MapSet.size(done) + new} in #{out}; " <>
            progress(new, positions, started, workers)
        )

        {:ok, %{done: MapSet.size(done), new: new, positions: positions}}
      after
        stop_pool(pool)
      end
    end
  end

  # "50 new games, 3210 positions, 412 s: 7.3 games/min, 1.03 s per
  # position per engine" - what the run-time estimate is made of.
  defp progress(games, positions, started, workers) do
    seconds = max(System.monotonic_time(:millisecond) - started, 1) / 1000
    per_position = if positions > 0, do: seconds * workers / positions, else: 0.0

    "#{games} new games, #{positions} positions, #{round(seconds)} s: " <>
      "#{:erlang.float_to_binary(games / seconds * 60, decimals: 1)} games/min, " <>
      "#{:erlang.float_to_binary(per_position, decimals: 2)} s per position per engine"
  end

  @doc "`\"K/N\"` as `{k, n}`."
  def shard(text) when is_binary(text) do
    with [k, n] <- String.split(text, "/"),
         {k, ""} <- Integer.parse(k),
         {n, ""} <- Integer.parse(n),
         true <- n >= 1 and k >= 1 and k <= n do
      {:ok, {k, n}}
    else
      _ -> {:error, {:bad_shard, text}}
    end
  end

  def shard({k, n} = pair) when k >= 1 and k <= n, do: {:ok, pair}

  @doc """
  A game's id: the first 16 hex digits of the SHA256 of its event, round,
  players and moves. The same on every machine and every OTP, which a
  `phash2` would not promise.
  """
  def game_id(game) do
    h = game.headers

    [h["Event"], h["Round"], h["White"], h["Black"], Enum.join(game.moves, " ")]
    |> Enum.map_join("\n", &(&1 || ""))
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc "Which of `n` shards (1-based) a game id belongs to."
  def shard_of(id, n), do: rem(String.to_integer(id, 16), n) + 1

  # The ids already in the file. A line cut off by a crash is cut away
  # first, or the next append would be glued to it.
  defp resume(out) do
    case File.read(out) do
      {:ok, text} ->
        whole =
          case :binary.matches(text, "\n") do
            [] -> ""
            matches -> binary_part(text, 0, elem(List.last(matches), 0) + 1)
          end

        if byte_size(whole) != byte_size(text), do: File.write!(out, whole)

        whole
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, %{"id" => id}} -> [id]
            _ -> []
          end
        end)
        |> MapSet.new()

      {:error, :enoent} ->
        File.mkdir_p!(Path.dirname(out))
        MapSet.new()
    end
  end

  # Standard time control (the first period's base at least `min_base`
  # seconds), standard chess, both rated. Broadcasts write the tag however
  # they like: seconds ("5400+30", "40/5400+30:1800+30"), words ("90 min +
  # 30 sec per move"), or nothing usable at all - and only then do the
  # clocks decide, the first reading after each player's first move being
  # the base give or take a few seconds. A tag that can be read wins over
  # the clocks: a file's clocks are the likelier thing to be wrong.
  @doc false
  def standard?(%{headers: h} = game, min_base) do
    base =
      case max(tag_seconds(h["TimeControl"]), tag_minutes(h["TimeControl"])) do
        0 -> clock_base(game)
        seconds -> seconds
      end

    base >= min_base and h["Variant"] in [nil, "Standard"] and rated(h["WhiteElo"]) != nil and
      rated(h["BlackElo"]) != nil
  end

  defp tag_seconds(tc) do
    case Regex.run(~r/^(?:\d+\/)?(\d+)/, tc || "") do
      [_, seconds] -> String.to_integer(seconds)
      nil -> 0
    end
  end

  defp tag_minutes(tc) do
    case Regex.run(~r/(\d+)\s*(?:min|')/i, tc || "") do
      [_, minutes] -> String.to_integer(minutes) * 60
      nil -> 0
    end
  end

  # The first two clock readings, one per player; 5% slack for the seconds
  # a first move costs, and never more than the clock showed.
  defp clock_base(%{clocks: [_ | _] = clocks}) do
    case clocks |> Enum.take(2) |> Enum.reject(&is_nil/1) do
      [] -> 0
      ms -> div(Enum.max(ms), 950)
    end
  end

  defp clock_base(_), do: 0

  defp rated(text) when is_binary(text) do
    case Integer.parse(text) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp rated(_), do: nil

  defp label_game(game, pool, meta, _nodes) do
    h = game.headers

    input = %{
      start_fen: h["FEN"],
      plies:
        game.moves
        |> Enum.zip(game.clocks)
        |> Enum.map(fn {san, ms} -> %{san: san, flags: [], clock_ms: ms} end),
      white_rating: rated(h["WhiteElo"]),
      black_rating: rated(h["BlackElo"]),
      result_confirmed: true
    }

    line = %{
      "id" => game.id,
      "event" => h["Event"],
      "broadcast" => h["BroadcastName"],
      "round" => h["Round"],
      "date" => h["Date"],
      "white" => h["White"],
      "black" => h["Black"],
      "white_elo" => input.white_rating,
      "black_elo" => input.black_rating,
      "time_control" => h["TimeControl"],
      "result" => game.result,
      "engine" => meta
    }

    {line, searched} =
      case with_engine(pool, &Analyzer.analyse(input, &1)) do
        {:ok, records} ->
          {Map.put(line, "plies", Enum.map(records, &encode_record/1)),
           Enum.count(records, &(&1.best != nil))}

        {:error, {ply, message}} ->
          {Map.put(line, "error", "ply #{ply}: #{message}"), 0}

        {:error, message} ->
          {Map.put(line, "error", to_string(message)), 0}
      end

    {Jason.encode!(line), searched}
  end

  # A counted ply keeps what the fit needs; a skipped one only why.
  defp encode_record(%{skip: nil} = r) do
    %{
      "ply" => r.ply,
      "colour" => Atom.to_string(r.colour),
      "rating" => r.rating,
      "uci" => r.played_uci,
      "best" => Enum.map(r.best || [], &[&1.move, &1.cp]),
      "played_cp" => r.played_cp,
      "rank" => r.rank,
      "near" => r.near_count,
      "material" => r.material,
      "clock" => r.clock_before_ms
    }
  end

  defp encode_record(r),
    do: %{"ply" => r.ply, "colour" => Atom.to_string(r.colour), "skip" => Atom.to_string(r.skip)}

  # --- the engines -----------------------------------------------------------------

  # A pool is an Agent holding the free engine functions; there are exactly
  # as many as workers, so a checkout never waits.
  defp engines(opts, nodes, workers) do
    case Keyword.fetch(opts, :engine_fun) do
      {:ok, fun} ->
        meta = Map.merge(%{"nodes" => nodes}, Keyword.get(opts, :engine_meta, %{}))
        {:ok, pool} = Agent.start_link(fn -> {List.duplicate(fun, workers), []} end)
        {:ok, meta, pool}

      :error ->
        start_engines(opts, nodes, workers)
    end
  end

  defp start_engines(opts, nodes, workers) do
    cmd = Keyword.fetch!(opts, :engine)
    args = Keyword.get(opts, :engine_args, [])
    engine_id = Keyword.get(opts, :engine_id, "sf19")

    with {:ok, pinned} <- pinned(engine_id),
         {:ok, bench} <- checked_bench(cmd, pinned, opts) do
      started =
        Enum.reduce_while(1..workers, {:ok, []}, fn _, {:ok, pids} ->
          case Uci.start(cmd: cmd, args: args) do
            {:ok, pid} -> {:cont, {:ok, [pid | pids]}}
            {:error, reason} -> {:halt, {:error, {:engine_would_not_start, reason}, pids}}
          end
        end)

      case started do
        {:ok, pids} ->
          pool(pids, engine_id, bench, nodes)

        {:error, reason, pids} ->
          Enum.each(pids, &Uci.stop/1)
          {:error, reason}
      end
    end
  end

  defp pool(pids, engine_id, bench, nodes) do
    info = Uci.info(hd(pids))

    meta = %{
      "id" => engine_id,
      "name" => info[:name],
      "bench" => bench,
      "nodes" => nodes
    }

    {:ok, pool} = Agent.start_link(fn -> {Enum.map(pids, &Uci.engine_fun(&1, nodes)), pids} end)
    {:ok, meta, pool}
  end

  defp pinned(id) do
    case Engines.fetch(id) do
      {:ok, engine} -> {:ok, engine}
      :error -> {:error, {:unknown_engine, id}}
    end
  end

  # The labels say which build made them, so the fit can refuse a mix.
  # `bench: n` skips running it (a test's fake engine has none).
  defp checked_bench(cmd, pinned, opts) do
    case Keyword.fetch(opts, :bench) do
      {:ok, n} ->
        {:ok, n}

      :error ->
        case Installer.bench(cmd) do
          {:ok, n} when n == pinned.bench -> {:ok, n}
          {:ok, n} -> {:error, {:bench_mismatch, pinned.bench, n}}
          {:error, why} -> {:error, {:bench_failed, why}}
        end
    end
  end

  defp with_engine(pool, fun) do
    engine = Agent.get_and_update(pool, fn {[e | free], pids} -> {e, {free, pids}} end)

    try do
      fun.(engine)
    after
      Agent.update(pool, fn {free, pids} -> {[engine | free], pids} end)
    end
  end

  defp stop_pool(pool) do
    {_free, pids} = Agent.get(pool, & &1)
    Enum.each(pids, &Uci.stop/1)
    Agent.stop(pool)
  end

  # --- reading games -----------------------------------------------------------------

  @doc """
  The games of PGN files, lazily: a `.zst` file is decompressed as it is
  read (a month of broadcasts is gigabytes), and the text is cut into games
  at each blank line before an `[Event` tag.
  """
  def games(paths) do
    Stream.flat_map(paths, fn path ->
      path
      |> text_chunks()
      |> Stream.transform("", fn
        :eof, rest -> {[rest], ""}
        chunk, rest -> split_games(rest <> chunk)
      end)
      |> Stream.flat_map(&Alnasl.PgnReader.parse/1)
    end)
  end

  defp split_games(text) do
    parts = String.split(text, ~r/\n\s*\n(?=\[Event )/)
    {complete, [rest]} = Enum.split(parts, -1)
    {complete, rest}
  end

  defp text_chunks(path) do
    Stream.resource(
      fn ->
        {:ok, file} = File.open(path, [:read, :binary])

        ctx =
          if String.ends_with?(path, ".zst") do
            {:ok, ctx} = :zstd.context(:decompress)
            ctx
          end

        {file, ctx, false}
      end,
      fn
        {_file, _ctx, true} = state ->
          {:halt, state}

        {file, ctx, false} ->
          case IO.binread(file, 1_048_576) do
            data when is_binary(data) and ctx == nil ->
              {[data], {file, ctx, false}}

            data when is_binary(data) ->
              {[IO.iodata_to_binary(zstd_feed(ctx, data, []))], {file, ctx, false}}

            _eof ->
              tail =
                if ctx do
                  IO.iodata_to_binary(zstd_finish(ctx, []))
                else
                  ""
                end

              {[tail, :eof], {file, ctx, true}}
          end
      end,
      fn {file, ctx, _} ->
        File.close(file)
        if ctx, do: :zstd.close(ctx)
      end
    )
  end

  # `:zstd.stream/2` hands back what it could not take yet as well as what it
  # made: `{:continue, rest, out}`. The rest goes straight back in. A test
  # file of a few kilobytes never has a rest; a month of broadcasts does, on
  # its first megabyte (2026-10-20, on the VM).
  defp zstd_feed(ctx, data, acc) do
    case :zstd.stream(ctx, data) do
      {:continue, out} ->
        [acc, out]

      {:continue, rest, out} ->
        if IO.iodata_length(rest) == 0,
          do: [acc, out],
          else: zstd_feed(ctx, rest, [acc, out])
    end
  end

  # `:zstd.finish/2` only ever answers `{:done, out}`: it loops on its own,
  # over whatever `stream/2` left behind, and hands back the tail whole. It
  # used to be matched for `{:continue, ...}` as well, which OTP's spec says
  # it cannot return, and Dialyzer (rightly) said so. A match error here
  # would be OTP breaking its own contract, which is loud enough, and is
  # not a thing this function is expected to survive.
  defp zstd_finish(ctx, acc) do
    {:done, out} = :zstd.finish(ctx, <<>>)
    [acc, out]
  end

  # --- fit -----------------------------------------------------------------------

  @doc """
  Fits the model from label files and writes it to `opts[:out]`.
  Returns `{:ok, %{model, report}}` and prints the report.
  """
  def fit(paths, opts) do
    holdout = Keyword.get(opts, :holdout, 0.2)
    log = Keyword.get(opts, :log, &IO.puts/1)

    with {:ok, games, meta} <- read_labels(paths) do
      {held, train} = Enum.split_with(games, &held_out?(holdout_key(&1), holdout))

      model =
        Model.fit(player_events(train),
          engine: meta["id"],
          bench: meta["bench"],
          nodes: meta["nodes"],
          meta: %{
            "engine_name" => meta["name"],
            "games" => length(train),
            "held_out_games" => length(held),
            "held_out_by" => "event",
            "fitted_on" => Date.to_iso8601(Date.utc_today()),
            "sources" => Enum.map(paths, &Path.basename/1)
          }
        )

      report = report(player_events(held), model)
      model = %{model | false_positives: report.table}

      if out = opts[:out], do: Model.save(model, out)
      Enum.each(format_report(report, length(train), length(held), opts[:out]), log)
      {:ok, %{model: model, report: report}}
    end
  end

  @doc """
  The games of label files, each game once, and the one engine they share
  - or `{:error, {:mixed_engines, [meta]}}`.
  """
  def read_labels(paths) do
    games =
      paths
      |> Stream.flat_map(&File.stream!/1)
      |> Stream.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, %{"id" => _} = game} -> [game]
          _ -> []
        end
      end)
      |> Enum.uniq_by(& &1["id"])

    case games
         |> Enum.map(&Map.take(&1["engine"] || %{}, ~w(id name bench nodes)))
         |> Enum.uniq() do
      [meta] -> {:ok, Enum.reject(games, &Map.has_key?(&1, "error")), meta}
      [] -> {:ok, [], %{}}
      several -> {:error, {:mixed_engines, several}}
    end
  end

  @doc """
  What decides whether a game is held out: its event, so a player-event
  is held out whole or not at all (a game without an event stands alone).

  The event is the broadcast's name when the file has one. Lichess
  broadcasts since 2024 put "Round 11: White - Black" in `Event`, one value
  per game, and grouping on that held out games, not events - the very
  leak this function exists to stop.
  """
  def holdout_key(game) do
    case event_of(game) do
      nil -> "game:" <> game["id"]
      event -> "event:" <> event
    end
  end

  @doc false
  def event_of(game) do
    Enum.find([game["broadcast"], game["event"]], &(is_binary(&1) and &1 != ""))
  end

  @doc "Whether a key (`holdout_key/1`) is in the held-out share: by hash, so every run agrees."
  def held_out?(key, fraction) do
    bucket =
      :sha256 |> :crypto.hash("holdout:" <> key) |> binary_part(0, 4) |> :binary.decode_unsigned()

    bucket / 4_294_967_296 < fraction
  end

  # One player in one event: all their plies there, as records.
  defp player_events(games) do
    games
    |> Enum.flat_map(fn g ->
      Enum.map(g["plies"] || [], fn ply ->
        name = if ply["colour"] == "white", do: g["white"], else: g["black"]
        {{event_of(g), name}, decode_record(ply)}
      end)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.values()
  end

  @doc false
  def decode_record(%{"skip" => skip} = ply) do
    reason = Enum.find(Selection.reasons(), :no_analysis, &(Atom.to_string(&1) == skip))
    %{ply: ply["ply"], skip: reason, best: nil, played_cp: nil}
  end

  def decode_record(ply) do
    %{
      ply: ply["ply"],
      rating: ply["rating"],
      best: Enum.map(ply["best"], fn [move, cp] -> %{move: move, cp: cp} end),
      played_cp: ply["played_cp"],
      rank: ply["rank"],
      near_count: ply["near"],
      material: ply["material"],
      skip: nil
    }
  end

  @doc """
  The held-out check: the false-positive table of the player-events with
  at least 40 counted moves (`Alnasl.FairPlay.FalsePositives.table/1`:
  the share scoring 2.0, 2.5, ... 5.0 or more, with exact 95% intervals),
  and per rating band the count, the mean score and the share at 2 or
  more. Normal players, all of them (as far as anybody knows): every one
  of those shares is a false-positive rate.
  """
  def report(events, model) do
    scored =
      for records <- events,
          numbers = Stats.player(records, model),
          numbers.score != nil,
          do: {band(records), numbers.score}

    total = length(scored)

    %{
      events: total,
      table: scored |> Enum.map(&elem(&1, 1)) |> FalsePositives.table(),
      bands:
        scored
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Enum.sort()
        |> Enum.map(fn {band, scores} ->
          n = length(scores)

          %{
            band: band,
            events: n,
            mean: Enum.sum(scores) / n,
            over_2: Enum.count(scores, &(&1 >= 2)) / n
          }
        end)
    }
  end

  defp band(records) do
    case Enum.find(records, &is_integer(&1[:rating])) do
      %{rating: r} -> Model.band(r)
      nil -> nil
    end
  end

  defp format_report(report, train, held, out) do
    pct = fn x -> :erlang.float_to_binary(x * 100, decimals: 2) <> "%" end

    rows =
      Enum.map(report.table["rows"], fn r ->
        "  >= #{r["threshold"]}: #{r["above"]} of #{r["events"]}" <>
          if(r["events"] > 0,
            do: ", #{pct.(r["rate"])} (95%: #{pct.(r["low"])} to #{pct.(r["high"])})",
            else: ""
          )
      end)

    [
      "fair_play fit: #{train} games fitted, #{held} held out (by event)" <>
        if(out, do: ", model written to #{out}", else: ""),
      "held-out player-events with a score: #{report.events}",
      "false positives (normal player-events scoring at least):"
    ] ++
      rows ++
      ["per rating band (events, mean score, share >= 2):"] ++
      Enum.map(report.bands, fn b ->
        "  #{b.band}: #{b.events}, #{:erlang.float_to_binary(b.mean / 1, decimals: 2)}, #{pct.(b.over_2)}"
      end) ++ gate(report, pct)
  end

  @doc """
  The plan's gate, read off the table: the share at 3 or more must not be
  above about 1 in 700 (`:failed`). And whether the sample can tell: the
  gate is only *shown* to hold (`:passed`) when the upper end of the 95%
  interval is below 1 in 700 too, which takes about 2,600 held-out
  player-events even when none of them scores 3. With fewer it is
  `:passed_unproven`: a pass by default, and the fit says so.
  """
  def gate_verdict(table) do
    case FalsePositives.row(table, @gate_threshold) do
      nil -> :no_data
      %{"events" => 0} -> :no_data
      %{"rate" => rate} when rate > @gate -> :failed
      %{"high" => high} when high <= @gate -> :passed
      %{} -> :passed_unproven
    end
  end

  @doc "Held-out player-events needed to show the gate holds when none scores 3 or more."
  def gate_events_needed, do: ceil(-:math.log(0.025) / @gate)

  defp gate(report, pct) do
    row = FalsePositives.row(report.table, @gate_threshold)

    case gate_verdict(report.table) do
      :no_data ->
        ["no held-out player-events with #{Stats.min_moves()} moves: no verdict"]

      :failed ->
        [
          "GATE FAILED: #{pct.(row["rate"])} at 3 or more (limit about 1 in 700). " <>
            "The model does not ship."
        ]

      :passed ->
        ["gate passed: #{pct.(row["rate"])} at 3 or more, 95% upper bound #{pct.(row["high"])}"]

      :passed_unproven ->
        [
          "gate passed by default: #{pct.(row["rate"])} at 3 or more, but the 95% upper bound " <>
            "is #{pct.(row["high"])}, above 1 in 700. #{row["events"]} held-out player-events " <>
            "cannot show a rate that small; about #{gate_events_needed()} can, if none of them " <>
            "scores 3."
        ]
    end
  end

  # --- both ------------------------------------------------------------------------

  @doc "Label (shard 1/1) into `opts[:labels]`, then fit from it."
  def calibrate(paths, opts) do
    out =
      Keyword.get(opts, :out, Model.path(Keyword.get(opts, :engine_id, "sf19"), "priv/fair_play"))

    labels = Keyword.get(opts, :labels, out <> ".labels.jsonl")

    with {:ok, _} <- label(paths, opts |> Keyword.put(:out, labels) |> Keyword.put(:shard, "1/1")) do
      fit([labels], Keyword.put(opts, :out, out))
    end
  end
end
