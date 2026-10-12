defmodule Alnasl.DataHome do
  @moduledoc """
  Where an installed box keeps what it must not lose, and the one rule about
  that place: nothing an installer, an updater or an uninstaller owns may be
  it, or contain it.

  The rule was paid for elsewhere. A sister program was once packed under an
  id that equalled its data folder, and uninstalling it removed every
  tournament on the machine: Velopack deletes `%LOCALAPPDATA%\\<pack id>`
  whole, not only the files it put there. So:

  | | program (replaced on update, removed on uninstall) | data (never touched by either) |
  |---|---|---|
  | Windows, installed | `%LOCALAPPDATA%\\AlnaslApp` | `%LOCALAPPDATA%\\AlnaslData` |
  | Windows, portable zip | wherever it was unzipped | `%LOCALAPPDATA%\\AlnaslData` |
  | Linux, installed | `/opt/alnasl` | `/var/lib/alnasl` (the unit says so) |
  | from source, `MIX_ENV=prod` | the checkout | `~/.alnasl` (Windows: as above) |

  `ALNASL_DATA` overrides the default everywhere, and is held to the same
  rule: `config/runtime.exs` refuses to start with a data directory that
  `refusal/2` names, and `rel/windows/build_installer.ps1` refuses to pack
  when the pack id or title is a data folder's name. The test
  (`test/alnasl/data_home_test.exs`) reads the names out of the scripts, so
  they cannot drift apart quietly.
  """

  # What Velopack is told this program is called. The pack id is the install
  # folder under %LOCALAPPDATA%; the title is what an .msi built from the
  # same pack would delete on uninstall (no .msi is built, and the name is
  # kept out of the data path anyway).
  @pack_id "AlnaslApp"
  @pack_title "Alnasl"
  @data_folder "AlnaslData"
  @linux_install "/opt/alnasl"
  @linux_data "/var/lib/alnasl"

  def pack_id, do: @pack_id
  def pack_title, do: @pack_title
  def data_folder, do: @data_folder
  def linux_install, do: @linux_install
  def linux_data, do: @linux_data

  @doc """
  The data directory when `ALNASL_DATA` does not name one. `os` and `env`
  are arguments so that the Windows answer can be asked for on Linux, and
  the other way round.
  """
  def default(os \\ :os.type(), env \\ &System.get_env/1)

  def default({:win32, _}, env) do
    case env.("LOCALAPPDATA") do
      dir when is_binary(dir) and dir != "" -> Path.join(dir, @data_folder)
      _unset -> Path.join(home(env), ".alnasl")
    end
  end

  def default(_unix, env), do: Path.join(home(env), ".alnasl")

  defp home(env), do: env.("HOME") || env.("USERPROFILE") || System.user_home!()

  @doc """
  Why `path` may not be the data directory, or `nil` when it may.

    * `:install_dir` - inside the folder the installer owns (a path segment
      that is the pack id, or `/opt/alnasl`)
    * `:title_dir` - `%LOCALAPPDATA%\\Alnasl`, the folder named after the
      pack title
    * `:release_dir` - inside the running release itself, which the next
      version replaces

  `opts`: `:release_root` (default `RELEASE_ROOT`), `:local_app_data`
  (default `LOCALAPPDATA`).
  """
  def refusal(path, opts \\ []) do
    release_root = Keyword.get(opts, :release_root, System.get_env("RELEASE_ROOT"))
    local = Keyword.get(opts, :local_app_data, System.get_env("LOCALAPPDATA"))
    segments = segments(path)

    cond do
      Enum.any?(segments, &(&1 == String.downcase(@pack_id))) -> :install_dir
      under?(segments, segments(@linux_install)) -> :install_dir
      local && under?(segments, segments(Path.join(local, @pack_title))) -> :title_dir
      release_root && under?(segments, segments(release_root)) -> :release_dir
      true -> nil
    end
  end

  @doc "The refusal as a sentence for whoever started the program."
  def refusal_message(path, reason) do
    why =
      case reason do
        :install_dir -> "it is inside the folder the installer owns and removes on uninstall"
        :title_dir -> "it is the folder an installer of this program may remove"
        :release_dir -> "it is inside the program's own folder, which the next version replaces"
      end

    "Alnasl will not keep its data in #{path}: #{why}. " <>
      "Leave ALNASL_DATA unset, or point it somewhere else."
  end

  # Compared without case and with either slash: Windows does not care, and
  # a rule that can be walked round by typing a capital is not a rule.
  defp segments(path) do
    path
    |> to_string()
    |> String.replace("\\", "/")
    |> String.downcase()
    |> String.split("/", trim: true)
  end

  defp under?(segments, parent), do: parent != [] and List.starts_with?(segments, parent)
end
