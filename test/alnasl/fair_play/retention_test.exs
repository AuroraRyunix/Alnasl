defmodule Alnasl.FairPlay.RetentionTest do
  use Alnasl.DataCase, async: false

  import AlnaslWeb.AccountHelpers, only: [first_owner: 0]
  import Alnasl.FairPlayFixtures

  alias Alnasl.Accounts
  alias Alnasl.FairPlay
  alias Alnasl.FairPlay.{Analysis, Keep, Move, Retention, View}
  alias Alnasl.Games.Game

  @now ~U[2026-11-20 12:00:00Z]

  defp finished_at(game, at) do
    Repo.update_all(from(g in Game, where: g.id == ^game.id),
      set: [status: "finished", result: "1-0", finished_at: at, updated_at: at]
    )
  end

  defp analysed_game(tournament, round \\ 1, board \\ 1) do
    game = game(tournament, random_sans(24, 5), round: round, board: board)
    :ok = Analysis.run(game.id, engine(), setting())
    game
  end

  defp view(tournament) do
    Repo.insert!(%View{tournament_id: tournament.id, user_email: "a@example.org", at: @now})
  end

  setup do
    %{tournament: rated_tournament()}
  end

  defp day(n), do: DateTime.add(@now, -n * 86_400, :second)

  test "the last round ended is the latest finish of any game", %{tournament: t} do
    a = analysed_game(t, 1, 1)
    b = analysed_game(t, 2, 1)
    finished_at(a, day(40))
    finished_at(b, day(35))

    assert Retention.last_round_end(t.id) == day(35)
  end

  test "a game still being played keeps the tournament young; an old unfinished one does not",
       %{tournament: t} do
    a = analysed_game(t, 1, 1)
    b = analysed_game(t, 2, 1)
    finished_at(a, day(60))
    Repo.update_all(from(g in Game, where: g.id == ^b.id), set: [updated_at: day(2)])

    assert Retention.last_round_end(t.id) == day(2)
    assert %{tournaments: 0} = Retention.purge(@now, 30)
    assert Repo.aggregate(Move, :count) > 0

    Repo.update_all(from(g in Game, where: g.id == ^b.id), set: [updated_at: day(45)])
    assert %{tournaments: 1} = Retention.purge(@now, 30)
    assert Repo.aggregate(Move, :count) == 0
  end

  test "deletes the analysis and the audit rows thirty days after the last round, not before",
       %{tournament: t} do
    game = analysed_game(t)
    view(t)
    finished_at(game, day(29))

    assert %{tournaments: 0, moves: 0, views: 0} = Retention.purge(@now, 30)
    assert Repo.aggregate(Move, :count) > 0
    assert Repo.aggregate(View, :count) == 1

    # Exactly thirty days is not "more than" thirty days.
    finished_at(game, day(30))
    assert %{tournaments: 0} = Retention.purge(@now, 30)

    finished_at(game, DateTime.add(day(30), -1, :second))
    assert %{tournaments: 1, moves: moves, views: 1} = Retention.purge(@now, 30)
    assert moves > 0
    assert Repo.aggregate(Move, :count) == 0
    assert Repo.aggregate(View, :count) == 0
  end

  test "the number of days is the configured one", %{tournament: t} do
    game = analysed_game(t)
    finished_at(game, day(10))

    assert %{tournaments: 0} = Retention.purge(@now, 30)
    assert %{tournaments: 1} = Retention.purge(@now, 7)
  end

  test "the default is thirty days and the environment can change it" do
    assert FairPlay.retention_days() == 30
    Application.put_env(:alnasl, :fair_play_retention_days, 90)
    on_exit(fn -> Application.delete_env(:alnasl, :fair_play_retention_days) end)
    assert FairPlay.retention_days() == 90
  end

  test "a keep in the future stops the deletion; once it has passed, everything goes", %{
    tournament: t
  } do
    game = analysed_game(t)
    view(t)
    finished_at(game, day(100))

    Repo.insert!(%Keep{
      tournament_id: t.id,
      keep_until: DateTime.add(@now, 5 * 86_400, :second),
      reason: "sent to the FPL"
    })

    assert %{tournaments: 0} = Retention.purge(@now, 30)
    assert Repo.aggregate(Move, :count) > 0

    later = DateTime.add(@now, 6 * 86_400, :second)
    assert %{tournaments: 1} = Retention.purge(later, 30)
    assert Repo.aggregate(Move, :count) == 0
    assert Repo.aggregate(Keep, :count) == 0
  end

  test "rows of games that are gone, and of tournaments with no games, are deleted", %{
    tournament: t
  } do
    game = analysed_game(t)
    Repo.delete!(game)

    assert %{moves: moves} = Retention.purge(@now, 30)
    assert moves > 0
    assert Repo.aggregate(Move, :count) == 0
  end

  describe "the owner's extension" do
    setup %{tournament: t} do
      owner = first_owner()
      scope = Accounts.scope(owner, Alnasl.Halls.own_id())
      game = analysed_game(t)
      finished_at(game, day(10))
      %{scope: scope}
    end

    test "counts from the last round, needs a reason, and stops at 365 days", %{
      scope: scope,
      tournament: t
    } do
      assert {:error, :reason} = FairPlay.extend(scope, t, 90, "  ")
      assert {:error, :too_long} = FairPlay.extend(scope, t, 366, "FPL case")
      assert {:error, :days} = FairPlay.extend(scope, t, 0, "FPL case")

      assert {:ok, keep} = FairPlay.extend(scope, t, 365, "FPL case 2026-11")
      assert keep.keep_until == DateTime.add(day(10), 365 * 86_400, :second)
      assert keep.set_by == "owner@example.org"

      # Extending again replaces it.
      assert {:ok, again} = FairPlay.extend(scope, t, 100, "narrower")
      assert again.id == keep.id
      assert Repo.aggregate(Keep, :count) == 1
    end

    test "a kept tournament survives the purge", %{scope: scope, tournament: t} do
      assert {:ok, _} = FairPlay.extend(scope, t, 120, "FPL case")
      assert %{tournaments: 0} = Retention.purge(DateTime.add(day(10), 60 * 86_400), 30)
      assert Repo.aggregate(Move, :count) > 0
    end
  end
end
