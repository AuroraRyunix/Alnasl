defmodule Alnasl.DuplicateCodesTest do
  @moduledoc """
  One tournament reached through two connect codes is one row on the box:
  a group's code and the tournament's own, the same desktop copy at two
  addresses, a tournament that joins a group later. The second code makes
  no row and says why; it can take the old code's place; and a box that
  already has two rows has them made one at start-up.
  """

  use Alnasl.HallCase

  import Alnasl.LinkHelpers

  alias Alnasl.{FakeOpenPairings, Games, Log, OpenPairings, Tournaments}
  alias Alnasl.Destination.OpenPairings, as: Report
  alias Alnasl.OpenPairings.Duplicates
  alias Alnasl.Tournaments.{Link, Tournament}

  setup do
    pairing_program()
    :ok
  end

  defp rows(remote_id),
    do: Repo.all(from t in Tournament, where: t.remote_id == ^remote_id, order_by: t.id)

  defp festival do
    FakeOpenPairings.add_tournament(17, group: "Festival", name: "Open", boards: 2)
    FakeOpenPairings.add_tournament(18, group: "Festival", name: "U12", boards: 2)
    FakeOpenPairings.group_code("Festival")
  end

  defp game(tournament, board, round \\ 1) do
    pairing = Tournaments.board(tournament.id, round, board)
    Games.ensure(tournament.id, round, board, Games.pairing_attrs(pairing))
  end

  defp play(game, sans) do
    Enum.reduce(sans, game, fn san, game ->
      {game, _replace?} =
        Games.apply_event(game, {:moves, [%{san: san, flags: []}]}, 1_791_700_000_000)

      Alnasl.Outbox.enqueue(game, nil, false)
    end)
  end

  describe "a second code for a tournament the box has" do
    test "the group first, then the tournament's own code: no second row, and it says why" do
      {:ok, group, [_open, _u12]} = OpenPairings.add_code(festival())
      first = by_remote(17)

      assert {:ok, own, []} = OpenPairings.add_code(FakeOpenPairings.code(17))
      assert [%Tournament{id: id}] = rows(17)
      assert id == first.id

      assert [%{remote_id: 17, name: "Open", tournament: %{id: ^id}, through: through}] =
               Duplicates.shared(own)

      assert through.id == group.id

      sentence = AlnaslWeb.LinkWords.elsewhere(Duplicates.shared(own))
      assert sentence =~ "This code reaches Open, which this box already has through"
      assert sentence =~ ~s(the group "Festival")
      assert "tournament.elsewhere" in log_kinds()

      # Asked again and again, it stays one row.
      poll()
      poll()
      assert length(rows(17)) == 1

      # A game is reported once, through the code that holds the row.
      first |> game(1) |> play(~w(e4 e5))
      assert {:empty, 1} = Report.deliver()
      assert length(FakeOpenPairings.requests("POST", "/games")) == 1
    end

    test "the tournament's own code first, then its group: only the other tournament is added" do
      FakeOpenPairings.add_tournament(17, group: "Festival", name: "Open", boards: 2)
      {:ok, own, [open]} = OpenPairings.add_code(FakeOpenPairings.code(17))
      FakeOpenPairings.add_tournament(18, group: "Festival", name: "U12", boards: 2)

      {:ok, group, found} = OpenPairings.add_code(FakeOpenPairings.group_code("Festival"))
      assert Enum.map(found, & &1.remote_id) == [18]
      assert [%{id: id, link_id: link_id}] = rows(17)
      assert {id, link_id} == {open.id, own.id}
      assert [%{remote_id: 17}] = Duplicates.shared(group)
    end

    test "a tournament that joins a group later, whose own code the box has" do
      FakeOpenPairings.add_tournament(17, group: "Festival", name: "Open", boards: 2)
      FakeOpenPairings.add_tournament(18, name: "U12", boards: 2)
      {:ok, group, [_open]} = OpenPairings.add_code(FakeOpenPairings.group_code("Festival"))
      {:ok, _own, [u12]} = OpenPairings.add_code(FakeOpenPairings.code(18))

      FakeOpenPairings.update(18, &%{&1 | group: "Festival"})
      poll()

      assert [%{id: id}] = rows(18)
      assert id == u12.id
      assert [%{remote_id: 18}] = Duplicates.shared(Repo.get!(Link, group.id))
    end

    test "the same desktop copy at two addresses is one tournament" do
      FakeOpenPairings.add_tournament(17, name: "Open", boards: 2)
      code = FakeOpenPairings.code(17)
      {:ok, _here, [open]} = OpenPairings.add_code(code)

      lan = FakeOpenPairings.at(code, "http://192.168.1.20:4747/api/boards/v1")
      assert {:ok, other, []} = OpenPairings.add_code(lan)
      assert [%{id: id}] = rows(17)
      assert id == open.id
      assert [%{remote_id: 17}] = Duplicates.shared(other)

      # `localhost` is `127.0.0.1`, a default port is no port.
      assert Duplicates.same_server?(
               "http://LOCALHOST:80/api/boards/v1/",
               "http://127.0.0.1/api/boards/v1"
             )

      refute Duplicates.same_server?("http://127.0.0.1:4747/api", "http://127.0.0.1:4748/api")
    end

    test "found late, by a game they share, the later row is merged into the first" do
      FakeOpenPairings.add_tournament(17, name: "Open", boards: 2)
      code = FakeOpenPairings.code(17)
      {:ok, _here, [open]} = OpenPairings.add_code(code)

      # The listing's version and the one the box holds do not agree at the
      # moment the second code is asked (a result was entered in between).
      Repo.update_all(from(t in Tournament, where: t.id == ^open.id),
        set: [listed_version: "older", version: "older"]
      )

      lan = FakeOpenPairings.at(code, "http://pc-in-the-hall:4747/api/boards/v1")
      {:ok, other, _found} = OpenPairings.add_code(lan)

      assert [%{id: id}] = rows(17)
      assert id == open.id
      assert [%{remote_id: 17}] = Duplicates.shared(Repo.get!(Link, other.id))
      assert "tournament.merged" in log_kinds()

      poll()
      assert length(rows(17)) == 1
    end
  end

  describe "using the new code in place of the old" do
    test "a withdrawn code made again: the same row, its games, through the new code" do
      FakeOpenPairings.add_tournament(17, name: "Open", boards: 2)
      old_code = FakeOpenPairings.code(17)
      {:ok, old, [open]} = OpenPairings.add_code(old_code)
      played = open |> game(1) |> play(~w(e4 e5))

      FakeOpenPairings.withdraw(old_code)
      assert {:error, :unauthorized} = OpenPairings.poll(Repo.get!(Link, old.id))

      {:ok, new, []} = OpenPairings.add_code(FakeOpenPairings.code(17))
      assert [%{remote_id: 17}] = Duplicates.shared(new)

      assert {:ok, moved} = OpenPairings.use_code(new, 17)
      assert moved.id == open.id
      assert moved.link_id == new.id
      assert Games.get!(played.id).tournament_id == open.id
      # The old code reached nothing else: it is gone.
      refute Repo.get(Link, old.id)
      assert Duplicates.shared(Repo.get!(Link, new.id)) == []
      assert Repo.get!(Link, new.id).state == "ok"
      assert "tournament.code_replaced" in log_kinds()

      # The game goes out through the new code.
      assert {:empty, 1} = Report.deliver()
      assert FakeOpenPairings.game(17, "g17r1b1s0")["moves"] == ["e4", "e5"]
    end

    test "an old group code that reaches more stays, and notes the tournament as elsewhere" do
      {:ok, group, _found} = OpenPairings.add_code(festival())
      {:ok, own, []} = OpenPairings.add_code(FakeOpenPairings.code(17))

      assert {:ok, moved} = OpenPairings.use_code(own, 17)
      assert moved.link_id == own.id
      assert Repo.get(Link, group.id)
      assert [%{remote_id: 17}] = Duplicates.shared(Repo.get!(Link, group.id))

      poll()
      assert length(rows(17)) == 1
      assert by_remote(18).link_id == group.id
    end

    test "a row its own code no longer lists moves to the code that lists it" do
      FakeOpenPairings.add_tournament(17, group: "Festival", name: "Open", boards: 2)
      {:ok, group, [open]} = OpenPairings.add_code(FakeOpenPairings.group_code("Festival"))
      {:ok, own, []} = OpenPairings.add_code(FakeOpenPairings.code(17))

      # Taken out of the group: the group's code no longer lists it, its own
      # code still does - the row is asked through that one, not gone.
      FakeOpenPairings.update(17, &%{&1 | group: nil})
      OpenPairings.poll(Repo.get!(Link, group.id))

      moved = Tournaments.get!(open.id)
      assert {moved.link_id, moved.gone} == {own.id, false}
      refute "tournament.gone" in log_kinds()

      OpenPairings.poll(Repo.get!(Link, own.id))
      assert Tournaments.get!(open.id).document_at
      assert length(rows(17)) == 1
      assert Duplicates.shared(Repo.get!(Link, own.id)) == []
    end
  end

  describe "a box that already has two rows of one tournament" do
    # What a box from before this rule holds: two codes, two rows, games in
    # both, a board in each.
    defp two_rows do
      {:ok, group, _found} = OpenPairings.add_code(festival())
      first = by_remote(17)
      code = FakeOpenPairings.code(17)
      secret = FakeOpenPairings.secret(code)
      second_link = Repo.insert!(%Link{root: FakeOpenPairings.root(), secret: secret})

      second =
        Repo.insert!(%Tournament{
          kind: "linked",
          link_id: second_link.id,
          remote_id: 17,
          name: "Open",
          document: first.document,
          version: first.version,
          listed_version: first.version,
          server_url: first.server_url,
          slug: first.slug,
          relay_key: first.relay_key,
          table_from: 3,
          table_to: 4
        })

      {group, first, second_link, second}
    end

    test "start-up makes them one: boards, games and outbox move to the first, and the log says so" do
      {_group, first, second_link, second} = two_rows()

      a = first |> game(1) |> play(~w(e4 e5))
      # The second row has board 2 to itself, and board 1 too: a game there
      # that began - it cannot take the first row's place.
      b = second |> game(2) |> play(~w(d4 d5))
      c = second |> game(1) |> play(~w(c4))
      # An empty game where the first row has one that began: not kept.
      first |> game(1, 2) |> play(~w(Nf3))
      empty = game(second, 1, 2)

      {:ok, board} =
        Boards.create(%{name: "B", driver: "simulator", port: "sim-x", enabled: false})

      {:ok, board} = Boards.update(board, %{tournament_id: second.id, round: 1, board_no: 2})

      assert [{first_id, second_id}] = Duplicates.merge_all()
      assert {first_id, second_id} == {first.id, second.id}

      refute Repo.get(Tournament, second.id)
      assert [%{id: ^first_id}] = rows(17)

      assert Games.get!(a.id).tournament_id == first.id
      assert %{tournament_id: tid, board_no: 2, game_no: 1} = Games.get!(b.id)
      assert tid == first.id
      # The game on the taken place stays on the box, as the next game there.
      assert %{board_no: 1, game_no: 2, local: true} = Games.get!(c.id)
      refute Repo.get(Alnasl.Games.Game, empty.id)

      assert Boards.get!(board.id).tournament_id == first.id

      assert Repo.all(from e in Alnasl.Outbox.Entry, where: e.tournament_id == ^second.id) == []
      assert Repo.aggregate(from(e in Alnasl.Outbox.Entry, where: e.game_id == ^b.id), :count) > 0

      # The first row had no tables: it takes the second's.
      assert %{table_from: 3, table_to: 4} = Tournaments.get!(first.id)

      assert [event] = Enum.filter(Log.list(), &(&1.kind == "tournament.merged"))
      assert %{"boards" => 1, "games" => 2, "tournament" => "Open"} = Jason.decode!(event.data)
      assert AlnaslWeb.Words.log(event) =~ "Made one"

      # The second code knows, and does not make the row again.
      assert [%{remote_id: 17}] = Duplicates.shared(Repo.get!(Link, second_link.id))
      poll()
      assert length(rows(17)) == 1

      # Nothing to do the second time.
      assert Duplicates.merge_all() == []
    end
  end
end
