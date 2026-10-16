defmodule Alnasl.UartPortsTest do
  @moduledoc """
  A Mac names every serial device twice. The arbiter is offered the one
  that works.
  """

  use ExUnit.Case, async: true

  alias Arkab.Transport.Uart

  defp ports(names), do: Enum.map(names, &%{port: &1, description: ""})

  test "a Mac's dial-in twin is dropped when the call-out port is there" do
    listed =
      ports(~w(/dev/cu.usbserial-A10KFS3Z /dev/tty.usbserial-A10KFS3Z
               /dev/cu.Bluetooth-Incoming-Port /dev/tty.Bluetooth-Incoming-Port))

    assert Enum.map(Uart.one_per_device(listed), & &1.port) ==
             ~w(/dev/cu.usbserial-A10KFS3Z /dev/cu.Bluetooth-Incoming-Port)
  end

  test "a tty. port without a cu. twin stays: dropping it would hide a device" do
    assert Uart.one_per_device(ports(~w(/dev/tty.usbmodem14101))) ==
             ports(~w(/dev/tty.usbmodem14101))
  end

  test "Linux and Windows names pass untouched" do
    names = ~w(COM3 COM7 /dev/ttyUSB0 /dev/ttyACM0 /dev/ttyS0)
    assert Uart.one_per_device(ports(names)) == ports(names)
  end
end
