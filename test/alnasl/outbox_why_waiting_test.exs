defmodule Alnasl.OutboxWhyWaitingTest do
  @moduledoc """
  Rows that wait must say why. Pending rows of a tournament that is gone, or
  that has no results page, are counted forever and sent never; the page used
  to call that "Waiting" and say nothing more.
  """

  use Alnasl.DataCase, async: false

  alias Alnasl.{FakeIngest, Games, Outbox}
  alias Alnasl.Outbox.Entry
  alias Alnasl.Tournaments.Tournament

  setup do
    start_supervised!(FakeIngest)
    FakeIngest.install()
    on_exit(fn -> Application.delete_env(:alnasl, :req_options) end)
    :ok
  end

  # The row belongs to a real game (the table says so); the tournament it
  # names is whatever the test needs it to be.
  defp row(tournament_id, board \\ 1) do
    game = Games.ensure(1, board, %{white: "W", black: "B"})

    Repo.insert!(%Entry{
      game_id: game.id,
      tournament_id: tournament_id,
      round: 1,
      board_no: board,
      seq: 1,
      plies: 1,
      body: ~s({"moves":["e4"]})
    })
  end

  defp linked_without_page do
    Repo.insert!(%Tournament{kind: "linked", name: "No page", remote_id: 7})
  end

  defp why(report, id), do: Enum.find(report, &(&1.tournament_id == id))

  test "rows of a tournament that is gone are reported as such, and are stuck" do
    row(9_999)
    row(9_999, 2)

    assert %{count: 2, why: :gone} = why(Outbox.waiting_report(), 9_999)
    assert Outbox.pending_count() == 2
    assert Outbox.stuck_count() == 2
    assert Outbox.status().stuck == 2
    # Draining does not touch them, and says nothing of them either.
    assert Outbox.drain() == :empty
    assert Outbox.pending_count() == 2
  end

  test "rows of a tournament with no results page are reported as such" do
    t = linked_without_page()
    row(t.id)

    assert %{count: 1, why: :no_page} = why(Outbox.waiting_report(), t.id)
    assert Outbox.stuck_count() == 1
  end

  test "rows of a tournament that can send are not stuck" do
    Outbox.enqueue(Games.ensure(1, 1, %{white: "W", black: "B"}) |> played(), nil, false)
    id = Alnasl.Tournaments.default_id()

    assert %{count: 1, why: :sending} = why(Outbox.waiting_report(), id)
    assert Outbox.stuck_count() == 0
  end

  defp played(game) do
    {game, _} = Games.apply_event(game, {:moves, [%{san: "e4", flags: [], clock: nil}]}, 1_000)
    game
  end

  test "the hall's scope keeps the report to its own tournaments" do
    row(9_999)
    assert Outbox.waiting_report([]) == []
    assert Outbox.stuck_count([]) == 0
  end

  describe "discarding" do
    test "marks the rows of a gone tournament discarded, and nobody else's" do
      row(9_999)
      other = linked_without_page()
      row(other.id)

      assert {:ok, 1} = Outbox.discard(9_999)
      assert Repo.get_by(Entry, tournament_id: 9_999).state == "discarded"
      assert Repo.get_by(Entry, tournament_id: other.id).state == "pending"
      assert Outbox.pending_count() == 1
    end

    test "rows of a tournament with no results page can be discarded too" do
      t = linked_without_page()
      row(t.id)
      assert {:ok, 1} = Outbox.discard(t.id)
      assert Outbox.pending_count() == 0
    end

    test "rows that could still be sent are never discarded" do
      Outbox.enqueue(Games.ensure(1, 1, %{white: "W", black: "B"}) |> played(), nil, false)
      assert {:error, :has_page} = Outbox.discard(Alnasl.Tournaments.default_id())
      assert Outbox.pending_count() == 1
    end
  end

  describe "going out without a new move" do
    test "rows of a tournament that gets its results page are sent by themselves" do
      start_supervised!(Outbox)
      own_put(server_url: "")
      Outbox.enqueue(Games.ensure(1, 1, %{white: "W", black: "B"}) |> played(), nil, false)
      assert Outbox.pending_count() == 1

      own_put(server_url: "http://results.test")

      Alnasl.HallCase.eventually(fn -> Outbox.pending_count() == 0 end)
      assert FakeIngest.game(1, 1).moves == ~w(e4)
    end
  end
end
