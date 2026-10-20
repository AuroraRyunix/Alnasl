defmodule Alnasl.FairPlay.StockfishTest do
  @moduledoc """
  The real thing, once: install the official archive for this machine,
  check its bench, and ask it about a position. Not run by default (it needs
  an 80 MB archive and a few seconds of CPU):

      ALNASL_STOCKFISH_ARCHIVE=/path/to/stockfish-windows-x86-64-universal.zip \\
        mix test --only stockfish
  """
  use ExUnit.Case, async: false

  alias Alnasl.FairPlay.{Installer, Uci}

  @moduletag :stockfish
  @moduletag :tmp_dir
  @moduletag timeout: 600_000

  test "installs, benches, and analyses with Stockfish 19", %{tmp_dir: tmp} do
    # A 100 MB binary has no business staying in tmp/ after the test.
    on_exit(fn -> File.rm_rf(tmp) end)

    archive =
      System.get_env("ALNASL_STOCKFISH_ARCHIVE") ||
        flunk("set ALNASL_STOCKFISH_ARCHIVE to the official sf_19 archive for this machine")

    assert {:ok, installed} = Installer.install({:file, archive}, dir: tmp)
    assert installed.bench == 2_497_913

    engine = start_supervised!({Uci, cmd: installed.path})
    assert %{name: "Stockfish 19"} = Uci.info(engine)

    position = %{start_fen: nil, moves: ~w(e2e4 e7e5 g1f3 b8c6 f1b5)}

    assert {:ok, %{best: best, played_cp: played_cp}} =
             Uci.analyse(engine, position, nodes: 50_000, played: "g7g5")

    assert length(best) == 4
    assert Enum.all?(best, &(&1.cp > -100 and &1.cp < 50))
    refute "g7g5" in Enum.map(best, & &1.move)
    assert played_cp < hd(best).cp - 50

    # Deterministic: the hash is cleared before every position.
    assert {:ok, %{best: ^best}} = Uci.analyse(engine, position, nodes: 50_000)
  end
end
