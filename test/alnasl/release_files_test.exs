defmodule Alnasl.ReleaseFilesTest do
  @moduledoc """
  The files a release is made of and by, held to each other: the names the
  workflow publishes are the names the program, the scripts and the download
  page ask for; every action is pinned to a commit; the changelog has
  something to say about the version in `mix.exs`, or says it is unreleased.

  None of this runs a workflow. It catches the kind of mistake that is one
  renamed file in one of five places.
  """

  use ExUnit.Case, async: true

  alias Alnasl.Updates

  @root Path.expand("../..", __DIR__)

  defp read(path), do: File.read!(Path.join(@root, path))

  defp version, do: Mix.Project.config()[:version]

  describe "the workflows" do
    test "every action is pinned to a commit, with the version beside it" do
      for file <- ~w(.github/workflows/ci.yml .github/workflows/release.yml),
          [line] <- Regex.scan(~r/^.*\buses:.*$/m, read(file)) do
        assert line =~ ~r/uses: [\w.-]+\/[\w.\/-]+@[0-9a-f]{40} # v\d+\.\d+\.\d+$/,
               "#{file}: not pinned to a commit: #{String.trim(line)}"
      end
    end

    test "only the job that publishes may write" do
      workflow = read(".github/workflows/release.yml")
      assert length(Regex.scan(~r/contents: write/, workflow)) == 1
      assert workflow =~ ~r/^permissions:\n  contents: read$/m
      refute read(".github/workflows/ci.yml") =~ "contents: write"
    end

    test "the files it publishes are the files that are asked for by name" do
      workflow = read(".github/workflows/release.yml")
      brief = read("docs/download-page-brief.md")
      readme = read("README.md")

      # What the program computes the size of...
      assert Updates.asset_name(:velopack, "1.2.3") == "AlnaslApp-1.2.3-full.nupkg"
      assert workflow =~ "AlnaslApp-${VERSION}-full.nupkg"

      # ...what the Linux scripts download...
      for script <- ~w(rel/linux/install.sh rel/linux/update.sh) do
        assert read(script) =~ ~s(file="alnasl-linux-$cpu.tar.gz")
        assert read(script) =~ "SHA256SUMS"
      end

      # ...and every fixed name, in the workflow's own list of what a
      # release must hold, on the download page's brief and in the README.
      for name <- ~w(Alnasl-Setup.exe alnasl-windows-x86_64-portable.zip
                     alnasl-linux-x86_64.tar.gz alnasl-linux-aarch64.tar.gz install.sh
                     alnasl-macos-aarch64.zip) do
        assert workflow =~ name, "release.yml does not publish #{name}"
        assert brief =~ "releases/latest/download/#{name}", "the brief does not link #{name}"
      end

      assert readme =~ "releases/latest/download/Alnasl-Setup.exe"
      assert readme =~ "releases/latest/download/install.sh"
      assert readme =~ "releases/latest/download/alnasl-macos-aarch64.zip"
      assert workflow =~ "releases.win.json"
      assert workflow =~ "SHA256SUMS"
    end

    test "the Linux archives are built where a Raspberry Pi can run them" do
      workflow = read(".github/workflows/release.yml")
      assert workflow =~ "runner: ubuntu-22.04, target: linux-x86_64"
      assert workflow =~ "runner: ubuntu-22.04-arm, target: linux-aarch64"
    end

    test "the Mac app is built on the Macs whose names the release gives it" do
      workflow = read(".github/workflows/release.yml")
      assert workflow =~ "runner: macos-15, target: macos-aarch64"
      refute workflow =~ "macos-15-intel"
      assert workflow =~ ~s(dist/alnasl-${{ matrix.target }}.zip)
      # Signing is there, and cannot run without its secret.
      assert workflow =~ "if: runner.os == 'macOS' && steps.apple.outputs.sign == 'true'"
      # ...and install.sh refuses, in words, a system older than that.
      assert read("rel/linux/install.sh") =~ ~s([ "$minor" -lt 35 ])
    end
  end

  describe "the Mac runtime" do
    test "is built for macOS 11, and a build that is not fails" do
      workflow = read(".github/workflows/release.yml")
      build_otp = read("rel/macos/build_otp.sh")
      build_app = read("rel/macos/build_app.sh")

      # The ready-made Erlang for macOS said "15.0"; it is not used there.
      assert workflow =~ "if: runner.os != 'macOS'"
      assert workflow =~ ~s(sh rel/macos/build_otp.sh "$HOME/otp-macos")
      assert workflow =~ ~s(echo "MACOSX_DEPLOYMENT_TARGET=11.0" >> "$GITHUB_ENV")
      assert workflow =~ "steps.otp-cache.outputs.cache-hit != 'true'"

      assert [_, otp_key] = Regex.run(~r/path: ~\/otp-macos\n\s+key: (.+)$/m, workflow)

      for part <- ~w(env.OTP_VERSION env.OPENSSL_VERSION env.ELIXIR_VERSION
                     env.MACOSX_DEPLOYMENT_TARGET matrix.runner rel/macos/build_otp.sh) do
        assert otp_key =~ part, "the OTP cache key does not include #{part}"
      end

      # OpenSSL inside crypto, and nothing the arbiter's Mac lacks.
      assert build_otp =~ "--disable-dynamic-ssl-lib"
      assert build_otp =~ "no-shared"
      assert build_otp =~ "--without-wx --without-javac --without-odbc"

      # Every version the workflow names has a checksum in the script.
      for var <- ~w(OTP_VERSION OPENSSL_VERSION ELIXIR_VERSION) do
        assert [_, version] = Regex.run(~r/^\s+#{var}: "([^"]+)"$/m, workflow)

        assert build_otp =~
                 ~r/^\s+#{Regex.escape(version)}(-otp-\d+)?\) \w+_sha256=[0-9a-f]{64} ;;$/m,
               "build_otp.sh has no checksum for #{var} #{version}"
      end

      # The SQLite NIF from source on the Mac, and never from a cache built
      # for another macOS.
      assert workflow =~ ~s(echo "EXQLITE_FORCE_BUILD=true" >> "$GITHUB_ENV")
      assert read("config/config.exs") =~ "config :exqlite, force_build: true"
      assert Regex.match?(~r/_build\/prod\/lib\n\s+key:.*env\.MACOSX_DEPLOYMENT_TARGET/, workflow)

      # A binary that wants newer than macOS 11 fails the build, by name.
      assert build_app =~ "supported=11.0"
      assert build_app =~ ~s(newer "$minos" "$supported")
      assert build_app =~ ~s(sed 's/^/  /' "$too_new")
    end
  end

  describe "the changelog" do
    test "has a section for this version, or says it is unreleased" do
      changelog = read("CHANGELOG.md")

      assert changelog =~ "\n## [#{version()}]" or changelog =~ "\n## [Unreleased]",
             "CHANGELOG.md says nothing about #{version()}"
    end

    @tag :tmp_dir
    test "release_notes.sh prints one version's section and nothing else", %{tmp_dir: dir} do
      if sh = System.find_executable("sh") do
        file = Path.join(dir, "CHANGELOG.md")

        File.write!(file, """
        # Changelog

        A version is released when it has a section (`## [0.2.0]`).

        ## [Unreleased]

        - [Feature] not yet

        ## [0.2.0] - 2026-11-03

        - [Feature] **The second.** With a `## [` in the middle of a line.
        - [Fix] And a fix.

        ## [0.1.0] - 2026-10-20

        - [Feature] The first.

        ## [0.1.5]
        """)

        script = Path.join(@root, "tools/release_notes.sh")

        assert {notes, 0} = System.cmd(sh, [script, "0.2.0", file])
        assert notes =~ "**The second.**"
        assert notes =~ "And a fix."
        refute notes =~ "The first."
        refute notes =~ "not yet"
        refute notes =~ "\n## ["
        assert String.starts_with?(notes, "- [Feature]")

        assert {first, 0} = System.cmd(sh, [script, "0.1.0", file])
        assert String.trim(first) == "- [Feature] The first."

        # No section, an empty section, and a version that only looks like
        # one that is there: nothing printed, and a failure.
        for missing <- ["0.3.0", "0.1.5", "0.2", "0.2.00"] do
          assert {"", 1} = System.cmd(sh, [script, missing, file])
        end
      end
    end
  end

  describe "the release" do
    test "is one release, with the files each system needs beside bin/" do
      release = Mix.Project.config()[:releases][:alnasl]
      assert release[:applications] == [alnasl: :permanent]

      for name <- ~w(alnasl.sh install.sh update.sh uninstall.sh alnasl.service
                     alnasl-update.service alnasl-update.path) do
        assert File.exists?(Path.join([@root, "rel/linux", name])), "rel/linux/#{name} is missing"
      end

      for name <- ~w(Alnasl.bat launcher.c launcher.rc launcher.manifest Alnasl.ico
                     build_launcher.ps1 build_installer.ps1) do
        assert File.exists?(Path.join([@root, "rel/windows", name])),
               "rel/windows/#{name} is missing"
      end

      for name <- ~w(Launcher.swift launcher.sh build_app.sh sign_and_notarize.sh Info.plist
                     entitlements.plist Alnasl-icon.png) do
        assert File.exists?(Path.join([@root, "rel/macos", name])), "rel/macos/#{name} is missing"
      end

      # The plist takes its version from the release, never from a literal.
      plist = read("rel/macos/Info.plist")
      assert plist =~ "<string>__VERSION__</string>"
      refute plist =~ ~r{<key>CFBundleShortVersionString</key>\s*<string>\d}

      # The executable is the compiled Swift launcher; the script that
      # starts the server sits beside the release as a resource.
      build = read("rel/macos/build_app.sh")
      assert plist =~ ~r{<key>CFBundleExecutable</key>\s*<string>Alnasl</string>}
      assert build =~ ~s(-o "$app/Contents/MacOS/Alnasl" "$swift_source")
      assert build =~ "-target arm64-apple-macos11"
      assert build =~ ~s(cp "$here/launcher.sh" "$app/Contents/Resources/launcher.sh")
      assert build =~ "logo=rel/macos/Alnasl-icon.png"
    end

    test "the Mac app has a Dock icon, and a launcher that asks before it stops" do
      # LSUIElement hides the app from the Dock and Cmd-Tab.
      refute read("rel/macos/Info.plist") =~ "LSUIElement"

      swift = read("rel/macos/Launcher.swift")
      assert swift =~ ~s(let defaultDataFolder = "Library/Application Support/AlnaslData")
      assert swift =~ ~s(let dataEnv = "ALNASL_DATA")
      assert swift =~ ~s(let releaseInResources = "app/bin/alnasl")
      assert swift =~ ~s(let probePath = "/help")
      assert swift =~ "let askBeforeStopping = true"
      assert swift =~ ~s[appendingPathComponent("launcher.sh")]
      assert swift =~ ~s[contains("--headless")]
      assert read(".github/workflows/release.yml") =~ ~s("$launcher" --headless)

      imports = Regex.scan(~r/^import (\w+)$/m, swift, capture: :all_but_first)
      assert Enum.sort(List.flatten(imports)) == ["AppKit", "Foundation"]
    end

    test "the Mac icon has Apple's margin around the tile" do
      png = File.read!(Path.join(@root, "rel/macos/Alnasl-icon.png"))
      assert <<0x89, "PNG", _::binary-size(12), width::32, height::32, _::binary>> = png
      assert {width, height} == {1024, 1024}
    end

    test "the launcher and the program agree on the code that means \"update me\"" do
      assert read("rel/windows/launcher.c") =~
               "#define ALNASL_UPDATE_EXIT_CODE #{Updates.update_exit_code()}\n"
    end

    test "the unit runs the program as its own user, read-only but for the data" do
      unit = read("rel/linux/alnasl.service")

      for line <- [
            "User=alnasl",
            "SupplementaryGroups=dialout",
            "NoNewPrivileges=yes",
            "ProtectSystem=strict",
            "Restart=on-failure",
            "Environment=RELEASE_DISTRIBUTION=none",
            "Environment=ALNASL_UPDATER=systemd",
            "ExecStart=/opt/alnasl/current/bin/alnasl start"
          ] do
        assert unit =~ ~r/^#{Regex.escape(line)}$/m, "alnasl.service lacks: #{line}"
      end

      # The boards are devices.
      refute unit =~ ~r/^PrivateDevices=/m
      refute unit =~ ~r/^User=root$/m
    end

    test "the shell scripts have Unix line endings, and the batch files Windows'" do
      for file <-
            Path.wildcard(Path.join(@root, "rel/linux/*")) ++
              Path.wildcard(Path.join(@root, "rel/macos/*.sh")) ++
              [Path.join(@root, "tools/release_notes.sh"), Path.join(@root, "rel/env.sh.eex")] do
        refute File.read!(file) =~ "\r", "#{file} has CRLF line endings"
      end
    end
  end
end
