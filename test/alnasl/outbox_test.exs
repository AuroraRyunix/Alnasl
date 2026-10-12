defmodule Alnasl.OutboxTest do
  @moduledoc """
  The outbox against a server that speaks the real contract
  (`Alnasl.FakeIngest`): order across outages, restarts mid-queue, server
  errors, duplicates and corrections. The claim under test is the one in the
  moduledoc of `Alnasl.Outbox`: nothing lost, nothing sent in a way the
  server would misread.
  """

  use Alnasl.DataCase, async: false

  alias Alnasl.{FakeIngest, Games, Outbox}
  alias Alnasl.Outbox.Entry

  @game ~w(e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6 O-O Be7)

  setup do
    start_supervised!(FakeIngest)
    FakeIngest.install()
    on_exit(fn -> Application.delete_env(:alnasl, :req_options) end)
    :ok
  end

  defp new_game(board \\ 1), do: Games.ensure(1, board, %{white: "White", black: "Black"})

  # Plays `sans` onto `game`, queueing an update after each move, as a board does.
  defp play(game, sans, clock \\ nil) do
    Enum.reduce(sans, game, fn san, game ->
      {game, _replace?} =
        Games.apply_event(game, {:moves, [%{san: san, flags: [], clock: nil}]}, 1_000)

      Outbox.enqueue(game, clock, false)
    end)
  end

  defp states, do: Repo.all(from e in Entry, order_by: e.id, select: {e.plies, e.state})
  defp accepted, do: for({200, body} <- FakeIngest.requests(), do: length(body["moves"]))

  test "every move reaches the server, in order, as the whole game so far" do
    play(new_game(), @game)
    assert Outbox.pending_count() == 10
    assert Outbox.drain() == :empty

    assert FakeIngest.game(1, 1).moves == @game
    assert accepted() == Enum.to_list(1..10)
    assert Outbox.pending_count() == 0

    for {{200, body}, n} <- Enum.with_index(FakeIngest.requests(), 1) do
      assert body["moves"] == Enum.take(@game, n)
      assert body["round"] == 1 and body["board"] == 1
      refute Map.has_key?(body, "replace")
    end
  end

  test "an entry is in the database before anything is sent, numbered per game" do
    FakeIngest.mode(:down)
    a = play(new_game(1), ~w(e4 e5))
    b = play(new_game(2), ~w(d4))
    assert a.seq == 2 and b.seq == 1
    assert FakeIngest.requests() == []

    rows =
      Repo.all(from e in Entry, order_by: e.id, select: {e.board_no, e.seq, e.plies, e.state})

    assert rows == [{1, 1, 1, "pending"}, {1, 2, 2, "pending"}, {2, 1, 1, "pending"}]
  end

  test "hours without a server lose nothing, and the queue drains in the order things happened" do
    game = play(new_game(), Enum.take(@game, 3))
    assert Outbox.drain() == :empty

    FakeIngest.mode(:down)
    game = play(game, Enum.slice(@game, 3, 4))
    other = play(new_game(2), ~w(d4 d5 c4))

    assert {:retry, {:unreachable, :econnrefused}, nil} = Outbox.drain()
    assert {:retry, _, _} = Outbox.drain()
    assert Outbox.pending_count() == 7
    assert FakeIngest.game(1, 1).moves == Enum.take(@game, 3)

    FakeIngest.mode(:ok)
    _game = play(game, Enum.slice(@game, 7, 3))
    assert Outbox.drain() == :empty

    assert FakeIngest.game(1, 1).moves == @game
    assert FakeIngest.game(1, 2).moves == other |> Games.sans()

    # The server heard each state of each game exactly once, oldest first.
    by_board =
      Enum.group_by(
        for({200, b} <- FakeIngest.requests(), do: b),
        & &1["board"],
        &length(&1["moves"])
      )

    assert by_board[1] == Enum.to_list(1..10)
    assert by_board[2] == [1, 2, 3]
  end

  test "a server that answers 500, 503 or 429 is asked again with the same message" do
    play(new_game(), ~w(e4 e5))

    FakeIngest.mode({:status, 500})
    assert {:retry, {:http, 500, nil}, nil} = Outbox.drain()

    FakeIngest.mode(:paused)
    assert {:retry, {:http, 503, "publishing_paused"}, nil} = Outbox.drain()

    FakeIngest.mode(:rate_limited)
    assert {:retry, :rate_limited, 1000} = Outbox.drain()

    assert states() == [{1, "pending"}, {2, "pending"}]
    assert Repo.one(from e in Entry, where: e.plies == 1, select: e.attempts) == 3

    FakeIngest.mode(:ok)
    assert Outbox.drain() == :empty
    assert FakeIngest.game(1, 1).moves == ~w(e4 e5)
  end

  test "a message delivered twice (the box died before it could note the answer) changes nothing" do
    game = play(new_game(), ~w(e4 e5 Nf3))
    assert Outbox.drain() == :empty

    # The crash: the last two rows look undelivered again.
    Repo.update_all(from(e in Entry, where: e.plies >= 2), set: [state: "pending", sent_at: nil])
    _game = play(game, ~w(Nc6))
    assert Outbox.drain() == :empty

    assert FakeIngest.game(1, 1).moves == ~w(e4 e5 Nf3 Nc6)
    assert Enum.all?(FakeIngest.requests(), fn {status, _} -> status == 200 end)
    assert Outbox.counts() == %{"sent" => 4}
  end

  test "a late message can never undo a newer one" do
    game = play(new_game(), ~w(e4 e5 Nf3))
    assert Outbox.drain() == :empty

    stale = Repo.one!(from e in Entry, where: e.plies == 1)
    Repo.update_all(from(e in Entry, where: e.id == ^stale.id), set: [state: "pending"])
    assert Outbox.drain() == :empty

    assert FakeIngest.game(1, 1).moves == ~w(e4 e5 Nf3)
    assert Repo.get!(Entry, stale.id).error == "older_than_stored"
    assert Games.sans(game) == ~w(e4 e5 Nf3)
  end

  test "a correction replaces the tail of the game on the server" do
    game = play(new_game(), ~w(e4 e5 Nf3 Nc6))
    assert Outbox.drain() == :empty

    # A takeback of the last move, then another move instead.
    {game, true} = Games.apply_event(game, {:correction, 3, [], :takeback}, 2_000)
    game = Outbox.enqueue(game, nil, true)
    assert Outbox.drain() == :empty
    assert FakeIngest.game(1, 1).moves == ~w(e4 e5 Nf3)

    {game, true} =
      Games.apply_event(
        game,
        {:correction, 2, [%{san: "Bc4", flags: [:arbiter]}], :arbiter},
        3_000
      )

    Outbox.enqueue(game, nil, true)
    assert Outbox.drain() == :empty
    assert FakeIngest.game(1, 1).moves == ~w(e4 e5 Bc4)

    {200, last} = List.last(FakeIngest.requests())
    assert last["replace"] == true
  end

  test "a correction queued behind an outage still lands after the moves it corrects" do
    FakeIngest.mode(:down)
    game = play(new_game(), ~w(e4 e5 Nf3))

    {game, true} =
      Games.apply_event(game, {:correction, 2, [%{san: "Bc4", flags: []}], :revised}, 2_000)

    game = Outbox.enqueue(game, nil, true)
    _game = play(game, ~w(Nc6))
    assert {:retry, _, _} = Outbox.drain()

    FakeIngest.mode(:ok)
    assert Outbox.drain() == :empty
    assert FakeIngest.game(1, 1).moves == ~w(e4 e5 Bc4 Nc6)
    assert Enum.all?(FakeIngest.requests(), fn {status, _} -> status == 200 end)
  end

  test "when the server holds other moves, the board wins: the game is sent again in full" do
    FakeIngest.plant(1, 1, ~w(d4 d5))
    play(new_game(), ~w(e4 e5))
    assert Outbox.drain() == :empty

    assert FakeIngest.game(1, 1).moves == ~w(e4 e5)
    # One move against the server's two is "older" and ignored; the second
    # move disagrees, and that is the conflict.
    assert [{200, _}, {409, _}, {200, %{"replace" => true}}] = FakeIngest.requests()
    assert Outbox.counts()["rejected"] >= 1
    assert {200, %{"replace" => true}} = List.last(FakeIngest.requests())
  end

  test "a message the server calls wrong is set aside and the queue moves on" do
    game = new_game()
    # Straight into the queue: a move the server will refuse.
    Repo.insert!(%Entry{
      game_id: game.id,
      round: 1,
      board_no: 1,
      seq: 1,
      plies: 1,
      body: Jason.encode!(%{round: 1, board: 1, moves: ["Ke4"]})
    })

    play(new_game(2), ~w(d4))

    assert Outbox.drain() == :empty

    assert [%Entry{state: "rejected", error: "invalid_moves", detail: detail}] =
             Outbox.list("rejected")

    assert detail =~ "ply 1"
    assert FakeIngest.game(1, 2).moves == ~w(d4)
  end

  test "a refused key holds the queue instead of throwing moves away" do
    own_put(relay_key: "orrk_wrong")
    play(new_game(), ~w(e4 e5))
    assert {:blocked, {401, "unauthorized"}} = Outbox.drain()
    assert Outbox.pending_count() == 2

    own_put(relay_key: FakeIngest.key())
    assert Outbox.drain() == :empty
    assert FakeIngest.game(1, 1).moves == ~w(e4 e5)
  end

  test "nothing is sent, and nothing lost, while the server is not set up" do
    own_put(server_url: "")
    play(new_game(), ~w(e4))
    assert Outbox.drain() == :unconfigured
    assert Outbox.pending_count() == 1
    assert Outbox.status().state == :unconfigured
  end

  test "clock refreshes that a newer one makes pointless are skipped; moves never are" do
    FakeIngest.mode(:down)
    game = play(new_game(), ~w(e4), %{white_ms: 60_000, black_ms: 60_000, running: :black})
    game = Outbox.enqueue(game, %{white_ms: 60_000, black_ms: 50_000, running: :black}, false)
    game = Outbox.enqueue(game, %{white_ms: 60_000, black_ms: 40_000, running: :black}, false)
    _game = play(game, ~w(e5), %{white_ms: 60_000, black_ms: 35_000, running: :white})

    FakeIngest.mode(:ok)
    assert Outbox.drain() == :empty
    assert states() == [{1, "superseded"}, {1, "superseded"}, {1, "sent"}, {2, "sent"}]

    assert FakeIngest.game(1, 1).clock == %{
             "white_ms" => 60_000,
             "black_ms" => 35_000,
             "running" => "white"
           }

    assert accepted() == [1, 2]
  end

  test "a result goes with the game, and a finished game is not skipped for a later refresh" do
    game = play(new_game(), ~w(f3 e5 g4 Qh4#))
    game = game |> Games.finish("0-1") |> Outbox.enqueue(nil, false)
    assert Outbox.drain() == :empty

    held = FakeIngest.game(1, 1)
    assert held.status == "finished" and held.result == "0-1"
    {200, last} = List.last(FakeIngest.requests())
    assert last["status"] == "finished" and last["result"] == "0-1" and last["running"] == nil
    assert Games.pgn(game) =~ "4. g4 Qh4# 0-1" or Games.pgn(game) =~ "Qh4# 0-1"
  end

  test "while sending is paused for a game nothing is queued for it" do
    game = new_game() |> Games.pause(true)
    game = play(game, ~w(e4 e5))
    assert Outbox.pending_count() == 0
    game |> Games.pause(false) |> Outbox.enqueue(nil, true)
    assert Outbox.drain() == :empty
    assert FakeIngest.game(1, 1).moves == ~w(e4 e5)
  end

  describe "the sender process" do
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
            50 -> wait_until(fun, left - 1)
          end
      end
    end

    test "sends by itself, says honestly how it stands, and picks up where a restart left it" do
      Outbox.subscribe()
      start_supervised!(Outbox)
      game = play(new_game(), ~w(e4 e5))
      wait_until(fn -> Outbox.pending_count() == 0 end)
      wait_until(fn -> Outbox.status().state == :connected end)
      assert %{pending: 0, last_error: nil, last_ok: %DateTime{}} = Outbox.status()

      FakeIngest.mode(:down)
      game = play(game, ~w(Nf3 Nc6))
      wait_until(fn -> Outbox.status().state == :offline end)
      status = Outbox.status()
      assert status.pending == 2
      assert status.last_error == {:unreachable, :econnrefused}
      assert %DateTime{} = status.next_try_at

      # The plug is pulled with moves in the queue.
      stop_supervised!(Outbox)
      _game = play(game, ~w(Bb5))
      assert Outbox.pending_count() == 3

      FakeIngest.mode(:ok)
      start_supervised!(Outbox)
      wait_until(fn -> Outbox.pending_count() == 0 end)
      assert FakeIngest.game(1, 1).moves == ~w(e4 e5 Nf3 Nc6 Bb5)
      assert accepted() == [1, 2, 3, 4, 5]
    end

    test "'send now' cuts a pause short" do
      Outbox.subscribe()
      FakeIngest.fail_next(1)
      start_supervised!(Outbox)
      play(new_game(), ~w(e4))
      wait_until(fn -> Outbox.status().state == :offline end)
      Outbox.send_now()
      wait_until(fn -> Outbox.pending_count() == 0 end)
      assert FakeIngest.game(1, 1).moves == ~w(e4)
    end
  end
end
