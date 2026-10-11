defmodule Alnasl.HallCase do
  @moduledoc """
  For tests that run boards: a results server (`Alnasl.FakeIngest`) with a
  tournament of four boards, the box set up for it, quick tracker timings,
  and every board process stopped again afterwards.

  Boards live in processes that tick on timers, so these tests wait for
  things to become true (`eventually/2`) rather than assuming when.
  """

  use ExUnit.CaseTemplate

  alias Alnasl.{Boards, Chess, FakeIngest, Position, Settings, Tournament}
  alias Alnasl.Dgt.Emulator
  alias Alnasl.Transport.Fake

  using do
    quote do
      import Ecto.Query
      import Alnasl.HallCase
      alias Alnasl.Repo
      alias Alnasl.{Boards, FakeIngest, Games, Outbox, Position, Recorder, Settings}
    end
  end

  setup tags do
    Alnasl.DataCase.setup_sandbox(tags)
    start_supervised!(FakeIngest)
    FakeIngest.install()
    {:ok, _snapshot} = Tournament.refresh()

    # A tracker that makes up its mind quickly: these tests run in real time.
    Settings.put("tracker", %{
      "settle_ms" => 40,
      "deep_settle_ms" => 300,
      "castle_hold_ms" => 150,
      "promotion_hold_ms" => 200,
      "takeback_settle_ms" => 120,
      "transient_ms" => 400,
      "lifted_ms" => 1_500
    })

    Boards.subscribe()

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Alnasl.BoardSupervisor) do
        DynamicSupervisor.terminate_child(Alnasl.BoardSupervisor, pid)
      end

      for {_, pid, _, _} <- DynamicSupervisor.which_children(Alnasl.BusSupervisor) do
        DynamicSupervisor.terminate_child(Alnasl.BusSupervisor, pid)
      end

      Alnasl.Recorder.flush()
      Application.delete_env(:alnasl, :req_options)
    end)

    :ok
  end

  @doc "Waits until `fun` returns something truthy and returns it; fails after `timeout` ms."
  def eventually(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait(fun, deadline)
  end

  defp wait(fun, deadline) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) > deadline do
          ExUnit.Assertions.flunk("it did not happen in time")
        else
          receive do
            _any -> :ok
          after
            20 -> :ok
          end

          wait(fun, deadline)
        end

      value ->
        value
    end
  end

  @doc "A DGT board in software on port `port`, and the board row that reads it."
  def fake_dgt(port, attrs \\ %{}) do
    ExUnit.Callbacks.start_supervised!({Fake, port: port, device: {Emulator, Emulator.new()}}, id: port)

    {:ok, board} =
      Boards.create(Map.merge(%{name: "DGT " <> port, driver: "dgt_serial", port: port, options: %{"clock" => true}}, attrs))

    board
  end

  @doc "Puts the pieces of the emulated board as `board` (a 64-tuple)."
  def set_pieces(port, board), do: Fake.update(port, &Emulator.set_board(&1, board))

  @doc "The boards after each of `sans`, from the start position."
  def boards_after(sans, start \\ Chess.start_fen()) do
    {:ok, plies} = Chess.replay(start, sans)
    Enum.map(plies, &Position.from_fen(&1.fen))
  end

  @doc "Plays `sans` on the emulated board, one whole move at a time, waiting for each to be seen."
  def play_on(port, board_id, sans, already \\ []) do
    all = already ++ sans

    all
    |> boards_after()
    |> Enum.drop(length(already))
    |> Enum.with_index(length(already) + 1)
    |> Enum.each(fn {position, count} ->
      set_pieces(port, position)
      eventually(fn -> length(Boards.snapshot(board_id).plies) >= count end)
    end)

    all
  end

  def sans(board_id), do: Enum.map(Boards.snapshot(board_id).plies, & &1.san)
end
