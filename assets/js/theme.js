// The colour theme. Loaded in <head> without defer, so the choice is on <html>
// before the first paint (no flash of the wrong theme), and it keeps working
// across LiveView navigations because it listens on the document.
//
// "system" is the absence of a choice: no data-theme attribute, and the
// stylesheet's prefers-color-scheme query picks paper or night. The choice is
// kept in this browser only; without storage the page simply follows the device.

const KEY = "alnasl-theme"
const THEMES = ["paper", "night", "board", "slate", "contrast"]
// The first version had a light/dark switch; its two values still mean something.
const LEGACY = {light: "paper", dark: "night"}

const root = document.documentElement
const read = () => { try { return localStorage.getItem(KEY) } catch (_e) { return null } }
const write = (value) => { try { localStorage.setItem(KEY, value) } catch (_e) { /* private mode */ } }

const current = () => root.getAttribute("data-theme") || "system"

const apply = (value) => {
  const theme = LEGACY[value] || value
  if (THEMES.includes(theme)) root.setAttribute("data-theme", theme)
  else root.removeAttribute("data-theme")
}

// Which option says so, for a screen reader as well as the eye.
const mark = () => {
  const now = current()
  document.querySelectorAll("[data-theme-opt]").forEach((option) => {
    option.setAttribute("aria-pressed", String(option.dataset.themeOpt === now))
  })
}

apply(read())

document.addEventListener("click", (event) => {
  const button = event.target.closest("[data-theme-opt]")
  if (!button) return

  const value = button.dataset.themeOpt
  write(value)
  apply(value)
  mark()

  const picker = button.closest("details")
  if (picker) {
    picker.removeAttribute("open")
    const trigger = picker.querySelector("summary")
    if (trigger) trigger.focus()
  }
})

document.addEventListener("keydown", (event) => {
  if (event.key !== "Escape") return
  const open = document.querySelector("details.theme-picker[open]")
  if (open) {
    open.removeAttribute("open")
    open.querySelector("summary")?.focus()
  }
})

// Another tab changed it.
window.addEventListener("storage", (event) => {
  if (event.key === KEY) { apply(event.newValue); mark() }
})

document.addEventListener("DOMContentLoaded", mark)
window.addEventListener("phx:page-loading-stop", mark)
