defmodule Alnasl.Driver do
  @moduledoc """
  A source of boards.

  A driver is a process. It is started with `owner: pid` and `id: term` and
  from then on sends the owner `{:driver, id, event}`:

  | event | meaning |
  |---|---|
  | `{:position, board}` | the WHOLE board as it reads now: a 64-tuple, a8 first (`Alnasl.Position`). Sent on every change, and again whenever the driver re-reads the board |
  | `{:clock, %{white_ms, black_ms, running}}` | a clock reading; `running` is `:white`, `:black` or `:none`. Never sent by a board without a clock |
  | `:connected` / `:disconnected` | the board answers / has stopped answering |
  | `{:info, map}` | what the board says about itself: `:serial`, `:firmware`, `:battery` |
  | `{:poll, :ok \\| :missed}` | one question to the board was answered / was not - the signal quality. `{:poll, :ok, n}` (from a bridge): `n` answers in one event |
  | `{:raw, :rx \\| :tx, binary}` | the bytes on the wire, for the capture file |

  A driver that plays recorded or simulated time wraps each event as
  `{:at, t_ms, speed, next_t_ms, event}`; see `Arkab.Driver.Player`.

  Full positions, not moves and not changes: what a move is, is the
  tracker's business, and a driver that reports the whole board cannot
  drift from it.

  The drivers: `Alnasl.Driver.Simulator` (PGN games played by an invisible
  hand, with faults), `Arkab.Driver.Replay` (a capture file played back),
  `Arkab.Driver.DgtSerial` (one DGT board on a serial port) and
  `Arkab.Driver.DgtBus` (a loop of DGT boards) - those three live in
  Arkab, where a bridge runs the same code - and `Alnasl.Driver.Remote` (a
  board read by an Arkab bridge somewhere else, arriving over its link).
  """

  @callback start_link(keyword()) :: GenServer.on_start()

  @doc "The module for a board's `driver` field."
  def module("simulator"), do: Alnasl.Driver.Simulator
  def module("replay"), do: Arkab.Driver.Replay
  def module("dgt_serial"), do: Arkab.Driver.DgtSerial
  def module("dgt_bus"), do: Arkab.Driver.DgtBus
  def module("remote"), do: Alnasl.Driver.Remote

  @doc "Sends an event to a driver's owner."
  defdelegate emit(owner, id, event), to: Arkab.Driver
end
