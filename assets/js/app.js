// Alnasl's management site: LiveView. (The theme is js/theme.js, loaded before the page paints.)

import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"
// Hooks written beside the template that uses them (the phone pages).
import {hooks as colocatedHooks} from "phoenix-colocated/alnasl"

const Hooks = {}

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
