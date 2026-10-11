defmodule Mix.Tasks.Alnasl.Dgt do
  @shortdoc "Talks to one DGT board on a serial port, prints every byte and message, and writes a capture"

  @moduledoc """
  The serial driver's debug mode: for the first meeting with a real board.

      mix alnasl.dgt --list
      mix alnasl.dgt --port COM3
      mix alnasl.dgt --port /dev/ttyUSB0 --out captures/board-a.jsonl --seconds 120
      mix alnasl.dgt --port COM3 --bus 1,2,3

  It starts nothing but the driver - no site, no database, no sending. For
  `--seconds` (60; 0 = until Ctrl+C) it prints

  - every byte sent and received, in hex (`tx` / `rx`);
  - what the driver made of them: `connected`, `info` (serial number,
    firmware), `position` (as a FEN piece placement) on every change,
    `clock`, `poll`;

  and writes all of it to `--out` (default `captures/dgt-<time>.jsonl`) in
  the capture format (`Alnasl.Recorder`), raw bytes included. That file can
  be replayed through the tracker with `mix alnasl.replay <file>`, loaded on
  the Recordings page, or kept as a test fixture.

  Type a line and press Enter to put a note in the capture ("lifted the
  knight on g1"); the note is timestamped like everything else.

  `--bus 1,2,3` polls those addresses on a loop instead (the UNVERIFIED bus
  driver): the output then shows what the loop answers to what is ASSUMED to
  be a poll, which is exactly what is needed to correct `Alnasl.Dgt.Bus`.

  Needs the serial library: on Windows start with `ALNASL_UART=1` from a
  checkout whose path has no space in it (see the README).
  """

  use Mix.Task

  alias Alnasl.{Position, Transport}

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [
          port: :string,
          out: :string,
          seconds: :integer,
          list: :boolean,
          bus: :string,
          notes: :boolean
        ]
      )

    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:jason)
    if Transport.Uart.available?(), do: Application.ensure_all_started(:circuits_uart)

    cond do
      opts[:list] -> list()
      opts[:port] -> listen(opts)
      true -> Mix.raise("Give --port, or --list to see the ports. See mix help alnasl.dgt.")
    end
  end

  defp list do
    if Transport.Uart.available?() do
      case Transport.Uart.enumerate() do
        [] -> Mix.shell().info("No serial ports found.")
        ports -> for p <- ports, do: Mix.shell().info("#{p.port}  #{p.description}")
      end
    else
      Mix.shell().error(
        "The serial library is not built into this copy (ALNASL_UART=1, see the README)."
      )
    end
  end

  defp listen(opts) do
    port = opts[:port]
    transport = Transport.for_port(port)

    unless transport.available?() do
      Mix.raise(
        "The serial library is not built into this copy. Start with ALNASL_UART=1 (see the README)."
      )
    end

    out =
      opts[:out] || "captures/dgt-#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")}.jsonl"

    File.mkdir_p!(Path.dirname(out))
    {:ok, file} = File.open(out, [:append, :binary])

    write(file, %{
      "k" => "cfg",
      "driver" => if(opts[:bus], do: "dgt_bus", else: "dgt_serial"),
      "port" => port,
      "flipped" => false
    })

    Process.flag(:trap_exit, true)
    Logger.configure(level: :warning)

    if opts[:bus] do
      {:ok, _} = Registry.start_link(keys: :unique, name: Alnasl.BusRegistry)
      {:ok, _} = DynamicSupervisor.start_link(name: Alnasl.BusSupervisor, strategy: :one_for_one)

      for text <- String.split(opts[:bus], ",", trim: true) do
        address = String.to_integer(String.trim(text))

        {:ok, _} =
          Alnasl.Driver.DgtBus.start_link(
            owner: self(),
            id: address,
            port: port,
            address: address
          )
      end
    else
      {:ok, _} = Alnasl.Driver.DgtSerial.start_link(owner: self(), id: 0, port: port)
    end

    seconds = if opts[:seconds] == nil, do: 60, else: opts[:seconds]
    if seconds > 0, do: Process.send_after(self(), :stop, seconds * 1000)
    me = self()
    # `--no-notes` for a terminal nobody is typing in (a script, an agent):
    # reading the keyboard there fails and takes the capture with it.
    if opts[:notes] != false, do: spawn_link(fn -> notes(me) end)

    Mix.shell().info(
      "Listening on #{port}#{if seconds > 0, do: " for #{seconds} s", else: ""}. Writing #{out}. Type a note + Enter to mark the capture."
    )

    loop(file, System.monotonic_time(:millisecond))
    File.close(file)
    Mix.shell().info("Capture written: #{out}")
  end

  defp notes(owner) do
    case IO.gets("") do
      line when is_binary(line) ->
        if String.trim(line) != "", do: send(owner, {:note, String.trim(line)})
        notes(owner)

      _eof ->
        :ok
    end
  end

  defp loop(file, t0) do
    receive do
      :stop ->
        :ok

      {:note, text} ->
        write(file, %{"k" => "note", "text" => text})
        say(t0, "note", text)
        loop(file, t0)

      {:driver, id, event} ->
        show(file, t0, id, event)
        loop(file, t0)

      {:EXIT, _pid, reason} when reason not in [:normal, :shutdown] ->
        Mix.shell().error("the driver stopped: #{inspect(reason)}")

      _other ->
        loop(file, t0)
    end
  end

  defp show(file, t0, id, {:raw, direction, bytes}) do
    write(file, %{
      "k" => to_string(direction),
      "h" => Base.encode16(bytes, case: :lower),
      "a" => id
    })

    say(
      t0,
      "#{direction} #{tag(id)}",
      bytes |> Base.encode16(case: :lower) |> String.replace(~r/(..)(?=.)/, "\\1 ")
    )
  end

  defp show(file, t0, id, {:position, board}) do
    write(file, %{"k" => "pos", "b" => Position.to_text(board), "a" => id})
    say(t0, "position #{tag(id)}", Position.placement(board))
  end

  defp show(file, t0, id, {:clock, reading}) do
    write(file, %{
      "k" => "clk",
      "w" => reading.white_ms,
      "b" => reading.black_ms,
      "r" => to_string(reading.running),
      "a" => id
    })

    say(
      t0,
      "clock #{tag(id)}",
      "white #{Alnasl.Clock.format(reading.white_ms)}  black #{Alnasl.Clock.format(reading.black_ms)}  running: #{reading.running}"
    )
  end

  defp show(file, t0, id, status) when status in [:connected, :disconnected] do
    write(file, %{"k" => "st", "v" => to_string(status), "a" => id})
    say(t0, "#{status} #{tag(id)}", "")
  end

  defp show(_file, t0, id, {:info, info}), do: say(t0, "info #{tag(id)}", inspect(info))
  defp show(_file, t0, id, {:poll, :missed}), do: say(t0, "poll #{tag(id)}", "no answer")
  defp show(_file, _t0, _id, _other), do: :ok

  defp tag(0), do: ""
  defp tag(address), do: "[#{address}]"

  defp say(t0, what, text) do
    ms = System.monotonic_time(:millisecond) - t0

    Mix.shell().info(
      "#{String.pad_leading(Float.to_string(ms / 1000), 9)}  #{String.pad_trailing(what, 14)} #{text}"
    )
  end

  defp write(file, fields) do
    IO.binwrite(file, [
      Jason.encode_to_iodata!(Map.put(fields, "t", System.os_time(:millisecond))),
      ?\n
    ])
  end
end
