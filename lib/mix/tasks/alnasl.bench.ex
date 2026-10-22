defmodule Mix.Tasks.Alnasl.Bench do
  @shortdoc "Plays the bundled games through the simulator with faults and prints what the tracker made of them"

  @moduledoc """
  The tracker's fault matrix, as a table.

      mix alnasl.bench
      mix alnasl.bench --passes 3

  Every bundled game (`priv/games/*.pgn`) is played once per pass under each
  fault mix of `Alnasl.Bench.suites/0`. The first columns are the verdicts
  of `Alnasl.Bench`, a game each: `silent` is the one that must stay zero,
  and `rec WRONG` / `guess WRONG` are the games that ended as a game that
  was not played, marked orange or red where they leave it. `assumed` is
  the games in which only what a pawn became differs, at a promotion the
  box marked as assumed: the new piece was never on the board to read. `rec plies`
  and `guess plies` are the marked moves: how many are not the move the
  game has at that place, of how many; `alarms` every
  time a board went out of sync, also when it found its way back; `gave
  up` the searches that ran out of budget. `misread` is a game that
  differs at a move the board itself read wrong and never contradicted.
  `named` is the games in which an alarm said what the board showed: a
  move out of turn, or a move that is not legal.

  The last rows are fast play: `Alnasl.Simulator.Script.profile(:bullet)`,
  with the tracker's defaults and with the "Bullet / fast play" preset of
  the Setup page.

  Then the recordings of real boards (`Alnasl.HallReplays`, `mix alnasl.hall`):
  how many still come out as pinned, and how many as the game played.
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
      String.pad_trailing("fault mix", 46) <>
        "  exact  rec ok  rec WRONG  guess ok  guess WRONG  assumed  flagged  alarm  misread  silent   faults    rec plies  guess plies  alarms  named  worst search  gave up"

    Mix.shell().info(header)

    for {name, _kind, sim, tracker} <- Alnasl.Bench.suites() do
      m = Alnasl.Bench.matrix(games, sim, tracker, passes)

      v = fn key, width ->
        m.verdicts |> Map.get(key, 0) |> Integer.to_string() |> String.pad_leading(width)
      end

      n = fn number, width -> number |> Integer.to_string() |> String.pad_leading(width) end

      Mix.shell().info(
        String.pad_trailing(name, 46) <>
          v.(:exact, 7) <>
          v.(:reconstructed_right, 8) <>
          v.(:reconstructed_wrong, 11) <>
          v.(:guessed_right, 10) <>
          v.(:guessed_wrong, 13) <>
          v.(:assumed, 9) <>
          v.(:flagged, 9) <>
          v.(:alarm, 7) <>
          v.(:unnoticed, 9) <>
          v.(:silent, 8) <>
          n.(m.faults, 9) <>
          String.pad_leading("#{m.recovered_wrong}/#{m.recovered}", 13) <>
          String.pad_leading("#{m.guessed_wrong}/#{m.guessed}", 13) <>
          n.(m.alarms, 8) <>
          n.(m.named_games, 7) <>
          String.pad_leading("#{Float.round(m.max_search_ms, 1)} ms", 14) <>
          n.(m.budget_hits, 9)
      )

      for bad <- m.bad, do: Mix.shell().info("    SILENT: #{inspect(bad, limit: 12)}")
    end

    hall(Alnasl.HallReplays.check())
  end

  defp hall([]), do: :ok

  defp hall(results) do
    known = Enum.reject(results, &(&1.played? == nil))

    Mix.shell().info(
      "
real boards: #{length(results)} recordings, #{Enum.count(results, & &1.same?)} as pinned, " <>
        "#{Enum.count(known, & &1.played?)} of #{length(known)} known games as played, " <>
        "#{results |> Enum.map(& &1.now["alarms"]) |> Enum.sum()} alarms"
    )

    for r <- results, not r.same?, do: Mix.shell().info("    CHANGED: #{r.name}")
  end
end
