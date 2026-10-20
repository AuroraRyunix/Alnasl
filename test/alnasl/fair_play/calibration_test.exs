defmodule Alnasl.FairPlay.CalibrationTest do
  use ExUnit.Case, async: true

  alias Alnasl.Chess
  alias Alnasl.FairPlay.{Calibration, Model}

  @moduletag :tmp_dir
  @moduletag :capture_log

  @fake Path.expand("../../support/fair_play/fake_uci.escript", __DIR__)

  # A random legal game of up to `plies` plies, from a seeded generator.
  defp random_game(plies) do
    Enum.reduce_while(1..plies, {Chess.start(), []}, fn _, {pos, sans} ->
      case Chess.legal_moves(pos) do
        [] ->
          {:halt, {pos, sans}}

        moves ->
          move = Enum.at(moves, :rand.uniform(length(moves)) - 1)
          {:cont, {Chess.apply_move(pos, move), [Chess.san(pos, move) | sans]}}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp pgn_game(i, opts) do
    sans = random_game(Keyword.get(opts, :plies, 60))

    movetext =
      sans
      |> Enum.with_index()
      |> Enum.map_join(" ", fn {san, k} ->
        number = if rem(k, 2) == 0, do: "#{div(k, 2) + 1}. ", else: ""
        clock = "{ [%clk 1:#{String.pad_leading("#{rem(59 - k, 60)}", 2, "0")}:00] }"
        number <> san <> " " <> clock
      end)

    tags = [
      {"Event", "Test Open #{rem(i, 3)}"},
      {"Round", "#{div(i, 6) + 1}.#{rem(i, 6) + 1}"},
      {"White", "Player #{rem(i, 7)}"},
      {"Black", "Player #{rem(i + 3, 7) + 7}"},
      {"WhiteElo", Keyword.get(opts, :white_elo, "#{1800 + rem(i * 37, 600)}")},
      {"BlackElo", "#{1750 + rem(i * 53, 650)}"},
      {"TimeControl", Keyword.get(opts, :tc, "5400+30")},
      {"Result", "*"}
    ]

    Enum.map_join(tags, "\n", fn {k, v} -> ~s([#{k} "#{v}"]) end) <> "\n\n" <> movetext <> " *\n"
  end

  # 24 games that count, and 4 that the filter must drop.
  defp corpus(dir, name \\ "broadcast.pgn.zst") do
    :rand.seed(:exsss, {11, 22, 33})

    games =
      Enum.map(1..24, &pgn_game(&1, [])) ++
        [
          pgn_game(100, tc: "180+2"),
          pgn_game(101, tc: "-"),
          pgn_game(102, white_elo: "0"),
          pgn_game(103, white_elo: "?")
        ]

    path = Path.join(dir, name)
    text = Enum.join(games, "\n")

    if String.ends_with?(name, ".zst"),
      do: File.write!(path, :zstd.compress(text)),
      else: File.write!(path, text)

    path
  end

  # Matches about half the time, otherwise loses 0.1 to 1.1 pawns: enough
  # spread for a fit to have something to fit.
  defp engine_fun do
    fn position, played ->
      h = :erlang.phash2({position.moves, played}, 100)

      if h < 50,
        do: {:ok, %{best: [%{move: played, cp: 20}, %{move: "a1a2", cp: 0}], played_cp: 20}},
        else:
          {:ok, %{best: [%{move: "a1a2", cp: 20}, %{move: "b1b2", cp: 10}], played_cp: 10 - h}}
    end
  end

  defp label(paths, opts) do
    Calibration.label(
      paths,
      Keyword.merge(
        [
          engine_fun: engine_fun(),
          engine_meta: %{"id" => "sf19", "name" => "Stockfish 19", "bench" => 2_497_913},
          nodes: 1000,
          engines: 3,
          log: fn _ -> :ok end
        ],
        opts
      )
    )
  end

  defp ids(path) do
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!(&1)["id"])
  end

  test "the shards are disjoint and together they are everything", %{tmp_dir: dir} do
    pgn = corpus(dir)

    assert {:ok, %{new: 24}} = label([pgn], shard: "1/1", out: Path.join(dir, "all.jsonl"))
    all = ids(Path.join(dir, "all.jsonl"))
    assert length(all) == 24
    assert length(Enum.uniq(all)) == 24

    shards =
      for k <- 1..3 do
        out = Path.join(dir, "shard-#{k}.jsonl")
        assert {:ok, _} = label([pgn], shard: "#{k}/3", out: out)
        MapSet.new(ids(out))
      end

    for a <- shards, b <- shards, a != b, do: assert(MapSet.disjoint?(a, b))
    assert Enum.reduce(shards, &MapSet.union/2) == MapSet.new(all)
    # With 24 games each shard has some; a hash that put everything in one would be no split.
    assert Enum.all?(shards, &(MapSet.size(&1) > 0))
  end

  test "a line holds the game, the engine and its plies", %{tmp_dir: dir} do
    out = Path.join(dir, "one.jsonl")
    assert {:ok, %{new: 1}} = label([corpus(dir, "plain.pgn")], out: out, games: 1)

    [line] = out |> File.read!() |> String.split("\n", trim: true)
    game = Jason.decode!(line)

    assert %{"engine" => %{"id" => "sf19", "bench" => 2_497_913, "nodes" => 1000}} = game
    assert game["time_control"] == "5400+30"
    assert [%{"skip" => "opening", "colour" => "white"} | _] = game["plies"]
    assert Enum.any?(game["plies"], &is_list(&1["best"]))
  end

  test "resumes: skips what is done, cuts a half-written line, appends the rest", %{tmp_dir: dir} do
    pgn = corpus(dir)
    out = Path.join(dir, "labels.jsonl")

    assert {:ok, %{done: 0, new: 10}} = label([pgn], out: out, games: 10)
    first = ids(out)

    # A crash in the middle of a write.
    File.write!(out, ~s({"id":"half-a-li), [:append])

    assert {:ok, %{done: 10, new: 14}} = label([pgn], out: out)
    after_resume = ids(out)

    assert length(after_resume) == 24
    assert Enum.take(after_resume, 10) == first
    assert length(Enum.uniq(after_resume)) == 24

    # Nothing left to do.
    assert {:ok, %{done: 24, new: 0}} = label([pgn], out: out)
  end

  test "fit refuses label files from different engines", %{tmp_dir: dir} do
    pgn = corpus(dir)
    a = Path.join(dir, "a.jsonl")
    b = Path.join(dir, "b.jsonl")

    {:ok, _} = label([pgn], out: a, shard: "1/2")

    {:ok, _} =
      label([pgn],
        out: b,
        shard: "2/2",
        engine_meta: %{"id" => "sf19", "name" => "Stockfish 18", "bench" => 2_187_402}
      )

    assert {:error, {:mixed_engines, seen}} = Calibration.fit([a, b], log: fn _ -> :ok end)
    assert length(seen) == 2

    # Nor different node counts.
    c = Path.join(dir, "c.jsonl")
    {:ok, _} = label([pgn], out: c, shard: "2/2", nodes: 2000)
    assert {:error, {:mixed_engines, _}} = Calibration.fit([a, c], log: fn _ -> :ok end)
  end

  test "fit merges shards, holds games out by hash, writes the model and the table", %{
    tmp_dir: dir
  } do
    pgn = corpus(dir)
    shards = for k <- 1..2, do: Path.join(dir, "s#{k}.jsonl")

    for {out, k} <- Enum.with_index(shards, 1),
        do: {:ok, _} = label([pgn], out: out, shard: "#{k}/2")

    model_path = Path.join(dir, "model-sf19.json")
    me = self()

    assert {:ok, %{model: model, report: report}} =
             Calibration.fit(shards ++ shards,
               holdout: 0.25,
               out: model_path,
               log: &send(me, {:line, &1})
             )

    assert {:ok, loaded} = Model.load("sf19", dir)
    assert loaded.match == model.match
    assert model.bench == 2_497_913
    assert model.nodes == 1000
    assert model.meta["games"] + model.meta["held_out_games"] == 24
    assert model.meta["held_out_by"] == "event"

    assert Enum.map(report.table["rows"], & &1["threshold"]) ==
             [2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0]

    # The table travels with the model, for the report to read.
    assert loaded.false_positives == report.table

    assert_received {:line, "fair_play fit: " <> _}
    assert_received {:line, "  >= 2.0: " <> _}

    # Held out by event: an event's games are all held out or none is, so
    # a held-out player-event is a whole one.
    games =
      shards
      |> Enum.flat_map(&(&1 |> File.read!() |> String.split("\n", trim: true)))
      |> Enum.map(&Jason.decode!/1)

    for {_event, in_event} <- Enum.group_by(games, & &1["event"]) do
      verdicts = Enum.map(in_event, &Calibration.held_out?(Calibration.holdout_key(&1), 0.25))
      assert Enum.uniq(verdicts) |> length() == 1
    end

    assert Calibration.holdout_key(%{"event" => "Open A", "id" => "x"}) == "event:Open A"
    assert Calibration.holdout_key(%{"event" => "", "id" => "x"}) == "game:x"

    # The same split every time.
    held = Enum.filter(ids(hd(shards)), &Calibration.held_out?(&1, 0.25))
    assert held == Enum.filter(ids(hd(shards)), &Calibration.held_out?(&1, 0.25))
  end

  test "the gate reads the table, and says when the sample is too small to show anything" do
    small = Alnasl.FairPlay.FalsePositives.table(List.duplicate(0.0, 500))
    assert Calibration.gate_verdict(small) == :passed_unproven

    big = Alnasl.FairPlay.FalsePositives.table(List.duplicate(0.0, 3000))
    assert Calibration.gate_verdict(big) == :passed

    bad =
      Alnasl.FairPlay.FalsePositives.table(List.duplicate(0.0, 990) ++ List.duplicate(3.5, 10))

    assert Calibration.gate_verdict(bad) == :failed

    assert Calibration.gate_verdict(Alnasl.FairPlay.FalsePositives.table([])) == :no_data
    # -ln(0.025) × 700, rounded up: the rule of three, at 97.5% one-sided.
    assert Calibration.gate_events_needed() == 2583
  end

  test "calibrate runs both steps with a fake engine over UCI, as the command line does", %{
    tmp_dir: dir
  } do
    pgn = corpus(dir)
    out = Path.join(dir, "model-sf19.json")
    escript = System.find_executable("escript") || flunk("escript is not on the PATH")

    printed =
      ExUnit.CaptureIO.capture_io(fn ->
        send(
          self(),
          {:result,
           Calibration.main(
             ["calibrate", "--engine", escript, "--engine-arg", @fake, "--engine-arg", "normal"] ++
               ~w(--bench 2497913 --nodes 500 --engines 2 --games 6 --holdout 0.5) ++
               ["--out", out, pgn],
             halt: false
           )}
        )
      end)

    assert_received {:result, {:ok, %{model: model}}}
    assert printed =~ "fair_play fit: "

    assert File.exists?(out)
    assert File.exists?(out <> ".labels.jsonl")
    assert length(ids(out <> ".labels.jsonl")) == 6
    assert model.engine == "sf19"
    assert model.meta["engine_name"] == "FakeFish 1"
  end

  test "bad arguments are refused, not guessed at" do
    assert {:error, {:bad_shard, "5/4"}} = Calibration.shard("5/4")
    assert {:error, {:bad_shard, "one of four"}} = Calibration.shard("one of four")
    assert {:ok, {2, 4}} = Calibration.shard("2/4")

    assert ExUnit.CaptureIO.capture_io(:stderr, fn ->
             assert {:error, :usage} = Calibration.main(["dance"], halt: false)
           end) =~ "usage"
  end
end
