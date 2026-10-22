defmodule AlnaslWeb.E2E.TourTest do
  @moduledoc """
  The guided tour as a person meets it: offered on the first visit, then
  walked from the first stop to the last, across the pages it lives on.
  The pointing is all in the browser (the `.Tour` hook, sessionStorage, live
  navigation between stops), which is exactly the part
  test/alnasl_web/live/tour_test.exs cannot see.
  """
  use AlnaslWeb.E2ECase

  alias Alnasl.Settings

  # A box without accounts gets every stop (AlnaslWeb.TourTest says so).
  @stops [
    {"places", "/"},
    {"wizard", "/setup/wizard"},
    {"bridges", :bridges},
    {"connections", "/setup/connections"},
    {"tournaments", "/setup/tournaments"},
    {"boards", "/boards"},
    {"numbering", "/boards"},
    {"ready", "/boards"},
    {"live", "/"},
    {"results", "/outbox"},
    {"fair_play", "/fair-play"},
    {"help", "/help"}
  ]

  test "taken from the offer and walked to the end, page by page", %{conn: conn} do
    count = length(@stops)

    conn =
      conn
      |> visit("/")
      |> assert_has("body .phx-connected")
      |> assert_has("#tour-offer")
      |> click("#tour-offer-start")
      |> refute_has("#tour-offer")

    conn =
      @stops
      |> Enum.with_index(1)
      |> Enum.reduce(conn, fn {{key, path}, n}, conn ->
        conn
        |> assert_has("#tour-pop[data-step='#{key}']")
        |> assert_has("#tour-pop .tour-pop-count", text: "Step #{n} of #{count}")
        |> assert_path(path(path))
        |> click(if n == count, do: "#tour-done", else: "#tour-next")
      end)

    conn
    |> refute_has("#tour-pop")
    |> refute_has("#tour-offer")

    assert eventually(fn -> Settings.get("tour") == "finished" end)
  end

  test "Back goes back, and Skip leaves it, remembered", %{conn: conn} do
    conn
    |> visit("/")
    |> assert_has("body .phx-connected")
    |> click("#tour-offer-start")
    |> assert_has("#tour-pop[data-step='places']")
    |> click("#tour-next")
    |> assert_has("#tour-pop[data-step='wizard']")
    |> assert_path("/setup/wizard")
    |> click("#tour-back")
    |> assert_has("#tour-pop[data-step='places']")
    |> click("#tour-skip")
    |> refute_has("#tour-pop")

    assert eventually(fn -> Settings.get("tour") == "dismissed" end)
  end

  test "Not now: no offer on the next page, and the account menu still starts it", %{conn: conn} do
    conn
    |> visit("/")
    |> assert_has("body .phx-connected")
    |> click("#tour-offer-dismiss")
    |> refute_has("#tour-offer")
    |> visit("/boards")
    |> assert_has("body .phx-connected")
    |> refute_has("#tour-offer")
    |> click("#account-button")
    |> click("#tour-start")
    |> assert_has("#tour-pop[data-step='places']")
    # From /boards, the first stop is back on the front page.
    |> assert_path("/")

    # Answered once, so never offered again, whatever became of it after.
    assert eventually(fn -> Settings.get("tour") == "started" end)
  end

  defp path(:bridges), do: "/halls/#{Alnasl.Halls.own_id()}/bridges"
  defp path(path), do: path

  # The server hears "tour_finish" a moment after the popover goes.
  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> receive(after: (50 -> eventually(fun, tries - 1)))
    end
  end
end
