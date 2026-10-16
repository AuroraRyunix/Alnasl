defmodule Alnasl.Accounts do
  @moduledoc """
  Accounts, sessions, the sign-in link of the QR code, invitations, and
  "Sign in with 02cloud".

  ## Open until it is not

  A box with no accounts is open, as it always was: anybody on the hall's
  network, behind the PIN if one is set (`AlnaslWeb.Hall`). The first
  account made on it (`create_first_owner/1`) is its owner and an admin,
  and from then on every page asks who you are.

  The hosted server (`ALNASL_NO_LOCAL_BOARDS`, `server?/0`) is never open,
  not even with no accounts: a box on the internet is not a box in a hall.

  ## Who gets an account

  * the first account of a box, made on the box itself;
  * whoever opens an invitation link (`invite/4`): made by a hall's owner,
    or - for an address with no account yet on the server - by an admin;
  * an address in `ALNASL_ADMIN_EMAILS`, signing in with 02cloud for the
    first time.

  Nobody else. A 02cloud login is a way to prove an address, not a ticket:
  it signs in to the account that address has, and makes none.
  """

  import Ecto.Query, only: [from: 2]

  alias Alnasl.{Boards, Halls, Log, Repo}
  alias Alnasl.Accounts.{Invitation, Scope, User, UserToken}
  alias Alnasl.Halls.Hall

  @invitation_days 7

  # --- the box -----------------------------------------------------------------

  @doc "The hosted server: boards from bridges only, and never open."
  def server?, do: not Boards.local?()

  @doc "Is there an account at all?"
  def any?, do: Repo.exists?(User)

  @doc "Must a browser sign in? On the server always; on a box once it has an account."
  def login_required?, do: server?() or any?()

  @doc "The addresses the deployment names as admins (`ALNASL_ADMIN_EMAILS`), lower case."
  def admin_emails do
    for email <- Application.get_env(:alnasl, :admin_emails, []), do: String.downcase(email)
  end

  @doc "Is `email` named an admin by the deployment?"
  def declared_admin?(email) when is_binary(email), do: String.downcase(email) in admin_emails()
  def declared_admin?(_none), do: false

  def admin?(%User{admin: true}), do: true
  def admin?(%User{email: email}), do: declared_admin?(email)
  def admin?(_none), do: false

  # --- scopes ------------------------------------------------------------------

  @doc """
  The scope of a browser: `user` signed in, with `hall_id` the hall it was
  looking at last (`nil`: the first it may see). `nil` as the user on a box
  that is open gives the open scope; on a box that is not, `nil`.
  """
  def scope(user, hall_id \\ nil)

  def scope(nil, hall_id) do
    if login_required?() do
      nil
    else
      halls = Halls.list()
      %Scope{open?: true, halls: halls, hall: pick(halls, hall_id)}
    end
  end

  def scope(%User{} = user, hall_id) do
    admin? = admin?(user)
    roles = Halls.roles(user)
    halls = for hall <- Halls.list(), admin? or Map.has_key?(roles, hall.id), do: hall
    %Scope{user: user, admin?: admin?, roles: roles, halls: halls, hall: pick(halls, hall_id)}
  end

  defp pick(halls, id), do: Enum.find(halls, &(&1.id == id)) || List.first(halls)

  # --- accounts ----------------------------------------------------------------

  def get_user(id), do: Repo.get(User, id)

  def get_user_by_email(email) when is_binary(email),
    do: Repo.get_by(User, email: String.downcase(String.trim(email)))

  def get_user_by_email(_none), do: nil

  @doc "The account with this address and password, or `nil`, in the same time either way."
  def get_user_by_email_and_password(email, password) do
    user = get_user_by_email(email)
    if User.valid_password?(user, password), do: user
  end

  def list_users, do: Repo.all(from u in User, order_by: u.email)

  def change_user_registration(attrs \\ %{}),
    do: User.registration_changeset(%User{}, attrs)

  def change_user_password(%User{} = user, attrs \\ %{}),
    do: User.password_changeset(user, attrs)

  @doc """
  The first account of a box: its owner, an admin, and the owner of the
  box's own hall. Refused when there is an account already, or on the
  server, where the first account is an admin signing in with 02cloud.
  """
  def create_first_owner(attrs) do
    Repo.transaction(fn ->
      cond do
        server?() ->
          Repo.rollback(:server)

        any?() ->
          Repo.rollback(:taken)

        true ->
          case %User{admin: true} |> User.registration_changeset(attrs) |> Repo.insert() do
            {:ok, user} ->
              {:ok, _member} = Halls.put_member(Halls.own(), user, "owner")
              Log.add(:info, "account.first", %{}, %{})
              user

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
      end
    end)
  end

  @doc "The holder changes the password; every other session of the account ends."
  def update_password(%User{} = user, attrs) do
    Repo.transaction(fn ->
      with {:ok, user} <- user |> User.password_changeset(attrs) |> Repo.update() do
        tokens =
          Repo.all(from t in UserToken, where: t.user_id == ^user.id and t.context == "session")

        Repo.delete_all(
          from t in UserToken, where: t.user_id == ^user.id and t.context == "session"
        )

        {user, tokens}
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  An admin gives an account a temporary password - the way back in on a
  box that cannot send mail. Shown once; the next sign-in asks for a new
  one, and every session of the account ends now.
  """
  def set_temporary_password(%Scope{} = scope, %User{} = user) do
    if Scope.can?(scope, :admin) do
      password = temporary_password()

      user
      |> Ecto.Changeset.change(
        hashed_password: Alnasl.Accounts.Password.hash(password),
        must_change_password: true
      )
      |> Repo.update!()

      tokens =
        Repo.all(from t in UserToken, where: t.user_id == ^user.id and t.context == "session")

      Repo.delete_all(from t in UserToken, where: t.user_id == ^user.id)
      Log.add(:info, "account.temporary_password", %{}, %{})
      {:ok, password, tokens}
    else
      {:error, :forbidden}
    end
  end

  @doc """
  For a server whose 02cloud sign-in is not set up yet: an account for an
  address in `ALNASL_ADMIN_EMAILS`, with a temporary password, printed by
  `bin/alnasl eval 'Alnasl.Accounts.admin_with_temporary_password("...")'`
  on the server itself. Whoever can run that can read the database anyway.
  """
  def admin_with_temporary_password(email) do
    if declared_admin?(email) do
      user =
        get_user_by_email(email) ||
          Repo.insert!(%User{email: String.downcase(String.trim(email))})

      set_temporary_password(%Scope{admin?: true}, user)
    else
      {:error, :not_an_admin}
    end
  end

  # Readable off a screen and typed on a phone: no 0/O, no 1/l/I.
  defp temporary_password do
    alphabet = ~c"abcdefghjkmnpqrstuvwxyz23456789"
    groups = for _ <- 1..4, do: for(_ <- 1..4, into: "", do: <<Enum.random(alphabet)>>)
    Enum.join(groups, "-")
  end

  # --- sessions ----------------------------------------------------------------

  def generate_session_token(%User{} = user) do
    {token, row} = UserToken.build_session_token(user)
    Repo.insert!(row)
    token
  end

  def get_user_by_session_token(token) when is_binary(token),
    do: Repo.one(UserToken.session_query(token))

  def get_user_by_session_token(_none), do: nil

  def delete_session_token(token) when is_binary(token) do
    Repo.delete_all(from t in UserToken, where: t.token == ^token and t.context == "session")
    :ok
  end

  def delete_session_token(_none), do: :ok

  # --- the sign-in link of the QR code -------------------------------------------

  @doc "A sign-in link for a phone: five minutes, once. Returns the token for the link."
  def create_qr_token(%User{} = user) do
    {url_token, row} = UserToken.build_hashed_token(user, "qr")
    Repo.insert!(row)
    url_token
  end

  @doc "Spends a QR sign-in token: `{:ok, user}`, or `:error` (unknown, used, or run out)."
  def use_qr_token(url_token) when is_binary(url_token) do
    with {:ok, query} <- UserToken.qr_query(url_token),
         %UserToken{user: user} = row <- Repo.one(query),
         {1, _} <-
           Repo.update_all(
             from(t in UserToken, where: t.id == ^row.id and is_nil(t.used_at)),
             set: [used_at: DateTime.utc_now(:second)]
           ) do
      {:ok, user}
    else
      _no -> :error
    end
  end

  def use_qr_token(_none), do: :error

  # --- invitations -------------------------------------------------------------

  @doc """
  Invites `email` to `hall` with `role`: `{:ok, url_token}` for the link,
  shown to whoever invited (there is no mail on a box). An owner of the
  hall may invite; on the server an address with no account yet needs an
  admin, because that is a new account.
  """
  def invite(%Scope{} = scope, %Hall{} = hall, email, role)
      when role in ["owner", "arbiter", "viewer"] do
    email = email |> to_string() |> String.trim() |> String.downcase()

    cond do
      # A box without accounts gets its first one on Setup, as its admin;
      # not through an invitation from nobody.
      scope.user == nil or not Scope.can?(scope, :owner, hall.id) ->
        {:error, :forbidden}

      not Regex.match?(~r/^[^@,;\s]+@[^@,;\s]+\.[^@,;\s]+$/, email) ->
        {:error, :email}

      server?() and not Scope.can?(scope, :admin) and get_user_by_email(email) == nil ->
        {:error, :admin_only}

      true ->
        token = :crypto.strong_rand_bytes(32)

        Repo.insert!(%Invitation{
          email: email,
          role: role,
          hall_id: hall.id,
          token: UserToken.hash(token),
          invited_by_id: scope.user && scope.user.id,
          expires_at: DateTime.add(DateTime.utc_now(:second), @invitation_days * 86_400)
        })

        Log.add(:info, "account.invited", %{hall: hall.name, role: role}, %{})
        {:ok, Base.url_encode64(token, padding: false)}
    end
  end

  def invite(_scope, _hall, _email, _role), do: {:error, :role}

  @doc "The invitations of a hall still open."
  def open_invitations(%Hall{id: id}) do
    now = DateTime.utc_now(:second)

    Repo.all(
      from i in Invitation,
        where: i.hall_id == ^id and is_nil(i.used_at) and i.expires_at > ^now,
        order_by: i.id
    )
  end

  @doc "Withdraws an open invitation (an owner of its hall)."
  def withdraw_invitation(%Scope{} = scope, id) do
    case Repo.get(Invitation, id) do
      %Invitation{} = invitation ->
        if Scope.can?(scope, :owner, invitation.hall_id) do
          Repo.delete(invitation)
        else
          {:error, :forbidden}
        end

      nil ->
        {:error, :not_found}
    end
  end

  @doc "The invitation a link is for, unused and not run out, with its hall; or `nil`."
  def get_invitation(url_token) when is_binary(url_token) do
    now = DateTime.utc_now(:second)

    with {:ok, token} <- Base.url_decode64(url_token, padding: false) do
      Repo.one(
        from i in Invitation,
          where: i.token == ^UserToken.hash(token) and is_nil(i.used_at) and i.expires_at > ^now,
          preload: :hall
      )
    else
      _bad -> nil
    end
  end

  def get_invitation(_none), do: nil

  @doc """
  Takes an invitation up for an account that has its address: the account
  is a member of the hall from now on, and the link is spent. `{:ok, user}`
  or `{:error, :used_or_expired | :other_address}`.
  """
  def accept_invitation(url_token, %User{} = user) do
    Repo.transaction(fn ->
      with %Invitation{} = invitation <- get_invitation(url_token) || {:error, :used_or_expired},
           true <- invitation.email == user.email || {:error, :other_address},
           {1, _} <-
             Repo.update_all(
               from(i in Invitation, where: i.id == ^invitation.id and is_nil(i.used_at)),
               set: [used_at: DateTime.utc_now(:second)]
             ) do
        # A role already higher in that hall is not lowered by an invitation.
        current = Halls.roles(user)[invitation.hall_id]

        unless current && rank(current) >= rank(invitation.role) do
          Halls.put_member(invitation.hall, user, invitation.role)
        end

        Log.add(
          :info,
          "account.joined",
          %{hall: invitation.hall.name, role: invitation.role},
          %{}
        )

        user
      else
        {:error, reason} -> Repo.rollback(reason)
        _lost_race -> Repo.rollback(:used_or_expired)
      end
    end)
  end

  defp rank("owner"), do: 3
  defp rank("arbiter"), do: 2
  defp rank(_viewer), do: 1

  @doc "Makes the account an invitation is for, with a password, and takes the invitation up."
  def register_with_invitation(url_token, attrs) do
    case get_invitation(url_token) do
      nil ->
        {:error, :used_or_expired}

      invitation ->
        attrs =
          Map.put(Map.new(attrs, fn {k, v} -> {to_string(k), v} end), "email", invitation.email)

        Repo.transaction(fn ->
          with {:ok, user} <- %User{} |> User.registration_changeset(attrs) |> Repo.insert(),
               {:ok, user} <- accept_invitation(url_token, user) do
            user
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
    end
  end

  # --- 02cloud ---------------------------------------------------------------

  @doc """
  Signs in what 02cloud says about somebody (`%{sub, email, email_verified}`):

  * the account linked to that 02cloud identity before;
  * else the account with that address - only when 02cloud has verified it -
    which is linked from now on;
  * else, for an address in `ALNASL_ADMIN_EMAILS`, a new account;
  * else, with an invitation for that address in hand (`invitation`), a new
    account that takes it up.

  Otherwise `{:error, :no_account}`: 02cloud proves an address, it does not
  let anybody in.
  """
  def keycloak_sign_in(%{sub: sub, email: email} = claims, invitation \\ nil)
      when is_binary(sub) do
    email = if is_binary(email), do: String.downcase(String.trim(email)), else: nil
    verified? = claims[:email_verified] == true

    case Repo.get_by(User, keycloak_sub: sub) do
      %User{} = user ->
        {:ok, user}

      nil ->
        cond do
          email in [nil, ""] ->
            {:error, :no_email}

          not verified? ->
            {:error, :unverified}

          user = get_user_by_email(email) ->
            link_keycloak(user, sub)

          declared_admin?(email) ->
            create_keycloak_user(email, sub)

          (i = get_invitation(invitation)) && i.email == email ->
            with {:ok, user} <- create_keycloak_user(email, sub),
                 {:ok, user} <- accept_invitation(invitation, user),
                 do: {:ok, user}

          true ->
            {:error, :no_account}
        end
    end
  end

  defp link_keycloak(%User{keycloak_sub: nil} = user, sub) do
    user |> Ecto.Changeset.change(keycloak_sub: sub) |> Repo.update()
  end

  # The address has an account linked to another 02cloud identity: the
  # address moved from one identity to another there. Not followed blindly.
  defp link_keycloak(%User{}, _sub), do: {:error, :other_identity}

  defp create_keycloak_user(email, sub) do
    with {:ok, user} <-
           %User{}
           |> User.keycloak_changeset(%{email: email, keycloak_sub: sub})
           |> Repo.insert() do
      Log.add(:info, "account.made", %{via: "02cloud"}, %{})
      {:ok, user}
    end
  end
end
