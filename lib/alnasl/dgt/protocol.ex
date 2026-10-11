defmodule Alnasl.Dgt.Protocol do
  @moduledoc """
  The DGT electronic board protocol for ONE board on its own serial line, as
  DGT published it ("DGT Electronic Board Protocol Description", the header
  file `dgtbrd13.h`, version 1.3 of the protocol).

  **Every number DGT's protocol uses is in this module and nowhere else.**
  They were written here from that published description as the author knew
  it. Each group below says how sure it is:

  - `CONFIRMED` - seen on the wire of a real board: "capture 2026-10-12,
    board 06310, fw 1.9" is the recording decoded in
    `docs/real-board-2026-10-12.md`, and its bytes are test fixtures
    (`test/fixtures/captures/real-06310-*.jsonl`).
  - `PUBLISHED` - stated in the published header, and the same in every
    open implementation of it. Believed, not yet seen by this project.
  - `ASSUMED` - believed, but a detail the author could not check against the
    document while writing, and that no capture has shown yet.

  ## The line

  CONFIRMED (capture 2026-10-12, board 06310, fw 1.9): 9600 baud, 8 data
  bits, no parity, 1 stop bit, no flow control.

  ## Commands (computer to board)

  One byte each, bit 7 clear, no framing, no answer unless the command asks
  for one.

  ## Messages (board to computer)

  CONFIRMED (capture 2026-10-12, board 06310, fw 1.9): three header bytes,
  then data. The board sent no byte outside a message in that capture, and
  the USB adapter hands a message over in pieces: a 67-byte dump arrives as
  five reads some 16 ms apart.

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
  #
  # CONFIRMED (capture 2026-10-12, board 06310, fw 1.9), by what the board
  # answered: 0x45 (serial number), 0x4D (version), 0x42 (board dump) and
  # 0x4B (update mode "nice": field updates, and the clock about once a second
  # while it changes). 0x40 was sent and nothing came back, as published. The
  # others were never sent to a real board.

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
  #
  # CONFIRMED (capture 2026-10-12, board 06310, fw 1.9): board dump, BWTIME,
  # field update, serial number, version. The rest were not seen.

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
  #
  # CONFIRMED (same capture): 67, 10, 5, 8 and 5 for the five messages seen.

  @size_board_dump 67
  @size_bwtime 10
  @size_field_update 5
  @size_serialnr 8
  @size_version 5
  @size_busadres 5

  # --- piece codes: PUBLISHED --------------------------------------------------
  #
  # CONFIRMED (capture 2026-10-12, board 06310, fw 1.9): 0x00 for an empty
  # square and 0x09 for a black knight - the one piece on the board. The
  # other eleven are as published.

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

  # CONFIRMED (capture 2026-10-12, board 06310, fw 1.9; the knight stood on
  # d6 and was byte 19 of the dump, then went to e4, d4, c2 and d2 as field
  # updates 36, 35, 50 and 51): square 0 of a board dump (and of a field
  # update) is a8, then b8 ... h8, a7 ... down to h1 = 63. The same order as `Alnasl.Position`,
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

  defp parse(<<id, hi, lo, _::binary>> = buffer, acc)
       when id >= 0x80 and hi < 0x80 and lo < 0x80 do
    size = hi <<< 7 ||| lo

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
    {:board,
     squares |> :binary.bin_to_list() |> Enum.map(&Map.get(@pieces, &1)) |> List.to_tuple()}
  end

  defp decode(@msg_field_update, <<square, code>>) when square < 64,
    do: {:field, square, Map.get(@pieces, code)}

  defp decode(@msg_bwtime, <<_::binary-size(7)>> = data), do: decode_clock(data)

  defp decode(@msg_serialnr, data), do: {:serial, printable(data)}
  defp decode(@msg_long_serialnr, data), do: {:serial, printable(data)}
  defp decode(@msg_version, <<major, minor>>), do: {:version, "#{major}.#{minor}"}
  defp decode(@msg_busadres, <<hi, lo>>), do: {:bus_address, hi <<< 7 ||| lo}
  defp decode(@msg_trademark, data), do: {:trademark, printable(data)}
  defp decode(@msg_battery_status, data), do: {:battery, data}
  defp decode(@msg_ee_moves, data), do: {:ee_moves, data}
  defp decode(id, data), do: {:unknown, id, data}

  defp printable(data), do: for(<<c <- data>>, c >= 0x20 and c < 0x7F, into: "", do: <<c>>)

  # --- the clock message -------------------------------------------------------
  #
  # CONFIRMED (capture 2026-10-12, board 06310, fw 1.9, a DGT clock on the
  # board's clock socket): seven data bytes.
  #
  #   0  BLACK's side: hours in the low nibble (flags in the high nibble)
  #   1  BLACK's side: minutes, BCD
  #   2  BLACK's side: seconds, BCD
  #   3  WHITE's side: hours in the low nibble (flags in the high nibble)
  #   4  WHITE's side: minutes, BCD
  #   5  WHITE's side: seconds, BCD
  #   6  status
  #
  # DGT's header calls bytes 0-2 the "right" player and bytes 3-5 the "left"
  # one. With the clock where it always stands - to the RIGHT of the board,
  # White's display toward ranks 1-2 - "left" is White: the capture began
  # that way, the user watched White's display count down, and bytes 3-5
  # did. The hours nibble and the BCD minutes and seconds are confirmed by
  # the display (1:30:30 read 01 30 30, and 01 30 00 was followed by
  # 01 29 59). The flag bits in the high nibble of the hours were never set:
  # PUBLISHED.
  #
  # CONFIRMED (same capture, seen twice: after the handshake, and when the
  # clock was switched on again): when the low nibble of byte 0 or of byte 3
  # is 0x0A the message is not a time but something the clock says about
  # itself (0A 10 01 2A 00 00 00); it is passed on as `{:clock_ack, data}`
  # and never read as a time. What it says is not decoded.
  #
  # The status byte, bit by bit:
  #
  #   bit 0  the clock is running                               CONFIRMED
  #   bit 1  the lever is up on BLACK's side ("right"): it is
  #          Black's time that runs, or will                    CONFIRMED
  #   bit 2  battery low                                        PUBLISHED, never set
  #   bit 3  BLACK's side is to move ("right")                  CONFIRMED
  #   bit 4  WHITE's side is to move ("left")                   CONFIRMED
  #   bit 5  no clock: the reading is not valid                 CONFIRMED
  #
  # What the capture showed of them: 0x10 standing still with the lever on
  # White's side; 0x11 with White's time running and 0x0B with Black's, a
  # press of the lever going from the one to the other with the increment
  # added to the side that pressed; 0x10 again when the clock was paused;
  # 0x12 when the lever was then tipped over by hand (bit 1 follows the
  # lever, bit 4 stays); 0x30 with nonsense in bytes 3-5 the moment the clock
  # was switched off; 0x0A when it came back on with the lever on Black's
  # side. Bits 3/4 belong to a SIDE of the clock, not to whoever started: the
  # clock turned round and started on the wrong side said "Black", and was
  # right.
  #
  # NOT seen: which side runs when a clock paused with bits 1 and 4 at odds
  # (0x12) is started again. `reading/1` takes either bit as "Black first".

  @status_running 0x01
  @status_lever_black 0x02
  @status_battery_low 0x04
  @status_black_turn 0x08
  @status_white_turn 0x10
  @status_no_clock 0x20

  defp decode_clock(<<b_h, b_m, b_s, w_h, w_m, w_s, status>> = data) do
    cond do
      (b_h &&& 0x0F) == 0x0A or (w_h &&& 0x0F) == 0x0A ->
        {:clock_ack, data}

      true ->
        {:clock,
         %{
           black_ms: time_ms(b_h, b_m, b_s),
           white_ms: time_ms(w_h, w_m, w_s),
           running?: (status &&& @status_running) != 0,
           lever: if((status &&& @status_lever_black) != 0, do: :black, else: :white),
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
  `%{white_ms, black_ms, running, armed}`, or `nil` when no clock is
  connected (or it is switched off).

  `running` is `:white`, `:black` or `:none`. `armed` is the side whose time
  runs or, on a clock standing still, will run when it is started: `:black`
  when the lever is up on Black's side or the clock says Black is to move,
  `:white` otherwise. It is what the starting-position check looks at.

  Which side is White's is not a setting. DGT convention: the clock stands
  to the right of the board (the cable reaches nowhere else, and DGT's own
  LiveChess assumes the same), so the side DGT calls "left" is White's. A
  clock that is turned round is a clock set up wrongly and is reported as
  exactly that - it is never read the other way round.
  """
  def reading(%{connected?: false}), do: nil

  def reading(%{} = clock) do
    %{
      white_ms: clock.white_ms,
      black_ms: clock.black_ms,
      # The lever only when the clock names nobody: it is up on the side
      # whose time runs (CONFIRMED: bit 1 was set whenever Black's ran).
      running: if(clock.running?, do: clock.turn || clock.lever, else: :none),
      armed: if(clock.lever == :black or clock.turn == :black, do: :black, else: :white)
    }
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

  def apply_message({:field, square, piece}, board),
    do: {:position, put_elem(board, square, piece)}

  def apply_message({:clock, clock}, _board) do
    case reading(clock) do
      nil -> {:info, %{clock: false}}
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

  def encode({:serial, text}),
    do: frame(@msg_serialnr, String.pad_trailing(String.slice(text, 0, 5), 5))

  def encode({:version, text}) do
    [major, minor] = text |> String.split(".") |> Enum.map(&String.to_integer/1)
    frame(@msg_version, <<major, minor>>)
  end

  def encode({:bus_address, address}),
    do: frame(@msg_busadres, <<address >>> 7 &&& 0x7F, address &&& 0x7F>>)

  def encode({:trademark, text}), do: frame(@msg_trademark, text)

  def encode({:clock, %{white_ms: white, black_ms: black} = clock}) do
    status =
      if(clock[:running?], do: @status_running, else: 0) |||
        if(clock[:lever] == :black, do: @status_lever_black, else: 0) |||
        case clock[:turn] do
          :white -> @status_white_turn
          :black -> @status_black_turn
          _none -> 0
        end |||
        if(clock[:connected?] == false, do: @status_no_clock, else: 0)

    frame(@msg_bwtime, time_bytes(black) <> time_bytes(white) <> <<status>>)
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
