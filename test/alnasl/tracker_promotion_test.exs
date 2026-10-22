defmodule Alnasl.TrackerPromotionTest do
  @moduledoc """
  A promotion whose new piece the board never reads: the pawn left
  standing on the last rank and taken there at once (d8=Q Rxd8, with no
  queen ever on d8), the new piece put down and taken before it could
  settle, and the later move that says, after all, what the pawn became.
  """

  use ExUnit.Case, async: true

  alias Alnasl.{Position, Tracker}

  defp board(fen), do: Position.from_fen(fen)
  defp sq(name), do: Position.square_index(name)
  defp lift(board, square), do: put_elem(board, sq(square), nil)
  defp put(board, square, piece), do: put_elem(board, sq(square), piece)
  defp move(board, from, to), do: board |> put(to, elem(board, sq(from))) |> lift(from)

  defp feed(tr, timed, tail \\ 70_000) do
    {tr, out, last} =
      Enum.reduce(timed, {tr, [], 0}, fn {t, what}, {tr, out, _last} ->
        {tr, out} = ticks(tr, t, out)

        {tr, events} =
          case what do
            :press -> Tracker.press(tr, t)
            board -> Tracker.observe(tr, t, board)
          end

        {tr, out ++ Enum.map(events, &{t, &1}), t}
      end)

    ticks(tr, last + tail, out)
  end

  defp ticks(tr, until, out) do
    case Tracker.deadline(tr) do
      due when is_integer(due) and due < until ->
        {tr, events} = Tracker.tick(tr, due)
        ticks(tr, until, out ++ Enum.map(events, &{due, &1}))

      _none ->
        {tr, out}
    end
  end

  defp alarms(out), do: for({_t, {:status, :out_of_sync, why}} <- out, do: why)

  # White to promote on d8, a black rook on a8 to take whatever arrives.
  @fen "r7/3P2k1/8/8/8/8/6K1/8 w - - 0 1"

  defp tracker(fen \\ @fen) do
    {tr, _} = Tracker.observe(Tracker.new(start_fen: fen), 0, board(fen))
    {tr, board(fen)}
  end

  # The pawn pushed to d8 and left there; the rook takes it.
  defp pawn_left_and_taken(b) do
    pawn = move(b, "d7", "d8")
    taken = move(pawn, "a8", "d8")
    {pawn, taken}
  end

  describe "the pawn left on the last rank and taken at once" do
    test "pressed for: the promotion is the default piece, assumed, and the capture is a capture" do
      {tr, b} = tracker()
      {pawn, taken} = pawn_left_and_taken(b)

      {tr, out} =
        feed(tr, [{1_000, pawn}, {1_300, :press}, {3_000, lift(pawn, "a8")}, {3_400, taken}])

      assert Tracker.sans(tr) == ["d8=Q", "Rxd8"]
      assert [%{flags: promo}, %{flags: capture}] = tr.plies, inspect(tr.plies)
      assert :assumed in promo, inspect(out)
      assert capture -- [:recovered] == []
      assert alarms(out) == []
      assert tr.status == :live
    end

    test "taken before the promotion was believed: both moves found, the piece assumed" do
      {tr, b} = tracker()
      {pawn, taken} = pawn_left_and_taken(b)

      # No clock, and the rook takes a second after the pawn arrived: the
      # promotion never stood its `promotion_hold_ms`.
      {tr, out} = feed(tr, [{1_000, pawn}, {2_000, lift(pawn, "a8")}, {2_300, taken}])

      assert Tracker.sans(tr) == ["d8=Q", "Rxd8"]
      assert [%{flags: promo}, %{flags: capture}] = tr.plies, inspect(tr.plies)
      assert :assumed in promo, inspect(out)
      assert :recovered in promo and :recovered in capture
      refute :guessed in promo
      assert alarms(out) == []
    end

    test "slammed: the pawn and the rook in one reading" do
      {tr, b} = tracker()
      {_pawn, taken} = pawn_left_and_taken(b)
      {tr, out} = feed(tr, [{1_000, taken}])

      assert Tracker.sans(tr) == ["d8=Q", "Rxd8"]
      assert [%{flags: promo}, %{flags: capture}] = tr.plies, inspect(tr.plies)
      assert :assumed in promo and :recovered in capture
      assert alarms(out) == []
    end

    test "taken by the king, which then stands on the promotion square" do
      fen = "8/2kP4/8/8/8/8/6K1/8 w - - 0 1"
      {tr, b} = tracker(fen)
      pawn = move(b, "d7", "d8")
      taken = move(pawn, "c7", "d8")

      {tr, out} =
        feed(tr, [{1_000, pawn}, {1_200, :press}, {4_000, lift(pawn, "c7")}, {4_300, taken}])

      assert Tracker.sans(tr) == ["d8=Q+", "Kxd8"]
      assert :assumed in hd(tr.plies).flags
      assert alarms(out) == []
    end
  end

  describe "an underpromotion never read" do
    for piece <- [:n, :b, :r] do
      @piece piece
      test "to #{piece}, taken at once: nothing on the board says which, so it is the queen, assumed" do
        {tr, b} = tracker()
        {pawn, taken} = pawn_left_and_taken(b)
        {tr, out} = feed(tr, [{1_000, pawn}, {1_200, :press}, {4_000, taken}, {4_100, :press}])

        # The game had d8=#{@piece |> Atom.to_string() |> String.upcase()}: the box says the queen
        # and that it assumed so - the one honest answer.
        assert Tracker.sans(tr) == ["d8=Q", "Rxd8"]
        assert :assumed in hd(tr.plies).flags
        assert alarms(out) == []
      end
    end

    test "to a knight, left as a pawn, which then moves as a knight: the promotion is rewritten" do
      fen = "8/3P2k1/8/8/8/8/6K1/r7 w - - 0 1"
      {tr, b} = tracker(fen)
      pawn = move(b, "d7", "d8")
      {tr, _} = feed(tr, [{1_000, pawn}, {1_200, :press}], 5_000)
      assert [%{san: "d8=Q", flags: [:assumed]}] = tr.plies

      black = move(pawn, "a1", "b1")
      jump = move(black, "d8", "c6")

      {tr, out} =
        feed(tr, [{8_000, black}, {8_200, :press}, {12_000, jump}, {12_200, :press}], 5_000)

      assert ["d8=N", "Rb1", "Nc6"] = Tracker.sans(tr), inspect(out)
      assert Enum.any?(out, &match?({_, {:correction, 0, _, :promotion}}, &1))
      assert alarms(out) == []
    end

    test "a check the queen would give and the next move ignores: not the queen, and a guess among the rest" do
      # d8=Q is check along the rank to h8; a knight or a bishop is not.
      fen = "7k/3P4/p7/8/8/8/6K1/8 w - - 0 1"
      {tr, b} = tracker(fen)
      pawn = move(b, "d7", "d8")
      {tr, _} = feed(tr, [{1_000, pawn}, {1_200, :press}], 5_000)
      ignore = move(pawn, "a6", "a5")
      {tr, out} = feed(tr, [{8_000, ignore}, {8_200, :press}], 10_000)

      assert [promo, "a5"] = Tracker.sans(tr)
      assert promo in ["d8=R+", "d8=B", "d8=N"]
      assert :guessed in hd(tr.plies).flags
      assert alarms(out) == []
    end
  end

  describe "the new piece put down and taken before it could settle" do
    for piece <- [:q, :n] do
      @piece piece
      test "#{piece}: read for a moment, and that moment is what the promotion was" do
        {tr, b} = tracker()
        gone = lift(b, "d7")
        placed = put(gone, "d8", {:w, @piece})
        # The rook is lifted while the new piece stands, then the new piece
        # comes off, then the rook lands. Under 250 ms each.
        rook_up = lift(placed, "a8")
        cleared = lift(rook_up, "d8")
        taken = put(cleared, "d8", {:b, :r})

        {tr, out} =
          feed(tr, [
            {1_000, gone},
            {1_100, placed},
            {1_200, rook_up},
            {1_300, cleared},
            {1_400, taken}
          ])

        letter = @piece |> Atom.to_string() |> String.upcase()
        assert Tracker.sans(tr) == ["d8=" <> letter, "Rxd8"]
        refute Enum.any?(tr.plies, &(:guessed in &1.flags))
        refute Enum.any?(tr.plies, &(:assumed in &1.flags))
        assert alarms(out) == []
      end

      test "#{piece}: the new piece taken off first, then the rook lifted and set down" do
        {tr, b} = tracker()
        gone = lift(b, "d7")
        placed = put(gone, "d8", {:w, @piece})
        cleared = lift(placed, "d8")
        rook_up = lift(cleared, "a8")
        taken = put(rook_up, "d8", {:b, :r})

        {tr, out} =
          feed(tr, [
            {1_000, gone},
            {1_150, placed},
            {1_300, cleared},
            {1_400, rook_up},
            {1_500, taken}
          ])

        letter = @piece |> Atom.to_string() |> String.upcase()
        assert Tracker.sans(tr) == ["d8=" <> letter, "Rxd8"]
        refute Enum.any?(tr.plies, &(:guessed in &1.flags))
        assert alarms(out) == []
      end
    end
  end

  describe "the simulator's promotion taken at once" do
    defp built(options) do
      for {game, i} <- Enum.with_index(Alnasl.Pgn.all_bundled(), 1),
          script = Alnasl.Simulator.Script.build(game.moves, Map.put(options, :seed, i)),
          script.taken_at != nil,
          do: script
    end

    test "every game with a promotion the other side can take ends with that capture, the pawn left" do
      taken = built(%{promotion_capture: :pawn_left})
      assert length(taken) >= 5

      for script <- taken do
        assert length(script.sans) == script.taken_at + 1
        [promotion, capture] = Enum.take(script.sans, -2)
        [square] = Regex.run(~r/[a-h][18](?==)/, promotion)
        assert capture =~ "x" <> square
        assert {script.taken_at, :leave_pawn} in script.log
      end
    end

    test "promote_as makes the promotion that piece where the game still holds" do
      promotions =
        for script <- built(%{promotion_capture: :quick, promote_as: :n}),
            do: Enum.at(script.sans, -2)

      assert Enum.count(promotions, &(&1 =~ "=N")) >= 5

      refute Enum.any?(
               built(%{promotion_capture: :quick}),
               &({&1.taken_at, :leave_pawn} in &1.log)
             )
    end
  end
end
