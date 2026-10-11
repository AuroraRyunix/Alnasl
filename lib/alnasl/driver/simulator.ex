defmodule Alnasl.Driver.Simulator do
  @moduledoc """
  A board nobody built: a game from a PGN, played onto a virtual board by
  `Alnasl.Simulator.Script` and delivered as a real board would deliver it,
  lifted pieces, two-step captures and all.

  Options (the board's `options` JSON, string keys):

  - `"moves"` - the game, as a list of SAN; or `"game"`, the number of a
    bundled game (`priv/games`, 1-based);
  - `"start_fen"` - when the game does not begin from the start position;
  - `"speed"` - how much faster than life (default 20);
  - `"faults"` - `%{"lift" => 0.1, ...}`, see `Alnasl.Simulator.Script`;
  - `"seed"`, `"clock"` (default true), `"unplug"` (`[[ply, plies]]`),
    `"illegal_at"`, `"gesture"` (a result, to end with the kings in the centre);
  - `"start_delay_ms"` - how long the board stands in the start position
    before the first move.
  """

  @behaviour Alnasl.Driver

  alias Alnasl.{Driver.Player, Pgn}
  alias Alnasl.Simulator.Script

  @fault_atoms %{
    "missed" => :missed,
    "lift" => :lift,
    "knock" => :knock,
    "swap" => :swap,
    "hover" => :hover,
    "takeback" => :takeback,
    "slide" => :slide,
    "clock_miss" => :clock_miss,
    "leave_pawn" => :leave_pawn
  }
  @faults Map.keys(@fault_atoms)

  @impl true
  def start_link(opts) do
    options = Keyword.get(opts, :options, %{})
    script = script(options)

    Player.start_link(
      owner: Keyword.fetch!(opts, :owner),
      id: Keyword.fetch!(opts, :id),
      events: script.events,
      speed: number(options["speed"], 20),
      start_delay_ms: number(options["start_delay_ms"], 1_500)
    )
  end

  @doc "The script a board with these options plays."
  def script(options) do
    Script.build(moves(options), script_options(options))
  end

  @doc "The moves a board with these options plays."
  def moves(%{"moves" => moves}) when is_list(moves), do: moves

  def moves(options) do
    games = Pgn.all_bundled()
    index = options["game"] |> number(1) |> round() |> max(1)
    Enum.at(games, rem(index - 1, length(games))).moves
  end

  defp script_options(options) do
    faults =
      for {name, rate} <- options["faults"] || %{}, is_map_key(@fault_atoms, name), is_number(rate), into: %{} do
        {Map.fetch!(@fault_atoms, name), rate}
      end

    %{
      seed: options["seed"] |> number(1) |> round(),
      faults: faults,
      clock: options["clock"] != false,
      start_fen: options["start_fen"],
      gesture: options["gesture"],
      illegal_at: options["illegal_at"],
      unplug: for([ply, plies] <- options["unplug"] || [], do: {ply, plies})
    }
  end

  defp number(value, _default) when is_number(value), do: value
  defp number(_other, default), do: default

  @doc "The faults a simulated board can be given, by name."
  def faults, do: @faults
end
