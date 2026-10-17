defmodule AlnaslWeb.HelpLive do
  @moduledoc """
  The in-app user manual: `/help` (the contents), `/help/:chapter` (one chapter
  of `Alnasl.Manual`, i.e. `priv/manual/*.md`) and `/help?q=...` (a search
  across every chapter). Built the way OpenPairings' manual is, on purpose:
  an arbiter who knows one knows the other.

  The manual is in the box's language (`@locale`, the English / Dutch switch
  in the rail); a chapter with no translation is shown in English. The page
  chrome around it is gettext.

  ## The page

  Three columns on a wide screen: the chapters (in three parts), the chapter
  in a reading column, and its outline. The outline folds above the chapter on
  a narrower screen, and the chapter list folds behind a button on a phone.
  The colocated `.Manual` hook does what the server cannot: the outline's
  scroll-spy, the `/` and Ctrl+K search shortcut and copying a heading's link.
  All of it is progressive: without JavaScript every link, the search (a GET
  form) and every heading still work.

  Beside the titles of the other pages sits a small "?"
  (`AlnaslWeb.Components.ManualLink`) that opens the chapter and section
  about that page.
  """
  use AlnaslWeb, :live_view

  alias Alnasl.Manual

  @impl true
  def mount(_params, _session, socket) do
    locale = socket.assigns.locale

    {:ok,
     assign(socket,
       manual_locale: locale,
       chapters: Manual.chapters(locale),
       chapter: nil,
       previous: nil,
       next: nil,
       query: "",
       results: [],
       search_form: to_form(%{"q" => ""}, as: :search),
       page_title: gettext("Help")
     )}
  end

  @impl true
  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_params(%{"chapter" => slug}, _uri, socket) do
    case Manual.get(slug, socket.assigns.manual_locale) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That help chapter does not exist."))
         |> push_navigate(to: ~p"/help")}

      chapter ->
        {previous, next} = Manual.neighbours(slug, socket.assigns.manual_locale)

        {:noreply,
         socket
         |> assign(
           chapter: chapter,
           previous: previous,
           next: next,
           page_title: gettext("Help") <> " - " <> chapter.title
         )
         |> assign_search("")}
    end
  end

  def handle_params(params, _uri, socket) do
    query = params |> Map.get("q", "") |> to_string() |> String.slice(0, 100)

    {:noreply,
     socket
     |> assign(chapter: nil, previous: nil, next: nil, page_title: gettext("Help"))
     |> assign_search(query)}
  end

  @impl true
  def handle_event("search", %{"search" => %{"q" => q}}, socket) do
    q = q |> to_string() |> String.slice(0, 100)

    cond do
      String.trim(q) == "" and socket.assigns.chapter != nil ->
        {:noreply, assign_search(socket, q)}

      String.trim(q) == "" ->
        {:noreply, push_patch(socket, to: ~p"/help", replace: true)}

      true ->
        {:noreply, push_patch(socket, to: ~p"/help?#{[q: q]}", replace: true)}
    end
  end

  defp assign_search(socket, query) do
    assign(socket,
      query: query,
      results: Manual.search(query, 30, socket.assigns.manual_locale),
      search_form: to_form(%{"q" => query}, as: :search)
    )
  end

  # The three parts of the manual, by chapter number.
  defp parts(chapters) do
    [
      {"part-setting-up", gettext("Setting up"), 1..3},
      {"part-round", gettext("During and after the round"), 4..5},
      {"part-people", gettext("People, records and repairs"), 6..99}
    ]
    |> Enum.map(fn {id, name, range} ->
      {id, name, Enum.filter(chapters, &(&1.number in range))}
    end)
    |> Enum.reject(fn {_, _, list} -> list == [] end)
  end

  defp part_name(chapters, chapter) do
    Enum.find_value(parts(chapters), fn {_, name, list} ->
      if Enum.any?(list, &(&1.slug == chapter.slug)), do: name
    end)
  end

  defp reading_minutes(chapter) do
    words =
      chapter.sections
      |> Enum.map(&(&1.text |> String.split() |> length()))
      |> Enum.sum()

    max(1, round(words / 200))
  end

  defp result_path(%{chapter: chapter, section_id: nil}), do: ~p"/help/#{chapter.slug}"

  defp result_path(%{chapter: chapter, section_id: id}),
    do: ~p"/help/#{chapter.slug}" <> "#" <> id

  attr :parts, :list, required: true

  defp marked(assigns) do
    ~H"""
    <%= for {text, matched?} <- @parts do %>
      <mark :if={matched?}>{text}</mark><span :if={!matched?}>{text}</span>
    <% end %>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={:help}
      link={@link}
      hall={@hall}
      update={@update}
      box={@box}
      locale={@locale}
      scope={@current_scope}
      path={@current_path}
      title={gettext("Help")}
    >
      <div
        id="manual"
        class={["manual-shell", @chapter && "has-outline"]}
        phx-hook=".Manual"
        data-copied={gettext("Link copied")}
      >
        <aside id="manual-sidebar" class="manual-sidebar" aria-label={gettext("User manual")}>
          <div class="manual-sidebar-inner">
            <.link navigate={~p"/help"} class="manual-brand" id="manual-home">
              <span class="manual-brand-mark" aria-hidden="true">
                <.icon name="book" />
              </span>
              <span>
                <span class="manual-brand-title">{gettext("User manual")}</span>
                <span class="manual-brand-sub">Alnasl</span>
              </span>
            </.link>

            <form
              id="manual-search"
              class="manual-search"
              role="search"
              action={~p"/help"}
              method="get"
              phx-change="search"
              phx-submit="search"
            >
              <span class="manual-search-icon" aria-hidden="true"><.icon name="search" /></span>
              <input
                type="search"
                id="manual-search-input"
                class="manual-search-input"
                name={@search_form[:q].name}
                value={@search_form[:q].value}
                placeholder={gettext("Search the manual")}
                aria-label={gettext("Search the manual")}
                autocomplete="off"
                phx-debounce="200"
              /> <span class="manual-search-key" aria-hidden="true"><kbd>/</kbd></span>
            </form>

            <button
              type="button"
              id="manual-nav-toggle"
              class="manual-nav-toggle"
              aria-controls="manual-toc"
              aria-expanded="false"
              phx-click={
                JS.toggle_class("is-open", to: "#manual-sidebar")
                |> JS.toggle_attribute({"aria-expanded", "true", "false"})
              }
            >
              <.icon name="bars" />
              <span class="manual-nav-toggle-label">
                {if @chapter,
                  do: gettext("Chapter %{n}: %{title}", n: @chapter.number, title: @chapter.title),
                  else: gettext("Chapters")}
              </span>
              <.icon name="chevron" class="manual-nav-toggle-chevron" />
            </button>

            <nav id="manual-toc" class="manual-toc" aria-label={gettext("Manual contents")}>
              <div :for={{id, name, list} <- parts(@chapters)} class="manual-part" id={id}>
                <h2 class="manual-part-title">{name}</h2>

                <ol class="manual-toc-list">
                  <li :for={c <- list}>
                    <.link
                      id={"manual-toc-#{c.slug}"}
                      navigate={~p"/help/#{c.slug}"}
                      aria-current={@chapter && @chapter.slug == c.slug && "page"}
                      class={["manual-toc-link", @chapter && @chapter.slug == c.slug && "current"]}
                    >
                      <span class="manual-toc-number" aria-hidden="true">{c.number}</span>
                      <span class="manual-toc-text">{c.title}</span>
                    </.link>
                  </li>
                </ol>
              </div>
            </nav>
          </div>
        </aside>

        <%= cond do %>
          <% String.trim(@query) != "" -> %>
            <section
              id="manual-results"
              class="manual-main manual-results"
              aria-labelledby="manual-results-title"
            >
              <nav class="manual-breadcrumb" aria-label={gettext("Breadcrumb")}>
                <ol>
                  <li><.link navigate={~p"/help"}>{gettext("Help")}</.link></li>

                  <li aria-current="page">{gettext("Search")}</li>
                </ol>
              </nav>

              <h2 id="manual-results-title" class="manual-title">
                {gettext("Search results")}
              </h2>

              <p class="manual-results-count" role="status" aria-live="polite">
                {ngettext(
                  "One section matches \"%{query}\".",
                  "%{count} sections match \"%{query}\".",
                  length(@results),
                  query: @query
                )}
              </p>

              <ol :if={@results != []} class="manual-results-list" lang={@manual_locale}>
                <li :for={{r, i} <- Enum.with_index(@results)}>
                  <.link
                    navigate={result_path(r)}
                    id={"manual-result-#{i}"}
                    class="manual-result"
                  >
                    <span class="manual-result-where">
                      <span class="manual-result-chapter">
                        {r.chapter.number}. {r.chapter.title}
                      </span>
                    </span>
                    <span class="manual-result-heading"><.marked parts={r.heading_parts} /></span>
                    <span class="manual-result-snippet"><.marked parts={r.snippet_parts} /></span>
                  </.link>
                </li>
              </ol>

              <div :if={@results == []} id="manual-no-results" class="manual-empty">
                <.icon name="search" />
                <p>
                  {gettext(
                    "Nothing in the manual matches every word. Try fewer or shorter words, or browse the chapters."
                  )}
                </p>
              </div>
            </section>
          <% @chapter -> %>
            <article
              id="manual-chapter"
              class="manual-main manual-chapter"
              aria-labelledby="manual-chapter-title"
            >
              <nav class="manual-breadcrumb" aria-label={gettext("Breadcrumb")}>
                <ol>
                  <li><.link navigate={~p"/help"}>{gettext("Help")}</.link></li>

                  <li>{part_name(@chapters, @chapter)}</li>

                  <li aria-current="page">{@chapter.title}</li>
                </ol>
              </nav>

              <header class="manual-chapter-head">
                <p class="manual-eyebrow">
                  <span class="manual-chapter-number">
                    {gettext("Chapter %{n}", n: @chapter.number)}
                  </span>

                  <span class="manual-reading-time">
                    {ngettext("1 minute read", "%{count} minutes read", reading_minutes(@chapter))}
                  </span>
                </p>

                <h2
                  id="manual-chapter-title"
                  class="manual-title manual-chapter-title"
                  lang={@manual_locale}
                >
                  {@chapter.title}
                </h2>
              </header>

              <nav
                :if={@chapter.toc != []}
                id="manual-chapter-toc"
                class="manual-outline"
                aria-label={gettext("On this page")}
              >
                <button
                  type="button"
                  id="manual-outline-toggle"
                  class="manual-outline-toggle"
                  aria-expanded="false"
                  aria-controls="manual-outline-list"
                  phx-click={
                    JS.toggle_class("is-open", to: "#manual-chapter-toc")
                    |> JS.toggle_attribute({"aria-expanded", "true", "false"})
                  }
                >
                  {gettext("On this page")} <.icon name="chevron" class="manual-chevron" />
                </button>

                <p class="manual-outline-title" aria-hidden="true">{gettext("On this page")}</p>

                <ul id="manual-outline-list" class="manual-outline-list" lang={@manual_locale}>
                  <li :for={h <- @chapter.toc} class={"level-#{h.level}"}>
                    <a href={"##{h.id}"} data-outline={h.id}>{h.text}</a>
                  </li>
                </ul>

                <a href="#main" class="manual-outline-top">
                  {gettext("Back to top")}
                </a>
              </nav>

              <div id="manual-chapter-body" class="manual-prose" lang={@manual_locale}>
                {raw(@chapter.html)}
              </div>

              <nav class="manual-pager" aria-label={gettext("Previous and next chapter")}>
                <.link
                  :if={@previous}
                  id="manual-previous"
                  navigate={~p"/help/#{@previous.slug}"}
                  class="manual-pager-link prev"
                  rel="prev"
                >
                  <span class="manual-pager-dir">
                    <.icon name="arrow" class="manual-arrow-back" /> {gettext("Previous")}
                  </span>
                  <span class="manual-pager-title">{@previous.number}. {@previous.title}</span>
                </.link>

                <.link
                  :if={@next}
                  id="manual-next"
                  navigate={~p"/help/#{@next.slug}"}
                  class="manual-pager-link next"
                  rel="next"
                >
                  <span class="manual-pager-dir">
                    {gettext("Next")} <.icon name="arrow" />
                  </span>
                  <span class="manual-pager-title">{@next.number}. {@next.title}</span>
                </.link>
              </nav>
            </article>
          <% true -> %>
            <section
              id="manual-index"
              class="manual-main manual-index"
              aria-labelledby="manual-index-title"
            >
              <header class="manual-hero">
                <p class="manual-eyebrow">{gettext("Help")}</p>

                <h2 id="manual-index-title" class="manual-title">
                  {gettext("The Alnasl user manual")}
                </h2>

                <p class="manual-lede">
                  {gettext(
                    "Everything Alnasl does, from the first board to the last PGN, written for the arbiter in the hall. New here? Start with Getting started."
                  )}
                </p>

                <p class="manual-hero-actions">
                  <.button navigate={~p"/help/getting-started"} variant="primary" id="manual-start">
                    {gettext("Getting started")} <.icon name="arrow" />
                  </.button>

                  <span class="manual-hint">
                    {gettext("Press")} <kbd>/</kbd> {gettext("to search")}
                  </span>
                </p>
              </header>

              <section
                :for={{id, name, list} <- parts(@chapters)}
                class="manual-index-part"
                aria-labelledby={"#{id}-index"}
              >
                <h3 id={"#{id}-index"} class="manual-index-part-title">{name}</h3>

                <ol class="manual-index-list" lang={@manual_locale}>
                  <li :for={c <- list}>
                    <.link
                      id={"manual-index-#{c.slug}"}
                      navigate={~p"/help/#{c.slug}"}
                      class="manual-card"
                    >
                      <span class="manual-card-number" aria-hidden="true">{c.number}</span>
                      <span class="manual-card-body">
                        <span class="manual-card-title">{c.title}</span>
                        <span class="manual-card-summary">{c.summary}</span>
                      </span>
                    </.link>
                  </li>
                </ol>
              </section>
            </section>
        <% end %>

        <div
          id="manual-copied"
          class="manual-toast"
          role="status"
          aria-live="polite"
          phx-update="ignore"
        >
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Manual">
        export default {
          mounted() {
            this.reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches
            this.onKey = (e) => this.key(e)
            this.onScroll = () => {
              if (this.ticking) return
              this.ticking = true
              requestAnimationFrame(() => { this.ticking = false; this.spy() })
            }
            this.onClick = (e) => this.click(e)
            window.addEventListener("keydown", this.onKey)
            window.addEventListener("scroll", this.onScroll, {passive: true})
            this.el.addEventListener("click", this.onClick)
            this.scrollToHash()
            this.spy()
          },
          updated() { this.spy() },
          destroyed() {
            window.removeEventListener("keydown", this.onKey)
            window.removeEventListener("scroll", this.onScroll)
          },
          behavior() { return this.reduced ? "auto" : "smooth" },
          scrollToHash() {
            const id = decodeURIComponent(window.location.hash.slice(1))
            if (!id) return
            const target = document.getElementById(id)
            if (target) requestAnimationFrame(() => target.scrollIntoView({block: "start"}))
          },
          // The outline entry of the last heading above the top fifth of the
          // window is the one being read.
          spy() {
            const links = this.el.querySelectorAll("[data-outline]")
            if (!links.length) return
            const line = window.innerHeight * 0.2
            let current = null
            const heads = this.el.querySelectorAll("#manual-chapter-body h2[id], #manual-chapter-body h3[id]")
            heads.forEach(h => { if (h.getBoundingClientRect().top <= line) current = h.id })
            if (window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 2) {
              heads.forEach(h => { if (h.getBoundingClientRect().top < window.innerHeight) current = h.id })
            }
            if (!current && links[0]) current = links[0].dataset.outline
            links.forEach(a => {
              const on = a.dataset.outline === current
              a.classList.toggle("is-active", on)
              if (on) a.setAttribute("aria-current", "location")
              else a.removeAttribute("aria-current")
            })
          },
          key(e) {
            const input = document.getElementById("manual-search-input")
            if (!input) return
            const t = e.target
            const typing = t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName))
            if ((e.key === "k" || e.key === "K") && (e.ctrlKey || e.metaKey)) {
              e.preventDefault(); input.focus(); input.select(); return
            }
            if (e.key === "/" && !typing && !e.altKey && !e.ctrlKey && !e.metaKey) {
              e.preventDefault(); input.focus(); input.select(); return
            }
            if (e.key === "Escape" && t === input) input.blur()
          },
          click(e) {
            const anchor = e.target.closest("a.manual-anchor")
            if (anchor) this.copyLink(e, anchor)
          },
          copyLink(e, anchor) {
            e.preventDefault()
            const id = anchor.getAttribute("href").slice(1)
            const url = window.location.origin + window.location.pathname + "#" + id
            history.replaceState(history.state, "", "#" + id)
            const heading = document.getElementById(id)
            if (heading) heading.scrollIntoView({behavior: this.behavior(), block: "start"})
            const toast = document.getElementById("manual-copied")
            const done = () => {
              if (!toast) return
              toast.textContent = this.el.dataset.copied
              toast.classList.add("is-shown")
              clearTimeout(this.toastTimer)
              this.toastTimer = setTimeout(() => toast.classList.remove("is-shown"), 1800)
            }
            if (navigator.clipboard && window.isSecureContext) {
              navigator.clipboard.writeText(url).then(done, () => {})
            }
          }
        }
      </script>
    </Layouts.app>
    """
  end
end
