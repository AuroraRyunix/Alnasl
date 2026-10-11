defmodule Alnasl.Transport.Uart do
  @moduledoc """
  A real serial port, through `circuits_uart`.

  The library is C code and is not always there: it is left out of the build
  on Windows unless asked for (see `mix.exs` and the README). So it is never
  named at compile time - the module is looked up when a port is opened, and
  `available?/0` says whether there is anything to open one with.

  Port names: `COM3` on Windows, `/dev/ttyUSB0` or `/dev/ttyACM0` on Linux
  (a DGT USB board is a serial port to the system; the RS232 models hang on
  a USB adapter).
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
      |> Enum.sort_by(& &1.port)
    else
      []
    end
  rescue
    _error -> []
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
