defmodule AlnaslWeb.OutboxWhyTest do
  @moduledoc "The Results page says why rows wait, and offers to discard the ones that cannot go."

  use AlnaslWeb.SiteCase

  alias Alnasl.Outbox.Entry
  alias Alnasl.Tournaments.Tournament

  defp stuck_row(tournament_id) do
    game = Games.ensure(Alnasl.Tournaments.default_id(), 1, 1, %{white: "W", black: "B"})

    Repo.insert!(%Entry{
      game_id: game.id,
      tournament_id: tournament_id,
      round: 1,
      board_no: 1,
      seq: 1,
      plies: 1,
      body: ~s({"moves":["e4"]})
    })
  end

  setup do
    t = Repo.insert!(%Tournament{kind: "linked", name: "No page", remote_id: 7})
    stuck_row(t.id)
    stuck_row(t.id)
    %{t: t}
  end

  test "says why, and the headline is not a plain Waiting", %{conn: conn, t: t} do
    {:ok, view, _html} = live(conn, ~p"/outbox")
    assert has_element?(view, "#waiting-why-#{t.id}", "no results page")
    assert has_element?(view, "#waiting-why-#{t.id}", "2 waiting")
    assert has_element?(view, "#dest-state-openresults", "Nothing can be sent")
    refute has_element?(view, "#dest-state-openresults", "Waiting")
  end

  test "discarding is explicit, confirmed and clears the count", %{conn: conn, t: t} do
    {:ok, view, _html} = live(conn, ~p"/outbox")
    assert has_element?(view, "#discard-#{t.id}[data-confirm]")

    view |> element("#discard-#{t.id}") |> render_click()

    assert Outbox.pending_count() == 0
    assert has_element?(view, "#waiting-count", "0")
    refute has_element?(view, "#waiting-why")
  end

  test "nothing is discarded unasked", %{conn: conn} do
    {:ok, _view, _html} = live(conn, ~p"/outbox")
    assert Outbox.pending_count() == 2
  end
end
