defmodule Mix.Tasks.FairPlay.Check do
  @shortdoc "Scores label files with a frozen fair-play model and prints the gate"

  @moduledoc """
  A thin wrapper around `Alnasl.FairPlay.Calibration` (`check`), which a
  release without Mix runs through
  `bin/alnasl eval "Alnasl.FairPlay.Calibration.main()" check ...`.

      mix fair_play.check --model FILE [--holdout F [--holdout-offset O]] files...

  Every player-event of the files is scored and counted, none fitted on:
  for a set of games kept apart from the model's whole development.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile")

    case Alnasl.FairPlay.Calibration.main(["check" | args], halt: false) do
      {:ok, _} -> :ok
      {:error, reason} -> Mix.raise("fair_play.check failed: #{inspect(reason)}")
    end
  end
end
