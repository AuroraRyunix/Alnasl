defmodule Alnasl.FairPlay.Installer do
  @moduledoc """
  Puts a pinned engine (`Alnasl.FairPlay.Engines`) on this machine, and
  proves it is the one that was calibrated.

  Two ways in, one check:

    * `install(:download, opts)` fetches the release asset from GitHub;
    * `install({:file, path}, opts)` takes an archive somebody carried in on
      a USB stick, for a hall without internet.

  Either way the archive's SHA256 must be the digest in the table, the
  binary is taken out of it (and only the binary: the archive also carries
  the source and the wiki, which nobody here will read), made executable,
  and asked for its `bench`. A wrong number means a wrong build, and a wrong
  build means a calibration that does not apply - so it is refused rather
  than run "close enough".

  Everything that touches the outside world is injectable (`:downloader`,
  `:bench`), so the tests never reach GitHub and never need a real engine.

  Errors are `{:error, reason}`; `message/1` turns any of them into a
  sentence an owner can act on.
  """

  alias Alnasl.FairPlay.Engines

  @type reason ::
          {:unsupported_platform, String.t()}
          | {:macos_too_old, String.t()}
          | {:no_network, term()}
          | {:download_failed, term()}
          | {:not_found, String.t()}
          | {:checksum_mismatch, %{file: String.t(), expected: String.t(), actual: String.t()}}
          | {:wrong_platform, Engines.platform(), Engines.platform()}
          | {:bad_archive, term()}
          | {:no_binary, String.t()}
          | {:bench_failed, term()}
          | {:bench_mismatch, pos_integer(), integer()}

  @type installed :: %{
          path: String.t(),
          engine: String.t(),
          version: String.t(),
          bench: pos_integer()
        }

  @bench_timeout 300_000

  @doc """
  Installs the engine. `source` is `:download` or `{:file, path}`.

  Options:

    * `:engine` - an engine map (default `Engines.default/0`)
    * `:platform` - default: this machine (`Engines.platform/0`)
    * `:dir` - where the binary goes (default `default_dir/1`)
    * `:downloader` - `fn url, dest -> :ok | {:error, reason}`
    * `:bench` - `fn binary_path -> {:ok, nodes} | {:error, reason}`
  """
  @spec install(:download | {:file, String.t()}, keyword()) ::
          {:ok, installed()} | {:error, reason()}
  def install(source, opts \\ []) do
    engine = Keyword.get(opts, :engine, Engines.default())
    downloader = Keyword.get(opts, :downloader, &download/2)
    bench = Keyword.get(opts, :bench, &bench/1)

    with {:ok, platform} <- platform(opts),
         :ok <- check_macos(platform, opts),
         {:ok, asset} <- asset(engine, platform),
         dir = Keyword.get_lazy(opts, :dir, fn -> default_dir(engine) end),
         :ok <- File.mkdir_p(dir),
         {:ok, archive, temporary?} <- obtain(source, engine, asset, dir, downloader) do
      result =
        with :ok <- verify(archive, engine, asset, platform),
             {:ok, binary} <- unpack(archive, asset, dir),
             :ok <- executable(binary),
             {:ok, nodes} <- check_bench(binary, engine, bench) do
          {:ok, %{path: binary, engine: engine.id, version: engine.version, bench: nodes}}
        end

      if temporary?, do: File.rm(archive)
      result
    end
  end

  @doc "Where an engine is installed unless told otherwise: under the data directory."
  @spec default_dir(Engines.engine()) :: String.t()
  def default_dir(engine), do: Path.join([Alnasl.Paths.data(), "fair_play", "engines", engine.id])

  defp platform(opts) do
    case Keyword.fetch(opts, :platform) do
      {:ok, platform} -> {:ok, platform}
      :error -> Engines.platform()
    end
  end

  # Before anything is fetched: a Mac too old for the build.
  defp check_macos(:macos, opts) do
    version = Keyword.get(opts, :macos_version, &Engines.macos_version/0).()

    case Engines.macos_problem(version) do
      nil -> :ok
      _sentence -> {:error, {:macos_too_old, version}}
    end
  end

  defp check_macos(_platform, _opts), do: :ok

  defp asset(engine, platform) do
    case Engines.asset(engine, platform) do
      {:ok, asset} -> {:ok, asset}
      :error -> {:error, {:unsupported_platform, to_string(platform)}}
    end
  end

  # --- getting the archive -----------------------------------------------------

  defp obtain(:download, engine, asset, dir, downloader) do
    dest = Path.join(dir, asset.name <> ".part")
    File.rm(dest)

    case downloader.(Engines.url(engine, asset), dest) do
      :ok ->
        {:ok, dest, true}

      {:error, reason} ->
        File.rm(dest)
        {:error, reason}
    end
  end

  defp obtain({:file, path}, _engine, _asset, _dir, _downloader) do
    if File.regular?(path), do: {:ok, path, false}, else: {:error, {:not_found, path}}
  end

  @doc """
  The default downloader: `Req`, straight into `dest`. A failure to reach
  the host at all is `{:no_network, why}`; a host that answered with
  anything but the file is `{:download_failed, status}`.
  """
  @spec download(String.t(), String.t()) :: :ok | {:error, reason()}
  def download(url, dest) do
    case Req.get(url, into: File.stream!(dest), receive_timeout: 120_000, retry: :transient) do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:download_failed, status}}
      {:error, %{reason: reason}} -> {:error, {:no_network, reason}}
      {:error, other} -> {:error, {:no_network, other}}
    end
  end

  # --- checking it -------------------------------------------------------------

  @doc "The SHA256 of a file, lowercase hex, read in pieces: the archives are 80 MB."
  @spec sha256(String.t()) :: String.t()
  def sha256(path) do
    path
    |> File.stream!(1_048_576)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp verify(archive, engine, asset, platform) do
    actual = sha256(archive)

    cond do
      actual == asset.sha256 ->
        :ok

      # The right engine for another machine: say so, rather than "corrupt".
      other = Enum.find(engine.assets, fn {_p, a} -> a.sha256 == actual end) ->
        {:error, {:wrong_platform, elem(other, 0), platform}}

      true ->
        {:error,
         {:checksum_mismatch,
          %{file: Path.basename(archive), expected: asset.sha256, actual: actual}}}
    end
  end

  # --- unpacking ---------------------------------------------------------------

  defp unpack(archive, asset, dir) do
    with {:ok, entries} <- entries(archive, asset.format),
         {:ok, entry} <- pick_binary(entries, asset) do
      extract(archive, asset.format, entry, dir)
    end
  end

  defp entries(archive, :zip) do
    case :zip.list_dir(String.to_charlist(archive)) do
      {:ok, listing} ->
        {:ok, for({:zip_file, name, info, _, _, _} <- listing, do: {to_string(name), size(info)})}

      {:error, reason} ->
        {:error, {:bad_archive, reason}}
    end
  end

  defp entries(archive, :tar_gz) do
    case :erl_tar.table(String.to_charlist(archive), [:compressed, :verbose]) do
      {:ok, rows} ->
        {:ok,
         for(
           {name, :regular, size, _mtime, _mode, _uid, _gid} <- rows,
           do: {to_string(name), size}
         )}

      {:error, reason} ->
        {:error, {:bad_archive, reason}}
    end
  end

  defp size(info) when elem(info, 0) == :file_info, do: elem(info, 1)

  # The engine is the biggest file called stockfish-something, not inside
  # the source tree, and on Windows it ends in .exe. Names that climb out of
  # the folder are not considered, whatever they are called.
  defp pick_binary(entries, asset) do
    windows? = String.ends_with?(asset.name, ".zip")

    entries
    |> Enum.reject(fn {name, _} -> String.ends_with?(name, "/") or unsafe?(name) end)
    |> Enum.filter(fn {name, _} ->
      base = Path.basename(name)
      segments = Path.split(name)

      String.starts_with?(base, "stockfish") and "src" not in segments and
        if(windows?, do: String.ends_with?(base, ".exe"), else: Path.extname(base) == "")
    end)
    |> Enum.max_by(fn {_, size} -> size end, fn -> nil end)
    |> case do
      nil -> {:error, {:no_binary, asset.name}}
      {name, _size} -> {:ok, name}
    end
  end

  defp unsafe?(name) do
    String.starts_with?(name, "/") or String.contains?(name, ":") or
      ".." in String.split(name, ["/", "\\"])
  end

  defp extract(archive, format, entry, dir) do
    unpack_dir = Path.join(dir, "unpack-#{System.unique_integer([:positive])}")
    File.mkdir_p!(unpack_dir)

    result =
      case format do
        :zip ->
          :zip.extract(String.to_charlist(archive), [
            {:cwd, String.to_charlist(unpack_dir)},
            {:file_list, [String.to_charlist(entry)]}
          ])

        :tar_gz ->
          :erl_tar.extract(String.to_charlist(archive), [
            :compressed,
            {:cwd, String.to_charlist(unpack_dir)},
            {:files, [String.to_charlist(entry)]}
          ])
      end

    try do
      case result do
        error = {:error, _} ->
          {:error, {:bad_archive, error}}

        _ok ->
          target = Path.join(dir, Path.basename(entry))
          File.rm(target)

          case File.rename(Path.join(unpack_dir, entry), target) do
            :ok -> {:ok, target}
            {:error, reason} -> {:error, {:bad_archive, {:move, reason}}}
          end
      end
    after
      File.rm_rf(unpack_dir)
    end
  end

  defp executable(binary) do
    case :os.type() do
      {:win32, _} -> :ok
      _unix -> File.chmod(binary, 0o755)
    end
  end

  # --- bench -------------------------------------------------------------------

  defp check_bench(binary, engine, bench) do
    case bench.(binary) do
      {:ok, nodes} when nodes == engine.bench -> {:ok, nodes}
      {:ok, nodes} -> {:error, {:bench_mismatch, engine.bench, nodes}}
      {:error, reason} -> {:error, {:bench_failed, reason}}
    end
  end

  @doc """
  Runs `<binary> bench` and reads the node count. Stockfish prints it on
  stderr, hence the merge.
  """
  @spec bench(String.t()) :: {:ok, integer()} | {:error, term()}
  def bench(binary) do
    task = Task.async(fn -> System.cmd(binary, ["bench"], stderr_to_stdout: true) end)

    case Task.yield(task, @bench_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> parse_bench(output)
      {:ok, {_output, status}} -> {:error, {:exit_status, status}}
      {:exit, reason} -> {:error, reason}
      nil -> {:error, :timeout}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc "The `Nodes searched` number of a bench run's output."
  @spec parse_bench(String.t()) :: {:ok, integer()} | {:error, :no_bench_line}
  def parse_bench(output) do
    case Regex.run(~r/Nodes searched\s*:\s*(\d+)/, output) do
      [_, n] -> {:ok, String.to_integer(n)}
      nil -> {:error, :no_bench_line}
    end
  end

  # --- words -------------------------------------------------------------------

  @doc "What went wrong, for the owner."
  @spec message(reason()) :: String.t()
  def message({:unsupported_platform, what}), do: Engines.unsupported_message(what)

  def message({:macos_too_old, version}), do: Engines.macos_message(version)

  def message({:no_network, _why}),
    do:
      "The engine could not be downloaded: this machine cannot reach github.com. " <>
        "Download the file on another computer and choose it here instead."

  def message({:download_failed, status}),
    do:
      "GitHub did not hand over the engine (answer #{inspect(status)}). Try again later, or choose the file by hand."

  def message({:not_found, path}), do: "There is no file at #{path}."

  def message({:checksum_mismatch, %{file: file}}),
    do:
      "#{file} is not the official Stockfish 19 download for this machine (its checksum differs). " <>
        "It may be another version, a damaged copy or another program. Download it again from the official release."

  def message({:wrong_platform, is_for, wanted}),
    do:
      "This is the official Stockfish 19, but the build for #{label(is_for)}. " <>
        "This machine needs the one for #{label(wanted)}."

  def message({:bad_archive, _why}),
    do: "The file could not be unpacked. It may be damaged; download it again."

  def message({:no_binary, asset}),
    do:
      "#{asset} does not contain a Stockfish program. Choose the archive exactly as GitHub serves it."

  def message({:bench_failed, _why}),
    do:
      "The engine was unpacked but would not run its self-test. " <>
        "On a Mac this can mean the system is too old for this build; on Linux, a missing system library."

  def message({:bench_mismatch, expected, got}),
    do:
      "The engine runs, but its self-test gives #{got} instead of #{expected}: " <>
        "this is not the build the screening was calibrated for, so it is not used."

  def message(other), do: "The engine could not be installed (#{inspect(other)})."

  defp label(:windows_x86_64), do: "Windows (x86-64)"
  defp label(:windows_arm64), do: "Windows (ARM64)"
  defp label(:macos), do: "macOS"
  defp label(:linux_x86_64), do: "Linux (x86-64)"
  defp label(:linux_arm64), do: "Linux (ARM64)"
  defp label(other), do: to_string(other)
end
