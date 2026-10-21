defmodule Mix.Tasks.Alnasl.Hall do
  @shortdoc "Pins a recording of a real board as a regression test, or checks them all"

  @moduledoc """
  The recordings of real boards the tracker is held to (`Alnasl.HallReplays`).

      mix alnasl.hall check
      mix alnasl.hall pin <capture> --name <name> [--played "e4 e5 Nf3"] [--source scoresheet] [--note "..."] [--address N]

  `check` replays every recording in `test/fixtures/hall/` and says, for
  each, whether the tracker still makes the pinned game of it and whether
  that is the game that was played (where somebody knows). A recording
  whose game changed is printed with what it is now; pin it again on purpose
  once the change has been looked at.

  `pin` copies a capture - one from `<data>/captures/board-<id>/`, or
  anything `mix alnasl.replay` reads - into the hall, decoded and without
  its raw bytes, replays it and writes what the tracker made of it to
  `pinned.json`. `--played` is the real game when it is known: a recording
  whose pinned game is not the played one is a known miss, reported by
  every `check`. Pinning a name again replaces it.

  Then commit the `.jsonl` and `pinned.json`: `mix test
  test/alnasl/hall_replays_test.exs` holds the tracker to them from then on.
  """

  use Mix.Task

  alias Alnasl.HallReplays

  @impl Mix.Task
  def run(["check" | _rest]) do
    start()
    results = HallReplays.check()

    for r <- results do
      verdict = if r.same?, do: "as pinned", else: "CHANGED"

      played =
        case r.played? do
          nil -> "game not known"
          true -> "the game played"
          false -> "NOT the game played"
        end

      Mix.shell().info(
        "#{String.pad_trailing(r.name, 36)} #{String.pad_leading("#{length(r.now["moves"])}", 4)} plies  #{String.pad_trailing(r.now["status"], 12)} #{r.now["alarms"]} alarm(s)  #{verdict}, #{played}"
      )

      unless r.same? do
        Mix.shell().info("    pinned: #{Enum.join(r.entry["pinned"]["moves"], " ")}")
        Mix.shell().info("    now:    #{Enum.join(r.now["moves"], " ")}")
      end
    end

    changed = Enum.count(results, &(not &1.same?))
    missed = Enum.count(results, &(&1.played? == false))

    Mix.shell().info(
      "\n#{length(results)} recordings, #{changed} changed, #{missed} not the game played"
    )
  end

  def run(["pin", source | args]) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [
          name: :string,
          played: :string,
          source: :string,
          note: :string,
          address: :integer
        ]
      )

    start()
    name = opts[:name] || Path.basename(source, Path.extname(source))
    played = if opts[:played], do: String.split(opts[:played])

    case HallReplays.pin(source, name,
           played: played,
           source: opts[:source] || (played && "given when pinned"),
           note: opts[:note],
           address: opts[:address]
         ) do
      {:ok, entry} ->
        pinned = entry["pinned"]

        Mix.shell().info(
          "pinned #{entry["capture"]}: #{length(pinned["moves"])} plies, #{pinned["status"]}, #{pinned["alarms"]} alarm(s)"
        )

        Mix.shell().info("  #{Enum.join(pinned["moves"], " ")}")
        for mark <- pinned["marks"], do: Mix.shell().info("  #{mark}")

        if played && played != pinned["moves"],
          do: Mix.shell().info("  NOT the game played - pinned as a known miss")

      {:error, reason} ->
        Mix.raise("cannot pin #{source}: #{inspect(reason)}")
    end
  end

  def run(_args),
    do: Mix.raise("usage: mix alnasl.hall check | mix alnasl.hall pin <capture> --name <name>")

  defp start do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:jason)
  end
end
