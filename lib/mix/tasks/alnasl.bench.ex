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

  ## At scale

      mix alnasl.bench --pgn games.pgn --limit 5000 --suites 15,16,19 --out runs/

  - `--pgn FILE|DIR` - the games of that file (or of every `.pgn` in that
    directory) instead of the bundled ones; games from another starting
    position, or that do not replay, are left out;
  - `--offset N`, `--limit N` - a slice of them;
  - `--suites LIST` - only these suites: their numbers (`--list` prints
    them) or kinds (`gap2`, `between`, ...), comma-separated;
  - `--seed-base N` - added to every seed, for another sample of the same
    games;
  - `--out DIR` - every run that did not end exact, per suite, as an
    Erlang term file (`Alnasl.Bench.scale/5`'s `failures`), to play again
    and sort by cause.

  Nothing is kept of a run but its numbers, so ten thousand games fit.
  The real-board recordings are left out of such a run.
  """

  use Mix.Task

  @switches [
    passes: :integer,
    pgn: :string,
    offset: :integer,
    limit: :integer,
    suites: :string,
    seed_base: :integer,
    out: :string,
    list: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    passes = opts[:passes] || 1
    Mix.Task.run("app.config")
    Application.ensure_all_started(:jason)

    suites = Alnasl.Bench.suites() |> Enum.with_index(1) |> select(opts[:suites])

    if opts[:list] do
      for {{name, kind, _sim, _tracker}, n} <- suites,
          do: Mix.shell().info("#{String.pad_leading("#{n}", 3)}  #{kind}  #{name}")
    else
      scaled? = opts[:pgn] != nil or opts[:out] != nil
      games = opts |> games() |> slice(opts)

      Mix.shell().info(
        "#{length(games)} games, #{games |> Enum.map(&length(&1.moves)) |> Enum.sum()} plies, #{passes} pass(es)\n"
      )

      header =
        String.pad_trailing("fault mix", 46) <>
          "  exact  rec ok  rec WRONG  guess ok  guess WRONG  assumed  flagged  alarm  misread  silent   faults    rec plies  guess plies  alarms  named  worst search  gave up"

      Mix.shell().info(header)
      if opts[:out], do: File.mkdir_p!(opts[:out])

      for {{name, kind, sim, tracker}, n} <- suites do
        m =
          if scaled?,
            do: Alnasl.Bench.scale(games, sim, tracker, passes, seed_base: opts[:seed_base]),
            else: Alnasl.Bench.matrix(games, sim, tracker, passes)

        Mix.shell().info(row(name, m))
        for bad <- m.bad, do: Mix.shell().info("    SILENT: #{inspect(bad, limit: 12)}")

        if opts[:out] do
          file = Path.join(opts[:out], "#{String.pad_leading("#{n}", 2, "0")}-#{kind}.etf")

          term = %{
            suite: n,
            name: name,
            kind: kind,
            sim: sim,
            tracker: tracker,
            pgn: opts[:pgn],
            offset: opts[:offset] || 0,
            seed_base: opts[:seed_base] || 0,
            summary: Map.drop(m, [:failures]),
            failures: m.failures
          }

          File.write!(file, :erlang.term_to_binary(term))
        end
      end

      unless scaled?, do: hall(Alnasl.HallReplays.check())
    end
  end

  defp row(name, m) do
    v = fn key, width ->
      m.verdicts |> Map.get(key, 0) |> Integer.to_string() |> String.pad_leading(width)
    end

    n = fn number, width -> number |> Integer.to_string() |> String.pad_leading(width) end

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
      String.pad_leading("#{Float.round(m.max_search_ms / 1, 1)} ms", 14) <>
      n.(m.budget_hits, 9)
  end

  defp games(opts) do
    case opts[:pgn] do
      nil ->
        Alnasl.Pgn.all_bundled()

      path ->
        files =
          if File.dir?(path),
            do:
              path
              |> File.ls!()
              |> Enum.filter(&String.ends_with?(&1, ".pgn"))
              |> Enum.sort()
              |> Enum.map(&Path.join(path, &1)),
            else: [path]

        {games, problems} =
          files |> Enum.map(&File.read!/1) |> Enum.join("\n\n") |> Alnasl.Pgn.load()

        games = Enum.filter(games, &(&1.start_fen in [nil, Alnasl.Chess.start_fen()]))

        if problems != [],
          do: Mix.shell().info("#{length(problems)} games left out: they do not replay")

        games
    end
  end

  defp slice(games, opts) do
    games = Enum.drop(games, opts[:offset] || 0)
    if opts[:limit], do: Enum.take(games, opts[:limit]), else: games
  end

  defp select(suites, nil), do: suites

  defp select(suites, list) do
    wanted = list |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    Enum.filter(suites, fn {{_name, kind, _sim, _tracker}, n} ->
      "#{n}" in wanted or "#{kind}" in wanted
    end)
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
