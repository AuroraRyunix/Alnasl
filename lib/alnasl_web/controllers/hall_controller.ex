defmodule AlnaslWeb.HallController do
  @moduledoc """
  The hall switcher: the pages are about one hall at a time, and this says
  which, in the session. A hall the account may not see is not switched to.
  """

  use AlnaslWeb, :controller

  alias Alnasl.Accounts.Scope

  def enter(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    with {id, ""} <- Integer.parse(id),
         true <- Scope.sees?(scope, id) do
      conn |> put_session(:hall_id, id) |> redirect(to: ~p"/")
    else
      _no ->
        conn
        |> put_flash(:error, gettext("That hall is not one of yours."))
        |> redirect(to: ~p"/halls")
    end
  end
end
