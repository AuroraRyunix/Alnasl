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
  which is what `Alnasl.Driver.Replay` plays and `dry_run/2` judges.
  """

  use GenServer

  alias Alnasl.{Paths, Position, Session, Settings, Tracker}
  alias Alnasl.Dgt.Protocol

  @rotate_bytes 8_000_000

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  # --- writing -----------------------------------------------------------------

  @doc "Appends what board `board_id` delivered. Never blocks the caller and never fails it."
  def record(board_id, event, server \\ __MODULE__) do
    case line(event) do
      nil ->
        :ok

      fields ->
        GenServer.cast(
          server,
          {:record, board_id, Map.put(fields, "t", System.os_time(:millisecond))}
        )
    end
  end

  @doc "Closes the open files, so what was written can be read back. For tests and before listing."
  def flush(server \\ __MODULE__), do: GenServer.call(server, :flush, 15_000)

  defp line({:position, board}), do: %{"k" => "pos", "b" => Position.to_text(board)}

  defp line({:clock, :off}), do: %{"k" => "clk", "r" => "off"}
  defp line({:clock, reading}), do: clock_line(reading)

  defp line({:status, status}), do: %{"k" => "st", "v" => to_string(status)}

  defp line({:raw, direction, bytes}),
    do: %{"k" => to_string(direction), "h" => Base.encode16(bytes, case: :lower)}

  defp line({:cfg, fields}),
    do: Map.put(Map.new(fields, fn {k, v} -> {to_string(k), v} end), "k", "cfg")

  defp line({:note, text}), do: %{"k" => "note", "text" => text}
  defp line(_other), do: nil

  @doc "A clock reading as the fields of a `clk` line. `mix alnasl.dgt` writes the same."
  def clock_line(reading) do
    %{
      "k" => "clk",
      "w" => reading[:white_ms],
      "b" => reading[:black_ms],
      "r" => to_string(reading[:running] || :none)
    }
    |> then(&if(reading[:armed], do: Map.put(&1, "l", to_string(reading.armed)), else: &1))
  end

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

  @doc "The capture file `name` of board `board_id`, if it is one of ours."
  def find(board_id, name), do: Enum.find(list(), &(&1.board_id == board_id and &1.name == name))

  @doc """
  Reads a capture: `{:ok, %{events, cfg, notes, lines, raw?}}` where `events`
  is `[{ms_since_first_line, driver_event}]`. A capture that holds raw bytes
  and no positions (a recording of a real board, or a log written by
  `tools/serial_proxy.py`) is decoded with the DGT protocol on the way.
  """
  def read(path, address \\ nil) do
    with {:ok, text} <- File.read(path) do
      # A capture of a loop (`mix alnasl.dgt --bus`) marks each line with the
      # address it belongs to (`"a"`); `address` picks one board out of it.
      lines =
        text
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_line/1)
        |> Enum.reject(&(is_nil(&1) or (address != nil and &1["a"] not in [nil, address])))

      case lines do
        [] ->
          {:error, :empty}

        [%{"t" => t0} | _] ->
          positions? = Enum.any?(lines, &(&1["k"] == "pos"))
          raw? = Enum.any?(lines, &(&1["k"] == "rx"))

          events = if positions?, do: from_positions(lines, t0), else: from_bytes(lines, t0)

          {:ok,
           %{
             events: events,
             cfg: lines |> Enum.filter(&(&1["k"] == "cfg")) |> List.first() || %{},
             notes: for(%{"k" => "note", "t" => t, "text" => text} <- lines, do: {t - t0, text}),
             lines: length(lines),
             raw?: raw? and not positions?
           }}
      end
    end
  end

  defp parse_line(line) do
    case Jason.decode(line) do
      {:ok, %{"t" => t, "k" => _} = fields} when is_integer(t) -> fields
      _not_ours -> proxy_line(line)
    end
  end

  # tools/serial_proxy.py: "   12.345678  BRD>APP  86 00 43 ..." and "# 12.3  NOTE  text".
  defp proxy_line(line) do
    case Regex.run(~r/^\s*(\d+\.\d+)\s+(APP>BRD|BRD>APP)\s+([0-9a-fA-F ]+)$/, line) do
      [_, seconds, direction, hex] ->
        %{
          "t" => round(String.to_float(seconds) * 1000),
          "k" => if(direction == "BRD>APP", do: "rx", else: "tx"),
          "h" => String.replace(hex, " ", "")
        }

      nil ->
        case Regex.run(~r/^#\s*(\d+\.\d+)\s+NOTE\s+(.*)$/, line) do
          [_, seconds, text] ->
            %{"t" => round(String.to_float(seconds) * 1000), "k" => "note", "text" => text}

          nil ->
            nil
        end
    end
  end

  defp from_positions(lines, t0) do
    Enum.flat_map(lines, fn
      %{"k" => "pos", "t" => t, "b" => text} ->
        case Position.from_text(text) do
          {:ok, board} -> [{t - t0, {:position, board}}]
          :error -> []
        end

      %{"k" => "clk", "t" => t, "r" => "off"} ->
        [{t - t0, {:info, %{clock: false}}}]

      %{"k" => "clk", "t" => t} = line ->
        reading = %{white_ms: line["w"], black_ms: line["b"], running: running(line["r"])}

        reading =
          case line["l"] do
            "white" -> Map.put(reading, :armed, :white)
            "black" -> Map.put(reading, :armed, :black)
            _none -> reading
          end

        [{t - t0, {:clock, reading}}]

      %{"k" => "st", "t" => t, "v" => "connected"} ->
        [{t - t0, :connected}]

      %{"k" => "st", "t" => t, "v" => "disconnected"} ->
        [{t - t0, :disconnected}]

      _other ->
        []
    end)
  end

  # Raw bytes only: run them through the protocol parser and the same small
  # board model the serial driver keeps.
  defp from_bytes(lines, t0) do
    {events, _state} =
      lines
      |> Enum.filter(&(&1["k"] == "rx"))
      |> Enum.flat_map_reduce({<<>>, nil}, fn %{"t" => t, "h" => hex}, {buffer, board} ->
        bytes =
          case Base.decode16(hex, case: :mixed) do
            {:ok, bytes} -> bytes
            :error -> <<>>
          end

        {messages, rest} = Protocol.parse(buffer <> bytes)

        {events, board} =
          Enum.flat_map_reduce(messages, board, fn message, board ->
            case Protocol.apply_message(message, board) do
              {:position, board} -> {[{t - t0, {:position, board}}], board}
              {:clock, reading} -> {[{t - t0, {:clock, reading}}], board}
              {:info, %{clock: false} = off} -> {[{t - t0, {:info, off}}], board}
              _other -> {[], board}
            end
          end)

        {events, {rest, board}}
      end)

    events
  end

  defp running("white"), do: :white
  defp running("black"), do: :black
  defp running(_other), do: :none

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

  # --- the process -------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       files: %{},
       rotate: Keyword.get(opts, :rotate_bytes, @rotate_bytes),
       dir: Keyword.get(opts, :dir)
     }}
  end

  @impl true
  def handle_cast({:record, board_id, fields}, state) do
    {:noreply, write(state, board_id, fields)}
  rescue
    _error -> {:noreply, state}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    for {_id, %{io: io}} <- state.files, do: File.close(io)
    {:reply, :ok, %{state | files: %{}}}
  end

  @impl true
  def terminate(_reason, state) do
    for {_id, %{io: io}} <- state.files, do: File.close(io)
    :ok
  end

  defp write(state, board_id, fields) do
    data = [Jason.encode_to_iodata!(fields), ?\n]
    size = IO.iodata_length(data)

    file =
      case state.files[board_id] do
        %{bytes: bytes} = file when bytes + size <= state.rotate ->
          file

        stale ->
          if stale, do: File.close(stale.io)
          open(state, board_id)
      end

    IO.binwrite(file.io, data)
    %{state | files: Map.put(state.files, board_id, %{file | bytes: file.bytes + size})}
  end

  defp open(state, board_id) do
    dir = Path.join(state.dir || Paths.captures(), "board-#{board_id}")
    File.mkdir_p!(dir)
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")
    path = unique(dir, stamp, 0)
    {:ok, io} = File.open(path, [:append, :binary, {:delayed_write, 64_000, 500}])
    enforce_cap(state)
    %{io: io, bytes: 0, path: path}
  end

  defp unique(dir, stamp, n) do
    path = Path.join(dir, if(n == 0, do: "#{stamp}.jsonl", else: "#{stamp}-#{n}.jsonl"))
    if File.exists?(path), do: unique(dir, stamp, n + 1), else: path
  end

  # The cap is on everything together; the oldest file goes first.
  defp enforce_cap(%{dir: nil}) do
    cap = (Settings.get("capture_cap_mb") || 500) * 1_000_000
    files = Enum.reverse(list())
    total = files |> Enum.map(& &1.size) |> Enum.sum()

    Enum.reduce_while(files, total, fn file, total ->
      if total > cap do
        File.rm(file.path)
        {:cont, total - file.size}
      else
        {:halt, total}
      end
    end)

    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp enforce_cap(_state), do: :ok
end
