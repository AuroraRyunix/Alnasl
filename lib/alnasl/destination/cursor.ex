defmodule Alnasl.Destination.Cursor do
  @moduledoc """
  How far one destination has got with one game: `acked_seq` is the game's
  counter (`games.seq`) at the last push the destination answered for. A
  game whose counter is ahead of it is waiting for that destination.
  `error` is what the destination said about the game last time, if it
  refused it. `force` is the arbiter's "send it again, whatever you hold".
  """
  use Ecto.Schema

  schema "destination_cursors" do
    field :destination, :string
    field :game_id, :integer
    field :acked_seq, :integer, default: 0
    field :error, :string
    field :digest, :string
    field :force, :boolean, default: false
    field :sent_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end
end
