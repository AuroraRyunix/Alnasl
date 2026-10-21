defmodule Alnasl.HallReplays do
  @moduledoc """
  Recordings of real boards, kept with the game the tracker must make of them.

  The simulator is what the tracker is tuned on; a real board is what it is
  for. Every game recorded at a real board that is worth keeping goes into
  `test/fixtures/hall/` with an entry in `pinned.json` beside it, and the
  tests replay each one and hold the tracker to it
  (`test/alnasl/hall_replays_test.exs`). `mix alnasl.hall` pins a new one
  and checks them all.

  ## What is kept

  The capture as the tracker reads it: the positions, the clock, the cable
  coming and going, the notes, and the `cfg` line - one JSON object a line,
  the format of `docs/capture.md`. The raw serial bytes are not: where a
  recording holds only bytes they are decoded once, on the way in, so the
  file is a test of the tracker and not of the driver (the driver has its
  own: `test/alnasl/real_board_test.exs`). Time stays as it was recorded.

  ## What is held

  Two games, because the truth is not always known:

  - `pinned` - what the tracker made of the recording when it was pinned:
    the moves, the marks on each, how it ended and how often it went out of
    sync. Any change to that is a test failure, better or worse: a change
    that makes a real game come out differently is looked at, then pinned
    again on purpose;
  - `played` - the game that was really played, when somebody knows it
    (from the scoresheet, or the notes typed while it was played), with
    `source` saying how it is known. `nil` when nobody does. A recording
    whose `pinned` differs from its `played` is a known miss, and `check/1`
    says so every time it runs.
  """

  alias Alnasl.Recorder

  @dir "test/fixtures/hall"
  @manifest "pinned.json"

  @doc "Where the recordings and `pinned.json` live (relative to the project)."
  def dir, do: @dir

  @doc "The pinned recordings: `%{name => entry}`, entries with string keys as stored."
  def pinned(dir \\ @dir) do
    case File.read(Path.join(dir, @manifest)) do
      {:ok, text} -> Jason.decode!(text)
      {:error, :enoent} -> %{}
    end
  end

  @doc """
  What the tracker makes of `path` now, in the shape of a `pinned` entry:
  `%{"moves", "marks", "status", "alarms"}`. `marks` is the flags of each
  ply that has any, as `"<ply>. <san>: <flags>"`.
  """
  def replay(path, tracker \\ []) do
    with {:ok, report} <- Recorder.dry_run(path, tracker) do
      {:ok,
       %{
         "moves" => report.moves,
         "marks" =>
           for(
             {ply, index} <- Enum.with_index(report.plies, 1),
             flags = ply.flags,
             flags != [],
             do: "#{index}. #{ply.san}: #{Enum.map_join(flags, ",", &to_string/1)}"
           ),
         "status" => to_string(report.status),
         "alarms" => length(report.alarms)
       }}
    end
  end

  @doc """
  Copies the capture at `source` into the hall as `<name>.jsonl` (decoded,
  without raw bytes; one board of a loop with `:address`), replays it and
  writes its entry. Options: `:played` (the real game, SAN), `:source`
  (how that is known), `:note`, `:address`, `:dir`. `{:ok, entry}`.
  """
  def pin(source, name, opts \\ []) do
    dir = Keyword.get(opts, :dir, @dir)
    name = safe(name)
    target = Path.join(dir, name <> ".jsonl")
    File.mkdir_p!(dir)

    with :ok <- compact(source, target, opts[:address]),
         {:ok, now} <- replay(target) do
      entry =
        %{
          "capture" => name <> ".jsonl",
          "pinned" => now,
          "played" => opts[:played],
          "source" => opts[:source],
          "note" => opts[:note]
        }

      manifest = Map.put(pinned(dir), name, entry)
      File.write!(Path.join(dir, @manifest), Jason.encode_to_iodata!(manifest, pretty: true))
      {:ok, entry}
    end
  end

  @doc """
  Replays every pinned recording. `[%{name, entry, now, same?, played?}]`:
  `same?` when the tracker still makes exactly the pinned game of it,
  `played?` when that is the game really played (`nil` when nobody knows).
  """
  def check(dir \\ @dir, tracker \\ []) do
    for {name, entry} <- Enum.sort(pinned(dir)) do
      {:ok, now} = replay(Path.join(dir, entry["capture"]), tracker)

      %{
        name: name,
        entry: entry,
        now: now,
        same?: now == entry["pinned"],
        played?: if(entry["played"], do: now["moves"] == entry["played"])
      }
    end
  end

  # The capture as the tracker reads it, one line an event.
  defp compact(source, target, address) do
    with {:ok, capture} <- Recorder.read(source, address) do
      # Times from the first line of the recording, which is all a replay
      # uses of them.
      t0 = 0
      cfg = capture.cfg |> Map.drop(["t", "k", "port", "a"]) |> Map.put("address", nil)

      events =
        Enum.map(capture.events, fn
          {t, {:info, %{clock: false}}} -> {t, {:clock, :off}}
          {t, :connected} -> {t, {:status, :connected}}
          {t, :disconnected} -> {t, {:status, :disconnected}}
          other -> other
        end)

      notes = Enum.map(capture.notes, fn {t, text} -> {t, {:note, text}} end)

      lines =
        [{0, {:cfg, cfg}} | Enum.sort_by(events ++ notes, &elem(&1, 0))]
        |> Enum.flat_map(fn {t, event} ->
          case Arkab.Capture.line(event) do
            nil -> []
            fields -> [Jason.encode!(Map.put(fields, "t", t0 + t))]
          end
        end)

      File.write(target, Enum.join(lines, "\n") <> "\n")
    end
  end

  defp safe(name) do
    case name |> String.replace(~r/[^A-Za-z0-9_-]+/, "-") |> String.trim("-") do
      "" -> "recording"
      safe -> safe
    end
  end
end
