defmodule AlnaslWeb.FairPlayAccessTest do
  @moduledoc """
  Fair play is the hall owner's and nobody else's, on every door: the
  report, a player's page, the settings, the switch and the engine's
  installation. Not an arbiter, not a viewer, not the hosted service's admin
  in somebody else's hall, not the owner of another hall. A box without
  accounts is its own owner.
  """

  use AlnaslWeb.SiteCase, async: false

  import AlnaslWeb.AccountHelpers
  import Alnasl.FairPlayFixtures

  alias Alnasl.{Accounts, FairPlay, Halls, Tournaments}
  alias Alnasl.FairPlay.{Access, Setting, View}

  @moduletag :capture_log
  @moduletag :tmp_dir

  # A zip laid out as the real Windows one is, and the table that expects it.
  defp archive(dir) do
    path = Path.join(dir, "stockfish-windows-x86-64-universal.zip")

    {:ok, _} =
      :zip.create(String.to_charlist(path), [
        {~c"stockfish/stockfish-windows-x86-64-universal.exe", "an engine, in spirit"}
      ])

    path
  end

  defp engine_for(path) do
    sf = Alnasl.FairPlay.Engines.default()

    %{
      sf
      | assets:
          Map.update!(
            sf.assets,
            :windows_x86_64,
            &%{&1 | sha256: Alnasl.FairPlay.Installer.sha256(path)}
          )
    }
  end

  defp install_options(dir, archive) do
    engine = engine_for(archive)

    [
      engine: engine,
      platform: :windows_x86_64,
      dir: Path.join(dir, "engines"),
      bench: fn _binary -> {:ok, engine.bench} end,
      downloader: fn _url, dest -> File.cp(archive, dest) end
    ]
  end

  # The people. `hall` is Hall A; `Halls.own_id()` is the box's own hall.
  setup do
    first = first_owner()
    hall = hall_fixture("Hall A")
    other = hall_fixture("Hall B")

    people = %{
      owner: member(hall, user_fixture("owner-a@example.org"), "owner"),
      arbiter: member(hall, user_fixture("arbiter-a@example.org"), "arbiter"),
      viewer: member(hall, user_fixture("viewer-a@example.org"), "viewer"),
      outsider_admin: user_fixture("operator@example.org", %{admin: true}),
      admin_owner: member(hall, user_fixture("admin-owner@example.org", %{admin: true}), "owner"),
      other_owner: member(other, user_fixture("owner-b@example.org"), "owner")
    }

    tournament = Halls.local_tournament(hall)
    insert_moves(tournament, 50)

    Map.merge(people, %{first: first, hall: hall, other: other, tournament: tournament})
  end

  defp scope(user, hall), do: Accounts.scope(user, hall.id)

  defp reach(conn, user, hall, path), do: live(log_in(conn, user, hall), path)

  defp reached?({:ok, _view, _html}), do: true
  defp reached?({:error, {kind, _}}) when kind in [:redirect, :live_redirect], do: false

  defp pages(ctx) do
    [
      report: ~p"/fair-play/#{ctx.tournament.id}",
      report_round: ~p"/fair-play/#{ctx.tournament.id}/round/1",
      player: ~p"/fair-play/#{ctx.tournament.id}/player?#{[p: "id:1"]}",
      settings: ~p"/halls/#{ctx.hall.id}/fair-play"
    ]
  end

  describe "the rule itself" do
    test "owner yes; arbiter, viewer, admin who is no member, owner elsewhere no", ctx do
      assert Access.owner?(scope(ctx.owner, ctx.hall), ctx.hall.id)
      refute Access.owner?(scope(ctx.arbiter, ctx.hall), ctx.hall.id)
      refute Access.owner?(scope(ctx.viewer, ctx.hall), ctx.hall.id)
      refute Access.owner?(scope(ctx.other_owner, ctx.other), ctx.hall.id)
      refute Access.owner?(scope(ctx.other_owner, ctx.hall), ctx.hall.id)

      # The operator sees every hall for running it, and Scope.role says so.
      admin = scope(ctx.outsider_admin, ctx.hall)
      assert Alnasl.Accounts.Scope.role(admin, ctx.hall.id) == "owner"
      refute Access.owner?(admin, ctx.hall.id)
      refute Access.owner?(admin, ctx.other.id)

      # An admin who really is the hall's owner is.
      assert Access.owner?(scope(ctx.admin_owner, ctx.hall), ctx.hall.id)
      refute Access.owner?(scope(ctx.admin_owner, ctx.other), ctx.other.id)

      # The box's first account owns the box's own hall, and no other.
      assert Access.owner?(scope(ctx.first, ctx.hall), Halls.own_id())
      refute Access.owner?(scope(ctx.first, ctx.hall), ctx.hall.id)
    end

    test "nobody and nothing is not an owner" do
      refute Access.owner?(nil, 1)
      refute Access.owner?(%Alnasl.Accounts.Scope{}, 1)
      refute Access.owner?(%Alnasl.Accounts.Scope{}, nil)
    end
  end

  describe "the report, a player's page and the settings" do
    test "the owner reaches all of them", %{conn: conn} = ctx do
      for {name, path} <- pages(ctx) do
        assert reached?(reach(conn, ctx.owner, ctx.hall, path)), "#{name}"
      end
    end

    test "an admin who is also the hall's owner does too", %{conn: conn} = ctx do
      for {name, path} <- pages(ctx) do
        assert reached?(reach(conn, ctx.admin_owner, ctx.hall, path)), "#{name}"
      end
    end

    for who <- [:arbiter, :viewer, :outsider_admin, :other_owner] do
      test "#{who} reaches none of them, and is told nothing", %{conn: conn} = ctx do
        user = Map.fetch!(ctx, unquote(who))
        # The other hall's owner looks at their own hall's pages.
        hall = if unquote(who) == :other_owner, do: ctx.other, else: ctx.hall

        for {name, path} <- pages(ctx) do
          refute reached?(reach(conn, user, hall, path)), "#{name}"
        end

        assert Repo.aggregate(View, :count) == 0
      end
    end

    test "a tournament that does not exist is no different from one that is not yours",
         %{conn: conn} = ctx do
      assert {:error, {_, %{to: "/"}}} = reach(conn, ctx.owner, ctx.hall, ~p"/fair-play/999999")

      assert {:error, {_, %{to: "/"}}} =
               reach(conn, ctx.viewer, ctx.hall, ~p"/fair-play/#{ctx.tournament.id}")
    end

    test "the owner of another hall cannot reach this hall's report, not even by its address",
         %{conn: conn} = ctx do
      refute reached?(
               reach(conn, ctx.other_owner, ctx.other, ~p"/fair-play/#{ctx.tournament.id}")
             )
    end

    test "an open box is its own owner", %{conn: conn} do
      # No accounts at all: the hall's own network, nobody signs in.
      Alnasl.Repo.delete_all(Alnasl.Accounts.User)
      refute Accounts.login_required?()

      own = Tournaments.default()
      insert_moves(own, 50)

      assert reached?(live(conn, ~p"/fair-play/#{own.id}"))
      assert reached?(live(conn, ~p"/halls/#{Halls.own_id()}/fair-play"))
      assert reached?(live(conn, ~p"/fair-play/#{own.id}/player?#{[p: "id:1"]}"))
    end

    test "the menu offers fair play to the owner and to nobody else", %{conn: conn} = ctx do
      {:ok, owner, _} = reach(conn, ctx.owner, ctx.hall, ~p"/halls/#{ctx.hall.id}")
      assert has_element?(owner, "#nav-fair_play", "Fair play")
      refute has_element?(owner, "#hall-fair-play")

      for who <- [:arbiter, :viewer] do
        {:ok, page, html} =
          reach(build_conn(), Map.fetch!(ctx, who), ctx.hall, ~p"/halls/#{ctx.hall.id}")

        refute has_element?(page, "#nav-fair_play")
        refute has_element?(page, "#hall-fair-play")
        refute html =~ "Fair-play"
      end

      {:ok, admin, _} =
        reach(build_conn(), ctx.outsider_admin, ctx.hall, ~p"/halls/#{ctx.hall.id}")

      refute has_element?(admin, "#nav-fair_play")
    end

    test "an admin who owns a hall has the item; a box without accounts has it too",
         %{conn: conn} = ctx do
      {:ok, admin, _} = reach(conn, ctx.admin_owner, ctx.hall, ~p"/halls/#{ctx.hall.id}")
      assert has_element?(admin, "#nav-fair_play")

      Alnasl.Repo.delete_all(Alnasl.Accounts.User)
      {:ok, open, _} = live(build_conn(), ~p"/halls")
      assert has_element?(open, "#nav-fair_play")
    end
  end

  describe "the halls page" do
    test "lists the halls the person owns and no other", %{conn: conn} = ctx do
      {:ok, view, _} = reach(conn, ctx.owner, ctx.hall, ~p"/fair-play")

      assert has_element?(view, "#fair-play-index")
      assert has_element?(view, "#fair-play-hall-#{ctx.hall.id}")
      refute has_element?(view, "#fair-play-hall-#{ctx.other.id}")
      assert has_element?(view, "#fair-play-hall-status-#{ctx.hall.id}", "Off")
      assert has_element?(view, "#fair-play-hall-status-#{ctx.hall.id}", "Engine not installed")
      assert has_element?(view, "#fair-play-settings-#{ctx.hall.id}")

      assert has_element?(
               view,
               "#fair-play-hall-#{ctx.hall.id}-report-#{ctx.tournament.id}"
             )

      assert has_element?(view, "#nav-fair_play[aria-current=page]")
    end

    test "answers arbiter, viewer and an admin who owns no hall as a page not there",
         %{conn: conn} = ctx do
      for who <- [:arbiter, :viewer, :outsider_admin] do
        refute reached?(reach(build_conn(), Map.fetch!(ctx, who), ctx.hall, ~p"/fair-play"))
      end

      _ = conn
    end
  end

  describe "the audit" do
    test "every opening of a report or a player's page by the owner is written down",
         %{conn: conn} = ctx do
      {:ok, view, _} = reach(conn, ctx.owner, ctx.hall, ~p"/fair-play/#{ctx.tournament.id}")
      assert has_element?(view, "#fair-play-table")

      {:ok, _view, _} =
        reach(
          build_conn(),
          ctx.owner,
          ctx.hall,
          ~p"/fair-play/#{ctx.tournament.id}/player?#{[p: "id:1"]}"
        )

      views = Repo.all(from v in View, order_by: v.id)
      assert [report, player] = views
      assert report.tournament_id == ctx.tournament.id
      assert report.user_email == "owner-a@example.org"
      assert report.round == 1
      assert report.player_key == nil
      assert player.player_key == "id:1"
    end

    test "the static first render holds no data and writes nothing", %{conn: conn} = ctx do
      conn = get(log_in(conn, ctx.owner, ctx.hall), ~p"/fair-play/#{ctx.tournament.id}")
      html = html_response(conn, 200)

      refute html =~ "fair-play-table"
      refute html =~ "Some Player"
      assert Repo.aggregate(View, :count) == 0
    end

    test "a stranger's attempt writes nothing and the context says no", ctx do
      assert {:error, :forbidden} =
               FairPlay.record_view(scope(ctx.arbiter, ctx.hall), ctx.tournament, 1, nil)

      assert {:error, :forbidden} =
               FairPlay.record_view(scope(ctx.outsider_admin, ctx.hall), ctx.tournament, 1, nil)

      assert Repo.aggregate(View, :count) == 0
    end
  end

  describe "the context functions say no to everybody else too" do
    test "rows, rounds, views, keeps, tournaments", ctx do
      for who <- [:arbiter, :viewer, :outsider_admin, :other_owner] do
        s = scope(Map.fetch!(ctx, who), ctx.hall)
        assert {:error, :forbidden} = FairPlay.moves(s, ctx.tournament)
        assert {:error, :forbidden} = FairPlay.rounds(s, ctx.tournament)
        assert {:error, :forbidden} = FairPlay.views(s, ctx.tournament)
        assert {:error, :forbidden} = FairPlay.keep(s, ctx.tournament)
        assert {:error, :forbidden} = FairPlay.tournaments(s, ctx.hall.id)
        assert {:error, :forbidden} = FairPlay.tournament(s, ctx.tournament.id)
        assert {:error, :forbidden} = FairPlay.extend(s, ctx.tournament, 30, "because")
      end

      assert {:ok, [_ | _]} = FairPlay.moves(scope(ctx.owner, ctx.hall), ctx.tournament)
    end
  end

  describe "the switch" do
    test "the owner switches it on and off; nobody else can", %{conn: conn} = ctx do
      {:ok, view, _} = reach(conn, ctx.owner, ctx.hall, ~p"/halls/#{ctx.hall.id}/fair-play")

      refute has_element?(view, "#fair-play-enabled[data-confirm]")
      view |> element("#fair-play-enabled") |> render_click()
      assert FairPlay.settings(ctx.hall.id).enabled
      assert has_element?(view, "#fair-play-enabled[aria-checked=true]")

      # Off is the one that asks first: the moves played meanwhile go unanalysed.
      assert has_element?(view, "#fair-play-enabled[data-confirm]")
      view |> element("#fair-play-enabled") |> render_click()
      refute FairPlay.settings(ctx.hall.id).enabled
      assert has_element?(view, "#fair-play-enabled[aria-checked=false]")

      for who <- [:arbiter, :viewer, :outsider_admin, :other_owner] do
        assert {:error, :forbidden} =
                 FairPlay.set_enabled(scope(Map.fetch!(ctx, who), ctx.hall), ctx.hall.id, true)
      end

      refute FairPlay.settings(ctx.hall.id).enabled
      assert Repo.aggregate(Setting, :count) == 1
    end

    test "a forged switch from a page that is not the owner's does nothing",
         %{conn: conn} = ctx do
      # The page itself is closed to them; the context is the second door.
      assert {:error, _} =
               reach(conn, ctx.outsider_admin, ctx.hall, ~p"/halls/#{ctx.hall.id}/fair-play")

      assert {:error, :forbidden} =
               FairPlay.set_enabled(scope(ctx.outsider_admin, ctx.hall), ctx.hall.id, true)

      refute FairPlay.settings(ctx.hall.id).enabled
    end

    test "fair play is off in every hall until an owner turns it on", ctx do
      refute FairPlay.settings(ctx.hall.id).enabled
      refute FairPlay.settings(ctx.other.id).enabled
      refute FairPlay.settings(Halls.own_id()).enabled
    end
  end

  describe "installing the engine" do
    test "the owner installs from a file", %{tmp_dir: dir} = ctx do
      archive = archive(dir)

      assert {:ok, setting} =
               FairPlay.install(
                 scope(ctx.owner, ctx.hall),
                 ctx.hall.id,
                 {:file, archive},
                 install_options(dir, archive)
               )

      assert setting.engine_version == "19"
      assert setting.engine_bench == 2_497_913
      assert File.regular?(setting.engine_path)
    end

    for who <- [:arbiter, :viewer, :outsider_admin, :other_owner] do
      test "#{who} cannot install it, and nothing is downloaded or written",
           %{tmp_dir: dir} = ctx do
        archive = archive(dir)
        options = install_options(dir, archive)
        test = self()
        options = Keyword.put(options, :downloader, fn _url, _dest -> send(test, :downloaded) end)

        s = scope(Map.fetch!(ctx, unquote(who)), ctx.hall)
        assert {:error, :forbidden} = FairPlay.install(s, ctx.hall.id, :download, options)
        assert {:error, :forbidden} = FairPlay.install(s, ctx.hall.id, {:file, archive}, options)

        refute_received :downloaded
        refute File.exists?(Path.join(dir, "engines"))
        assert Repo.aggregate(Setting, :count) == 0
      end
    end

    test "the download button of the owner's page installs; a forged event from anybody else does not",
         %{conn: conn, tmp_dir: dir} = ctx do
      archive = archive(dir)
      Application.put_env(:alnasl, :fair_play_install_opts, install_options(dir, archive))
      on_exit(fn -> Application.delete_env(:alnasl, :fair_play_install_opts) end)

      {:ok, view, _} = reach(conn, ctx.owner, ctx.hall, ~p"/halls/#{ctx.hall.id}/fair-play")
      view |> element("#fair-play-download") |> render_click()

      eventually(fn -> FairPlay.settings(ctx.hall.id).engine_bench end)
      assert has_element?(view, "#fair-play-engine-status", "Installed")

      # An arbiter who forges the event at the report page of nothing
      # gets nowhere: the page is not theirs to mount.
      assert {:error, _} =
               reach(build_conn(), ctx.arbiter, ctx.hall, ~p"/halls/#{ctx.hall.id}/fair-play")
    end
  end

  describe "another hall's data" do
    test "an owner sees their own hall's report and not the neighbour's", %{conn: conn} = ctx do
      other_t = Halls.local_tournament(ctx.other)
      insert_moves(other_t, 50, "id:7", "Neighbour")

      assert reached?(reach(conn, ctx.other_owner, ctx.other, ~p"/fair-play/#{other_t.id}"))
      refute reached?(reach(build_conn(), ctx.owner, ctx.hall, ~p"/fair-play/#{other_t.id}"))

      refute reached?(
               reach(build_conn(), ctx.admin_owner, ctx.hall, ~p"/fair-play/#{other_t.id}")
             )

      refute reached?(
               reach(build_conn(), ctx.outsider_admin, ctx.other, ~p"/fair-play/#{other_t.id}")
             )
    end
  end
end
