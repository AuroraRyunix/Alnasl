defmodule Alnasl.Contracts.LinkTest do
  @moduledoc """
  OpenPairings' `alnasl-link-v1` (vendored), from Alnasl's side.

  Every answer the contract has an example of is served as it is, by a
  plug standing in for OpenPairings, to the box's real client and the code
  behind it (`Alnasl.OpenPairings`, its sync, the destination that reports
  games, the account connect); every request the box builds is checked
  against the request schemas. And `Alnasl.FakeOpenPairings`, which the
  other tests talk to, is held to the same schemas: a fake that drifts from
  the real thing proves nothing about it.
  """

  use Alnasl.DataCase, async: false

  import Alnasl.LinkHelpers

  alias Alnasl.{Contract, FakeOpenPairings, Games, OpenPairings, Outbox, Tournaments}
  alias Alnasl.Destination.Cursor
  alias Alnasl.Destination.OpenPairings, as: Reports
  alias Alnasl.OpenPairings.{Client, Connect}
  alias Alnasl.Tournaments.Link

  @root "http://pairings.test/api/boards/v1"

  # --- a stand-in that answers with the contract's examples --------------------

  # `answers` maps {method, path} to {status, body} or to a function of the
  # request body. Every request is sent to the test as {:request, method,
  # path, body}.
  defp serve(answers) do
    test = self()

    plug = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = if raw == "", do: nil, else: Jason.decode!(raw)
      send(test, {:request, conn.method, conn.request_path, body})

      {status, answer} =
        case Map.get(answers, {conn.method, conn.request_path}) do
          nil -> {404, %{"error" => "not_found", "detail" => "not in this test"}}
          fun when is_function(fun, 1) -> fun.(body)
          answer -> answer
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(answer))
    end

    Application.put_env(:alnasl, :openpairings_req_options, plug: plug)
    on_exit(fn -> Application.delete_env(:alnasl, :openpairings_req_options) end)
  end

  defp ok(name), do: {200, Contract.example(:link, name)}

  defp sent(method, path) do
    receive do
      {:request, ^method, ^path, body} -> body
    after
      0 -> flunk("no #{method} #{path} was sent")
    end
  end

  defp v1(path), do: "/api/boards/v1" <> path

  # A tournament reached by a code, the stand-in answering with `document`.
  defp link_with(document) do
    serve(%{
      {"GET", v1("/link")} => ok("link-response"),
      {"GET", v1("/tournaments/1")} => ok(document),
      {"POST", v1("/box")} => ok("box-response")
    })

    {:ok, link, [tournament]} = OpenPairings.add_code(@root <> "#oplt_example")
    {link, tournament}
  end

  describe "the answers, as the box reads them" do
    test "a listing and a tournament: the pairings are on the box" do
      {link, tournament} = link_with("tournament-response")

      assert link.state == "ok" and link.kind == "tournament"
      assert link.server_version == "0.101.3"
      assert tournament.remote_id == 1 and tournament.name == "Board Link Open"
      assert tournament.remote_round == 1

      assert [%{board: 1, game: "e91dd5ef6fe3ad1d7d580629b473a62d"} = one, %{board: 2}] =
               Tournaments.boards(tournament.id, 1)

      assert one.white == "Player 1" and one.black == "Player 2" and one.white_id == 1

      info = Tournaments.info(tournament.id)
      assert info.time_control == "90min/40moves+30min/end+30sec/move from move 1"
      assert info.time_control_pgn == "40/5400+30:1800+30"

      # Not published: nowhere for the moves to go on a results site.
      refute Tournaments.openresults_configured?(tournament)
    end

    test "a published tournament brings its results page and relay key" do
      {_link, tournament} = link_with("tournament-response.published")

      assert tournament.server_url == "https://results.example.org"
      assert tournament.slug == "k3v9x2"
      assert tournament.relay_key == "orrk_0123456789abcdef"
      assert Tournaments.openresults_configured?(tournament)
    end

    test "an account's listing is taken the same way" do
      serve(%{
        {"GET", v1("/link")} => ok("link-response.account"),
        {"GET", v1("/tournaments/2")} => ok("tournament-response"),
        {"POST", v1("/box")} => ok("box-response")
      })

      assert {:ok, %Link{kind: "account"}, [tournament]} =
               OpenPairings.add_code(@root <> "#oplu_example")

      assert tournament.remote_id == 2
    end

    test "game answers: each ok is acknowledged, an error flags the game it names" do
      {_link, tournament} = link_with("tournament-response")
      _e91 = play(tournament, 1, ~w(e4 e5))
      _5c2 = play(tournament, 2, ~w(d4))

      # The answers of games-response.mixed, given in the order the box
      # asked (the contract's rule: one answer per game, in order).
      mixed = Contract.example(:link, "games-response.mixed")["results"]
      by_game = Map.new(mixed, &{&1["game"], &1})

      serve(%{
        {"POST", v1("/tournaments/1/games")} => fn %{"games" => games} ->
          {200, %{"status" => "ok", "results" => Enum.map(games, &by_game[&1["game"]])}}
        end
      })

      # The duplicate is taken (the program had it already); the refused one is not.
      assert {:empty, 1} = Reports.deliver()
      %{"games" => games} = sent("POST", v1("/tournaments/1/games"))
      assert length(games) == 2

      e91 = Games.list(tournament.id, 1) |> Enum.find(&(&1.board_no == 1))
      assert e91.pairing_flag == "changed"

      errors = for c <- Repo.all(Cursor), c.destination == "openpairings", do: c.error
      assert Enum.any?(errors, &(&1 =~ "pairing_changed"))
    end

    test "game answers that are all ok: every game is taken" do
      {_link, tournament} = link_with("tournament-response")
      play(tournament, 1, ~w(e4 e5))
      play(tournament, 2, ~w(d4))

      answers = Contract.example(:link, "games-response")["results"]

      serve(%{
        {"POST", v1("/tournaments/1/games")} => fn %{"games" => games} ->
          by_game = Map.new(answers, &{&1["game"], &1})
          {200, %{"status" => "ok", "results" => Enum.map(games, &by_game[&1["game"]])}}
        end
      })

      assert {:empty, 2} = Reports.deliver()
      assert Reports.pending_count() == 0
    end

    test "every batch answer is read by the client as a list of answers" do
      link = %Link{root: @root, secret: "oplt_example"}

      for {name, %{"results" => results} = body} <- Contract.examples(:link, "games-response") do
        serve(%{{"POST", v1("/tournaments/1/games")} => {200, body}})
        assert Client.report(link, 1, []) == {:ok, results}, name

        for answer <- results do
          assert answer["status"] in ["ok", "error"]
          if answer["status"] == "ok", do: assert(answer["reason"] in [nil, "duplicate", "stale"])
        end
      end
    end

    test "the refusals: each means to the box what its code says" do
      link = %Link{root: @root, secret: "oplt_example"}

      serve(%{
        {"GET", v1("/link")} => {401, Contract.example(:link, "error.unauthorized")},
        {"GET", v1("/tournaments/9")} => {404, Contract.example(:link, "error")},
        {"POST", v1("/tournaments/1/games")} =>
          {409, Contract.example(:link, "error.pairing-changed")},
        {"POST", v1("/grant")} => {401, Contract.example(:link, "error.invalid-grant")}
      })

      assert Client.listing(link) == {:error, :unauthorized}
      assert Client.tournament(link, 9) == {:error, :tournament_not_found}

      assert {:error, {:refused, 409, "pairing_changed", detail}} = Client.report(link, 1, [])
      assert detail =~ "no longer between these two players"

      assert Connect.redeem("http://pairings.test", "used") == {:error, :expired}
    end

    test "a grant is traded for the code it stands for" do
      serve(%{{"POST", v1("/grant")} => ok("grant-response")})
      code = Contract.example(:link, "grant-response")["code"]

      assert Connect.redeem("http://pairings.test", "the-grant") == {:ok, code}
      Contract.assert_valid!(:link, "grant-request", sent("POST", v1("/grant")))
    end
  end

  describe "the requests, as the box builds them" do
    test "what the box says about itself fits box-request" do
      {link, _tournament} = link_with("tournament-response")
      Alnasl.Settings.put("box_name", "Hall A")

      assert :ok = Alnasl.OpenPairings.tell(link)
      Contract.assert_valid!(:link, "box-request", sent("POST", v1("/box")))
    end

    test "every report fits games-request: waiting, live, finished, forced, from a position" do
      {_link, tournament} = link_with("tournament-response")
      clock = %{white_ms: 5_398_000, black_ms: 5_391_000, running: :black}

      # A game nobody has touched yet is "waiting".
      pairing = Tournaments.board(tournament.id, 1, 1)
      fresh = Games.ensure(tournament.id, 1, 1, Games.pairing_attrs(pairing))
      waiting = Reports.report(fresh)
      assert waiting["status"] == "waiting"
      Contract.assert_valid!(:link, "games-request", %{"games" => [waiting]})

      _live = play(tournament, 1, ~w(e4 e5 Nf3), clock, [:recovered])

      finished =
        tournament |> play(2, ~w(f3 e5 g4 Qh4#)) |> Games.finish("0-1")

      Outbox.enqueue(finished, nil, false)

      serve(%{
        {"POST", v1("/tournaments/1/games")} => fn %{"games" => games} ->
          {200,
           %{
             "status" => "ok",
             "results" =>
               for(
                 g <- games,
                 do: %{
                   "status" => "ok",
                   "game" => g["game"],
                   "applied" => true,
                   "seq" => g["seq"]
                 }
               )
           }}
        end
      })

      assert {:empty, 2} = Reports.deliver()

      body =
        Contract.assert_valid!(:link, "games-request", sent("POST", v1("/tournaments/1/games")))

      statuses = body["games"] |> Enum.map(& &1["status"]) |> Enum.sort()
      assert statuses == ["finished", "live"]

      # One entry a ply, moves and clocks alike.
      for game <- body["games"], do: assert(length(game["moves"]) == length(game["move_clocks"]))

      for game <- Games.list(tournament.id, 1) do
        report = Reports.report(game, %Cursor{force: true})
        assert report["replace"] == true
        Contract.assert_valid!(:link, "games-request", %{"games" => [report]})
      end
    end
  end

  describe "the fake pairing program the other tests talk to" do
    setup do
      pairing_program()
    end

    test "answers as the contract says" do
      FakeOpenPairings.add_tournament(17, name: "Open", boards: 3)
      FakeOpenPairings.add_team_tournament(18, teams: 4, per_match: 4)
      FakeOpenPairings.add_tournament(19, boards: 2, openresults: nil)

      link = %Link{
        root: FakeOpenPairings.root(),
        secret: FakeOpenPairings.secret(FakeOpenPairings.code(17))
      }

      assert {:ok, listing, _etag} = Client.listing(link)
      Contract.assert_valid!(:link, "link-response", listing)

      for id <- [17, 18, 19] do
        Contract.assert_valid!(:link, "tournament-response", FakeOpenPairings.document(id))
      end

      group = %Link{
        root: FakeOpenPairings.root(),
        secret: FakeOpenPairings.secret(FakeOpenPairings.account_code([17, 18]))
      }

      assert {:ok, listing, _etag} = Client.listing(group)
      Contract.assert_valid!(:link, "link-response", listing)
    end
  end

  # --- games -------------------------------------------------------------------

  defp play(tournament, board, sans, clock \\ nil, flags \\ []) do
    pairing = Tournaments.board(tournament.id, 1, board)
    game = Games.ensure(tournament.id, 1, board, Games.pairing_attrs(pairing))

    Enum.reduce(sans, game, fn san, game ->
      ply = %{san: san, flags: flags, clock: clock && Map.take(clock, [:white_ms, :black_ms])}
      {game, _replace?} = Games.apply_event(game, {:moves, [ply]}, 1_791_700_000_000)
      game |> Games.remember_clock(clock) |> Outbox.enqueue(clock, false)
    end)
  end
end
