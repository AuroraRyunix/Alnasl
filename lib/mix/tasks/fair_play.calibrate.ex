defmodule Mix.Tasks.FairPlay.Calibrate do
  @shortdoc "Labels and fits the fair-play model on one machine"

  @moduledoc """
  A thin wrapper: everything is in `Alnasl.FairPlay.Calibration`, which a
  release without Mix runs through `bin/alnasl eval`. The options are
  there, and in docs/fair-play-calibration.md.

      mix fair_play.calibrate [options] files...
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile")

    case Alnasl.FairPlay.Calibration.main(["calibrate" | args], halt: false) do
      {:ok, _} -> :ok
      {:error, reason} -> Mix.raise("fair_play.calibrate failed: #{inspect(reason)}")
    end
  end
end
