defmodule Alnasl.Destination.OpenPairings do
  @moduledoc """
  The pairing program, as a destination: each game of a linked tournament
  goes back to the tournament it came from (`POST
  <root>/tournaments/:id/games`, `docs/board-link-api.md` in OpenPairings).

  ## What is sent

  The game as it is now, whole: the moves in SAN, the clock after each
  move, both clocks as they read, the game's PGN as the box writes it,
  whether it is waiting, live or finished, how many of its moves the box
  reconstructed, guessed and rewrote, and **the result the board saw** -
  the one the arbiter set on the box, or, while nobody has, the one the
  position shows (mate, the kings in the centre). The pairing program shows
  that beside the pairing. It does not enter it: a board never enters a
  result.

  ## Which games

  The game of a pairing: one the pairing program named (`remote_game`), in
  a tournament it still lists. Not a game kept on the box - a second game
  on the same board has no place there, the contract knows one game a
  pairing - and not a game whose pairing changed under it
  (`pairing_flag`): the pairing program would refuse it, and what becomes
  of it is the arbiter's to say first.

  ## Its place in the queue

  As for Lichess: `games.seq` counts every change, and for each game this
  destination remembers the count at the last report that was answered
  (`destination_cursors`). Offline for an afternoon, what goes out
  afterwards is each game as it stands then, lowest board first.

  ## `seq`

  The contract wants a number per game that only grows. It is the game's
  row and its counter in one (`id * 2^32 + seq`), so a game begun again for
  the same pairing outranks the one set aside. A box that was wiped and
  set up again starts lower than what the pairing program holds and is
  told `stale`: the game is then listed as refused, and "Send again,
  whatever is held" (`force/1`) sends it with `replace: true` - the
  arbiter's say-so the contract asks for.

  ## Not on a timer

  The clock refresh the results site gets every twenty seconds is not for
  the pairing program, which shows no running clock: a change that leaves
  everything but the clocks as it was is not sent.

  ## The answers

  | per game | |
  |---|---|
  | `applied: true`, or `duplicate` | done |
  | `stale` | done with, and listed: the pairing program holds something newer |
  | `pairing_changed`, `pairing_gone` | not sent again; the game is flagged if it has moves, and the tournament is fetched again at once |
  | `not_a_game`, `invalid_request` | not sent again, and listed with what was said |

  | the request | |
  |---|---|
  | 401 | the code is refused: the link says so and the sender waits |
  | 404 `tournament_not_found` | the tournament is marked gone |
  | 429, 5xx, nothing | again later |
  """

  @behaviour Alnasl.Destination

  import Ecto.Query

  alias Alnasl.{Games, Log, Repo, Tournaments}
  alias Alnasl.Destination.Cursor
  alias Alnasl.Games.Game
  alias Alnasl.OpenPairings.Client
  alias Alnasl.Tournaments.{Link, Tournament}

  @id "openpairings"
  @batch 64
  @max_plies 1000
  @max_pgn 100_000
  @max_ms 360_000_000

  @impl true
  def id, do: @id

  @impl true
  def configured?, do: Repo.exists?(Link)

  @impl true
  def setting_keys, do: []

  @impl true
  def coalesce_ms, do: Application.get_env(:alnasl, :openpairings_coalesce_ms, 500)

  @impl true
  def default_enabled?, do: true

  # --- what waits --------------------------------------------------------------

  defp waiting_query do
    from g in Game,
      join: t in Tournament,
      on: t.id == g.tournament_id,
      left_join: c in Cursor,
      on: c.game_id == g.id and c.destination == @id,
      where:
        t.kind == "linked" and not t.gone and not g.local and not is_nil(g.remote_game) and
          is_nil(g.pairing_flag) and g.seq > coalesce(c.acked_seq, 0),
      order_by: [g.tournament_id, g.round, g.board_no]
  end

  @impl true
  def pending_count, do: Repo.aggregate(waiting_query(), :count)

  @doc "How many games wait for each tournament's pairing program: `%{tournament_id => count}`."
  def pending_by_tournament do
    waiting_query()
    |> exclude(:order_by)
    |> group_by([g], g.tournament_id)
    |> select([g], {g.tournament_id, count(g.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc "What the pairing program said about the games it did not take: `[{game, message}]`."
  def refused do
    Repo.all(
      from c in Cursor,
        join: g in Game,
        on: g.id == c.game_id,
        where: c.destination == @id and not is_nil(c.error),
        order_by: [g.tournament_id, g.round, g.board_no],
        select: {g, c.error}
    )
  end

  @doc """
  "Send again, whatever is held": the games the pairing program called
  stale go out once more with `replace: true`. `tournament_ids` keeps it to
  the games of those tournaments (the halls of whoever asked; see
  `Alnasl.Halls.tournament_ids/1`); `nil` is every tournament on the box.
  """
  def force(tournament_ids \\ nil) do
    stale = from(c in Cursor, where: c.destination == @id and c.error == "stale")

    stale =
      if is_list(tournament_ids) do
        mine = from(g in Game, where: g.tournament_id in ^tournament_ids, select: g.id)
        from(c in stale, where: c.game_id in subquery(mine))
      else
        stale
      end

    {count, _} = Repo.update_all(stale, set: [force: true, acked_seq: 0, error: nil])

    if count > 0, do: Log.add(:info, "destination.forced", %{destination: @id, games: count})
    Alnasl.Destination.send_now(__MODULE__)
    count
  end

  # --- sending -----------------------------------------------------------------

  @impl true
  def deliver do
    if configured?() do
      games = waiting_query() |> limit(@batch) |> Repo.all()
      cursors = cursors(games)

      {results, sent} =
        games
        |> Enum.group_by(& &1.tournament_id)
        |> Enum.map_reduce(0, fn {tournament_id, games}, sent ->
          {result, n} = deliver_tournament(Tournaments.get!(tournament_id), games, cursors)
          {result, sent + n}
        end)

      if sent > 0, do: Phoenix.PubSub.broadcast(Alnasl.PubSub, "outbox", :outbox_changed)

      result =
        Enum.find(results, &match?({:blocked, _}, &1)) ||
          Enum.find(results, &match?({:retry, _, _}, &1)) ||
          if(Repo.exists?(waiting_query()) and results != [], do: :more, else: :empty)

      {result, sent}
    else
      {:unconfigured, 0}
    end
  end

  defp deliver_tournament(%Tournament{} = tournament, games, cursors) do
    link = Tournaments.link_of(tournament)

    # What is as it was at the last report, clocks aside, is done without a word.
    {same, changed} =
      games
      |> Enum.map(&{&1, report(&1, cursors[&1.id])})
      |> Enum.split_with(fn {game, report} ->
        cursor = cursors[game.id]

        cursor != nil and cursor.error == nil and not cursor.force and
          cursor.digest == digest(report)
      end)

    for {game, report} <- same, do: ack(cursors[game.id], game, report, nil, false)

    cond do
      changed == [] ->
        {:empty, 0}

      link == nil or link.state in ["unauthorized", "unsupported"] ->
        {{:blocked, :unauthorized}, 0}

      true ->
        case Client.report(link, tournament.remote_id, Enum.map(changed, &elem(&1, 1))) do
          {:ok, answers} ->
            taken =
              changed
              |> Enum.with_index()
              |> Enum.count(fn {{game, report}, index} ->
                answered(cursors[game.id], game, report, Enum.at(answers, index))
              end)

            if Enum.any?(answers, &(is_map(&1) and &1["status"] == "error")),
              do: Alnasl.OpenPairings.refetch(tournament)

            {:empty, taken}

          {:error, :unauthorized} ->
            link
            |> Ecto.Changeset.change(%{state: "unauthorized", error: "unauthorized"})
            |> Repo.update!()

            Log.add(:error, "link.unauthorized", %{
              server: Alnasl.OpenPairings.Code.host(link.root)
            })

            Tournaments.notify(nil)
            {{:blocked, :unauthorized}, 0}

          {:error, :tournament_not_found} ->
            Log.add(:warn, "tournament.gone", %{tournament: Tournaments.title(tournament) || ""})
            Tournaments.update!(tournament, %{gone: true})
            {:empty, 0}

          {:error, {:rate_limited, wait}} ->
            {{:retry, :rate_limited, wait}, 0}

          {:error, {:refused, _status, code, detail}} ->
            # The request as a whole is wrong and stays wrong: these games
            # are not sent again as they are.
            for {game, report} <- changed,
                do: ack(cursors[game.id], game, report, error(code, detail), true)

            {:empty, 0}

          {:error, {:http, status}} ->
            {{:retry, {:http, status, nil}, nil}, 0}

          {:error, reason} ->
            {{:retry, reason, nil}, 0}
        end
    end
  end

  # Was the game taken?
  defp answered(cursor, game, report, %{"status" => "ok"} = answer) do
    stale? = answer["applied"] == false and answer["reason"] == "stale"
    ack(cursor, game, report, if(stale?, do: "stale"), true)
    not stale?
  end

  defp answered(cursor, game, report, %{"status" => "error", "error" => code} = answer) do
    if code in ["pairing_changed", "pairing_gone"] and Games.begun?(game) do
      Alnasl.OpenPairings.Sync.flag(game, if(code == "pairing_gone", do: "gone", else: "changed"))
    end

    ack(cursor, game, report, error(code, answer["detail"]), true)
    false
  end

  defp answered(cursor, game, report, _nothing) do
    ack(cursor, game, report, "no_answer", true)
    false
  end

  defp error(code, detail) when is_binary(detail) and detail != "",
    do: String.slice("#{code}: #{detail}", 0, 500)

  defp error(code, _detail), do: to_string(code)

  defp cursors([]), do: %{}

  defp cursors(games) do
    ids = Enum.map(games, & &1.id)

    Cursor
    |> where([c], c.destination == @id and c.game_id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.game_id, &1})
  end

  # The count that is acknowledged is the one read before the report was
  # made: a move that arrived while the request was out leaves the game
  # waiting.
  defp ack(cursor, game, report, error, sent?) do
    changes = %{
      acked_seq: game.seq,
      error: error,
      force: false,
      digest: if(error, do: nil, else: digest(report))
    }

    changes = if sent?, do: Map.put(changes, :sent_at, DateTime.utc_now(:second)), else: changes

    (cursor || %Cursor{destination: @id, game_id: game.id})
    |> Ecto.Changeset.change(changes)
    |> Repo.insert_or_update!()
  end

  # Everything but the clocks as they read now, the counter and the PGN
  # (which says the same as the rest).
  defp digest(report) do
    report
    |> Map.drop(~w(seq white_ms black_ms running pgn replace))
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # --- the report --------------------------------------------------------------

  @doc "The number the contract calls `seq`: it only grows, per pairing."
  def seq(%Game{id: id, seq: seq}), do: id * 4_294_967_296 + seq

  @doc "One game as the contract's report. `cursor` says whether the arbiter forced it."
  def report(%Game{} = game, cursor \\ nil) do
    plies = Enum.take(Games.plies(game), @max_plies)
    black_first? = black_first?(game)
    clock = clock(game)
    pgn = Games.pgn(game)

    %{
      "game" => game.remote_game,
      "white" => game.remote_white,
      "black" => game.remote_black,
      "seq" => seq(game),
      "status" => status(game, plies),
      "moves" => Enum.map(plies, & &1.san),
      "move_clocks" =>
        plies
        |> Enum.with_index(if(black_first?, do: 1, else: 0))
        |> Enum.map(fn {ply, index} ->
          ms(ply.clock && ply.clock[if(rem(index, 2) == 0, do: :white_ms, else: :black_ms)])
        end),
      "result" => result(game),
      "reconstructed" => Enum.count(plies, &(:recovered in &1.flags)),
      "guessed" => Enum.count(plies, &(:guessed in &1.flags)),
      # A move first read as another move of the same piece. Such a move is
      # also orange or red, so it is in one of the two counts above as well.
      "rewritten" => Enum.count(plies, &(:rewritten in &1.flags))
    }
    |> put("white_ms", ms(clock["white_ms"]))
    |> put("black_ms", ms(clock["black_ms"]))
    |> put(
      "running",
      cond do
        clock == %{} -> nil
        game.status == "finished" -> "none"
        clock["running"] in ["white", "black"] -> clock["running"]
        true -> "none"
      end
    )
    |> put("start_fen", game.start_fen)
    |> put("pgn", if(byte_size(pgn) <= @max_pgn, do: pgn))
    |> put("replace", if(cursor && cursor.force, do: true))
  end

  defp status(%Game{status: "finished"}, _plies), do: "finished"
  defp status(_game, []), do: "waiting"
  defp status(_game, _plies), do: "live"

  @seen ["1-0", "0-1", "1/2-1/2"]

  # What the board saw: the arbiter's word on the box when the game is
  # closed, else what the position shows and nobody has confirmed.
  defp result(%Game{status: "finished", result: result}) when result in @seen, do: result
  defp result(%Game{status: "finished"}), do: nil
  defp result(%Game{suggestion: suggestion}) when suggestion in @seen, do: suggestion
  defp result(_game), do: nil

  defp clock(%Game{clock: nil}), do: %{}

  defp clock(%Game{clock: json}) do
    case Jason.decode(json) do
      {:ok, %{} = clock} -> clock
      _other -> %{}
    end
  end

  defp ms(value) when is_integer(value) and value >= 0, do: min(value, @max_ms)
  defp ms(_other), do: nil

  defp black_first?(%Game{start_fen: nil}), do: false

  defp black_first?(%Game{start_fen: fen}),
    do: match?({:ok, %{turn: :b}}, Alnasl.Chess.parse_fen(fen))

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)
end
