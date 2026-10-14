defmodule Alnasl.Transport.Uart do
  @moduledoc """
  A real serial port, through `circuits_uart`.

  The library is C code and is not always there: it is left out of the build
  on Windows unless asked for (see `mix.exs` and the README). So it is never
  named at compile time - the module is looked up when a port is opened, and
  `available?/0` says whether there is anything to open one with.

  Port names: `COM3` on Windows, `/dev/ttyUSB0` or `/dev/ttyACM0` on Linux,
  `/dev/cu.usbserial-...` or `/dev/cu.usbmodem...` on a Mac (a DGT USB
  board is a serial port to the system; the RS232 models hang on a USB
  adapter).

  A Mac lists every serial device twice, as `/dev/tty.X` and `/dev/cu.X`.
  The `tty.` one is for dial-in: opening it waits for a modem's carrier
  signal, which a chess board never sends. Only the `cu.` one is offered
  (`one_per_device/1`), so nobody has to know that.
  """

  @behaviour Alnasl.Transport

  defp uart, do: Module.concat(["Circuits", "UART"])

  @impl true
  def available?, do: Code.ensure_loaded?(uart())

  @impl true
  def enumerate do
    if available?() do
      uart()
      |> apply(:enumerate, [])
      |> Enum.map(fn {port, info} ->
        %{port: port, description: info[:description] || info[:manufacturer] || ""}
      end)
      |> one_per_device()
      |> Enum.sort_by(& &1.port)
    else
      []
    end
  rescue
    _error -> []
  end

  @doc """
  Drops a Mac's `/dev/tty.X` when `/dev/cu.X` is in the list too (see the
  moduledoc). Every other name passes untouched, so this is a no-op off a
  Mac.
  """
  def one_per_device(ports) do
    names = MapSet.new(ports, & &1.port)

    Enum.reject(ports, fn %{port: port} ->
      case port do
        "/dev/tty." <> device -> MapSet.member?(names, "/dev/cu." <> device)
        _other -> false
      end
    end)
  end

  @impl true
  def open(port, opts) do
    if available?() do
      settings = [
        speed: Keyword.get(opts, :baud, 9600),
        data_bits: 8,
        parity: :none,
        stop_bits: 1,
        flow_control: :none,
        active: true
      ]

      with {:ok, pid} <- apply(uart(), :start_link, []),
           :ok <- apply(uart(), :open, [pid, port, settings]) do
        {:ok, pid}
      else
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    else
      {:error, :no_serial_library}
    end
  end

  @impl true
  def write(pid, data), do: apply(uart(), :write, [pid, IO.iodata_to_binary(data)])

  @impl true
  def close(pid) do
    apply(uart(), :close, [pid])
    apply(uart(), :stop, [pid])
    :ok
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def message({:circuits_uart, _port, {:error, reason}}), do: {:error, reason}
  def message({:circuits_uart, _port, data}) when is_binary(data), do: {:data, data}
  def message(_other), do: nil
end
