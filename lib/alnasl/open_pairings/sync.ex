defmodule Alnasl.OpenPairings.Sync do
  @moduledoc """
  What the box does with a tournament's document when the pairing program
  hands it a new one.

  ## 1. It is kept

  The document, its version, the tournament's name and state - and where
  its games go on the results site: address, short name and relay key
  arrive here and are the tournament's from then on. A tournament that is
  not published (`openresults: null`) has no results page, and one whose
  arbiter saved no relay key has no key: the box then sends nothing there
  and goes on reporting to the pairing program.

  ## 2. The round is started

  The pairing program has no "start the round": a round that is paired is
  on, and `current_round` says which. When that number changes, the box
  starts that round for this tournament's boards by itself
  (`Alnasl.Boards.start_round/2`) - names, ratings, colours and the rate of
  play are on the tiles a few seconds after the arbiter paired. The boards
  of the other tournaments are not touched. One exception: the number
  going *down* while a game of the round on the boards is being played
  moves nothing (see `under_way?/1`). A tournament can be told not
  to (`auto_start`): the Round page then says which round the pairing
  program is on and leaves the button to the arbiter. The arbiter may also
  look at another round by hand; the box follows again when the pairing
  program moves on.

  ## 3. The games are held against the pairings

  Every game the box has for the tournament - the one being played on each
  board, not the ones kept on the box - is compared with what the document
  now says for it:

  | the document says | the game |
  |---|---|
  | the same game, the same two players | its names are refreshed |
  | the same game on another board number | moves there, and the physical board with it: the pairing program renumbered it |
  | another game, or other players, and **nothing has been played** | simply becomes the new pairing's |
  | other players or the colours the other way round, and **moves have been made** | is kept as it is and flagged `changed` |
  | no such game any more, and moves have been made | is kept as it is and flagged `gone` |

  A flagged game is not thrown away, not renamed and not reported to the
  pairing program (which would refuse it: `409`). Its tile says "Pairing
  changed", and the arbiter chooses on the board's page: these moves are the
  new pairing's game (`Alnasl.Boards.adopt_pairing/1`), or set it aside and
  begin again (`Alnasl.Boards.set_aside/1`). Until then the moves keep
  going to the results site and Lichess under the names the game had. The
  flag goes by itself when the pairing program is put back as it was.

  Why not decide for the arbiter: a colour switch entered because two
  players sat down the wrong way round means the game on the board is the
  right one, with the names exchanged; a round paired again while board 3
  had already begun means the game on board 3 is nobody's. The document
  looks the same in both cases.
  """

  alias Alnasl.{Boards, Games, Log, Repo, Tournaments}
  alias Alnasl.Tournaments.Tournament

  @doc "Takes a new document for a linked tournament. Returns the tournament."
  def apply(%Tournament{} = tournament, %{} = document) do
    target = target(document["openresults"])
    current = document["current_round"]

    was = tournament.remote_round
    target_was = {tournament.server_url, tournament.slug, tournament.relay_key}

    tournament =
      Tournaments.update!(
        tournament,
        Map.merge(target, %{
          document: Jason.encode!(document),
          document_at: DateTime.utc_now(:second),
          version: document["version"],
          listed_version: document["version"],
          name: get_in(document, ["tournament", "name"]) || tournament.name,
          state: get_in(document, ["tournament", "state"]) || tournament.state,
          remote_round: if(is_integer(current), do: current)
        })
      )

    tournament =
      if is_integer(current) and current != was and tournament.auto_start and
           (current > tournament.round or not under_way?(tournament)) do
        Boards.start_round(tournament.id, current)
        Tournaments.get!(tournament.id)
      else
        tournament
      end

    reconcile(tournament)

    # A results page that has just arrived (or is another one now) gets every
    # game as it stands; there was nowhere to send them until now.
    if Tournaments.openresults_configured?(tournament) and
         {tournament.server_url, tournament.slug, tournament.relay_key} != target_was,
       do: Alnasl.Outbox.requeue(tournament.id)

    Boards.refresh_games(tournament.id)
    Tournaments.notify(tournament.id)
    tournament
  end

  # Is a game being played in the round the box has on? Then the box does
  # not walk its boards BACK to an earlier round by itself. `current_round`
  # is "the lowest round with a result missing", so an arbiter who clears a
  # result of round 2 to correct it, while round 3 is being played, makes it
  # say 2 for a minute. The Round page says where the pairing program is
  # and offers the button; the boards stay with the games on them.
  defp under_way?(%Tournament{} = tournament) do
    tournament.id
    |> Games.list(tournament.round)
    |> Enum.any?(&(not &1.local and &1.status == "live" and Games.begun?(&1)))
  end

  defp target(%{"server_url" => url, "slug" => slug} = target)
       when is_binary(url) and is_binary(slug) do
    %{
      server_url: String.trim_trailing(url, "/"),
      slug: slug,
      relay_key: if(is_binary(target["relay_key"]), do: target["relay_key"], else: "")
    }
  end

  defp target(_not_published), do: %{server_url: "", slug: "", relay_key: ""}

  # --- games against pairings --------------------------------------------------

  @doc "Holds every game of the tournament against its pairings as they are now."
  def reconcile(%Tournament{} = tournament) do
    games =
      for round <- Games.rounds(tournament.id),
          game <- Games.list(tournament.id, round),
          not game.local,
          do: game

    # A game the pairing program gave another board number goes there first,
    # so that what is compared afterwards is each game with its own board.
    games |> moved(tournament) |> move(tournament)

    for round <- Games.rounds(tournament.id),
        game <- Games.list(tournament.id, round),
        not game.local do
      judge(game, Tournaments.board(tournament.id, game.round, game.board_no))
    end

    :ok
  end

  # `[{game, new board number}]` for begun games whose id is now at another
  # board of the same round, with the same two players.
  defp moved(games, tournament) do
    for game <- games,
        game.remote_game != nil,
        Games.begun?(game),
        {round, board_no} <- [Tournaments.find_game(tournament.id, game.remote_game)],
        round == game.round,
        board_no != game.board_no,
        pairing = Tournaments.board(tournament.id, round, board_no),
        Games.same_pairing?(game, Games.pairing_attrs(pairing)),
        do: {game, board_no}
  end

  defp move([], _tournament), do: :ok

  defp move(moves, tournament) do
    # Out of the way first: two games may be changing places.
    parked =
      for {{game, to}, index} <- Enum.with_index(moves) do
        boards = for b <- feeding(game), do: elem(Boards.update(b, %{board_no: nil}), 1)
        {Games.move(game, -1 - index), game.board_no, to, boards}
      end

    for {game, from, to, boards} <- parked do
      there = Games.history(tournament.id, game.round, to)

      # A begun game that is not going anywhere holds the number: this one
      # goes back where it was, and is judged there like any other.
      to = if Enum.any?(there, &Games.begun?/1), do: from, else: to

      # A game that never began may be sitting on the number: it gives way,
      # and the board that waited for it takes the number this one left -
      # the players who were paired here are the ones paired there now.
      if to != from do
        for other <- there, do: Repo.delete(other)

        for board <- feeding(%{game | board_no: to}),
            do: Boards.update(board, %{board_no: from})
      end

      Games.move(game, to)

      if to != from do
        Log.add(:info, "pairing.board_moved", %{from: from, to: to}, %{
          round: game.round,
          board_no: to
        })
      end

      for board <- boards, do: Boards.update(Boards.get!(board.id), %{board_no: to})
    end

    :ok
  end

  defp feeding(game) do
    Enum.filter(
      Boards.list(),
      &(&1.tournament_id == game.tournament_id and &1.round == game.round and
          &1.board_no == game.board_no)
    )
  end

  # The box's own tournament, or a board no pairing names: nothing to hold
  # the game against.
  defp judge(%{remote_game: nil} = game, nil), do: game

  defp judge(game, nil) do
    if Games.begun?(game), do: flag(game, "gone"), else: Games.adopt(game, nil)
  end

  defp judge(game, %{game: nil}), do: game

  defp judge(game, pairing) do
    attrs = Games.pairing_attrs(pairing)

    cond do
      Games.same_pairing?(game, attrs) ->
        if {game.white, game.black, game.pairing_flag} != {attrs.white, attrs.black, nil},
          do: Games.adopt(game, pairing),
          else: game

      # Nothing played, or a game that was nobody's until now: the pairing's.
      not Games.begun?(game) or game.remote_game == nil ->
        Games.adopt(game, pairing)

      game.remote_game == pairing.game ->
        flag(game, "changed")

      true ->
        flag(game, "gone")
    end
  end

  @doc "Flags a game whose pairing changed under it, and writes it in the log - once."
  def flag(%{pairing_flag: flag} = game, flag), do: game

  def flag(game, flag) do
    ref = %{round: game.round, board_no: game.board_no}

    case flag do
      "gone" -> Log.add(:warn, "pairing.gone", %{}, ref)
      "changed" -> Log.add(:warn, "pairing.changed", %{}, ref)
    end

    Games.flag(game, flag)
  end
end
