defmodule Alnasl.FairPlay.Grant do
  @moduledoc """
  The owner lets one named account see fair play (`fair_play_grants`): a
  report - a tournament's (`tournament_id`) or an upload's (`upload_id`) -
  or, with neither, every report of the hall. Until `expires_at`, unless
  revoked first (`revoked_at`), and only while the account is still a
  member of the hall. See `Alnasl.FairPlay.Grants`.
  """
  use Ecto.Schema

  schema "fair_play_grants" do
    field :hall_id, :integer
    field :tournament_id, :integer
    field :upload_id, :integer
    field :user_id, :integer
    field :user_email, :string
    field :granted_by, :string
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :revoked_by, :string
    timestamps(type: :utc_datetime)
  end

  @doc "Is the grant in force at `now`: not revoked, not expired?"
  def active?(%__MODULE__{revoked_at: nil, expires_at: expires}, now),
    do: DateTime.compare(expires, now) == :gt

  def active?(_grant, _now), do: false

  @doc "`:hall`, `{:tournament, id}` or `{:upload, id}`."
  def subject(%__MODULE__{tournament_id: id}) when is_integer(id), do: {:tournament, id}
  def subject(%__MODULE__{upload_id: id}) when is_integer(id), do: {:upload, id}
  def subject(%__MODULE__{}), do: :hall
end
