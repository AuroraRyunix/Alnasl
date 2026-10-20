defmodule Alnasl.FairPlay.Engines do
  @moduledoc """
  The engines fair play will run, pinned: which file to fetch for
  which machine, what that file must hash to, and what `bench` must print
  once it is installed.

  Why pinned and not "whatever Stockfish is on the PATH": a screening score
  is only as good as its calibration, and a calibration belongs to exactly
  one engine build (`docs/plan-fair-play.md`, §2). A different version
  thinks differently, so its matches mean something else. The digest proves
  the archive is the one GitHub published; the bench signature proves the
  binary inside it is the build that was calibrated, and nothing a USB
  stick had lying around.

  Alnasl never ships the engine. The table holds URLs and digests only.

  ## Where the numbers come from

  - Digests: GitHub's own `digest` field of each release asset of `sf_19`
    (`gh api repos/official-stockfish/Stockfish/releases/tags/sf_19`),
    as copied into the plan, §3.
  - Bench: `Bench: 2497913` in the message of the release commit the
    `sf_19` tag points at (edb0d9db, "Stockfish 19"), and the same number
    from running `bench` on the Windows x86-64 universal binary on
    2026-10-20. Stockfish's bench is deterministic across platforms, which
    is the whole point of it.
  """

  @type platform ::
          :windows_x86_64 | :windows_arm64 | :macos | :linux_x86_64 | :linux_arm64

  @type asset :: %{name: String.t(), sha256: String.t(), format: :zip | :tar_gz}

  @type engine :: %{
          id: String.t(),
          name: String.t(),
          version: String.t(),
          tag: String.t(),
          bench: pos_integer(),
          assets: %{platform() => asset()}
        }

  @sf19_tag "sf_19"

  @sf19 %{
    id: "sf19",
    name: "Stockfish",
    version: "19",
    tag: @sf19_tag,
    bench: 2_497_913,
    assets: %{
      windows_x86_64: %{
        name: "stockfish-windows-x86-64-universal.zip",
        sha256: "3c8bf1f9ea66a09350a40df4f632288285ac206d99f33ab5842c408fc30b48a7",
        format: :zip
      },
      windows_arm64: %{
        name: "stockfish-windows-arm64-universal.zip",
        sha256: "8372ad3f0d7276deb2c70f801f541ec7db463219fc6d9c7592864e542aa4f401",
        format: :zip
      },
      macos: %{
        name: "stockfish-macos-universal.tar.gz",
        sha256: "a1f0e3bcc5a6927a11fe6fc8e54a779754645f3c2bae2cf13420fd1957adaa77",
        format: :tar_gz
      },
      linux_x86_64: %{
        name: "stockfish-linux-x86-64-universal.tar.gz",
        sha256: "9defc0d4e55d49c65a6d042f3e571a39fcea499ade6dbe741b53b8c65e03611f",
        format: :tar_gz
      },
      linux_arm64: %{
        name: "stockfish-linux-arm64-universal.tar.gz",
        sha256: "fe26cfd1d9db4c8af3d21e24d9ff34cacb31c1f940085a7583da11796f2bac01",
        format: :tar_gz
      }
    }
  }

  @engines %{"sf19" => @sf19}

  @doc "The engine fair play uses unless a hall says otherwise."
  @spec default() :: engine()
  def default, do: @sf19

  @doc "Every pinned engine, by id."
  @spec all() :: %{String.t() => engine()}
  def all, do: @engines

  @doc "One pinned engine by id (`\"sf19\"`)."
  @spec fetch(String.t()) :: {:ok, engine()} | :error
  def fetch(id), do: Map.fetch(@engines, id)

  @doc "The asset of `engine` for `platform`, or `:error` when it has none."
  @spec asset(engine(), platform()) :: {:ok, asset()} | :error
  def asset(engine, platform), do: Map.fetch(engine.assets, platform)

  @doc "Where GitHub serves an asset of a release."
  @spec url(engine(), asset()) :: String.t()
  def url(engine, asset) do
    "https://github.com/official-stockfish/Stockfish/releases/download/#{engine.tag}/#{asset.name}"
  end

  @doc """
  The platform this machine is, as the table spells it, or why there is no
  engine for it.

  `os` is `:os.type/0`; `arch` the processor: on Windows Erlang only ever
  says `win32`, so it is read from `PROCESSOR_ARCHITEW6432` (set when an
  x86 process runs under emulation) or `PROCESSOR_ARCHITECTURE`; elsewhere
  it is `:erlang.system_info(:system_architecture)`. Both are arguments so
  every answer can be asked for on any machine.
  """
  @spec platform(tuple(), String.t() | nil) ::
          {:ok, platform()} | {:error, {:unsupported_platform, String.t()}}
  def platform(os \\ :os.type(), arch \\ nil)

  def platform(os, nil), do: platform(os, detect_arch(os))

  def platform({:win32, _}, arch) do
    case String.upcase(arch) do
      a when a in ["AMD64", "X86_64", "EM64T"] -> {:ok, :windows_x86_64}
      "ARM64" -> {:ok, :windows_arm64}
      other -> unsupported("Windows on #{other}")
    end
  end

  # One universal build for both Intel and Apple silicon.
  def platform({:unix, :darwin}, arch) do
    if arch =~ ~r/^(x86_64|aarch64|arm64)/,
      do: {:ok, :macos},
      else: unsupported("macOS on #{arch}")
  end

  def platform({:unix, :linux}, arch) do
    cond do
      arch =~ ~r/^(x86_64|amd64)/ -> {:ok, :linux_x86_64}
      arch =~ ~r/^(aarch64|arm64)/ -> {:ok, :linux_arm64}
      true -> unsupported("Linux on #{arch}")
    end
  end

  def platform({family, name}, arch), do: unsupported("#{family}/#{name} on #{arch}")

  defp unsupported(what), do: {:error, {:unsupported_platform, what}}

  defp detect_arch({:win32, _}) do
    System.get_env("PROCESSOR_ARCHITEW6432") || System.get_env("PROCESSOR_ARCHITECTURE") ||
      "unknown"
  end

  defp detect_arch(_unix), do: to_string(:erlang.system_info(:system_architecture))

  # Stockfish 19's macOS build is compiled with -mmacosx-version-min=10.15
  # (src/Makefile at tag sf_19); Alnasl's Intel Mac build goes back to 10.13.
  @macos_minimum {10, 15}

  @doc "The macOS version, as text (`\"10.13.6\"`), or `nil` when this is not a Mac."
  def macos_version do
    with {:unix, :darwin} <- :os.type(),
         cmd when is_binary(cmd) <- System.find_executable("sw_vers"),
         {out, 0} <- System.cmd(cmd, ["-productVersion"]) do
      String.trim(out)
    else
      _no -> nil
    end
  end

  @doc """
  Why this Mac cannot run the engine, as a sentence, or `nil` when it can
  (or when the version is unknown, or this is no Mac). `version` is text
  like `"10.13.6"`.
  """
  @spec macos_problem(String.t() | nil) :: String.t() | nil
  def macos_problem(nil), do: nil

  def macos_problem(version) do
    parts = version |> String.split(".") |> Enum.map(&Integer.parse/1)

    case parts do
      [{major, _}, {minor, _} | _] when {major, minor} < @macos_minimum ->
        macos_message(version)

      _fine_or_unreadable ->
        nil
    end
  end

  @doc false
  def macos_message(version),
    do:
      "Fair play needs macOS 10.15 or newer; this Mac runs #{version}. " <>
        "Everything else in Alnasl works as before."

  @doc "A sentence for the owner who asked for an engine on a machine with none."
  @spec unsupported_message(String.t()) :: String.t()
  def unsupported_message(what) do
    "There is no official Stockfish 19 build for this machine (#{what}). " <>
      "Fair play runs on Windows (x86-64 or ARM64), macOS, and Linux (x86-64 or ARM64)."
  end
end
