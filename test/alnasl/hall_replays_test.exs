defmodule Alnasl.HallReplaysTest do
  @moduledoc """
  Every recording of a real board in `test/fixtures/hall/`, replayed, and
  held to the game pinned for it (`Alnasl.HallReplays`). A failure here is
  a real game coming out differently: look at it with `mix alnasl.hall
  check`, and pin it again on purpose if the new game is the better one.
  """

  use ExUnit.Case, async: true

  alias Alnasl.HallReplays

  @dir HallReplays.dir()
  @external_resource Path.join(@dir, "pinned.json")

  for {name, entry} <- HallReplays.pinned(@dir) do
    @entry entry
    test "#{name}: #{entry["note"] || "a recording"}" do
      assert {:ok, now} = HallReplays.replay(Path.join(@dir, @entry["capture"]))
      assert now == @entry["pinned"]
    end
  end

  test "the hall is not empty, and every known game of it comes out as played" do
    pinned = HallReplays.pinned(@dir)
    assert map_size(pinned) >= 6

    for {_name, %{"played" => played} = entry} <- pinned,
        played != nil,
        do: assert(entry["pinned"]["moves"] == played)
  end

  describe "pinning" do
    @tag :tmp_dir
    test "a capture of raw bytes comes in decoded, and replays as it did", %{tmp_dir: tmp} do
      source = "test/fixtures/captures/real-06310-misread-pawn.jsonl"
      {:ok, before} = HallReplays.replay(source)

      assert {:ok, entry} =
               HallReplays.pin(source, "a pawn / misread", dir: tmp, played: before["moves"])

      assert entry["capture"] == "a-pawn-misread.jsonl"
      assert entry["pinned"] == before
      refute File.read!(Path.join(tmp, "a-pawn-misread.jsonl")) =~ ~s("k":"rx")

      assert [%{name: "a-pawn-misread", same?: true, played?: true}] = HallReplays.check(tmp)
    end

    @tag :tmp_dir
    test "a game that changes is reported, not hidden", %{tmp_dir: tmp} do
      {:ok, _entry} =
        HallReplays.pin("test/fixtures/captures/opera-with-hands.jsonl", "opera", dir: tmp)

      manifest = Path.join(tmp, "pinned.json")
      pinned = manifest |> File.read!() |> Jason.decode!()
      wrong = put_in(pinned, ["opera", "pinned", "moves"], ["e4"])
      File.write!(manifest, Jason.encode!(wrong))

      assert [%{same?: false, played?: nil}] = HallReplays.check(tmp)
    end
  end
end
