defmodule Alnasl.Dgt.Loop do
  @moduledoc """
  Who is on this serial line? Asked with the port open and nobody else
  talking on it: when a port is added, and each time the single-board driver
  opens one.

  How, as a real loop showed it works (`docs/real-loop-2026-10-12.md`):

  1. the bus-mode byte, and a pause;
  2. a ping to address 0. Every board answers with its address after a wait
     of its own choosing - 26 to 1020 ms in 40 answers - so the line is
     listened to for `window_ms` (1100);
  3. two boards that pick the same moment garble each other (once in 20
     pings with two boards; with twelve it will be most rounds). So every
     board heard is told to sit out the next ping, and the ping is sent
     again for the others;
  4. until two rounds in a row brought nobody new and no garbage - or
     `max_rounds` (12) were asked;
  5. each address heard is then pinged by name, and kept if it answers.

  With one board on the line that is two rounds: some 2.3 seconds. A board
  that does not know bus mode says nothing and the answer is `[]`.

  It blocks the process that calls it, and reads the port's messages out of
  that process's mailbox; anything else that arrives meanwhile is put back
  in the order it came.
  """

  alias Alnasl.Dgt.Bus

  @doc "The pause after the bus-mode byte. 30 ms was enough ten times in ten; none was not."
  def settle_ms, do: 50

  @doc "How long a ping to everybody is listened to."
  def window_ms, do: Application.get_env(:alnasl, :loop_ping_window_ms, 1_100)

  @doc "How long one board gets to begin its answer. The slowest seen was 64 ms."
  def reply_ms, do: Application.get_env(:alnasl, :loop_reply_ms, 200)

  @doc """
  The addresses that answer on the open line `handle`, sorted. `opts`:
  `:trace` - `fn :tx | :rx, bytes -> any end`, called for every byte;
  `:max_rounds`.
  """
  def discover(transport, handle, opts \\ []) do
    io = %{
      transport: transport,
      handle: handle,
      trace: Keyword.get(opts, :trace, fn _direction, _bytes -> :ok end),
      stash: []
    }

    io = tx(io, Bus.to_busmode())
    {_bytes, io} = listen(io, settle_ms(), :all)
    {found, io} = rounds(io, [], 0, Keyword.get(opts, :max_rounds, 12))
    {found, io} = confirmed(io, found)
    for message <- Enum.reverse(io.stash), do: send(self(), message)
    Enum.sort(found)
  end

  # Each address heard is asked once more, by name. Two answers on top of
  # each other can make an address nobody has, with a checksum that happens
  # to fit - once in 128 such accidents - and a row for a board that does
  # not exist would say "No signal" for the rest of the weekend.
  defp confirmed(io, found) do
    Enum.reduce(found, {[], io}, fn address, {kept, io} ->
      {there?, io} = there?(io, address, 2)
      {if(there?, do: kept ++ [address], else: kept), io}
    end)
  end

  defp there?(io, _address, 0), do: {false, io}

  defp there?(io, address, tries) do
    io = tx(io, Bus.command(:ping, address))
    {bytes, io} = listen(io, reply_ms(), :one)

    case Bus.parse(bytes) do
      {[{^address, {:ping, _}} | _], _rest} -> {true, io}
      _nothing -> there?(io, address, tries - 1)
    end
  end

  defp rounds(io, found, quiet, left) when quiet >= 2 or left == 0, do: {found, io}

  defp rounds(io, found, quiet, left) do
    io =
      Enum.reduce(found, io, fn address, io ->
        io = tx(io, Bus.command(:ignore_next_ping, address))
        {_answer, io} = listen(io, reply_ms(), :one)
        io
      end)

    io = tx(io, Bus.command(:ping, 0))
    {bytes, io} = listen(io, window_ms(), :all)
    {answers, rest} = Bus.parse(bytes)
    new = for {address, {:ping, _}} <- answers, address not in found, uniq: true, do: address
    garbled? = rest != <<>> or Enum.any?(answers, &match?({:bad_checksum, _}, &1))

    if new == [] and not garbled?,
      do: rounds(io, found, quiet + 1, left - 1),
      else: rounds(io, found ++ new, 0, left - 1)
  end

  defp tx(io, bytes) do
    io.trace.(:tx, bytes)
    io.transport.write(io.handle, bytes)
    io
  end

  # Everything that arrives in `ms` (`:all`), or until one whole answer is
  # there (`:one`).
  defp listen(io, ms, mode), do: listen(io, now() + ms, mode, <<>>)

  defp listen(io, until, mode, acc) do
    receive do
      message ->
        case io.transport.message(message) do
          {:data, bytes} ->
            io.trace.(:rx, bytes)
            acc = acc <> bytes

            if mode == :one and match?({[_ | _], _}, Bus.parse(acc)),
              do: {acc, io},
              else: listen(io, until, mode, acc)

          {:error, _reason} ->
            {acc, %{io | stash: [message | io.stash]}}

          nil ->
            listen(%{io | stash: [message | io.stash]}, until, mode, acc)
        end
    after
      max(until - now(), 0) -> {acc, io}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
