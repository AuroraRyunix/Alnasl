defmodule Alnasl.Recorder do
  @moduledoc """
  Keeps everything every board delivers, as it was delivered.

  One JSON object a line, appended to a file per board:

      {"t":1791700000123,"k":"cfg","flipped":false,"round":4,"board":7,"driver":"dgt_serial"}
      {"t":1791700000456,"k":"pos","b":"rnbqkbnrpppppppp................................PPPPPPPPRNBQKBNR"}
      {"t":1791700003210,"k":"clk","w":5400000,"b":5400000,"r":"white","l":"white"}
      {"t":1791700003300,"k":"rx","h":"8e0005340c"}
      {"t":1791700009000,"k":"st","v":"disconnected"}
      {"t":1791700012000,"k":"note","text":"knocked over on purpose"}

  `t` is wall-clock milliseconds. `pos` is the board exactly as the driver
  reported it - before the box turns a flipped board round - as 64 characters
  from a8 to h1. `clk` is a clock reading: both times, the side running
  (`r`: `white`, `black`, `none` - or `off` for a clock switched off) and,
  from a driver that can tell, the side its lever is set for (`l`).
  `rx`/`tx` are the raw serial bytes of a real board, hex.
  `cfg` says how the board was set up when the lines after it were written,
  so a capture can be replayed the way it was read.

  Files live in `<data>/captures/board-<id>/<start time>.jsonl`. A file is
  closed and a new one begun at `rotate_bytes` (8 MB); when all captures
  together pass the cap from Setup (500 MB), the oldest files go.

  Any game can be rebuilt from its capture, and any failure exported as a
  test fixture: `read/1` gives back the timed events a driver would deliver,
  which is what `Arkab.Driver.Replay` plays and `dry_run/2` judges.

  The writing and the format live in Arkab (`Arkab.Recorder`,
  `Arkab.Capture`), where the bridge writes its own captures the same way;
  what is Alnasl's is where the files go, the cap from Setup, and what a
  capture is good for afterwards: the list, the dry run, the fixture.
  """

  alias Alnasl.{Paths, Position, Session, Settings, Tracker}

  @doc false
  def child_spec(opts) do
    opts =
      Keyword.merge(
        [
          name: __MODULE__,
          root: &Paths.captures/0,
          cap: fn -> (Settings.get("capture_cap_mb") || 500) * 1_000_000 end
        ],
        opts
      )

    %{id: Keyword.get(opts, :name), start: {Arkab.Recorder, :start_link, [opts]}}
  end

  # --- writing -----------------------------------------------------------------

  @doc "Appends what board `board_id` delivered. Never blocks the caller and never fails it."
  def record(board_id, event, server \\ __MODULE__),
    do: Arkab.Recorder.record(server, board_id, event)

  @doc "Closes the open files, so what was written can be read back. For tests and before listing."
  def flush(server \\ __MODULE__), do: Arkab.Recorder.flush(server)

  @doc "A clock reading as the fields of a `clk` line. `mix alnasl.dgt` writes the same."
  defdelegate clock_line(reading), to: Arkab.Capture

  # --- reading -----------------------------------------------------------------

  @doc "Every capture file, newest first: `%{board_id, name, path, size, modified}`."
  def list do
    root = Paths.captures()

    for dir <- ls(root),
        String.starts_with?(dir, "board-"),
        {board_id, ""} <- [Integer.parse(String.replace_prefix(dir, "board-", ""))],
        name <- ls(Path.join(root, dir)),
        String.ends_with?(name, ".jsonl"),
        path = Path.join([root, dir, name]),
        {:ok, stat} <- [File.stat(path, time: :posix)] do
      %{board_id: board_id, name: name, path: path, size: stat.size, modified: stat.mtime}
    end
    |> Enum.sort_by(&{&1.modified, &1.name}, :desc)
  end

  # Not `Path.wildcard/1`: on Windows a data directory may come with
  # backslashes, which a glob reads as escapes.
  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      _error -> []
    end
  end

  @doc """
  Writes down, beside a board's captures, the hall the board was in, so that
  the captures of a board since removed still belong to that hall: its owner
  can reach them, and nobody else of it (`removed_visible?/2`).
  """
  def remember_hall(board_id, hall_id) when is_integer(hall_id) do
    dir = Path.join(Paths.captures(), "board-#{board_id}")
    if File.dir?(dir), do: File.write(Path.join(dir, "hall"), Integer.to_string(hall_id))
    :ok
  end

  def remember_hall(_board_id, _hall_id), do: :ok

  @doc "The hall a removed board's captures belong to, or `nil` (removed before that was written down)."
  def hall_of(board_id) do
    with {:ok, text} <- File.read(Path.join([Paths.captures(), "board-#{board_id}", "hall"])),
         {id, ""} <- Integer.parse(String.trim(text)) do
      id
    else
      _none -> nil
    end
  end

  @doc """
  May `scope` open the captures of the removed board `board_id`? The owner
  of the hall it was in, and an admin; not an arbiter. A board removed before
  its hall was written down belongs to nobody but an admin.
  """
  def removed_visible?(scope, board_id) do
    case hall_of(board_id) do
      nil -> Alnasl.Accounts.Scope.everything?(scope)
      hall_id -> Alnasl.Accounts.Scope.can?(scope, :owner, hall_id)
    end
  end

  @doc "The capture file `name` of board `board_id`, if it is one of ours."
  def find(board_id, name), do: Enum.find(list(), &(&1.board_id == board_id and &1.name == name))

  @doc """
  Reads a capture: `{:ok, %{events, cfg, notes, lines, raw?}}` where `events`
  is `[{ms_since_first_line, driver_event}]`. See `Arkab.Capture.read/2`.
  """
  defdelegate read(path, address \\ nil), to: Arkab.Capture

  @doc """
  Plays a capture through a fresh tracker without touching anything: what
  moves it makes of it and where it lost the thread. Returns
  `%{moves, plies, alarms: [{ms, why}], corrections, status, duration_ms,
  events, raw?, cfg}` and, of the clock: `presses`, `clock_alarms: [{ms,
  side}]`, `clock_cleared: [ms]`, `clock_off: [ms]` and `clock_check` (the
  starting-position check as the recording ends).
  """
  def dry_run(path, tracker_opts \\ nil, address \\ nil) do
    with {:ok, capture} <- read(path, address) do
      opts = tracker_opts || Settings.tracker_opts()
      opts = if fen = capture.cfg["start_fen"], do: Keyword.put(opts, :start_fen, fen), else: opts
      flipped? = capture.cfg["flipped"] == true

      events =
        Enum.map(capture.events, fn
          {t, {:position, board}} ->
            {t, {:position, if(flipped?, do: Position.rotate(board), else: board)}}

          other ->
            other
        end)

      # Long enough after the last line for a last move to settle, short
      # enough that a hand over the board at the end is not called an alarm.
      {session, out} = Session.run(Session.new(opts), events, tail_ms: 5_500)
      tr = session.tracker

      {:ok,
       %{
         moves: Tracker.sans(tr),
         plies: tr.plies,
         alarms: for({t, {:status, :out_of_sync, why}} <- out, do: {t, why}),
         resumed: for({t, {:status, :live, _}} <- out, do: t),
         corrections:
           for(
             {t, {:correction, keep, plies, why}} <- out,
             do: {t, keep, Enum.map(plies, & &1.san), why}
           ),
         suggestions: for({t, {:result_suggestion, result, why}} <- out, do: {t, result, why}),
         presses: presses(events),
         clock_alarms: for({t, {:warning, :clock_side, side}} <- out, do: {t, side}),
         clock_cleared: for({t, {:warning_cleared, :clock_side}} <- out, do: t),
         clock_off: for({t, {:info, %{clock: false}}} <- events, do: t),
         clock_check: Session.clock_check(session),
         unseen: for({t, {:unseen, pieces}} <- out, do: {t, pieces}),
         status: tr.status,
         detail: tr.detail,
         duration_ms: (List.last(capture.events) || {0, nil}) |> elem(0),
         events: length(capture.events),
         raw?: capture.raw?,
         cfg: capture.cfg,
         notes: capture.notes
       }}
    end
  end

  # Every press of the lever in a recording, moves or no moves (the session
  # only counts them once a game is under way).
  defp presses(events) do
    {_clock, presses} =
      Enum.reduce(events, {Alnasl.Clock.new(), 0}, fn
        {t, {:clock, reading}}, {clock, presses} ->
          {clock, pressed?} = Alnasl.Clock.update(clock, t, reading)
          {clock, presses + if(pressed?, do: 1, else: 0)}

        {t, {:info, %{clock: false}}}, {clock, presses} ->
          {Alnasl.Clock.off(clock, t), presses}

        _other, acc ->
          acc
      end)

    presses
  end

  @doc "Copies a capture to `<data>/fixtures/<name>.jsonl`, a file a test can replay. `{:ok, path}`."
  def export_fixture(path, name) do
    safe = name |> String.replace(~r/[^A-Za-z0-9_-]+/, "-") |> String.trim("-")
    safe = if safe == "", do: "capture", else: safe
    target = Path.join(Paths.fixtures(), safe <> ".jsonl")

    case File.cp(path, target) do
      :ok -> {:ok, target}
      error -> error
    end
  end
end
