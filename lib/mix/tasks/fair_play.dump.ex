defmodule Mix.Tasks.FairPlay.Dump do
  @shortdoc "Writes every counted ply of a calibration run as numbers, for outside analysis"

  @moduledoc """
  A thin wrapper around `Alnasl.FairPlay.Dump`.

      mix fair_play.dump --holdout 0.67 --out plies.csv files...
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile")
    Alnasl.FairPlay.Dump.main(args, halt: false)
    :ok
  end
end
