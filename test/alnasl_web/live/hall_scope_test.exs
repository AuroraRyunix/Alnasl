defmodule AlnaslWeb.HallScopeTest do
  @moduledoc """
  Every page reads the current hall: an account in two halls, looking at
  one of them, sees that hall's log lines, recordings, queue, boards and
  walk - and the other's only when it asks for "all my halls". Lists have an
  end: fifty a page, and a search.
  """

  use AlnaslWeb.SiteCase, async: false

  @moduletag :capture_log

  import AlnaslWeb.AccountHelpers

  alias Alnasl.{Accounts, Boards, Finder, Halls, Log, Outbox, Repo, Tournaments}
  alias Alnasl.Outbox.Entry

  defp remote_board(hall, name) do
    {:ok, board} =
      Boards.create(%{name: name, driver: "remote", port: "bridge-0:#{name}", hall_id: hall.id})

    board
  end

  defp capture(board, name) do
    dir = Path.join(Alnasl.Paths.captures(), "board-#{board.id}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, name), ~s({"t":0,"k":"note","text":"x"}\n))
  end

  defp entry(tournament, board_no, state \\ "pending") do
    game =
      Repo.insert!(%Alnasl.Games.Game{tournament_id: tournament.id, round: 1, board_no: board_no})

    Repo.insert!(%Entry{
      game_id: game.id,
      tournament_id: tournament.id,
      round: 1,
      board_no: board_no,
      seq: board_no,
      body: Jason.encode!(%{"status" => "live", "moves" => []}),
      state: state
    })
  end

  # How many rows a page draws, and how many the pager says there are.
  defp rows(view, marker), do: view |> render() |> String.split(marker) |> length() |> Kernel.-(1)

  defp total(view) do
    [_, n] = Regex.run(~r/\((\d+) in all\)/, view |> render())
    String.to_integer(n)
  end

  setup do
    _admin = first_owner()
    a = hall_fixture("Hall A")
    b = hall_fixture("Hall B")
    user = user_fixture("both@example.org")
    member(a, user, "arbiter")
    member(b, user, "arbiter")
    Finder.reset()

    %{a: a, b: b, user: user, a1: remote_board(a, "A-1"), b1: remote_board(b, "B-1")}
  end

  describe "the log" do
    test "this hall by default, every hall of the account on request", ctx do
      %{conn: conn, user: user, a: a, a1: a1, b1: b1} = ctx
      one = Log.add(:info, "board.connected", %{}, %{board_id: a1.id})
      two = Log.add(:info, "board.connected", %{}, %{board_id: b1.id})

      {:ok, view, _html} = live(log_in(conn, user, a), ~p"/log")
      assert has_element?(view, "#events-#{one.id}")
      refute has_element?(view, "#events-#{two.id}")

      view |> form("#log-filter", filter: %{all: "1"}) |> render_change()
      assert has_element?(view, "#events-#{one.id}")
      assert has_element?(view, "#events-#{two.id}")

      view |> form("#log-filter", filter: %{all: ""}) |> render_change()
      refute has_element?(view, "#events-#{two.id}")
    end

    test "fifty a page, and a search", ctx do
      %{conn: conn, user: user, a: a, a1: a1} = ctx
      Log.add(:warn, "board.disconnected", %{}, %{board_id: a1.id})
      for _n <- 1..59, do: Log.add(:info, "board.connected", %{}, %{board_id: a1.id})

      {:ok, view, _html} = live(log_in(conn, user, a), ~p"/log")
      assert has_element?(view, "#log-pager-where", "1 of 2")
      assert view |> render() |> String.split("<li id=\"events-") |> length() == 51

      view |> element("#log-pager-next") |> render_click()
      assert has_element?(view, "#log-pager-where", "2 of 2")
      assert rows(view, "<li id=\"events-") == total(view) - 50

      # A search finds across the pages and ends the paging when it is short.
      view |> form("#log-filter", filter: %{q: "stopped answering"}) |> render_change()
      refute has_element?(view, "#log-pager")
      assert view |> render() |> String.split("<li id=\"events-") |> length() == 2
    end
  end

  describe "the recordings" do
    test "this hall by default, all halls on request", ctx do
      %{conn: conn, user: user, a: a, a1: a1, b1: b1} = ctx
      capture(a1, "2026-01-01.jsonl")
      capture(b1, "2026-01-02.jsonl")

      {:ok, view, _html} = live(log_in(conn, user, a), ~p"/recordings")
      assert has_element?(view, "#capture-#{a1.id}-2026-01-01")
      refute has_element?(view, "#capture-#{b1.id}-2026-01-02")

      view |> form("#captures-filter", filter: %{all: "1"}) |> render_change()
      assert has_element?(view, "#capture-#{b1.id}-2026-01-02")
    end

    test "fifty a page, and a search", ctx do
      %{conn: conn, user: user, a: a, a1: a1} = ctx
      for n <- 1..55, do: capture(a1, "run-#{String.pad_leading("#{n}", 2, "0")}.jsonl")

      {:ok, view, _html} = live(log_in(conn, user, a), ~p"/recordings")
      assert has_element?(view, "#captures-pager-where", "1 of 2")
      assert render(view) |> String.split("<tr id=\"capture-") |> length() == 51

      view |> element("#captures-pager-next") |> render_click()
      assert rows(view, "<tr id=\"capture-") == total(view) - 50

      view |> form("#captures-filter", filter: %{q: "run-07"}) |> render_change()
      refute has_element?(view, "#captures-pager")
      assert has_element?(view, "#capture-#{a1.id}-run-07")
      assert render(view) |> String.split("<tr id=\"capture-") |> length() == 2
    end
  end

  describe "the outbox" do
    test "counts and lists are this hall's", ctx do
      %{conn: conn, user: user, a: a, b: b} = ctx
      ta = Halls.local_tournament(a)
      tb = Halls.local_tournament(b)
      mine = entry(ta, 1)
      for n <- 2..4, do: entry(tb, n)

      scope = Accounts.scope(user, a.id)
      assert Outbox.status(scope).pending == 1
      assert Outbox.status(Accounts.scope(user, b.id)).pending == 3
      assert Outbox.status().pending == 4
      assert Halls.tournament_ids(scope) == [ta.id]

      {:ok, view, _html} = live(log_in(conn, user, a), ~p"/outbox")
      assert has_element?(view, "#waiting-count", "1")
      assert has_element?(view, "#waiting-table-#{mine.id}")
      assert render(view) |> String.split("<tr id=\"waiting-table-") |> length() == 2
    end
  end

  describe "walk" do
    test "which board is this? knows only this hall's boards", ctx do
      %{conn: conn, user: user, a: a, a1: a1, b1: b1} = ctx
      Finder.touch(a1.id, 1_000)
      Finder.touch(b1.id, 2_000)
      _ = Finder.state()

      {:ok, view, _html} = live(log_in(conn, user, a), ~p"/boards/find")
      assert has_element?(view, "#walk-found", "A-1")
      refute has_element?(view, "#walk-found", "B-1")
    end

    test "a run keeps to its hall: another hall's board is not numbered", ctx do
      %{a: a, a1: a1, b1: b1} = ctx
      a2 = remote_board(a, "A-2")
      Finder.start_wizard(1, a.id)

      Finder.touch(b1.id)
      _ = Finder.state()
      assert Boards.get(b1.id).table_no == nil
      assert %{wizard: %{next: 1}} = Finder.state()

      Finder.touch(a1.id)
      Finder.touch(a2.id)
      _ = Finder.state()
      assert Boards.get(a1.id).table_no == 1
      assert Boards.get(a2.id).table_no == 2
      # Both boards of the hall have a number: the run is over.
      assert Finder.state().wizard == nil
    end

    test "the numbering count is the hall's", ctx do
      %{conn: conn, user: user, a: a} = ctx
      {:ok, view, _html} = live(log_in(conn, user, a), ~p"/boards/number")
      assert has_element?(view, "#walk-count", "0 of 1")
    end
  end

  describe "boards" do
    test "the tournament select offers the tournaments placed here, and the board's own", ctx do
      %{conn: conn, user: user, a: a, b: b, a1: a1} = ctx
      ta = Halls.local_tournament(a)
      tb = Halls.local_tournament(b)

      extra =
        Repo.insert!(%Tournaments.Tournament{
          kind: "linked",
          name: "Open",
          label: "Open",
          hall_id: a.id
        })

      {:ok, _} = Tournaments.assign_tables(extra, 1, 4, a.id)

      {:ok, view, _html} = live(log_in(conn, user, a), ~p"/boards")
      sel = "#tournament-#{a1.id}"
      assert has_element?(view, "#{sel} option[value='#{ta.id}']")
      assert has_element?(view, "#{sel} option[value='#{extra.id}']")
      refute has_element?(view, "#{sel} option[value='#{tb.id}']")
    end
  end

  describe "the halls" do
    test "the list is a table with one row a hall", ctx do
      %{conn: conn, user: user, a: a, b: b} = ctx
      {:ok, view, _html} = live(log_in(conn, user, a), ~p"/halls")

      assert has_element?(view, "table#halls")
      assert has_element?(view, "#hall-#{a.id}-open")
      assert has_element?(view, "#hall-#{b.id}-role")
      assert has_element?(view, "#hall-#{a.id}-boards", "0 of 1")
    end

    test "tabs, each with its own address; an owner's tabs for an owner only", ctx do
      %{conn: conn, user: user, a: a} = ctx
      owner = member(a, user_fixture("hall-owner@example.org"), "owner")

      {:ok, view, _html} = live(log_in(conn, owner, a), ~p"/halls/#{a.id}")
      assert has_element?(view, "#hall-people")
      refute has_element?(view, "#hall-bridges")
      refute has_element?(view, "#hall-invite")

      view |> element("#hall-tab-invitations") |> render_click()
      assert_patch(view, ~p"/halls/#{a.id}/invitations")
      assert has_element?(view, "#hall-invite")
      refute has_element?(view, "#hall-people")

      view |> element("#hall-tab-bridges") |> render_click()
      assert_patch(view, ~p"/halls/#{a.id}/bridges")
      assert has_element?(view, "#hall-bridges")

      view |> element("#hall-tab-settings") |> render_click()
      assert_patch(view, ~p"/halls/#{a.id}/settings")
      assert has_element?(view, "#hall-name-form")
      assert has_element?(view, "#hall-delete-ask")

      # An arbiter has People and Bridges, and an address that is not hers
      # lands on People.
      {:ok, view, _html} = live(log_in(build_conn(), user, a), ~p"/halls/#{a.id}/settings")
      assert has_element?(view, "#hall-people")
      refute has_element?(view, "#hall-tab-settings")
      refute has_element?(view, "#hall-tab-invitations")
      assert has_element?(view, "#hall-tab-bridges")
    end
  end
end
