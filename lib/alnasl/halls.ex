defmodule Alnasl.Halls do
  @moduledoc """
  Halls: places with boards, and who may do what in each.

  The box's own serial ports are one hall (`own/0`), made when the box was
  upgraded and never removed. Every bridge is in a hall (`bridges.hall_id`),
  and so is every board (`boards.hall_id`: a bridge's boards are in its
  hall, the box's own in the own hall), every tournament and every connect
  code. A hall other than the own one has a tournament of its own as well
  (`local_tournament/1`): where its boards play until a pairing program
  says otherwise, as the box's own tournament is for the box's own boards.

  A box with no accounts has one hall that matters and nobody to scope by:
  `Alnasl.Accounts.Scope` is `open?` there and every filter here lets
  everything through.
  """

  import Ecto.Query, only: [from: 2]

  alias Alnasl.{Boards, Log, Repo, Tournaments}
  alias Alnasl.Accounts.{Invitation, Scope, User}
  alias Alnasl.Bridges.{Bridge, Join}
  alias Alnasl.Games.Game
  alias Alnasl.Halls.{Hall, Member}
  alias Alnasl.Tournaments.{Link, Placement, Tournament}

  @topic "halls"

  def subscribe, do: Phoenix.PubSub.subscribe(Alnasl.PubSub, @topic)

  @doc false
  def notify, do: Phoenix.PubSub.broadcast(Alnasl.PubSub, @topic, {:halls, :changed})

  # --- halls -------------------------------------------------------------------

  @doc "The hall of the box's own ports. Made if it is not there (a database made before halls by hand)."
  def own do
    case Repo.one(from h in Hall, where: h.own, order_by: h.id, limit: 1) do
      nil -> Repo.insert!(%Hall{name: Alnasl.Settings.get("box_name") || "Alnasl", own: true})
      hall -> hall
    end
  end

  def own_id, do: own().id

  @doc "Every hall, the own one first."
  def list, do: Repo.all(from h in Hall, order_by: [desc: h.own, asc: h.id])

  def get(nil), do: nil
  def get(id), do: Repo.get(Hall, id)

  @doc "The hall a row is in: its `hall_id`, or the own hall for a row from before halls."
  def of(%{hall_id: id}) when is_integer(id), do: id
  def of(_row), do: own_id()

  @doc "A new hall, with its own tournament. Only an admin makes halls."
  def create(%Scope{} = scope, attrs) do
    if Scope.can?(scope, :admin) do
      with {:ok, hall} <- %Hall{} |> Hall.changeset(attrs) |> Repo.insert() do
        local_tournament(hall)
        Log.add(:info, "hall.created", %{name: hall.name}, %{})
        notify()
        {:ok, hall}
      end
    else
      {:error, :forbidden}
    end
  end

  @doc "Renames a hall (its owner)."
  def rename(%Scope{} = scope, %Hall{} = hall, attrs) do
    if Scope.can?(scope, :owner, hall.id) do
      with {:ok, hall} <- hall |> Hall.changeset(attrs) |> Repo.update() do
        notify()
        {:ok, hall}
      end
    else
      {:error, :forbidden}
    end
  end

  @doc """
  What still keeps a hall from being deleted: `%{bridges, tournaments,
  links}`, counts. A bridge that was removed does not count; a hall's own
  local tournament counts only once games were played in it or it is
  played in another hall as well, and a link
  (a code, an account) counts because it brings tournaments. A tournament
  from another hall that is also played here counts too: take its tables
  away in Setup first, or the hall would vanish from under its boards.
  """
  def leftovers(%Hall{id: id}) do
    local_with_games =
      Repo.all(
        from(t in Tournament,
          where: t.hall_id == ^id and t.kind == "local",
          join: g in Game,
          on: g.tournament_id == t.id,
          select: t.id,
          distinct: true
        )
      )

    # The hall's own tournament placed in another hall has boards there:
    # deleting it would leave them pointing at nothing.
    local_elsewhere =
      Repo.all(
        from(t in Tournament,
          where: t.hall_id == ^id and t.kind == "local",
          join: p in Placement,
          on: p.tournament_id == t.id and p.hall_id != ^id,
          select: t.id,
          distinct: true
        )
      )

    locals = length(Enum.uniq(local_with_games ++ local_elsewhere))

    %{
      bridges:
        Repo.aggregate(
          from(b in Bridge, where: b.hall_id == ^id and is_nil(b.revoked_at)),
          :count
        ),
      tournaments:
        Repo.aggregate(
          from(t in Tournament, where: t.hall_id == ^id and t.kind != "local"),
          :count
        ) +
          locals +
          Repo.aggregate(
            from(p in Placement,
              join: t in Tournament,
              on: t.id == p.tournament_id,
              where: p.hall_id == ^id and (is_nil(t.hall_id) or t.hall_id != ^id)
            ),
            :count
          ),
      links: Repo.aggregate(from(l in Link, where: l.hall_id == ^id), :count)
    }
  end

  @doc """
  Deletes a hall (its owner, or an admin), in one transaction: its open
  join codes, invitations, memberships, boards, removed bridges and its
  own local tournament, then the hall. Never the box's own hall, and never
  one that still has bridges, tournaments or links: `{:error, {:not_empty,
  leftovers}}`, so no game is thrown away by this.
  """
  def delete(%Scope{} = scope, %Hall{} = hall) do
    cond do
      not Scope.can?(scope, :owner, hall.id) -> {:error, :forbidden}
      hall.own -> {:error, :own}
      true -> do_delete(hall)
    end
  end

  defp do_delete(%Hall{id: id} = hall) do
    boards = Repo.all(from b in Boards.Board, where: b.hall_id == ^id)
    Enum.each(boards, &Boards.stop/1)

    result =
      Repo.transaction(fn ->
        left = leftovers(hall)

        if left.bridges + left.tournaments + left.links > 0 do
          Repo.rollback({:not_empty, left})
        else
          Repo.delete_all(from j in Join, where: j.hall_id == ^id)
          Repo.delete_all(from i in Invitation, where: i.hall_id == ^id)
          Repo.delete_all(from m in Member, where: m.hall_id == ^id)
          Repo.delete_all(from b in Boards.Board, where: b.hall_id == ^id)
          Repo.delete_all(from b in Bridge, where: b.hall_id == ^id)
          Repo.delete_all(from p in Placement, where: p.hall_id == ^id)
          Repo.delete_all(from t in Tournament, where: t.hall_id == ^id and t.kind == "local")
          Repo.delete!(hall)
        end
      end)

    case result do
      {:ok, hall} ->
        Log.add(:info, "hall.deleted", %{name: hall.name}, %{})
        notify()
        {:ok, hall}

      error ->
        error
    end
  end

  @doc """
  The tournament a hall's boards play in when nobody said otherwise: for
  the own hall the box's own tournament, for another its own local one
  (made the first time it is asked for).
  """
  def local_tournament(%Hall{own: true}), do: Tournaments.default()

  def local_tournament(%Hall{id: id}) do
    case Repo.one(
           from t in Tournament,
             where: t.kind == "local" and t.hall_id == ^id,
             order_by: t.id,
             limit: 1
         ) do
      nil -> Repo.insert!(%Tournament{kind: "local", hall_id: id})
      tournament -> tournament
    end
  end

  def local_tournament(id) when is_integer(id) do
    case get(id) do
      nil -> Tournaments.default()
      hall -> local_tournament(hall)
    end
  end

  def local_tournament(nil), do: Tournaments.default()

  # --- what a scope sees -------------------------------------------------------

  @doc """
  Keeps the rows (anything with a `hall_id`) in the scope's current hall;
  a tournament is in every hall it is placed in (`Alnasl.Placements`).
  Everything passes on a box with no accounts.
  """
  def here(%Scope{open?: true}, rows), do: rows

  def here(%Scope{} = scope, rows) do
    id = Scope.hall_id(scope)
    index = Alnasl.Placements.index()
    Enum.filter(rows, &(id in Alnasl.Placements.halls_of(&1, index)))
  end

  def here(_none, _rows), do: []

  @doc """
  The tournaments in play in the scope's current hall
  (`Alnasl.Tournaments.active/0`, of this hall), never empty: a hall with
  none in play has its own local one.
  """
  def active(%Scope{open?: true}), do: Tournaments.active()

  def active(%Scope{} = scope) do
    case {here(scope, Tournaments.active()), Scope.hall_id(scope)} do
      {[], nil} -> []
      {[], id} -> [local_tournament(id)]
      {list, _id} -> list
    end
  end

  def active(_none), do: []

  @doc "The hall a box-wide action (numbering, remaps) keeps to: `nil` (all) on a box without accounts."
  def filter_id(%Scope{open?: true}), do: nil
  def filter_id(%Scope{} = scope), do: Scope.hall_id(scope)
  def filter_id(_none), do: nil

  @doc "Keeps the rows in any hall the scope may see."
  def visible(%Scope{open?: true}, rows), do: rows

  def visible(%Scope{} = scope, rows) do
    ids = Scope.hall_ids(scope)
    index = Alnasl.Placements.index()

    Enum.filter(rows, fn row ->
      Enum.any?(Alnasl.Placements.halls_of(row, index), &(&1 in ids))
    end)
  end

  def visible(_none, _rows), do: []

  @doc "May the scope see this row (a board, a tournament, a bridge, a code)?"
  def sees?(%Scope{open?: true}, _row), do: true

  def sees?(%Scope{} = scope, row),
    do: row != nil and Enum.any?(Alnasl.Placements.halls_of(row), &Scope.sees?(scope, &1))

  def sees?(_none, _row), do: false

  # --- members -----------------------------------------------------------------

  @doc "The members of a hall, with their accounts, owners first."
  def members(%Hall{id: id}) do
    Repo.all(
      from m in Member,
        where: m.hall_id == ^id,
        join: u in assoc(m, :user),
        preload: [user: u],
        order_by: [
          asc: fragment("CASE ? WHEN 'owner' THEN 0 WHEN 'arbiter' THEN 1 ELSE 2 END", m.role),
          asc: u.email
        ]
    )
  end

  @doc "`%{hall_id => role}` of an account."
  def roles(%User{id: id}) do
    Repo.all(from m in Member, where: m.user_id == ^id, select: {m.hall_id, m.role})
    |> Map.new()
  end

  @doc "Makes `user` a member of `hall` with `role`, or changes the role it has there."
  def put_member(%Hall{id: hall_id}, %User{id: user_id}, role)
      when role in ["owner", "arbiter", "viewer"] do
    case Repo.get_by(Member, hall_id: hall_id, user_id: user_id) do
      nil -> Repo.insert(%Member{hall_id: hall_id, user_id: user_id, role: role})
      member -> member |> Ecto.Changeset.change(role: role) |> Repo.update()
    end
    |> tap(fn _ -> notify() end)
  end

  @doc "An owner changes someone's role, or takes them out of the hall (`nil`)."
  def set_role(%Scope{} = scope, %Hall{} = hall, member_id, role) do
    with true <- Scope.can?(scope, :owner, hall.id) || {:error, :forbidden},
         %Member{} = member <-
           Repo.get_by(Member, id: member_id, hall_id: hall.id) || {:error, :not_found},
         :ok <- keeps_an_owner(hall, member, role) do
      result =
        case role do
          nil ->
            Repo.delete(member)

          role when role in ["owner", "arbiter", "viewer"] ->
            member |> Ecto.Changeset.change(role: role) |> Repo.update()

          _other ->
            {:error, :role}
        end

      notify()
      result
    end
  end

  # A hall is never left without an owner by its owners: the last one cannot
  # step down or be taken out. An admin can always put one back.
  defp keeps_an_owner(hall, %Member{role: "owner", id: id}, role) when role != "owner" do
    others =
      Repo.aggregate(
        from(m in Member, where: m.hall_id == ^hall.id and m.role == "owner" and m.id != ^id),
        :count
      )

    if others > 0, do: :ok, else: {:error, :last_owner}
  end

  defp keeps_an_owner(_hall, _member, _role), do: :ok
end
