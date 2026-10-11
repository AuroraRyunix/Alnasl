defmodule Alnasl.Dgt.Protocol do
  @moduledoc """
  The DGT electronic board protocol for ONE board on its own serial line, as
  DGT published it ("DGT Electronic Board Protocol Description", the header
  file `dgtbrd13.h`, version 1.3 of the protocol).

  **Every number DGT's protocol uses is in this module and nowhere else.**
  They are written here from that published description as the author knows
  it; none of it has met a real board yet. Each group below says how sure it
  is:

  - `PUBLISHED` - stated in the published header, and the same in every
    open implementation of it. Believed.
  - `ASSUMED` - believed, but a detail the author could not check against the
    document while writing. The first capture of a real board
    (docs/tomorrow.md) confirms or corrects it, and the tests that pin it
    (`test/alnasl/dgt_protocol_test.exs`) say so by name.

  ## The line

  PUBLISHED: 9600 baud, 8 data bits, no parity, 1 stop bit, no flow control.

  ## Commands (computer to board)

  One byte each, bit 7 clear, no framing, no answer unless the command asks
  for one.

  ## Messages (board to computer)

  PUBLISHED: three header bytes, then data.

      byte 0   message id, with bit 7 SET
      byte 1   size, high 7 bits   (bit 7 clear)
      byte 2   size, low 7 bits    (bit 7 clear)
      ...      size - 3 bytes of data

  The size counts the header. Since only a header's first byte has bit 7 set
  in the fixed-size messages, a reader that lost its place can find the next
  message by skipping to a byte with bit 7 set and a plausible size; `parse/1`
  does that.
  """

  import Bitwise

  # --- commands: PUBLISHED -----------------------------------------------------

  # Resets the board to idle: it stops sending updates.
  @send_reset 0x40
  # Asks for one clock message (DGT_MSG_BWTIME).
  @send_clk 0x41
  # Asks for the whole board once (DGT_MSG_BOARD_DUMP).
  @send_brd 0x42
  # Update mode: a field update for every change, and the clock every second.
  @send_update 0x43
  # Update mode, board only: a field update for every change, no clock.
  @send_update_brd 0x44
  # Asks for the serial number (DGT_MSG_SERIALNR).
  @return_serialnr 0x45
  # Asks for the bus address (DGT_MSG_BUSADRES).
  @return_busadres 0x46
  # Asks for the trademark text (DGT_MSG_TRADEMARK).
  @send_trademark 0x47
  # Update mode, "nice": field updates, and the clock only when it changed.
  @send_update_nice 0x4B
  # Asks for the battery status (DGT_MSG_BATTERY_STATUS) - Bluetooth boards.
  @send_battery_status 0x4C
  # Asks for the firmware version (DGT_MSG_VERSION).
  @send_version 0x4D

  @commands %{
    reset: @send_reset,
    clock: @send_clk,
    board: @send_brd,
    update: @send_update,
    update_board: @send_update_brd,
    serial: @return_serialnr,
    bus_address: @return_busadres,
    trademark: @send_trademark,
    update_nice: @send_update_nice,
    battery: @send_battery_status,
    version: @send_version
  }

  # --- message ids (without bit 7): PUBLISHED ----------------------------------

  @msg_board_dump 0x06
  @msg_bwtime 0x0D
  @msg_field_update 0x0E
  @msg_ee_moves 0x0F
  @msg_busadres 0x10
  @msg_serialnr 0x11
  @msg_trademark 0x12
  @msg_version 0x13
  # ASSUMED: the id of the battery message of the Bluetooth boards.
  @msg_battery_status 0x20
  # ASSUMED: the id of the long serial number of the newer boards.
  @msg_long_serialnr 0x22

  # --- sizes, header included: PUBLISHED ---------------------------------------

  @size_board_dump 67
  @size_bwtime 10
  @size_field_update 5
  @size_serialnr 8
  @size_version 5
  @size_busadres 5

  # --- piece codes: PUBLISHED --------------------------------------------------

  # 0x00 is an empty square. 0x0D-0x0F are the three "special" pieces a board
  # may carry for signalling a result; they are read as empty squares here.
  @pieces %{
    0x01 => {:w, :p},
    0x02 => {:w, :r},
    0x03 => {:w, :n},
    0x04 => {:w, :b},
    0x05 => {:w, :k},
    0x06 => {:w, :q},
    0x07 => {:b, :p},
    0x08 => {:b, :r},
    0x09 => {:b, :n},
    0x0A => {:b, :b},
    0x0B => {:b, :k},
    0x0C => {:b, :q}
  }
  @codes Map.new(@pieces, fn {code, piece} -> {piece, code} end)

  # PUBLISHED: square 0 of a board dump (and of a field update) is a8, then
  # b8 ... h8, a7 ... down to h1 = 63. The same order as `Alnasl.Position`,
  # for a board lying with White's side where DGT prints it; a board plugged
  # in the other way round is turned by the box, not here.

  @baud 9600
  def baud, do: @baud

  # --- writing commands --------------------------------------------------------

  @doc "The byte of a command: `:reset | :clock | :board | :update | :update_board | :update_nice | :serial | :bus_address | :trademark | :battery | :version`."
  def command(name), do: <<Map.fetch!(@commands, name)>>

  def commands, do: @commands

  # --- reading messages --------------------------------------------------------

  @type message ::
          {:board, tuple()}
          | {:field, 0..63, tuple() | nil}
          | {:clock, map()}
          | {:clock_ack, binary()}
          | {:serial, String.t()}
          | {:version, String.t()}
          | {:bus_address, non_neg_integer()}
          | {:trademark, String.t()}
          | {:battery, binary()}
          | {:ee_moves, binary()}
          | {:unknown, byte(), binary()}

  @doc """
  Takes the bytes received so far and returns the complete messages in them
  and what is left over (the start of a message still arriving).
  Bytes that cannot begin a message are skipped.
  """
  @spec parse(binary()) :: {[message()], binary()}
  def parse(buffer), do: parse(buffer, [])

  defp parse(<<id, hi, lo, _::binary>> = buffer, acc) when id >= 0x80 and hi < 0x80 and lo < 0x80 do
    size = (hi <<< 7) ||| lo

    cond do
      size < 3 ->
        <<_skip, rest::binary>> = buffer
        parse(rest, acc)

      byte_size(buffer) >= size ->
        length = size - 3
        <<_header::binary-size(3), data::binary-size(^length), rest::binary>> = buffer
        parse(rest, [decode(id &&& 0x7F, data) | acc])

      true ->
        {Enum.reverse(acc), buffer}
    end
  end

  # A first byte with bit 7 set, but the header is not all here yet.
  defp parse(<<id, _::binary>> = buffer, acc) when id >= 0x80 and byte_size(buffer) < 3,
    do: {Enum.reverse(acc), buffer}

  defp parse(<<_garbage, rest::binary>>, acc), do: parse(rest, acc)
  defp parse(<<>>, acc), do: {Enum.reverse(acc), <<>>}

  defp decode(@msg_board_dump, <<squares::binary-size(64)>>) do
    {:board, squares |> :binary.bin_to_list() |> Enum.map(&Map.get(@pieces, &1)) |> List.to_tuple()}
  end

  defp decode(@msg_field_update, <<square, code>>) when square < 64,
    do: {:field, square, Map.get(@pieces, code)}

  defp decode(@msg_bwtime, <<_::binary-size(7)>> = data), do: decode_clock(data)

  defp decode(@msg_serialnr, data), do: {:serial, printable(data)}
  defp decode(@msg_long_serialnr, data), do: {:serial, printable(data)}
  defp decode(@msg_version, <<major, minor>>), do: {:version, "#{major}.#{minor}"}
  defp decode(@msg_busadres, <<hi, lo>>), do: {:bus_address, (hi <<< 7) ||| lo}
  defp decode(@msg_trademark, data), do: {:trademark, printable(data)}
  defp decode(@msg_battery_status, data), do: {:battery, data}
  defp decode(@msg_ee_moves, data), do: {:ee_moves, data}
  defp decode(id, data), do: {:unknown, id, data}

  defp printable(data), do: for(<<c <- data>>, c >= 0x20 and c < 0x7F, into: "", do: <<c>>)

  # --- the clock message -------------------------------------------------------
  #
  # PUBLISHED: seven data bytes.
  #
  #   0  RIGHT player: hours in the low nibble; flags in the high nibble
  #   1  RIGHT player: minutes, BCD
  #   2  RIGHT player: seconds, BCD
  #   3  LEFT player:  hours in the low nibble; flags in the high nibble
  #   4  LEFT player:  minutes, BCD
  #   5  LEFT player:  seconds, BCD
  #   6  status
  #
  # PUBLISHED: when the low nibble of byte 0 or of byte 3 is 0x0A the message
  # is not a time at all but the clock's acknowledgement of a command sent to
  # it; such a message is passed on as `{:clock_ack, data}` and never read as
  # a time.
  #
  # ASSUMED - the status byte, bit by bit:
  #
  #   bit 0  the clock is running
  #   bit 1  the lever (tumbler) is high on the RIGHT player's side
  #   bit 2  battery low
  #   bit 3  it is Black's turn
  #   bit 4  it is White's turn
  #   bit 5  no clock connected: the reading is not valid
  #
  # ASSUMED: "left" and "right" are as seen from the front of the clock, and
  # which of them is White depends on how the clock stands beside the board.
  # The message therefore gives `left_ms` and `right_ms`; the driver maps
  # them to White and Black by the board's `clock_white` option (`"left"` by
  # default) - or, when bits 3/4 are trustworthy, by which side they say runs.

  @status_running 0x01
  @status_lever_right 0x02
  @status_battery_low 0x04
  @status_black_turn 0x08
  @status_white_turn 0x10
  @status_no_clock 0x20

  defp decode_clock(<<r_h, r_m, r_s, l_h, l_m, l_s, status>> = data) do
    cond do
      (r_h &&& 0x0F) == 0x0A or (l_h &&& 0x0F) == 0x0A ->
        {:clock_ack, data}

      true ->
        {:clock,
         %{
           right_ms: time_ms(r_h, r_m, r_s),
           left_ms: time_ms(l_h, l_m, l_s),
           running?: (status &&& @status_running) != 0,
           lever: if((status &&& @status_lever_right) != 0, do: :right, else: :left),
           battery_low?: (status &&& @status_battery_low) != 0,
           turn:
             cond do
               (status &&& @status_white_turn) != 0 -> :white
               (status &&& @status_black_turn) != 0 -> :black
               true -> nil
             end,
           connected?: (status &&& @status_no_clock) == 0
         }}
    end
  end

  defp time_ms(hours, minutes, seconds),
    do: (((hours &&& 0x0F) * 60 + bcd(minutes)) * 60 + bcd(seconds)) * 1000

  defp bcd(byte), do: (byte >>> 4 &&& 0x07) * 10 + (byte &&& 0x0F)

  @doc """
  A clock message as the reading the rest of Alnasl uses:
  `%{white_ms, black_ms, running}`, or `nil` when no clock is connected.
  `white` says which side of the clock is White's: `:left` or `:right`.
  """
  def reading(%{connected?: false}, _white), do: nil

  def reading(%{} = clock, white) do
    {white_ms, black_ms} =
      if white == :right, do: {clock.right_ms, clock.left_ms}, else: {clock.left_ms, clock.right_ms}

    %{
      white_ms: white_ms,
      black_ms: black_ms,
      running: if(clock.running?, do: clock.turn || lever_side(clock.lever, white), else: :none)
    }
  end

  # ASSUMED: the lever is high on the side of the player whose clock is NOT
  # running (they have just pressed it down... on the other side). Only used
  # when the turn bits say nothing.
  defp lever_side(lever, white) do
    if lever == white, do: :black, else: :white
  end

  @doc """
  What a message means for the board the driver is keeping: `{:position,
  board}` when the picture of the board changed, `{:clock, map}`, `{:info,
  map}`, or `:ignore`. `board` is the last known board, or `nil` before the
  first dump - a field update for a board never seen whole is ignored (the
  driver asks for a dump instead).
  """
  def apply_message({:board, squares}, _board), do: {:position, squares}
  def apply_message({:field, _square, _piece}, nil), do: :ignore
  def apply_message({:field, square, piece}, board), do: {:position, put_elem(board, square, piece)}

  def apply_message({:clock, clock}, _board) do
    case reading(clock, :left) do
      nil -> :ignore
      reading -> {:clock, reading}
    end
  end

  def apply_message({:serial, serial}, _board), do: {:info, %{serial: serial}}
  def apply_message({:version, version}, _board), do: {:info, %{firmware: version}}
  def apply_message({:bus_address, address}, _board), do: {:info, %{bus_address: address}}
  def apply_message({:trademark, text}, _board), do: {:info, %{trademark: text}}
  def apply_message({:battery, data}, _board), do: {:info, %{battery: Base.encode16(data)}}
  def apply_message(_other, _board), do: :ignore

  # --- writing messages (the emulator, and the tests) --------------------------

  @doc "A message as the board would send it: header and data."
  def frame(id, data) do
    size = byte_size(data) + 3
    <<id ||| 0x80, size >>> 7 &&& 0x7F, size &&& 0x7F, data::binary>>
  end

  def encode({:board, squares}) do
    frame(@msg_board_dump, for(i <- 0..63, into: <<>>, do: <<code(elem(squares, i))>>))
  end

  def encode({:field, square, piece}), do: frame(@msg_field_update, <<square, code(piece)>>)
  def encode({:serial, text}), do: frame(@msg_serialnr, String.pad_trailing(String.slice(text, 0, 5), 5))

  def encode({:version, text}) do
    [major, minor] = text |> String.split(".") |> Enum.map(&String.to_integer/1)
    frame(@msg_version, <<major, minor>>)
  end

  def encode({:bus_address, address}), do: frame(@msg_busadres, <<address >>> 7 &&& 0x7F, address &&& 0x7F>>)
  def encode({:trademark, text}), do: frame(@msg_trademark, text)

  def encode({:clock, %{left_ms: left, right_ms: right} = clock}) do
    status =
      if(clock[:running?], do: @status_running, else: 0) |||
        if(clock[:lever] == :right, do: @status_lever_right, else: 0) |||
        case clock[:turn] do
          :white -> @status_white_turn
          :black -> @status_black_turn
          _none -> 0
        end |||
        if(clock[:connected?] == false, do: @status_no_clock, else: 0)

    frame(@msg_bwtime, time_bytes(right) <> time_bytes(left) <> <<status>>)
  end

  defp time_bytes(ms) do
    total = div(ms, 1000)
    hours = min(div(total, 3600), 9)
    minutes = total |> rem(3600) |> div(60)
    seconds = rem(total, 60)
    <<hours, to_bcd(minutes), to_bcd(seconds)>>
  end

  defp to_bcd(n), do: div(n, 10) <<< 4 ||| rem(n, 10)

  defp code(nil), do: 0x00
  defp code(piece), do: Map.fetch!(@codes, piece)

  @doc "The sizes the published description gives, for the tests."
  def sizes do
    %{
      board_dump: @size_board_dump,
      bwtime: @size_bwtime,
      field_update: @size_field_update,
      serialnr: @size_serialnr,
      version: @size_version,
      busadres: @size_busadres
    }
  end
end
