defmodule Alnasl.FairPlay.PrivacyTest do
  @moduledoc """
  Fair-play data goes nowhere but the owner's pages: not into the PGN a
  game exports, not into what is sent to OpenResults or Lichess, not into the
  arbiter's log, not into the outbox. The test analyses a game with an
  engine whose answers are easy to recognise, then looks for them everywhere
  a game's data leaves.
  """

  use Alnasl.DataCase, async: false

  import Alnasl.FairPlayFixtures

  alias Alnasl.{FakeIngest, Games, Log, Outbox}
  alias Alnasl.Destination.LichessBroadcast
  alias Alnasl.FairPlay.{Analysis, Move}
  alias Alnasl.Games.Game
  alias Alnasl.Outbox.Entry

  @moduletag :capture_log

  # Words that only fair-play data would put anywhere.
  @markers ~w(fair stockfish sf19 played_cp near_count bench prefix_hash a2a3 b2b3 c2c3 engine)

  setup do
    start_supervised!(FakeIngest)
    FakeIngest.install()
    on_exit(fn -> Application.delete_env(:alnasl, :req_options) end)

    tournament = rated_tournament()
    game = game(tournament, random_sans(30, 4))
    :ok = Analysis.run(game.id, engine(), setting())
    assert Repo.aggregate(Move, :count) == 30

    %{game: Games.get!(game.id), tournament: tournament}
  end

  defp assert_clean(text, where) do
    lowered = String.downcase(inspect(text, limit: :infinity, printable_limit: :infinity))

    for marker <- @markers do
      refute lowered =~ marker, "#{where} mentions #{marker}"
    end
  end

  test "the stored game and its outbox entry have no field for it" do
    for schema <- [Game, Entry], field <- schema.__schema__(:fields) do
      name = Atom.to_string(field)

      refute name =~ ~r/fair|engine|analysis|bench|stockfish/,
             "#{inspect(schema)} has #{name}"
    end
  end

  test "the PGN of a game, of a round, and the file on disk", %{game: game, tournament: t} do
    assert_clean(Games.pgn(game), "Games.pgn")
    assert_clean(Games.round_pgn(t.id, 1), "Games.round_pgn")
    assert_clean(File.read!(Games.pgn_path(game)), "the PGN file")
    assert_clean(LichessBroadcast.pgn(game), "the Lichess PGN")
  end

  test "what is sent to the results site", %{game: game} do
    assert_clean(Games.body(game, nil, true), "the update body")

    Outbox.enqueue(game)
    assert_clean(Repo.all(Entry), "the outbox")
    Outbox.drain()

    assert FakeIngest.requests() != []
    assert_clean(FakeIngest.requests(), "the requests to the results site")
  end

  test "the arbiter's log does not hear of it", %{game: game} do
    before = Log.list()
    :ok = Analysis.run(game.id, engine(), setting(%{nodes: 123}))
    assert Log.list() == before
    assert_clean(Log.list(), "the log")
  end
end
