defmodule Alnasl.FairPlay.EnginesTest do
  use ExUnit.Case, async: true

  alias Alnasl.FairPlay.Engines

  test "the table is the plan's, digest for digest" do
    plan = File.read!(Path.expand("../../../docs/plan-fair-play.md", __DIR__))
    sf = Engines.default()

    assert sf.id == "sf19"
    assert sf.bench == 2_497_913
    assert map_size(sf.assets) == 5

    for {_platform, asset} <- sf.assets do
      assert plan =~ "`#{asset.name}` | `#{asset.sha256}`"
    end
  end

  test "platforms" do
    assert Engines.platform({:win32, :nt}, "AMD64") == {:ok, :windows_x86_64}
    assert Engines.platform({:win32, :nt}, "ARM64") == {:ok, :windows_arm64}
    assert Engines.platform({:unix, :darwin}, "aarch64-apple-darwin23.4.0") == {:ok, :macos}
    assert Engines.platform({:unix, :darwin}, "x86_64-apple-darwin17.7.0") == {:ok, :macos}
    assert Engines.platform({:unix, :linux}, "x86_64-pc-linux-gnu") == {:ok, :linux_x86_64}
    assert Engines.platform({:unix, :linux}, "aarch64-unknown-linux-gnu") == {:ok, :linux_arm64}

    assert {:error, {:unsupported_platform, "Windows on X86"}} =
             Engines.platform({:win32, :nt}, "x86")

    assert {:error, {:unsupported_platform, "Linux on armv7l-unknown-linux-gnueabihf"}} =
             Engines.platform({:unix, :linux}, "armv7l-unknown-linux-gnueabihf")

    assert {:error, {:unsupported_platform, _}} = Engines.platform({:unix, :freebsd}, "amd64")
  end

  test "this machine is one of them, or says why not" do
    assert match?({:ok, _}, Engines.platform()) or
             match?({:error, {:unsupported_platform, _}}, Engines.platform())
  end
end
