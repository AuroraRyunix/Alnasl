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
  something - asks this and nothing else. Seeing a report has a second way
  in, a grant from the owner (`Alnasl.FairPlay.Grants`, through
  `Alnasl.FairPlay.can_view?/2`), and only seeing: a grant changes nothing
  of what `owner?/2` answers.
  """

  alias Alnasl.Accounts.Scope

  @doc "May the scope see and change fair play in hall `hall_id`?"
  @spec owner?(%Scope{} | nil, integer() | nil) :: boolean()
  def owner?(%Scope{open?: true}, hall_id) when is_integer(hall_id), do: true

  def owner?(%Scope{roles: roles}, hall_id) when is_integer(hall_id) and is_map(roles),
    do: Map.get(roles, hall_id) == "owner"

  def owner?(_scope, _hall_id), do: false

  @doc """
  Does the scope own at least one hall, so that fair play has a place in its
  menu? The same rule as `owner?/2`, asked of every hall at once: an open
  box, or a real membership with the role "owner". An admin without one
  owns nothing here.
  """
  @spec any_hall?(%Scope{} | nil) :: boolean()
  def any_hall?(%Scope{open?: true}), do: true

  def any_hall?(%Scope{roles: roles}) when is_map(roles),
    do: Enum.any?(roles, fn {_hall_id, role} -> role == "owner" end)

  def any_hall?(_scope), do: false

  @doc """
  Has fair play a place in the scope's menu: it owns a hall (`any_hall?/1`),
  or a report was shared with it and the grant is in force
  (`Alnasl.FairPlay.Grants`, as the scope noted when it was made).
  """
  @spec menu?(%Scope{} | nil) :: boolean()
  def menu?(%Scope{fair_play_shared?: true}), do: true
  def menu?(scope), do: any_hall?(scope)

  @doc "The halls of the scope's own list that it owns, in that list's order."
  @spec halls(%Scope{} | nil) :: [struct()]
  def halls(%Scope{halls: halls} = scope) when is_list(halls),
    do: Enum.filter(halls, &owner?(scope, &1.id))

  def halls(_scope), do: []
end
