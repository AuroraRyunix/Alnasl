defmodule Alnasl.RecordedLoop do
  @moduledoc """
  The loop of 2026-10-12 as a device for `Arkab.Transport.Fake`: every bus
  command is answered with the bytes a real board answered that command
  with, taken from the recordings in `test/fixtures/captures/real-loop-*.jsonl`.

  The answers are the recorded ones, byte for byte; what this module adds
  is which command they belong to.
  A ping to everybody is answered by each board that was not told to sit it
  out, one after the other (the real ones answer at moments of their own
  choosing; see `collision/0` for the time they chose the same one).
  """

  @dir "test/fixtures/captures"
  @ping_all <<0x87, 0x00, 0x00, 0x07>>

  @doc "The lines of a recording as `{:tx | :rx | :note, binary}`."
  def lines(name) do
    Path.join(@dir, name)
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.flat_map(fn
      %{"k" => "tx", "h" => hex} -> [{:tx, Base.decode16!(hex, case: :lower)}]
      %{"k" => "rx", "h" => hex} -> [{:rx, Base.decode16!(hex, case: :lower)}]
      %{"k" => "note", "text" => text} -> [{:note, text}]
      _other -> []
    end)
  end

  @doc "Each thing sent in a recording with everything that came back before the next: `[{tx, rx}]`."
  def exchanges(name) do
    name
    |> lines()
    |> Enum.reject(&match?({:note, _}, &1))
    |> Enum.chunk_while(
      nil,
      fn
        {:tx, bytes}, nil -> {:cont, {bytes, <<>>}}
        {:tx, bytes}, done -> {:cont, done, {bytes, <<>>}}
        {:rx, _bytes}, nil -> {:cont, nil}
        {:rx, bytes}, {tx, rx} -> {:cont, {tx, rx <> bytes}}
      end,
      fn
        nil -> {:cont, nil}
        done -> {:cont, done, nil}
      end
    )
  end

  @doc """
  What the two boards answered to each command they were sent on their own,
  in the order they answered it: the first "what changed?" to 06310 is its
  whole memory, the later ones are empty, and the last answer to a command
  is the answer from then on. An answer the recording cut short by asking
  the next question too soon is left out (its own length and checksum say
  so).
  """
  def new do
    answers =
      for name <- ~w(real-loop-02-version-board-clock.jsonl real-loop-03-changes-repeat.jsonl
            real-loop-06-ignore-ping-all-d.jsonl),
          {<<id, _::binary-size(3)>> = tx, rx} <- exchanges(name),
          id >= 0x80 and tx != @ping_all and whole?(rx),
          reduce: %{} do
        acc -> Map.update(acc, tx, [rx], &(&1 ++ [rx]))
      end

    %{answers: answers, sitting_out: MapSet.new(), asked: []}
  end

  defp whole?(rx),
    do: match?({[{address, _message}], <<>>} when is_integer(address), Arkab.Dgt.Bus.parse(rx))

  def handle(state, bytes) do
    for <<frame::binary-size(4) <- strip(bytes)>>, reduce: {<<>>, state} do
      {reply, state} ->
        state = %{state | asked: [frame | state.asked]}

        case frame do
          @ping_all ->
            pings =
              for address <- [<<0x31, 0x26>>, <<0x63, 0x7F>>],
                  not MapSet.member?(state.sitting_out, address),
                  into: <<>>,
                  do: state.answers |> Map.fetch!(ping(address)) |> hd()

            {reply <> pings, %{state | sitting_out: MapSet.new()}}

          <<0x8A, address::binary-size(2), _sum>> ->
            {answer, state} = said(state, frame)
            {reply <> answer, %{state | sitting_out: MapSet.put(state.sitting_out, address)}}

          frame ->
            {answer, state} = said(state, frame)
            {reply <> answer, state}
        end
    end
  end

  defp said(state, frame) do
    case state.answers[frame] do
      nil -> {<<>>, state}
      [only] -> {only, state}
      [first | rest] -> {first, put_in(state.answers[frame], rest)}
    end
  end

  # Single-board bytes (the bus-mode byte) between the commands.
  defp strip(<<byte, rest::binary>>) when byte < 0x80, do: strip(rest)
  defp strip(bytes), do: bytes

  # An addressed ping is not in the recordings used here under its own
  # command; the answer to "sit out the next ping" is the same message.
  defp ping(<<hi, lo>>) do
    import Bitwise
    <<0x8A, hi, lo, 0x8A + hi + lo &&& 0x7F>>
  end

  @doc "The one time in twenty pings that both boards answered at the same moment: what arrived."
  def collision do
    "real-loop-09-ping-delays.jsonl"
    |> exchanges()
    |> Enum.filter(fn {tx, _rx} -> tx == @ping_all end)
    |> Enum.map(&elem(&1, 1))
    |> Enum.find(fn rx ->
      {answers, _rest} = Arkab.Dgt.Bus.parse(rx)
      Enum.any?(answers, &match?({:bad_checksum, _}, &1))
    end)
  end
end
