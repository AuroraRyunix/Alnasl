defmodule Alnasl.FairPlay.UploadsTest do
  use Alnasl.DataCase, async: false

  import AlnaslWeb.AccountHelpers
  import Alnasl.FairPlayFixtures

  alias Alnasl.{Accounts, FairPlay, Halls}
  alias Alnasl.FairPlay.{Retention, Upload, UploadGame, UploadMove, Uploads, View}

  @moduletag :capture_log
  @moduletag :tmp_dir

  # A PGN game of `sans` with these tags.
  defp pgn(sans, tags) do
    head = Enum.map_join(tags, "\n", fn {k, v} -> ~s([#{k} "#{v}"]) end)

    moves =
      sans
      |> Enum.chunk_every(2)
      |> Enum.with_index(1)
      |> Enum.map_join(" ", fn {pair, n} -> "#{n}. " <> Enum.join(pair, " ") end)

    head <> "\n\n" <> moves <> " *\n\n"
  end

  defp tags(extra \\ []) do
    [
      Event: "Club Open",
      Round: "1",
      White: "Alpha, Ann",
      Black: "Beta, Bo",
      WhiteElo: "2100",
      BlackElo: "1900"
    ]
    |> Keyword.merge(extra)
  end

  setup %{tmp_dir: dir} do
    owner = first_owner()
    hall = Halls.own_id()
    engine = Path.join(dir, "engine")
    File.write!(engine, "")
    switch_on(hall, engine)
    %{owner: owner, scope: Accounts.scope(owner, hall), hall: hall}
  end

  describe "reading a file" do
    test "a PGN of two games reads; binaries, empties and oversized ones do not" do
      text = pgn(random_sans(20, 1), tags()) <> pgn(random_sans(20, 2), tags(Round: "2"))
      assert {:ok, [_, _]} = Uploads.read(text)

      assert {:error, :binary} = Uploads.read(<<"PK", 3, 4, "zip">>)
      assert {:error, :binary} = Uploads.read(<<0x1F, 0x8B, 0, 0>>)
      assert {:error, :binary} = Uploads.read("[Event \"x\"]" <> <<0>>)
      assert {:error, :no_games} = Uploads.read("just some words")
      assert {:error, :too_big} = Uploads.read(text, 10)
    end

    test "latin-1 names are read, not refused" do
      text = pgn(random_sans(10, 1), tags(White: "M\xFCller"))
      assert {:ok, [game]} = Uploads.read(text)
      assert game.headers["White"] == "Müller"
    end
  end

  describe "checking a game" do
    test "ratings, round and board come from the tags" do
      {:ok, [game]} = Uploads.read(pgn(random_sans(20, 1), tags(Round: "5.12")))
      assert {:ok, attrs, []} = Uploads.check(game, 1)
      assert attrs.white_elo == 2100
      assert attrs.black_elo == 1900
      assert {attrs.round, attrs.board} == {5, 12}
      assert attrs.white_key == "name:Alpha, Ann"
    end

    test "a missing rating is said, not guessed" do
      {:ok, [game]} =
        Uploads.read(pgn(random_sans(20, 1), Keyword.delete(tags(), :BlackElo)))

      assert {:ok, attrs, [problem]} = Uploads.check(game, 3)
      assert attrs.black_elo == nil
      assert %{"kind" => "unrated", "detail" => "black", "game" => 3} = problem
    end

    test "an illegal move and a variant are refused, each with its reason" do
      {:ok, [bad]} = Uploads.read(pgn(["e4", "e5", "Ke3"], tags()))
      assert {:error, %{"kind" => "illegal", "detail" => detail}} = Uploads.check(bad, 1)
      assert detail =~ "Ke3"

      {:ok, [odd]} = Uploads.read(pgn(["e4"], tags(Variant: "Chess960")))
      assert {:error, %{"kind" => "variant"}} = Uploads.check(odd, 1)
    end

    test "names match a tournament's players whichever way round they are written" do
      players = %{fide: %{1_234 => 7}, names: %{Uploads.name_key("Ann Alpha") => 3}}
      assert Uploads.player_key(players, "Alpha, Ann", nil) == "id:3"
      assert Uploads.player_key(players, "Someone", 1_234) == "id:7"
      assert Uploads.player_key(players, "Nobody", nil) == "name:Nobody"
      assert Uploads.player_key(nil, "Alpha, Ann", nil) == "name:Alpha, Ann"
    end
  end

  describe "creating an upload" do
    test "stores the games, says what was refused, and writes the audit", ctx do
      text =
        pgn(random_sans(20, 1), tags()) <>
          pgn(["e4", "e5", "Ke3"], tags(Round: "2")) <>
          pgn(random_sans(20, 1), tags())

      assert {:ok, upload} =
               Uploads.create(ctx.scope, ctx.hall, %{
                 bytes: text,
                 filename: "C:\\games\\club.pgn",
                 name: nil,
                 tournament_id: nil
               })

      assert upload.name == "Club Open"
      assert upload.filename == "club.pgn"
      assert upload.accepted == 1
      assert upload.rejected == 2
      kinds = upload |> Upload.problems() |> Enum.map(& &1["kind"]) |> Enum.sort()
      assert kinds == ["illegal", "repeated"]

      assert [%View{action: "upload", upload_id: id}] = Repo.all(View)
      assert id == upload.id
      assert {:ok, %{waiting: 1, done: 0}} = Uploads.progress(ctx.scope, upload)
    end

    test "the same file twice is the same upload", ctx do
      text = pgn(random_sans(20, 1), tags())
      attrs = %{bytes: text, filename: "a.pgn", name: nil, tournament_id: nil}
      assert {:ok, first} = Uploads.create(ctx.scope, ctx.hall, attrs)
      assert {:error, {:already, again}} = Uploads.create(ctx.scope, ctx.hall, attrs)
      assert again.id == first.id
    end

    test "nobody but the owner, and nowhere fair play is not working" do
      hall = hall_fixture("Hall X")
      viewer = member(hall, user_fixture("viewer-x@example.org"), "viewer")
      admin = user_fixture("operator@example.org", %{admin: true})

      attrs = %{
        bytes: pgn(random_sans(20, 1), tags()),
        filename: "a.pgn",
        name: nil,
        tournament_id: nil
      }

      assert {:error, :forbidden} =
               Uploads.create(Accounts.scope(viewer, hall.id), hall.id, attrs)

      assert {:error, :forbidden} = Uploads.create(Accounts.scope(admin, hall.id), hall.id, attrs)
      assert {:error, :forbidden} = Uploads.create(nil, hall.id, attrs)

      owner = member(hall, user_fixture("owner-x@example.org"), "owner")

      assert {:error, :not_working} =
               Uploads.create(Accounts.scope(owner, hall.id), hall.id, attrs)

      assert Repo.aggregate(Upload, :count) == 0
    end

    test "a tournament of another hall is refused", ctx do
      other = hall_fixture("Hall Y")
      foreign = Halls.local_tournament(other)

      assert {:error, :tournament} =
               Uploads.create(ctx.scope, ctx.hall, %{
                 bytes: pgn(random_sans(20, 1), tags()),
                 filename: "a.pgn",
                 name: nil,
                 tournament_id: foreign.id
               })
    end
  end

  describe "analysing and reporting" do
    test "an uploaded game is analysed and reported like a board game", ctx do
      {:ok, upload} =
        Uploads.create(ctx.scope, ctx.hall, %{
          bytes: pgn(random_sans(30, 4), tags()),
          filename: "a.pgn",
          name: "Rapid",
          tournament_id: nil
        })

      Phoenix.PubSub.subscribe(Alnasl.PubSub, Uploads.topic(upload.id))
      [game] = Repo.all(UploadGame)
      assert :ok = Uploads.analyse(game, upload, engine(), setting())
      assert_receive {:fair_play_upload, id} when id == upload.id

      assert Repo.get(UploadGame, game.id).status == "done"
      assert {:ok, rows} = FairPlay.moves(ctx.scope, upload)
      assert length(rows) == 30
      assert Enum.all?(rows, &(&1.player_key in ["name:Alpha, Ann", "name:Beta, Bo"]))
      assert {:ok, [1]} = FairPlay.rounds(ctx.scope, upload)
      assert {:ok, %{done: 1, waiting: 0}} = Uploads.progress(ctx.scope, upload)

      # Analysed again, it replaces its rows rather than doubling them.
      assert :ok = Uploads.analyse(game, upload, engine(), setting())
      assert Repo.aggregate(UploadMove, :count) == 30
    end

    test "games attached to a tournament count in its report, under its players' keys", ctx do
      tournament = rated_tournament()

      {:ok, upload} =
        Uploads.create(ctx.scope, ctx.hall, %{
          bytes:
            pgn(
              random_sans(30, 4),
              tags(White: "Player, White", Black: "Player, Black", Round: "2")
            ),
          filename: "a.pgn",
          name: nil,
          tournament_id: tournament.id
        })

      [game] = Repo.all(UploadGame)
      :ok = Uploads.analyse(game, upload, engine(), setting())

      {:ok, rows} = FairPlay.moves(ctx.scope, tournament)
      assert rows |> Enum.map(& &1.player_key) |> Enum.uniq() |> Enum.sort() == ["id:1", "id:2"]
      assert {:ok, rounds} = FairPlay.rounds(ctx.scope, tournament)
      assert 2 in rounds

      # Kept as long as the tournament, not on its own.
      assert {:ok, :with_tournament} = FairPlay.keep(ctx.scope, upload)
      assert {:error, :attached} = FairPlay.extend(ctx.scope, upload, 60, "appeal")
    end

    test "a game the boards recorded is not analysed a second time", ctx do
      tournament = rated_tournament()
      game(tournament, random_sans(20, 1))

      {:ok, upload} =
        Uploads.create(ctx.scope, ctx.hall, %{
          bytes: pgn(random_sans(20, 1), tags(White: "White Player", Black: "Black Player")),
          filename: "a.pgn",
          name: nil,
          tournament_id: tournament.id
        })

      assert {:ok, %{duplicate: 1, waiting: 0}} = Uploads.progress(ctx.scope, upload)
      assert [%{"kind" => "on_the_boards"}] = Upload.problems(upload)
    end

    test "requeue and delete are the owner's; delete leaves one line in the hall's audit", ctx do
      {:ok, upload} =
        Uploads.create(ctx.scope, ctx.hall, %{
          bytes: pgn(random_sans(20, 1), tags()),
          filename: "a.pgn",
          name: nil,
          tournament_id: nil
        })

      stranger = Accounts.scope(user_fixture("x@example.org"), ctx.hall)
      assert {:error, :forbidden} = Uploads.requeue(stranger, upload)
      assert {:error, :forbidden} = Uploads.delete(stranger, upload)
      assert {:ok, 1} = Uploads.requeue(ctx.scope, upload)

      assert :ok = Uploads.delete(ctx.scope, upload)
      assert Repo.aggregate(Upload, :count) == 0
      assert Repo.aggregate(UploadGame, :count) == 0
      assert [%View{action: "delete_upload", upload_id: nil}] = Repo.all(View)
    end
  end

  describe "a round on demand" do
    test "the owner queues a played round's games and it is written down", ctx do
      tournament = rated_tournament()
      game(tournament, random_sans(20, 1))

      assert {:ok, [1]} = FairPlay.played_rounds(ctx.scope, tournament)
      assert {:ok, 1} = FairPlay.analyse_round(ctx.scope, tournament, 1)
      assert {:ok, 0} = FairPlay.analyse_round(ctx.scope, tournament, 2)
      assert [%View{action: "analyse_round", tournament_id: tid} | _] = Repo.all(View)
      assert tid == tournament.id
    end

    test "nobody else, and not where fair play is not working", ctx do
      tournament = rated_tournament()
      game(tournament, random_sans(20, 1))

      viewer = member(hall_fixture("Hall Z"), user_fixture("v@example.org"), "viewer")

      assert {:error, :forbidden} =
               FairPlay.analyse_round(Accounts.scope(viewer, ctx.hall), tournament, 1)

      FairPlay.set_enabled(ctx.scope, ctx.hall, false)
      assert {:error, :not_working} = FairPlay.analyse_round(ctx.scope, tournament, 1)
    end
  end

  describe "retention" do
    test "an upload of its own goes after the retention days, unless kept", ctx do
      {:ok, upload} =
        Uploads.create(ctx.scope, ctx.hall, %{
          bytes: pgn(random_sans(20, 1), tags()),
          filename: "a.pgn",
          name: nil,
          tournament_id: nil
        })

      [game] = Repo.all(UploadGame)
      :ok = Uploads.analyse(game, upload, engine(), setting())
      later = DateTime.add(upload.inserted_at, 40 * 86_400, :second)

      assert {:ok, _} = FairPlay.extend(ctx.scope, upload, 60, "an appeal")
      assert %{uploads: 0} = Retention.purge(later, 30)
      assert Repo.aggregate(UploadMove, :count) == 20

      much_later = DateTime.add(upload.inserted_at, 70 * 86_400, :second)
      assert %{uploads: 1} = Retention.purge(much_later, 30)
      assert Repo.aggregate(UploadMove, :count) == 0
      assert Repo.aggregate(Upload, :count) == 0
    end

    test "an attached upload goes with its tournament", ctx do
      tournament = rated_tournament()

      {:ok, upload} =
        Uploads.create(ctx.scope, ctx.hall, %{
          bytes: pgn(random_sans(20, 1), tags()),
          filename: "a.pgn",
          name: nil,
          tournament_id: tournament.id
        })

      [game] = Repo.all(UploadGame)
      :ok = Uploads.analyse(game, upload, engine(), setting())

      # The tournament has no board games: no last round, so it goes at once.
      assert %{tournaments: 1, uploads: 1} = Retention.purge(DateTime.utc_now(), 30)
      assert Repo.aggregate(UploadMove, :count) == 0
    end
  end
end
