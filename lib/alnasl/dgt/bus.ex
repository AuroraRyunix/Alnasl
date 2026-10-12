defmodule Alnasl.Dgt.Bus do
  @moduledoc """
  The wire format of DGT's BUS mode: several boards on one serial loop, each
  with a number of its own, each speaking only when asked.

  Written from the outline in DGT's published description and then corrected
  against a real loop: two boards on one line on 2026-10-12, serial 06310
  (firmware 1.9) and a newer board that answers as 12799 (firmware 4.0).
  `docs/real-loop-2026-10-12.md` is that session byte by byte, and its
  recordings are test fixtures (`test/fixtures/captures/real-loop-*.jsonl`).
  Each group below says how sure it is, in the words of
  `Alnasl.Dgt.Protocol`: `CONFIRMED` (seen on that loop), `PUBLISHED`,
  `ASSUMED`.

  ## The line

  CONFIRMED: the same 9600 baud 8N1 as a single board.

  ## A command (computer to one board)

  CONFIRMED: four bytes.

      byte 0   command id, bit 7 SET
      byte 1   address, high 7 bits
      byte 2   address, low 7 bits
      byte 3   checksum: the sum of bytes 0-2, low 7 bits

  Address 0 is everybody: confirmed for the ping and for "end bus mode".

  Commands must not be sent back to back. Three clock requests written at
  once got one answer; a command written in the same breath as the
  bus-mode byte was lost three times in ten, and never after a 30 ms pause.
  One question, one answer, then the next.

  ## An answer (one board to the computer)

  CONFIRMED:

      byte 0   message id, bit 7 SET
      byte 1   size, high 7 bits
      byte 2   size, low 7 bits     - the size counts every byte of the
                                      answer, header and checksum included
      byte 3   address, high 7 bits - the board that is speaking
      byte 4   address, low 7 bits
      ...      size - 6 bytes of data
      last     checksum: the sum of every byte before it, low 7 bits

  Inside the data a byte may have bit 7 clear only: confirmed for every
  answer seen, which is what lets a reader that lost its place find the
  next answer.

  ## The address

  CONFIRMED on board 06310: its address is 6310, its serial number as a
  number. NOT so for the newer board: it answers as 12799 and what could be
  read of its serial number (through a collision) ends in 730. So an
  address is a number the board has, stable and its own; for a board with
  firmware 1.x it is taken to be the serial number (`serial/2`), for any
  other it is not.

  ## Bus mode

  CONFIRMED: both boards answer bus commands whether or not they were told
  to go to bus mode (0x4A), and both go on answering single-board commands
  in bus mode - at the same time, which is the scrambled reading a loop
  gives when it is treated as one board. What the mode changes is seen on
  the old board only: after a single-board command, or after "end bus mode",
  the first bus command is swallowed (it switches the board over, as the
  published text says) and the next is answered. The new board answers the
  first. So: 0x4A before talking, a pause, and a question that goes
  unanswered is asked again.

  "End bus mode" (0x88) is answered by nobody, to address 0 or to one board.

  ## What was not seen, and is still ASSUMED

  - a board reporting a change as it happens: nobody was at the boards.
    What "send changes" returns was seen as history only (see `changes/1`);
  - "repeat changes" after a non-empty answer (after an empty one it
    answers empty);
  - a clock: neither board had one. The clock answer has the size and the
    "no clock" bit of the single-board message; that the times lie the
    same way is assumed;
  - two boards with the same address;
  - 0x85 (set a start-of-game mark) and 0x89 (reset) were never sent, on
    purpose: the one writes to the board's memory, the other is not needed.
    0x8D ("send all") was answered by neither board.
  """

  import Bitwise

  alias Alnasl.Dgt.Protocol

  # --- command ids -------------------------------------------------------------
  #
  # CONFIRMED by what the boards answered: 0x81, 0x82, 0x83, 0x84, 0x86,
  # 0x87, 0x88, 0x8A, 0x8B. The rest are PUBLISHED and not in this map,
  # because nothing here sends them.

  @commands %{
    # One clock message.
    clock: 0x81,
    # The whole board.
    board: 0x82,
    # What happened since the last time this was asked.
    changes: 0x83,
    # The last answer to "changes" once more.
    repeat_changes: 0x84,
    # The board's whole memory since the last start-of-game mark.
    from_start: 0x86,
    # "Are you there?" To address 0: everybody, each after a random wait.
    ping: 0x87,
    # Back to single-board mode. No answer.
    end_busmode: 0x88,
    # Answer this (with a ping message), then sit out the next ping to
    # address 0.
    ignore_next_ping: 0x8A,
    # The firmware version.
    version: 0x8B
  }

  # Every byte that can begin an answer.
  @starts for byte <- 0x80..0xFF, do: <<byte>>

  # CONFIRMED: the single-board command that switches a board to bus mode.
  @to_busmode 0x4A

  # --- message ids (without bit 7) ---------------------------------------------
  #
  # CONFIRMED: all six.

  @msg_bus_brd_dump 0x03
  @msg_bus_bwtime 0x04
  @msg_bus_update 0x05
  @msg_bus_from_start 0x06
  @msg_bus_ping 0x07
  @msg_bus_version 0x09

  @answers %{
    board: @msg_bus_brd_dump,
    clock: @msg_bus_bwtime,
    changes: @msg_bus_update,
    from_start: @msg_bus_from_start,
    ping: @msg_bus_ping,
    version: @msg_bus_version
  }

  # --- the board's memory ("EEPROM format") ------------------------------------
  #
  # What "changes" and "from start" carry. CONFIRMED on both boards, by
  # reading their memories against their board dumps: the squares named by
  # the last events are the squares the dump shows.
  #
  #   0x40-0x5F  a square changed: the low nibble is the piece (0 = empty),
  #              the NEXT byte the square, a8 = 0 as in a dump. Firmware 1.9
  #              sets bit 4 on some of them (0x5x); what it means is not
  #              known and the piece is the same either way.
  #   0x60-0x69  a clock time, the low nibble the hours, then minutes and
  #              seconds in BCD: the side the single-board clock message
  #              has in bytes 0-2, Black's
  #   0x70-0x79  the same for the other side, White's. (Board 06310: the
  #              last 0x7x in its memory is 1:32:12, and bytes 3-5 of its
  #              clock answer are 01 32 12.)
  #   0x6A       the board was switched on
  #   0x6B-0x6F, 0x7A-0x7F  one-byte marks (0x6F a starting position, 0x7B
  #              a start-of-game mark, 0x7C the board restarted itself)
  #   below 0x40, standing where an event would begin: firmware 4.0 writes
  #              one to four such bytes between events. Time stamps,
  #              presumably; skipped.

  @ee_powerup 0x6A
  @ee_beginpos 0x6F
  @ee_start_tag 0x7B
  @ee_watchdog 0x7C

  @doc """
  Has this been checked against hardware? Yes: `docs/real-loop-2026-10-12.md`.
  The site still says what was not (`unverified/0`).
  """
  def verified?, do: true

  @doc "What no real loop has shown yet, as atoms the site turns into words."
  def unverified, do: [:live_changes, :clock, :more_than_two]

  @doc "The byte that puts a single board into bus mode."
  def to_busmode, do: <<@to_busmode>>

  @doc "The commands this module can write: `%{name => id}`."
  def commands, do: @commands

  @doc "A command for the board at `address` (0: every board)."
  def command(name, address) when address >= 0 and address < 16_384 do
    head = <<Map.fetch!(@commands, name), address >>> 7 &&& 0x7F, address &&& 0x7F>>
    head <> <<checksum(head)>>
  end

  @doc "The checksum of a frame's bytes: their sum, low 7 bits."
  def checksum(bytes), do: bytes |> :binary.bin_to_list() |> Enum.sum() |> band(0x7F)

  @doc """
  The address as the five digits printed under a board. It IS the serial
  number of a board with firmware 1.x; see the module text for the others.
  """
  def number(address), do: address |> Integer.to_string() |> String.pad_leading(5, "0")

  @doc """
  The serial number of the board at `address`, when the address says it:
  firmware 1.x. `nil` for any other firmware - the board has to be seen on
  a port of its own once for the box to know its serial number.
  """
  def serial(address, "1." <> _minor), do: number(address)
  def serial(_address, _firmware), do: nil

  @doc """
  Takes bytes from the loop and returns the complete answers in them and the
  rest: `{[{address, message} | {:bad_checksum, address | nil}], rest}` - a
  damaged answer with the address it seemed to carry.

  `message` is `{:board, squares}`, `{:clock, map}` or `{:clock_ack, data}`
  and `{:version, text}` as `Alnasl.Dgt.Protocol` gives them, `{:ping, <<>>}`,
  `{:changes, data}` or `{:from_start, data}` (see `changes/1`), or
  `{:unknown, id, data}`.
  """
  def parse(buffer), do: parse(buffer, [])

  defp parse(<<id, hi, lo, _::binary>> = buffer, acc)
       when id >= 0x80 and hi < 0x80 and lo < 0x80 do
    size = hi <<< 7 ||| lo

    cond do
      size < 6 ->
        <<_skip, rest::binary>> = buffer
        parse(rest, acc)

      # Only the first byte of an answer has bit 7 set. One inside it is
      # the beginning of another answer, on top of this one: a board that
      # began to speak while this one was speaking (the real collision of
      # 2026-10-12 is 87 00 06 31 A6 87 00 06 63 7F 6F). This one is lost;
      # the other is read from where it begins.
      (cut = second_start(buffer, min(size, byte_size(buffer)))) != nil ->
        <<damaged::binary-size(^cut), rest::binary>> = buffer
        parse(rest, [{:bad_checksum, address_in(damaged)} | acc])

      byte_size(buffer) >= size ->
        <<frame::binary-size(^size), rest::binary>> = buffer
        body = binary_part(frame, 0, size - 1)

        if :binary.last(frame) == checksum(body) do
          <<_header::binary-size(3), _address::binary-size(2), data::binary>> = body
          parse(rest, [{address_in(frame), decode(id &&& 0x7F, data)} | acc])
        else
          # The size may be part of the damage: the next answer is looked
          # for inside these bytes, not after them.
          <<_first, after_first::binary>> = buffer
          parse(after_first, [{:bad_checksum, address_in(frame)} | acc])
        end

      true ->
        {Enum.reverse(acc), buffer}
    end
  end

  defp parse(<<id, _::binary>> = buffer, acc) when id >= 0x80 and byte_size(buffer) < 3,
    do: {Enum.reverse(acc), buffer}

  defp parse(<<_garbage, rest::binary>>, acc), do: parse(rest, acc)
  defp parse(<<>>, acc), do: {Enum.reverse(acc), <<>>}

  defp second_start(buffer, within) do
    case :binary.match(buffer, @starts, scope: {1, within - 1}) do
      {index, 1} -> index
      :nomatch -> nil
    end
  end

  defp address_in(<<_header::binary-size(3), hi, lo, _::binary>>),
    do: (hi &&& 0x7F) <<< 7 ||| (lo &&& 0x7F)

  defp address_in(_short), do: nil

  # The data of a board dump, a clock message and a version is laid out as
  # in the single-board message of the same kind (CONFIRMED for the dump and
  # the version; the clock: see the module text), so that decoder reads it.
  defp decode(@msg_bus_brd_dump, data), do: single(0x06, data)
  defp decode(@msg_bus_bwtime, data), do: single(0x0D, data)
  defp decode(@msg_bus_update, data), do: {:changes, data}
  defp decode(@msg_bus_from_start, data), do: {:from_start, data}
  defp decode(@msg_bus_ping, data), do: {:ping, data}
  defp decode(@msg_bus_version, data), do: single(0x13, data)
  defp decode(id, data), do: {:unknown, id, data}

  defp single(id, data) do
    case Protocol.parse(Protocol.frame(id, data)) do
      {[message], <<>>} -> message
      _other -> {:unknown, id, data}
    end
  end

  @doc """
  The events in the data of a "changes" (or "from start") answer, in order:

  - `{:field, square, piece}` - `piece` as in a dump, `nil` for empty;
  - `{:clock, :white | :black, ms}` - a time the board wrote down, which it
    does when the clock's lever goes over;
  - `:power_up`, `:start_position`, `:start_mark`, `:restarted`;
  - nothing for the bytes that are time stamps or marks nobody needs.

  An event cut off by the end of the data is dropped.
  """
  def changes(data), do: changes(data, [])

  defp changes(<<code, square, rest::binary>>, acc) when code in 0x40..0x5F and square < 64,
    do: changes(rest, [{:field, square, Protocol.piece(code &&& 0x0F)} | acc])

  defp changes(<<code, minutes, seconds, rest::binary>>, acc)
       when code in 0x60..0x69 or code in 0x70..0x79 do
    side = if code >= 0x70, do: :white, else: :black
    ms = (((code &&& 0x0F) * 60 + bcd(minutes)) * 60 + bcd(seconds)) * 1000
    changes(rest, [{:clock, side, ms} | acc])
  end

  defp changes(<<@ee_powerup, rest::binary>>, acc), do: changes(rest, [:power_up | acc])
  defp changes(<<@ee_beginpos, rest::binary>>, acc), do: changes(rest, [:start_position | acc])
  defp changes(<<@ee_start_tag, rest::binary>>, acc), do: changes(rest, [:start_mark | acc])
  defp changes(<<@ee_watchdog, rest::binary>>, acc), do: changes(rest, [:restarted | acc])
  defp changes(<<_other, rest::binary>>, acc), do: changes(rest, acc)
  defp changes(<<>>, acc), do: Enum.reverse(acc)

  defp bcd(byte), do: (byte >>> 4 &&& 0x07) * 10 + (byte &&& 0x0F)

  # --- writing answers (the emulator, and the tests) ---------------------------

  @doc "An answer as a board sends it: `kind` is `:board | :clock | :changes | :from_start | :ping | :version`."
  def answer(kind, address, data) do
    size = byte_size(data) + 6

    body =
      <<Map.fetch!(@answers, kind) ||| 0x80, size >>> 7 &&& 0x7F, size &&& 0x7F,
        address >>> 7 &&& 0x7F, address &&& 0x7F, data::binary>>

    body <> <<checksum(body)>>
  end

  @doc "A square's change as the board writes it in its memory."
  def field_event(square, piece), do: <<0x40 ||| Protocol.code(piece), square>>

  @doc "A clock time as the board writes it in its memory."
  def clock_event(side, ms) do
    total = div(ms, 1000)
    hours = min(div(total, 3600), 9)
    base = if side == :white, do: 0x70, else: 0x60
    <<base ||| hours, to_bcd(total |> rem(3600) |> div(60)), to_bcd(rem(total, 60))>>
  end

  defp to_bcd(n), do: div(n, 10) <<< 4 ||| rem(n, 10)

  @doc "Which command a 4-byte frame from the computer is, and for whom: `{name, address}` or `:error`."
  def decode_command(<<id, hi, lo, sum>> = frame) when hi < 0x80 and lo < 0x80 do
    name = Enum.find_value(@commands, fn {name, code} -> code == id && name end)

    if name && sum == checksum(binary_part(frame, 0, 3)),
      do: {name, hi <<< 7 ||| lo},
      else: :error
  end

  def decode_command(_other), do: :error
end
