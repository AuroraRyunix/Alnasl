defmodule Alnasl.Halls.Member do
  @moduledoc """
  An account's role in a hall:

  * `owner` - joins bridges, invites people, and everything an arbiter does;
  * `arbiter` - games, corrections, rounds, the links to OpenPairings and
    the results site;
  * `viewer` - follows the games and changes nothing.
  """

  use Ecto.Schema

  @roles ~w(owner arbiter viewer)

  schema "hall_members" do
    field :role, :string
    belongs_to :hall, Alnasl.Halls.Hall
    belongs_to :user, Alnasl.Accounts.User
    timestamps(type: :utc_datetime)
  end

  def roles, do: @roles
end
