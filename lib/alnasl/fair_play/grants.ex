defmodule Alnasl.FairPlay.Grants do
  @moduledoc """
  Sharing: the hall's owner lets named accounts see fair play. The chief
  arbiter, the fair-play officer, whoever the owner chooses - and only
  them.

  A grant (`Alnasl.FairPlay.Grant`) is for one report (a tournament's or
  an upload's) or for the hall's fair play as a whole, to one account,
  until a date the owner sets (at most `max_days/0` ahead), unless the
  owner revokes it first. It is in force only while the account is still
  a member of the hall: an account taken off the hall loses what it was
  shown, without anybody having to remember to revoke it. And so a grant
  can only be made to a member of the hall: the owner picks from the
  hall's people, never types an address, and the page never tells anybody
  which addresses have accounts here.

  A grantee **sees**: the report, its rounds and its players' pages. A
  grantee never changes anything (no switch, no engine, no upload, no
  round analysed, no retention) and never shares further: every one of
  those asks `Alnasl.FairPlay.Access.owner?/2`, which a grant does not
  touch. Nor does a grant make anybody the owner of anything else.

  Every grant and every revocation is written in the audit
  (`Alnasl.FairPlay.View`), and so is every opening of a report by a
  grantee, as by the owner.

  The hosted service's admin gets nothing from being the admin, here as
  everywhere in fair play. An admin who is a member of the hall can be
  given a grant like anybody else; one who is not, cannot.
  """

  import Ecto.Query

  alias Alnasl.{Accounts, Halls, Repo, Tournaments}
  alias Alnasl.Accounts.Scope
  alias Alnasl.FairPlay
  alias Alnasl.FairPlay.{Access, Grant, Upload}
  alias Alnasl.Tournaments.Tournament

  @max_days 365

  @doc "The longest a grant may run, in days."
  def max_days, do: @max_days

  # --- the question ------------------------------------------------------------

  @doc """
  Does the scope hold a grant, in force now, that covers `subject` (a
  tournament or an upload)? A grant of the hall covers every report of
  it; a grant of a tournament covers the uploads attached to it too.
  """
  @spec active?(%Scope{} | nil, struct(), DateTime.t()) :: boolean()
  def active?(scope, subject, now \\ DateTime.utc_now())

  def active?(%Scope{user: %{id: user_id}, roles: roles}, subject, now) when is_map(roles) do
    hall_id = FairPlay.hall_of(subject)

    Map.has_key?(roles, hall_id) and
      Repo.exists?(
        from g in in_force(user_id, now),
          where: g.hall_id == ^hall_id,
          where: ^covers(subject)
      )
  end

  def active?(_scope, _subject, _now), do: false

  @doc "Does the scope hold a grant of the whole hall, in force now?"
  @spec hall_active?(%Scope{} | nil, integer(), DateTime.t()) :: boolean()
  def hall_active?(scope, hall_id, now \\ DateTime.utc_now())

  def hall_active?(%Scope{user: %{id: user_id}, roles: roles}, hall_id, now)
      when is_map(roles) do
    Map.has_key?(roles, hall_id) and
      Repo.exists?(
        from g in in_force(user_id, now),
          where: g.hall_id == ^hall_id and is_nil(g.tournament_id) and is_nil(g.upload_id)
      )
  end

  def hall_active?(_scope, _hall_id, _now), do: false

  defp in_force(user_id, now) do
    from g in Grant,
      where: g.user_id == ^user_id and is_nil(g.revoked_at) and g.expires_at > ^now
  end

  defp covers(%Tournament{id: id}) do
    dynamic([g], (is_nil(g.tournament_id) and is_nil(g.upload_id)) or g.tournament_id == ^id)
  end

  defp covers(%Upload{id: id, tournament_id: nil}) do
    dynamic([g], (is_nil(g.tournament_id) and is_nil(g.upload_id)) or g.upload_id == ^id)
  end

  defp covers(%Upload{id: id, tournament_id: tid}) do
    dynamic(
      [g],
      (is_nil(g.tournament_id) and is_nil(g.upload_id)) or g.upload_id == ^id or
        g.tournament_id == ^tid
    )
  end

  @doc """
  Does the account hold any grant in force, in a hall it is still a member
  of? What puts fair play in its menu (`Alnasl.Accounts.Scope`).
  """
  @spec any_active?(integer() | nil, map(), DateTime.t()) :: boolean()
  def any_active?(user_id, roles, now \\ DateTime.utc_now())

  def any_active?(user_id, roles, now) when is_integer(user_id) and is_map(roles) do
    halls = Map.keys(roles)

    halls != [] and
      Repo.exists?(from g in in_force(user_id, now), where: g.hall_id in ^halls)
  end

  def any_active?(_user_id, _roles, _now), do: false

  @doc """
  What has been shared with the scope's account and is in force: one map
  per grant, `%{grant, hall, subject}`, `subject` being `:hall`, the
  tournament or the upload. Newest first. Nothing for anybody else.
  """
  def shared_with(scope, now \\ DateTime.utc_now())

  def shared_with(%Scope{user: %{id: user_id}, roles: roles}, now) when is_map(roles) do
    halls = Map.keys(roles)

    from(g in in_force(user_id, now),
      where: g.hall_id in ^halls,
      order_by: [desc: g.id]
    )
    |> Repo.all()
    |> Enum.flat_map(fn grant ->
      case resolve(grant) do
        nil -> []
        subject -> [%{grant: grant, hall: Halls.get(grant.hall_id), subject: subject}]
      end
    end)
  end

  def shared_with(_scope, _now), do: []

  defp resolve(%Grant{tournament_id: id}) when is_integer(id), do: Tournaments.get(id)
  defp resolve(%Grant{upload_id: id}) when is_integer(id), do: Repo.get(Upload, id)
  defp resolve(%Grant{}), do: :hall

  # --- the owner's side ----------------------------------------------------------

  @doc """
  The accounts the owner may share with in a hall: its members who are not
  its owners (an owner sees everything already). Owner only.
  """
  def candidates(scope, hall_id) do
    with true <- Access.owner?(scope, hall_id),
         %{} = hall <- Halls.get(hall_id) do
      {:ok, hall |> Halls.members() |> Enum.reject(&(&1.role == "owner")) |> Enum.map(& &1.user)}
    else
      _no -> {:error, :forbidden}
    end
  end

  @doc """
  Shares `subject` - `{:hall, hall_id}`, a tournament or an upload - with
  account `user_id` for `days` days. Owner only.

  `{:error, :days}` outside 1 to #{@max_days}; `{:error, :not_member}` for
  an account that is not a member of the hall (or is its owner, who needs
  no grant).
  """
  @spec grant(%Scope{} | nil, term(), integer(), integer()) ::
          {:ok, struct()} | {:error, :forbidden | :days | :not_member}
  def grant(scope, subject, user_id, days) do
    hall_id = hall_id(subject)

    cond do
      not Access.owner?(scope, hall_id) ->
        {:error, :forbidden}

      not is_integer(days) or days < 1 or days > @max_days ->
        {:error, :days}

      true ->
        with %{} = user <- Accounts.get_user(user_id),
             role when role in ["arbiter", "viewer"] <- Halls.roles(user)[hall_id] do
          now = DateTime.utc_now(:second)

          {tournament_id, upload_id} =
            case subject do
              %Tournament{id: id} -> {id, nil}
              %Upload{id: id} -> {nil, id}
              {:hall, _} -> {nil, nil}
            end

          grant =
            Repo.insert!(%Grant{
              hall_id: hall_id,
              tournament_id: tournament_id,
              upload_id: upload_id,
              user_id: user.id,
              user_email: user.email,
              granted_by: by(scope),
              expires_at: DateTime.add(now, days * 86_400, :second)
            })

          FairPlay.audit(scope, subject_ids(grant), "grant",
            detail: "#{user.email} until #{Date.to_iso8601(DateTime.to_date(grant.expires_at))}"
          )

          {:ok, grant}
        else
          _no -> {:error, :not_member}
        end
    end
  end

  @doc "Ends a grant now. Owner of its hall only."
  def revoke(scope, grant_id) do
    with %Grant{} = grant <- Repo.get(Grant, grant_id),
         true <- Access.owner?(scope, grant.hall_id) do
      if grant.revoked_at do
        {:ok, grant}
      else
        grant =
          grant
          |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second), revoked_by: by(scope))
          |> Repo.update!()

        FairPlay.audit(scope, subject_ids(grant), "revoke", detail: grant.user_email)
        {:ok, grant}
      end
    else
      _no -> {:error, :forbidden}
    end
  end

  @doc """
  The grants of a hall, newest first, those in force and those that ended
  (the owner sees what was shared, not just what still is). `subject`
  narrows them to the grants that cover one report. Owner only.
  """
  def list(scope, hall_id, subject \\ nil) do
    if Access.owner?(scope, hall_id) do
      query = from g in Grant, where: g.hall_id == ^hall_id, order_by: [desc: g.id]
      query = if subject, do: from(g in query, where: ^covers(subject)), else: query
      {:ok, Repo.all(query)}
    else
      {:error, :forbidden}
    end
  end

  defp hall_id({:hall, id}), do: id
  defp hall_id(subject), do: FairPlay.hall_of(subject)

  defp subject_ids(%Grant{} = g),
    do: %{hall_id: g.hall_id, tournament_id: g.tournament_id, upload_id: g.upload_id}

  defp by(%Scope{user: %{email: email}}), do: email
  defp by(_scope), do: nil
end
