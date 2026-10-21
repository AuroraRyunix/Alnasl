defmodule AlnaslWeb.TourTest do
  @moduledoc """
  The guided tour: offered once and never forced, remembered when it is
  dismissed, started or finished (per account, or per box without accounts),
  always to be had again from the account menu, and only the steps a role
  can use - fair play for the hall's owner alone.
  """

  use AlnaslWeb.SiteCase, async: false

  import AlnaslWeb.AccountHelpers

  alias Alnasl.{Accounts, Repo, Settings}
  alias Alnasl.Accounts.User
  alias AlnaslWeb.Tour

  @everything ~w(places wizard bridges connections tournaments boards numbering ready live results fair_play help)
  @arbiter ~w(places connections tournaments boards numbering ready live results help)
  @viewer ~w(places boards ready live results help)

  defp who(role, fair_play? \\ false), do: %{role: role, fair_play?: fair_play?, hall_id: 7}

  defp step_ids(view) do
    for key <- @everything, has_element?(view, "#tour-step-#{key}"), do: key
  end

  describe "the steps, as a pure function" do
    test "each role gets the steps for the pages it can use, in order" do
      assert Tour.keys(who("owner", true)) == @everything
      assert Tour.keys(who("owner", false)) == @everything -- ["fair_play"]
      assert Tour.keys(who("arbiter")) == @arbiter
      assert Tour.keys(who("viewer")) == @viewer
      assert Tour.keys(who(nil)) == []
    end

    test "fair play follows fair play's own rule, not the role" do
      # An arbiter is never shown fair play, even if somebody said yes.
      refute "fair_play" in Tour.keys(who("arbiter", true))
      refute "fair_play" in Tour.keys(who("owner", false))
    end

    test "the bridges step goes to the hall on show" do
      assert %{path: "/halls/7/bridges"} =
               Enum.find(Tour.steps(who("owner")), &(&1.key == "bridges"))
    end

    test "every step's manual section exists, in English and Dutch" do
      for step <- Tour.steps(who("owner", true)), locale <- ["en", "nl"] do
        ["/help/" <> slug, anchor] = String.split(step.manual, "#")
        chapter = Alnasl.Manual.get(slug, locale)
        assert chapter, "#{step.key}: no chapter #{slug}"

        assert Enum.any?(chapter.sections, &(&1.id == anchor)),
               "#{step.key}: no section #{anchor} in #{slug} (#{locale})"
      end
    end

    test "every step points at something and says something" do
      for step <- Tour.steps(who("owner", true)) do
        assert step.anchor != []
        assert step.title != "" and step.body != ""
        assert String.starts_with?(step.path, "/")
      end
    end
  end

  describe "a box without accounts" do
    test "the tour is offered on the first visit, with every step", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#tour-offer")
      assert has_element?(view, "#tour-offer-start")
      assert has_element?(view, "#tour-offer-dismiss")
      assert has_element?(view, "#tour[data-run='0']")
      assert step_ids(view) == @everything
      assert has_element?(view, "#account-menu #tour-start")
    end

    test "Not now is remembered: no offer on the next page, the menu still has it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#tour-offer-dismiss") |> render_click()
      refute has_element?(view, "#tour-offer")
      assert Settings.get("tour") == "dismissed"

      {:ok, view, _html} = live(conn, ~p"/boards")
      refute has_element?(view, "#tour-offer")
      assert has_element?(view, "#tour-start")
    end

    test "Take the tour starts it, and it is not offered again", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#tour-offer-start") |> render_click()
      refute has_element?(view, "#tour-offer")
      assert has_element?(view, "#tour[data-run='1']")
      assert Settings.get("tour") == "started"

      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "#tour-offer")
    end

    test "finishing is remembered, and a later skip does not undo it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#tour-offer-start") |> render_click()
      view |> element("#tour") |> render_hook("tour_finish", %{})
      assert Settings.get("tour") == "finished"

      view |> element("#tour") |> render_hook("tour_dismiss", %{})
      assert Settings.get("tour") == "finished"
    end

    test "restarting from the account menu, after it was finished", %{conn: conn} do
      Settings.put("tour", "finished")
      {:ok, view, _html} = live(conn, ~p"/help")

      refute has_element?(view, "#tour-offer")
      view |> element("#tour-start") |> render_click()
      assert has_element?(view, "#tour[data-run='1']")
      view |> element("#tour-start") |> render_click()
      assert has_element?(view, "#tour[data-run='2']")
      assert Settings.get("tour") == "finished"
    end
  end

  describe "with accounts" do
    setup do
      first = first_owner()
      hall = hall_fixture("Hall A")

      %{
        first: first,
        hall: hall,
        owner: member(hall, user_fixture("owner-a@example.org"), "owner"),
        arbiter: member(hall, user_fixture("arbiter-a@example.org"), "arbiter"),
        viewer: member(hall, user_fixture("viewer-a@example.org"), "viewer"),
        operator: user_fixture("operator@example.org", %{admin: true})
      }
    end

    test "each role sees its own steps", ctx do
      for {user, keys} <- [
            {ctx.owner, @everything},
            {ctx.arbiter, @arbiter},
            {ctx.viewer, @viewer},
            # The operator runs every hall, and owns none of its players.
            {ctx.operator, @everything -- ["fair_play"]}
          ] do
        {:ok, view, _html} = live(log_in(ctx.conn, user, ctx.hall), ~p"/")
        assert step_ids(view) == keys, "#{user.email}"
      end
    end

    test "the bridges step leads to the hall on show", ctx do
      {:ok, view, _html} = live(log_in(ctx.conn, ctx.owner, ctx.hall), ~p"/")
      assert has_element?(view, "#tour-step-bridges[data-path='/halls/#{ctx.hall.id}/bridges']")
    end

    test "offered once per account: one person's answer is not another's", ctx do
      {:ok, view, _html} = live(log_in(ctx.conn, ctx.viewer, ctx.hall), ~p"/")
      assert has_element?(view, "#tour-offer")
      view |> element("#tour-offer-dismiss") |> render_click()
      assert Repo.get!(User, ctx.viewer.id).tour == "dismissed"

      {:ok, view, _html} = live(log_in(ctx.conn, ctx.viewer, ctx.hall), ~p"/boards")
      refute has_element?(view, "#tour-offer")
      assert has_element?(view, "#tour-start")

      # The arbiter was never asked.
      {:ok, view, _html} = live(log_in(ctx.conn, ctx.arbiter, ctx.hall), ~p"/")
      assert has_element?(view, "#tour-offer")
      assert Settings.get("tour") == nil
    end

    test "a viewer may start, skip and finish it: it changes nothing of the hall's", ctx do
      {:ok, view, _html} = live(log_in(ctx.conn, ctx.viewer, ctx.hall), ~p"/")

      view |> element("#tour-offer-start") |> render_click()
      assert has_element?(view, "#tour[data-run='1']")
      assert Repo.get!(User, ctx.viewer.id).tour == "started"

      view |> element("#tour") |> render_hook("tour_finish", %{})
      assert Repo.get!(User, ctx.viewer.id).tour == "finished"
    end

    test "an account that finished it is not offered it again", ctx do
      {:ok, _user} = Accounts.set_tour(ctx.owner, "finished")
      {:ok, view, _html} = live(log_in(ctx.conn, ctx.owner, ctx.hall), ~p"/")
      refute has_element?(view, "#tour-offer")
      assert has_element?(view, "#tour-start")
    end
  end
end
