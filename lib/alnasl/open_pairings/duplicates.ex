defmodule Alnasl.OpenPairings.Duplicates do
  @moduledoc """
  One tournament of a pairing program is one row on the box, however many
  connect codes reach it.

  An arbiter adds the code of a group and then, to be sure, the code of the
  tournament in it; or a desktop copy of OpenPairings hands out one code
  for this computer and one for the hall's network. Two rows for one
  tournament each report every game, so the pairing program heard each
  game twice, and the Round page showed the boards twice.

  ## Who is who

  The contract gives no identity for a tournament but the pairing program's
  address and the tournament's id there. So two listings name the same
  tournament when (`holder/2`)

  1. the address is the same (scheme, host and port, `localhost` being
     `127.0.0.1`) and so is the id; or
  2. the id is the same, the other row is still listed, and its version is
     the one this listing gives - a version is a hash of the whole
     document, and two programs do not hash two tournaments alike; or,
     once the document is in, it shares a game id with the other row's
     (`same_games?/2`): game ids are random and live as long as a pairing.

  The second rule is for a desktop copy reached at `127.0.0.1` and at its
  address on the hall's network. A machine reached by two names whose
  versions never once agree at the moment of a listing is caught by the
  game ids as soon as a round is paired.

  ## What happens

  The second code is kept - the arbiter may want it in place of the first -
  but makes no row: the tournament is written down on its link as reached
  elsewhere (`Alnasl.Tournaments.Link`, `elsewhere`), and Setup says so in
  words. The arbiter may then use the new code for that tournament instead
  of the old one (`use_code/2`): a code withdrawn and made again is the
  usual reason. The row stays the same row; only the code it is asked
  through changes. The old code goes when it reaches nothing else.

  A row the old code no longer lists (`gone`) is the same tournament found
  again: it moves to the new code by itself.

  ## Boxes that already have two rows

  `merge_all/0`, at start-up: the later row of each pair is merged into the
  first. Its boards, its games and what waits in the outbox move over; a
  game whose place the first row has already filled with a game that began
  stays on the box as the next game of that board, never in place of
  another. Each merge is written in the log.
  """

  import Ecto.Query

  alias Alnasl.{Boards, Games, Log, Repo, Tournaments}
  alias Alnasl.Games.Game
  alias Alnasl.OpenPairings.Code
  alias Alnasl.Tournaments.{Link, Tournament}

  # --- who is who --------------------------------------------------------------

  @doc "The same pairing program? Scheme, host and port compared, the path too."
  def same_server?(a, b), do: server(a) == server(b)

  defp server(root) do
    case URI.parse(root || "") do
      %URI{scheme: scheme, host: host, port: port, path: path} when is_binary(host) ->
        scheme = String.downcase(scheme || "")
        host = String.downcase(host)
        host = if host in ["localhost", "[::1]", "::1"], do: "127.0.0.1", else: host
        {scheme, host, port || URI.default_port(scheme), String.trim_trailing(path || "", "/")}

      _other ->
        root
    end
  end

  @doc """
  The row the box already has, through another code, of the tournament that
  `entry` of `link`'s listing names; `nil` when it has none.
  """
  def holder(%Link{} = link, %{"id" => id} = entry) do
    noted =
      case elsewhere(link)[to_string(id)] do
        %{"tournament_id" => tid} -> Tournaments.get(tid)
        _none -> nil
      end

    if noted && noted.kind == "linked" && noted.link_id != link.id && noted.remote_id == id do
      noted
    else
      Enum.find(others(link), fn t ->
        t.remote_id == id and
          (same_server?(root(t), link.root) or
             (not t.gone and is_binary(entry["version"]) and
                entry["version"] in [t.listed_version, t.version]))
      end)
    end
  end

  def holder(_link, _entry), do: nil

  defp others(%Link{id: id}) do
    Tournament
    |> where([t], t.kind == "linked" and t.link_id != ^id)
    |> order_by([t], t.id)
    |> Repo.all()
  end

  defp root(%Tournament{} = t) do
    case Tournaments.link_of(t) do
      %Link{root: root} -> root
      nil -> nil
    end
  end

  @doc """
  Do two documents share a game? Only games the pairing program gave an
  id; a document without rounds shares nothing.
  """
  def same_games?(a, b) do
    ids = game_ids(a)
    ids != MapSet.new() and not MapSet.disjoint?(ids, game_ids(b))
  end

  defp game_ids(%{"rounds" => rounds}) when is_list(rounds) do
    for %{"boards" => boards} <- rounds,
        is_list(boards),
        %{"game" => game} <- boards,
        is_binary(game) and game != "",
        into: MapSet.new(),
        do: game
  end

  defp game_ids(_none), do: MapSet.new()

  @doc """
  A document arrived for `tournament`. Another row with the same id there
  and a game in common is the same tournament, and the later row of the
  two is merged into the first. `{:apply, row}` - the document is for
  `row` - or `:merged` when the row it came for is no more.
  """
  def check_document(%Tournament{kind: "linked"} = tournament, document) do
    twin =
      Enum.find(others_than(tournament), fn t ->
        t.remote_id == tournament.remote_id and not t.gone and
          same_games?(document, Tournaments.document(t))
      end)

    cond do
      twin == nil ->
        {:apply, tournament}

      twin.id < tournament.id ->
        merge(tournament, twin)
        :merged

      true ->
        merge(twin, tournament)
        {:apply, Tournaments.get!(tournament.id)}
    end
  end

  def check_document(tournament, _document), do: {:apply, tournament}

  defp others_than(%Tournament{id: id, link_id: link_id}) do
    Tournament
    |> where([t], t.kind == "linked" and t.id != ^id and t.link_id != ^link_id)
    |> order_by([t], t.id)
    |> Repo.all()
  end

  # --- what a link reaches elsewhere -------------------------------------------

  @doc "`%{\"<id there>\" => %{\"tournament_id\", \"name\"}}`."
  def elsewhere(%Link{elsewhere: nil}), do: %{}

  def elsewhere(%Link{elsewhere: json}) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> map
      _broken -> %{}
    end
  end

  @doc """
  What a link reaches that the box has through another code, for the page:
  `[%{remote_id, name, tournament, through}]`, `through` being the link the
  box asks for it. Entries whose row went away are left out.
  """
  def shared(%Link{} = link) do
    for {id, %{"tournament_id" => tid} = entry} <- elsewhere(link),
        %Tournament{} = t <- [Tournaments.get(tid)],
        t.link_id != link.id,
        %Link{} = through <- [Tournaments.link_of(t)] do
      %{
        remote_id: String.to_integer(id),
        name: entry["name"] || Tournaments.title(t),
        tournament: t,
        through: through
      }
    end
    |> Enum.sort_by(& &1.remote_id)
  end

  @doc "Writes down what a link reaches elsewhere: `%{id there => {tournament, name}}`."
  def note(%Link{} = link, found) do
    map =
      Map.new(found, fn {id, {%Tournament{id: tid}, name}} ->
        {to_string(id), %{"tournament_id" => tid, "name" => name}}
      end)

    json = if map == %{}, do: nil, else: Jason.encode!(map)

    if json != link.elsewhere do
      for {id, {t, name}} <- found, not Map.has_key?(elsewhere(link), to_string(id)) do
        Log.add(:warn, "tournament.elsewhere", %{
          tournament: name || Tournaments.title(t) || "",
          server: Code.host(link.root)
        })
      end

      link |> Ecto.Changeset.change(%{elsewhere: json}) |> Repo.update!()
    else
      link
    end
  end

  defp add_note(%Link{} = link, id, %Tournament{} = t, name) do
    map = Map.put(elsewhere(link), to_string(id), %{"tournament_id" => t.id, "name" => name})
    link |> Ecto.Changeset.change(%{elsewhere: Jason.encode!(map)}) |> Repo.update!()
  end

  defp drop_note(%Link{} = link, id) do
    map = Map.delete(elsewhere(link), to_string(id))
    json = if map == %{}, do: nil, else: Jason.encode!(map)
    link |> Ecto.Changeset.change(%{elsewhere: json}) |> Repo.update!()
  end

  # --- one code in place of another --------------------------------------------

  @doc """
  The tournament with id `remote_id` there is asked through `link` from now
  on, not through the code the box had for it. The row, its boards and its
  games stay as they are. The old code is taken off the box when it reaches
  nothing else. `{:ok, tournament}` or `{:error, :not_found}`.
  """
  def use_code(%Link{} = link, remote_id) when is_integer(remote_id) do
    link = Repo.get!(Link, link.id)

    with %{"tournament_id" => tid} = entry <- elsewhere(link)[to_string(remote_id)],
         %Tournament{kind: "linked"} = t <- Tournaments.get(tid) do
      old = Tournaments.link_of(t)
      moved = take(t, link)
      drop_note(link, remote_id)

      if old do
        if Tournaments.of_link(old) == [] do
          Repo.delete(old)
          Log.add(:info, "link.removed", %{server: Code.host(old.root)})
        else
          add_note(old, remote_id, moved, entry["name"])
        end
      end

      Log.add(:info, "tournament.code_replaced", %{
        tournament: Tournaments.title(moved) || entry["name"] || "",
        server: Code.host(link.root)
      })

      Tournaments.notify(moved.id)
      Alnasl.Destination.settings_changed()
      {:ok, moved}
    else
      _none -> {:error, :not_found}
    end
  end

  def use_code(%Link{} = link, remote_id) when is_binary(remote_id),
    do: use_code(link, String.to_integer(remote_id))

  @doc """
  A row the code it was asked through no longer lists, found again through
  `link`: it is asked through `link` from now on.
  """
  def adopt(%Tournament{} = t, %Link{} = link) do
    old = Tournaments.link_of(t)
    moved = take(t, link)
    if old, do: add_note(old, t.remote_id, moved, t.name)

    Log.add(:info, "tournament.code_replaced", %{
      tournament: Tournaments.title(moved) || "",
      server: Code.host(link.root)
    })

    moved
  end

  @doc """
  The code row `t` was asked through no longer reaches it. Another code
  the box has does - it wrote the tournament down as reached elsewhere -
  and the row is asked through that one from now on: `{:moved, row}`.
  `nil` when no other code reaches it.
  """
  def reclaim(%Tournament{} = t) do
    found =
      Enum.find(Tournaments.links(), fn link ->
        link.id != t.link_id and link.state not in ["unauthorized", "unsupported"] and
          match?(
            %{"tournament_id" => id} when id == t.id,
            elsewhere(link)[to_string(t.remote_id)]
          )
      end)

    if found do
      moved = adopt(t, found)
      drop_note(Repo.get!(Link, found.id), t.remote_id)
      Tournaments.notify(moved.id)
      Alnasl.OpenPairings.Poller.poll_now()
      {:moved, moved}
    end
  end

  # The row is asked through `link`; its document is owed again, at once.
  defp take(%Tournament{} = t, %Link{} = link) do
    t
    |> Ecto.Changeset.change(%{link_id: link.id, version: nil, gone: false})
    |> Repo.update!()
  end

  # --- two rows into one -------------------------------------------------------

  @doc """
  Every pair of rows of one tournament on the box is made one: the later
  into the first. Returns `[{first, later}]` for the rows merged. Run at
  start-up; there is nothing to do on a box it has run on.
  """
  def merge_all do
    linked =
      Tournament |> where([t], t.kind == "linked") |> order_by([t], t.id) |> Repo.all()

    {merged, _kept} =
      Enum.reduce(linked, {[], []}, fn t, {merged, kept} ->
        case Enum.find(kept, &twins?(&1, t)) do
          nil ->
            {merged, kept ++ [t]}

          first ->
            merge(t, first)
            {[{first.id, t.id} | merged], kept}
        end
      end)

    Enum.reverse(merged)
  end

  defp twins?(%Tournament{} = a, %Tournament{} = b) do
    a.link_id != b.link_id and a.remote_id == b.remote_id and
      (same_server?(root(a), root(b)) or
         (a.version != nil and a.version == b.version) or
         same_games?(Tournaments.document(a), Tournaments.document(b)))
  end

  @doc """
  Row `later` goes into row `first`: its boards, its games (and with them
  what waits for each destination) and its outbox. A table range, a Lichess
  round, a results page the first row lacks are taken over. The code
  `later` was reached through writes the tournament down as reached
  elsewhere, so it does not make the row again.
  """
  def merge(%Tournament{} = later, %Tournament{} = first) do
    {boards, games} =
      Repo.transaction(fn ->
        games = for game <- games_of(later.id), do: move_game(game, first.id)

        Repo.update_all(from(e in Alnasl.Outbox.Entry, where: e.tournament_id == ^later.id),
          set: [tournament_id: first.id]
        )

        boards = for b <- Boards.list(), b.tournament_id == later.id, do: b

        for b <- boards,
            do: b |> Ecto.Changeset.change(%{tournament_id: first.id}) |> Repo.update!()

        first = Repo.get!(Tournament, first.id)
        first |> Ecto.Changeset.change(taken_over(first, later)) |> Repo.update!()

        with %Link{} = link <- Repo.get(Link, later.link_id),
             do: add_note(link, later.remote_id, first, later.name)

        Repo.delete!(later)
        {boards, Enum.count(games, &(&1 != :dropped))}
      end)
      |> elem(1)

    # A board that is running holds its tournament in its process: it is
    # told, once the rows are what they will be.
    for b <- boards, Boards.running?(b.id), do: Boards.update(Boards.get!(b.id), %{})
    boards = length(boards)

    Log.add(:warn, "tournament.merged", %{
      tournament: Tournaments.title(first) || later.name || "",
      boards: boards,
      games: games
    })

    Tournaments.notify(first.id)
    Boards.refresh_games(first.id)
    :ok
  end

  defp games_of(tournament_id) do
    Game
    |> where([g], g.tournament_id == ^tournament_id)
    |> order_by([g], [g.round, g.board_no, g.game_no])
    |> Repo.all()
  end

  # A game of the later row, to its place in the first: free, or held by
  # games that never began (they make way), or held by a game that began
  # (this one stays on the box as the next game there). An empty game
  # whose place is taken is not worth keeping.
  defp move_game(%Game{} = game, to) do
    there = Games.history(to, game.round, game.board_no)
    empty? = fn g -> not Games.begun?(g) and g.status == "live" end

    cond do
      there == [] ->
        Games.rehome(game, %{tournament_id: to})

      empty?.(game) ->
        File.rm(Games.pgn_path(game))
        Repo.delete!(game)
        :dropped

      Enum.all?(there, empty?) ->
        for g <- there do
          File.rm(Games.pgn_path(g))
          Repo.delete!(g)
        end

        Games.rehome(game, %{tournament_id: to})

      true ->
        next = Enum.max_by(there, & &1.game_no).game_no + 1

        Games.rehome(game, %{
          tournament_id: to,
          game_no: next,
          local: true,
          pairing_flag: nil
        })
    end
  end

  defp taken_over(first, later) do
    [
      if(first.table_from == nil and later.table_from != nil,
        do: %{table_from: later.table_from, table_to: later.table_to}
      ),
      if(first.lichess_round_id in [nil, ""] and later.lichess_round_id not in [nil, ""],
        do: %{
          lichess_round_id: later.lichess_round_id,
          lichess_token: later.lichess_token,
          lichess_round: later.lichess_round
        }
      ),
      if(first.document == nil and later.document != nil,
        do: %{
          document: later.document,
          document_at: later.document_at,
          version: later.version,
          listed_version: later.listed_version,
          server_url: later.server_url,
          slug: later.slug,
          relay_key: later.relay_key,
          remote_round: later.remote_round,
          round: later.round
        }
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(%{}, &Map.merge(&2, &1))
  end
end
