import { Controller } from "@hotwired/stimulus"

// The repository page's workspaces are CSS-only radio tabs, so they work with no script at all.
// This only makes in-page anchors ("#api-keys", "#rejected-ingests"…) land: an anchor into a pane
// that is not showing selects the pane that holds its target, then scrolls to it.
export default class extends Controller {
  connect() {
    this.reveal = this.reveal.bind(this)
    window.addEventListener("hashchange", this.reveal)
    document.addEventListener("click", this.reveal)
    this.reveal()
  }

  disconnect() {
    window.removeEventListener("hashchange", this.reveal)
    document.removeEventListener("click", this.reveal)
  }

  reveal(event) {
    const isClick = event && event.type === "click"
    const link = isClick && event.target && event.target.closest ? event.target.closest("a[href^='#']") : null
    // A click that is not on an in-page link must never fall back to the (possibly stale) URL hash.
    if (isClick && !link) return
    const hash = link ? link.getAttribute("href") : window.location.hash
    if (!hash || hash.length < 2) return
    const target = this.element.querySelector(hash) || document.getElementById(hash.slice(1))
    const pane = target && target.closest("[data-pane]")
    if (!pane) return
    const radio = this.element.querySelector(`#ws-${pane.dataset.pane}`)
    if (radio && !radio.checked) {
      radio.checked = true
      requestAnimationFrame(() => target.scrollIntoView({ block: "start" }))
    }
  }
}
