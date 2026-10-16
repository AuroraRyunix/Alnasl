defmodule AlnaslWeb.HelpTest do
  @moduledoc """
  The manual at /help: the contents and every chapter render in both
  languages, the search finds things, and no link in it (chapter to chapter,
  or the "?" beside a page title) points at a chapter or a heading that is not
  there.
  """

  use AlnaslWeb.SiteCase

  alias Alnasl.{Manual, Settings}
  alias AlnaslWeb.Components.ManualLink

  setup do
    on_exit(fn -> Settings.put("locale", "en") end)
    :ok
  end

  defp use_locale(locale), do: Settings.put("locale", locale)

  describe "the contents" do
    for locale <- ~w(en nl) do
      test "renders in #{locale} with a card for every chapter", %{conn: conn} do
        use_locale(unquote(locale))
        {:ok, view, _html} = live(conn, ~p"/help")

        assert has_element?(view, "#manual-index")
        assert has_element?(view, "#manual-start")

        for chapter <- Manual.chapters(unquote(locale)) do
          assert has_element?(view, "#manual-index-#{chapter.slug}")
          assert has_element?(view, "#manual-toc-#{chapter.slug}")
        end
      end
    end

    test "the chapters are the same ones in both languages" do
      assert Enum.map(Manual.chapters("en"), & &1.slug) ==
               Enum.map(Manual.chapters("nl"), & &1.slug)

      assert length(Manual.slugs()) >= 7
    end
  end

  describe "a chapter" do
    for locale <- ~w(en nl), slug <- Manual.slugs() do
      test "#{slug} renders in #{locale}", %{conn: conn} do
        use_locale(unquote(locale))
        {:ok, view, _html} = live(conn, ~p"/help/#{unquote(slug)}")
        chapter = Manual.get(unquote(slug), unquote(locale))

        assert has_element?(view, "#manual-chapter")
        assert has_element?(view, "#manual-chapter-title", chapter.title)
        assert has_element?(view, "#manual-chapter-body h2[id]")
        assert has_element?(view, "#manual-toc-#{unquote(slug)}[aria-current=page]")
      end
    end

    test "the Dutch chapters are really translated", %{conn: _conn} do
      for en <- Manual.chapters("en") do
        nl = Manual.get(en.slug, "nl")
        refute nl.title == en.title, "#{en.slug} has no Dutch title"
        refute nl.html == en.html, "#{en.slug} is still English"
      end
    end

    test "the Dutch chapters keep the English heading ids", %{conn: _conn} do
      for en <- Manual.chapters("en") do
        nl = Manual.get(en.slug, "nl")
        assert Enum.map(nl.toc, & &1.id) == Enum.map(en.toc, & &1.id), en.slug
      end
    end

    test "the Dutch manual speaks to the reader as je", %{conn: _conn} do
      for chapter <- Manual.chapters("nl") do
        text = chapter.sections |> Enum.map_join(" ", & &1.text)
        refute text =~ ~r/\b(u|uw)\b/, "#{chapter.slug} says u"
      end
    end

    test "previous and next lead along the whole manual", %{conn: conn} do
      slugs = Manual.slugs()
      {:ok, view, _html} = live(conn, ~p"/help/#{hd(slugs)}")
      refute has_element?(view, "#manual-previous")
      assert has_element?(view, "#manual-next")

      {:ok, view, _html} = live(conn, ~p"/help/#{List.last(slugs)}")
      assert has_element?(view, "#manual-previous")
      refute has_element?(view, "#manual-next")
    end

    test "an unknown chapter goes back to the contents", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/help"}}} = live(conn, ~p"/help/nonsense")
    end
  end

  describe "links" do
    test "every link between chapters, in both languages, reaches a chapter and a heading" do
      for locale <- ~w(en nl), chapter <- Manual.chapters(locale) do
        for [_, slug, anchor] <-
              Regex.scan(~r{href="/help/([a-z0-9-]+)(#[^"]*)?"}, chapter.html) |> Enum.map(&pad/1) do
          target = Manual.get(slug, locale)
          assert target, "#{locale}/#{chapter.slug} links to a chapter that is not there: #{slug}"

          if anchor != "" do
            ids = Enum.map(target.toc, &("#" <> &1.id))

            assert anchor in ids,
                   "#{locale}/#{chapter.slug} links to #{slug}#{anchor}, which has no such heading"
          end
        end
      end
    end

    test "the heading anchors of a chapter are unique", %{conn: _conn} do
      for locale <- ~w(en nl), chapter <- Manual.chapters(locale) do
        ids = Enum.map(chapter.toc, & &1.id)
        assert ids == Enum.uniq(ids), "#{locale}/#{chapter.slug}"
      end
    end

    test "every \"?\" beside a page title points at a chapter and a heading that exist" do
      for {topic, {slug, id}} <- ManualLink.targets(), locale <- ~w(en nl) do
        chapter = Manual.get(slug, locale)
        assert chapter, "#{topic}: no chapter #{slug}"
        assert id in Enum.map(chapter.toc, & &1.id), "#{topic}: no heading #{id} in #{slug}"
      end
    end

    test "the pages carry their \"?\" and it opens the manual", %{conn: conn} do
      for {path, topic} <- [
            {~p"/", :round},
            {~p"/boards", :boards},
            {~p"/outbox", :outbox},
            {~p"/pgn", :pgn},
            {~p"/recordings", :recordings},
            {~p"/log", :log},
            {~p"/halls", :halls},
            {~p"/setup", :setup},
            {~p"/boards/number", :numbering}
          ] do
        {:ok, view, _html} = live(conn, path)
        assert has_element?(view, "#manual-link-#{topic}[href='#{ManualLink.path(topic)}']"), path
      end
    end
  end

  describe "search" do
    test "finds a section and marks the words, and says when there is nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/help?q=bridge")
      assert has_element?(view, "#manual-results")
      assert has_element?(view, "#manual-result-0")
      assert has_element?(view, "#manual-results mark")

      {:ok, view, _html} = live(conn, ~p"/help?q=zzzqqxx")
      assert has_element?(view, "#manual-no-results")
    end

    test "typing in the search box patches to the results, and clearing it comes back", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/help")

      view |> form("#manual-search", search: %{q: "recordings"}) |> render_change()
      assert_patch(view, ~p"/help?#{[q: "recordings"]}")
      assert has_element?(view, "#manual-results")

      view |> form("#manual-search", search: %{q: ""}) |> render_change()
      assert_patch(view, ~p"/help")
      assert has_element?(view, "#manual-index")
    end

    test "searches the Dutch text in Dutch", %{conn: conn} do
      use_locale("nl")
      {:ok, view, _html} = live(conn, ~p"/help?q=brug")
      assert has_element?(view, "#manual-result-0")
    end
  end

  describe "who may read it" do
    test "a viewer can search the manual", %{conn: conn} do
      assert AlnaslWeb.Permit.needed(AlnaslWeb.HelpLive, "search") == :viewer
      {:ok, _view, html} = live(conn, ~p"/help")
      assert html =~ "manual-search"
    end
  end

  defp pad([whole, slug]), do: [whole, slug, ""]
  defp pad(other), do: other
end
