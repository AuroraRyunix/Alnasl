defmodule Mix.Tasks.FairPlay.Power do
  @shortdoc "Measures how many synthetic cheaters the fair-play score catches"

  @moduledoc """
  A thin wrapper around `Alnasl.FairPlay.Power`, which a release without
  Mix runs through `bin/alnasl eval "Alnasl.FairPlay.Power.main()"`.

      mix fair_play.power --holdout 0.67 [--model FILE] [--rates 0.05,0.1] \\
        [--games 1,2,3] [--window 40] [--seed 1] [--tune 0.5] [--budget 0.01] \\
        [--limit N] [--out FILE] files...

  `--holdout` must be the fit's: cheats go only into the events the model
  never saw, and only the same fraction finds the same events.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile")

    case Alnasl.FairPlay.Power.main(args, halt: false) do
      {:ok, _} -> :ok
      {:error, reason} -> Mix.raise("fair_play.power failed: #{inspect(reason)}")
    end
  end
end
