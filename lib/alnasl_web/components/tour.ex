defmodule AlnaslWeb.Components.Tour do
  @moduledoc """
  The guided tour on the page (`AlnaslWeb.Tour` decides what is in it).

  Three parts, all in the frame of every page:

    * the offer, a small card in a corner, once: "Take the tour" or "Not
      now". Never in the way of the page, never forced;
    * the steps, as a hidden list (`#tour-steps`): every word is the
      server's and translated, and a test can read which steps a role gets;
    * the `.Tour` hook, which points at the step's element with a popover
      (a panel docked above the tab bar on a phone), moves to the step's
      page with live navigation when it lives elsewhere, and says so when
      the element is not there yet.

  The server starts the tour by raising `data-run` (the offer's button, the
  account menu's "Take the tour"); the hook notices the change. Skip, Escape
  and Done go back as "tour_dismiss" and "tour_finish", and are remembered.
  """

  use Phoenix.Component
  use Gettext, backend: AlnaslWeb.Gettext

  import AlnaslWeb.CoreComponents, only: [icon: 1]

  alias AlnaslWeb.Tour

  attr :scope, :any, default: nil

  def tour(assigns) do
    assigns =
      assign(assigns,
        on?: match?(%{tour: %{}}, assigns.scope),
        steps: steps(assigns.scope)
      )

    ~H"""
    <div :if={@on?} id="tour-root">
      <section
        :if={Tour.offer?(@scope)}
        id="tour-offer"
        class="tour-offer"
        aria-labelledby="tour-offer-title"
      >
        <span class="tour-offer-icon" aria-hidden="true"><.icon name="help" /></span>
        <div class="tour-offer-text">
          <b id="tour-offer-title">{gettext("New here?")}</b>
          <span>
            {gettext(
              "A short tour of the pages, in the order a hall is set up and played. A couple of minutes; leave it whenever you like."
            )}
          </span>
        </div>
        <div class="tour-offer-actions">
          <button id="tour-offer-start" type="button" class="btn primary small" phx-click="tour_start">
            {gettext("Take the tour")}
          </button>
          <button id="tour-offer-dismiss" type="button" class="btn small" phx-click="tour_dismiss">
            {gettext("Not now")}
          </button>
        </div>
      </section>

      <div
        id="tour"
        phx-hook=".Tour"
        data-run={@scope.tour.run}
        data-of={gettext("Step %{n} of %{m}", n: "{n}", m: "{m}")}
        data-next={gettext("Next")}
        data-back={gettext("Back")}
        data-skip={gettext("Skip the tour")}
        data-done={gettext("Done")}
        data-close={gettext("Close the tour")}
        data-manual={gettext("Read more in the manual")}
        data-label={gettext("Guided tour")}
      >
        <ol id="tour-steps" hidden>
          <li
            :for={step <- @steps}
            id={"tour-step-#{step.key}"}
            data-key={step.key}
            data-path={step.path}
            data-anchor={Enum.join(step.anchor, ",")}
            data-fallback={Enum.join(step.fallback, ",")}
            data-manual={step.manual}
          >
            <b class="tour-step-title">{step.title}</b>
            <p class="tour-step-body">{step.body}</p>
            <p :if={step.empty} class="tour-step-empty">{step.empty}</p>
          </li>
        </ol>
        <div id="tour-live" class="sr-only" aria-live="polite" phx-update="ignore"></div>
        <div id="tour-layer" phx-update="ignore"></div>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".Tour">
        // The guided tour's pointing. Where the tour is lives in this tab
        // (sessionStorage), so it carries on across live navigation and is
        // gone with the tab; what became of it is the server's to remember.
        const KEY = "alnasl-tour"
        const PHONE = "(max-width: 860px)"
        const REDUCED = "(prefers-reduced-motion: reduce)"

        const load = () => {
          try { return JSON.parse(sessionStorage.getItem(KEY) || "null") } catch (_e) { return null }
        }
        const save = (state) => {
          try {
            if (state) sessionStorage.setItem(KEY, JSON.stringify(state))
            else sessionStorage.removeItem(KEY)
          } catch (_e) { /* a private window: the tour lasts as long as the page */ }
        }
        const shown = (el) => el && el.getClientRects().length > 0 && getComputedStyle(el).visibility !== "hidden"
        const find = (list) => {
          if (!list) return null
          for (const selector of list.split(",")) {
            let all = []
            try { all = document.querySelectorAll(selector.trim()) } catch (_e) { all = [] }
            const hit = Array.from(all).find((el) => shown(el) && !el.closest("#tour-root"))
            if (hit) return hit
          }
          return null
        }

        export default {
          mounted() {
            this.run = this.el.dataset.run
            this.onKey = (event) => this.key(event)
            this.onMove = () => this.place()
            document.addEventListener("keydown", this.onKey)
            window.addEventListener("resize", this.onMove)
            window.addEventListener("scroll", this.onMove, true)
            // Carry on where the tour took us. A page the tour did not lead
            // to is somebody leaving it by the rail: let them.
            const state = load()
            const step = state && state.active && this.steps()[state.i]
            if (step && (location.pathname === step.dataset.path || state.went === step.dataset.path)) {
              requestAnimationFrame(() => this.show(state.i, true))
            } else if (state) {
              save(null)
            }
          },
          updated() {
            if (this.el.dataset.run !== this.run) {
              this.run = this.el.dataset.run
              if (this.el.dataset.run !== "0") {
                this.opener = document.activeElement
                save({active: true, i: 0})
                this.show(0, false)
              }
            } else if (load()?.active) {
              this.place()
            }
          },
          destroyed() {
            document.removeEventListener("keydown", this.onKey)
            window.removeEventListener("resize", this.onMove)
            window.removeEventListener("scroll", this.onMove, true)
          },
          steps() { return Array.from(this.el.querySelectorAll("#tour-steps > li")) },

          show(i, arrived) {
            const steps = this.steps()
            if (steps.length === 0) return this.close(null)
            i = Math.max(0, Math.min(i, steps.length - 1))
            const step = steps[i]
            const path = step.dataset.path
            const state = load() || {active: true}
            // Another page: go there, and carry on when it is mounted. Once
            // only, so a page that sends us elsewhere does not loop.
            if (path && location.pathname !== path && state.went !== path) {
              save({active: true, i, went: path})
              this.js().navigate(path)
              return
            }
            save({active: true, i, went: arrived ? state.went : undefined})
            this.i = i
            this.draw(step, i, steps.length)
          },

          draw(step, i, count) {
            const d = this.el.dataset
            const target = find(step.dataset.anchor)
            const fallback = target ? null : find(step.dataset.fallback)
            this.target = target || fallback
            const layer = this.el.querySelector("#tour-layer")
            const title = step.querySelector(".tour-step-title").textContent
            const of = d.of.replace("{n}", i + 1).replace("{m}", count)
            const empty = !target && step.querySelector(".tour-step-empty")

            layer.innerHTML = ""
            const ring = document.createElement("div")
            ring.className = "tour-ring"
            ring.setAttribute("aria-hidden", "true")
            const pop = document.createElement("div")
            pop.className = "tour-pop"
            pop.id = "tour-pop"
            pop.setAttribute("role", "dialog")
            pop.setAttribute("aria-modal", "false")
            pop.setAttribute("aria-labelledby", "tour-pop-title")
            pop.setAttribute("aria-describedby", "tour-pop-body")
            pop.tabIndex = -1
            pop.dataset.step = step.dataset.key

            const head = document.createElement("div")
            head.className = "tour-pop-head"
            const count_ = document.createElement("span")
            count_.className = "tour-pop-count"
            count_.textContent = of
            const x = this.button(d.close, "tour-pop-close", () => this.close("tour_dismiss"))
            x.className = "tour-pop-x"
            x.setAttribute("aria-label", d.close)
            x.textContent = "×"
            head.append(count_, x)

            const h = document.createElement("h2")
            h.id = "tour-pop-title"
            h.textContent = title
            const body = document.createElement("div")
            body.id = "tour-pop-body"
            const p = document.createElement("p")
            p.textContent = step.querySelector(".tour-step-body").textContent
            body.append(p)
            if (empty) {
              const e = document.createElement("p")
              e.className = "tour-pop-empty"
              e.textContent = empty.textContent
              body.append(e)
            }
            const more = document.createElement("a")
            more.className = "tour-pop-manual"
            more.href = step.dataset.manual
            more.target = "_blank"
            more.rel = "noopener"
            more.textContent = d.manual

            const foot = document.createElement("div")
            foot.className = "tour-pop-foot"
            const skip = this.button(d.skip, "tour-skip", () => this.close("tour_dismiss"))
            skip.className = "linkish tour-pop-skip"
            const nav = document.createElement("span")
            nav.className = "tour-pop-nav"
            if (i > 0) nav.append(this.button(d.back, "tour-back", () => this.show(i - 1, false), "btn small"))
            const last = i === count - 1
            const next = last
              ? this.button(d.done, "tour-done", () => this.close("tour_finish"), "btn primary small")
              : this.button(d.next, "tour-next", () => this.show(i + 1, false), "btn primary small")
            nav.append(next)
            foot.append(skip, nav)

            pop.append(head, h, body, more, foot)
            layer.append(ring, pop)
            this.ring = ring
            this.pop = pop

            const live = this.el.querySelector("#tour-live")
            live.textContent = of + ": " + title

            if (this.target) {
              const smooth = !matchMedia(REDUCED).matches
              this.target.scrollIntoView({block: "center", inline: "nearest", behavior: smooth ? "smooth" : "auto"})
            }
            this.place()
            pop.focus({preventScroll: true})
          },

          button(text, id, action, cls) {
            const b = document.createElement("button")
            b.type = "button"
            b.id = id
            b.className = cls || ""
            b.textContent = text
            b.addEventListener("click", action)
            return b
          },

          place() {
            if (!this.pop || !this.pop.isConnected) return
            const pop = this.pop
            const ring = this.ring
            const docked = matchMedia(PHONE).matches
            const target = this.target && this.target.isConnected ? this.target : null
            pop.classList.toggle("docked", docked)
            pop.classList.toggle("floating", !docked && !target)

            if (!target) {
              ring.hidden = true
              pop.style.top = pop.style.left = ""
              return
            }
            const r = target.getBoundingClientRect()
            ring.hidden = false
            ring.style.top = r.top - 4 + "px"
            ring.style.left = r.left - 4 + "px"
            ring.style.width = r.width + 8 + "px"
            ring.style.height = r.height + 8 + "px"
            if (docked) {
              pop.style.top = pop.style.left = ""
              return
            }
            const gap = 12
            const w = pop.offsetWidth
            const h = pop.offsetHeight
            const vw = document.documentElement.clientWidth
            const vh = document.documentElement.clientHeight
            let top
            if (r.bottom + gap + h <= vh) top = r.bottom + gap
            else if (r.top - gap - h >= 0) top = r.top - gap - h
            else if (r.right + gap + w <= vw) {
              pop.style.left = r.right + gap + "px"
              pop.style.top = Math.max(8, Math.min(r.top, vh - h - 8)) + "px"
              return
            } else top = Math.max(8, vh - h - 8)
            const left = Math.max(8, Math.min(r.left, vw - w - 8))
            pop.style.top = top + "px"
            pop.style.left = left + "px"
          },

          key(event) {
            if (!this.pop || !this.pop.isConnected) return
            if (event.key === "Escape") {
              event.preventDefault()
              this.close("tour_dismiss")
              return
            }
            if (!this.pop.contains(document.activeElement)) return
            const tag = document.activeElement?.tagName
            if (event.key === "ArrowRight" && tag !== "INPUT") {
              event.preventDefault()
              const steps = this.steps()
              if (this.i < steps.length - 1) this.show(this.i + 1, false)
            } else if (event.key === "ArrowLeft" && tag !== "INPUT") {
              event.preventDefault()
              if (this.i > 0) this.show(this.i - 1, false)
            }
          },

          close(event) {
            save(null)
            const layer = this.el.querySelector("#tour-layer")
            if (layer) layer.innerHTML = ""
            this.pop = null
            this.target = null
            if (event) this.pushEvent(event, {})
            const back = this.opener && this.opener.isConnected && shown(this.opener) ? this.opener : document.querySelector("#main")
            if (back) {
              if (!back.hasAttribute("tabindex") && back.id === "main") back.tabIndex = -1
              back.focus({preventScroll: true})
            }
          },
        }
      </script>
    </div>
    """
  end

  defp steps(%{tour: %{}} = scope), do: Tour.steps(Tour.who(scope))
  defp steps(_scope), do: []
end
