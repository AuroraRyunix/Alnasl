defmodule Alnasl.Tournaments do
  @moduledoc """
  The tournaments the box serves, and what it knows of each: who plays whom
  on which board, which round is on, where its games go.

  ## More than one

  A hall has one box and often several tournaments: tables 1-4 the Open,
  5-8 the under-twelves. Each is a row (`Alnasl.Tournaments.Tournament`)
  with its own pairings, its own round in play, its own results page and
  Lichess round. Which table plays in which tournament is said here, on the
  box (`assign_tables/3`, `Alnasl.Tables`); board numbers begin again at 1
  in each, so table 5 can be board 1.

  ## The box's own

  One tournament is always there: the box's own (`default/0`, kind
  `"local"`). It is what a box with no pairing program has - names typed
  in or read from a PGN, a results page typed in on Setup - and where a
  board belongs that nobody has given to another tournament.

  ## Where the pairings come from

  For a linked tournament, from its pairing program
  (`Alnasl.OpenPairings`), which is asked every few seconds; the answer is
  kept (`document`), so the box knows the pairings with the network gone.
  For the box's own, from nowhere but the arbiter: `set_names/5`, or a PGN
  attached to a board. The box does not read pairings from the results
  server any more: that link is one way, moves out.
  """

  import Ecto.Query, only: [from: 2, order_by: 3, select: 3, distinct: 2, where: 3]

  alias Alnasl.Repo
  alias Alnasl.Tournaments.{Link, Tournament}

  @topic "tournaments"

  def subscribe, do: Phoenix.PubSub.subscribe(Alnasl.PubSub, @topic)

  @doc "Tells every page that tournament `id` changed (`{:tournament, id}`)."
  def notify(id), do: Phoenix.PubSub.broadcast(Alnasl.PubSub, @topic, {:tournament, id})

  # --- rows --------------------------------------------------------------------

  @doc "The box's own tournament. Made if it is not there."
  def default do
    case Repo.one(from t in Tournament, where: t.kind == "local", order_by: t.id, limit: 1) do
      nil -> Repo.insert!(%Tournament{kind: "local"})
      tournament -> tournament
    end
  end

  def default_id, do: default().id

  @doc "Every tournament: the box's own first, then in the order they were added."
  def list do
    Tournament
    |> order_by([t], asc: fragment("CASE WHEN ? = 'local' THEN 0 ELSE 1 END", t.kind), asc: t.id)
    |> Repo.all()
  end

  def get(nil), do: nil
  def get(id), do: Repo.get(Tournament, id)
  def get!(id), do: Repo.get!(Tournament, id)

  @doc """
  The tournaments to show: every linked one the pairing program still
  names, and the box's own when it has a board - or when it is all there is.
  """
  def active do
    with_boards =
      Alnasl.Boards.Board |> select([b], b.tournament_id) |> distinct(true) |> Repo.all()

    all = list()
    linked = Enum.filter(all, &(&1.kind == "linked" and not &1.gone))

    own =
      Enum.filter(
        all,
        &((&1.kind == "local" and (linked == [] or &1.id in with_boards)) or
            (&1.gone and &1.id in with_boards))
      )

    Enum.sort_by(own ++ linked, &{&1.kind != "local", &1.id})
  end

  @doc "Is there more than one tournament to tell apart?"
  def many?, do: length(active()) > 1

  @doc "What to call it on a tile: its short label, else its name."
  def title(%Tournament{label: label}) when is_binary(label) and label != "", do: label
  def title(%Tournament{name: name}) when is_binary(name) and name != "", do: name
  def title(%Tournament{}), do: nil

  def linked?(%Tournament{kind: kind}), do: kind == "linked"

  def update(%Tournament{} = tournament, attrs) do
    with {:ok, updated} <- tournament |> Tournament.changeset(Map.new(attrs)) |> Repo.update() do
      notify(updated.id)
      Alnasl.Destination.settings_changed()
      {:ok, updated}
    end
  end

  def update!(%Tournament{} = tournament, attrs) do
    {:ok, updated} = update(tournament, attrs)
    updated
  end

  @doc """
  Takes a tournament off the box: its boards go back to the box's own
  tournament, not linked to a game, and its games are forgotten here (the
  PGN files already written stay on the disk). The box's own cannot go.
  """
  def remove(%Tournament{kind: "local"}), do: {:error, :own}

  def remove(%Tournament{} = tournament) do
    own = default()

    for board <- Alnasl.Boards.list(), board.tournament_id == tournament.id do
      Alnasl.Boards.update(board, %{tournament_id: own.id, round: nil, board_no: nil})
    end

    Repo.delete_all(from g in Alnasl.Games.Game, where: g.tournament_id == ^tournament.id)
    Repo.delete!(tournament)
    notify(tournament.id)
    :ok
  end

  # --- the round ---------------------------------------------------------------

  @doc "The round the box has on that tournament's boards."
  def round_in_play(id) do
    case get(id) do
      %Tournament{round: round} when is_integer(round) -> round
      _none -> 1
    end
  end

  def set_round(id, round) when is_integer(round) and round > 0 do
    case get(id) do
      %Tournament{round: ^round} = same -> same
      %Tournament{} = tournament -> update!(tournament, %{round: round})
      nil -> nil
    end
  end

  # --- the results page and the Lichess round ----------------------------------

  def openresults_configured?(%Tournament{server_url: url, slug: slug, relay_key: key}),
    do: url not in [nil, ""] and slug not in [nil, ""] and key not in [nil, ""]

  def lichess_configured?(%Tournament{lichess_round_id: id, lichess_token: token}),
    do: id not in [nil, ""] and token not in [nil, ""]

  @doc "The round of the tournament that goes to its Lichess round."
  def lichess_round(%Tournament{lichess_round: n}) when is_integer(n) and n > 0, do: n
  def lichess_round(%Tournament{round: round}), do: round || 1

  @doc "`\"orrk_...9f2c\"`: enough to tell two secrets apart, not enough to use one."
  def hint(secret, lead \\ 5)

  def hint(secret, lead) when is_binary(secret) and byte_size(secret) > 12,
    do: String.slice(secret, 0, lead) <> "..." <> String.slice(secret, -4, 4)

  def hint(secret, _lead) when is_binary(secret) and secret != "", do: "..."
  def hint(_none, _lead), do: nil

  def relay_key_hint(%Tournament{relay_key: key}), do: hint(key)
  def lichess_token_hint(%Tournament{lichess_token: token}), do: hint(token, 4)
  def secret_hint(%Link{secret: secret}), do: hint(secret)

  # --- tables ------------------------------------------------------------------

  @doc """
  Tables `from` to `to` play in this tournament, table `from` being its
  board 1. Every board that carries one of those numbers moves over, to the
  board its table now stands for; a range another tournament had that
  overlaps is given up there. `nil, nil` forgets the range.
  """
  def assign_tables(%Tournament{} = tournament, nil, nil) do
    {:ok, update!(tournament, %{table_from: nil, table_to: nil})}
  end

  def assign_tables(%Tournament{} = tournament, from, to)
      when is_integer(from) and is_integer(to) and from > 0 and to >= from do
    for other <- list(),
        other.id != tournament.id,
        other.table_from != nil,
        other.table_from <= to and (other.table_to || other.table_from) >= from do
      update!(other, %{table_from: nil, table_to: nil})
    end

    tournament = update!(tournament, %{table_from: from, table_to: to})

    for board <- Alnasl.Boards.list(), board.table_no != nil, board.table_no in from..to do
      Alnasl.Tables.assign(board, tournament)
    end

    Alnasl.Log.add(:info, "tournament.tables", %{
      tournament: title(tournament) || "",
      from: from,
      to: to
    })

    {:ok, tournament}
  end

  def assign_tables(_tournament, _from, _to), do: {:error, :range}

  @doc "The tournament whose range of tables holds table `number`, if any."
  def for_table(number) when is_integer(number) do
    Enum.find(list(), fn t ->
      not t.gone and t.table_from != nil and number >= t.table_from and
        number <= (t.table_to || t.table_from)
    end)
  end

  def for_table(_none), do: nil

  @doc "The board of the round that table `number` stands for in this tournament."
  def board_of_table(%Tournament{table_from: from}, number)
      when is_integer(from) and is_integer(number) and number >= from,
      do: number - from + 1

  def board_of_table(%Tournament{table_from: nil}, number) when is_integer(number), do: number
  def board_of_table(_tournament, _number), do: nil

  # --- the pairings ------------------------------------------------------------

  @doc "What the box holds of a tournament's pairings, decoded; `nil` when nothing."
  def document(%Tournament{document: nil}), do: nil

  def document(%Tournament{document: json}) do
    case Jason.decode(json) do
      {:ok, %{} = document} -> document
      _broken -> nil
    end
  end

  def document(id) when is_integer(id), do: id |> get() |> then(&(&1 && document(&1)))
  def document(nil), do: nil

  @doc "Name, site and rate of play, for PGN headers and the page title."
  def info(id) do
    tournament = get(id)
    document = tournament && document(tournament)
    described = (document && document["tournament"]) || %{}

    %{
      name: described["name"] || (tournament && tournament.name),
      city: described["site"] || described["city"],
      time_control: get_in(described, ["time_control", "text"]),
      time_control_pgn: get_in(described, ["time_control", "pgn"]),
      display: described["display"] || %{}
    }
  end

  @doc "The numbers of the rounds that are paired."
  def rounds(id) do
    case document(id) do
      %{"rounds" => rounds} when is_list(rounds) ->
        rounds |> Enum.map(& &1["number"]) |> Enum.filter(&is_integer/1) |> Enum.sort()

      _none ->
        []
    end
  end

  @doc """
  The boards of a round that have a game to follow, in board order:
  `[%{board, label, game, kind, white, black, white_id, black_id,
  white_rating, black_rating, result}]` with `white` and `black` the names
  as a tile shows them (title first).
  A bye has no board to set up and is left out.
  """
  def boards(id, round) do
    with %{"rounds" => rounds} = document <- document(id),
         %{"boards" => boards} <- Enum.find(rounds, &(&1["number"] == round)) do
      players = players_by_id(document)

      boards
      |> Enum.filter(&(is_integer(&1["board"]) and &1["kind"] != "bye"))
      |> Enum.map(fn b ->
        %{
          board: b["board"],
          label: b["label"],
          game: b["game"],
          kind: b["kind"] || "game",
          white: tile_name(players[b["white"]]),
          black: tile_name(players[b["black"]]),
          white_id: b["white"],
          black_id: b["black"],
          white_rating: rating(players[b["white"]]),
          black_rating: rating(players[b["black"]]),
          result: b["result"]
        }
      end)
      |> Enum.sort_by(& &1.board)
    else
      _none -> []
    end
  end

  def board(id, round, board_no), do: Enum.find(boards(id, round), &(&1.board == board_no))

  @doc "Where the pairing program's game `game` is now: `{round, board}` or `nil`."
  def find_game(_id, nil), do: nil

  def find_game(id, game) do
    case document(id) do
      %{"rounds" => rounds} when is_list(rounds) ->
        Enum.find_value(rounds, fn round ->
          Enum.find_value(List.wrap(round["boards"]), fn b ->
            if b["game"] == game and b["kind"] != "bye", do: {round["number"], b["board"]}
          end)
        end)

      _none ->
        nil
    end
  end

  @doc """
  The two players of a board as the pairing program describes them:
  `%{white: player | nil, black: player | nil}`, each a map with `:name`,
  `:title`, `:rating`, `:fide_id` and `:federation` (any of them `nil`).
  For destinations that want more than a name.
  """
  def players(id, round, board_no) do
    with %{"rounds" => rounds} = document <- document(id),
         %{"boards" => boards} <- Enum.find(rounds, &(&1["number"] == round)),
         %{} = board <- Enum.find(boards, &(&1["board"] == board_no)) do
      by_id = players_by_id(document)
      %{white: player(by_id[board["white"]]), black: player(by_id[board["black"]])}
    else
      _none -> %{white: nil, black: nil}
    end
  end

  defp rating(%{"rating" => rating}) when is_integer(rating) and rating > 0, do: rating
  defp rating(_none), do: nil

  defp players_by_id(document),
    do: Map.new(List.wrap(document["players"]), &{&1["id"], &1})

  defp player(%{"name" => name} = p) when is_binary(name) do
    %{
      name: name,
      title: if(p["title"] in [nil, ""], do: nil, else: p["title"]),
      rating: if(is_integer(p["rating"]) and p["rating"] > 0, do: p["rating"]),
      fide_id: if(is_integer(p["fide_id"]) and p["fide_id"] > 0, do: p["fide_id"]),
      federation: if(p["federation"] in [nil, ""], do: nil, else: p["federation"])
    }
  end

  defp player(_none), do: nil

  defp tile_name(%{"name" => name} = player) when is_binary(name) do
    case player["title"] do
      title when is_binary(title) and title != "" -> "#{title} #{name}"
      _none -> name
    end
  end

  defp tile_name(_other), do: nil

  @doc """
  Says by hand who plays a board of the box's own tournament - the box has
  no pairing program to ask. Kept with the pairings, so the next board
  linked to that number, the PGN and the Lichess round all know. An empty
  name takes the player away.
  """
  def set_names(%Tournament{kind: "local"} = tournament, round, board_no, white, black)
      when is_integer(round) and is_integer(board_no) do
    document = document(tournament) || %{"tournament" => %{}, "players" => [], "rounds" => []}
    {white_id, document} = player_named(document, white)
    {black_id, document} = player_named(document, black)

    entry = %{
      "game" => nil,
      "board" => board_no,
      "label" => to_string(board_no),
      "kind" => "game",
      "white" => white_id,
      "black" => black_id,
      "result" => nil
    }

    rounds = List.wrap(document["rounds"])

    this =
      Enum.find(rounds, &(&1["number"] == round)) || %{"number" => round, "boards" => []}

    boards =
      this["boards"]
      |> List.wrap()
      |> Enum.reject(&(&1["board"] == board_no))
      |> then(&if(white_id || black_id, do: [entry | &1], else: &1))
      |> Enum.sort_by(& &1["board"])

    rounds =
      [Map.put(this, "boards", boards) | Enum.reject(rounds, &(&1["number"] == round))]
      |> Enum.reject(&(&1["boards"] == []))
      |> Enum.sort_by(& &1["number"])

    update(tournament, %{
      document: Jason.encode!(Map.put(document, "rounds", rounds)),
      document_at: DateTime.utc_now(:second)
    })
  end

  def set_names(%Tournament{}, _round, _board_no, _white, _black), do: {:error, :linked}

  defp player_named(document, name) do
    name = String.trim(name || "")
    players = List.wrap(document["players"])

    cond do
      name == "" ->
        {nil, document}

      known = Enum.find(players, &(tile_name(&1) == name or &1["name"] == name)) ->
        {known["id"], document}

      true ->
        id = Enum.max([2_000_000 | Enum.map(players, &(&1["id"] || 0))]) + 1
        {id, Map.put(document, "players", players ++ [%{"id" => id, "name" => name}])}
    end
  end

  @doc """
  Gives a tournament pairings written in the shape of the results server's
  public snapshot - `tournament` (name, city), `players` by number, `rounds`
  whose boards name two numbers. It is what the demo makes up and what the
  tests plant; the box itself does not fetch such a thing any more.
  """
  def import_snapshot(%Tournament{} = tournament, %{} = snapshot) do
    players =
      for %{"no" => no} = p <- List.wrap(snapshot["players"]), is_integer(no) do
        p |> Map.take(~w(no name title rating federation fide_id)) |> Map.put("id", no)
      end

    rounds =
      for %{"number" => number} = round <- List.wrap(snapshot["rounds"]) do
        %{
          "number" => number,
          "boards" =>
            for %{"board" => board} = b <- List.wrap(round["boards"]), is_integer(board) do
              %{
                "game" => nil,
                "board" => board,
                "label" => to_string(board),
                "kind" => "game",
                "white" => b["white"],
                "black" => b["black"],
                "result" => b["result"]
              }
            end
        }
      end

    described = snapshot["tournament"] || %{}

    update(tournament, %{
      name: described["name"] || tournament.name,
      document:
        Jason.encode!(%{
          "tournament" => %{
            "name" => described["name"],
            "site" => described["city"],
            "city" => described["city"]
          },
          "players" => players,
          "rounds" => rounds
        }),
      document_at: DateTime.utc_now(:second)
    })
  end

  # --- connect codes -----------------------------------------------------------

  def links, do: Link |> order_by([l], l.id) |> Repo.all()
  def get_link(nil), do: nil
  def get_link(id), do: Repo.get(Link, id)

  @doc "The tournaments a code reaches, as the box holds them."
  def of_link(%Link{id: id}),
    do: Tournament |> where([t], t.link_id == ^id) |> order_by([t], t.id) |> Repo.all()

  def link_of(%Tournament{link_id: id}), do: get_link(id)
end
