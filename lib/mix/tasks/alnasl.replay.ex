defmodule Mix.Tasks.Alnasl.Replay do
  @shortdoc "Replays a capture file through the tracker and prints what it makes of it"

  @moduledoc """
  A dry run of a capture, at a desk: nothing is saved, nothing is sent.

      mix alnasl.replay captures/dgt-20261012-093000.jsonl
      mix alnasl.replay capture-1.log --settle 300
      mix alnasl.replay data/captures/board-3/20261012-101500.jsonl --timeline

  Takes a capture written by Alnasl (`<data>/captures/...`, or `mix
  alnasl.dgt`) or a log written by `tools/serial_proxy.py` - raw bytes are
  decoded with the DGT protocol on the way in. Prints how many readings it
  held, the moves the tracker found, every time it went out of sync and
  every correction, and the notes typed during the capture with their times,
  so a note "castled, king first" can be checked against what was found.

  `--address N` picks one board out of a capture of a loop (`mix alnasl.dgt
  --bus`).

  `--timeline` also prints every position as it came, with its time: the
  way to see WHY the tracker made what it made.
  """

  use Mix.Task

  alias Alnasl.{Clock, Position, Recorder}

  @impl Mix.Task
  def run(args) do
    {opts, files} =
      OptionParser.parse!(args,
        strict: [settle: :integer, depth: :integer, timeline: :boolean, address: :integer]
      )

    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:jason)

    tracker =
      [settle_ms: opts[:settle], search_depth: opts[:depth]]
      |> Enum.reject(fn {_key, value} -> value == nil end)

    for file <- files do
      Mix.shell().info("\n#{file}")

      case Recorder.dry_run(file, tracker, opts[:address]) do
        {:ok, report} -> print(file, report, opts)
        {:error, reason} -> Mix.shell().error("  cannot be read: #{inspect(reason)}")
      end
    end
  end

  defp print(file, report, opts) do
    info = fn text -> Mix.shell().info(text) end

    info.(
      "  #{report.events} readings over #{Clock.format(report.duration_ms)}#{if report.raw?, do: " (decoded from raw bytes)", else: ""}"
    )

    if opts[:timeline] do
      {:ok, capture} = Recorder.read(file, opts[:address])

      for {t, event} <- capture.events do
        case event do
          {:position, board} ->
            info.("  #{at(t)}  #{Position.placement(board)}")

          {:clock, c} ->
            info.(
              "  #{at(t)}  clock w #{Clock.format(c.white_ms)} b #{Clock.format(c.black_ms)} #{c.running}"
            )

          other ->
            info.("  #{at(t)}  #{inspect(other)}")
        end
      end
    end

    numbered =
      report.plies
      |> Enum.with_index()
      |> Enum.map_join(" ", fn {ply, i} ->
        flags = if ply.flags == [], do: "", else: "{#{Enum.join(ply.flags, ",")}}"
        if(rem(i, 2) == 0, do: "#{div(i, 2) + 1}. ", else: "") <> ply.san <> flags
      end)

    info.("  moves (#{length(report.moves)}): #{numbered}")

    info.(
      "  ends: #{report.status}#{if report.detail, do: " (#{inspect(report.detail)})", else: ""}"
    )

    for {t, why} <- report.alarms, do: info.("  OUT OF SYNC at #{at(t)}: #{inspect(why)}")

    for {t, keep, moves, why} <- report.corrections,
        do: info.("  correction at #{at(t)}: keep #{keep}, then #{inspect(moves)} (#{why})")

    for {t, result, why} <- report.suggestions,
        do: info.("  result suggested at #{at(t)}: #{result} (#{why})")

    for {t, text} <- report.notes, do: info.("  note at #{at(t)}: #{text}")
  end

  defp at(ms),
    do:
      "#{div(ms, 60_000)}:#{ms |> rem(60_000) |> div(1000) |> Integer.to_string() |> String.pad_leading(2, "0")}.#{ms |> rem(1000) |> div(100)}"
end
