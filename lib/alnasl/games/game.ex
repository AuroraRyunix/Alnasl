defmodule Alnasl.Games.Game do
  @moduledoc """
  One game of one round, as the box knows it.

  `plies` is JSON: `[%{"san", "flags", "at", "clock"}]`, the whole game.
  `status` is `"live"` or `"finished"`; `result` is what the arbiter set (or
  confirmed), `suggestion` what the board suggested and nobody has confirmed.
  `seq` counts what was queued for the server for this game.

  A board of a round usually sees one game. When it sees more - "New game
  on this board" - they are numbered by `game_no`, from 1, and the highest
  is the one being played. Every place a game goes to knows it by round and
  board, or by the pairing, and has room for one: a game marked `local`
  stays on the box, with its PGN (`Alnasl.Outbox`).

  `tournament_id` says whose round and board these are: board 1 of round 3
  exists once per tournament.

  For a game of a pairing program: `remote_game` is the game's id there and
  `remote_white` / `remote_black` the player ids the box believes are
  playing it. `pairing_flag` is set when the pairing changed under a game
  that had begun: `"changed"` (other players, or the colours the other way
  round) or `"gone"` (no such game any more). The game is kept; the arbiter
  says what becomes of it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "games" do
    field :tournament_id, :integer
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
    field :remote_game, :string
    field :remote_white, :integer
    field :remote_black, :integer
    field :pairing_flag, :string
    field :local, :boolean, default: false
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
      :remote_game,
      :remote_white,
      :remote_black,
      :pairing_flag,
      :local,
      :finished_at
    ])
    |> validate_inclusion(:status, ~w(live finished))
    |> validate_inclusion(:result, @results)
    |> unique_constraint([:tournament_id, :round, :board_no, :game_no])
  end
end
