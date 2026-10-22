defmodule Mix.Tasks.FairPlay.Hits do
  @shortdoc "Lists the held-out player-events a fair-play model scores high"

  @moduledoc """
  A thin wrapper: everything is in `Alnasl.FairPlay.Calibration`, which a
  release without Mix runs through `bin/alnasl eval`.

      mix fair_play.hits --model model-sf19.json --holdout 0.67 [--threshold 3.0] files...

  `--holdout` must be the one the model was fitted with, or the list is of
  games the model has seen.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile")

    case Alnasl.FairPlay.Calibration.main(["hits" | args], halt: false) do
      {:ok, _} -> :ok
      {:error, reason} -> Mix.raise("fair_play.hits failed: #{inspect(reason)}")
    end
  end
end
