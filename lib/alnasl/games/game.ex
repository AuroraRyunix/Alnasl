defmodule Alnasl.Games.Game do
  @moduledoc """
  One game of one round, as the box knows it.

  `plies` is JSON: `[%{"san", "flags", "at", "clock"}]`, the whole game.
  `status` is `"live"` or `"finished"`; `result` is what the arbiter set (or
  confirmed), `suggestion` what the board suggested and nobody has confirmed.
  `seq` counts what was queued for the server for this game.

  A board of a round usually sees one game. When it sees more - "New game
  on this board" - they are numbered by `game_no`, from 1, and the highest
  is the one being played. The results server knows a game by round and
  board and has room for one: only game 1 is sent anywhere
  (`Alnasl.Outbox`); the others are kept here, with their PGN.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "games" do
    field :round, :integer
    field :board_no, :integer
    field :game_no, :integer, default: 1
    field :white, :string
    field :black, :string
    field :start_fen, :string
    field :plies, :string, default: "[]"
    field :status, :string, default: "live"
    field :result, :string
    field :suggestion, :string
    field :paused, :boolean, default: false
    field :source, :string, default: "board"
    field :clock, :string
    field :seq, :integer, default: 0
    field :finished_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  @results ["1-0", "0-1", "1/2-1/2", "*"]
  def results, do: @results

  def changeset(game, attrs) do
    game
    |> cast(attrs, [
      :white,
      :black,
      :start_fen,
      :plies,
      :status,
      :result,
      :suggestion,
      :paused,
      :source,
      :clock,
      :seq,
      :finished_at
    ])
    |> validate_inclusion(:status, ~w(live finished))
    |> validate_inclusion(:result, @results)
    |> unique_constraint([:round, :board_no, :game_no])
  end
end
