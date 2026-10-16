defmodule Alnasl.Boards.Board do
  @moduledoc """
  A physical board on a port or bus address - or a simulator slot standing in
  for one - and the game of the round it is linked to (`round`, `board_no`),
  in the tournament its table plays in (`tournament_id`).

  `options` is JSON for the driver: the simulator's game and faults, a replay's
  file. `flipped` says the board is plugged in turned round, so what it calls
  a8 is h1.
  """
  use Ecto.Schema
  import Ecto.Changeset

  # "remote": a board an Arkab bridge reads elsewhere; `port` is
  # "bridge-<bridge id>:<the bridge's name for it>" (`Alnasl.Bridges`).
  @drivers ~w(simulator replay dgt_serial dgt_bus remote)

  schema "boards" do
    field :name, :string
    field :driver, :string
    field :port, :string
    field :address, :integer
    field :options, :string
    field :flipped, :boolean, default: false
    field :enabled, :boolean, default: true
    field :tournament_id, :integer
    field :round, :integer
    field :board_no, :integer
    field :table_no, :integer
    field :serial, :string
    field :firmware, :string
    timestamps(type: :utc_datetime)
  end

  def drivers, do: @drivers

  # A box without boards of its own (`Alnasl.Boards.local?/0`) takes rows
  # from bridges only: a simulator added there would be a board nobody
  # asked the server to invent.
  defp allowed, do: if(Alnasl.Boards.local?(), do: @drivers, else: ["remote"])

  def changeset(board, attrs) do
    board
    |> cast(attrs, [
      :name,
      :driver,
      :port,
      :address,
      :options,
      :flipped,
      :enabled,
      :tournament_id,
      :round,
      :board_no,
      :table_no,
      :serial,
      :firmware
    ])
    |> validate_required([:name, :driver])
    |> validate_inclusion(:driver, allowed())
    |> validate_number(:address, greater_than_or_equal_to: 0, less_than: 16_384)
    |> validate_number(:round, greater_than: 0, less_than: 1000)
    |> validate_number(:board_no, greater_than: 0, less_than: 10_000)
    |> validate_number(:table_no, greater_than: 0, less_than: 10_000)
  end

  @doc "The driver options as a map with string keys."
  def options(%__MODULE__{options: nil}), do: %{}

  def options(%__MODULE__{options: json}) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> map
      _other -> %{}
    end
  end
end
