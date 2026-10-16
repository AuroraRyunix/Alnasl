defmodule Alnasl.RecorderTest do
  @moduledoc """
  The capture files: what goes in comes out, a file of raw serial bytes is
  decoded with the DGT protocol, files rotate at a size, and a capture
  replayed through a fresh tracker gives the game back.
  """

  use Alnasl.DataCase, async: false

  alias Alnasl.{Chess, Position, Recorder}
  alias Arkab.Dgt.Protocol
  alias Alnasl.Simulator.Script

  setup do
    dir =
      Path.expand(
        Path.join(System.tmp_dir!(), "alnasl-rec-#{System.unique_integer([:positive])}")
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp recorder(dir, opts \\ []) do
    start_supervised!({Recorder, [name: :test_recorder, dir: dir] ++ opts}, id: :test_recorder)
    :test_recorder
  end

  defp files(dir), do: Path.wildcard(Path.join(dir, "board-*/*.jsonl"))

  test "everything a driver delivers is written as a line and read back as the same events", %{
    dir: dir
  } do
    rec = recorder(dir)
    after_e4 = Position.from_fen("rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1")

    Recorder.record(7, {:cfg, %{flipped: false, round: 4, board: 7}}, rec)
    Recorder.record(7, {:status, :connected}, rec)
    Recorder.record(7, {:position, Position.start()}, rec)

    Recorder.record(
      7,
      {:clock, %{white_ms: 5_400_000, black_ms: 5_400_000, running: :white}},
      rec
    )

    Recorder.record(7, {:raw, :rx, <<0x8E, 0x00, 0x05, 52, 0x00>>}, rec)
    Recorder.record(7, {:note, "knocked over on purpose"}, rec)
    Recorder.record(7, {:position, after_e4}, rec)
    Recorder.record(7, {:status, :disconnected}, rec)
    Recorder.record(7, :something_else, rec)
    Recorder.flush(rec)

    assert [path] = files(dir)
    lines = path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.map(lines, & &1["k"]) == ~w(cfg st pos clk rx note pos st)
    assert Enum.all?(lines, &is_integer(&1["t"]))

    assert Enum.at(lines, 2)["b"] ==
             "rnbqkbnrpppppppp" <> String.duplicate(".", 32) <> "PPPPPPPPRNBQKBNR"

    assert Enum.at(lines, 4)["h"] == "8e00053400"

    assert {:ok, capture} = Recorder.read(path)
    assert capture.cfg["round"] == 4 and capture.cfg["board"] == 7
    assert [{_, "knocked over on purpose"}] = capture.notes
    refute capture.raw?

    # Times count from the first line; the clock may tick between two lines.
    assert [
             {_, :connected},
             {_, {:position, start}},
             {_, {:clock, %{white_ms: 5_400_000, running: :white}}},
             {_, {:position, ^after_e4}},
             {_, :disconnected}
           ] = capture.events

    assert start == Position.start()
  end

  test "a file is closed at the size limit and a new one begun", %{dir: dir} do
    rec = recorder(dir, rotate_bytes: 400)
    for _ <- 1..20, do: Recorder.record(1, {:position, Position.start()}, rec)
    Recorder.flush(rec)
    assert length(files(dir)) >= 4
    assert Enum.all?(files(dir), &(File.stat!(&1).size <= 400))

    total =
      files(dir)
      |> Enum.map(&length(String.split(File.read!(&1), "\n", trim: true)))
      |> Enum.sum()

    assert total == 20
  end

  test "a capture of raw bytes only - what tools/serial_proxy.py writes - is decoded with the protocol",
       %{dir: dir} do
    # LiveChess asks for the board; the board answers, then reports 1.e4 as
    # two field updates, the second one split across two reads.
    dump = Protocol.encode({:board, Position.start()})
    lift = Protocol.encode({:field, 52, nil})
    <<put_a::binary-size(2), put_b::binary>> = Protocol.encode({:field, 36, {:w, :p}})

    hex = fn bytes ->
      bytes |> Base.encode16(case: :lower) |> String.replace(~r/(..)(?=.)/, "\\1 ")
    end

    log = """
    # capture started 2026-10-12 09:00:00 app=COM11 board=COM3 baud=9600
        0.100000  APP>BRD  42
        0.180000  BRD>APP  #{hex.(dump)}
    #     5.000000  NOTE  b1 e2e4
        5.200000  BRD>APP  #{hex.(lift)}
        5.900000  BRD>APP  #{hex.(put_a)}
        5.905000  BRD>APP  #{hex.(put_b)}
    # capture stopped
    """

    path = Path.join(dir, "capture-1.log")
    File.write!(path, log)

    assert {:ok, capture} = Recorder.read(path)
    assert capture.raw?
    assert [{_, "b1 e2e4"}] = capture.notes

    assert [{80, {:position, a}}, {5_100, {:position, b}}, {5_805, {:position, c}}] =
             capture.events

    assert a == Position.start()
    assert Position.placement(b) == "rnbqkbnr/pppppppp/8/8/8/8/PPPP1PPP/RNBQKBNR"
    assert Position.placement(c) == "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR"

    assert {:ok, report} = Recorder.dry_run(path, [])
    assert report.moves == ["e4"]
    assert report.raw?
  end

  test "a whole game with faults survives the trip through a capture file", %{dir: dir} do
    sans = ~w(e4 e5 Nf3 Nc6 Bc4 Bc5 O-O Nf6 d3 d6)
    script = Script.build(sans, seed: 5, faults: %{lift: 0.3, takeback: 0.3, hover: 0.2})

    # Written by hand with the script's own times, as the recorder would.
    path = Path.join(dir, "game.jsonl")

    lines =
      Enum.map(script.events, fn
        {t, {:position, board}} ->
          %{"t" => 1_000_000 + t, "k" => "pos", "b" => Position.to_text(board)}

        {t, {:clock, c}} ->
          %{
            "t" => 1_000_000 + t,
            "k" => "clk",
            "w" => c.white_ms,
            "b" => c.black_ms,
            "r" => to_string(c.running)
          }
      end)

    File.write!(path, Enum.map_join(lines, "\n", &Jason.encode!/1))

    assert {:ok, report} = Recorder.dry_run(path, [])
    assert report.moves == sans
    assert report.alarms == []
    assert report.events == length(script.events)
    assert report.duration_ms == script.duration_ms
  end

  test "a capture of a turned board, or of a game from a set position, is replayed as it was read",
       %{dir: dir} do
    fen = "4k3/8/8/8/8/8/4P3/4K3 w - - 0 1"
    {:ok, [after_move]} = Chess.replay(fen, ["e4"])

    lines = [
      %{"t" => 1, "k" => "cfg", "flipped" => true, "start_fen" => fen},
      %{
        "t" => 2,
        "k" => "pos",
        "b" => fen |> Position.from_fen() |> Position.rotate() |> Position.to_text()
      },
      %{
        "t" => 5_000,
        "k" => "pos",
        "b" => after_move.fen |> Position.from_fen() |> Position.rotate() |> Position.to_text()
      },
      %{
        "t" => 9_000,
        "k" => "pos",
        "b" => after_move.fen |> Position.from_fen() |> Position.rotate() |> Position.to_text()
      }
    ]

    path = Path.join(dir, "flipped.jsonl")
    File.write!(path, Enum.map_join(lines, "\n", &Jason.encode!/1))
    assert {:ok, %{moves: ["e4"], cfg: %{"flipped" => true}}} = Recorder.dry_run(path, [])
  end

  test "a capture is exported as a fixture a test can replay", %{dir: dir} do
    path = Path.join(dir, "x.jsonl")

    File.write!(
      path,
      Jason.encode!(%{"t" => 1, "k" => "pos", "b" => Position.to_text(Position.start())})
    )

    assert {:ok, target} = Recorder.export_fixture(path, "board 7 / round 4: out of sync!")
    assert Path.basename(target) == "board-7-round-4-out-of-sync.jsonl"
    assert File.read!(target) == File.read!(path)
    File.rm!(target)
  end

  test "an empty or missing file is an error, not a crash", %{dir: dir} do
    assert {:error, :enoent} = Recorder.read(Path.join(dir, "nope.jsonl"))
    File.write!(Path.join(dir, "empty.jsonl"), "")
    assert {:error, :empty} = Recorder.read(Path.join(dir, "empty.jsonl"))
    assert {:error, :empty} = Recorder.dry_run(Path.join(dir, "empty.jsonl"), [])
  end
end
