defmodule Alnasl.LichessTest do
  @moduledoc """
  The Lichess destination against a stand-in for Lichess
  (`Alnasl.FakeLichess`), and beside the results server
  (`Alnasl.FakeIngest`): what is pushed, in what order, how often, and that
  neither destination waits for the other.
  """

  use Alnasl.DataCase, async: false

  alias Alnasl.{Destination, FakeIngest, FakeLichess, Games, Outbox, Settings, Tournament}
  alias Alnasl.Destination.{LichessApi, LichessBroadcast, OpenResults, Sender}

  @game ~w(e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6 O-O Be7)

  setup do
    start_supervised!(FakeIngest)
    FakeIngest.install()
    {:ok, _snapshot} = Tournament.refresh()
    start_supervised!(FakeLichess)
    FakeLichess.install()

    on_exit(fn ->
      Application.delete_env(:alnasl, :req_options)
      Application.delete_env(:alnasl, :lichess_coalesce_ms)
      FakeLichess.uninstall()
    end)

    :ok
  end

  defp new_game(board \\ 1, round \\ 1) do
    names = Tournament.board(round, board) || %{}
    Games.ensure(round, board, %{white: names[:white], black: names[:black]})
  end

  # Plays `sans` onto `game`, queueing after each move, as a board does.
  defp play(game, sans, clock \\ nil) do
    Enum.reduce(sans, game, fn san, game ->
      {game, _replace?} =
        Games.apply_event(game, {:moves, [%{san: san, flags: [], clock: clock}]}, 1_000)

      Outbox.enqueue(game, clock && Map.put(clock, :running, :white), false)
    end)
  end

  defp wait_until(fun, left \\ 200) do
    cond do
      fun.() ->
        :ok

      left == 0 ->
        flunk("timed out waiting")

      true ->
        receive do
          _any -> wait_until(fun, left - 1)
        after
          25 -> wait_until(fun, left - 1)
        end
    end
  end

  describe "what is pushed" do
    test "every changed game of the round in one request, boards in order, as PGN with players and clocks" do
      play(new_game(2), ~w(d4 d5))
      play(new_game(1), ~w(e4 e5 Nf3), %{white_ms: 5_400_000, black_ms: 5_390_000})
      assert LichessBroadcast.pending_count() == 2

      assert {:empty, 2} = LichessBroadcast.deliver()
      assert LichessBroadcast.pending_count() == 0

      assert [{200, [first, second]}] = FakeLichess.pushes()
      assert first.headers["Board"] == "1" and second.headers["Board"] == "2"
      assert first.moves == ~w(e4 e5 Nf3) and second.moves == ~w(d4 d5)

      # Names without the title in front; title, rating and round as tags.
      assert %{
               "White" => "Player 1",
               "WhiteTitle" => "GM",
               "WhiteElo" => "2001",
               "Black" => "Player 2",
               "BlackElo" => "2002",
               "Round" => "1",
               "Result" => "*",
               "Event" => "Test Open"
             } = first.headers

      refute Map.has_key?(first.headers, "BlackTitle")
      assert first.clocks == [5_400_000, 5_390_000, 5_400_000]

      pgn = LichessBroadcast.pgn(Games.get(1, 1))
      assert pgn =~ "1. e4 {[%clk 1:30:00]} 1... e5 {[%clk 1:29:50]}"
    end

    test "a later push is the whole game again, and a result goes with it" do
      game = play(new_game(), Enum.take(@game, 4))
      assert {:empty, 1} = LichessBroadcast.deliver()

      game = play(game, Enum.slice(@game, 4, 6))
      assert {:empty, 1} = LichessBroadcast.deliver()
      assert FakeLichess.game(1).moves == @game

      game |> Games.finish("1/2-1/2") |> Outbox.enqueue(nil, false)
      assert {:empty, 1} = LichessBroadcast.deliver()
      assert FakeLichess.game(1).headers["Result"] == "1/2-1/2"
      assert FakeLichess.game(1).result == "1/2-1/2"
      assert length(FakeLichess.pushes()) == 3
    end

    test "a correction replaces the game Lichess holds" do
      game = play(new_game(), ~w(e4 e5 Nf3 Nc6))
      assert {:empty, 1} = LichessBroadcast.deliver()
      assert FakeLichess.game(1).moves == ~w(e4 e5 Nf3 Nc6)

      # The last two moves were not what was played.
      {game, true} =
        Games.apply_event(
          game,
          {:correction, 2, [%{san: "Bc4", flags: [], clock: nil}], :takeback},
          2_000
        )

      Outbox.enqueue(game, nil, true)
      assert {:empty, 1} = LichessBroadcast.deliver()
      assert FakeLichess.game(1).moves == ~w(e4 e5 Bc4)
      assert map_size(FakeLichess.games()) == 1
    end

    test "a change that leaves the PGN as it was - a clock refresh - is not sent again" do
      game = play(new_game(), ~w(e4 e5))
      assert {:empty, 1} = LichessBroadcast.deliver()

      game = Outbox.enqueue(game, %{white_ms: 60_000, black_ms: 50_000, running: :white}, false)
      _game = Outbox.enqueue(game, %{white_ms: 55_000, black_ms: 50_000, running: :white}, false)
      assert LichessBroadcast.pending_count() == 1
      assert {:empty, 0} = LichessBroadcast.deliver()
      assert LichessBroadcast.pending_count() == 0
      assert length(FakeLichess.pushes()) == 1
    end

    test "only the round the Lichess round stands for" do
      play(new_game(1, 1), ~w(e4))
      play(new_game(1, 2), ~w(d4))
      assert LichessBroadcast.pending_count() == 1
      assert {:empty, 1} = LichessBroadcast.deliver()
      assert [{200, [game]}] = FakeLichess.pushes()
      assert game.headers["Round"] == "1"

      Settings.put("lichess_round", 2)
      assert LichessBroadcast.pending_count() == 1
      assert {:empty, 1} = LichessBroadcast.deliver()
      assert [_first, {200, [second]}] = FakeLichess.pushes()
      assert second.headers["Round"] == "2" and second.moves == ~w(d4)
    end

    test "a game sending is paused for is not pushed until it is resumed" do
      game = play(new_game(), ~w(e4))
      assert {:empty, 1} = LichessBroadcast.deliver()

      game = Games.pause(game, true)
      game = play(game, ~w(e5 Nf3))
      assert LichessBroadcast.pending_count() == 0

      game |> Games.pause(false) |> Outbox.enqueue(nil, true)
      assert {:empty, 1} = LichessBroadcast.deliver()
      assert FakeLichess.game(1).moves == ~w(e4 e5 Nf3)
    end
  end

  describe "when Lichess does not take it" do
    test "offline: nothing is lost, and what goes out afterwards is the game as it stands then" do
      game = play(new_game(), ~w(e4 e5))
      assert {:empty, 1} = LichessBroadcast.deliver()

      FakeLichess.mode(:down)
      game = play(game, ~w(Nf3 Nc6 Bb5))
      play(new_game(2), ~w(d4))
      assert {{:retry, {:unreachable, :econnrefused}, nil}, 0} = LichessBroadcast.deliver()
      assert {{:retry, _, _}, 0} = LichessBroadcast.deliver()
      assert LichessBroadcast.pending_count() == 2
      assert FakeLichess.game(1).moves == ~w(e4 e5)

      _game = play(game, ~w(a6))
      FakeLichess.mode(:ok)
      assert {:empty, 2} = LichessBroadcast.deliver()
      assert FakeLichess.game(1).moves == ~w(e4 e5 Nf3 Nc6 Bb5 a6)
      assert FakeLichess.game(2).moves == ~w(d4)
      # One request for the lot: the outage is not replayed move by move.
      assert length(FakeLichess.pushes()) == 2
    end

    test "429: silence for as long as Lichess asks - a minute when it does not say" do
      play(new_game(), ~w(e4))
      FakeLichess.mode(:rate_limited)
      assert {{:retry, :rate_limited, 60_000}, 0} = LichessBroadcast.deliver()
      assert LichessBroadcast.pending_count() == 1

      FakeLichess.mode(:ok)
      assert {:empty, 1} = LichessBroadcast.deliver()
      assert [{429, _}, {200, [_game]}] = FakeLichess.pushes()
    end

    test "a bad token, a round that is not this token's, a round that is not there: wait and say so" do
      play(new_game(), ~w(e4))

      Settings.put("lichess_token", "lip_wrong")
      assert {{:blocked, {:lichess, 401, "No such token"}}, 0} = LichessBroadcast.deliver()

      Settings.put("lichess_token", FakeLichess.token())
      FakeLichess.mode(:not_yours)
      assert {{:blocked, {:lichess, 403, _}}, 0} = LichessBroadcast.deliver()

      FakeLichess.mode(:ok)
      Settings.put("lichess_round_id", "Zz999999")
      assert {{:blocked, {:lichess, 404, _}}, 0} = LichessBroadcast.deliver()
      assert LichessBroadcast.pending_count() == 1

      Settings.put("lichess_round_id", FakeLichess.round_id())
      assert {:empty, 1} = LichessBroadcast.deliver()
    end

    test "a server error is tried again; without a round or a token nothing is tried" do
      play(new_game(), ~w(e4))
      FakeLichess.mode({:status, 502})
      assert {{:retry, {:http, 502, nil}, nil}, 0} = LichessBroadcast.deliver()

      Settings.put("lichess_token", "")
      refute LichessBroadcast.configured?()
      assert {:unconfigured, 0} = LichessBroadcast.deliver()
      assert LichessBroadcast.pending_count() == 1
    end

    test "one game Lichess refuses does not hold up the others, and is shown" do
      play(new_game(1), ~w(e4))
      play(new_game(2), ~w(d4))
      FakeLichess.mode({:refuse_board, 2})
      assert {:empty, 2} = LichessBroadcast.deliver()
      assert FakeLichess.game(1).moves == ~w(e4)
      assert FakeLichess.game(2) == nil
      assert [{%{board_no: 2}, "Cannot parse moves"}] = LichessBroadcast.refused()

      # Its next change is its next chance.
      FakeLichess.mode(:ok)
      play(Games.get(1, 2), ~w(d5))
      assert {:empty, 1} = LichessBroadcast.deliver()
      assert FakeLichess.game(2).moves == ~w(d4 d5)
      assert LichessBroadcast.refused() == []
    end
  end

  describe "destinations do not wait for each other" do
    test "the results server down: Lichess gets everything; and the other way round" do
      FakeIngest.mode(:down)
      game = play(new_game(), ~w(e4 e5))
      assert {:retry, {:unreachable, :econnrefused}, nil} = Outbox.drain()
      assert {:empty, 1} = LichessBroadcast.deliver()
      assert FakeLichess.game(1).moves == ~w(e4 e5)
      assert Outbox.pending_count() == 2 and LichessBroadcast.pending_count() == 0

      FakeIngest.mode(:ok)
      FakeLichess.mode(:down)
      _game = play(game, ~w(Nf3))
      assert Outbox.drain() == :empty
      assert FakeIngest.game(1, 1).moves == ~w(e4 e5 Nf3)
      assert {{:retry, _, _}, 0} = LichessBroadcast.deliver()
      assert Outbox.pending_count() == 0 and LichessBroadcast.pending_count() == 1
    end

    test "each has its own status line; switching one off leaves the other sending" do
      start_supervised!(Outbox)
      Application.put_env(:alnasl, :lichess_coalesce_ms, 20)
      start_supervised!({Sender, destination: LichessBroadcast})

      FakeLichess.mode(:down)
      play(new_game(), ~w(e4))

      wait_until(fn -> Destination.status(OpenResults).state == :connected end)
      wait_until(fn -> Destination.status(LichessBroadcast).state == :offline end)

      assert %{id: "openresults", pending: 0, last_ok: %DateTime{}, last_error: nil} =
               Destination.status(OpenResults)

      assert %{
               id: "lichess",
               pending: 1,
               last_ok: nil,
               last_error: {:unreachable, :econnrefused},
               next_try_at: %DateTime{},
               enabled?: true
             } = Destination.status(LichessBroadcast)

      assert Outbox.status().state == :connected

      # "Send now" is per destination.
      FakeLichess.mode(:ok)
      Destination.send_now(LichessBroadcast)
      wait_until(fn -> Destination.status(LichessBroadcast).state == :connected end)
      assert FakeLichess.game(1).moves == ~w(e4)

      # Off: quiet, and what it would have sent stays counted.
      Destination.set_enabled(LichessBroadcast, false)
      play(Games.get(1, 1), ~w(e5))
      wait_until(fn -> Outbox.pending_count() == 0 end)

      assert %{state: :disabled, pending: 1, enabled?: false} =
               Destination.status(LichessBroadcast)

      assert FakeLichess.game(1).moves == ~w(e4)

      Destination.set_enabled(LichessBroadcast, true)
      wait_until(fn -> FakeLichess.game(1).moves == ~w(e4 e5) end)

      # And the results server can be switched off just the same.
      Destination.set_enabled(OpenResults, false)
      play(Games.get(1, 1), ~w(Nf3))
      wait_until(fn -> FakeLichess.game(1).moves == ~w(e4 e5 Nf3) end)
      assert Outbox.pending_count() == 1
      assert Outbox.status().state == :disabled
      Destination.set_enabled(OpenResults, true)
      wait_until(fn -> Outbox.pending_count() == 0 end)
    end

    test "Lichess is off until the arbiter switches it on, and says when it is not set up" do
      Settings.put("dest_lichess_enabled", nil)
      refute Destination.enabled?(LichessBroadcast)
      assert Destination.enabled?(OpenResults)
      assert Destination.status(LichessBroadcast).state == :disabled

      Destination.set_enabled(LichessBroadcast, true)
      Settings.put("lichess_round_id", "")
      assert Destination.status(LichessBroadcast).state == :unconfigured
      assert Enum.map(Destination.statuses(), & &1.id) == ["openresults", "lichess"]
    end
  end

  describe "the sender for Lichess" do
    test "a burst of moves on several boards becomes one push" do
      Application.put_env(:alnasl, :lichess_coalesce_ms, 250)
      start_supervised!({Sender, destination: LichessBroadcast})
      # The sender looks once when it starts; let that pass.
      wait_until(fn -> Sender.status(Destination.sender(LichessBroadcast)) != nil end)

      a = play(new_game(1), ~w(e4 e5 Nf3 Nc6))
      b = play(new_game(2), ~w(d4 d5 c4))
      wait_until(fn -> LichessBroadcast.pending_count() == 0 end)

      assert [{200, [first, second]}] = FakeLichess.pushes()
      assert first.moves == ~w(e4 e5 Nf3 Nc6) and second.moves == ~w(d4 d5 c4)

      # The next burst is the next push - one, not five.
      play(a, ~w(Bb5 a6 Ba4))
      play(b, ~w(e6 Nc3))
      wait_until(fn -> LichessBroadcast.pending_count() == 0 end)
      assert [_one, {200, [_, _]}] = FakeLichess.pushes()
      assert FakeLichess.game(1).moves == ~w(e4 e5 Nf3 Nc6 Bb5 a6 Ba4)
    end

    test "it backs off when told to slow down, and carries on by itself" do
      Application.put_env(:alnasl, :lichess_coalesce_ms, 10)
      FakeLichess.mode(:rate_limited)
      start_supervised!({Sender, destination: LichessBroadcast})
      play(new_game(), ~w(e4))

      wait_until(fn -> Destination.status(LichessBroadcast).state == :offline end)
      status = Destination.status(LichessBroadcast)
      assert status.last_error == :rate_limited
      # A minute, as Lichess asks: not the one second of an ordinary first retry.
      assert DateTime.diff(status.next_try_at, DateTime.utc_now()) > 50
      assert length(FakeLichess.pushes()) == 1

      FakeLichess.mode(:ok)
      Destination.send_now(LichessBroadcast)
      wait_until(fn -> LichessBroadcast.pending_count() == 0 end)
    end
  end

  describe "the API module" do
    test "reads a round id or a pasted link" do
      assert LichessApi.parse_round("AbCd1234") == {:ok, "AbCd1234"}
      assert LichessApi.parse_round("  AbCd1234 ") == {:ok, "AbCd1234"}

      assert LichessApi.parse_round("https://lichess.org/broadcast/test-open/round-1/AbCd1234") ==
               {:ok, "AbCd1234"}

      assert LichessApi.parse_round(
               "https://lichess.org/broadcast/test-open/round-1/AbCd1234/edit"
             ) ==
               {:ok, "AbCd1234"}

      assert LichessApi.parse_round("https://lichess.org/api/broadcast/round/AbCd1234/push") ==
               {:ok, "AbCd1234"}

      assert LichessApi.parse_round("https://lichess.org/broadcast/test-open") == :error
      assert LichessApi.parse_round("round 1") == :error
      assert LichessApi.parse_round("") == :error
    end

    test "builds the documented addresses" do
      assert LichessApi.push_url("https://lichess.org", "AbCd1234") ==
               "https://lichess.org/api/broadcast/round/AbCd1234/push"

      assert LichessApi.account_url("https://lichess.org") == "https://lichess.org/api/account"
      Settings.put("lichess_url", "")
      assert LichessApi.base() == "https://lichess.org"
    end

    test "the test asks who the token is, what it may do, and whether the round is there" do
      base = FakeLichess.base()

      assert [account: {:ok, "Arbiter"}, scope: {:ok, "study:write"}, round: {:ok, round}] =
               LichessApi.test(base, FakeLichess.round_id(), FakeLichess.token())

      assert round == %{round: "Round 1", tour: "Test Open"}

      assert [account: {:error, :token_refused}, scope: :skipped, round: {:ok, _}] =
               LichessApi.test(base, FakeLichess.round_id(), "lip_wrong")

      assert [account: {:error, :no_token}, scope: :skipped, round: {:error, :no_round}] =
               LichessApi.test(base, "", "")

      assert [account: {:ok, _}, scope: {:ok, _}, round: {:error, :round_not_found}] =
               LichessApi.test(base, "Zz999999", FakeLichess.token())

      FakeLichess.scopes("challenge:read")

      assert [account: {:ok, _}, scope: {:error, {:scope_missing, "challenge:read"}}, round: _] =
               LichessApi.test(base, FakeLichess.round_id(), FakeLichess.token())

      # An answer in a shape this code does not know is "could not check", not "wrong".
      FakeLichess.scopes(:garbled)

      assert [account: {:ok, _}, scope: :unknown, round: {:ok, _}] =
               LichessApi.test(base, FakeLichess.round_id(), FakeLichess.token())

      FakeLichess.mode(:down)

      assert [account: {:error, {:unreachable, :econnrefused}}, scope: :skipped, round: :skipped] =
               LichessApi.test(base, FakeLichess.round_id(), FakeLichess.token())

      # Nothing was pushed by any of it.
      assert FakeLichess.pushes() == []
    end

    test "the token is never shown again in full" do
      assert LichessBroadcast.token_hint() == "lip_...cdef"
      refute LichessBroadcast.token_hint() =~ "0123456789"
      Settings.put("lichess_token", "")
      assert LichessBroadcast.token_hint() == nil
    end
  end
end
