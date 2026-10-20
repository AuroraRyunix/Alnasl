defmodule Alnasl.FairPlay.Setting do
  @moduledoc """
  A hall's fair-play switch and the engine this machine has for it
  (`fair_play_settings`). A hall with no row has it off. The engine's path,
  version and bench are what `Alnasl.FairPlay.Installer` reported; `nodes`
  is the search size every position is given (frozen at calibration, so
  changing it makes the stored analyses stale).
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "fair_play_settings" do
    field :hall_id, :integer
    field :enabled, :boolean, default: false
    field :engine_id, :string
    field :engine_path, :string
    field :engine_version, :string
    field :engine_bench, :integer
    field :nodes, :integer, default: 1_000_000
    timestamps(type: :utc_datetime)
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [
      :enabled,
      :engine_id,
      :engine_path,
      :engine_version,
      :engine_bench,
      :nodes
    ])
    |> validate_number(:nodes, greater_than: 0)
    |> unique_constraint(:hall_id)
  end

  @doc "An engine is installed: its file is there."
  def installed?(%__MODULE__{engine_path: path}) when is_binary(path), do: File.regular?(path)
  def installed?(_none), do: false
end
