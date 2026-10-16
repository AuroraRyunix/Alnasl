defmodule AlnaslWeb.TeamsAndCodesTest do
  @moduledoc """
  The pages for a team event - the Round page by match, the Setup page's
  tables that keep a match together - and for a code that reaches a
  tournament the box already has.
  """

  use AlnaslWeb.SiteCase

  import Alnasl.LinkHelpers

  alias Alnasl.{FakeOpenPairings, OpenPairings, Tables, Tournaments}
  alias Alnasl.Tournaments.Link

  setup do
    pairing_program()
  end

  defp team_event do
    FakeOpenPairings.add_team_tournament(40, name: "Interclub")
    {:ok, _link, _} = OpenPairings.add_code(FakeOpenPairings.code(40))
    by_remote(40)
  end

  defp finish(event, board, result) do
    pairing = Tournaments.board(event.id, 1, board)

    event.id
    |> Games.ensure(1, board, Games.pairing_attrs(pairing))
    |> Games.finish(result)
  end

  describe "Round: a team event" do
    test "boards stand under their match, with the teams and the score as the boards saw it",
         %{conn: conn} do
      event = team_event()
      {:ok, view, _html} = live(conn, ~p"/t/#{event.id}")

      refute has_element?(view, "#tiles-t#{event.id}")
      assert has_element?(view, "#matches-t#{event.id}")
      assert has_element?(view, "#match-title-t#{event.id}-1", "Match 1: Team 1 - Team 2")
      assert has_element?(view, "#match-title-t#{event.id}-2", "Match 2: Team 3 - Team 4")

      # Match 2's boards, in its board order, under its heading.
      html = render(view)
      [_before, match_two] = String.split(html, ~s(id="match-t#{event.id}-2"), parts: 2)

      positions =
        for n <- 5..8, do: :binary.match(match_two, ~s(id="tile-wrap-t#{event.id}-#{n}"))

      assert Enum.all?(positions, &is_tuple/1)
      assert positions == Enum.sort(positions)

      dom = "t#{event.id}-6"
      assert has_element?(view, "#tile-match-#{dom}", "match 2, board 2")
      assert has_element?(view, "#tile-white-team-#{dom}", "Team 4")
      assert has_element?(view, "#tile-black-team-#{dom}", "Team 3")
      refute has_element?(view, "#match-score-t#{event.id}-2")

      # Board 2 of match 2: Team 4 has White and wins; board 1: a draw.
      finish(event, 6, "1-0")
      finish(event, 5, "1/2-1/2")
      Tournaments.notify(event.id)

      eventually_html(view, fn _ -> has_element?(view, "#match-score-t#{event.id}-2") end)

      assert has_element?(
               view,
               "#match-score-t#{event.id}-2",
               "As the boards saw it: ½ - 1½"
             )

      assert has_element?(view, "#match-score-t#{event.id}-2", "(2 of 4 finished)")
    end

    test "an individual tournament looks as it did", %{conn: conn} do
      open = linked(17, name: "Open", boards: 2)
      {:ok, view, _html} = live(conn, ~p"/t/#{open.id}")
      assert has_element?(view, "#tiles-t#{open.id}")
      refute has_element?(view, "#matches-t#{open.id}")
      refute has_element?(view, "#tile-match-t#{open.id}-1")
    end
  end

  describe "Setup: a team event's tables" do
    test "the form offers to keep each match together, and says how many boards a match has",
         %{conn: conn} do
      event = team_event()
      {:ok, view, _html} = live(conn, ~p"/setup")

      assert has_element?(view, "#tournament-teams-#{event.id}", "4 boards a match")
      assert has_element?(view, "#tables-keep-#{event.id}[checked]")
      assert has_element?(view, "#tables-matches-note")

      view
      |> form("#tables-form-#{event.id}",
        tables: %{from: "1", to: "8", keep_matches: "false"}
      )
      |> render_submit()

      refute Tournaments.get!(event.id).keep_matches
      assert Tournaments.tables(Tournaments.get!(event.id)) == {1, 8}
      refute has_element?(view, "#tables-keep-#{event.id}[checked]")

      open = linked(17, name: "Open", boards: 2)
      {:ok, view, _html} = live(conn, ~p"/setup")
      refute has_element?(view, "#tables-keep-#{open.id}")
    end

    test "the ready list says which match a missing board is in", %{conn: _conn} do
      event = team_event()
      {:ok, _} = Tournaments.assign_tables(event, 1, 8)

      for n <- [1, 2, 4] do
        {:ok, _} = Tables.set_table(fake_dgt("TEAM#{n}"), n)
      end

      sentences =
        event.id
        |> Tables.checks(1)
        |> Enum.map(&elem(AlnaslWeb.TableWords.check(&1), 1))

      assert "Board 3 of the round (match 1, board 3) has no electronic board, though higher boards do." in sentences
      assert "Match 1: 3 of its 4 boards are on electronic boards." in sentences
    end
  end

  describe "Setup: a code for a tournament the box has" do
    test "says so in words, and the new code can take the old one's place", %{conn: conn} do
      FakeOpenPairings.add_tournament(17, name: "Open", boards: 2)
      old_code = FakeOpenPairings.code(17)
      {:ok, old, [open]} = OpenPairings.add_code(old_code)
      FakeOpenPairings.withdraw(old_code)

      {:ok, view, _html} = live(conn, ~p"/setup")

      html =
        view
        |> form("#code-form", link: %{code: FakeOpenPairings.code(17)})
        |> render_submit()

      assert html =~ "This code reaches Open, which this box already has through"
      assert Repo.aggregate(Alnasl.Tournaments.Tournament, :count) == 2

      new = Repo.one!(from l in Link, where: l.id != ^old.id)
      assert has_element?(view, "#link-elsewhere-#{new.id}-17", "already has through")

      view |> element("#use-code-#{new.id}-17") |> render_click()

      assert render(view) =~ "Open is asked through this code from now on"
      assert Tournaments.get!(open.id).link_id == new.id
      refute Repo.get(Link, old.id)
      refute has_element?(view, "#link-elsewhere-#{new.id}-17")
    end
  end
end
