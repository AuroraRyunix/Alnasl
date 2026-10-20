defmodule Alnasl.FairPlay.InstallerTest do
  use ExUnit.Case, async: true

  alias Alnasl.FairPlay.{Engines, Installer}

  @moduletag :tmp_dir

  @binary_contents "not really an engine, but the right size of lie"

  # A Windows zip laid out as the real one is: a folder, the licence, the
  # source tree (with a file that could pass for the engine by name), and
  # the program.
  defp zip(dir, entries \\ nil) do
    entries =
      entries ||
        [
          {~c"stockfish/Copying.txt", "GPL"},
          {~c"stockfish/src/stockfish.exe", "a decoy in the source tree"},
          {~c"stockfish/stockfish-windows-x86-64-universal.exe", @binary_contents}
        ]

    path = Path.join(dir, "stockfish-windows-x86-64-universal.zip")
    {:ok, _} = :zip.create(String.to_charlist(path), entries)
    path
  end

  defp tar_gz(dir) do
    src = Path.join(dir, "tar-src")
    File.mkdir_p!(Path.join([src, "stockfish", "src"]))

    File.write!(
      Path.join([src, "stockfish", "stockfish-linux-x86-64-universal"]),
      @binary_contents
    )

    File.write!(Path.join([src, "stockfish", "src", "uci.cpp"]), "// source")
    File.write!(Path.join([src, "stockfish", "README.md"]), "readme")

    path = Path.join(dir, "stockfish-linux-x86-64-universal.tar.gz")

    :ok =
      :erl_tar.create(
        String.to_charlist(path),
        [
          {~c"stockfish/stockfish-linux-x86-64-universal",
           String.to_charlist(Path.join([src, "stockfish", "stockfish-linux-x86-64-universal"]))},
          {~c"stockfish/src/uci.cpp",
           String.to_charlist(Path.join([src, "stockfish", "src", "uci.cpp"]))},
          {~c"stockfish/README.md",
           String.to_charlist(Path.join([src, "stockfish", "README.md"]))}
        ],
        [:compressed]
      )

    path
  end

  # The real table with the fake archives' digests put in, so every path
  # through the installer runs against the real asset names.
  defp engine_for(archives) do
    sf = Engines.default()

    assets =
      Enum.reduce(archives, sf.assets, fn {platform, path}, assets ->
        Map.update!(assets, platform, &%{&1 | sha256: Installer.sha256(path)})
      end)

    %{sf | assets: assets}
  end

  defp good_bench(engine), do: fn _path -> {:ok, engine.bench} end

  test "a Mac older than 10.15 is refused before anything is fetched", %{tmp_dir: tmp} do
    test = self()

    opts = [
      platform: :macos,
      dir: Path.join(tmp, "engines"),
      macos_version: fn -> "10.13.6" end,
      downloader: fn _url, _dest -> send(test, :downloaded) end
    ]

    assert {:error, {:macos_too_old, "10.13.6"}} = Installer.install(:download, opts)
    assert {:error, {:macos_too_old, _}} = Installer.install({:file, "x.tar.gz"}, opts)
    refute_received :downloaded
    refute File.exists?(Path.join(tmp, "engines"))

    assert Installer.message({:macos_too_old, "10.13.6"}) ==
             "Fair-play screening needs macOS 10.15 or newer; this Mac runs 10.13.6. Everything else in Alnasl works as before."
  end

  test "macOS 10.15 and later, and an unknown version, are not refused", %{tmp_dir: tmp} do
    for version <- ["10.15", "10.15.7", "11.0", "14.5", "26.0", nil, "garbage"] do
      assert Engines.macos_problem(version) == nil, inspect(version)
    end

    for version <- ["10.13", "10.14.6", "10.9.5"] do
      assert Engines.macos_problem(version) =~ "macOS 10.15 or newer"
    end

    opts = [platform: :macos, dir: tmp, macos_version: fn -> "10.15.7" end]
    assert {:error, {:not_found, _}} = Installer.install({:file, "/nope.tar.gz"}, opts)
  end

  test "installs from a chosen zip: checksum, the binary and nothing else, bench", %{tmp_dir: tmp} do
    archive = zip(tmp)
    engine = engine_for(windows_x86_64: archive)
    dir = Path.join(tmp, "engines")

    assert {:ok, installed} =
             Installer.install({:file, archive},
               engine: engine,
               platform: :windows_x86_64,
               dir: dir,
               bench: good_bench(engine)
             )

    assert installed == %{
             path: Path.join(dir, "stockfish-windows-x86-64-universal.exe"),
             engine: "sf19",
             version: "19",
             bench: 2_497_913
           }

    assert File.read!(installed.path) == @binary_contents
    # Only the program is unpacked, and the owner's own file is left alone.
    assert File.ls!(dir) == ["stockfish-windows-x86-64-universal.exe"]
    assert File.exists?(archive)
  end

  test "installs from a tar.gz", %{tmp_dir: tmp} do
    archive = tar_gz(tmp)
    engine = engine_for(linux_x86_64: archive)
    dir = Path.join(tmp, "engines")

    assert {:ok, %{path: path}} =
             Installer.install({:file, archive},
               engine: engine,
               platform: :linux_x86_64,
               dir: dir,
               bench: good_bench(engine)
             )

    assert Path.basename(path) == "stockfish-linux-x86-64-universal"
    assert File.read!(path) == @binary_contents

    if match?({:unix, _}, :os.type()) do
      assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
      assert Bitwise.band(mode, 0o111) != 0
    end
  end

  test "downloads through the injected downloader, from the pinned URL", %{tmp_dir: tmp} do
    archive = zip(tmp)
    engine = engine_for(windows_x86_64: archive)
    dir = Path.join(tmp, "engines")
    me = self()

    downloader = fn url, dest ->
      send(me, {:fetched, url})
      File.cp!(archive, dest)
    end

    assert {:ok, %{bench: 2_497_913}} =
             Installer.install(:download,
               engine: engine,
               platform: :windows_x86_64,
               dir: dir,
               downloader: downloader,
               bench: good_bench(engine)
             )

    assert_received {:fetched,
                     "https://github.com/official-stockfish/Stockfish/releases/download/sf_19/stockfish-windows-x86-64-universal.zip"}

    # The downloaded archive does not stay behind: 80 MB nobody needs.
    assert File.ls!(dir) == ["stockfish-windows-x86-64-universal.exe"]
  end

  test "a checksum mismatch is refused before anything is unpacked", %{tmp_dir: tmp} do
    archive = zip(tmp)
    dir = Path.join(tmp, "engines")

    assert {:error, {:checksum_mismatch, mismatch} = why} =
             Installer.install({:file, archive},
               engine: Engines.default(),
               platform: :windows_x86_64,
               dir: dir,
               bench: fn _ -> flunk("bench must not run") end
             )

    assert mismatch == %{
             file: "stockfish-windows-x86-64-universal.zip",
             expected: "3c8bf1f9ea66a09350a40df4f632288285ac206d99f33ab5842c408fc30b48a7",
             actual: Installer.sha256(archive)
           }

    assert File.ls!(dir) == []
    assert Installer.message(why) =~ "not the official Stockfish 19 download"
  end

  test "the right engine for another machine says which machine", %{tmp_dir: tmp} do
    archive = zip(tmp)
    engine = engine_for(macos: archive)

    assert {:error, {:wrong_platform, :macos, :windows_x86_64} = why} =
             Installer.install({:file, archive},
               engine: engine,
               platform: :windows_x86_64,
               dir: Path.join(tmp, "engines"),
               bench: good_bench(engine)
             )

    assert Installer.message(why) =~ "the build for macOS"
  end

  test "a bench mismatch is refused, and so is an engine whose bench will not run", %{
    tmp_dir: tmp
  } do
    archive = zip(tmp)
    engine = engine_for(windows_x86_64: archive)
    opts = [engine: engine, platform: :windows_x86_64, dir: Path.join(tmp, "engines")]

    assert {:error, {:bench_mismatch, 2_497_913, 2_187_402} = why} =
             Installer.install({:file, archive}, [bench: fn _ -> {:ok, 2_187_402} end] ++ opts)

    assert Installer.message(why) =~ "2187402 instead of 2497913"

    assert {:error, {:bench_failed, :enoent}} =
             Installer.install({:file, archive}, [bench: fn _ -> {:error, :enoent} end] ++ opts)
  end

  test "no network, and a host that will not hand it over", %{tmp_dir: tmp} do
    opts = [
      platform: :linux_arm64,
      dir: Path.join(tmp, "engines"),
      bench: fn _ -> flunk("no") end
    ]

    assert {:error, {:no_network, :nxdomain} = why} =
             Installer.install(
               :download,
               [downloader: fn _, _ -> {:error, {:no_network, :nxdomain}} end] ++ opts
             )

    assert Installer.message(why) =~ "choose it here instead"

    assert {:error, {:download_failed, 404}} =
             Installer.install(
               :download,
               [downloader: fn _, _ -> {:error, {:download_failed, 404}} end] ++ opts
             )
  end

  test "a missing file, an archive with no engine in it, and an archive that climbs out", %{
    tmp_dir: tmp
  } do
    assert {:error, {:not_found, _}} =
             Installer.install({:file, Path.join(tmp, "nope.zip")},
               platform: :windows_x86_64,
               dir: tmp
             )

    empty = zip(tmp, [{~c"stockfish/README.md", "just words"}, {~c"../stockfish.exe", "escapee"}])
    engine = engine_for(windows_x86_64: empty)

    assert {:error, {:no_binary, "stockfish-windows-x86-64-universal.zip"}} =
             Installer.install({:file, empty},
               engine: engine,
               platform: :windows_x86_64,
               dir: Path.join(tmp, "engines"),
               bench: good_bench(engine)
             )

    refute File.exists?(Path.join(tmp, "stockfish.exe"))
  end

  test "an unsupported machine is told so before anything is fetched", %{tmp_dir: tmp} do
    assert {:error, {:unsupported_platform, what} = why} =
             Installer.install(:download,
               platform: :amiga,
               dir: tmp,
               downloader: fn _, _ -> flunk("must not download") end
             )

    assert what == "amiga"
    assert Installer.message(why) =~ "no official Stockfish 19 build"
  end

  test "reads the node count of a bench run" do
    output = """
    info depth 13 seldepth 15 multipv 1 score cp 11 nodes 38112 nps 846933 hashfull 18 tbhits 0 time 45 pv f1g1
    bestmove f1g1 ponder f8g8

    ===========================
    Total time (ms) : 2392
    Nodes searched  : 2497913
    Nodes/second    : 1044278
    """

    assert Installer.parse_bench(output) == {:ok, 2_497_913}
    assert Installer.parse_bench("Segmentation fault") == {:error, :no_bench_line}
  end
end
