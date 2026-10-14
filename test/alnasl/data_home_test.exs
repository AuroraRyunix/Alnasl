defmodule Alnasl.DataHomeTest do
  @moduledoc """
  The rule that was paid for with somebody's tournaments: the data directory
  is never a folder an installer, an updater or an uninstaller owns, and no
  such folder contains it.

  Half of this is the rule itself. The other half reads the names out of the
  scripts that pack and install the program, because a rule kept in one file
  and broken in another is how it was broken the first time.
  """

  use ExUnit.Case, async: false

  alias Alnasl.DataHome

  @root Path.expand("../..", __DIR__)

  defp read(path), do: File.read!(Path.join(@root, path))

  defp env(map), do: &Map.get(map, &1)

  describe "where the data goes" do
    test "Windows: a folder of its own beside the program's, never inside it" do
      local = "C:\\Users\\arbiter\\AppData\\Local"
      data = DataHome.default({:win32, :nt}, env(%{"LOCALAPPDATA" => local}))

      assert data == Path.join(local, "AlnaslData")
      assert DataHome.refusal(data, local_app_data: local, release_root: nil) == nil
    end

    test "Windows without LOCALAPPDATA, and everything else: under the home directory" do
      assert DataHome.default({:win32, :nt}, env(%{"USERPROFILE" => "C:\\Users\\a"})) ==
               Path.join("C:\\Users\\a", ".alnasl")

      assert DataHome.default({:unix, :linux}, env(%{"HOME" => "/home/pi"})) == "/home/pi/.alnasl"
    end

    test "macOS: Application Support, in a folder of its own, never in the app" do
      data = DataHome.default({:unix, :darwin}, env(%{"HOME" => "/Users/arbiter"}))

      assert data == "/Users/arbiter/Library/Application Support/AlnaslData"
      assert DataHome.refusal(data, release_root: nil, local_app_data: nil) == nil

      # Even with the release inside an app in Applications, as it is there.
      assert DataHome.refusal(data,
               release_root: "/Applications/Alnasl.app/Contents/Resources/app",
               local_app_data: nil
             ) == nil
    end

    test "the three names are three names" do
      names = [DataHome.pack_id(), DataHome.pack_title(), DataHome.data_folder()]
      assert names == Enum.uniq(names)
      refute String.contains?(DataHome.data_folder(), DataHome.pack_id())
      refute DataHome.linux_data() |> String.starts_with?(DataHome.linux_install())
    end
  end

  describe "what is refused" do
    @local "C:\\Users\\arbiter\\AppData\\Local"

    test "the installer's folder, and anything in it, however it is spelled" do
      for path <- [
            @local <> "\\AlnaslApp",
            @local <> "\\AlnaslApp\\data",
            "c:/users/arbiter/appdata/local/alnaslapp/current/data",
            "D:\\Somewhere\\ALNASLAPP\\x"
          ] do
        assert DataHome.refusal(path, local_app_data: @local, release_root: nil) == :install_dir
      end
    end

    test "the folder named after the program's title" do
      assert DataHome.refusal(@local <> "\\Alnasl", local_app_data: @local, release_root: nil) ==
               :title_dir

      assert DataHome.refusal("c:/users/arbiter/appdata/local/alnasl/pgn",
               local_app_data: @local,
               release_root: nil
             ) == :title_dir
    end

    test "the Linux install tree" do
      assert DataHome.refusal("/opt/alnasl", release_root: nil) == :install_dir
      assert DataHome.refusal("/opt/alnasl/data", release_root: nil) == :install_dir
      assert DataHome.refusal("/opt/alnasl-data", release_root: nil) == nil
      assert DataHome.refusal(DataHome.linux_data(), release_root: nil) == nil
    end

    test "the running release itself - a portable copy's own folder" do
      root = "D:\\Tools\\alnasl-windows\\"

      assert DataHome.refusal("D:\\Tools\\alnasl-windows\\data",
               release_root: root,
               local_app_data: @local
             ) == :release_dir

      assert DataHome.refusal("D:\\Tools\\alnasl-data",
               release_root: root,
               local_app_data: @local
             ) ==
               nil
    end

    test "anything inside a Mac app, whichever app and however it is spelled" do
      for path <- [
            "/Applications/Alnasl.app",
            "/Applications/Alnasl.app/Contents/Resources/app/data",
            "/Users/arbiter/Downloads/ALNASL.APP/x",
            "/Applications/Some Other.app/data"
          ] do
        assert DataHome.refusal(path, release_root: nil, local_app_data: nil) == :app_bundle
      end

      for path <- ["/Users/arbiter/apps", "/Users/arbiter/Alnasl.application", "/srv/app"] do
        assert DataHome.refusal(path, release_root: nil, local_app_data: nil) == nil
      end

      assert DataHome.refusal_message("/Applications/Alnasl.app/d", :app_bundle) =~
               "inside an app"
    end

    test "a folder that only looks alike is not" do
      for path <- [@local <> "\\AlnaslData", @local <> "\\AlnaslAppData", "C:\\Alnasl"] do
        assert DataHome.refusal(path, local_app_data: @local, release_root: nil) == nil
      end
    end

    test "the refusal is a sentence that names the path" do
      path = @local <> "\\AlnaslApp\\data"
      assert DataHome.refusal_message(path, :install_dir) =~ path
      assert DataHome.refusal_message(path, :install_dir) =~ "ALNASL_DATA"
    end
  end

  describe "the program refuses to start on such a directory" do
    @tag :tmp_dir
    test "config/runtime.exs raises before it writes anything", %{tmp_dir: dir} do
      bad = Path.join([dir, "AlnaslApp", "data"])
      before = System.get_env("ALNASL_DATA")
      System.put_env("ALNASL_DATA", bad)

      try do
        assert_raise RuntimeError, ~r/will not keep its data/, fn ->
          Config.Reader.read!(Path.join(@root, "config/runtime.exs"), env: :prod)
        end

        refute File.exists?(bad)

        good = Path.join(dir, "data")
        System.put_env("ALNASL_DATA", good)
        config = Config.Reader.read!(Path.join(@root, "config/runtime.exs"), env: :prod)

        assert config[:alnasl][:data_dir] == good
        assert config[:alnasl][Alnasl.Repo][:database] == Path.join(good, "alnasl.db")
        # The secret is made once, kept with the data, and read back.
        secret = config[:alnasl][AlnaslWeb.Endpoint][:secret_key_base]
        assert File.read!(Path.join(good, "secret_key_base")) == secret

        again = Config.Reader.read!(Path.join(@root, "config/runtime.exs"), env: :prod)
        assert again[:alnasl][AlnaslWeb.Endpoint][:secret_key_base] == secret
      after
        if before,
          do: System.put_env("ALNASL_DATA", before),
          else: System.delete_env("ALNASL_DATA")
      end
    end

    @tag :tmp_dir
    test "an installed box answers only itself until it is told otherwise", %{tmp_dir: dir} do
      before = {System.get_env("ALNASL_DATA"), System.get_env("ALNASL_LISTEN")}
      System.put_env("ALNASL_DATA", dir)
      System.delete_env("ALNASL_LISTEN")
      runtime = Path.join(@root, "config/runtime.exs")

      ip = fn ->
        Config.Reader.read!(runtime, env: :prod)[:alnasl][AlnaslWeb.Endpoint][:http][:ip]
      end

      try do
        assert ip.() == {127, 0, 0, 1}

        # Setup's switch is a word in a file...
        File.write!(Path.join(dir, "listen"), "lan\n")
        assert ip.() == {0, 0, 0, 0}

        # ...and the environment, when it speaks, is the last word.
        System.put_env("ALNASL_LISTEN", "local")
        assert ip.() == {127, 0, 0, 1}
        File.rm!(Path.join(dir, "listen"))
        System.put_env("ALNASL_LISTEN", "lan")
        assert ip.() == {0, 0, 0, 0}
      after
        {data, listen} = before
        if data, do: System.put_env("ALNASL_DATA", data), else: System.delete_env("ALNASL_DATA")

        if listen,
          do: System.put_env("ALNASL_LISTEN", listen),
          else: System.delete_env("ALNASL_LISTEN")
      end
    end
  end

  describe "the scripts say the same" do
    test "the Windows installer packs under the id and title this module knows" do
      script = read("rel/windows/build_installer.ps1")

      assert [_, id] = Regex.run(~r/^\$packId\s*=\s*'([^']+)'/m, script)
      assert [_, title] = Regex.run(~r/^\$packTitle\s*=\s*'([^']+)'/m, script)
      assert id == DataHome.pack_id()
      assert title == DataHome.pack_title()

      # It names the data folder as one it must never pack over, and checks.
      assert [_, names] = Regex.run(~r/^\$dataFolderNames\s*=\s*@\(([^)]+)\)/m, script)
      assert names =~ "'#{DataHome.data_folder()}'"
      assert script =~ "Assert-DataDirectorySafe"
      # No .msi: its uninstall removes a folder named after the title.
      refute script =~ ~r/^\s*--msi\b/m
    end

    test "the launcher and the .bat put the data where this module does" do
      folder = DataHome.data_folder()
      assert read("rel/windows/launcher.c") =~ ~s(L"\\\\#{folder}")
      assert read("rel/windows/Alnasl.bat") =~ "%LOCALAPPDATA%\\#{folder}"
    end

    test "the Mac launcher puts the data where this module does, and no Mac script removes it" do
      launcher = read("rel/macos/launcher.sh")
      assert launcher =~ ~s(ALNASL_DATA=${ALNASL_DATA:-"$HOME/#{DataHome.macos_data()}"})
      # What the release writes at start goes outside the (read-only) bundle.
      assert launcher =~ ~s(export RELEASE_TMP="${TMPDIR:-/tmp}/Alnasl")
      assert launcher =~ ~s(cd "$ALNASL_DATA")

      for name <- ~w(launcher.sh build_app.sh sign_and_notarize.sh),
          line <- String.split(read("rel/macos/#{name}"), "\n"),
          line = String.trim(line),
          line =~ ~r/\brm\b/ and not String.starts_with?(line, "#") do
        refute line =~ "ALNASL_DATA", "rel/macos/#{name} removes the data: #{line}"
        refute line =~ "Application Support", "rel/macos/#{name} removes the data: #{line}"
      end
    end

    test "the Linux scripts keep program and data apart, and no script removes the data" do
      install = read("rel/linux/install.sh")
      update = read("rel/linux/update.sh")
      uninstall = read("rel/linux/uninstall.sh")
      unit = read("rel/linux/alnasl.service")

      for script <- [install, update, uninstall] do
        assert script =~ ~s(INSTALL_DIR="#{DataHome.linux_install()}")
      end

      assert install =~ ~s(DATA_DIR="#{DataHome.linux_data()}")
      assert unit =~ "Environment=ALNASL_DATA=#{DataHome.linux_data()}"
      assert unit =~ "ReadWritePaths=#{DataHome.linux_data()}"

      # Nothing that deletes names the data directory: not by its path, not
      # by the variable that holds it.
      data = Regex.escape(DataHome.linux_data())

      for script <- [install, update, uninstall],
          line <- String.split(script, "\n"),
          line = String.trim(line),
          line =~ ~r/\brm\b/ and not String.starts_with?(line, ["#", "echo ", "say "]) do
        # /var/lib/alnasl-update is the updater's own notebook, not the data.
        refute line =~ ~r/#{data}(?![\w-])/, "a script removes the data: #{line}"
        refute line =~ "DATA_DIR", "a script removes the data: #{line}"
      end

      # And the one that removes the program says, in so many words, that
      # the data stays.
      assert uninstall =~ "Your data is untouched"
    end
  end
end
