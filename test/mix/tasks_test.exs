defmodule Mix.Tasks.AlnaslTasksTest do
  @moduledoc """
  The tools for a desk: replaying a capture through the tracker, and the
  capture that is checked in as a fixture - a recording of a simulated board
  with hands all over it, which is also the example of what "export as test
  fixture" is for.
  """

  use ExUnit.Case, async: false

  alias Alnasl.Recorder

  @fixture "test/fixtures/captures/opera-with-hands.jsonl"
  @opera ~w(e4 e5 Nf3 d6 d4 Bg4 dxe5 Bxf3 Qxf3 dxe5 Bc4 Nf6 Qb3 Qe7 Nc3 c6 Bg5 b5 Nxb5 cxb5
            Bxb5+ Nbd7 O-O-O Rd8 Rxd7 Rxd7 Rd1 Qe6 Bxd7+ Nxd7 Qb8+ Nxb8 Rd8#)

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  test "the fixture: lifts, knocks, swaps, takebacks and slides, and the game comes out whole" do
    assert {:ok, report} = Recorder.dry_run(@fixture, [])
    assert report.moves == @opera
    assert report.alarms == []
    assert report.corrections != []
    assert {_t, "1-0", :checkmate} = hd(report.suggestions)
    assert {_t, "1-0", :gesture} = List.last(report.suggestions)
    assert [{0, note}] = report.notes
    assert note =~ "Morphy"
  end

  test "the same capture with an impatient tracker still never emits a wrong final game" do
    assert {:ok, report} = Recorder.dry_run(@fixture, settle_ms: 100)
    assert report.moves == @opera
  end

  test "mix alnasl.replay prints the moves, the corrections and the notes" do
    Mix.Tasks.Alnasl.Replay.run([@fixture])
    lines = collect()
    assert Enum.any?(lines, &(&1 =~ "moves (33): 1. e4 e5 2. Nf3 d6"))
    assert Enum.any?(lines, &(&1 =~ "17. Rd8#"))
    assert Enum.any?(lines, &(&1 =~ "ends: "))
    assert Enum.any?(lines, &(&1 =~ "correction at"))
    assert Enum.any?(lines, &(&1 =~ "result suggested at"))
    assert Enum.any?(lines, &(&1 =~ "note at 0:00.0"))
    refute Enum.any?(lines, &(&1 =~ "OUT OF SYNC"))
  end

  test "mix alnasl.replay --timeline shows every reading, and says so when a file cannot be read" do
    Mix.Tasks.Alnasl.Replay.run([@fixture, "--timeline"])
    assert Enum.count(collect(), &(&1 =~ ~r{^  \d+:\d\d\.\d  [rnbqkpRNBQKP1-8/]+$})) > 100

    Mix.Tasks.Alnasl.Replay.run(["no/such/file.jsonl"])
    assert_received {:mix_shell, :error, [message]}
    assert message =~ "cannot be read"
  end

  test "mix alnasl.bench is documented and its suites are the ones the tests assert" do
    assert Mix.Task.get("alnasl.bench") == Mix.Tasks.Alnasl.Bench
    assert Mix.Task.get("alnasl.demo") == Mix.Tasks.Alnasl.Demo
    assert Mix.Task.get("alnasl.e2e") == Mix.Tasks.Alnasl.E2e
    assert Mix.Task.get("alnasl.dgt") == Mix.Tasks.Alnasl.Dgt
    assert length(Alnasl.Bench.suites()) >= 17
  end

  defp collect(acc \\ []) do
    receive do
      {:mix_shell, :info, [line]} -> collect([line | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
