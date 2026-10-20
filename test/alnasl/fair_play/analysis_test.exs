defmodule Alnasl.FairPlay.AnalysisTest do
  use Alnasl.DataCase, async: false

  import Alnasl.FairPlayFixtures

  alias Alnasl.FairPlay.{Analysis, Move}
  alias Alnasl.Games

  # 40 plies of random play: moves 1-8 of each side are book (16 plies), the
  # rest can count (repetitions and forced moves aside).
  @sans random_sans(40, 3)

  setup do
    %{tournament: rated_tournament()}
  end

  defp rows(game), do: Repo.all(from m in Move, where: m.game_id == ^game.id, order_by: m.ply)
  defp counted(rows), do: Enum.filter(rows, &(&1.skip == nil))

  test "stores one row per final ply, with the engine that made it", %{tournament: t} do
    game = game(t, @sans)
    assert :ok = Analysis.run(game.id, engine(), setting())

    rows = rows(game)
    assert length(rows) == 40
    assert Enum.take(rows, 16) |> Enum.all?(&(&1.skip == "opening"))

    [first | _] = counted(rows)
    assert first.engine_id == "sf19"
    assert first.bench == 2_497_913
    assert first.nodes == 1_000_000
    assert first.rating in [2100, 2000]
    assert first.rank == 1
    assert [%{move: _, cp: 30} | _] = Move.decode_best(first.best)
    assert first.player_key in ["id:1", "id:2"]

    # Only the plies that can count reach the engine.
    assert length(asked()) ==
             length(counted(rows)) + Enum.count(rows, &(&1.skip in ~w(decided forced)))
  end

  test "a ply already analysed is not analysed again", %{tournament: t} do
    game = game(t, @sans)
    :ok = Analysis.run(game.id, engine(), setting())
    asked()

    :ok = Analysis.run(game.id, engine(), setting())
    assert asked() == []
  end

  test "new moves are analysed, the old ones are left alone", %{tournament: t} do
    sans = random_sans(44, 3)
    {first, rest} = Enum.split(sans, 40)
    game = game(t, first)
    :ok = Analysis.run(game.id, engine(), setting())
    asked()

    game = more(game, rest)
    :ok = Analysis.run(game.id, engine(), setting())

    assert asked() |> Enum.map(&elem(&1, 0)) |> Enum.all?(&(&1 >= 40))
    assert length(rows(game)) == 44
  end

  test "another engine, bench or node count redoes the work", %{tournament: t} do
    game = game(t, @sans)
    :ok = Analysis.run(game.id, engine(), setting())
    asked()

    :ok = Analysis.run(game.id, engine(), setting(%{nodes: 500_000}))
    assert asked() != []
    assert rows(game) |> Enum.all?(&(&1.nodes == 500_000))
  end

  test "a rewritten ply invalidates its row and the rows after it", %{tournament: t} do
    game = game(t, @sans)
    :ok = Analysis.run(game.id, engine(), setting())
    asked()

    # The tracker takes back plies 31 on and plays something else from there.
    tail = random_sans(40, 3) |> Enum.take(30)
    {:ok, pos} = Alnasl.Chess.parse_fen(Alnasl.Chess.start_fen())

    after_30 =
      Enum.reduce(tail, pos, fn san, pos ->
        {:ok, move} = Alnasl.Chess.parse_san(pos, san)
        Alnasl.Chess.apply_move(pos, move)
      end)

    other =
      after_30
      |> Alnasl.Chess.legal_moves()
      |> Enum.map(&Alnasl.Chess.san(after_30, &1))
      |> Enum.reject(&(&1 == Enum.at(@sans, 30)))
      |> hd()

    {game, _} =
      Games.apply_event(
        Games.get!(game.id),
        {:correction, 30, [%{san: other, flags: [:rewritten], clock: nil}], :misread},
        System.os_time(:millisecond)
      )

    :ok = Analysis.run(game.id, engine(), setting())

    asked = asked()
    # Nothing before ply 31 was asked again; the new ply 31 was not, either,
    # because the game is not confirmed: a rewritten move waits for the arbiter.
    assert Enum.all?(asked, fn {before, _move} -> before >= 30 end)
    rows = rows(game)
    assert length(rows) == 31
    assert Enum.at(rows, 30).skip == "tracker_rewritten"
    assert Enum.at(rows, 30).san == other

    # The arbiter confirms the result: the rewritten move counts.
    Games.finish(Games.get!(game.id), "1-0")
    :ok = Analysis.run(game.id, engine(), setting())
    assert Enum.at(rows(game), 30).skip in [nil, "decided", "forced", "repetition"]
  end

  test "a reconstructed (orange) ply waits for the game to finish; a guessed one never counts",
       %{tournament: t} do
    {before, last} = Enum.split(@sans, 38)
    game = game(t, before)
    game = more(game, last, [:recovered])

    :ok = Analysis.run(game.id, engine(), setting())

    # The two orange plies are not stored yet.
    assert length(rows(game)) == 38
    refute Enum.any?(asked(), fn {before, _} -> before >= 38 end)

    Games.finish(Games.get!(game.id), "1/2-1/2")
    :ok = Analysis.run(game.id, engine(), setting())
    assert length(rows(game)) == 40
  end

  test "a guessed ply is stored as left out, and so is everything after it", %{tournament: t} do
    {before, rest} = Enum.split(@sans, 30)
    game = game(t, before) |> more(rest, [:guessed])

    :ok = Analysis.run(game.id, engine(), setting())

    rows = rows(game)
    assert length(rows) == 40
    assert rows |> Enum.drop(30) |> Enum.all?(&(&1.skip == "tracker_guessed"))
    refute Enum.any?(asked(), fn {before, _} -> before >= 30 end)
  end

  test "a game without ratings is stored, all of it left out as unrated" do
    Alnasl.Tournaments.update!(Alnasl.Tournaments.default(), %{document: nil})
    game = game(Alnasl.Tournaments.default(), @sans)

    :ok = Analysis.run(game.id, engine(), setting())

    assert rows(game) |> Enum.all?(&(&1.skip == "unrated"))
    assert asked() == []
  end

  test "an engine that fails leaves the ply as not analysed, and it is tried again", %{
    tournament: t
  } do
    game = game(t, @sans)
    broken = fn _position, _played -> {:error, :engine_failed} end
    :ok = Analysis.run(game.id, broken, setting())

    assert Enum.any?(rows(game), &(&1.skip == "no_analysis"))

    :ok = Analysis.run(game.id, engine(), setting())
    refute Enum.any?(rows(game), &(&1.skip == "no_analysis"))
  end
end
