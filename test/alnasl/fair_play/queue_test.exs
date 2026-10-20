defmodule Alnasl.FairPlay.QueueTest do
  use Alnasl.DataCase, async: false

  import Alnasl.FairPlayFixtures

  alias Alnasl.FairPlay
  alias Alnasl.FairPlay.{Live, Move, Queue}
  alias Alnasl.Games

  @moduletag :capture_log
  @fake Path.expand("../../support/fair_play/fake_uci.escript", __DIR__)

  describe "the line" do
    setup do
      test = self()

      job = fn id ->
        send(test, {:started, id, self()})

        receive do
          {:finish, ^id} -> :ok
        after
          5_000 -> :timeout
        end
      end

      start_supervised!({Task.Supervisor, name: Alnasl.FairPlay.TaskSupervisor})
      %{job: job}
    end

    test "runs at most `slots` jobs at once, the rest wait", %{job: job} do
      start_supervised!({Queue, slots: 2, job: job})

      for id <- 1..4, do: Queue.enqueue(id)

      assert_receive {:started, 1, one}
      assert_receive {:started, 2, two}
      refute_receive {:started, 3, _}, 50
      assert %{running: 2, waiting: 2} = Queue.info()

      send(one, {:finish, 1})
      assert_receive {:started, 3, three}
      send(two, {:finish, 2})
      assert_receive {:started, 4, four}
      send(three, {:finish, 3})
      send(four, {:finish, 4})
      assert :ok = Queue.drain()
    end

    test "a game already waiting is not queued twice; one running is queued once more after", %{
      job: job
    } do
      start_supervised!({Queue, slots: 1, job: job})

      Queue.enqueue(1)
      assert_receive {:started, 1, one}
      Queue.enqueue(2)
      Queue.enqueue(2)
      Queue.enqueue(1)
      Queue.enqueue(1)
      assert %{running: 1, waiting: 1} = Queue.info()

      send(one, {:finish, 1})
      assert_receive {:started, 2, two}
      send(two, {:finish, 2})
      assert_receive {:started, 1, again}
      send(again, {:finish, 1})
      refute_receive {:started, _, _}, 50
    end

    test "a full line drops the newcomer and says so, and carries on", %{job: job} do
      start_supervised!({Queue, slots: 1, max: 2, job: job})

      Queue.enqueue(1)
      assert_receive {:started, 1, one}
      for id <- 2..5, do: Queue.enqueue(id)

      assert %{waiting: 2, dropped: 2} = Queue.info()
      send(one, {:finish, 1})
      assert_receive {:started, 2, two}
      send(two, {:finish, 2})
      assert_receive {:started, 3, three}
      send(three, {:finish, 3})
      refute_receive {:started, _, _}, 50
    end

    test "a job that crashes does not stop the line" do
      test = self()

      start_supervised!(
        {Queue,
         slots: 1,
         job: fn
           1 -> raise "boom"
           id -> send(test, {:done, id})
         end}
      )

      Queue.enqueue(1)
      Queue.enqueue(2)
      assert_receive {:done, 2}
    end

    test "bulk work waits for the live games, whatever the order it came in", %{job: job} do
      start_supervised!({Queue, slots: 1, job: job})

      Queue.enqueue(1)
      assert_receive {:started, 1, one}
      Queue.enqueue({:upload_game, 7})
      Queue.enqueue({:game, 8})
      Queue.enqueue(2)
      assert %{waiting: 3, bulk: 2} = Queue.info()

      send(one, {:finish, 1})
      assert_receive {:started, 2, two}
      send(two, {:finish, 2})
      assert_receive {:started, {:upload_game, 7}, up}
      send(up, {:finish, {:upload_game, 7}})
      assert_receive {:started, {:game, 8}, eight}
      send(eight, {:finish, {:game, 8}})
      assert :ok = Queue.drain()
    end

    test "a board game is one piece of work in either lane", %{job: job} do
      start_supervised!({Queue, slots: 1, job: job})

      Queue.enqueue(1)
      assert_receive {:started, 1, one}
      Queue.enqueue({:game, 3})
      Queue.enqueue(3)
      Queue.enqueue({:game, 3})
      assert %{waiting: 1} = Queue.info()

      # Asked for on demand while it runs live: once more after, not twice now.
      Queue.enqueue({:game, 1})
      send(one, {:finish, 1})
      assert_receive {:started, 1, again}
      send(again, {:finish, 1})
      assert_receive {:started, {:game, 3}, three}
      send(three, {:finish, {:game, 3}})
      refute_receive {:started, _, _}, 50
    end

    test "a full bulk lane drops bulk work and leaves the live lane alone", %{job: job} do
      start_supervised!({Queue, slots: 1, bulk_max: 1, job: job})

      Queue.enqueue(1)
      assert_receive {:started, 1, one}
      Queue.enqueue({:upload_game, 1})
      Queue.enqueue({:upload_game, 2})
      Queue.enqueue(2)
      assert %{waiting: 2, bulk: 1, dropped: 1} = Queue.info()
      send(one, {:finish, 1})
      assert_receive {:started, 2, two}
      send(two, {:finish, 2})
      assert_receive {:started, {:upload_game, 1}, up}
      send(up, {:finish, {:upload_game, 1}})
    end

    test "telling a queue that is not running is a no-op" do
      assert Queue.enqueue(1, :nobody_home) == :ok
      assert FairPlay.game_changed(%{id: 1}) == :ok
    end
  end

  describe "with an engine" do
    setup do
      escript = System.find_executable("escript") || flunk("escript is not on the PATH")

      Application.put_env(:alnasl, :fair_play_launch, fn _path -> {escript, [@fake, "normal"]} end)

      on_exit(fn -> Application.delete_env(:alnasl, :fair_play_launch) end)

      tournament = rated_tournament()
      %{tournament: tournament}
    end

    test "a saved game is analysed in the background when the hall has it on", %{
      tournament: tournament
    } do
      start_supervised!({Live, slots: 1, limit: 1, timer: false})
      switch_on(Alnasl.Halls.own_id(), @fake)

      game = game(tournament, random_sans(24, 5))
      assert :ok = Queue.drain()

      rows = Repo.all(from m in Move, where: m.game_id == ^game.id)
      assert length(rows) == 24
      assert Enum.any?(rows, &(&1.engine_version == "19" and &1.best != nil))

      # The next move queues the game once more; only the new ply is asked.
      before = Enum.count(rows, &(&1.best != nil))
      more(Games.get!(game.id), Enum.take(random_sans(25, 5), -1))
      assert :ok = Queue.drain()
      assert Repo.aggregate(from(m in Move, where: m.game_id == ^game.id), :count) == 25

      assert Repo.aggregate(
               from(m in Move, where: m.game_id == ^game.id and not is_nil(m.best)),
               :count
             ) >= before
    end

    test "nothing is analysed while the hall has it off, whatever the games do", %{
      tournament: tournament
    } do
      start_supervised!({Live, slots: 1, limit: 1, timer: false})

      game(tournament, random_sans(24, 5))
      assert :ok = Queue.drain()

      assert Repo.aggregate(Move, :count) == 0
      assert %{started: 0} = Alnasl.FairPlay.Pool.info()
    end

    test "switched on without an engine file, nothing happens either", %{tournament: tournament} do
      start_supervised!({Live, slots: 1, limit: 1, timer: false})
      switch_on(Alnasl.Halls.own_id(), "/there/is/no/engine")

      game(tournament, random_sans(24, 5))
      assert :ok = Queue.drain()
      assert Repo.aggregate(Move, :count) == 0
    end
  end
end
