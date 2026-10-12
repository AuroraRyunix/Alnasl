defmodule Alnasl.Destination.LichessBroadcast do
  @moduledoc """
  A Lichess broadcast round, fed by pushing PGN to it.

  ## What is sent

  Not messages: **the game as it is now**. Whenever a game of the round has
  changed - a move, a correction, a result - its whole PGN goes to Lichess
  again, with the players as the pairing program knows them (names, titles,
  ratings, FIDE ids), the round and the board, the result, and the clock
  after each move as a `{[%clk h:mm:ss]}` comment. A correction needs no
  special word: the PGN simply says something else from some move on, and
  Lichess brings its copy into line (see `Alnasl.Destination.LichessApi` for
  how sure that is).

  ## Its place in the queue

  `games.seq` counts every change queued for a game. For each game this
  destination remembers the count at the last push Lichess answered for
  (`destination_cursors`). A game whose count is ahead is waiting. So:

  - nothing is lost by being offline, however long: the count is in the
    database, and what goes out afterwards is the game as it stands then;
  - a push can never undo a newer one: the PGN is made when it is sent;
  - the results server being down, refused or switched off is no concern of
    this queue, nor the other way round.

  ## Not too often

  The sender waits `coalesce_ms/0` (2 s) after being woken, so a burst of
  moves - or a recovery of four at once, or six boards moving in the same
  second - is **one request with every changed game of the round in it**,
  and Lichess is asked at most once every two seconds. A change that leaves
  the PGN as it was (the clock refresh between moves) is not sent at all.
  On `429` it stays silent for as long as Lichess asks, a minute if it does
  not say.

  ## One round

  A Lichess round is one round. `lichess_round` says which round of the
  tournament it is (the round in play when the card was saved); games of
  other rounds are not for this destination and do not count as waiting.

  ## Settings

  `lichess_round_id` (eight characters), `lichess_token` (a secret: stored
  as given because it must be sent, never logged, never shown again in
  full), `lichess_round`, `lichess_url`.
  """

  @behaviour Alnasl.Destination

  import Ecto.Query

  alias Alnasl.{Games, Pgn, Repo, Settings, Tournament}
  alias Alnasl.Destination.{Cursor, LichessApi}
  alias Alnasl.Games.Game

  @id "lichess"
  @batch 64

  @impl true
  def id, do: @id

  @impl true
  def configured? do
    s = Settings.get_many(~w(lichess_round_id lichess_token))
    s["lichess_round_id"] not in [nil, ""] and s["lichess_token"] not in [nil, ""]
  end

  @impl true
  def setting_keys, do: ~w(lichess_round_id lichess_token lichess_round lichess_url)

  @impl true
  def coalesce_ms, do: Application.get_env(:alnasl, :lichess_coalesce_ms, 2_000)

  @impl true
  def default_enabled?, do: false

  @doc "The round of the tournament that goes to the Lichess round."
  def round do
    case Settings.get("lichess_round") do
      n when is_integer(n) and n > 0 -> n
      _unset -> Settings.get("round") || 1
    end
  end

  @doc "`\"lip_...9f2c\"`: enough to tell two tokens apart, not enough to use."
  def token_hint do
    case Settings.get("lichess_token") do
      token when is_binary(token) and byte_size(token) > 12 ->
        String.slice(token, 0, 4) <> "..." <> String.slice(token, -4, 4)

      token when is_binary(token) and token != "" ->
        "..."

      _none ->
        nil
    end
  end

  # --- what waits --------------------------------------------------------------

  defp waiting_query(round) do
    from g in Game,
      left_join: c in Cursor,
      on: c.game_id == g.id and c.destination == @id,
      # Game 1 of a board only: see `Alnasl.Outbox.enqueue/3`.
      where: g.round == ^round and g.game_no == 1 and g.seq > coalesce(c.acked_seq, 0),
      order_by: g.board_no
  end

  @impl true
  def pending_count, do: Repo.aggregate(waiting_query(round()), :count)

  @doc "The games waiting for Lichess, lowest board first."
  def waiting, do: Repo.all(waiting_query(round()))

  @doc "What Lichess said about the games it refused: `[{game, message}]`."
  def refused do
    Repo.all(
      from c in Cursor,
        join: g in Game,
        on: g.id == c.game_id,
        where: c.destination == @id and not is_nil(c.error) and g.round == ^round(),
        order_by: g.board_no,
        select: {g, c.error}
    )
  end

  # --- sending -----------------------------------------------------------------

  @impl true
  def deliver do
    s = Settings.get_many(~w(lichess_round_id lichess_token))

    if s["lichess_round_id"] in [nil, ""] or s["lichess_token"] in [nil, ""] do
      {:unconfigured, 0}
    else
      round = round()
      games = waiting_query(round) |> limit(@batch) |> Repo.all()
      cursors = cursors(games)

      # A game whose PGN is what Lichess already has is done without a word.
      {same, changed} =
        games
        |> Enum.map(&{&1, pgn(&1)})
        |> Enum.split_with(fn {game, pgn} ->
          cursor = cursors[game.id]
          cursor != nil and cursor.error == nil and cursor.digest == digest(pgn)
        end)

      for {game, pgn} <- same, do: ack(cursors[game.id], game, pgn, nil, false)

      case changed do
        [] ->
          {if(more?(round), do: :more, else: :empty), 0}

        changed ->
          body = Enum.map_join(changed, "\n", &elem(&1, 1))

          case LichessApi.push(LichessApi.base(), s["lichess_round_id"], s["lichess_token"], body) do
            {:ok, answers} ->
              changed
              |> Enum.with_index()
              |> Enum.each(fn {{game, pgn}, index} ->
                error =
                  case Enum.at(answers, index) do
                    {:error, message} -> String.slice(message, 0, 500)
                    _taken -> nil
                  end

                ack(cursors[game.id], game, pgn, error, true)
              end)

              Phoenix.PubSub.broadcast(Alnasl.PubSub, "outbox", :outbox_changed)
              {if(more?(round), do: :more, else: :empty), length(changed)}

            other ->
              {other, 0}
          end
      end
    end
  end

  defp more?(round), do: Repo.exists?(waiting_query(round))

  defp cursors([]), do: %{}

  defp cursors(games) do
    ids = Enum.map(games, & &1.id)

    Cursor
    |> where([c], c.destination == @id and c.game_id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.game_id, &1})
  end

  # The count that is acknowledged is the one read before the PGN was made:
  # a move that arrived while the request was out leaves the game waiting.
  defp ack(cursor, game, pgn, error, sent?) do
    changes = %{
      acked_seq: game.seq,
      error: error,
      digest: if(error, do: nil, else: digest(pgn))
    }

    changes = if sent?, do: Map.put(changes, :sent_at, DateTime.utc_now(:second)), else: changes

    (cursor || %Cursor{destination: @id, game_id: game.id})
    |> Ecto.Changeset.change(changes)
    |> Repo.insert_or_update!()
  end

  defp digest(pgn), do: :sha256 |> :crypto.hash(pgn) |> Base.encode16(case: :lower)

  # --- the PGN -----------------------------------------------------------------

  @doc """
  One game as Lichess gets it: the box's own PGN of it, with the players as
  the pairing program describes them. Titles go in `WhiteTitle`/`BlackTitle`
  and not in front of the name, which is where Lichess looks for them.
  """
  def pgn(%Game{} = game) do
    players = Tournament.players(game.round, game.board_no)
    info = Tournament.info()
    plies = Games.plies(game)

    date =
      case List.first(plies) do
        %{at: at} when is_integer(at) ->
          at |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%Y.%m.%d")

        _none ->
          Calendar.strftime(game.inserted_at || DateTime.utc_now(), "%Y.%m.%d")
      end

    black_first? =
      game.start_fen != nil and match?({:ok, %{turn: :b}}, Alnasl.Chess.parse_fen(game.start_fen))

    offset = if black_first?, do: 1, else: 0

    clocks =
      plies
      |> Enum.with_index()
      |> Enum.map(fn {ply, index} ->
        ply.clock && ply.clock[if(rem(index + offset, 2) == 0, do: :white_ms, else: :black_ms)]
      end)

    Pgn.write(%{
      headers:
        [
          {"Event", info.name || Settings.get("slug") || "?"},
          {"Site", info.city || "?"},
          {"Date", date},
          {"Round", Integer.to_string(game.round)},
          {"White", name(players.white, game.white)},
          {"Black", name(players.black, game.black)},
          {"Board", Integer.to_string(game.board_no)}
        ] ++ extra("White", players.white) ++ extra("Black", players.black),
      moves: Enum.map(plies, & &1.san),
      clocks: clocks,
      result: if(game.status == "finished", do: game.result || "*", else: "*"),
      start_fen: game.start_fen
    })
  end

  defp name(%{name: name}, _stored) when is_binary(name) and name != "", do: name
  defp name(_none, stored), do: stored || "?"

  defp extra(_side, nil), do: []

  defp extra(side, player) do
    for {suffix, value} <- [
          {"Title", player.title},
          {"Elo", player.rating},
          {"FideId", player.fide_id}
        ],
        value != nil,
        do: {side <> suffix, to_string(value)}
  end
end
