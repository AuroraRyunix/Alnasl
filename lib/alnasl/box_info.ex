defmodule Alnasl.BoxInfo do
  @moduledoc """
  Which copy of Alnasl this is, and where it keeps what it knows.

  Boards are known by their serial number, and the number on a board's
  sticker, the tournaments and the codes live in the box's database, in its
  data folder. That folder depends on how the program was started
  (`Alnasl.DataHome`): a checkout run from source keeps `./data`, an
  installed copy `%LOCALAPPDATA%\AlnaslData`, the Linux service
  `/var/lib/alnasl`. So a copy started one way and a copy started another
  way on the same computer share nothing: not the boards, not their numbers,
  not the tournaments. Setup shows this so that nobody has to guess.
  """

  alias Alnasl.{Boards, Paths, Tournaments, Updates}

  @doc """
  How this copy was started: `:installed` (the Windows installer),
  `:service` (the Linux service), `:portable` (a release folder, run from
  where it was unpacked) or `:source` (a checkout).
  """
  def kind do
    case Updates.install_kind() do
      :velopack -> :installed
      :systemd -> :service
      :manual -> if System.get_env("RELEASE_ROOT"), do: :portable, else: :source
    end
  end

  @doc "Everything the panel shows."
  def info do
    %{
      version: Updates.current_version(),
      kind: kind(),
      data_dir: Path.expand(Paths.data()),
      boards: length(Boards.list()),
      tournaments: length(Tournaments.active())
    }
  end
end
