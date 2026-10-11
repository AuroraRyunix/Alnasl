defmodule Alnasl.Pgn do
  @moduledoc """
  PGN in and out, with the moves checked.

  `load/1` reads games and replays each with `Alnasl.Chess`: what comes back
  is canonical SAN, or the game is reported with the ply that is not legal.
  `write/1` is what the box keeps of a finished game - headers, moves, and
  the clock after a move as a `[%clk]` comment when a clock was read.
  """

  alias Alnasl.{Chess, PgnReader}

  @type game :: %{
          headers: map(),
          moves: [String.t()],
          clocks: [integer() | nil],
          result: String.t(),
          start_fen: String.t() | nil
        }

  @doc """
  Every game in `text`: `{games, problems}` where `problems` is
  `[{index, white, black, message}]` for the games that do not replay.
  """
  @spec load(String.t()) :: {[game()], [tuple()]}
  def load(text) when is_binary(text) do
    text
    |> PgnReader.parse()
    |> Enum.with_index(1)
    |> Enum.reduce({[], []}, fn {game, index}, {good, bad} ->
      fen = game.headers["FEN"]

      case Chess.replay(fen || Chess.start_fen(), game.moves) do
        {:ok, plies} ->
          game = game |> Map.put(:moves, Enum.map(plies, & &1.san)) |> Map.put(:start_fen, fen)
          {[game | good], bad}

        {:error, {ply, message}} ->
          {good,
           [{index, game.headers["White"], game.headers["Black"], "ply #{ply}: #{message}"} | bad]}

        {:error, message} ->
          {good, [{index, game.headers["White"], game.headers["Black"], message} | bad]}
      end
    end)
    |> then(fn {good, bad} -> {Enum.reverse(good), Enum.reverse(bad)} end)
  end

  @doc "The games of a PGN file that ships with Alnasl (`priv/games/<name>`)."
  def bundled(name) do
    {games, _problems} =
      :alnasl |> :code.priv_dir() |> Path.join("games/#{name}") |> File.read!() |> load()

    games
  end

  @doc "Every bundled game, classics first. Read and checked once, then kept."
  def all_bundled do
    case :persistent_term.get({__MODULE__, :bundled}, nil) do
      nil ->
        dir = :alnasl |> :code.priv_dir() |> Path.join("games")

        games =
          dir
          |> File.ls!()
          |> Enum.filter(&String.ends_with?(&1, ".pgn"))
          |> Enum.sort_by(&{&1 != "classics.pgn", &1})
          |> Enum.flat_map(&bundled/1)

        :persistent_term.put({__MODULE__, :bundled}, games)
        games

      games ->
        games
    end
  end

  @doc """
  One game as PGN. `game` has `:headers` (a map or an ordered list of pairs),
  `:moves` (SAN), optionally `:clocks` (ms after each move, or `nil`),
  `:result` and `:start_fen`.
  """
  @spec write(map()) :: String.t()
  def write(game) do
    result = game[:result] || "*"
    headers = Enum.to_list(game[:headers] || [])

    seven =
      for name <- ~w(Event Site Date Round White Black) do
        {name, find(headers, name) || "?"}
      end ++ [{"Result", result}]

    extra =
      Enum.reject(headers, fn {name, _} ->
        to_string(name) in ~w(Event Site Date Round White Black Result FEN SetUp)
      end)

    setup =
      case game[:start_fen] do
        nil -> []
        fen -> if fen == Chess.start_fen(), do: [], else: [{"SetUp", "1"}, {"FEN", fen}]
      end

    tags =
      Enum.map_join(seven ++ extra ++ setup, "\n", fn {name, value} ->
        ~s([#{name} "#{escape(value)}"])
      end)

    first_number =
      case game[:start_fen] && Chess.parse_fen(game[:start_fen]) do
        {:ok, pos} -> {pos.fullmove, pos.turn}
        _standard -> {1, :w}
      end

    tags <>
      "\n\n" <> movetext(game[:moves] || [], game[:clocks] || [], first_number, result) <> "\n"
  end

  defp find(headers, name) do
    Enum.find_value(headers, fn {key, value} -> to_string(key) == name && value end)
  end

  defp escape(value),
    do: value |> to_string() |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")

  defp movetext(moves, clocks, {number, turn}, result) do
    {tokens, _state} =
      moves
      |> Enum.with_index()
      |> Enum.flat_map_reduce({number, turn, true}, fn {san, index}, {number, turn, lead?} ->
        prefix =
          cond do
            turn == :w -> ["#{number}."]
            lead? -> ["#{number}..."]
            true -> []
          end

        clock =
          case Enum.at(clocks, index) do
            nil -> []
            ms -> ["{[%clk #{clk(ms)}]}"]
          end

        next = if turn == :w, do: {number, :b, clock != []}, else: {number + 1, :w, false}
        {prefix ++ [san] ++ clock, next}
      end)

    wrap(tokens ++ [result], 80)
  end

  defp clk(ms) do
    total = div(max(ms, 0), 1000)
    pad = &String.pad_leading(Integer.to_string(&1), 2, "0")
    "#{div(total, 3600)}:#{pad.(total |> rem(3600) |> div(60))}:#{pad.(rem(total, 60))}"
  end

  defp wrap(tokens, width) do
    tokens
    |> Enum.reduce([""], fn token, [line | lines] ->
      cond do
        line == "" -> [token | lines]
        String.length(line) + 1 + String.length(token) > width -> [token, line | lines]
        true -> [line <> " " <> token | lines]
      end
    end)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  @doc """
  Where two move lists first differ: `:same`, or `{ply, a, b}` with the
  1-based ply and each side's move there (`nil` where a list has ended).
  Check marks are not a difference.
  """
  def first_difference(a, b) do
    bare = &String.replace(&1, ~r/[+#!?]+$/, "")

    0..max(length(a), length(b))
    |> Enum.find_value(:same, fn i ->
      {x, y} = {Enum.at(a, i), Enum.at(b, i)}

      cond do
        x == nil and y == nil -> nil
        x == nil or y == nil -> {i + 1, x, y}
        bare.(x) != bare.(y) -> {i + 1, x, y}
        true -> nil
      end
    end)
  end
end
