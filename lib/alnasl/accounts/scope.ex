defmodule Alnasl.Accounts.Scope do
  @moduledoc """
  Who is asking, and where: what every page and every context function
  that lists or changes something is given first.

  * `user` - the account, or `nil` on a box with no accounts (open mode,
    `open?`), where everybody on the hall's network is the owner of
    everything, as before there were accounts.
  * `admin?` - everything, every hall: the box's first account, and the
    addresses the deployment names in `ALNASL_ADMIN_EMAILS`.
  * `roles` - `%{hall_id => "owner" | "arbiter" | "viewer"}`.
  * `halls` - the halls the account may see; `hall` the one the pages are
    about now (the switcher at the top).
  * `fair_play_shared?` - somebody shared a fair-play report with the
    account, and the grant is in force (`Alnasl.FairPlay.Grants`): what
    puts fair play in the menu of an account that owns no hall. Worked out
    once when the scope is made, not on every page drawn.
  * `tour` - the guided tour on this page, `%{state, run}`, put here by
    `AlnaslWeb.Hall` (`AlnaslWeb.Tour`): what became of it, and how often
    it was started on this page. `nil` outside the site's pages.
  """

  alias Alnasl.Halls.Hall

  defstruct user: nil,
            admin?: false,
            open?: false,
            roles: %{},
            halls: [],
            hall: nil,
            fair_play_shared?: false,
            tour: nil

  @rank %{"viewer" => 1, "arbiter" => 2, "owner" => 3}

  @doc "The role in `hall_id`: everything for an admin and in open mode, `nil` for a hall not one's own."
  def role(%__MODULE__{open?: true}, _hall_id), do: "owner"
  def role(%__MODULE__{admin?: true}, _hall_id), do: "owner"
  def role(%__MODULE__{roles: roles}, hall_id), do: Map.get(roles, hall_id)
  def role(nil, _hall_id), do: nil

  @doc """
  May the scope do what needs `need` in `hall_id`? `need` is `:viewer`,
  `:arbiter`, `:owner` or `:admin` (the box itself: its PIN, its updates,
  its network, every hall).
  """
  def can?(scope, need, hall_id \\ :current)

  def can?(%__MODULE__{} = scope, :admin, _hall_id), do: scope.open? or scope.admin?

  def can?(%__MODULE__{} = scope, need, :current), do: can?(scope, need, hall_id(scope))

  def can?(%__MODULE__{} = scope, need, hall_id) when need in [:viewer, :arbiter, :owner] do
    case role(scope, hall_id) do
      nil -> false
      role -> @rank[role] >= @rank[Atom.to_string(need)]
    end
  end

  def can?(_scope, _need, _hall_id), do: false

  @doc "Does the scope see everything (no account to scope by, or an admin)?"
  def everything?(%__MODULE__{open?: open?, admin?: admin?}), do: open? or admin?
  def everything?(_none), do: false

  @doc "May the scope see hall `hall_id` at all?"
  def sees?(%__MODULE__{} = scope, hall_id), do: role(scope, hall_id) != nil
  def sees?(_none, _hall_id), do: false

  @doc "The hall the pages are about now."
  def hall_id(%__MODULE__{hall: %Hall{id: id}}), do: id
  def hall_id(_scope), do: nil

  @doc "The ids of every hall the scope may see."
  def hall_ids(%__MODULE__{halls: halls}), do: Enum.map(halls, & &1.id)
  def hall_ids(_none), do: []
end
