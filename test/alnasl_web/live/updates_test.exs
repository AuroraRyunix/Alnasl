defmodule AlnaslWeb.UpdatesTest do
  @moduledoc """
  The notice of a newer version on every page, and Setup's Updates panel:
  what it says before anything is fetched, what it refuses, and what it
  takes to be overruled. Also the switch for the hall's network, which an
  installed program needs in the same place.
  """

  use AlnaslWeb.SiteCase

  alias Alnasl.{FakeReleases, Listen, Updates}
  alias Alnasl.Updates.Checker

  setup do
    start_supervised!(FakeReleases)
    FakeReleases.install()
    Checker.forget()
    test = self()
    Application.put_env(:alnasl, :updates_stop_fun, &send(test, {:stopped, &1}))
    Application.put_env(:alnasl, :updates_stop_delay, 0)

    on_exit(fn ->
      FakeReleases.uninstall()
      Checker.forget()
      Application.put_env(:alnasl, :install_kind, :manual)
      Application.delete_env(:alnasl, :updates_stop_fun)
      Application.delete_env(:alnasl, :updates_stop_delay)
      File.rm(Path.join(Alnasl.Paths.data(), "listen"))
    end)

    :ok
  end

  defp newer do
    version = Version.parse!(Updates.current_version())
    "#{version.major}.#{version.minor + 1}.0"
  end

  defp heard_of_one(kind \\ :velopack) do
    Application.put_env(:alnasl, :install_kind, kind)
    FakeReleases.publish(newer())
    {:ok, _info} = Checker.check_now()
    :ok
  end

  defp game_on(port, number) do
    board = fake_dgt(port, %{round: 1, board_no: number})
    eventually(fn -> Boards.snapshot(board.id).connected? end)
    play_on(port, board.id, ~w(e4 e5))
    board
  end

  describe "the notice on every page" do
    test "is not there when there is nothing to say", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/boards")
      refute has_element?(view, "#update-banner")
    end

    test "names the version and the size, and leads to the notes and to Setup", %{conn: conn} do
      heard_of_one()

      for path <- [~p"/", ~p"/boards", ~p"/outbox", ~p"/log", ~p"/help", ~p"/setup"] do
        {:ok, view, _html} = live(conn, path)
        assert has_element?(view, "#update-banner", newer())
        assert has_element?(view, "#update-banner-size", "41 MB")
        assert has_element?(view, ~s(#update-banner-notes[href*="/releases/tag/v#{newer()}"]))
        assert has_element?(view, ~s(#update-banner-setup[href="/setup/updates"]))
      end
    end

    test "appears on a page that is already open when the box hears of a release", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/boards")
      refute has_element?(view, "#update-banner")

      heard_of_one()
      eventually_html(view, &(&1 =~ ~s(id="update-banner")))
    end

    test "\"Later\" puts it away, on this page and the next", %{conn: conn} do
      heard_of_one()
      {:ok, view, _html} = live(conn, ~p"/boards")

      view |> element("#update-banner-later") |> render_click()
      refute has_element?(view, "#update-banner")

      {:ok, other, _html} = live(conn, ~p"/log")
      refute has_element?(other, "#update-banner")
      # Setup still knows, for whoever goes looking.
      {:ok, setup, _html} = live(conn, ~p"/setup/updates")
      assert has_element?(setup, "#update-offer", newer())
    end

    test "\"Don't ask again\" switches the looking off, and Setup shows the switch", %{conn: conn} do
      heard_of_one()
      {:ok, view, _html} = live(conn, ~p"/boards")

      view |> element("#update-banner-never") |> render_click()
      refute has_element?(view, "#update-banner")
      assert Updates.mode() == "never"

      {:ok, setup, _html} = live(conn, ~p"/setup/updates")
      assert has_element?(setup, "#update-mode-never[checked]")
      refute has_element?(setup, "#update-banner")
    end

    test "a second click on a notice that is gone is not a crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/boards")
      render_click(view, "update_later")
      render_click(view, "update_never")
      assert has_element?(view, "#nav-boards")
    end
  end

  describe "Setup, Updates" do
    test "says which version this is and what the setting is", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup/updates")

      assert has_element?(view, "#update-version", Updates.current_version())
      assert has_element?(view, "#update-mode-ask[checked]")
      refute has_element?(view, "#update-offer")
    end

    test "the switch is kept", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup/updates")

      view |> element("#update-mode-form") |> render_change(%{"mode" => "never"})
      assert Updates.mode() == "never"
      assert has_element?(view, "#update-mode-never[checked]")

      view |> element("#update-mode-form") |> render_change(%{"mode" => "ask"})
      assert Updates.mode() == "ask"
    end

    test "\"Look now\" asks, and says what it found - also that it found nobody", %{conn: conn} do
      Application.put_env(:alnasl, :install_kind, :velopack)
      {:ok, view, _html} = live(conn, ~p"/setup/updates")

      FakeReleases.publish(Updates.current_version())
      view |> element("#check-update") |> render_click()
      assert has_element?(view, "#update-looked-current")

      FakeReleases.mode(:down)
      view |> element("#check-update") |> render_click()
      assert has_element?(view, "#update-looked-error")
      refute has_element?(view, "#update-offer")

      FakeReleases.mode(:ok)
      FakeReleases.publish(newer())
      view |> element("#check-update") |> render_click()
      assert has_element?(view, "#update-offer", newer())
      assert has_element?(view, "#update-size", "41 MB")
    end

    test "\"Look now\" works with the looking switched off: a button is a person", %{conn: conn} do
      Updates.put_mode("never")
      FakeReleases.publish(newer())
      {:ok, view, _html} = live(conn, ~p"/setup/updates")

      view |> element("#check-update") |> render_click()
      assert has_element?(view, "#update-offer", newer())
      refute has_element?(view, "#update-banner")
    end

    test "nothing is fetched on the first press: it says what the second will cost", %{conn: conn} do
      heard_of_one()
      {:ok, view, _html} = live(conn, ~p"/setup/updates")

      view |> element("#update-start") |> render_click()
      assert has_element?(view, "#update-confirm", "41 MB")
      refute_receive {:stopped, _code}, 100

      view |> element("#update-cancel") |> render_click()
      refute has_element?(view, "#update-confirm")
      assert has_element?(view, "#update-start")
      refute_receive {:stopped, _code}, 100
    end

    test "the yes hands over to the launcher, and the page says what happens next", %{conn: conn} do
      heard_of_one()
      {:ok, view, _html} = live(conn, ~p"/setup/updates")

      view |> element("#update-start") |> render_click()
      view |> element("#update-yes") |> render_click()

      assert has_element?(view, "#update-going")
      refute has_element?(view, "#update-yes")
      assert_receive {:stopped, 90}
    end

    test "a game in progress is a refusal in words, with the board's number", %{conn: conn} do
      heard_of_one()
      game_on("FAKE1", 3)
      {:ok, view, _html} = live(conn, ~p"/setup/updates")

      view |> element("#update-start") |> render_click()

      assert has_element?(view, "#update-games", "board 3")
      refute has_element?(view, "#update-yes")
      refute_receive {:stopped, _code}, 100

      # The way out that changes nothing is the obvious one.
      view |> element("#update-cancel") |> render_click()
      refute has_element?(view, "#update-games")
      refute_receive {:stopped, _code}, 100
    end

    test "the refusal is overruled only by the button that asks to be sure", %{conn: conn} do
      heard_of_one()
      game_on("FAKE1", 3)
      {:ok, view, _html} = live(conn, ~p"/setup/updates")

      view |> element("#update-start") |> render_click()
      assert has_element?(view, "#update-force[data-confirm]")

      view |> element("#update-force") |> render_click()
      assert has_element?(view, "#update-going")
      assert_receive {:stopped, 90}
    end

    test "a game that began after the question is still a refusal", %{conn: conn} do
      heard_of_one()
      {:ok, view, _html} = live(conn, ~p"/setup/updates")

      view |> element("#update-start") |> render_click()
      assert has_element?(view, "#update-confirm")

      game_on("FAKE1", 2)
      view |> element("#update-yes") |> render_click()

      assert has_element?(view, "#update-games", "board 2")
      refute_receive {:stopped, _code}, 100
    end

    test "a copy that cannot update itself is told how, and offered no button", %{conn: conn} do
      heard_of_one(:manual)
      {:ok, view, _html} = live(conn, ~p"/setup/updates")

      assert has_element?(view, "#update-manual", "sudo /opt/alnasl/update.sh")
      refute has_element?(view, "#update-start")
    end

    test "the Linux installation leaves its request and says so", %{conn: conn} do
      heard_of_one(:systemd)
      File.rm_rf!(Updates.request_dir())
      {:ok, view, _html} = live(conn, ~p"/setup/updates")

      view |> element("#update-start") |> render_click()
      view |> element("#update-yes") |> render_click()

      assert has_element?(view, "#update-going")
      assert File.read!(Path.join(Updates.request_dir(), "request")) == newer() <> "\n"
      refute_receive {:stopped, _code}, 100
    after
      File.rm_rf!(Updates.request_dir())
    end

    @tag :tmp_dir
    test "an update that failed and was undone says so", %{conn: conn, tmp_dir: dir} do
      file = Path.join(dir, "status")
      File.write!(file, "failed 9.9.9 the new version did not answer; 0.1.0 is running again\n")
      Application.put_env(:alnasl, :update_status_file, file)

      {:ok, view, _html} = live(conn, ~p"/setup/updates")
      assert has_element?(view, "#update-failed", "9.9.9")
      assert has_element?(view, "#update-failed", "did not answer")
    after
      Application.delete_env(:alnasl, :update_status_file)
    end

    test "\"Start with Windows\" is not offered where it means nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup/updates")
      refute has_element?(view, "#autostart-form")
    end
  end

  describe "the Dutch" do
    test "the notice and the panel are in Dutch when the box is", %{conn: conn} do
      heard_of_one()
      Settings.put("locale", "nl")
      {:ok, view, html} = live(conn, ~p"/setup/updates")

      assert has_element?(view, "#update-banner-later", "Later")
      assert has_element?(view, "#update-banner-never", "Niet meer vragen")
      assert html =~ "Downloaden en installeren"
      refute html =~ "Download and install"
    end
  end

  describe "the hall's network" do
    test "a box answers only itself, and the switch wants a PIN first", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup/access")

      assert Listen.chosen() == "local"
      assert has_element?(view, "#listen-lan[disabled]")
      assert has_element?(view, "#listen-needs-pin")

      # Not through the button either.
      render_click(view, "set_listen", %{"choice" => "lan"})
      assert Listen.chosen() == "local"
    end

    test "with a PIN it is one press, and it says it waits for the next start", %{conn: conn} do
      Settings.set_pin("2468")
      {:ok, view, _html} = live(conn, ~p"/setup/access")

      view |> element("#listen-lan") |> render_click()
      assert Listen.chosen() == "lan"
      assert has_element?(view, "#listen-pending")
      assert has_element?(view, "#listen-local")

      view |> element("#listen-local") |> render_click()
      assert Listen.chosen() == "local"
      refute has_element?(view, "#listen-pending")
    end
  end
end
