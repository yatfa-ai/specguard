import { Controller } from "@hotwired/stimulus"

// The repository page is a column of native <details> chapters, so it opens and closes with no
// script at all. This only makes an in-page anchor ("#api-keys", "#ch-changes", "#rejected-ingests")
// land: it opens every chapter that holds the target, then scrolls to it.
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
    if (isClick && !link) return
    const hash = link ? link.getAttribute("href") : window.location.hash
    if (!hash || hash.length < 2) return
    const target = document.getElementById(hash.slice(1))
    if (!target) return
    let opened = false
    for (let el = target; el; el = el.parentElement && el.parentElement.closest("details")) {
      if (el.tagName === "DETAILS" && !el.open) { el.open = true; opened = true }
    }
    if (opened || isClick) requestAnimationFrame(() => target.scrollIntoView({ block: "start" }))
  }
}
