# The OpenPairings side of `mix alnasl.link_e2e`: what an arbiter would do in
# OpenPairings' own pages, done through its context functions, one step a
# run. It is run INSIDE an OpenPairings checkout, against a throwaway
# database, while that OpenPairings is serving on the same database:
#
#     cd <openpairings>
#     PORT=4061 mix run <alnasl>/tools/link_e2e_openpairings.exs seed
#     PORT=4061 mix run <alnasl>/tools/link_e2e_openpairings.exs pair-round-2
#
# Steps: seed, new-code, games, pair-round-2, clear-result, restore-result,
# swap, add-to-group, withdraw.
# Everything it makes is named "E2E ...". It is not part of either test
# suite and is never run in CI. See README, "The link, end to end".

Logger.configure(level: :warning)

import Ecto.Query

alias PairingsEngine.{Accounts, BoardLink, Pairing, Repo, TournamentGroups, Tournaments}
alias PairingsEngine.Accounts.Scope
alias PairingsEngine.Tournaments.{Player, Round, Tournament}

defmodule LinkE2E do
  import Ecto.Query

  alias PairingsEngine.{Accounts, BoardLink, Pairing, Repo, Tournaments}
  alias PairingsEngine.Accounts.Scope
  alias PairingsEngine.Tournaments.{Player, Round, Tournament}

  @email "link-e2e@example.test"

  def scope do
    user =
      Accounts.get_user_by_email(@email) ||
        case Accounts.register_user(%{email: @email}) do
          {:ok, user} -> user
          other -> raise "could not make the arbiter: #{inspect(other)}"
        end

    Scope.for_user(user)
  end

  def tournament(name), do: Repo.one(from t in Tournament, where: t.name == ^name, limit: 1)
  def tournament!(name), do: tournament(name) || raise("no tournament #{name}: run seed first")

  def ours,
    do: Repo.all(from t in Tournament, where: like(t.name, "E2E %"), order_by: t.id)

  @doc "A Swiss of `count` players with round 1 paired by the pairing engine."
  def make(scope, name, count) do
    tournament =
      Repo.insert!(%Tournament{
        name: name,
        type: "swiss",
        rounds_count: 3,
        round_dates: ["2026-10-12", "2026-10-13", "2026-10-14"],
        tiebreaks: ["BH"],
        city: "Ghent",
        start_date: "2026-10-12",
        rate_of_play: "90min/40moves+30min/end+30sec/move from move 1",
        user_id: scope.user.id
      })

    for n <- 1..count do
      Repo.insert!(%Player{
        tournament_id: tournament.id,
        name: "#{String.replace(name, "E2E ", "")} Player #{n}",
        title: if(n == 1, do: "IM"),
        fide_rating: 2300 - n * 20,
        federation: "BEL"
      })
    end

    pair!(tournament)
    Repo.get!(Tournament, tournament.id)
  end

  def pair!(%Tournament{} = tournament) do
    tournament = Repo.get!(Tournament, tournament.id)

    case Pairing.pair_next_round(tournament) do
      {:ok, _round} ->
        :ok

      {:ok, _round, _more} ->
        :ok

      other ->
        raise "pairing #{tournament.name} failed: #{inspect(other) |> String.slice(0, 600)}"
    end
  end

  def round(tournament, number) do
    Repo.one(
      from r in Round,
        where: r.tournament_id == ^tournament.id and r.number == ^number,
        preload: [pairings: [:white_player, :black_player]]
    )
  end

  def boards(tournament, number) do
    case round(tournament, number) do
      nil -> []
      round -> round.pairings |> Enum.filter(&(&1.white_player_id && &1.black_player_id)) |> Enum.sort_by(& &1.board)
    end
  end

  def say_round(tournament, number) do
    for p <- boards(tournament, number) do
      IO.puts(
        "PAIRING #{tournament.name}|#{number}|#{p.board}|#{p.white_player.name}|#{p.black_player.name}|#{p.result}"
      )
    end
  end

  def code(secret), do: PairingsEngineWeb.BoardLinkAddress.connect_code(secret)
end

[step | _args] = System.argv()
scope = LinkE2E.scope()

case step do
  "seed" ->
    if LinkE2E.tournament("E2E Open"), do: raise("already seeded: use a fresh database")

    open = LinkE2E.make(scope, "E2E Open", 6)
    u12 = LinkE2E.make(scope, "E2E U12", 4)
    solo = LinkE2E.make(scope, "E2E Solo", 4)

    {:ok, group} = TournamentGroups.create_group(scope, open, "E2E Festival")
    {:ok, _group} = TournamentGroups.join_group(scope, u12, group.id)

    {:ok, _link, group_secret} = BoardLink.create_group_link(scope, open)
    {:ok, _link, solo_secret} = BoardLink.create_link(scope, solo)

    for t <- [open, u12, solo], do: LinkE2E.say_round(t, 1)
    IO.puts("CODE group #{LinkE2E.code(group_secret)}")
    IO.puts("CODE solo #{LinkE2E.code(solo_secret)}")

  # What the boxes reported, as OpenPairings holds it.
  "games" ->
    for t <- LinkE2E.ours() do
      by_uid = BoardLink.games_by_uid(t.id)

      for {uid, game} <- by_uid do
        pairing = BoardLink.get_pairing(t.id, uid)

        IO.puts(
          Enum.join(
            [
              "GAME #{t.name}",
              uid,
              length(game.moves || []),
              game.status,
              game.result || "-",
              game.reconstructed,
              game.guessed,
              Map.get(game, :rewritten, "-"),
              "arbiter=#{(pairing && pairing.result) || ""}",
              "compare=#{pairing && BoardLink.compare(pairing.result, game)}"
            ],
            "|"
          )
        )
      end
    end

  # The arbiter enters round 1 of the Open (what the board saw, where it saw
  # something) and pairs round 2.
  "pair-round-2" ->
    open = LinkE2E.tournament!("E2E Open")
    seen = BoardLink.games_by_uid(open.id)

    for p <- LinkE2E.boards(open, 1), p.result in [nil, ""] do
      result = (seen[p.game_uid] && seen[p.game_uid].result) || "1/2-1/2"
      {:ok, _} = Tournaments.update_pairing_result(p, result)
    end

    LinkE2E.pair!(open)
    LinkE2E.say_round(Repo.get!(Tournament, open.id), 2)

  # Two players of round 2 change places: boards 1 and 2 exchange their Whites.
  "swap" ->
    open = LinkE2E.tournament!("E2E Open")
    [one, two | _] = LinkE2E.boards(open, 2)

    {:ok, _} =
      Tournaments.swap_players_in_round(
        Tournaments.get_round(open.id, 2),
        one.white_player_id,
        two.white_player_id
      )

    LinkE2E.say_round(open, 2)

  # A result of round 1 is cleared, as an arbiter correcting it would.
  "clear-result" ->
    open = LinkE2E.tournament!("E2E Open")
    [one | _] = LinkE2E.boards(open, 1)
    {:ok, _} = Tournaments.update_pairing_result(one, "", acknowledged: [:result_correction])
    IO.puts("CLEARED #{one.board}")

  "restore-result" ->
    open = LinkE2E.tournament!("E2E Open")
    [one | _] = LinkE2E.boards(open, 1)
    {:ok, _} =
      Tournaments.update_pairing_result(one, "1/2-1/2", acknowledged: [:result_correction])
    IO.puts("RESTORED #{one.board}")

  "add-to-group" ->
    open = LinkE2E.tournament!("E2E Open")
    late = LinkE2E.make(scope, "E2E Late", 4)
    %{group_id: group_id} = TournamentGroups.membership(open.id)
    {:ok, _group} = TournamentGroups.join_group(scope, late, group_id)
    LinkE2E.say_round(late, 1)

  # Another code for the group: a code is shown once, and this is how to
  # get one when the first was not kept.
  "new-code" ->
    open = LinkE2E.tournament!("E2E Open")
    {:ok, _link, secret} = BoardLink.create_group_link(scope, open)
    IO.puts("CODE group #{LinkE2E.code(secret)}")

  "withdraw" ->
    open = LinkE2E.tournament!("E2E Open")

    links = BoardLink.list_links(open)

    for link <- links.group ++ links.tournament do
      BoardLink.revoke_link(scope, open, link.id)
      IO.puts("WITHDRAWN #{link.id}")
    end

  other ->
    raise "unknown step #{other}"
end

IO.puts("DONE #{step}")
_ = {Player, Round, Pairing}
