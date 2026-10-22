defmodule AlnaslWeb.FairPlayPagesTest do
  @moduledoc """
  What the owner sees: the settings, the report with and without a
  calibrated model, a player's key positions, the longer-keeping form. (Who
  gets in is `AlnaslWeb.FairPlayAccessTest`.)
  """

  use AlnaslWeb.SiteCase, async: false

  import AlnaslWeb.AccountHelpers
  import Alnasl.FairPlayFixtures

  alias Alnasl.FairPlay
  alias Alnasl.FairPlay.{Model, Report, Setting}
  alias Alnasl.{Halls, Tournaments}

  @moduletag :capture_log
  @moduletag :tmp_dir

  setup %{conn: conn} do
    owner = first_owner()
    %{conn: log_in(conn, owner), owner: owner, tournament: Tournaments.default()}
  end

  defp calibrate(dir) do
    Repo.insert!(%Setting{
      hall_id: Halls.own_id(),
      enabled: true,
      engine_id: "sf19",
      engine_version: "19",
      engine_bench: 2_497_913,
      nodes: 1_000_000
    })

    model = %Model{
      engine: "sf19",
      bench: 2_497_913,
      nodes: 1_000_000,
      match: List.duplicate(0.0, length(Model.feature_names())),
      ev: List.duplicate(0.0, length(Model.feature_names())),
      loss: %{cells: %{}, bands: %{}, global: {0.2, 0.05, 1000}},
      dispersion: %{
        r0: [[1.0, 0.5, 0.5], [0.5, 1.0, 0.5], [0.5, 0.5, 1.0]],
        within: List.duplicate([0.0, 0.0, 0.0], 3),
        between: List.duplicate([0.0, 0.0, 0.0], 3)
      },
      weights: [1.0, 1.0, 1.0]
    }

    Model.save(model, Model.path("sf19", dir))
    Application.put_env(:alnasl, :fair_play_model_dir, dir)
    on_exit(fn -> Application.delete_env(:alnasl, :fair_play_model_dir) end)
  end

  describe "the settings" do
    test "off by default, with the credit and the way to get an engine", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/halls/#{Halls.own_id()}/fair-play")

      refute has_element?(view, "#fair-play-enabled[checked]")
      assert has_element?(view, "#fair-play-engine-status", "Not installed")
      assert has_element?(view, "#fair-play-download", "Download Stockfish 19")
      assert has_element?(view, "#fair-play-install-file", "Choose a file")

      assert has_element?(
               view,
               "#fair-play-credit",
               "Uses Stockfish (GPL-3.0), stockfishchess.org, downloaded from the official release."
             )

      assert has_element?(view, "#fair-play-not-fide", "Art. 1.6")
    end

    test "says it is on but does nothing without an engine", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/halls/#{Halls.own_id()}/fair-play")
      view |> element("#fair-play-enabled") |> render_click()

      assert has_element?(view, "#fair-play-enabled[aria-checked=true]")
      assert has_element?(view, "#fair-play-needs-engine")
    end

    test "a failed installation says why in a sentence", %{conn: conn, tmp_dir: dir} do
      Application.put_env(:alnasl, :fair_play_install_opts,
        platform: :windows_x86_64,
        dir: Path.join(dir, "engines"),
        downloader: fn _url, _dest -> {:error, {:no_network, :nxdomain}} end
      )

      on_exit(fn -> Application.delete_env(:alnasl, :fair_play_install_opts) end)

      {:ok, view, _} = live(conn, ~p"/halls/#{Halls.own_id()}/fair-play")
      view |> element("#fair-play-download") |> render_click()

      error = eventually(fn -> has_element?(view, "#fair-play-error") && render(view) end)
      assert error =~ "internet"
      assert has_element?(view, "#fair-play-engine-status", "Not installed")
    end

    test "on a Mac too old for the engine the page says so instead of offering it", %{conn: conn} do
      Application.put_env(:alnasl, :fair_play_macos_version, fn -> "10.13.6" end)
      on_exit(fn -> Application.delete_env(:alnasl, :fair_play_macos_version) end)

      {:ok, view, _} = live(conn, ~p"/halls/#{Halls.own_id()}/fair-play")

      assert has_element?(
               view,
               "#fair-play-problem",
               "macOS 10.15 or newer; this Mac runs 10.13.6"
             )

      assert has_element?(
               view,
               "#fair-play-problem",
               "Everything else in Alnasl works as before."
             )

      refute has_element?(view, "#fair-play-download")
      refute has_element?(view, "#fair-play-install-file")
    end

    test "lists the hall's tournaments, each with its report", %{conn: conn, tournament: t} do
      {:ok, view, _} = live(conn, ~p"/halls/#{Halls.own_id()}/fair-play")
      assert has_element?(view, "#fair-play-tournament-#{t.id}")
      assert has_element?(view, "#fair-play-open-#{t.id}")
    end
  end

  describe "the report" do
    test "without a calibrated model: the counts, no score, and it says so", %{
      conn: conn,
      tournament: t
    } do
      insert_moves(t, 50)
      {:ok, view, _} = live(conn, ~p"/fair-play/#{t.id}")

      assert has_element?(view, "#fair-play-uncalibrated")
      assert has_element?(view, "#fair-play-table")
      assert has_element?(view, "#fair-play-player-id-1", "Some Player")
      assert has_element?(view, "#fair-play-player-id-1", "50")

      assert has_element?(
               view,
               "#fair-play-player-id-1",
               "no score until the engine is calibrated"
             )

      # Every report names the regulation and links the manual.
      assert has_element?(
               view,
               "#fair-play-not-fide",
               "FIDE Fair Play Regulations 2024, Art. 1.6"
             )

      assert has_element?(view, "#fair-play-manual[href='/help/fair-play#what-the-numbers-mean']")
    end

    test "with a model: the score and the wording", %{conn: conn, tournament: t, tmp_dir: dir} do
      calibrate(dir)
      insert_moves(t, 50)
      {:ok, view, _} = live(conn, ~p"/fair-play/#{t.id}")

      refute has_element?(view, "#fair-play-uncalibrated")
      assert has_element?(view, "#fair-play-player-id-1", "statistically very unusual")
      assert has_element?(view, "#fair-play-player-id-1", "100.0%")
    end

    test "too few moves is said, not scored", %{conn: conn, tournament: t, tmp_dir: dir} do
      calibrate(dir)
      insert_moves(t, 20)
      {:ok, view, _} = live(conn, ~p"/fair-play/#{t.id}")

      assert has_element?(view, "#fair-play-player-id-1", "too few moves")
      refute has_element?(view, "#fair-play-player-id-1", "statistically")
    end

    test "players with skipped moves show how many and why", %{conn: conn, tournament: t} do
      insert_moves(t, 45)
      Repo.update_all(from(m in Alnasl.FairPlay.Move, where: m.ply <= 5), set: [skip: "opening"])
      {:ok, view, _} = live(conn, ~p"/fair-play/#{t.id}")

      assert has_element?(view, "#fair-play-player-id-1", "5 opening (moves 1 to 8)")
    end

    test "an empty tournament says what is missing", %{conn: conn, tournament: t} do
      {:ok, view, _} = live(conn, ~p"/fair-play/#{t.id}")
      assert has_element?(view, "#fair-play-empty")
    end

    test "rounds: through a round, or that round only", %{conn: conn, tournament: t} do
      insert_moves(t, 50, "id:1", "First Player")

      Repo.insert_all(
        Alnasl.FairPlay.Move,
        Repo.all(from m in Alnasl.FairPlay.Move, where: m.ply <= 10)
        |> Enum.map(fn m ->
          m
          |> Map.from_struct()
          |> Map.drop([:__meta__, :id])
          |> Map.merge(%{
            round: 2,
            game_id: 777,
            player_key: "id:2",
            player_name: "Second Player"
          })
        end)
      )

      {:ok, view, _} = live(conn, ~p"/fair-play/#{t.id}/round/1")
      assert has_element?(view, "#fair-play-player-id-1")
      refute has_element?(view, "#fair-play-player-id-2")

      {:ok, view, _} = live(conn, ~p"/fair-play/#{t.id}/round/2")
      assert has_element?(view, "#fair-play-player-id-1")
      assert has_element?(view, "#fair-play-player-id-2")

      {:ok, view, _} = live(conn, ~p"/fair-play/#{t.id}/round/2?only=1")
      refute has_element?(view, "#fair-play-player-id-1")
      assert has_element?(view, "#fair-play-player-id-2")

      # The page opens on the latest round by itself.
      {:ok, view, _} = live(conn, ~p"/fair-play/#{t.id}")
      assert has_element?(view, "#fair-play-round-2[aria-current='true']")
    end

    test "the verdict words begin at 2 and at 5" do
      assert Report.verdict(nil) == nil
      assert Report.verdict(1.99) == nil
      assert Report.verdict(2.0) == :closer_look
      assert Report.verdict(5.0) == :closer_look
      assert Report.verdict(5.01) == :very_unusual
    end
  end

  describe "keeping it longer" do
    test "needs a reason; says until when", %{conn: conn, tournament: t} do
      insert_moves(t, 50)
      game = Alnasl.Games.ensure(t.id, 1, 1, %{white: "A", black: "B"})

      Repo.update_all(from(g in Alnasl.Games.Game, where: g.id == ^game.id),
        set: [status: "finished"]
      )

      {:ok, view, _} = live(conn, ~p"/fair-play/#{t.id}")
      assert has_element?(view, "#fair-play-keep-text", "Deleted 30 days")

      view
      |> form("#fair-play-extend", %{"keep" => %{"days" => "90", "reason" => " "}})
      |> render_submit()

      assert render(view) =~ "a reason is needed"

      view
      |> form("#fair-play-extend", %{"keep" => %{"days" => "90", "reason" => "FPL case"}})
      |> render_submit()

      assert has_element?(view, "#fair-play-keep-text", "FPL case")
      assert {:ok, %{reason: "FPL case"}} = FairPlay.keep(owner_scope(), t)
    end

    test "not beyond 365 days", %{conn: conn, tournament: t} do
      insert_moves(t, 50)
      Alnasl.Games.ensure(t.id, 1, 1, %{white: "A", black: "B"})

      {:ok, view, _} = live(conn, ~p"/fair-play/#{t.id}")

      view
      |> form("#fair-play-extend", %{"keep" => %{"days" => "400", "reason" => "Because"}})
      |> render_submit()

      assert render(view) =~ "At most 365 days"
    end
  end

  describe "a player" do
    test "the positions to look at: matched moves with the largest gap first", %{
      conn: conn,
      tournament: t
    } do
      insert_moves(t, 12)

      for {ply, gap} <- [{3, 150}, {5, 40}, {8, 90}] do
        Repo.update_all(from(m in Alnasl.FairPlay.Move, where: m.ply == ^ply), set: [gap: gap])
      end

      best =
        Jason.encode!([
          %{"move" => "e2e4", "cp" => 120},
          %{"move" => "d2d4", "cp" => 20},
          %{"move" => "g1f3", "cp" => 10},
          %{"move" => "c2c4", "cp" => 0}
        ])

      Repo.update_all(from(m in Alnasl.FairPlay.Move, where: m.ply == 3), set: [best: best])

      {:ok, view, _} = live(conn, ~p"/fair-play/#{t.id}/player?#{[p: "id:1"]}")

      assert has_element?(view, "#fair-play-player-numbers", "Some Player")
      assert has_element?(view, "#fair-play-position-0")
      assert has_element?(view, "#fair-play-board-0")
      # The widest gap leads, and the engine's four are shown as moves.
      assert has_element?(view, "#fair-play-position-0", "e4 +1.20")
      assert has_element?(view, "#fair-play-position-0", "d4")
      assert has_element?(view, "#fair-play-position-0", "Nf3")
      assert has_element?(view, "#fair-play-position-0", "c4")
    end

    test "a player with nothing analysed is said so", %{conn: conn, tournament: t} do
      insert_moves(t, 3)
      {:ok, view, _} = live(conn, ~p"/fair-play/#{t.id}/player?#{[p: "id:99"]}")
      assert has_element?(view, "#fair-play-no-player")
    end
  end

  defp owner_scope do
    Alnasl.Accounts.scope(Repo.get_by!(Alnasl.Accounts.User, email: "owner@example.org"), nil)
  end
end
