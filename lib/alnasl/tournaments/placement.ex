defmodule Alnasl.Tournaments.Placement do
  @moduledoc """
  Where a tournament is played: in hall `hall_id`, on tables `table_from`
  to `table_to`, table `table_from` playing the tournament's board
  `first_board`.

  No range (`table_from` nil) is every table of the hall that no other
  range holds, table 1 playing board `first_board` - what a tournament
  without a range always meant. See `Alnasl.Placements`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "tournament_placements" do
    # Set by the box, never cast.
    field :tournament_id, :integer
    field :hall_id, :integer
    field :table_from, :integer
    field :table_to, :integer
    field :first_board, :integer, default: 1
    timestamps(type: :utc_datetime)
  end

  def changeset(placement, attrs) do
    placement
    |> cast(attrs, [:table_from, :table_to, :first_board])
    |> validate_required([:first_board])
    |> validate_number(:table_from, greater_than: 0, less_than: 10_000)
    |> validate_number(:table_to, greater_than: 0, less_than: 10_000)
    |> validate_number(:first_board, greater_than: 0, less_than: 10_000)
    |> validate_range()
  end

  defp validate_range(changeset) do
    from = get_field(changeset, :table_from)
    to = get_field(changeset, :table_to)

    cond do
      from == nil and to != nil ->
        add_error(changeset, :table_from, "is needed with a last table")

      from != nil and to != nil and to < from ->
        add_error(changeset, :table_to, "is before the first")

      true ->
        changeset
    end
  end
end
