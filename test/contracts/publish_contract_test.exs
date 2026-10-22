defmodule Alnasl.Contracts.PublishTest do
  @moduledoc """
  OpenResults' `publish-v1` (vendored), from Alnasl's side: what the outbox
  sends fits `live-board.request`, and every answer the contract has an
  example of means to `Alnasl.Outbox` what the contract says it means.

  The answers are the contract's examples, served as they are by
  `Alnasl.FakeIngest` (`{:answer, status, body}`). Where the contract has no
  example of a code Alnasl must tell apart, the body is written here and
  checked against `error.response` before it is used.
  """

  use Alnasl.DataCase, async: false

  alias Alnasl.{Contract, FakeIngest, Games, Outbox}
  alias Alnasl.Outbox.Entry

  setup do
    start_supervised!(FakeIngest)
    FakeIngest.install()
    on_exit(fn -> Application.delete_env(:alnasl, :req_options) end)
    :ok
  end

  defp new_game(board \\ 1), do: Games.ensure(1, board, %{white: "White", black: "Black"})

  defp play(game, sans, clock \\ nil) do
    Enum.reduce(sans, game, fn san, game ->
      {game, _replace?} =
        Games.apply_event(game, {:moves, [%{san: san, flags: [], clock: nil}]}, 1_000)

      Outbox.enqueue(game, clock, false)
    end)
  end

  defp answer(status, body), do: FakeIngest.mode({:answer, status, body})

  # The status each refusal comes with on POST /api/tournaments/:slug/live,
  # as live-board.response.schema.json lists them.
  @live_statuses %{
    "unauthorized" => 401,
    "key_required" => 403,
    "key_mismatch" => 403,
    "not_owner" => 403,
    "tournament_hidden" => 403,
    "installation_suspended" => 403,
    "installation_revoked" => 403,
    "address_blocked" => 403,
    "relay_key_revoked" => 403,
    "relay_key_wrong_tournament" => 403,
    "owner_suspended" => 403,
    "owner_revoked" => 403,
    "tournament_not_published" => 404,
    "moves_conflict" => 409,
    "board_not_published" => 409,
    "live_game_limit" => 409,
    "invalid_request" => 422,
    "invalid_fen" => 422,
    "invalid_moves" => 422,
    "ply_mismatch" => 422,
    "fen_mismatch" => 422,
    "rate_limited" => 429,
    "publishing_paused" => 503,
    "storage_low" => 503
  }

  test "the statuses above are the ones the contract lists for a live board" do
    description = Contract.read!(:publish, "live-board.response.schema.json")["description"]

    for {code, status} <- @live_statuses do
      assert description =~ ~r/#{status} [^;]*\b#{code}\b/,
             "live-board.response no longer says #{code} is a #{status}"
    end
  end

  describe "what is sent" do
    test "every body the outbox sends fits live-board.request" do
      clock = %{white_ms: 3_600_000, black_ms: 3_540_000, running: :black}
      game = play(new_game(), ~w(e4 e5 Nf3), clock)
      {game, true} = Games.apply_event(game, {:correction, 2, [], :takeback}, 2_000)
      game = Outbox.enqueue(game, clock, true)
      _game = game |> Games.finish("1/2-1/2") |> Outbox.enqueue(clock, false)

      from_fen =
        Games.ensure(1, 2, %{
          white: "W",
          black: "B",
          start_fen: "4k3/8/8/8/8/8/8/4K2R w K - 0 1"
        })

      play(from_fen, ~w(O-O))

      assert Outbox.drain() == :empty
      bodies = for {_status, body} <- FakeIngest.requests(), do: body
      assert length(bodies) == 6

      for body <- bodies, do: Contract.assert_valid!(:publish, "live-board.request", body)

      # Plies, not full moves: the contract counts half-moves.
      assert Enum.map(bodies, &length(&1["moves"])) == [1, 2, 3, 2, 2, 1]
      assert Enum.any?(bodies, &(&1["replace"] == true))
      assert Enum.any?(bodies, &(&1["status"] == "finished" and &1["result"] == "1/2-1/2"))
      assert Enum.any?(bodies, &is_binary(&1["start_fen"]))
    end

    test "the fake server's own answers fit the contract" do
      play(new_game(), ~w(e4 e5))
      FakeIngest.plant(1, 2, ~w(d4 d5))
      play(new_game(2), ~w(e4 e5))
      Outbox.drain()

      FakeIngest.mode(:paused)
      play(new_game(3), ~w(c4))
      Outbox.drain()
      FakeIngest.mode(:rate_limited)
      Outbox.drain()
      FakeIngest.mode(:ok)
      Outbox.drain()

      answers = FakeIngest.answers()
      assert Enum.any?(answers, &match?({409, _}, &1))

      for {status, body} <- answers do
        schema = if status == 200, do: "live-board.response", else: "error.response"
        Contract.assert_valid!(:publish, schema, body)
      end
    end
  end

  describe "what comes back" do
    test "stored, and stored already: both are sent" do
      for {name, body} <- Contract.examples(:publish, "live-board.response") do
        Repo.delete_all(Entry)
        answer(200, body)
        play(Games.ensure(1, 1, %{white: "W", black: "B"}), ~w(e4))

        assert {:sent, entry} = step()
        assert entry.state == "sent", name
        assert entry.error == body["reason"], name
      end
    end

    test "every refusal the contract has an example of is handled as its code says" do
      examples = Contract.examples(:publish, "error.response")
      assert examples != []

      handled =
        for {name, body} <- examples, status = @live_statuses[body["error"]] do
          Repo.delete_all(Entry)
          answer(status, body)
          play(Games.ensure(1, 1, %{white: "W", black: "B"}), ~w(e4))
          {name, body["error"], step()}
        end

      by_code = Map.new(handled, fn {_name, code, result} -> {code, result} end)

      # Too early: tried again later, nothing thrown away.
      assert {:retry, {:http, 409, "board_not_published"}, nil} = by_code["board_not_published"]
      # Wrong, and stays wrong: set aside.
      assert {:rejected, %Entry{error: "invalid_moves"}} = by_code["invalid_moves"]
      # Slow down, for as long as it says.
      assert {:retry, :rate_limited, 42_000} = by_code["rate_limited"]
      # The key: the queue waits.
      assert {:blocked, {403, "key_mismatch"}} = by_code["key_mismatch"]
    end

    test "a 409 board_not_published keeps the row, and it goes once the round is published" do
      answer(409, Contract.example(:publish, "error.response.board-not-published"))
      play(new_game(), ~w(e4 e5))

      assert {:retry, {:http, 409, "board_not_published"}, nil} = Outbox.drain()
      assert {:retry, _, _} = Outbox.drain()
      assert Outbox.counts() == %{"pending" => 2}
      # Not mistaken for a conflict: nothing was queued again as a replacement.
      refute Repo.exists?(from e in Entry, where: e.replace)

      FakeIngest.mode(:ok)
      assert Outbox.drain() == :empty
      assert FakeIngest.game(1, 1).moves == ~w(e4 e5)
      assert Outbox.counts() == %{"sent" => 2}
      assert Enum.all?(FakeIngest.requests(), &(elem(&1, 1)["replace"] == nil))
    end

    test "a 409 live_game_limit sets the row aside with that reason; no replacement is sent" do
      body =
        Contract.assert_valid!(:publish, "error.response", %{
          "error" => "live_game_limit",
          "detail" => "this tournament already shows 64 live games",
          "limit" => 64
        })

      answer(409, body)
      play(new_game(), ~w(e4))

      assert Outbox.drain() == :empty

      assert [%Entry{state: "rejected", error: "live_game_limit", detail: detail}] =
               Repo.all(Entry)

      assert detail =~ "64"
      assert length(FakeIngest.requests()) == 1
    end

    test "only a 409 moves_conflict sends the game again in full, as a replacement" do
      body =
        Contract.assert_valid!(:publish, "error.response", %{
          "error" => "moves_conflict",
          "detail" => "the moves disagree with those held"
        })

      answer(409, body)
      play(new_game(), ~w(e4))
      assert {:rejected, %Entry{error: "moves_conflict"}} = step()
      assert [%Entry{state: "pending", replace: true}] = Outbox.list("pending")
    end

    test "the connection test reads the server's answer as the contract gives it" do
      assert [server: :ok, key: :ok] =
               Alnasl.OpenResults.test("http://results.test", FakeIngest.slug(), FakeIngest.key())
    end
  end

  defp step, do: Outbox.step(Alnasl.Tournaments.default())
end
