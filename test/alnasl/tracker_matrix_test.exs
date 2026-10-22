defmodule Alnasl.TrackerMatrixTest do
  @moduledoc """
  The tracker against whole games with faults: every bundled game
  (`priv/games` - 59 classics, 7 constructed for underpromotion and en
  passant, 3 more) played through the simulator under each fault mix of
  `Alnasl.Bench.suites/0`.

  What is asserted, per kind of mix:

  - `:exact` - faults a board survives by itself (a hand, a knocked piece,
    two pieces swapped and put right, a flickering square, a takeback, a
    piece resting on its way, a missing clock press, a pawn left for its
    piece): the tracker's moves are the game's moves, and it never once
    raised an alarm. Except what a pawn left standing became: a queen,
    assumed, until it does something only another piece can.
  - `:promotion`, `:promotion_seen` - every promotion that can be taken at
    once is: the pawn left standing until it is, or the new piece read for
    a moment before it is.
  - `:unseen` - a piece that is not seen where it stands for one to five
    plies (parked beside the board, a weak sensor), alone and among the
    other survivable faults: every game whole, no alarm.
  - `:between` - a piece set down between two squares and read on the
    neighbour of the one it went to. See the case below.
  - `:gap2` - one ply at a time goes by unseen, so two moves must be found at
    once. They are, and marked: "reconstructed" when one pair fits,
    "guessed" when more than one does (the classic: a pawn that went one
    square or two and was then taken en passant or plainly) and the box
    took one. Nine games in ten whole and right; never an orange move
    that is wrong, never a wrong move without a mark.
  - `:long` - three or more unseen plies. Here a board alone is not enough
    (docs/design.md, "What the search cannot see"): the shortest explanation
    can be the wrong one, and the order of two moves nobody read is a
    guess. Asserted: whenever the tracker's game differs from the real
    one, the place is marked. Nothing silent.
  - `:lost` - eight unseen plies: found and marked, or the alarm. Nothing
    silent.
  - `:fast_default`, `:fast_clean`, `:bullet` - fast play: see the cases
    below.
  - `:stuck` - a square's sensor dies with a piece on it and goes on
    reading that piece after it has left: found out by the second piece of
    it the board then shows, and not read again. Nearly every game whole.
  - `:dead` - a square's sensor dies and reads empty. A piece going onto it
    reads as a piece lifted, which a hand does too, so only a square a
    piece was seen to leave while it read empty is ever found out; the
    rest is what the box makes of a piece that vanished. Nothing silent.
  - `:illegal` - an illegal move played on. No game leads to that board, so
    whatever the box makes of it is wrong: the alarm, or moves marked as
    reconstructed or guessed. Everything before the illegal move is right,
    and nothing after it is unmarked.
  """

  use ExUnit.Case, async: true

  alias Alnasl.{Bench, Pgn}

  @moduletag timeout: 600_000

  setup_all do
    {:ok, games: Pgn.all_bundled()}
  end

  test "the bundled games are what they are said to be", %{games: games} do
    assert length(games) >= 60
    sans = Enum.flat_map(games, & &1.moves)
    assert Enum.count(games, &(length(&1.moves) >= 120)) >= 5
    assert Enum.any?(sans, &(&1 == "O-O")) and Enum.any?(sans, &String.starts_with?(&1, "O-O-O"))

    for piece <- ~w(Q R B N) do
      assert Enum.any?(sans, &String.contains?(&1, "=" <> piece)), "no promotion to #{piece}"
    end
  end

  for {name, kind, sim, tracker} <- Bench.suites() do
    @sim sim
    @kind kind
    @tracker tracker
    test "#{name}", %{games: games} do
      m = Bench.matrix(games, @sim, @tracker)
      v = fn key -> Map.get(m.verdicts, key, 0) end
      assert m.bad == [], "silently wrong or incomplete: #{inspect(m.bad, limit: 20)}"
      assert v.(:silent) == 0
      assert m.max_search_ms < 2_000
      right = v.(:exact) + v.(:reconstructed_right) + v.(:guessed_right)

      case @kind do
        # A pawn left for a rook, bishop or knight is the one thing here
        # that a board cannot say at once: taken for a queen and marked
        # assumed until it does something a queen cannot, then rewritten.
        :exact ->
          assert only_promotions_unsure?(m)
          assert m.alarms == 0
          assert m.budget_hits == 0

        # Every promotion that can be taken at once is, with the pawn left
        # standing for its piece. The queen is assumed; when it was another
        # piece, the game differs there and only there, and says so.
        :promotion ->
          assert only_promotions_unsure?(m)
          assert v.(:assumed) > 0
          assert m.alarms == 0
          assert m.faults >= 5

        # The same with the new piece on the board for a moment: that
        # moment is enough.
        :promotion_seen ->
          assert right == m.games
          assert m.alarms == 0
          assert m.guessed == 0

        # Crosstalk: a piece read as nothing, or as its neighbour in the
        # frequency table, for a moment or for as long as it stands there.
        # A wrong kind on the right colour is the board mishearing, never
        # the game; a piece not heard is a piece standing unseen. Nothing
        # silent, the games whole bar the odd promotion assumed, and the
        # alarm left for the rare board nothing explains.
        :crosstalk ->
          assert m.faults > 100
          assert right + v.(:assumed) >= m.games * 0.9
          assert m.alarms <= m.games * 0.1

        # A piece out of sight for a few plies (`:unseen`): the game is
        # followed through it, whole, and nobody is called. (With the
        # benign faults: a pawn left for its piece, as above.)
        :unseen ->
          assert only_promotions_unsure?(m)
          assert m.alarms == 0
          assert m.faults > 100

        # A piece set down between two squares and read on the wrong one
        # (`:between`). Found out when a later move makes no sense, and the
        # misread move rewritten; or never contradicted by anything the
        # board reads, which no tracker can help. Nothing silent, and most
        # games whole.
        :between ->
          assert m.faults > 50
          assert right + v.(:unnoticed) >= m.games * 0.85
          assert v.(:alarm) <= m.games * 0.05

        :gap2 ->
          assert v.(:flagged) == 0
          assert v.(:reconstructed_wrong) == 0
          assert right >= m.games * 0.9
          # Marked: orange, or red where the cable was out.
          assert m.recovered + m.guessed > 0

        :long ->
          assert right > 0

        :lost ->
          assert v.(:alarm) > 0
          assert v.(:exact) == 0

        # Fast play (`Script.profile(:bullet)`): a move every 0.3-2 s, the
        # clock a second late. At speed alone, with the tracker as it
        # comes, a move may have to be reconstructed - never wrongly.
        :fast_default ->
          assert right == m.games
          assert m.alarms == 0

        # With "Bullet / fast play" from the Setup page: the same.
        :fast_clean ->
          assert right == m.games
          assert m.alarms == 0
          assert m.guessed == 0

        # And with the hands of a time scramble - slammed pieces, pieces
        # knocked over, plies that went by unseen, presses the clock never
        # reported: nothing silent, and nearly every game whole and right.
        :bullet ->
          assert v.(:flagged) == 0
          assert v.(:reconstructed_wrong) == 0
          assert right >= m.games * 0.9
          assert m.faults > 2_000

        # A move out of turn, or a move no rule allows, left standing and
        # taken back: said by name, nothing added to the game, and the
        # game whole afterwards. (A move out of turn that undoes the move
        # just made reads as that move taken back, and is.)
        :named ->
          assert right == m.games
          assert m.guessed == 0
          assert m.named_games >= m.games * 0.9

        # What hands do in a hall besides moving: a j'adoube on the
        # opponent's time, a piece knocked onto the next square and put
        # back, the next player lifting before the last piece has landed,
        # the lever knocked back and pressed again. The knocked piece is
        # what the board shows for a few seconds and is called out while
        # it lies there; the game is whole all the same.
        :hall ->
          assert m.faults > 50
          assert v.(:flagged) == 0
          assert v.(:reconstructed_wrong) == 0
          assert v.(:guessed_wrong) == 0
          assert right + v.(:assumed) >= m.games * 0.95

        # The same at bullet speed, among the scramble's own faults:
        # nothing unmarked, and nearly every game right.
        :hall_bullet ->
          assert v.(:flagged) == 0
          assert right >= m.games * 0.9
          assert v.(:reconstructed_wrong) + v.(:guessed_wrong) <= m.games * 0.03

        :stuck ->
          assert m.faults > 50
          assert right >= m.games * 0.8
          assert v.(:alarm) <= m.games * 0.2

        :dead ->
          assert m.faults > 50
          assert right >= m.games * 0.2

        :illegal ->
          for {index, run} <- m.runs, game = Enum.at(games, index - 1), length(game.moves) > 14 do
            assert run.verdict in [:alarm, :guessed_wrong, :reconstructed_wrong]
            # Whatever became of it later, the box first said what it saw.
            assert run.named >= 1
            plies = run.session.tracker.plies

            # The moves before it are right - or, among the last few, a
            # move rewritten to make the illegal one a legal one, and
            # marked as rewritten.
            for {ply, san} <- plies |> Enum.take(11) |> Enum.zip(game.moves) do
              assert (ply.san == san and ply.flags == []) or :rewritten in ply.flags
            end

            assert plies |> Enum.take(5) |> Enum.map(& &1.san) == Enum.take(game.moves, 5)

            # Whatever came after is marked, every move of it that the box
            # worked out rather than read.
            assert run.verdict == :alarm or
                     Enum.any?(Enum.drop(plies, 11), &(&1.flags != []))
          end
      end
    end
  end

  test "the bullet profile is fast play: a move every 0.3-2 s, slams, knocks, a late clock", %{
    games: games
  } do
    profile = Alnasl.Simulator.Script.profile(:bullet)
    scripts = for {game, i} <- Enum.with_index(games, 1), do: build(game, profile, i)

    plies = games |> Enum.map(&length(&1.moves)) |> Enum.sum()
    per_move = (scripts |> Enum.map(& &1.duration_ms) |> Enum.sum()) / plies
    assert per_move > 300 and per_move < 2_000

    faults = scripts |> Enum.flat_map(& &1.log) |> Enum.frequencies_by(&elem(&1, 1))
    assert faults.slam > plies * 0.2
    for fault <- [:topple, :knock, :missed, :clock_miss, :hover], do: assert(faults[fault] > 50)

    # What arrives is in the order it arrives, lagging clock or not.
    for script <- scripts do
      times = Enum.map(script.events, &elem(&1, 0))
      assert times == Enum.sort(times)
    end

    # A simulator board asked for "bullet" plays exactly that.
    assert Alnasl.Driver.Simulator.script(%{"profile" => "bullet", "game" => 1, "seed" => 1}) ==
             hd(scripts)
  end

  # Every game right, or differing only in what a pawn left standing became
  # (and marked assumed there); and every move marked is such a promotion,
  # or the capture of it found together with it.
  defp only_promotions_unsure?(m) do
    Map.keys(m.verdicts) -- [:exact, :reconstructed_right, :guessed_right, :assumed] == [] and
      Enum.all?(m.runs, fn {_index, run} ->
        plies = run.session.tracker.plies

        plies
        |> Enum.with_index()
        |> Enum.filter(fn {ply, _i} -> :recovered in ply.flags or :guessed in ply.flags end)
        |> Enum.all?(fn {ply, i} ->
          # The promotion, or the capture found with it.
          ply.promo != nil or (i > 0 and Enum.at(plies, i - 1).promo != nil)
        end)
      end)
  end

  defp build(game, profile, seed),
    do: Alnasl.Simulator.Script.build(game.moves, Map.put(profile, :seed, seed))

  test "any mix of the survivable faults, at any rates", %{games: games} do
    faults = [:hover, :lift, :knock, :swap, :clock_miss, :leave_pawn, :takeback, :slide]

    sim = fn {index, pass} ->
      :rand.seed(:exsss, {index, pass, 99})
      chosen = Enum.take_random(faults, :rand.uniform(length(faults)))
      %{faults: Map.new(chosen, &{&1, :rand.uniform() * 0.3}), clock: :rand.uniform() < 0.7}
    end

    m = Bench.matrix(games, sim, [], 2)
    assert only_promotions_unsure?(m)
    assert m.alarms == 0
    assert m.faults > 1_000
  end

  test "the same, with slower and faster tracker settings", %{games: games} do
    sim = %{faults: %{lift: 0.1, takeback: 0.1, slide: 0.1, hover: 0.1}}

    for tracker <- [[settle_ms: 150], [settle_ms: 900, castle_hold_ms: 3_000]] do
      m = Bench.matrix(Enum.take(games, 30), sim, tracker)
      assert m.verdicts == %{exact: 30}
      assert m.alarms == 0
    end
  end
end
