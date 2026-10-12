defmodule Alnasl.ResultsSiteTest do
  @moduledoc "The addresses of the results site: only routes OpenResults has, whatever the site was typed as."

  use ExUnit.Case, async: true

  alias Alnasl.ResultsSite

  defp t(url, slug), do: %{server_url: url, slug: slug}

  test "the routes OpenResults has, for a site with and without a trailing slash" do
    for url <- [
          "https://results.example.org",
          "https://results.example.org/",
          "  https://results.example.org//  "
        ] do
      site = t(url, "open-2026")
      assert ResultsSite.tournament_url(site) == "https://results.example.org/t/open-2026"
      assert ResultsSite.live_url(site) == "https://results.example.org/t/open-2026/live"
      assert ResultsSite.round_url(site, 1) == "https://results.example.org/t/open-2026/live/1"

      assert ResultsSite.board_url(site, 3, 12) ==
               "https://results.example.org/t/open-2026/live/3/12"

      assert ResultsSite.round_pgn_url(site, 3) ==
               "https://results.example.org/t/open-2026/live/3/pgn"

      assert ResultsSite.board_pgn_url(site, 3, 12) ==
               "https://results.example.org/t/open-2026/live/3/12/pgn"
    end
  end

  test "a site under a port or a path keeps it" do
    assert ResultsSite.tournament_url(t("http://192.168.1.5:4000/", "x")) ==
             "http://192.168.1.5:4000/t/x"

    assert ResultsSite.round_url(t("https://example.org/results/", "x"), 2) ==
             "https://example.org/results/t/x/live/2"
  end

  test "a slug that needs escaping is one path segment" do
    site = t("https://r.test", "open 2026/b#1?x")
    assert ResultsSite.tournament_url(site) == "https://r.test/t/open%202026%2Fb%231%3Fx"

    assert ResultsSite.board_url(site, 1, 2) ==
             "https://r.test/t/open%202026%2Fb%231%3Fx/live/1/2"

    assert ResultsSite.tournament_url(t("https://r.test", "été")) ==
             "https://r.test/t/%C3%A9t%C3%A9"

    assert ResultsSite.tournament_url(t("https://r.test", " padded ")) ==
             "https://r.test/t/padded"
  end

  test "nothing to link to is nil, and says what is missing" do
    assert ResultsSite.why_not(t("", "x")) == :no_site
    assert ResultsSite.why_not(t(nil, "x")) == :no_site
    assert ResultsSite.why_not(t("results.example.org", "x")) == :no_site
    assert ResultsSite.why_not(t("ftp://results.example.org", "x")) == :no_site
    assert ResultsSite.why_not(t("https://results.example.org", "")) == :no_slug
    assert ResultsSite.why_not(t("https://results.example.org", "  ")) == :no_slug
    assert ResultsSite.why_not(t("https://results.example.org", "x")) == nil

    for site <- [t("", "x"), t("https://r.test", ""), t(nil, nil)] do
      refute ResultsSite.page?(site)
      assert ResultsSite.tournament_url(site) == nil
      assert ResultsSite.live_url(site) == nil
      assert ResultsSite.round_url(site, 1) == nil
      assert ResultsSite.board_url(site, 1, 1) == nil
      assert ResultsSite.display(site) == nil
    end

    assert ResultsSite.page?(t("https://r.test", "x"))
  end

  test "a round or a board that is not a number has no page" do
    site = t("https://r.test", "x")
    assert ResultsSite.round_url(site, nil) == nil
    assert ResultsSite.round_url(site, 0) == nil
    assert ResultsSite.board_url(site, 1, nil) == nil
    assert ResultsSite.board_url(site, 1, 0) == nil
    assert ResultsSite.round_pgn_url(site, nil) == nil
    assert ResultsSite.board_pgn_url(site, nil, 1) == nil
  end

  test "the address as people say it" do
    assert ResultsSite.display(t("https://results.example.org/", "open")) ==
             "results.example.org/t/open"
  end
end
