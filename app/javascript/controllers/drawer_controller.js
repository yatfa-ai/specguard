import { Controller } from "@hotwired/stimulus"

// A table row that carries `data-drawer-title` opens ONE shared detail drawer. The row supplies the
// title, the kind label and a <template> holding the detail; nothing is fetched. The open row is
// written into the URL hash (`#row-…`) so the view is shareable and the back button closes it.
export default class extends Controller {
  static targets = ["scrim", "panel", "kind", "title", "body", "close"]

  connect() {
    // Back/Forward across a drawer transition is OURS, and Turbo must not see it: the entry the
    // drawer was opened from is one of Turbo's own, so letting its popstate handler run would treat
    // closing a drawer as a visit and re-render the whole page — losing the reader's scroll, their
    // open sections and any sort they chose. Registered in the CAPTURE phase, so it runs before
    // Turbo's bubble-phase listener on the same target, and it stops the event only when the
    // transition is a drawer's (going to a `#row-…` entry, or leaving one that is open).
    this.onPopCapture = (event) => {
      if (this.server) return
      if (location.hash.startsWith("#row-") || this.open) event.stopImmediatePropagation()
      this.#fromHash()
    }
    window.addEventListener("popstate", this.onPopCapture, true)
    this.onPop = () => this.#fromHash(false)
    this.onKey = (event) => {
      if (event.key !== "Escape" || !this.open) return
      if (this.server) this.closeTarget.click(); else this.close()
    }
    window.addEventListener("hashchange", this.onPop)
    document.addEventListener("keydown", this.onKey)
    if (this.panelTarget.dataset.server === "true") this.closeTarget.focus({ preventScroll: true })
    else this.#fromHash(false)
  }

  disconnect() {
    window.removeEventListener("popstate", this.onPopCapture, true)
    window.removeEventListener("hashchange", this.onPop)
    document.removeEventListener("keydown", this.onKey)
  }

  get open() { return this.panelTarget.dataset.open === "true" }
  get server() { return this.panelTarget.dataset.server === "true" }

  // A row either carries its own detail (`data-drawer-title` + a template) or names the URL whose
  // server-rendered drill-in the drawer will hold on load (`data-href`). Both leave a real URL.
  show(event) {
    if (event.target.closest("a, form, [data-no-drawer]") && !event.target.closest("a.row-open")) return
    const link = event.target.closest("tr[data-href]")
    if (link && !event.target.closest("a")) {
      event.preventDefault()
      window.Turbo ? window.Turbo.visit(link.dataset.href) : (location.href = link.dataset.href)
      return
    }
    const row = event.target.closest("tr[data-drawer-title]")
    if (!row) return
    event.preventDefault()
    this.#render(row)
    // One entry per OPEN, never per click: while a drawer is already open from a row, picking
    // another row replaces that entry rather than stacking a second one on it.
    if (row.id) {
      const entry = { drawer: row.id }
      if (history.state?.drawer) history.replaceState(entry, "", `#${row.id}`)
      else history.pushState(entry, "", `#${row.id}`)
    }
  }

  // The server-rendered drill-in closes by navigating to the same page without its asks (the
  // anchor's own href); a client row just hides the panel and drops its hash.
  close(event) {
    if (this.panelTarget.dataset.server === "true") return
    event?.preventDefault()
    this.#hide()
    // Closing walks the history back to the entry the drawer was opened from, so the stack stays
    // the page's own: open, close, open again is one entry, not three.
    if (location.hash.startsWith("#row-")) {
      if (history.state?.drawer) history.back()
      else history.replaceState({}, "", location.pathname + location.search)
    }
  }

  #fromHash() {
    const id = location.hash.slice(1)
    const row = id.startsWith("row-") ? document.getElementById(id) : null
    if (row && row.matches("tr[data-drawer-title]")) this.#render(row)
    else this.#hide()
  }

  #render(row) {
    this.#unselect()
    this.selected = row
    row.dataset.selected = "true"
    this.kindTarget.textContent = row.dataset.drawerKind || ""
    this.titleTarget.textContent = row.dataset.drawerTitle
    const tpl = row.querySelector("template[data-drawer-body]")
    this.bodyTarget.replaceChildren(tpl ? tpl.content.cloneNode(true) : "")
    this.scrimTarget.dataset.open = "true"
    this.panelTarget.dataset.open = "true"
    this.panelTarget.removeAttribute("inert")
    this.closeTarget.focus({ preventScroll: true })
  }

  #hide() {
    const returnTo = this.selected?.querySelector(".row-open")
    this.#unselect()
    this.scrimTarget.dataset.open = "false"
    this.panelTarget.dataset.open = "false"
    this.panelTarget.setAttribute("inert", "")
    if (returnTo && this.wasOpen) returnTo.focus({ preventScroll: true })
    this.selected = null
  }

  #unselect() {
    this.wasOpen = this.open
    if (this.panelTarget.dataset.server === "true") return
    this.element.ownerDocument.querySelectorAll("tr[data-selected]").forEach((r) => delete r.dataset.selected)
  }
}
