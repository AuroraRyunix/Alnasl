defmodule Mix.Tasks.FairPlay.Label do
  @shortdoc "Analyses one shard of Lichess broadcast games for the fair-play calibration"

  @moduledoc """
  A thin wrapper: everything is in `Alnasl.FairPlay.Calibration`, which a
  release without Mix runs through `bin/alnasl eval`. The options are
  there, and in docs/fair-play-calibration.md.

      mix fair_play.label [options] files...
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile")

    case Alnasl.FairPlay.Calibration.main(["label" | args], halt: false) do
      {:ok, _} -> :ok
      {:error, reason} -> Mix.raise("fair_play.label failed: #{inspect(reason)}")
    end
  end
end
