defmodule Alnasl.FairPlay.UploadMove do
  @moduledoc """
  One analysed ply of an uploaded game (`fair_play_upload_moves`): the
  same as `Alnasl.FairPlay.Move`, for a game with no row in `games`.
  `game_id` is the `Alnasl.FairPlay.UploadGame`'s; `tournament_id` the
  upload's tournament, when it has one, so that the tournament's report
  counts it.
  """
  use Ecto.Schema

  schema "fair_play_upload_moves" do
    field :upload_id, :integer
    field :tournament_id, :integer
    field :game_id, :integer
    field :round, :integer
    field :board_no, :integer
    field :ply, :integer
    field :colour, :string
    field :move_number, :integer
    field :player_key, :string
    field :player_name, :string
    field :san, :string
    field :played_uci, :string
    field :fen, :string
    field :best, :string
    field :played_cp, :integer
    field :rank, :integer
    field :gap, :integer
    field :near_count, :integer
    field :material, :integer
    field :clock_before_ms, :integer
    field :rating, :integer
    field :skip, :string
    field :engine_id, :string
    field :engine_version, :string
    field :bench, :integer
    field :nodes, :integer
    timestamps(type: :utc_datetime)
  end
end
