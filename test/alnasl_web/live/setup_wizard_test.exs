defmodule AlnaslWeb.SetupWizardTest do
  @moduledoc """
  The Setup wizard: the questions first, then the steps for exactly that
  hall, ticked by what is really there - a bridge that connected, boards
  that arrived, a tournament from OpenPairings, numbers on the boards - and
  `/setup` opening on it until every step is done.
  """

  use AlnaslWeb.SiteCase, async: false

  import AlnaslWeb.AccountHelpers

  alias Alnasl.{Halls, Tables, Wizard}
  alias Alnasl.Boards.Board
  alias Alnasl.Bridges.Bridge
  alias Alnasl.Tournaments.Tournament

  defp answer(view, params) do
    view
    |> form("#wizard-form", wizard: params)
    |> render_submit()
  end

  defp linked_tournament(name) do
    Repo.insert!(%Tournament{
      kind: "linked",
      name: name,
      label: name,
      state: "running",
      hall_id: Halls.own_id()
    })
  end

  defp bridge(name, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Bridge{uid: "uid-" <> name, name: name, key_hash: "hash", hall_id: Halls.own_id()},
        attrs
      )
    )
  end

  defp remote_board(name, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Board{name: name, driver: "remote", port: "bridge-1:" <> name, hall_id: Halls.own_id()},
        attrs
      )
    )
  end

  describe "a box" do
    test "/setup asks the questions first, and an unknown section leads there", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")
      assert has_element?(view, "#setup-wizard")
      assert has_element?(view, "#setup-nav-wizard.current")
      assert has_element?(view, "#wizard-form")
      refute has_element?(view, "#wizard-steps")
      # A box in one room is not asked about bridges.
      refute has_element?(view, "#wizard-bridges")
      assert has_element?(view, "#wizard-extra-phone")

      assert {:error, {:live_redirect, %{to: "/setup/wizard"}}} =
               live(conn, "/setup/nothing-here")
    end

    test "the steps follow the answers, and the first one not done is current", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup/wizard")
      answer(view, %{shape: "simple", boards: "2", extras: ["phone"]})

      assert has_element?(view, "#wizard-step-plug.current")
      assert has_element?(view, "#wizard-step-connect")
      assert has_element?(view, "#wizard-step-number")
      assert has_element?(view, "#wizard-step-phone")
      # Not chosen, not there; no bridges on a box in one room.
      refute has_element?(view, "#wizard-step-polis")
      refute has_element?(view, "#wizard-step-arkab")
      refute has_element?(view, "#wizard-step-tables")
      assert has_element?(view, "#wizard-step-plug-go[href='/boards']")

      # The answers are kept, and asked again on request.
      assert %{"shape" => "simple", "boards" => 2} = Wizard.answers(Halls.own_id())
      view |> element("#wizard-change") |> render_click()
      assert has_element?(view, "#wizard-form")
    end

    test "a step is ticked by the boards that are really there", %{conn: conn} do
      Wizard.save(Halls.own_id(), %{"shape" => "simple", "boards" => "1"}, ctx(false))
      {:ok, view, _html} = live(conn, ~p"/setup/wizard")
      refute has_element?(view, "#wizard-step-plug-done")

      fake_dgt("WIZ1")
      {:ok, view, _html} = live(conn, ~p"/setup/wizard")
      assert has_element?(view, "#wizard-step-plug-done")
      assert has_element?(view, "#wizard-step-connect.current")
    end

    test "several rooms bring Arkab and a step per bridge", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup/wizard")
      view |> form("#wizard-form", wizard: %{shape: "halls"}) |> render_change()
      assert has_element?(view, "#wizard-bridges")

      answer(view, %{shape: "halls", bridges: "2", boards: "4"})
      assert has_element?(view, "#wizard-step-arkab")
      assert has_element?(view, "#wizard-step-bridge-1")
      assert has_element?(view, "#wizard-step-bridge-2")
    end

    test "several tournaments ask for their tables", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup/wizard")
      view |> form("#wizard-form", wizard: %{shape: "tournaments"}) |> render_change()
      answer(view, %{shape: "tournaments", tournaments: "2", boards: "4"})
      assert has_element?(view, "#wizard-step-tables")
      assert has_element?(view, "#wizard-step-connect", "0/2")
    end

    test "a print station is marked by hand, and says so", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup/wizard")
      answer(view, %{shape: "simple", boards: "1", extras: ["polis"]})
      refute has_element?(view, "#wizard-step-polis-done")

      view |> element("#wizard-step-polis-mark") |> render_click()
      assert has_element?(view, "#wizard-step-polis-done", "marked done")

      view |> element("#wizard-step-polis-unmark") |> render_click()
      refute has_element?(view, "#wizard-step-polis-done")
    end

    test "once every step is done, /setup opens on Tournaments again", %{conn: conn} do
      Wizard.save(Halls.own_id(), %{"shape" => "simple", "boards" => "1"}, ctx(false))
      linked_tournament("Club Open")
      {:ok, _board} = Tables.set_table(fake_dgt("WIZ2"), 1)

      {:ok, view, _html} = live(conn, ~p"/setup")
      assert has_element?(view, "#setup-tournaments")

      assert {:error, {:live_redirect, %{to: "/setup/tournaments"}}} =
               live(conn, "/setup/nothing-here")

      # The wizard is still there, finished.
      {:ok, view, _html} = live(conn, ~p"/setup/wizard")
      assert has_element?(view, "#wizard-complete")
    end
  end

  describe "the server" do
    setup %{conn: conn} do
      owner = first_owner()
      server_mode()
      %{conn: log_in(conn, owner)}
    end

    test "This server names Arkab and leads to the wizard", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup/this-box")
      assert has_element?(view, "#about-edition", "Arkab")
      assert has_element?(view, "#about-edition-wizard[href='/setup/wizard']")
    end

    test "the steps are Arkab, a bridge each, then the boards from them", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")
      assert has_element?(view, "#wizard-bridges")
      refute has_element?(view, "#wizard-extra-phone")

      answer(view, %{shape: "simple", bridges: "2", boards: "1", extras: ["results"]})

      assert has_element?(view, "#wizard-step-arkab.current")

      assert has_element?(
               view,
               "#wizard-step-arkab-go[href='https://github.com/teapot-chess/Arkab/releases/latest']"
             )

      assert has_element?(view, "#wizard-step-bridge-1", "1 of 2")
      assert has_element?(view, "#wizard-step-bridge-2")
      assert has_element?(view, "#wizard-step-boards", "0/2")
      hall = Halls.own_id()
      assert has_element?(view, "#wizard-step-bridge-1-go[href='/halls/#{hall}/bridges']")
      refute has_element?(view, "#wizard-step-plug")
    end

    test "a bridge that has connected ticks Arkab and its own step", %{conn: conn} do
      Wizard.save(Halls.own_id(), %{"shape" => "simple", "bridges" => "2"}, ctx(true))
      bridge("Pi", %{last_connected_at: DateTime.utc_now(:second)})
      bridge("Second")
      remote_board("a1")

      {:ok, view, _html} = live(conn, ~p"/setup/wizard")
      assert has_element?(view, "#wizard-step-arkab-done")
      assert has_element?(view, "#wizard-step-bridge-1-done")
      # Connected once, not now: still done, and says so.
      assert has_element?(view, "#wizard-step-bridge-1-offline")
      # Joined, never connected.
      refute has_element?(view, "#wizard-step-bridge-2-done")
      assert has_element?(view, "#wizard-step-bridge-2.current", "Second")
    end

    test "an arbiter sees the ticks, not the owner's buttons", %{conn: _conn} do
      hall = hall_fixture("Annex")
      arbiter = member(hall, user_fixture("arbiter@example.org"), "arbiter")
      Wizard.save(hall.id, %{"shape" => "simple", "bridges" => "1"}, ctx(true, false))

      {:ok, view, _html} = live(log_in(build_conn(), arbiter, hall), ~p"/setup/wizard")
      assert has_element?(view, "#wizard-step-bridge-1-who")
      refute has_element?(view, "#wizard-step-bridge-1-go")
      refute has_element?(view, "#wizard-change")

      render_hook(view, "save_wizard", %{"wizard" => %{"shape" => "halls"}})
      assert Wizard.answers(hall.id)["shape"] == "simple"
    end
  end

  defp ctx(server?, own_hall? \\ true), do: %{server?: server?, own_hall?: own_hall?, lan?: false}
end
