defmodule Alnasl.FairPlay.Analysis do
  @moduledoc """
  The job of the live queue: bring the stored analysis of one game up to
  date with the game as it stands now, doing as little engine work as
  possible. Everything the core library does (`Alnasl.FairPlay.Analyzer`,
  `Alnasl.FairPlay.Selection`) is used as it is; this module is the glue to
  the database.

  ## What is redone, and what is not

  A stored row (`Alnasl.FairPlay.Move`) is reused when it was made by the
  same engine, bench and node count **and** its `prefix_hash` is still the
  game's: the start position and every move up to and including its own.
  So a ply already analysed is not analysed again, and a ply the tracker
  rewrote takes every row after it with it (their hashes no longer match),
  after which the new moves are analysed as the new plies they are. Rows
  for plies that no longer exist are deleted.

  ## Which plies are analysed now

  A ply is *final* when it is not guessed (red: the tracker was not sure
  what was played) and not reconstructed (orange: the moves are certain but
  a later reading may still rewrite them) - until the game is finished,
  after which orange plies are final too. Only final plies reach the
  engine. A guessed ply is stored at once as skipped (`:tracker_guessed`),
  and so is every ply after it, since after a wrong guess every position is
  fiction (the core's rule). A ply still waiting to become final is not
  stored at all.

  The rules that need no engine are applied on every run, to every ply,
  because they depend on facts that change: the arbiter confirming the
  result turns `:tracker_rewritten` plies into counted ones, and a rating
  arriving with the pairing turns `:unrated` into counted.

  ## Players and ratings

  A player is the pairing program's id when the game has one
  (`remote_white`), else the name on the game. Ratings come from the
  tournament's pairing document (`Alnasl.Tournaments.boards/2`); a local
  tournament has none, and its games are all `:unrated`.
  """

  import Ecto.Query

  alias Alnasl.{Games, Repo, Tournaments}
  alias Alnasl.FairPlay.{Analyzer, Move, Selection, Setting}
  alias Alnasl.Games.Game

  require Logger

  @doc """
  Updates the rows of game `game_id`. `engine` is a function as
  `Alnasl.FairPlay.Analyzer` takes it; `setting` the hall's
  `Alnasl.FairPlay.Setting`. Returns `:ok`, or `{:error, reason}` for a
  game that cannot be replayed.
  """
  @spec run(integer(), function(), struct()) :: :ok | {:error, term()}
  def run(game_id, engine, %Setting{} = setting) do
    case Repo.get(Game, game_id) do
      nil -> :ok
      game -> refresh(game, engine, setting)
    end
  end

  defp refresh(game, engine, setting) do
    ratings = ratings(game)
    input = Analyzer.from_game(game, ratings)
    plies = Games.plies(game)

    case Analyzer.prepare(input) do
      {:ok, records} ->
        hashes = prefix_hashes(game, records)
        existing = existing(game.id)
        {reusable, stale} = split(existing, hashes, setting)
        records = reuse(records, reusable)
        finished? = game.status == "finished"

        wanted =
          for {record, ply} <- Enum.zip(records, plies),
              record.skip == nil and record.best == nil and final?(ply, finished?),
              do: record.ply

        records =
          if wanted == [],
            do: records,
            else: Analyzer.evaluate(input, records, engine, only: wanted)

        store(game, records, plies, hashes, existing, stale, setting, finished?)

      {:error, reason} ->
        Logger.warning("fair play: game #{game.id} cannot be replayed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # --- what is final -----------------------------------------------------------

  defp final?(ply, finished?) do
    :guessed not in ply.flags and (:recovered not in ply.flags or finished?)
  end

  # --- ratings and players -----------------------------------------------------

  defp ratings(game) do
    board =
      game.tournament_id
      |> Tournaments.boards(game.round)
      |> Enum.find(&(&1.board == game.board_no))

    %{white: board && board.white_rating, black: board && board.black_rating}
  end

  @doc "The key a player is known by within a tournament: the pairing program's id, else the name."
  def player_key(game, :white), do: key(game.remote_white, game.white)
  def player_key(game, :black), do: key(game.remote_black, game.black)

  defp key(id, _name) when is_integer(id), do: "id:#{id}"
  defp key(_id, name) when is_binary(name) and name != "", do: "name:" <> String.trim(name)
  defp key(_id, _name), do: "unknown"

  defp player_name(game, :white), do: game.white
  defp player_name(game, :black), do: game.black

  # --- the hash chain ----------------------------------------------------------

  # A digest per ply of the start position and the moves up to it.
  defp prefix_hashes(game, records) do
    seed = :crypto.hash_init(:sha256) |> :crypto.hash_update(game.start_fen || "start")

    {hashes, _state} =
      Enum.map_reduce(records, seed, fn record, state ->
        state = :crypto.hash_update(state, <<0>> <> record.played_uci)
        {state |> :crypto.hash_final() |> Base.encode16(case: :lower), state}
      end)

    hashes
  end

  # --- what is stored ----------------------------------------------------------

  defp existing(game_id),
    do: Repo.all(from m in Move, where: m.game_id == ^game_id, order_by: m.ply)

  defp split(existing, hashes, setting) do
    by_ply = hashes |> Enum.with_index(1) |> Map.new(fn {hash, ply} -> {ply, hash} end)

    Enum.split_with(existing, fn row ->
      Map.get(by_ply, row.ply) == row.prefix_hash and same_engine?(row, setting)
    end)
  end

  defp same_engine?(row, setting) do
    row.engine_id == setting.engine_id and row.bench == setting.engine_bench and
      row.nodes == setting.nodes
  end

  # A stored answer stands in for asking the engine again. Only rows that
  # have the engine's answer are reused: a ply stored as `:no_analysis` is
  # tried again.
  defp reuse(records, rows) do
    answered =
      rows |> Enum.filter(&(&1.best != nil and &1.played_cp != nil)) |> Map.new(&{&1.ply, &1})

    Enum.map(records, fn record ->
      case {record.skip, answered[record.ply]} do
        {nil, %Move{} = row} ->
          %{
            record
            | best: Move.decode_best(row.best),
              played_cp: row.played_cp,
              rank: row.rank,
              gap: row.gap,
              near_count: row.near_count
          }
          |> Selection.after_engine()

        _no ->
          record
      end
    end)
  end

  defp store(game, records, plies, hashes, existing, stale, setting, finished?) do
    now = DateTime.utc_now(:second)
    existing_by_ply = Map.new(existing, &{&1.ply, &1})

    rows =
      for {{record, ply}, hash} <- Enum.zip(Enum.zip(records, plies), hashes),
          # Not stored: a ply still waiting to become final.
          record.skip != nil or record.best != nil or final?(ply, finished?),
          do: row(game, record, hash, setting, now)

    changed =
      Enum.reject(rows, fn row ->
        case existing_by_ply[row.ply] do
          %Move{} = old -> same?(old, row)
          nil -> false
        end
      end)

    keep_plies = MapSet.new(rows, & &1.ply)

    drop =
      for old <- existing, old in stale or not MapSet.member?(keep_plies, old.ply), do: old.id

    {:ok, _} =
      Repo.transaction(fn ->
        if drop != [], do: Repo.delete_all(from m in Move, where: m.id in ^drop)

        for chunk <- Enum.chunk_every(changed, 100) do
          Repo.insert_all(Move, chunk,
            on_conflict: {:replace_all_except, [:id, :inserted_at]},
            conflict_target: [:game_id, :ply]
          )
        end
      end)

    :ok
  end

  @compared ~w(prefix_hash best played_cp rank gap near_count material clock_before_ms rating
               skip engine_id engine_version bench nodes player_key player_name san)a

  defp same?(old, row), do: Map.take(old, @compared) == Map.take(row, @compared)

  defp row(game, record, hash, setting, now) do
    colour = record.colour

    %{
      tournament_id: game.tournament_id,
      game_id: game.id,
      round: game.round,
      board_no: game.board_no,
      ply: record.ply,
      colour: Atom.to_string(colour),
      move_number: record.move_number,
      player_key: player_key(game, colour),
      player_name: player_name(game, colour),
      san: record.san,
      played_uci: record.played_uci,
      fen: record.fen,
      prefix_hash: hash,
      best: Move.encode_best(record.best),
      played_cp: record.played_cp,
      rank: record.rank,
      gap: record.gap,
      near_count: record.near_count,
      material: record.material,
      clock_before_ms: record.clock_before_ms,
      rating: record.rating,
      skip: record.skip && Atom.to_string(record.skip),
      engine_id: setting.engine_id,
      engine_version: setting.engine_version,
      bench: setting.engine_bench,
      nodes: setting.nodes,
      inserted_at: now,
      updated_at: now
    }
  end
end
