defmodule Mix.Tasks.FairPlay.Fit do
  @shortdoc "Fits the fair-play model from label files and prints the held-out check"

  @moduledoc """
  A thin wrapper: everything is in `Alnasl.FairPlay.Calibration`, which a
  release without Mix runs through `bin/alnasl eval`. The options are
  there, and in docs/fair-play-calibration.md.

      mix fair_play.fit [options] files...
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile")

    case Alnasl.FairPlay.Calibration.main(["fit" | args], halt: false) do
      {:ok, _} -> :ok
      {:error, reason} -> Mix.raise("fair_play.fit failed: #{inspect(reason)}")
    end
  end
end
