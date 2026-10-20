defmodule Alnasl.FairPlay.Uploads do
  @moduledoc """
  Games that were not played on the boards, screened all the same: the
  owner uploads a PGN file, Alnasl reads it, keeps the games it can use,
  says per game what it could not, and analyses the rest through the same
  queue and engines as the live games (`Alnasl.FairPlay.Queue`), at a
  lower priority than they have.

  ## What is checked

  The file, before anything is stored (`read/2`):

    * its size: at most `max_bytes/0` (10 MB unless `config :alnasl,
      :fair_play_upload_max_bytes` says otherwise), which is thousands of
      games;
    * that it is text: no NUL bytes, not a zip or a gzip (`:binary`).
      UTF-8, or else Latin-1, which is what many older programs write;
    * that it has games: at least one with moves (`:no_games`), and at
      most `max_games/0` (`{:too_many, n}`);
    * the same file uploaded to the hall before (`{:already, upload}`).

  Every game (`check/3`), each on its own: a game that fails is refused
  and listed with the reason; the others go on.

    * standard chess (a `Variant` tag of anything else is refused);
    * every move legal from the start position (or the `FEN` tag's), by the
      box's own move generator: the first illegal one is named;
    * the same game twice in the file: the second is refused;
    * a game already recorded by the boards, in a tournament the upload is
      attached to (same round, same two players): kept, marked
      `"duplicate"`, never analysed twice;
    * the ratings, `WhiteElo` and `BlackElo`. A game without one is kept,
      and that player's moves are left out as "no rating", exactly as on
      the boards; the upload lists those games, so nobody wonders why a
      player has no score. A rating is never guessed.

  ## Players

  Without a tournament a player is their name in the PGN. Attached to a
  tournament, the pairing document's players are matched by FIDE ID
  (`WhiteFideId`) and then by name (case, commas and word order aside), so
  that a player who played some rounds on the boards and some without is
  one line in the report.

  ## What is kept, and for how long

  The games, as read, and their analysis. The file itself is not kept:
  only its name, size and SHA256. Nothing of an upload is ever served,
  only shown to those who may see the report. An upload attached to a
  tournament goes when the tournament's fair play goes; one on its own,
  `Alnasl.FairPlay.retention_days/0` after it was uploaded, unless the
  owner keeps it longer (`Alnasl.FairPlay.extend/4`). Uploading, and
  deleting, are written in the audit.
  """

  import Ecto.Query

  alias Alnasl.{PgnReader, Repo, Tournaments}
  alias Alnasl.Accounts.Scope
  alias Alnasl.FairPlay
  alias Alnasl.FairPlay.{Access, Analyzer, Grant, Pool, Queue, Uci}
  alias Alnasl.FairPlay.{Upload, UploadGame, UploadMove, View}
  alias Alnasl.Games.Game

  require Logger

  @max_bytes 10_000_000
  @max_games 2_000

  @doc "The largest file accepted, in bytes."
  def max_bytes do
    case Application.get_env(:alnasl, :fair_play_upload_max_bytes) do
      n when is_integer(n) and n > 0 -> n
      _unset -> @max_bytes
    end
  end

  @doc "The most games one file may hold."
  def max_games, do: @max_games

  @doc "The PubSub topic of an upload's progress."
  def topic(upload_id), do: "fair_play:upload:#{upload_id}"

  # --- reading -------------------------------------------------------------------

  @doc """
  The games of a file's bytes, or why there are none:
  `{:ok, [game]}` (as `Alnasl.PgnReader` reads them) or `{:error, reason}`,
  `reason` one of `:too_big`, `:binary`, `:no_games`, `{:too_many, n}`.
  """
  def read(bytes, max \\ max_bytes())

  def read(bytes, max) when is_binary(bytes) do
    cond do
      byte_size(bytes) > max ->
        {:error, :too_big}

      binary?(bytes) ->
        {:error, :binary}

      true ->
        text = if String.valid?(bytes), do: bytes, else: latin1(bytes)

        # A file without a single tag pair is prose, whatever the reader
        # makes of it.
        games = PgnReader.parse(text)

        case if(Enum.all?(games, &(&1.headers == %{})), do: [], else: games) do
          [] -> {:error, :no_games}
          games when length(games) > @max_games -> {:error, {:too_many, length(games)}}
          games -> {:ok, games}
        end
    end
  end

  # A zip ("PK"), a gzip, or anything with a NUL in it is not a PGN.
  defp binary?(<<"PK", 3, 4, _::binary>>), do: true
  defp binary?(<<0x1F, 0x8B, _::binary>>), do: true
  defp binary?(<<0x28, 0xB5, 0x2F, 0xFD, _::binary>>), do: true
  defp binary?(bytes), do: :binary.match(bytes, <<0>>) != :nomatch

  defp latin1(bytes), do: :unicode.characters_to_binary(bytes, :latin1, :utf8)

  @doc """
  One game, checked: `{:ok, attrs, problems}` (`attrs` for an
  `Alnasl.FairPlay.UploadGame`, `problems` the warnings, such as a missing
  rating) or `{:error, problem}`. A problem is a map with string keys:
  `"game"` (its number in the file), `"white"`, `"black"`, `"kind"` and
  `"detail"`.
  """
  def check(%{headers: h} = game, number, players \\ nil) do
    base = %{"game" => number, "white" => h["White"], "black" => h["Black"]}
    variant = h["Variant"]

    cond do
      variant not in [nil, ""] and String.downcase(variant) not in ["standard", "chess"] ->
        {:error, Map.merge(base, %{"kind" => "variant", "detail" => variant})}

      true ->
        start_fen = start_fen(h)

        input = %{
          start_fen: start_fen,
          plies: Enum.map(game.moves, &%{san: &1, flags: [], clock_ms: nil}),
          white_rating: elo(h["WhiteElo"]),
          black_rating: elo(h["BlackElo"]),
          result_confirmed: true
        }

        case Analyzer.prepare(input) do
          {:ok, _records} ->
            {round, board} = round_and_board(h)

            attrs = %{
              number: number,
              event: text(h["Event"]),
              date: text(h["Date"]),
              round: round,
              board: board,
              white: text(h["White"]),
              black: text(h["Black"]),
              white_elo: input.white_rating,
              black_elo: input.black_rating,
              white_fide_id: elo(h["WhiteFideId"]),
              black_fide_id: elo(h["BlackFideId"]),
              result: game.result,
              start_fen: start_fen,
              moves: Enum.join(game.moves, " "),
              clocks: Jason.encode!(game.clocks),
              status: "waiting"
            }

            {:ok, attrs, unrated(base, input) |> List.wrap() |> Enum.reject(&is_nil/1)}
            |> keyed(players)

          {:error, {ply, message}} ->
            {:error,
             Map.merge(base, %{
               "kind" => "illegal",
               "detail" =>
                 "#{div(ply + 1, 2)}#{if rem(ply, 2) == 1, do: ".", else: "..."} " <>
                   "#{Enum.at(game.moves, ply - 1)} (#{message})"
             })}

          {:error, message} ->
            {:error, Map.merge(base, %{"kind" => "position", "detail" => to_string(message)})}
        end
    end
  end

  defp keyed({:ok, attrs, problems}, players) do
    {:ok,
     Map.merge(attrs, %{
       white_key: player_key(players, attrs.white, attrs.white_fide_id),
       black_key: player_key(players, attrs.black, attrs.black_fide_id)
     }), problems}
  end

  defp unrated(base, %{white_rating: w, black_rating: b}) do
    case {w, b} do
      {nil, nil} -> Map.merge(base, %{"kind" => "unrated", "detail" => "both"})
      {nil, _} -> Map.merge(base, %{"kind" => "unrated", "detail" => "white"})
      {_, nil} -> Map.merge(base, %{"kind" => "unrated", "detail" => "black"})
      _rated -> nil
    end
  end

  defp start_fen(h) do
    case h["FEN"] do
      fen when is_binary(fen) and fen != "" -> fen
      _none -> nil
    end
  end

  defp elo(text) when is_binary(text) do
    case Integer.parse(String.trim(text)) do
      {n, ""} when n > 0 -> n
      _none -> nil
    end
  end

  defp elo(_none), do: nil

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      v when v in ["", "?", "-"] -> nil
      v -> String.slice(v, 0, 200)
    end
  end

  defp text(_none), do: nil

  # "5" is round 5; "5.12" is round 5, board 12 (Lichess broadcasts); a
  # `Board` tag wins. Anything else is no round at all.
  defp round_and_board(h) do
    {round, from_round} =
      case Regex.run(~r/^\s*(\d+)(?:\.(\d+))?/, h["Round"] || "") do
        [_, r] -> {String.to_integer(r), nil}
        [_, r, b] -> {String.to_integer(r), String.to_integer(b)}
        nil -> {nil, nil}
      end

    {round, elo(h["Board"]) || from_round}
  end

  # --- players ---------------------------------------------------------------------

  @doc """
  The players of a tournament's pairing document, to match uploaded names
  against: `%{fide: %{fide_id => id}, names: %{name_key => id}}`, or `nil`
  for an upload on its own.
  """
  def players(nil), do: nil

  def players(tournament_id) do
    case Tournaments.document(tournament_id) do
      %{"players" => players} when is_list(players) ->
        Enum.reduce(players, %{fide: %{}, names: %{}}, fn p, acc ->
          acc
          |> then(fn acc ->
            case p["fide_id"] do
              f when is_integer(f) and f > 0 -> put_in(acc, [:fide, f], p["id"])
              _none -> acc
            end
          end)
          |> then(fn acc ->
            case p["name"] do
              name when is_binary(name) -> put_in(acc, [:names, name_key(name)], p["id"])
              _none -> acc
            end
          end)
        end)

      _none ->
        %{fide: %{}, names: %{}}
    end
  end

  @doc """
  The key a player of an uploaded game is known by: the pairing program's
  id when the tournament's players say who it is (FIDE ID first, then the
  name), else `"name:" <> name`, as for a board game without an id.
  """
  def player_key(players, name, fide_id) do
    id =
      players &&
        ((is_integer(fide_id) && players.fide[fide_id]) ||
           (is_binary(name) && players.names[name_key(name)]))

    cond do
      is_integer(id) -> "id:#{id}"
      is_binary(name) and String.trim(name) != "" -> "name:" <> String.trim(name)
      true -> "unknown"
    end
  end

  @doc "A name as compared: lower case, no punctuation, the words in order (\"Carlsen, Magnus\" is \"Magnus Carlsen\")."
  def name_key(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.split()
    |> Enum.sort()
    |> Enum.join(" ")
  end

  # --- the owner's side -------------------------------------------------------------

  @doc """
  Reads, checks and stores an uploaded file for hall `hall_id`, then
  queues its games. `attrs`: `:bytes` (the file), `:filename`, `:name` (or
  the first game's event, or the file's name), `:tournament_id` (a
  tournament of the hall, or `nil`). Owner only, and only in a hall where
  fair play is on with an engine installed.

  `{:ok, upload}`, or `{:error, reason}`: `:forbidden`, `:not_working`,
  `:tournament`, `{:already, upload}`, or one of `read/2`'s. A file of
  which no game could be used is still stored, with its problems, so the
  owner sees why.
  """
  def create(scope, hall_id, attrs) do
    bytes = Map.fetch!(attrs, :bytes)
    tournament_id = attrs[:tournament_id]
    sha256 = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    with :ok <- owner(scope, hall_id),
         :ok <- working(hall_id),
         :ok <- tournament_of(scope, hall_id, tournament_id),
         :ok <- not_already(hall_id, sha256),
         {:ok, games} <- read(bytes) do
      store(scope, hall_id, games, %{
        tournament_id: tournament_id,
        filename: attrs[:filename] |> text() |> then(&(&1 && file_name(&1))),
        name: text(attrs[:name]),
        byte_size: byte_size(bytes),
        sha256: sha256
      })
    end
  end

  defp owner(scope, hall_id),
    do: if(Access.owner?(scope, hall_id), do: :ok, else: {:error, :forbidden})

  defp working(hall_id),
    do: if(FairPlay.working?(FairPlay.settings(hall_id)), do: :ok, else: {:error, :not_working})

  defp tournament_of(_scope, _hall_id, nil), do: :ok

  defp tournament_of(scope, hall_id, id) do
    {:ok, tournaments} = FairPlay.tournaments(scope, hall_id)
    if Enum.any?(tournaments, &(&1.id == id)), do: :ok, else: {:error, :tournament}
  end

  defp not_already(hall_id, sha256) do
    case Repo.one(
           from u in Upload,
             where: u.hall_id == ^hall_id and u.sha256 == ^sha256,
             limit: 1
         ) do
      nil -> :ok
      upload -> {:error, {:already, upload}}
    end
  end

  defp store(scope, hall_id, games, file) do
    players = players(file.tournament_id)
    boards = board_games(file.tournament_id)

    {accepted, problems, _seen} =
      games
      |> Enum.with_index(1)
      |> Enum.reduce({[], [], %{}}, fn {game, number}, {accepted, problems, seen} ->
        case check(game, number, players) do
          {:ok, attrs, warnings} ->
            twin = {attrs.round, attrs.white_key, attrs.black_key, attrs.moves}

            cond do
              first = seen[twin] ->
                problem = %{
                  "game" => number,
                  "white" => attrs.white,
                  "black" => attrs.black,
                  "kind" => "repeated",
                  "detail" => "#{first}"
                }

                {accepted, [problem | problems], seen}

              MapSet.member?(boards, {attrs.round, attrs.white_key, attrs.black_key}) ->
                problem = %{
                  "game" => number,
                  "white" => attrs.white,
                  "black" => attrs.black,
                  "kind" => "on_the_boards",
                  "detail" => nil
                }

                {[%{attrs | status: "duplicate"} | accepted], [problem | problems],
                 Map.put(seen, twin, number)}

              true ->
                {[attrs | accepted], Enum.reverse(warnings) ++ problems,
                 Map.put(seen, twin, number)}
            end

          {:error, problem} ->
            {accepted, [problem | problems], seen}
        end
      end)

    accepted = Enum.reverse(accepted)
    problems = Enum.reverse(problems)
    refused = Enum.count(problems, &(&1["kind"] in ~w(variant illegal position repeated)))
    now = DateTime.utc_now(:second)

    name =
      file.name ||
        Enum.find_value(accepted, & &1.event) ||
        file.filename ||
        "PGN"

    {:ok, upload} =
      Repo.transaction(fn ->
        upload =
          Repo.insert!(%Upload{
            hall_id: hall_id,
            tournament_id: file.tournament_id,
            name: name,
            filename: file.filename,
            byte_size: file.byte_size,
            sha256: file.sha256,
            uploaded_by: email(scope),
            uploaded_by_id: user_id(scope),
            accepted: length(accepted),
            rejected: refused,
            problems: Jason.encode!(problems)
          })

        rows =
          for attrs <- accepted do
            attrs
            |> Map.drop([:white_key, :black_key])
            |> Map.merge(%{upload_id: upload.id, inserted_at: now, updated_at: now})
          end

        for chunk <- Enum.chunk_every(rows, 200), do: Repo.insert_all(UploadGame, chunk)
        upload
      end)

    FairPlay.audit(scope, %{hall_id: hall_id, upload_id: upload.id}, "upload",
      detail: file.filename || name
    )

    enqueue_waiting(upload)
    {:ok, upload}
  end

  # The board games of a tournament, as {round, white key, black key}.
  defp board_games(nil), do: MapSet.new()

  defp board_games(tournament_id) do
    from(g in Game, where: g.tournament_id == ^tournament_id)
    |> Repo.all()
    |> Enum.filter(&Alnasl.Games.begun?/1)
    |> MapSet.new(fn g ->
      {g.round, FairPlay.Analysis.player_key(g, :white), FairPlay.Analysis.player_key(g, :black)}
    end)
  end

  @doc "The uploads of a hall, newest first. Its owner, or a holder of a grant of the whole hall."
  def list(scope, hall_id) do
    if Access.owner?(scope, hall_id) or Alnasl.FairPlay.Grants.hall_active?(scope, hall_id) do
      {:ok, Repo.all(from u in Upload, where: u.hall_id == ^hall_id, order_by: [desc: u.id])}
    else
      {:error, :forbidden}
    end
  end

  @doc """
  An upload, when the scope may see it (its hall's owner, or somebody it
  was shared with). A missing one is forbidden too.
  """
  def get(scope, id) do
    with %Upload{} = upload <- Repo.get(Upload, id),
         true <- FairPlay.can_view?(scope, upload) do
      {:ok, upload}
    else
      _no -> {:error, :forbidden}
    end
  end

  @doc "How many of an upload's games wait, are done, failed or were on the boards. Viewers too."
  def progress(scope, %Upload{} = upload) do
    if FairPlay.can_view?(scope, upload) do
      counts =
        from(g in UploadGame,
          where: g.upload_id == ^upload.id,
          group_by: g.status,
          select: {g.status, count(g.id)}
        )
        |> Repo.all()
        |> Map.new()

      {:ok,
       %{
         waiting: Map.get(counts, "waiting", 0),
         done: Map.get(counts, "done", 0),
         failed: Map.get(counts, "failed", 0),
         duplicate: Map.get(counts, "duplicate", 0)
       }}
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Queues an upload's waiting games again: after a restart, or when the
  queue was full. Owner only. `{:ok, n}`, or `{:error, :not_working}`.
  """
  def requeue(scope, %Upload{} = upload) do
    cond do
      not Access.owner?(scope, upload.hall_id) -> {:error, :forbidden}
      working(upload.hall_id) != :ok -> {:error, :not_working}
      true -> {:ok, enqueue_waiting(upload)}
    end
  end

  @doc """
  Deletes an upload: its games, their analysis, the grants of its report
  and its audit lines; one line in the hall's audit says it was deleted.
  Owner only.
  """
  def delete(scope, %Upload{} = upload) do
    if Access.owner?(scope, upload.hall_id) do
      purge(upload.id)

      FairPlay.audit(scope, %{hall_id: upload.hall_id}, "delete_upload",
        detail: upload.filename || upload.name
      )

      :ok
    else
      {:error, :forbidden}
    end
  end

  @doc false
  # Everything of an upload, gone. For `delete/2` and the retention.
  def purge(upload_id) do
    {moves, _} = Repo.delete_all(from m in UploadMove, where: m.upload_id == ^upload_id)
    Repo.delete_all(from g in UploadGame, where: g.upload_id == ^upload_id)
    {views, _} = Repo.delete_all(from v in View, where: v.upload_id == ^upload_id)
    Repo.delete_all(from g in Grant, where: g.upload_id == ^upload_id)
    Repo.delete_all(from u in Upload, where: u.id == ^upload_id)
    %{moves: moves, views: views}
  end

  # --- the queue's side ----------------------------------------------------------------

  defp enqueue_waiting(%Upload{id: id}) do
    ids =
      Repo.all(
        from g in UploadGame,
          where: g.upload_id == ^id and g.status == "waiting",
          order_by: g.number,
          select: g.id
      )

    Enum.each(ids, &Queue.enqueue({:upload_game, &1}))
    length(ids)
  end

  @doc """
  Queues every waiting game of every upload in a hall where fair play
  works: what a restart left unfinished. Started with the live queue.
  """
  def resume do
    halls =
      from(u in Upload,
        join: g in UploadGame,
        on: g.upload_id == u.id,
        where: g.status == "waiting",
        distinct: true,
        select: u
      )
      |> Repo.all()

    for upload <- halls, working(upload.hall_id) == :ok, do: enqueue_waiting(upload)
    :ok
  end

  @doc false
  # The queue's job for one uploaded game: unless fair play is off in its
  # hall or the game is no longer waiting, analyse it with an engine from
  # the pool.
  def job(game_id) do
    with %UploadGame{status: "waiting"} = game <- Repo.get(UploadGame, game_id),
         %Upload{} = upload <- Repo.get(Upload, game.upload_id),
         setting = FairPlay.settings(upload.hall_id),
         true <- FairPlay.working?(setting),
         {:ok, engine} <- Pool.checkout(setting.engine_path) do
      try do
        analyse(game, upload, Uci.engine_fun(engine, setting.nodes), setting)
      after
        Pool.checkin(engine)
      end
    else
      _off -> :ok
    end
  end

  @doc """
  Analyses one uploaded game with `engine` (a function, as
  `Alnasl.FairPlay.Analyzer` takes it) and stores its rows, replacing any
  it had. Marks the game done, or failed with the reason; tells the
  upload's page.
  """
  def analyse(%UploadGame{} = game, %Upload{} = upload, engine, setting) do
    input = %{
      start_fen: game.start_fen,
      plies:
        game
        |> UploadGame.sans()
        |> Enum.zip(UploadGame.clocks(game))
        |> Enum.map(fn {san, ms} -> %{san: san, flags: [], clock_ms: ms} end),
      white_rating: game.white_elo,
      black_rating: game.black_elo,
      result_confirmed: true
    }

    result =
      case Analyzer.analyse(input, engine) do
        {:ok, records} ->
          players = players(upload.tournament_id)
          now = DateTime.utc_now(:second)
          rows = Enum.map(records, &row(&1, game, upload, players, setting, now))

          Repo.transaction(fn ->
            Repo.delete_all(from m in UploadMove, where: m.game_id == ^game.id)
            for chunk <- Enum.chunk_every(rows, 100), do: Repo.insert_all(UploadMove, chunk)
            set_status(game, "done", nil)
          end)

          :ok

        {:error, reason} ->
          Logger.warning("fair play: uploaded game #{game.id} cannot be replayed")
          set_status(game, "failed", reason |> inspect() |> String.slice(0, 200))
          {:error, reason}
      end

    Phoenix.PubSub.broadcast(Alnasl.PubSub, topic(upload.id), {:fair_play_upload, upload.id})
    result
  end

  defp set_status(game, status, error) do
    game |> Ecto.Changeset.change(status: status, error: error) |> Repo.update!()
  end

  defp row(record, game, upload, players, setting, now) do
    {name, fide} =
      if record.colour == :white,
        do: {game.white, game.white_fide_id},
        else: {game.black, game.black_fide_id}

    %{
      upload_id: upload.id,
      tournament_id: upload.tournament_id,
      game_id: game.id,
      round: game.round || 0,
      board_no: game.board || 0,
      ply: record.ply,
      colour: Atom.to_string(record.colour),
      move_number: record.move_number,
      player_key: player_key(players, name, fide),
      player_name: name,
      san: record.san,
      played_uci: record.played_uci,
      fen: record.fen,
      best: FairPlay.Move.encode_best(record.best),
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

  defp email(%Scope{user: %{email: email}}), do: email
  defp email(_scope), do: nil
  defp user_id(%Scope{user: %{id: id}}), do: id
  defp user_id(_scope), do: nil

  # The name without the folder it came from. Some browsers on Windows send
  # the whole "C:\games\club.pgn"; `Path.basename/1` only knows the separator
  # of the machine it runs on, which on the server is not a backslash.
  defp file_name(name), do: name |> String.split(["/", "\\"]) |> List.last()
end
