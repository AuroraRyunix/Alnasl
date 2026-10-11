defmodule Alnasl.Outbox.Entry do
  @moduledoc """
  One message for the results server: the state of one game at one moment,
  as the JSON body the live-boards API takes. `state` is `pending`, `sent`,
  `rejected` (the server said this message is wrong) or `superseded` (a later
  message for the same game said the same and more).
  """
  use Ecto.Schema

  schema "outbox" do
    field :game_id, :integer
    field :round, :integer
    field :board_no, :integer
    field :seq, :integer
    field :plies, :integer, default: 0
    field :replace, :boolean, default: false
    field :body, :string
    field :state, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :error, :string
    field :detail, :string
    field :sent_at, :utc_datetime
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
