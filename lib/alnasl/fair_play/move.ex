defmodule Alnasl.FairPlay.Move do
  @moduledoc """
  One analysed ply of one game (`fair_play_moves`): what
  `Alnasl.FairPlay.Analyzer` and `Alnasl.FairPlay.Selection` produce for it,
  plus which engine, bench and node count produced it. Plies left out of the
  count are stored too, with their reason, so the report can say how many
  and why.

  `prefix_hash` is a digest of the start position and every move up to and
  including this one: when the tracker rewrites a move, every row from it
  on stops matching and is thrown away (`Alnasl.FairPlay.Analysis`).
  """
  use Ecto.Schema

  schema "fair_play_moves" do
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
    field :prefix_hash, :string
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

  @doc """
  The row as the record `Alnasl.FairPlay.Stats` reads: the best lines
  decoded, the colour and the skip reason as atoms. Takes an
  `Alnasl.FairPlay.UploadMove` as well: the same columns, another table.
  """
  def to_record(%{__struct__: kind, ply: _} = row)
      when kind in [__MODULE__, Alnasl.FairPlay.UploadMove] do
    %{
      ply: row.ply,
      colour: String.to_existing_atom(row.colour),
      move_number: row.move_number,
      fen: row.fen,
      san: row.san,
      played_uci: row.played_uci,
      rating: row.rating,
      material: row.material,
      clock_before_ms: row.clock_before_ms,
      best: decode_best(row.best),
      played_cp: row.played_cp,
      rank: row.rank,
      gap: row.gap,
      near_count: row.near_count,
      skip: row.skip && String.to_existing_atom(row.skip),
      round: row.round,
      board_no: row.board_no,
      player_key: row.player_key,
      player_name: row.player_name
    }
  end

  def decode_best(nil), do: nil

  def decode_best(json) do
    json
    |> Jason.decode!()
    |> Enum.map(&%{move: &1["move"], cp: &1["cp"]})
  end

  def encode_best(nil), do: nil
  def encode_best(best), do: Jason.encode!(Enum.map(best, &%{"move" => &1.move, "cp" => &1.cp}))
end
