defmodule AlnaslWeb.PlacementsLiveTest do
  @moduledoc """
  Setup -> Tournaments, "Halls and tables": the halls a tournament is
  played in, a hall added (only one the account arbitrates in), a range
  changed, the last hall kept; and a code from a second hall that reaches
  the same tournament offers to play it there as well.
  """

  use AlnaslWeb.SiteCase, async: false

  import AlnaslWeb.AccountHelpers

  alias Alnasl.{Halls, Placements, Tournaments}
  alias Alnasl.Tournaments.Tournament

  setup do
    _owner = first_owner()
    b = hall_fixture("Annex")
    c = hall_fixture("Cellar")
    a = Halls.own()

    open =
      Repo.insert!(%Tournament{kind: "linked", name: "Open", label: "Open", hall_id: a.id})

    {:ok, _} = Tournaments.assign_tables(open, 1, 8, a.id)

    arbiter = user_fixture("arbiter@example.org")
    member(a, arbiter, "arbiter")
    member(b, arbiter, "owner")
    member(c, arbiter, "viewer")

    %{a: a, b: b, c: c, open: Tournaments.get!(open.id), arbiter: arbiter}
  end

  test "a hall is added from the halls the account arbitrates in, and the boards follow on",
       ctx do
    %{conn: conn, a: a, b: b, c: c, open: open, arbiter: arbiter} = ctx
    {:ok, view, _html} = live(log_in(conn, arbiter, a), ~p"/setup")

    assert has_element?(view, "#placement-#{open.id}-#{a.id}")
    assert has_element?(view, "#placement-add-hall-#{open.id} option[value='#{b.id}']")
    refute has_element?(view, "#placement-add-hall-#{open.id} option[value='#{c.id}']")
    refute has_element?(view, "#placement-add-hall-#{open.id} option[value='#{a.id}']")
    # One hall: nothing to remove.
    refute has_element?(view, "#placement-remove-#{open.id}-#{a.id}")

    view
    |> form("#placement-add-#{open.id}", add: %{hall: "#{b.id}"})
    |> render_submit()

    assert %{table_from: 1, table_to: 8, first_board: 9} = Placements.in_hall(open, b.id)
    assert has_element?(view, "#placement-#{open.id}-#{b.id}")
    assert has_element?(view, "#placement-boards-#{open.id}-#{b.id}", "9")
    assert has_element?(view, "#placement-remove-#{open.id}-#{a.id}")

    # The cellar, by a hand-made event: refused.
    render_click(view, "placement_add", %{"t" => "#{open.id}", "hall" => "#{c.id}"})
    assert Placements.in_hall(open, c.id) == nil
  end

  test "a hall's tables are changed; a clash is refused and the last hall stays", ctx do
    %{conn: conn, a: a, b: b, open: open, arbiter: arbiter} = ctx
    {:ok, _, _} = Placements.add(open, b.id)
    {:ok, view, _html} = live(log_in(conn, arbiter, a), ~p"/setup")

    view
    |> form("#placement-form-#{open.id}-#{b.id}",
      place: %{from: "11", to: "18", first: "9"}
    )
    |> render_submit()

    assert %{table_from: 11, table_to: 18, first_board: 9} = Placements.in_hall(open, b.id)

    # Boards 5-12 in the annex: boards 5-8 are the main hall's.
    view
    |> form("#placement-form-#{open.id}-#{b.id}",
      place: %{from: "11", to: "18", first: "5"}
    )
    |> render_submit()

    assert has_element?(view, "#flash-error")
    assert %{first_board: 9} = Placements.in_hall(open, b.id)

    view |> element("#placement-remove-#{open.id}-#{b.id}") |> render_click()
    assert Placements.halls_of(open) == [a.id]
    refute has_element?(view, "#placement-#{open.id}-#{b.id}")

    render_click(view, "placement_remove", %{"t" => "#{open.id}", "hall" => "#{a.id}"})
    assert Placements.halls_of(open) == [a.id]
  end

  test "the annex's code for a tournament the main hall has: play it there as well", ctx do
    %{conn: conn, a: a, b: b, arbiter: arbiter} = ctx
    Alnasl.LinkHelpers.pairing_program()

    Alnasl.FakeOpenPairings.add_tournament(17,
      group: "Festival",
      name: "Festival Open",
      boards: 2
    )

    {:ok, _group, [festival]} =
      Alnasl.OpenPairings.add_code(Alnasl.FakeOpenPairings.group_code("Festival"), a.id)

    {:ok, annex_link, []} =
      Alnasl.OpenPairings.add_code(Alnasl.FakeOpenPairings.code(17), b.id)

    {:ok, view, _html} = live(log_in(conn, arbiter, b), ~p"/setup")
    assert has_element?(view, "#link-elsewhere-#{annex_link.id}-17")
    view |> element("#link-also-here-#{annex_link.id}-17") |> render_click()

    # One tournament, now in both halls; the button has done its job.
    assert Placements.halls_of(festival) == [a.id, b.id]
    assert length(Alnasl.Repo.all(Tournament)) == length(Tournaments.list())
    assert has_element?(view, "#tournament-#{festival.id}")
    refute has_element?(view, "#link-also-here-#{annex_link.id}-17")
  end

  test "the tournament is on the annex's Setup once it is played there", ctx do
    %{conn: conn, b: b, open: open, arbiter: arbiter} = ctx
    {:ok, view, _html} = live(log_in(conn, arbiter, b), ~p"/setup")
    refute has_element?(view, "#tournament-#{open.id}")

    {:ok, _, _} = Placements.add(open, b.id)
    {:ok, view, _html} = live(log_in(build_conn(), arbiter, b), ~p"/setup")
    assert has_element?(view, "#tournament-#{open.id}")
    # Its "tables from" is the annex's range.
    assert has_element?(view, "#tables-from-#{open.id}[value='1']")
  end

  test "an arbiter of the annex only gets the button, and the button works", ctx do
    %{conn: conn, a: a, b: b} = ctx
    Alnasl.LinkHelpers.pairing_program()

    Alnasl.FakeOpenPairings.add_tournament(17,
      group: "Festival",
      name: "Festival Open",
      boards: 2
    )

    {:ok, _group, [festival]} =
      Alnasl.OpenPairings.add_code(Alnasl.FakeOpenPairings.group_code("Festival"), a.id)

    {:ok, annex_link, []} =
      Alnasl.OpenPairings.add_code(Alnasl.FakeOpenPairings.code(17), b.id)

    # No role in the main hall, so none for the tournament: only the code.
    annex = user_fixture("annex@example.org")
    member(b, annex, "arbiter")

    {:ok, view, _html} = live(log_in(conn, annex, b), ~p"/setup")
    view |> element("#link-also-here-#{annex_link.id}-17") |> render_click()

    assert Placements.halls_of(festival) == [a.id, b.id]
    refute has_element?(view, "#flash-error")

    # Without a code of the annex's reaching it, the same event is refused.
    other =
      Repo.insert!(%Tournament{kind: "linked", name: "Other", label: "Other", hall_id: a.id})

    render_click(view, "placement_add", %{"t" => "#{other.id}", "hall" => "#{b.id}"})
    assert Placements.halls_of(other) == [a.id]
  end

  test "an arbiter of the annex standing in the main hall does not seat the annex's tournament there",
       ctx do
    %{conn: conn, a: a, b: b, open: open} = ctx

    blitz =
      Repo.insert!(%Tournament{kind: "linked", name: "Blitz", label: "Blitz", hall_id: b.id})

    {:ok, _} = Tournaments.assign_tables(blitz, 1, 8, b.id)

    user = user_fixture("both@example.org")
    member(a, user, "viewer")
    member(b, user, "arbiter")

    {:ok, view, _html} = live(log_in(conn, user, a), ~p"/setup")

    render_click(view, "assign_tables", %{
      "tables" => %{"id" => "#{blitz.id}", "from" => "1", "to" => "8"}
    })

    render_click(view, "seat_tables", %{
      "seat" => %{"id" => "#{blitz.id}", "from" => "1", "to" => "8"}
    })

    assert has_element?(view, "#flash-error")
    assert Placements.halls_of(Tournaments.get!(blitz.id)) == [b.id]
    assert Tournaments.tables(Tournaments.get!(open.id), a.id) == {1, 8}
  end
end
