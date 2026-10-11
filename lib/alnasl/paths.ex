defmodule Alnasl.Paths do
  @moduledoc """
  Where the box keeps things. One directory (`config :alnasl, :data_dir`,
  `ALNASL_DATA`) holds the database, the raw captures, the PGN of every game
  and the fixtures exported from captures.
  """

  def data, do: ensure(Application.fetch_env!(:alnasl, :data_dir))
  def captures, do: ensure(Path.join(data(), "captures"))
  def pgn, do: ensure(Path.join(data(), "pgn"))
  def fixtures, do: ensure(Path.join(data(), "fixtures"))

  defp ensure(dir) do
    File.mkdir_p!(dir)
    dir
  end
end
