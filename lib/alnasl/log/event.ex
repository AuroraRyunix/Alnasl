defmodule Alnasl.Log.Event do
  @moduledoc "One line of the arbiter's log. `data` is JSON; the words are made when it is shown."
  use Ecto.Schema

  schema "events" do
    field :at, :utc_datetime_usec
    field :level, :string
    field :kind, :string
    field :board_id, :integer
    field :round, :integer
    field :board_no, :integer
    field :data, :string
  end
end
