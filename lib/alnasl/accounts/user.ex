defmodule Alnasl.Accounts.User do
  @moduledoc """
  An account: an address, a password (none for an account that only signs
  in with 02cloud), and whether it may do everything on the box (`admin`).
  What it may do in a hall is its membership there (`Alnasl.Halls.Member`).

  Addresses are kept in lower case: an address is not case-sensitive in
  practice, and two accounts that differ in a capital are one person
  locked out of one of them.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Alnasl.Accounts.Password

  @min_password 12

  schema "users" do
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :keycloak_sub, :string
    field :admin, :boolean, default: false
    field :must_change_password, :boolean, default: false
    timestamps(type: :utc_datetime)
  end

  def min_password, do: @min_password

  @doc "A new account with an address and a password."
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :password])
    |> validate_email()
    |> validate_password()
  end

  @doc "A new account with an address only: it signs in with 02cloud."
  def keycloak_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :keycloak_sub])
    |> validate_email()
    |> unique_constraint(:keycloak_sub)
  end

  @doc "A new password, chosen by the account's holder."
  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match")
    |> validate_password()
    |> put_change(:must_change_password, false)
  end

  defp validate_email(changeset) do
    changeset
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+\.[^@,;\s]+$/,
      message: "must be an address"
    )
    |> validate_length(:email, max: 160)
    |> unsafe_validate_unique(:email, Alnasl.Repo)
    |> unique_constraint(:email)
  end

  defp validate_password(changeset) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: @min_password, max: 72)
    |> hash_password()
  end

  defp hash_password(changeset) do
    password = get_change(changeset, :password)

    if password && changeset.valid? do
      changeset
      |> put_change(:hashed_password, Password.hash(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc "Whether `password` is this account's. An account with none, or no account, says no in the same time."
  def valid_password?(%__MODULE__{hashed_password: hashed}, password)
      when is_binary(hashed) and is_binary(password) and byte_size(password) > 0,
      do: Password.verify(password, hashed)

  def valid_password?(_user, _password), do: Password.no_user_verify()
end
