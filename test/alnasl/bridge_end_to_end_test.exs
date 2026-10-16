defmodule Alnasl.BridgeEndToEndTest do
  @moduledoc """
  A real Arkab bridge, in this VM, over a real WebSocket on a free local
  port, playing back a recorded game (never a serial port). The same game
  is read by the box's own replay driver beside it, and the two have to
  end the same: the same moves, the same result - whatever happens to the
  line, the bridge or this end in between. Nothing lost, nothing applied
  twice: the positions the board's process was given are the recording's,
  in order, with a repeat only where a board was sent again in full.
  """

  use Alnasl.HallCase, async: false

  # A link cut on purpose is logged as one. It is not news either.
  @moduletag :capture_log

  alias Alnasl.{Bridges, OtherServer}
  alias Arkab.Bridge.Store

  @game "test/fixtures/captures/opera-with-hands.jsonl"
  @speed 30

  setup do
    dir = Path.join(System.tmp_dir!(), "alnasl-bridge-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    listener = serve(0)
    on_exit(fn -> File.rm_rf(dir) end)

    %{dir: dir, listener: listener}
  end

  # This box's site on a port of its own: the endpoint itself, served by a
  # Bandit the test can take away and bring back on the same port.
  defp serve(port) do
    {:ok, pid} =
      Bandit.start_link(
        plug: AlnaslWeb.Endpoint,
        port: port,
        ip: :loopback,
        startup_log: false
      )

    Process.unlink(pid)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    listener = %{pid: pid, port: port}
    on_exit(fn -> stop_listener(listener) end)
    listener
  end

  defp stop_listener(%{pid: pid}) do
    if Process.alive?(pid), do: Supervisor.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defp start_bridge(dir) do
    start_supervised!(
      {Arkab.Bridge, data_dir: dir, name: "hall", sources: [], web: false},
      id: :bridge
    )
  end

  defp join(listener) do
    {:ok, code} = Bridges.create_join()
    {:ok, _server} = Arkab.Bridge.join("http://127.0.0.1:#{listener.port}/join/#{code.code}")
    [bridge] = Bridges.list()
    eventually(fn -> Bridges.live(bridge.id) end)
    bridge
  end

  # The same recording, read here (board 1) and through the bridge (board 2).
  defp play_both(bridge) do
    {:ok, remote} =
      Boards.create(%{
        name: "Through the bridge",
        driver: "remote",
        port: Bridges.port(bridge, "opera"),
        round: 1,
        board_no: 2
      })

    {:ok, local} =
      Boards.create(%{
        name: "Read here",
        driver: "replay",
        port: "replay-opera",
        round: 1,
        board_no: 1,
        options: %{"path" => @game, "speed" => @speed}
      })

    :ok = Arkab.Bridge.Ports.add(%{"replay" => @game, "name" => "opera", "speed" => @speed})
    {local, remote}
  end

  defp finished(local) do
    eventually(fn -> match?(%{finished?: true}, Boards.snapshot(local.id).player) end, 40_000)
    # The tail: what the last readings settle into.
    Process.sleep(1_000)
    game(local)
  end

  defp game(board) do
    snapshot = Boards.snapshot(board.id)
    %{sans: Enum.map(snapshot.plies, & &1.san), status: snapshot.status}
  end

  defp same_game(remote, expected) do
    eventually(fn -> game(remote) == expected end, 40_000)
    assert length(expected.sans) > 20
  end

  # What the board's process was given, as positions, against the recording.
  defp nothing_lost_nothing_twice(remote) do
    Recorder.flush()

    given =
      for file <- Recorder.list(),
          file.board_id == remote.id,
          {:ok, capture} = Recorder.read(file.path),
          {_t, {:position, board}} <- capture.events,
          do: board

    {:ok, source} = Arkab.Capture.read(@game)
    played = for {_t, {:position, board}} <- source.events, do: board
    assert Enum.dedup(given) == Enum.dedup(played)
  end

  defp all_taken(bridge) do
    eventually(fn -> Store.waiting() == 0 end, 40_000)
    assert Bridges.get(bridge.id).seen_seq == Store.last_seq()
  end

  test "the line cut mid-game and the bridge restarted: the game is the one read here",
       %{dir: dir, listener: listener} do
    start_bridge(dir)
    bridge = join(listener)
    {local, remote} = play_both(bridge)

    eventually(fn -> length(game(remote).sans) >= 6 end, 20_000)
    stop_listener(listener)
    expected = finished(local)

    # The rest of the game is in the bridge's queue, and the bridge goes
    # down and comes back with it.
    assert Store.waiting() > 0
    stop_supervised!(:bridge)
    start_bridge(dir)
    assert Store.waiting() > 0

    serve(listener.port)
    same_game(remote, expected)
    all_taken(bridge)
    nothing_lost_nothing_twice(remote)
  end

  test "this end restarted mid-game - the link and the board's own process: the game is the one read here",
       %{dir: dir, listener: listener} do
    start_bridge(dir)
    bridge = join(listener)
    {local, remote} = play_both(bridge)

    eventually(fn -> length(game(remote).sans) >= 8 end, 20_000)
    stop_listener(listener)
    pid = Alnasl.BoardServer.whereis(remote.id)
    Process.exit(pid, :kill)
    eventually(fn -> Alnasl.BoardServer.whereis(remote.id) not in [nil, pid] end)
    serve(listener.port)

    expected = finished(local)
    same_game(remote, expected)
    all_taken(bridge)
    nothing_lost_nothing_twice(remote)
  end

  test "two servers on one bridge, one of them down: this one gets the game, the other all of it later",
       %{dir: dir, listener: listener} do
    other = OtherServer.start()
    start_bridge(dir)
    bridge = join(listener)
    {:ok, _other_id} = Arkab.Bridge.join(OtherServer.link(other))
    OtherServer.down(other)

    {local, remote} = play_both(bridge)
    expected = finished(local)
    same_game(remote, expected)

    # Everything is here; the queue keeps it for the one that is away.
    eventually(fn -> Bridges.get(bridge.id).seen_seq == Store.last_seq() end)
    assert Store.waiting() > 0

    OtherServer.up(other)
    eventually(fn -> Store.waiting() == 0 end, 60_000)
    seqs = OtherServer.seqs(other)
    assert seqs == Enum.uniq(seqs)
    assert List.last(seqs) == Store.last_seq()
    nothing_lost_nothing_twice(remote)
  end
end
