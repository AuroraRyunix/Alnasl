defmodule Alnasl.FairPlay.UploadGame do
  @moduledoc """
  One game of an uploaded PGN (`fair_play_upload_games`): its tags, its
  moves (SAN, separated by spaces) and its clocks (JSON, the mover's time
  after each move in ms, or null). `status` is `"waiting"` until the queue
  has analysed it, then `"done"` or `"failed"` (`error` says why);
  `"duplicate"` for a game the boards recorded too, which is not analysed
  twice.
  """
  use Ecto.Schema

  schema "fair_play_upload_games" do
    field :upload_id, :integer
    field :number, :integer
    field :event, :string
    field :date, :string
    field :round, :integer
    field :board, :integer
    field :white, :string
    field :black, :string
    field :white_elo, :integer
    field :black_elo, :integer
    field :white_fide_id, :integer
    field :black_fide_id, :integer
    field :result, :string
    field :start_fen, :string
    field :moves, :string
    field :clocks, :string
    field :status, :string, default: "waiting"
    field :error, :string
    timestamps(type: :utc_datetime)
  end

  @doc "The SANs."
  def sans(%__MODULE__{moves: moves}), do: String.split(moves || "", " ", trim: true)

  @doc "The clocks, one per move (`nil` where unknown)."
  def clocks(%__MODULE__{clocks: nil} = game), do: List.duplicate(nil, length(sans(game)))

  def clocks(%__MODULE__{clocks: json} = game) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _broken -> List.duplicate(nil, length(sans(game)))
    end
  end
end
