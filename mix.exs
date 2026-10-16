defmodule Alnasl.MixProject do
  use Mix.Project

  def project do
    [
      app: :alnasl,
      version: "0.1.6",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Alnasl.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # What is shipped: an ordinary Erlang release, the runtime inside, so there
  # is nothing to install first. It is a folder, not a single self-unpacking
  # executable, on purpose: an unsigned executable that unpacks a runtime and
  # starts processes is what antivirus takes for a dropper (measured next
  # door, on OpenPairings: deleted before it ran once), and a folder of DLLs
  # with a small launcher is not.
  #
  # The same release is the Windows installer's payload, the portable zip
  # and the Linux tarball; `release_extras/1` adds what each needs beside
  # `bin/`. See docs/releasing.md.
  defp releases do
    [
      alnasl: [
        applications: [alnasl: :permanent],
        steps: [:assemble, &__MODULE__.release_extras/1]
      ]
    ]
  end

  @doc false
  # The files that stand beside `bin/` in a release, per system. A step and
  # not an overlay: an overlay copies the same files everywhere (a .bat in a
  # Linux tarball), and the Windows launcher is built, not copied.
  def release_extras(release) do
    case :os.type() do
      {:win32, _} ->
        copy_extras(release, "rel/windows", ~w(Alnasl.bat))
        windows_launcher(release)
        velopack_dll(release)
        c_runtime(release)
        without_debug_files(release)

      # Nothing beside bin/ on a Mac: the release goes inside Alnasl.app,
      # whose launcher (rel/macos/launcher.sh) is put there by
      # rel/macos/build_app.sh, and systemd units mean nothing to macOS.
      {:unix, :darwin} ->
        :ok

      _unix ->
        copy_extras(
          release,
          "rel/linux",
          ~w(alnasl.sh install.sh update.sh uninstall.sh alnasl.service
             alnasl-update.service alnasl-update.path)
        )
    end

    File.write!(Path.join(release.path, "VERSION"), release.version <> "\n")
    release
  end

  defp copy_extras(release, dir, names) do
    for name <- names do
      target = Path.join(release.path, name)
      File.cp!(Path.join([__DIR__, dir, name]), target)
      if Path.extname(name) == ".sh", do: File.chmod!(target, 0o755)
    end
  end

  # Alnasl.exe, compiled from rel/windows/launcher.c with `zig cc`. Without
  # Zig the release is still whole and starts through Alnasl.bat; what will
  # not work is the installer, and rel/windows/build_installer.ps1 refuses a
  # payload without the launcher, as does the release workflow. So a missing
  # or failing Zig warns here and is fatal there.
  defp windows_launcher(release) do
    script = Path.join([__DIR__, "rel", "windows", "build_launcher.ps1"])
    output = Path.join(release.path, "Alnasl.exe")

    if System.find_executable("zig") do
      args =
        ~w(-NoProfile -ExecutionPolicy Bypass -File) ++
          [script, "-OutputPath", output, "-Version", release.version]

      case System.cmd("powershell", args, stderr_to_stdout: true) do
        {out, 0} ->
          Mix.shell().info(out)

        {out, status} ->
          Mix.shell().error(
            "Alnasl.exe was NOT built (build_launcher.ps1 exited #{status}). " <>
              "The release starts through Alnasl.bat; no installer can be packed from it.\n" <>
              out
          )
      end
    else
      Mix.shell().info([
        :yellow,
        "Skipping Alnasl.exe: zig is not on PATH. The release starts through ",
        "Alnasl.bat; no installer can be packed from it.",
        :reset
      ])
    end
  end

  # Velopack's own library, for the launcher's "download and install". Not
  # in the repository: the release workflow fetches a pinned, checksummed
  # copy to rel/windows/velopack_libc.dll. A build without it has no update
  # button and is otherwise the same program.
  defp velopack_dll(release) do
    source = Path.join([__DIR__, "rel", "windows", "velopack_libc.dll"])
    if File.exists?(source), do: File.cp!(source, Path.join(release.path, "velopack_libc.dll"))
  end

  # Erlang's Windows runtime is linked against Microsoft's C runtime, which
  # Erlang's own installer puts on the machine and a release does not: on a
  # PC that never had it, erl.exe stops with "VCRUNTIME140.dll was not
  # found". The three DLLs are Microsoft's to redistribute beside a program
  # that needs them (NOTICE), so they are copied from the build machine -
  # which has them, or it could not have built this - to stand beside
  # erl.exe. Where they are already there, nothing is copied.
  defp c_runtime(release) do
    system32 = Path.join(System.get_env("SystemRoot") || "C:/Windows", "System32")

    for bin <- Path.wildcard(Path.join(release.path, "erts-*/bin")),
        name <- ~w(vcruntime140.dll vcruntime140_1.dll msvcp140.dll),
        source = Path.join(system32, name),
        target = Path.join(bin, name),
        File.exists?(source) and not File.exists?(target) do
      File.cp!(source, target)
    end
  end

  # Erlang's Windows build ships its debugger symbols and a debug build of
  # the emulator: about a third of the download, for a debugger nobody will
  # attach in a playing hall.
  defp without_debug_files(release) do
    for pattern <- ["erts-*/bin/*.pdb", "erts-*/bin/beam.debug.*"],
        file <- Path.wildcard(Path.join(release.path, pattern)) do
      File.rm!(file)
    end
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.9"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:bandit, "~> 1.5"},
      {:req, "~> 0.5"},
      # The QR code of the box's address, for a phone to scan. Pure Elixir, MIT.
      {:eqrcode, "~> 0.2.1"}
    ] ++ uart()
  end

  # The serial port library is C code built with make. It builds on the Pi
  # and on Windows with mingw - but not from a path with a space in it, so
  # on Windows it is asked for (ALNASL_UART=1) rather than assumed. Without
  # it everything but the real serial port works; see README. The release
  # workflow asks for it on every system: a box that cannot open a serial
  # port is a simulator.
  defp uart do
    wanted =
      case System.get_env("ALNASL_UART") do
        "1" -> true
        "0" -> false
        _unset -> match?({:unix, _}, :os.type())
      end

    if wanted, do: [{:circuits_uart, "~> 1.5"}], else: []
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["esbuild.install --if-missing"],
      "assets.build": ["compile", "esbuild alnasl"],
      "assets.deploy": [
        "esbuild.install --if-missing",
        "esbuild alnasl --minify",
        "phx.digest"
      ],
      # No "deps.unlock --unused" here: on a machine that leaves the serial
      # library out (see uart/0) it would drop it from the lock file.
      precommit: ["compile --warnings-as-errors", "format", "test"]
    ]
  end
end
