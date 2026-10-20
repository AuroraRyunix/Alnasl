defmodule Alnasl.FairPlay.UciTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Alnasl.FairPlay.Uci

  @fixtures Path.expand("../../fixtures/fair_play", __DIR__)
  @fake Path.expand("../../support/fair_play/fake_uci.escript", __DIR__)

  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> String.split(~r/\r?\n/)

  defp fake(mode, extra \\ [], opts \\ []) do
    escript = System.find_executable("escript") || flunk("escript is not on the PATH")
    start_supervised!({Uci, [cmd: escript, args: [@fake, mode | extra]] ++ opts})
  end

  describe "parsing Stockfish 19's own output" do
    test "keeps the last info line of each multipv, line 1 first" do
      %{best: best, bestmove: bestmove} = Uci.collect(fixture("sf19_multipv_ruy_lopez.txt"))

      assert bestmove == "a7a6"

      # Line 4 is left over from depth 7 (the depth-8 iteration stopped at
      # the node limit before reaching it); it is still the last one seen.
      assert best == [
               %{move: "a7a6", cp: -29},
               %{move: "d8f6", cp: -43},
               %{move: "g8e7", cp: -44},
               %{move: "c6d4", cp: -46}
             ]
    end

    test "a mate for the side to move outranks every evaluation" do
      %{best: [first | rest], bestmove: "d1d8"} = Uci.collect(fixture("sf19_mate_in_one.txt"))

      assert first == %{move: "d1d8", cp: 9_999}
      # The unfinished iteration's line 4 (692, depth 11) sorts above line 2 (683).
      assert Enum.map(rest, & &1.cp) == [692, 683, 674]
    end

    test "being mated is minus ten thousand less the plies" do
      assert %{best: [%{move: "a8b8", cp: -9_998}], bestmove: "a8b8"} =
               Uci.collect(fixture("sf19_mated_in_one.txt"))
    end

    test "a searchmoves search prices exactly that move" do
      assert %{best: [%{move: "g7g5", cp: -177}], bestmove: "g7g5"} =
               Uci.collect(fixture("sf19_searchmoves.txt"))
    end

    test "mate scores" do
      assert Uci.mate_cp(1) == 9_999
      assert Uci.mate_cp(2) == 9_997
      assert Uci.mate_cp(-1) == -9_998
      assert Uci.mate_cp(-3) == -9_994
      assert Uci.mate_cp(0) == -10_000
    end

    test "lines without a score or a move are not lines of play" do
      assert Uci.parse_info("info string NNUE evaluation using nn-1a298aa575a0.nnue") == nil
      assert Uci.parse_info("info depth 2 currmove e2e4 currmovenumber 1") == nil
      assert Uci.parse_info("bestmove e2e4") == nil

      assert Uci.parse_info("info depth 8 multipv 2 score cp -44 lowerbound nodes 1 pv g8e7") ==
               %{multipv: 2, cp: -44, move: "g8e7", bound: :lower}
    end

    test "position commands" do
      assert Uci.position_command(%{start_fen: nil, moves: []}) == "position startpos"

      assert Uci.position_command(%{start_fen: nil, moves: ["e2e4", "e7e5"]}) ==
               "position startpos moves e2e4 e7e5"

      assert Uci.position_command("8/8/8/8/8/8/8/K1k5 w - - 0 1") ==
               "position fen 8/8/8/8/8/8/8/K1k5 w - - 0 1"
    end
  end

  describe "a fake engine over a port" do
    test "handshake, four lines, and the played move from the top four" do
      engine = fake("normal")
      assert %{name: "FakeFish 1", restarts: 0} = Uci.info(engine)

      assert {:ok, result} =
               Uci.analyse(engine, %{start_fen: nil, moves: []}, nodes: 1000, played: "g1f3")

      assert result.best == [
               %{move: "e2e4", cp: 30},
               %{move: "d2d4", cp: 20},
               %{move: "g1f3", cp: 10},
               %{move: "c2c4", cp: -5}
             ]

      assert result.played_cp == 10
      assert result.bestmove == "e2e4"
      refute result.restarted
    end

    test "a played move outside the top four gets its own search" do
      engine = fake("normal")

      assert {:ok, %{played_cp: -120}} =
               Uci.analyse(engine, Alnasl.Chess.start_fen(), played: "g2g4")
    end

    test "mate lines" do
      engine = fake("mate")

      assert {:ok, %{best: [%{cp: 9_997}, %{cp: -9_994}]}} =
               Uci.analyse(engine, Alnasl.Chess.start_fen())
    end

    @tag :tmp_dir
    test "an engine that dies once is restarted and asked again", %{tmp_dir: dir} do
      marker = Path.join(dir, "crashed")
      engine = fake("crash_once", [marker])

      assert {:ok, %{best: [%{move: "e2e4"} | _], restarted: true}} =
               Uci.analyse(engine, Alnasl.Chess.start_fen())

      assert %{restarts: 1} = Uci.info(engine)
      assert {:ok, %{restarted: false}} = Uci.analyse(engine, Alnasl.Chess.start_fen())
    end

    test "an engine that dies every time is reported, and the server lives on" do
      engine = fake("crash")

      assert {:error, {:engine_failed, {:exited, 3, []}}} =
               Uci.analyse(engine, Alnasl.Chess.start_fen())

      assert %{restarts: 1} = Uci.info(engine)
      assert {:error, {:engine_failed, _}} = Uci.analyse(engine, Alnasl.Chess.start_fen())
    end

    test "the engine's last words are kept" do
      engine = fake("critical")

      assert {:error, {:engine_failed, {:exited, 1, ["info string CRITICAL ERROR" <> _]}}} =
               Uci.analyse(engine, Alnasl.Chess.start_fen())
    end

    test "an engine that never answers times out, twice" do
      engine = fake("hang", [], timeout: 300)

      assert {:error, {:engine_failed, {:timeout, "bestmove"}}} =
               Uci.analyse(engine, Alnasl.Chess.start_fen())
    end
  end
end
