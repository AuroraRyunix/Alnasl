defmodule Alnasl.AutostartTest do
  @moduledoc """
  "Start Alnasl when Windows starts", against a stand-in for `reg.exe`: what
  is asked of Windows, and that nothing is asked where the switch means
  nothing. The registry of the machine the tests run on is not read and not
  written.
  """

  use ExUnit.Case, async: false

  alias Alnasl.Autostart
  alias Alnasl.FakeReg, as: Reg

  setup %{tmp_dir: dir} do
    start_supervised!(Reg)
    before = Application.get_env(:alnasl, :autostart_cmd)
    Application.put_env(:alnasl, :autostart_cmd, &Reg.cmd/3)

    # An installation as Velopack lays it out: the release in `current`,
    # its own small Alnasl.exe one folder up.
    current = Path.join(dir, "current")
    File.mkdir_p!(current)
    File.write!(Path.join(current, "Alnasl.exe"), "")
    File.write!(Path.join(dir, "Alnasl.exe"), "")
    root = System.get_env("RELEASE_ROOT")
    System.put_env("RELEASE_ROOT", current)

    on_exit(fn ->
      Application.put_env(:alnasl, :autostart_cmd, before)
      if root, do: System.put_env("RELEASE_ROOT", root), else: System.delete_env("RELEASE_ROOT")
    end)

    {:ok, dir: dir}
  end

  @tag :tmp_dir
  test "off until somebody turns it on" do
    refute Autostart.enabled?()
    assert Autostart.set(false) == :ok
    assert [["query" | _], ["query" | _]] = Reg.calls()
  end

  @tag :tmp_dir
  test "on is one value under the user's own Run key: the launcher, in the background", %{
    dir: dir
  } do
    assert Autostart.set(true) == :ok
    assert Autostart.enabled?()

    assert [
             [
               "add",
               "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run",
               "/v",
               "Alnasl",
               "/t",
               "REG_SZ",
               "/d",
               command,
               "/f"
             ]
             | _
           ] = Reg.calls()

    # The Alnasl.exe that stays put across updates, not the one in `current`.
    exe = dir |> Path.join("Alnasl.exe") |> String.replace("/", "\\")
    assert command == ~s("#{exe}" --background)
    assert command == Autostart.command(exe)
  end

  @tag :tmp_dir
  test "off again removes the value", %{} do
    Autostart.set(true)
    assert Autostart.set(false) == :ok
    refute Autostart.enabled?()
    assert Reg.value() == nil
  end

  @tag :tmp_dir
  test "a copy with no launcher to point at says so and asks Windows nothing", %{dir: dir} do
    File.rm!(Path.join(dir, "Alnasl.exe"))
    File.rm!(Path.join([dir, "current", "Alnasl.exe"]))

    assert {:error, _words} = Autostart.set(true)
    assert Reg.calls() == []
  end

  @tag :tmp_dir
  test "the switch is not offered to a copy that was not installed" do
    # config/test.exs: install_kind is :manual.
    refute Autostart.supported?()
  end
end
