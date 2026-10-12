defmodule Mix.Tasks.Alnasl.Loop do
  @shortdoc "Asks a serial port what DGT boards are on it, byte by byte, and writes a capture"

  @moduledoc """
  The loop's debug mode: several DGT boards on one serial line.

      mix alnasl.loop --port COM5 --discover
      mix alnasl.loop --port COM5 --watch --seconds 60
      mix alnasl.loop --port COM5 --probe "s:4a w:300 b:ping:0 w:1500"
      mix alnasl.loop --port COM5 --leave

  It starts nothing but the port - no site, no database, no driver. Every
  byte sent and received is printed in hex with the time in milliseconds and
  written to `--out` (default `captures/loop-<time>.jsonl`) in the capture
  format, so that the recording can be kept as a test fixture.

  ## --discover

  What the box does when a port is added: the bus-mode byte, then a ping to
  everybody until nobody new answers (`Alnasl.Dgt.Loop`). Then each board
  found is asked its version and its position, and gets a line.

  ## --watch

  Discovers, then lets go of the port and starts the real bus driver on it
  (`Alnasl.Driver.DgtBus`) for the boards found, for `--seconds` (60):
  prints every position, clock reading and missed poll, every byte that
  said something, a board that was plugged in since - and at the end how
  many questions each board answered and how long they took.

  ## --leave

  Sends every board the "end bus mode" command (to address 0), so that a
  program that expects single boards finds them.

  ## --probe "steps"

  A script, one step per word:

      s:4a           single-board command bytes, in hex
      b:ping:0       a bus command by name (or by hex id: b:87:0) to an
                     address (decimal)
      w:500          wait 500 ms, listening
      r:300          wait for an answer: until the line has been silent for
                     60 ms, at most 300 ms
      q:300          wait for one whole answer (its length says when it is
                     whole), at most 300 ms; prints the round-trip time, and
                     the run ends with the median and the worst per size
      x10:...+...    (prefix) repeat the steps ten times:
                     x10:b:changes:12345+q:300
      n:some-words   a note in the capture

  Only bytes that ask a board something or switch its mode are let through
  (`s:` 40-47, 49-4d, 55; `b:` 81-8d). Nothing that sets a clock, writes
  the board's memory or starts its bootloader can be sent from here.

  `--seconds` is the most the whole run may take (60, at most 120); the port
  is closed at the end whatever happened.

  Needs the serial library: on Windows start with `ALNASL_UART=1` from a
  build path without a space in it (see the README).
  """

  use Mix.Task

  import Bitwise

  alias Alnasl.Dgt.{Bus, Loop}
  alias Alnasl.{Position, Transport}

  # Single-board commands that ask or switch modes. 0x48 and 0x4E and up are
  # not on the list: the published header has a bootloader in that range.
  @single_allowed [0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x49, 0x4A, 0x4B, 0x4C, 0x4D] ++
                    [0x55]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [
          port: :string,
          out: :string,
          seconds: :integer,
          probe: :string,
          discover: :boolean,
          watch: :boolean,
          leave: :boolean,
          stay: :boolean
        ]
      )

    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:jason)
    if Transport.Uart.available?(), do: Application.ensure_all_started(:circuits_uart)

    port = opts[:port] || Mix.raise("Give --port. mix alnasl.dgt --list shows the ports.")
    transport = Transport.for_port(port)

    unless transport.available?() do
      Mix.raise(
        "The serial library is not built into this copy. Start with ALNASL_UART=1 (see the README)."
      )
    end

    seconds = min(opts[:seconds] || 60, 120)

    out =
      opts[:out] ||
        "captures/loop-#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")}.jsonl"

    File.mkdir_p!(Path.dirname(out))
    {:ok, file} = File.open(out, [:write, :binary])

    case transport.open(port, baud: Alnasl.Dgt.Protocol.baud()) do
      {:ok, handle} ->
        io = %{
          transport: transport,
          handle: handle,
          file: file,
          t0: now(),
          deadline: now() + seconds * 1000
        }

        write(io, %{"k" => "cfg", "driver" => "dgt_bus", "port" => port, "flipped" => false})

        Process.flag(:trap_exit, true)
        Logger.configure(level: :warning)

        try do
          cond do
            opts[:probe] -> probe(io, opts[:probe])
            opts[:discover] -> discover(io, opts)
            opts[:watch] -> watch(io, opts, seconds)
            opts[:leave] -> leave(io)
            true -> Mix.raise("Give --discover, --watch, --leave or --probe.")
          end
        after
          transport.close(handle)
          File.close(file)
          Mix.shell().info("Port closed. Capture written: #{out}")
        end

      {:error, reason} ->
        File.close(file)
        File.rm(out)
        Mix.raise("Cannot open #{port}: #{inspect(reason)}")
    end
  end

  # --- the script ----------------------------------------------------------------

  defp probe(io, script) do
    for word <- String.split(script, " ", trim: true), do: step(io, word)

    for {size, trips} <- Enum.group_by(Process.get(:trips, []), &elem(&1, 0), &elem(&1, 1)) do
      sorted = Enum.sort(trips)

      say(
        io,
        "round trip",
        "#{size}-byte answers: n=#{length(sorted)} median #{Enum.at(sorted, div(length(sorted), 2))} ms, " <>
          "worst #{List.last(sorted)} ms"
      )
    end

    if missed = Process.get(:missed), do: say(io, "round trip", "#{missed} not answered")
    :ok
  end

  # One whole answer, known by its length.
  defp whole(io, until, acc) do
    case Bus.parse(acc) do
      {[_answer | _], _rest} ->
        {:ok, acc}

      {[], _rest} ->
        receive do
          message ->
            case io.transport.message(message) do
              {:data, bytes} ->
                write(io, %{"k" => "rx", "h" => Base.encode16(bytes, case: :lower)})
                say(io, "rx", hex(bytes))
                whole(io, until, acc <> bytes)

              {:error, reason} ->
                Mix.raise("The port failed: #{inspect(reason)}")

              nil ->
                whole(io, until, acc)
            end
        after
          max(until - now(), 0) -> :none
        end
    end
  end

  defp step(io, "x" <> rest = word) do
    case Integer.parse(rest) do
      {times, ":" <> inner} ->
        for _ <- 1..times, part <- String.split(inner, "+"), do: step(io, part)

      _other ->
        Mix.raise("Not a step: #{word}")
    end
  end

  defp step(io, "s:" <> hex) do
    bytes = Base.decode16!(hex, case: :mixed)

    for <<byte <- bytes>>, byte not in @single_allowed do
      Mix.raise("0x#{Integer.to_string(byte, 16)} is not a command this tool sends.")
    end

    tx(io, bytes)
  end

  defp step(io, "b:" <> rest) do
    [name, address] = String.split(rest, ":")
    tx(io, bus_frame(name, String.to_integer(address)))
  end

  defp step(io, "w:" <> ms), do: listen(io, String.to_integer(ms))

  defp step(io, "r:" <> ms) do
    started = now()
    {bytes, last} = settle(io, String.to_integer(ms), <<>>, nil)

    say(
      io,
      "answer",
      if(bytes == <<>>,
        do: "none",
        else: "#{byte_size(bytes)} bytes, last after #{last - started} ms"
      )
    )
  end

  defp step(io, "q:" <> ms) do
    started = now()

    case whole(io, started + String.to_integer(ms), <<>>) do
      {:ok, bytes} ->
        trip = now() - started
        Process.put(:trips, [{byte_size(bytes), trip} | Process.get(:trips, [])])
        say(io, "answer", "#{byte_size(bytes)} bytes, whole after #{trip} ms")

      :none ->
        Process.put(:missed, Process.get(:missed, 0) + 1)
        say(io, "answer", "none")
    end
  end

  defp step(io, "n:" <> text) do
    write(io, %{"k" => "note", "text" => text})
    say(io, "note", text)
  end

  defp step(_io, word), do: Mix.raise("Not a step: #{word}")

  defp bus_frame(name, address) do
    case Enum.find(Bus.commands(), fn {known, _id} -> to_string(known) == name end) do
      {known, _id} ->
        Bus.command(known, address)

      nil ->
        id = String.to_integer(name, 16)
        unless id in 0x81..0x8D, do: Mix.raise("#{name} is not a bus command this tool sends.")
        head = <<id, address >>> 7 &&& 0x7F, address &&& 0x7F>>
        head <> <<Bus.checksum(head)>>
    end
  end

  # --- discovery, as the box does it ----------------------------------------------

  defp discover(io, opts) do
    boards = find(io)
    if boards == [], do: say(io, "found", "nobody answered a ping on this line")

    for board <- boards do
      say(
        io,
        "board",
        "answers as #{Bus.number(board.address)}  firmware #{board.version || "?"}  " <>
          "serial #{Bus.serial(board.address, board.version || "") || "not said on a loop"}  " <>
          if(board.board, do: Position.placement(board.board), else: "no position")
      )
    end

    unless opts[:stay], do: leave(io)
    boards
  end

  defp find(io) do
    addresses =
      Loop.discover(io.transport, io.handle,
        trace: fn direction, bytes ->
          write(io, %{"k" => to_string(direction), "h" => Base.encode16(bytes, case: :lower)})
          say(io, to_string(direction), hex(bytes))
        end
      )

    for address <- addresses do
      version = ask(io, :version, address, &match?({^address, {:version, _}}, &1))
      board = ask(io, :board, address, &match?({^address, {:board, _}}, &1))

      %{
        address: address,
        version: with({_, {:version, v}} <- version, do: v),
        board: with({_, {:board, b}} <- board, do: b)
      }
    end
  end

  defp ask(io, command, address, wanted?) do
    tx(io, Bus.command(command, address))

    case whole(io, now() + Loop.reply_ms(), <<>>) do
      {:ok, bytes} -> bytes |> Bus.parse() |> elem(0) |> Enum.find(wanted?)
      :none -> nil
    end
  end

  # The real driver on the open line's port: the tool lets go of the port
  # and the bus opens it, as the site would.
  defp watch(io, opts, seconds) do
    addresses = Loop.discover(io.transport, io.handle)
    io.transport.close(io.handle)
    say(io, "found", Enum.map_join(addresses, ", ", &Bus.number/1))

    {:ok, _} = Registry.start_link(keys: :unique, name: Alnasl.BusRegistry)
    {:ok, _} = DynamicSupervisor.start_link(name: Alnasl.BusSupervisor, strategy: :one_for_one)
    me = self()

    drivers =
      for address <- addresses do
        {:ok, pid} =
          Alnasl.Driver.DgtBus.start_link(
            owner: me,
            id: address,
            port: opts[:port],
            address: address,
            stranger: fn _port, stranger -> send(me, {:stranger, stranger}) end
          )

        pid
      end

    Process.send_after(self(), :stop, max(seconds - 6, 1) * 1000)
    watching(io)
    bus = Alnasl.Driver.DgtBus.whereis(opts[:port])

    if bus do
      for s <- Alnasl.Driver.DgtBus.stats(bus) do
        say(
          io,
          "board",
          "#{Bus.number(s.address)}: #{s.answered} answered, #{s.missed} missed" <>
            if(s.connected?, do: "", else: " - NOT answering")
        )
      end

      t = Alnasl.Driver.DgtBus.timing(bus)

      say(
        io,
        "line",
        "#{t.polls} questions; question to whole answer: median #{t.trip_ms} ms, worst #{t.worst_trip_ms} ms; " <>
          "one board asked what changed every #{t.cycle_ms} ms (median), worst #{t.worst_cycle_ms} ms"
      )

      ref = Process.monitor(bus)
      for pid <- drivers, do: Agent.stop(pid)
      for address <- addresses, do: Alnasl.Driver.DgtBus.detach(bus, address)

      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      after
        2_000 -> :ok
      end
    end

    say(io, "left", "the bus told every board to leave bus mode and closed the port")
  catch
    :exit, _reason -> :ok
  end

  defp watching(io) do
    receive do
      :stop ->
        :ok

      {:stranger, address} ->
        say(io, "new board", "answers as #{Bus.number(address)}")
        write(io, %{"k" => "note", "text" => "new board #{address}"})
        watching(io)

      {:driver, address, {:raw, direction, bytes}} ->
        write(io, %{
          "k" => to_string(direction),
          "h" => Base.encode16(bytes, case: :lower),
          "a" => address
        })

        say(io, "#{direction} #{Bus.number(address)}", hex(bytes))
        watching(io)

      {:driver, address, {:position, board}} ->
        write(io, %{"k" => "pos", "b" => Position.to_text(board), "a" => address})
        say(io, "position", "#{Bus.number(address)}  #{Position.placement(board)}")
        watching(io)

      {:driver, address, {:clock, reading}} ->
        write(io, reading |> Alnasl.Recorder.clock_line() |> Map.put("a", address))

        say(
          io,
          "clock",
          "#{Bus.number(address)}  white #{Alnasl.Clock.format(reading.white_ms)}  black #{Alnasl.Clock.format(reading.black_ms)}  running: #{reading.running}"
        )

        watching(io)

      {:driver, address, status} when status in [:connected, :disconnected] ->
        write(io, %{"k" => "st", "v" => to_string(status), "a" => address})
        say(io, to_string(status), Bus.number(address))
        watching(io)

      {:driver, address, {:info, info}} ->
        say(io, "info", "#{Bus.number(address)}  #{inspect(info)}")
        watching(io)

      {:driver, address, {:poll, :missed}} ->
        say(io, "poll", "#{Bus.number(address)}  no answer")
        watching(io)

      _other ->
        watching(io)
    end
  end

  defp leave(io) do
    tx(io, Bus.command(:end_busmode, 0))
    listen(io, 300)
    say(io, "left", "every board on the line was told to leave bus mode")
  end

  # --- the line ------------------------------------------------------------------

  defp tx(io, bytes) do
    if now() > io.deadline, do: Mix.raise("Out of time.")
    write(io, %{"k" => "tx", "h" => Base.encode16(bytes, case: :lower)})
    say(io, "tx", hex(bytes))
    :ok = io.transport.write(io.handle, bytes)
  end

  defp listen(io, ms), do: settle(io, ms, <<>>, nil, ms)

  # Collects what arrives: for `window` ms, or (quiet < window) until the
  # line has been silent for `quiet` ms after the first byte.
  defp settle(io, window, acc, last, quiet \\ 60) do
    started = now()
    do_settle(io, started + window, acc, last, quiet)
  end

  defp do_settle(io, until, acc, last, quiet) do
    left = until - now()
    wait = if last, do: min(left, quiet - (now() - last)), else: left

    if wait <= 0 do
      {acc, last}
    else
      receive do
        message ->
          case io.transport.message(message) do
            {:data, bytes} ->
              write(io, %{"k" => "rx", "h" => Base.encode16(bytes, case: :lower)})
              say(io, "rx", hex(bytes))
              do_settle(io, until, acc <> bytes, now(), quiet)

            {:error, reason} ->
              Mix.raise("The port failed: #{inspect(reason)}")

            nil ->
              do_settle(io, until, acc, last, quiet)
          end
      after
        wait -> {acc, last}
      end
    end
  end

  defp hex(bytes),
    do: bytes |> Base.encode16(case: :lower) |> String.replace(~r/(..)(?=.)/, "\\1 ")

  defp now, do: System.monotonic_time(:millisecond)

  defp say(io, what, text) do
    ms = now() - io.t0

    Mix.shell().info(
      "#{String.pad_leading(Integer.to_string(ms), 7)}  #{String.pad_trailing(what, 10)} #{text}"
    )
  end

  defp write(io, fields) do
    IO.binwrite(io.file, [
      Jason.encode_to_iodata!(Map.put(fields, "t", System.os_time(:millisecond))),
      ?\n
    ])
  end
end
