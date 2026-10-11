defmodule Alnasl.Transport do
  @moduledoc """
  A serial line, as far as a driver needs one: open it, write to it, be sent
  what arrives.

  Behind a behaviour so that the DGT drivers do not care whether the bytes
  come from a real port (`Alnasl.Transport.Uart`, the `circuits_uart`
  library) or from a stand-in (`Alnasl.Transport.Fake`, an emulated board for
  the tests and for working without hardware) - and so that the application
  compiles and runs on a machine where the serial library was not built.

  What arrives comes as ordinary messages to the process that opened the
  line; `message/1` turns one into `{:data, binary}`, `{:error, reason}` or
  `nil` (not ours).
  """

  @type handle :: term()

  @callback available?() :: boolean()
  @callback enumerate() :: [%{port: String.t(), description: String.t()}]
  @callback open(port :: String.t(), opts :: keyword()) :: {:ok, handle()} | {:error, term()}
  @callback write(handle(), iodata()) :: :ok | {:error, term()}
  @callback close(handle()) :: :ok
  @callback message(term()) :: {:data, binary()} | {:error, term()} | nil

  @doc "The transport a driver uses when it is not told which."
  def default, do: Application.get_env(:alnasl, :transport, Alnasl.Transport.Uart)

  @doc "Every serial port the machine offers, real ones first, then stand-ins."
  def ports do
    real = if Alnasl.Transport.Uart.available?(), do: Alnasl.Transport.Uart.enumerate(), else: []
    real ++ Alnasl.Transport.Fake.enumerate()
  end

  @doc "Which transport a port name belongs to."
  def for_port("FAKE" <> _rest), do: Alnasl.Transport.Fake
  def for_port(_real), do: default()
end
