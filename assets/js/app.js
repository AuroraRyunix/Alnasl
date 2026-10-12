// Alnasl's management site: LiveView. (The theme is js/theme.js, loaded before the page paints.)

import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"
// Hooks written beside the template that uses them (the phone pages).
import {hooks as colocatedHooks} from "phoenix-colocated/alnasl"

// "Live · 2 ms" in the bar: this browser's connection to the box. The box is
// asked a question every few seconds and the time it takes to answer is the
// number; a socket that is down says so, and says it again as soon as it is
// back. (Written for this program; it measures the LiveView socket and
// nothing about the results server.)
const Hooks = {
  LivePill: {
    mounted() {
      this.word = this.el.querySelector(".live-word")
      this.ms = this.el.querySelector(".live-ms")
      this.measure()
      this.timer = setInterval(() => this.measure(), 5000)
    },
    measure() {
      const sent = performance.now()
      this.pushEvent("live_ping", {}, () => {
        this.show("live", Math.max(1, Math.round(performance.now() - sent)))
      })
    },
    show(state, ms) {
      this.el.dataset.state = state
      this.word.textContent = this.el.dataset[state === "live" ? "live" : "reconnecting"]
      this.ms.textContent = state === "live" && ms ? "· " + ms + " ms" : ""
    },
    disconnected() { this.show("reconnecting") },
    reconnected() { this.measure() },
    destroyed() { clearInterval(this.timer) },
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
