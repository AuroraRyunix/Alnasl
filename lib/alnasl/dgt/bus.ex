defmodule Alnasl.Dgt.Bus do
  @moduledoc """
  The wire format of DGT's BUS mode: several boards on one serial loop, each
  with an address, each speaking only when asked.

  # NOT VERIFIED. EVERYTHING IN THIS MODULE IS `ASSUMED`.

  DGT's published description covers the single-board protocol in full and
  the bus mode only in outline. What is below is that outline as the author
  remembers it. It is isolated here so that the scheduler
  (`Alnasl.Driver.DgtBus`), the per-address board model and everything above
  them can be built and tested now, and so that finishing the bus driver is
  a matter of correcting THIS file against a capture of a real loop
  (docs/tomorrow.md, steps 2-4) - nothing else should need to change.

  ## What is believed

  - A board answers on the bus only after it has been switched to bus mode;
    in bus mode it never sends anything unasked.
  - A command is four bytes: the command id (bit 7 set), the address in two
    7-bit bytes (high first), and a checksum.
  - An answer is a message as in the single-board protocol - id with bit 7
    set, 2-byte size - followed by the address (two 7-bit bytes), the data
    and a checksum; the size counts all of it.
  - The checksum is the sum of all preceding bytes of the frame, low 7 bits.
  - Address 0 is the broadcast address.

  ## TODO, from the first capture of a real loop

  - [ ] the command ids below, each one;
  - [ ] the message ids of the answers;
  - [ ] whether the size includes the address and the checksum;
  - [ ] the checksum rule;
  - [ ] how a board gets its address (believed: it is derived from the
        serial number) and how LiveChess discovers who is on the loop
        (believed: a ping to address 0, answered by each board after a
        delay derived from its address);
  - [ ] whether "send changes" returns field updates since the last poll
        and must be acknowledged, or the box should ask for a full dump each
        round (what the scheduler does today: it is slower and cannot be
        wrong);
  - [ ] the clock: whether it is a separate poll.
  """

  import Bitwise

  alias Alnasl.Dgt.Protocol

  # ASSUMED - command ids (computer to a board on the bus).
  @bus_send_clk 0x81
  @bus_send_brd 0x82
  @bus_send_changes 0x83
  @bus_repeat_changes 0x84
  @bus_ping 0x87
  @bus_end_busmode 0x88
  @bus_reset 0x89
  @bus_send_version 0x8B

  # ASSUMED - the single-board command that switches a board to bus mode.
  @to_busmode 0x4A

  # ASSUMED - message ids of the answers, without bit 7.
  @msg_bus_brd_dump 0x03
  @msg_bus_bwtime 0x04
  @msg_bus_update 0x05
  @msg_bus_ping 0x07
  @msg_bus_version 0x09

  @commands %{
    clock: @bus_send_clk,
    board: @bus_send_brd,
    changes: @bus_send_changes,
    repeat_changes: @bus_repeat_changes,
    ping: @bus_ping,
    end_busmode: @bus_end_busmode,
    reset: @bus_reset,
    version: @bus_send_version
  }

  @doc "Is anything here verified against hardware? No. The site says so beside every bus board."
  def verified?, do: false

  @doc "The byte that puts a single board into bus mode. ASSUMED."
  def to_busmode, do: <<@to_busmode>>

  @doc "A command for the board at `address`. ASSUMED framing."
  def command(name, address) when address >= 0 and address < 16_384 do
    head = <<Map.fetch!(@commands, name), address >>> 7 &&& 0x7F, address &&& 0x7F>>
    head <> <<checksum(head)>>
  end

  @doc "The checksum of a frame's bytes. ASSUMED: their sum, low 7 bits."
  def checksum(bytes), do: bytes |> :binary.bin_to_list() |> Enum.sum() |> band(0x7F)

  @doc """
  Takes bytes from the loop and returns the complete answers in them and the
  rest: `{[{address, message} | {:bad_checksum, address}], rest}` with
  `message` as `Alnasl.Dgt.Protocol` gives it. ASSUMED framing.
  """
  def parse(buffer), do: parse(buffer, [])

  defp parse(<<id, hi, lo, _::binary>> = buffer, acc) when id >= 0x80 and hi < 0x80 and lo < 0x80 do
    size = (hi <<< 7) ||| lo

    cond do
      size < 6 ->
        <<_skip, rest::binary>> = buffer
        parse(rest, acc)

      byte_size(buffer) >= size ->
        <<frame::binary-size(^size), rest::binary>> = buffer
        body = binary_part(frame, 0, size - 1)
        <<_header::binary-size(3), a_hi, a_lo, data::binary>> = body
        address = (a_hi <<< 7) ||| a_lo

        answer =
          if :binary.last(frame) == checksum(body),
            do: {address, decode(id &&& 0x7F, data)},
            else: {:bad_checksum, address}

        parse(rest, [answer | acc])

      true ->
        {Enum.reverse(acc), buffer}
    end
  end

  defp parse(<<id, _::binary>> = buffer, acc) when id >= 0x80 and byte_size(buffer) < 3,
    do: {Enum.reverse(acc), buffer}

  defp parse(<<_garbage, rest::binary>>, acc), do: parse(rest, acc)
  defp parse(<<>>, acc), do: {Enum.reverse(acc), <<>>}

  # The data of an answer is believed to be laid out as in the single-board
  # message of the same kind, so the single-board decoder reads it.
  defp decode(@msg_bus_brd_dump, data), do: single(0x06, data)
  defp decode(@msg_bus_bwtime, data), do: single(0x0D, data)
  defp decode(@msg_bus_update, data), do: {:changes, data}
  defp decode(@msg_bus_ping, data), do: {:ping, data}
  defp decode(@msg_bus_version, data), do: single(0x13, data)
  defp decode(id, data), do: {:unknown, id, data}

  defp single(id, data) do
    case Protocol.parse(Protocol.frame(id, data)) do
      {[message], <<>>} -> message
      _other -> {:unknown, id, data}
    end
  end

  @doc "An answer as a board would send it, for the emulator and the tests. ASSUMED framing."
  def answer(kind, address, data) do
    id =
      Map.fetch!(
        %{board: @msg_bus_brd_dump, clock: @msg_bus_bwtime, changes: @msg_bus_update, ping: @msg_bus_ping, version: @msg_bus_version},
        kind
      )

    size = byte_size(data) + 6
    body = <<id ||| 0x80, size >>> 7 &&& 0x7F, size &&& 0x7F, address >>> 7 &&& 0x7F, address &&& 0x7F, data::binary>>
    body <> <<checksum(body)>>
  end

  @doc "Which command a 4-byte frame from the computer is, and for whom: `{name, address}` or `:error`."
  def decode_command(<<id, hi, lo, sum>> = frame) when hi < 0x80 and lo < 0x80 do
    name = Enum.find_value(@commands, fn {name, code} -> code == id && name end)

    if name && sum == checksum(binary_part(frame, 0, 3)),
      do: {name, (hi <<< 7) ||| lo},
      else: :error
  end

  def decode_command(_other), do: :error
end
