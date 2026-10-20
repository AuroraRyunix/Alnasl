defmodule Alnasl.FairPlay.Upload do
  @moduledoc """
  A PGN file the owner uploaded for screening (`fair_play_uploads`): games
  that were not played on the boards, or a whole event. The file is read
  once, its games stored (`Alnasl.FairPlay.UploadGame`) and the file
  itself not kept; what could not be read is listed in `problems`.

  With a `tournament_id` the games are part of that tournament: their
  analysis counts in its report and is deleted with it. Without one the
  upload is its own report, deleted `Alnasl.FairPlay.retention_days/0`
  after it was uploaded unless the owner keeps it longer (`keep_until`,
  with a reason, at most 365 days). See `Alnasl.FairPlay.Uploads`.
  """
  use Ecto.Schema

  schema "fair_play_uploads" do
    field :hall_id, :integer
    field :tournament_id, :integer
    field :name, :string
    field :filename, :string
    field :byte_size, :integer
    field :sha256, :string
    field :uploaded_by, :string
    field :uploaded_by_id, :integer
    field :accepted, :integer, default: 0
    field :rejected, :integer, default: 0
    field :problems, :string
    field :keep_until, :utc_datetime
    field :keep_reason, :string
    field :keep_set_by, :string
    timestamps(type: :utc_datetime)
  end

  @doc "The problems as a list of maps (string keys)."
  def problems(%__MODULE__{problems: nil}), do: []

  def problems(%__MODULE__{problems: json}) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _broken -> []
    end
  end
end
