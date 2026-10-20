defmodule Alnasl.FairPlay.View do
  @moduledoc """
  One opening of a report or a player page (`fair_play_views`): who, which
  tournament, which round and player, when. The audit of a thing that is
  meant to be confidential. `user_id` and `user_email` are `nil` on a box
  with no accounts.
  """
  use Ecto.Schema

  schema "fair_play_views" do
    field :tournament_id, :integer
    field :user_id, :integer
    field :user_email, :string
    field :round, :integer
    field :player_key, :string
    field :at, :utc_datetime
  end
end
