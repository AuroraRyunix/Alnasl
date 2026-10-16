defmodule Alnasl.Accounts.Invitation do
  @moduledoc """
  An invitation to a hall: the address it is for, the role it gives, and
  the hash of the token in its link. Good once and for a week; whoever
  opens the link signs in or makes the account for that address, and is a
  member of the hall from then on.
  """

  use Ecto.Schema

  schema "invitations" do
    field :email, :string
    field :role, :string
    field :token, :binary, redact: true
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime
    belongs_to :hall, Alnasl.Halls.Hall
    belongs_to :invited_by, Alnasl.Accounts.User
    timestamps(type: :utc_datetime)
  end
end
