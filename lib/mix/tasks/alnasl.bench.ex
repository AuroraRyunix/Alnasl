defmodule Mix.Tasks.Alnasl.Bench do
  @shortdoc "Plays the bundled games through the simulator with faults and prints what the tracker made of them"

  @moduledoc """
  The tracker's fault matrix, as a table.

      mix alnasl.bench
      mix alnasl.bench --passes 3

  Every bundled game (`priv/games/*.pgn`) is played once per pass under each
  fault mix of `Alnasl.Bench.suites/0`. The columns are the verdicts of
  `Alnasl.Bench`: `silent` is the one that must stay zero.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [passes: :integer])
    passes = opts[:passes] || 1
    Mix.Task.run("app.config")
    Application.ensure_all_started(:jason)
    games = Alnasl.Pgn.all_bundled()

    Mix.shell().info(
      "#{length(games)} games, #{games |> Enum.map(&length(&1.moves)) |> Enum.sum()} plies, #{passes} pass(es)\n"
    )

    header =
      String.pad_trailing("fault mix", 40) <>
        "  exact  ambig  alarm  flagged  silent  faults  recovered  corrections  worst search"

    Mix.shell().info(header)

    for {name, _kind, sim} <- Alnasl.Bench.suites() do
      m = Alnasl.Bench.matrix(games, sim, [], passes)
      v = fn key -> m.verdicts |> Map.get(key, 0) |> Integer.to_string() end

      Mix.shell().info(
        String.pad_trailing(name, 40) <>
          String.pad_leading(v.(:exact), 7) <>
          String.pad_leading(v.(:ambiguous), 7) <>
          String.pad_leading(v.(:alarm), 7) <>
          String.pad_leading(v.(:flagged), 9) <>
          String.pad_leading(v.(:silent), 8) <>
          String.pad_leading(Integer.to_string(m.faults), 8) <>
          String.pad_leading(Integer.to_string(m.recovered), 11) <>
          String.pad_leading(Integer.to_string(m.corrections), 13) <>
          String.pad_leading("#{Float.round(m.max_search_ms, 1)} ms", 14)
      )

      for bad <- m.bad, do: Mix.shell().info("    SILENT: #{inspect(bad, limit: 12)}")
    end
  end
end
