defmodule Alnasl.Accounts.UserToken do
  @moduledoc """
  A session, or a one-time sign-in link.

  * `"session"`: the token sits in the signed session cookie as it is, and
    here so that a session can be ended. Valid for thirty days.
  * `"qr"`: the sign-in link in the QR code on Setup. Only its hash is kept
    here, it is good for five minutes, and it is spent by its first use.
  """

  use Ecto.Schema
  import Ecto.Query

  alias Alnasl.Accounts.User

  @rand_size 32
  @session_days 30
  @qr_minutes 5

  schema "users_tokens" do
    field :token, :binary, redact: true
    field :context, :string
    field :used_at, :utc_datetime
    belongs_to :user, User
    timestamps(type: :utc_datetime, updated_at: false)
  end

  def session_days, do: @session_days
  def qr_minutes, do: @qr_minutes

  @doc "A session token, `{token, row}`."
  def build_session_token(%User{id: id}) do
    token = :crypto.strong_rand_bytes(@rand_size)
    {token, %__MODULE__{token: token, context: "session", user_id: id}}
  end

  @doc "The account behind a session token that has not run out."
  def session_query(token) do
    from t in __MODULE__,
      join: u in assoc(t, :user),
      where: t.token == ^token and t.context == "session",
      where: t.inserted_at > ^since(@session_days * 86_400),
      select: u
  end

  @doc "A one-time sign-in link's token: `{url_token, row}`. The row holds its hash."
  def build_hashed_token(%User{id: id}, context) do
    token = :crypto.strong_rand_bytes(@rand_size)

    {Base.url_encode64(token, padding: false),
     %__MODULE__{token: hash(token), context: context, user_id: id}}
  end

  @doc "The row of an unspent QR sign-in link that has not run out, by the token in the link."
  def qr_query(url_token) do
    case Base.url_decode64(url_token, padding: false) do
      {:ok, token} ->
        {:ok,
         from(t in __MODULE__,
           where: t.token == ^hash(token) and t.context == "qr" and is_nil(t.used_at),
           where: t.inserted_at > ^since(@qr_minutes * 60),
           preload: :user
         )}

      :error ->
        :error
    end
  end

  def hash(token), do: :crypto.hash(:sha256, token)

  # A cut-off computed here rather than with `ago/2`: SQLite would compare
  # its own text form of the time with the one the rows are written in.
  defp since(seconds), do: DateTime.add(DateTime.utc_now(:second), -seconds)
end
