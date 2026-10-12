defmodule Alnasl.Autostart do
  @moduledoc """
  "Start Alnasl when Windows starts": a switch on Setup, off unless the
  arbiter turns it on, and only there on an installed Windows copy.

  It is one value under the user's own `Run` key
  (`HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run`, name
  `Alnasl`), written with Windows' own `reg.exe`: no administrator, no
  service, nothing that outlives the user's say-so. The command is the
  launcher with `--background`, which starts the program and its window
  without opening a browser on a desktop nobody is looking at yet.

  The launcher removes the value when the program is uninstalled
  (`rel/windows/launcher.c`, the `--veloapp-uninstall` hook), so a removed
  program does not leave Windows starting something that is gone.

  A Linux box installed with `install.sh` starts with the machine anyway:
  that is what its systemd unit is for.
  """

  alias Alnasl.Updates

  @key ~S"HKCU\Software\Microsoft\Windows\CurrentVersion\Run"
  @value "Alnasl"

  @doc "Whether the switch means anything here."
  def supported?, do: match?({:win32, _}, :os.type()) and Updates.install_kind() == :velopack

  def enabled? do
    match?({_out, 0}, reg(["query", @key, "/v", @value]))
  end

  @doc "`:ok`, or `{:error, words_from_reg}`."
  def set(true) do
    case launcher() do
      nil -> {:error, "no launcher"}
      exe -> done(reg(["add", @key, "/v", @value, "/t", "REG_SZ", "/d", command(exe), "/f"]))
    end
  end

  def set(false) do
    if enabled?(), do: done(reg(["delete", @key, "/v", @value, "/f"])), else: :ok
  end

  @doc "The line Windows runs at sign-in."
  def command(exe), do: ~s("#{exe}" --background)

  # Velopack keeps a small Alnasl.exe in the install root that starts the
  # one in `current`; it is what the Start menu points at and what stays put
  # across updates. `current\Alnasl.exe` is the same program one step in.
  defp launcher do
    with root when is_binary(root) <- System.get_env("RELEASE_ROOT") do
      current = Path.expand(root)

      [Path.join(Path.dirname(current), "Alnasl.exe"), Path.join(current, "Alnasl.exe")]
      |> Enum.find(&File.exists?/1)
      |> case do
        nil -> nil
        path -> String.replace(path, "/", "\\")
      end
    end
  end

  defp done({_out, 0}), do: :ok
  defp done({out, _status}), do: {:error, String.trim(out)}

  defp reg(args) do
    run = Application.get_env(:alnasl, :autostart_cmd, &System.cmd/3)
    run.("reg", args, stderr_to_stdout: true)
  rescue
    error -> {Exception.message(error), 1}
  end
end
