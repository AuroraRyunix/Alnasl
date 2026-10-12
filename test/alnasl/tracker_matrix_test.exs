defmodule Alnasl.TrackerMatrixTest do
  @moduledoc """
  The tracker against whole games with faults: every bundled game
  (`priv/games` - 59 classics, 7 constructed for underpromotion and en
  passant, 3 more) played through the simulator under each fault mix of
  `Alnasl.Bench.suites/0`.

  What is asserted, per kind of mix:

  - `:exact` - faults a board survives by itself (a hand, a knocked piece,
    two pieces swapped and put right, a flickering square, a takeback, a
    piece resting on its way, a missing clock press, a pawn left for a
    queen): the tracker's moves are the game's moves, and it never once
    raised an alarm.
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
        :exact ->
          assert m.verdicts == %{exact: m.games}
          assert m.alarms == 0
          assert m.recovered == 0 and m.guessed == 0
          assert m.budget_hits == 0

        # A piece out of sight for a few plies (`:unseen`): the game is
        # followed through it, whole, and nobody is called.
        :unseen ->
          assert m.verdicts == %{exact: m.games}
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
          assert m.recovered > 0

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

        :illegal ->
          for {index, run} <- m.runs, game = Enum.at(games, index - 1), length(game.moves) > 14 do
            assert run.verdict in [:alarm, :guessed_wrong, :reconstructed_wrong]
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
    assert m.verdicts == %{exact: m.games}
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
