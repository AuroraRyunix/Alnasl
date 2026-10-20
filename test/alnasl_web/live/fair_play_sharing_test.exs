defmodule AlnaslWeb.FairPlaySharingTest do
  @moduledoc """
  Sharing fair play: the owner lets a named member of the hall see a report
  or the whole hall's, until a date, and can stop it. Every way in is
  tried: the owner, a grantee, an expired grant, a revoked one, a former
  member, the hosted admin, a stranger, nobody signed in.
  """

  use AlnaslWeb.SiteCase, async: false

  import AlnaslWeb.AccountHelpers
  import Alnasl.FairPlayFixtures

  alias Alnasl.{Accounts, FairPlay, Halls, Repo}
  alias Alnasl.FairPlay.{Grant, Grants, View}

  @moduletag :capture_log

  setup do
    first_owner()
    hall = hall_fixture("Hall A")
    other = hall_fixture("Hall B")
    tournament = Halls.local_tournament(hall)
    insert_moves(tournament, 50)

    %{
      hall: hall,
      other: other,
      tournament: tournament,
      owner: member(hall, user_fixture("owner-a@example.org"), "owner"),
      arbiter: member(hall, user_fixture("arbiter-a@example.org"), "arbiter"),
      viewer: member(hall, user_fixture("viewer-a@example.org"), "viewer"),
      admin: user_fixture("operator@example.org", %{admin: true}),
      stranger: member(other, user_fixture("stranger@example.org"), "viewer")
    }
  end

  defp scope(user, hall), do: Accounts.scope(user, hall.id)
  defp reach(conn, user, hall, path), do: live(log_in(conn, user, hall), path)
  defp reached?({:ok, _view, _html}), do: true
  defp reached?({:error, {kind, _}}) when kind in [:redirect, :live_redirect], do: false

  defp share(ctx, subject, who, days \\ 30) do
    {:ok, grant} =
      Grants.grant(scope(ctx.owner, ctx.hall), subject, Map.fetch!(ctx, who).id, days)

    grant
  end

  defp report(ctx), do: ~p"/fair-play/#{ctx.tournament.id}"

  describe "who may share, and with whom" do
    test "the owner shares with a member; never with an outsider, never for too long", ctx do
      owner = scope(ctx.owner, ctx.hall)

      assert {:ok, %Grant{}} = Grants.grant(owner, ctx.tournament, ctx.arbiter.id, 30)
      assert {:error, :not_member} = Grants.grant(owner, ctx.tournament, ctx.stranger.id, 30)
      assert {:error, :not_member} = Grants.grant(owner, ctx.tournament, ctx.admin.id, 30)
      assert {:error, :not_member} = Grants.grant(owner, ctx.tournament, ctx.owner.id, 30)
      assert {:error, :days} = Grants.grant(owner, ctx.tournament, ctx.viewer.id, 0)
      assert {:error, :days} = Grants.grant(owner, ctx.tournament, ctx.viewer.id, 366)
    end

    test "a grantee, the admin and a stranger cannot share, nor revoke", ctx do
      grant = share(ctx, ctx.tournament, :arbiter)

      for who <- [:arbiter, :viewer, :admin, :stranger] do
        s = scope(Map.fetch!(ctx, who), ctx.hall)
        assert {:error, :forbidden} = Grants.grant(s, ctx.tournament, ctx.viewer.id, 30)
        assert {:error, :forbidden} = Grants.grant(s, {:hall, ctx.hall.id}, ctx.viewer.id, 30)
        assert {:error, :forbidden} = Grants.revoke(s, grant.id)
        assert {:error, :forbidden} = Grants.list(s, ctx.hall.id)
      end

      assert {:error, :forbidden} = Grants.grant(nil, ctx.tournament, ctx.viewer.id, 30)
    end

    test "granting and revoking are written in the audit", ctx do
      grant = share(ctx, ctx.tournament, :arbiter)
      {:ok, _} = Grants.revoke(scope(ctx.owner, ctx.hall), grant.id)

      assert [%View{action: "grant", tournament_id: tid, detail: detail}, %View{action: "revoke"}] =
               Repo.all(from v in View, order_by: v.id)

      assert tid == ctx.tournament.id
      assert detail =~ "arbiter-a@example.org until "
    end
  end

  describe "every way in" do
    test "the owner reads", ctx do
      assert FairPlay.can_view?(scope(ctx.owner, ctx.hall), ctx.tournament)
      assert reached?(reach(build_conn(), ctx.owner, ctx.hall, report(ctx)))
    end

    test "a grantee reads the report and its players' pages, and that is written down", ctx do
      share(ctx, ctx.tournament, :arbiter)
      s = scope(ctx.arbiter, ctx.hall)

      assert {:ok, [_ | _]} = FairPlay.moves(s, ctx.tournament)
      assert {:ok, view, _} = reach(build_conn(), ctx.arbiter, ctx.hall, report(ctx))
      assert has_element?(view, "#fair-play-table")
      assert has_element?(view, "#fair-play-shared-note")
      refute has_element?(view, "#fair-play-share")
      refute has_element?(view, "#fair-play-keep")
      refute has_element?(view, "#fair-play-views")

      assert reached?(
               reach(build_conn(), ctx.arbiter, ctx.hall, report(ctx) <> "/player?p=id%3A1")
             )

      assert [%View{user_email: "arbiter-a@example.org"}, %View{player_key: "id:1"}] =
               Repo.all(from v in View, where: v.action == "view", order_by: v.id)
    end

    test "a grantee changes nothing and sees nothing of the owner's", ctx do
      share(ctx, {:hall, ctx.hall.id}, :arbiter)
      s = scope(ctx.arbiter, ctx.hall)

      assert {:error, :forbidden} = FairPlay.views(s, ctx.tournament)
      assert {:error, :forbidden} = FairPlay.keep(s, ctx.tournament)
      assert {:error, :forbidden} = FairPlay.extend(s, ctx.tournament, 30, "why")
      assert {:error, :forbidden} = FairPlay.set_enabled(s, ctx.hall.id, true)
      assert {:error, :forbidden} = FairPlay.analyse_round(s, ctx.tournament, 1)
      assert {:error, :forbidden} = FairPlay.tournaments(s, ctx.hall.id)

      # The settings are still the owner's alone.
      refute reached?(
               reach(build_conn(), ctx.arbiter, ctx.hall, ~p"/halls/#{ctx.hall.id}/fair-play")
             )
    end

    test "a hall's grant covers its reports and puts fair play in the menu", ctx do
      share(ctx, {:hall, ctx.hall.id}, :viewer)
      s = scope(ctx.viewer, ctx.hall)

      assert s.fair_play_shared?
      assert FairPlay.can_view?(s, ctx.tournament)
      assert {:ok, [_]} = FairPlay.shared_tournaments(s, ctx.hall.id)

      {:ok, view, _} = reach(build_conn(), ctx.viewer, ctx.hall, ~p"/fair-play")
      assert has_element?(view, "#fair-play-shared")
      assert has_element?(view, "#nav-fair_play")
      refute has_element?(view, "#fair-play-hall-#{ctx.hall.id}")
    end

    test "an expired grant opens nothing", ctx do
      grant = share(ctx, ctx.tournament, :arbiter)

      Repo.update_all(from(g in Grant, where: g.id == ^grant.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(:second), -60, :second)]
      )

      refute FairPlay.can_view?(scope(ctx.arbiter, ctx.hall), ctx.tournament)
      refute reached?(reach(build_conn(), ctx.arbiter, ctx.hall, report(ctx)))
      refute scope(ctx.arbiter, ctx.hall).fair_play_shared?
    end

    test "a revoked grant opens nothing", ctx do
      grant = share(ctx, ctx.tournament, :arbiter)
      {:ok, _} = Grants.revoke(scope(ctx.owner, ctx.hall), grant.id)

      refute FairPlay.can_view?(scope(ctx.arbiter, ctx.hall), ctx.tournament)
      refute reached?(reach(build_conn(), ctx.arbiter, ctx.hall, report(ctx)))
    end

    test "somebody taken off the hall loses what was shared with them", ctx do
      share(ctx, ctx.tournament, :arbiter)

      Repo.delete_all(
        from m in Halls.Member, where: m.user_id == ^ctx.arbiter.id and m.hall_id == ^ctx.hall.id
      )

      refute FairPlay.can_view?(Accounts.scope(ctx.arbiter, nil), ctx.tournament)
    end

    test "a grant for one report opens no other", ctx do
      share(ctx, ctx.tournament, :arbiter)
      second = Repo.insert!(%Alnasl.Tournaments.Tournament{hall_id: ctx.hall.id})
      refute FairPlay.can_view?(scope(ctx.arbiter, ctx.hall), second)
    end

    test "the hosted admin gets nothing by being the admin", ctx do
      share(ctx, {:hall, ctx.hall.id}, :arbiter)
      s = scope(ctx.admin, ctx.hall)

      refute FairPlay.can_view?(s, ctx.tournament)
      assert {:error, :forbidden} = FairPlay.moves(s, ctx.tournament)
      refute reached?(reach(build_conn(), ctx.admin, ctx.hall, report(ctx)))
    end

    test "a stranger gets nothing, even with a grant's hall in the address", ctx do
      refute FairPlay.can_view?(scope(ctx.stranger, ctx.other), ctx.tournament)
      refute reached?(reach(build_conn(), ctx.stranger, ctx.other, report(ctx)))
      refute reached?(reach(build_conn(), ctx.stranger, ctx.other, ~p"/fair-play"))
    end

    test "nobody signed in gets nothing", %{conn: conn} = ctx do
      share(ctx, ctx.tournament, :arbiter)
      refute FairPlay.can_view?(nil, ctx.tournament)
      assert {:error, {_, %{to: to}}} = live(conn, report(ctx))
      refute to =~ "fair-play"
      assert Repo.aggregate(from(v in View, where: v.action == "view"), :count) == 0
    end
  end

  describe "the owner's pages" do
    test "the owner shares the hall from the settings and stops it", ctx do
      {:ok, view, _} =
        reach(build_conn(), ctx.owner, ctx.hall, ~p"/halls/#{ctx.hall.id}/fair-play")

      view
      |> form("#fair-play-sharing-form", grant: %{user_id: ctx.viewer.id, days: 10})
      |> render_submit()

      assert [grant] = Repo.all(Grant)
      assert grant.tournament_id == nil and grant.upload_id == nil
      assert has_element?(view, "#grant-#{grant.id}", "viewer-a@example.org")

      view |> element("#revoke-#{grant.id}") |> render_click()
      assert Repo.get(Grant, grant.id).revoked_at
      assert has_element?(view, "#fair-play-hall-audit", "stopped sharing")
    end

    test "the owner shares one report from the report", ctx do
      {:ok, view, _} = reach(build_conn(), ctx.owner, ctx.hall, report(ctx))

      view
      |> form("#fair-play-share-form", grant: %{user_id: ctx.arbiter.id, days: 5})
      |> render_submit()

      assert [%Grant{tournament_id: tid}] = Repo.all(Grant)
      assert tid == ctx.tournament.id
    end

    @tag :tmp_dir
    test "the owner uploads a PGN and lands on its report; a grantee of it reads it",
         %{tmp_dir: dir} = ctx do
      engine = Path.join(dir, "engine")
      File.write!(engine, "")
      switch_on(ctx.hall.id, engine)

      {:ok, view, _} =
        reach(build_conn(), ctx.owner, ctx.hall, ~p"/halls/#{ctx.hall.id}/fair-play")

      sans = random_sans(20, 3)

      moves =
        sans
        |> Enum.chunk_every(2)
        |> Enum.with_index(1)
        |> Enum.map_join(" ", fn {pair, n} -> "#{n}. " <> Enum.join(pair, " ") end)

      text =
        ~s([Event "Blitz"]\n[White "A"]\n[Black "B"]\n[WhiteElo "2000"]\n\n) <> moves <> " *\n"

      pgn =
        file_input(view, "#fair-play-pgn-form", :pgn, [
          %{name: "blitz.pgn", content: text, type: "application/vnd.chess-pgn"}
        ])

      render_upload(pgn, "blitz.pgn")

      view
      |> form("#fair-play-pgn-form", pgn: %{tournament_id: "", name: ""})
      |> render_submit()

      upload = Repo.one!(Alnasl.FairPlay.Upload)
      assert_redirect(view, ~p"/fair-play/pgn/#{upload.id}")
      assert upload.name == "Blitz"

      {:ok, page, _} = reach(build_conn(), ctx.owner, ctx.hall, ~p"/fair-play/pgn/#{upload.id}")
      assert has_element?(page, "#fair-play-upload-progress")
      assert has_element?(page, "#fair-play-upload-problems")
      assert has_element?(page, "#fair-play-delete-upload")

      refute reached?(reach(build_conn(), ctx.viewer, ctx.hall, ~p"/fair-play/pgn/#{upload.id}"))
      share(ctx, upload, :viewer)

      {:ok, shared, _} =
        reach(build_conn(), ctx.viewer, ctx.hall, ~p"/fair-play/pgn/#{upload.id}")

      refute has_element?(shared, "#fair-play-delete-upload")
      refute reached?(reach(build_conn(), ctx.viewer, ctx.hall, report(ctx)))
    end

    test "the report says plainly when the engine is not calibrated", ctx do
      {:ok, view, _} = reach(build_conn(), ctx.owner, ctx.hall, report(ctx))
      assert has_element?(view, "#fair-play-uncalibrated")
    end
  end
end
