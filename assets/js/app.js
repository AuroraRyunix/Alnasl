// Alnasl's management site: LiveView, and the light/dark switch.

import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/alnasl"
import topbar from "../vendor/topbar"

// The theme follows the system until the arbiter picks one; the pick is kept
// in this browser.
const stored = (() => { try { return localStorage.getItem("alnasl-theme") } catch (_e) { return null } })()
if (stored === "light" || stored === "dark") document.documentElement.dataset.theme = stored

window.addEventListener("alnasl:theme", () => {
  const root = document.documentElement
  const dark = root.dataset.theme
    ? root.dataset.theme === "dark"
    : window.matchMedia("(prefers-color-scheme: dark)").matches
  root.dataset.theme = dark ? "light" : "dark"
  try { localStorage.setItem("alnasl-theme", root.dataset.theme) } catch (_e) { /* private mode */ }
})

const Hooks = {
  // Keeps a scrolling list at its end as lines are added: the move list.
  StickToEnd: {
    mounted() { this.el.scrollTop = this.el.scrollHeight },
    updated() { this.el.scrollTop = this.el.scrollHeight },
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
})

topbar.config({barColors: {0: "#0a5967"}, shadowColor: "rgba(0, 0, 0, .25)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

liveSocket.connect()
window.liveSocket = liveSocket
