defmodule Alnasl.NoLocalBoardsTest do
  @moduledoc """
  `ALNASL_NO_LOCAL_BOARDS`: the hosted server, which has no hall plugged
  into it. No buses, no serial drivers, no simulators, no ports looked for;
  boards come from bridges only. Unset - every box in a hall - nothing
  changes.
  """

  use Alnasl.HallCase, async: false

  alias Alnasl.Loops

  defp hosted(on?) do
    Application.put_env(:alnasl, :local_boards, not on?)
    on_exit(fn -> Application.delete_env(:alnasl, :local_boards) end)
  end

  defp runtime_config(value) do
    if value, do: System.put_env("ALNASL_NO_LOCAL_BOARDS", value)

    try do
      Config.Reader.read!("config/runtime.exs", env: :test, target: :host)
    after
      System.delete_env("ALNASL_NO_LOCAL_BOARDS")
    end
  end

  test "the switch is read at start, and is off unless it is set" do
    assert runtime_config("true")[:alnasl][:local_boards] == false
    assert runtime_config("1")[:alnasl][:local_boards] == false
    assert runtime_config(nil)[:alnasl][:local_boards] == nil
    assert Boards.local?()
  end

  test "unset: the box runs its buses and reads what is plugged in, as it always has" do
    children = Alnasl.Application.children(autostart: true, local_boards: true)
    assert Arkab.Drivers in children
    assert Enum.any?(children, &match?({Alnasl.Updates.Checker, _opts}, &1))
    assert Process.whereis(Arkab.BusSupervisor)

    {:ok, sim} = Boards.create(%{name: "Sim", driver: "simulator", options: %{"game" => 1}})
    assert Boards.running?(sim.id)
  end

  test "set: no buses, no serial port, no simulator - and a board through a bridge runs as ever" do
    children = Alnasl.Application.children(autostart: true, local_boards: false)
    refute Arkab.Drivers in children
    # A server is updated by whoever deploys it: nobody asks GitHub.
    refute Enum.any?(children, &match?({Alnasl.Updates.Checker, _opts}, &1))
    assert AlnaslWeb.Endpoint in children
    assert Alnasl.Finder in children

    hosted(true)

    assert {:error, changeset} =
             Boards.create(%{name: "Sim", driver: "simulator", options: %{"game" => 1}})

    assert changeset.errors[:driver]
    assert Loops.add("FAKE-NO") == {:error, :no_local_boards}
    assert Loops.probe("FAKE-NO") == {:error, :no_local_boards}
    assert %{ports: [], serial?: false} = Boards.discover()

    # A row from the days the box had a hall of its own is not started.
    old = Repo.insert!(%Boards.Board{name: "Old", driver: "dgt_serial", port: "COM3"})
    assert Boards.start(old) == {:error, :no_local_boards}
    Boards.start_all()
    refute Boards.running?(old.id)

    {:ok, remote} =
      Boards.create(%{name: "Far away", driver: "remote", port: "bridge-1:COM3", options: %{}})

    assert Boards.running?(remote.id)
    assert Alnasl.Driver.Remote.whereis("bridge-1:COM3")
  end
end
