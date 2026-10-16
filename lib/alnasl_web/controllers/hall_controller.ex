defmodule AlnaslWeb.HallController do
  @moduledoc """
  The hall picker: the pages are about one hall at a time, and this says
  which, in the session, then goes back to the page it was asked from
  (`return_to`). A hall the account may not see is not switched to.
  """

  use AlnaslWeb, :controller

  alias Alnasl.Accounts.Scope

  def enter(conn, %{"id" => id} = params) do
    scope = conn.assigns.current_scope

    with {id, ""} <- Integer.parse(id),
         true <- Scope.sees?(scope, id) do
      # Back to the page the picker was opened on, in the other hall. Only a
      # path on this site: a `return_to` is whatever the address says.
      conn
      |> put_session(:hall_id, id)
      |> redirect(to: AlnaslWeb.UserAuth.local_path(params["return_to"]))
    else
      _no ->
        conn
        |> put_flash(:error, gettext("That hall is not one of yours."))
        |> redirect(to: ~p"/halls")
    end
  end
end
