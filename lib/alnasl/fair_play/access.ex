defmodule Alnasl.FairPlay.Access do
  @moduledoc """
  Who may see anything of fair-play screening: its settings, its reports,
  its player pages, the engine's installation. The hall's **owner**, and
  nobody else (`docs/plan-fair-play.md`, section 2).

  This is deliberately not `Alnasl.Accounts.Scope.role/2`. That gives the
  hosted service's admin the role "owner" in every hall, which is right for
  running the service and wrong here: a report on somebody else's hall's
  players is not the operator's business. So the question is asked of the
  scope's real memberships (`roles`) and of nothing else:

    * an account that is a member of the hall with the role "owner": yes
      (an admin who really is the hall's owner included);
    * an admin who is not a member of the hall: no;
    * an arbiter or a viewer: no;
    * the owner of another hall: no;
    * a box with no accounts (`open?`, nobody signs in, the hall's own
      network): yes, as everywhere else in Alnasl, nobody there being
      anybody's guest.

  Every door - the pages, their events, the context functions that change
  something - asks this and nothing else.
  """

  alias Alnasl.Accounts.Scope

  @doc "May the scope see and change fair play in hall `hall_id`?"
  @spec owner?(%Scope{} | nil, integer() | nil) :: boolean()
  def owner?(%Scope{open?: true}, hall_id) when is_integer(hall_id), do: true

  def owner?(%Scope{roles: roles}, hall_id) when is_integer(hall_id) and is_map(roles),
    do: Map.get(roles, hall_id) == "owner"

  def owner?(_scope, _hall_id), do: false
end
