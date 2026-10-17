defmodule AlnaslWeb.DeleteHallTest do
  @moduledoc """
  Deleting a hall: its owner or an admin, never the box's own hall, never
  while bridges or tournaments are left in it, and only after its name was
  typed. People, invitations and boards go with it.
  """

  use AlnaslWeb.SiteCase, async: false

  @moduletag :capture_log

  import AlnaslWeb.AccountHelpers

  alias Alnasl.{Accounts, Boards, Bridges, Halls, Repo}
  alias Alnasl.Accounts.{Invitation, Scope}
  alias Alnasl.Bridges.Join
  alias Alnasl.Halls.Member
  alias Alnasl.Tournaments.{Link, Tournament}

  setup do
    admin = first_owner()
    hall = hall_fixture("Annex")
    owner = member(hall, user_fixture("annex-owner@example.org"), "owner")
    %{admin: admin, hall: hall, owner: owner}
  end

  defp scope(user, hall), do: Accounts.scope(user, hall.id)

  defp open_dialog(conn, user, hall) do
    {:ok, view, _html} = live(log_in(conn, user, hall), ~p"/halls/#{hall.id}/settings")
    view |> element("#hall-delete-ask") |> render_click()
    view
  end

  test "an owner deletes an empty hall, and everything of it goes", ctx do
    %{hall: hall, owner: owner, admin: admin} = ctx
    other = member(hall, user_fixture("viewer@example.org"), "viewer")
    {:ok, board} = Boards.create(%{name: "A-1", driver: "remote", port: "b:1", hall_id: hall.id})
    {:ok, join} = Bridges.create_join(DateTime.utc_now(:second), hall.id)
    {:ok, _token} = Accounts.invite(scope(admin, hall), hall, "new@example.org", "viewer")

    assert {:ok, _} = Halls.delete(scope(owner, hall), hall)

    assert Halls.get(hall.id) == nil
    assert Boards.get(board.id) == nil
    assert Repo.get(Join, join.id) == nil
    assert Repo.aggregate(from(m in Member, where: m.hall_id == ^hall.id), :count) == 0
    assert Repo.aggregate(from(i in Invitation, where: i.hall_id == ^hall.id), :count) == 0
    assert Repo.aggregate(from(t in Tournament, where: t.hall_id == ^hall.id), :count) == 0
    assert Accounts.get_user(other.id)
  end

  test "an admin who is not a member may delete it", %{admin: admin, hall: hall} do
    assert {:ok, _} = Halls.delete(scope(admin, hall), hall)
  end

  test "an arbiter or a stranger may not", %{hall: hall} do
    arbiter = member(hall, user_fixture("arb@example.org"), "arbiter")
    stranger = user_fixture("stranger@example.org")

    assert {:error, :forbidden} = Halls.delete(scope(arbiter, hall), hall)
    assert {:error, :forbidden} = Halls.delete(scope(stranger, hall), hall)
    assert Halls.get(hall.id)
  end

  test "the box's own hall is refused", %{admin: admin} do
    own = Halls.own()
    assert {:error, :own} = Halls.delete(scope(admin, own), own)
    assert Halls.get(own.id)
  end

  test "bridges and tournaments keep a hall, and the page names them", ctx do
    %{hall: hall, owner: owner, conn: conn} = ctx

    for uid <- ~w(one two) do
      {:ok, join} = Bridges.create_join(DateTime.utc_now(:second), hall.id)

      {:ok, _} =
        Bridges.redeem(join.code, %{
          "v" => 1,
          "bridge" => uid,
          "name" => uid,
          "software" => "arkab"
        })
    end

    Repo.insert!(%Tournament{kind: "remote", hall_id: hall.id, name: "Open"})

    assert {:error, {:not_empty, %{bridges: 2, tournaments: 1, links: 0}}} =
             Halls.delete(scope(owner, hall), hall)

    view = open_dialog(conn, owner, hall)

    view
    |> form("#hall-delete-form", %{"name" => hall.name})
    |> render_submit()

    assert render(view) =~ "2 bridges and 1 tournament"
    assert Halls.get(hall.id)
  end

  test "a connection that brings tournaments keeps the hall too", %{hall: hall, owner: owner} do
    Repo.insert!(%Link{hall_id: hall.id, root: "http://op.example", secret: "s"})

    assert {:error, {:not_empty, %{links: 1}}} = Halls.delete(scope(owner, hall), hall)
  end

  test "another hall's tournament played here keeps the hall", %{hall: hall, owner: owner} do
    t = Repo.insert!(%Tournament{kind: "remote", hall_id: Halls.own_id(), name: "Open"})

    Repo.insert!(%Alnasl.Tournaments.Placement{
      tournament_id: t.id,
      hall_id: hall.id,
      first_board: 9
    })

    assert {:error, {:not_empty, %{tournaments: 1}}} = Halls.delete(scope(owner, hall), hall)
    assert Halls.get(hall.id)
  end

  test "the name has to be typed before the button works", ctx do
    %{hall: hall, owner: owner, conn: conn} = ctx
    view = open_dialog(conn, owner, hall)

    assert has_element?(view, "#hall-delete-submit[disabled]")

    view |> form("#hall-delete-form", %{"name" => "Anne"}) |> render_change()
    assert has_element?(view, "#hall-delete-submit[disabled]")

    # A forged submit with the wrong name changes nothing.
    render_submit(view, "delete_hall", %{"name" => "Anne"})
    assert Halls.get(hall.id)

    view |> form("#hall-delete-form", %{"name" => hall.name}) |> render_change()
    refute has_element?(view, "#hall-delete-submit[disabled]")

    view |> form("#hall-delete-form", %{"name" => hall.name}) |> render_submit()
    assert_redirect(view, ~p"/halls")
    assert Halls.get(hall.id) == nil
  end

  test "no button on the own hall, nor for an arbiter", %{conn: conn, admin: admin, hall: hall} do
    own = Halls.own()
    {:ok, view, _html} = live(log_in(conn, admin, own), ~p"/halls/#{own.id}/settings")
    refute has_element?(view, "#hall-delete")

    arbiter = member(hall, user_fixture("arb@example.org"), "arbiter")
    {:ok, view, _html} = live(log_in(build_conn(), arbiter, hall), ~p"/halls/#{hall.id}")
    refute has_element?(view, "#hall-delete")
  end

  test "whoever was in it lands on another hall of theirs", %{conn: conn, hall: hall} do
    own = Halls.own()
    both = member(hall, member(own, user_fixture("both@example.org"), "viewer"), "owner")

    assert Scope.hall_id(scope(both, hall)) == hall.id
    {:ok, _} = Halls.delete(scope(both, hall), hall)
    assert Scope.hall_id(scope(both, hall)) == own.id

    # The session still says the deleted hall; the page shows the other.
    {:ok, _view, html} = live(log_in(conn, both, hall), ~p"/halls")
    assert html =~ own.name
  end

  test "an open page of the hall is sent away when it is deleted", ctx do
    %{hall: hall, owner: owner, admin: admin, conn: conn} = ctx
    {:ok, view, _html} = live(log_in(conn, owner, hall), ~p"/halls/#{hall.id}")

    {:ok, _} = Halls.delete(scope(admin, hall), hall)
    assert_redirect(view, ~p"/halls")
  end
end
