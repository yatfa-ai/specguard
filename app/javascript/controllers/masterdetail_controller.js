import { Controller } from "@hotwired/stimulus"

// The repository page is an index (the rail) beside ONE unit (the detail). Every unit is already
// in the document; this only decides which one is showing, so the page works as plain anchors and
// the browser's find-in-page still reaches a unit that is not showing once it is chosen.
// An in-page anchor to anything inside a unit ("#api-keys", "#suite-size-basis") selects the unit
// that holds it, then scrolls to it.
export default class extends Controller {
  static targets = ["item", "pane"]
  static values = { default: String }

  connect() {
    this.onHash = () => this.fromHash()
    this.onClick = (event) => this.fromLink(event)
    window.addEventListener("hashchange", this.onHash)
    document.addEventListener("click", this.onClick)
    this.fromHash(true)
  }

  disconnect() {
    window.removeEventListener("hashchange", this.onHash)
    document.removeEventListener("click", this.onClick)
  }

  choose(event) {
    event.preventDefault()
    const key = event.currentTarget.dataset.pane
    this.show(key)
    history.replaceState(null, "", `#${key}`)
    this.detailTop()
  }

  fromLink(event) {
    const link = event.target && event.target.closest ? event.target.closest("a[href^='#']") : null
    if (!link || link.hasAttribute("data-pane")) return
    const id = link.getAttribute("href").slice(1)
    if (this.reveal(id)) event.preventDefault()
  }

  fromHash(initial = false) {
    const id = window.location.hash.slice(1)
    if (id && this.reveal(id)) return
    if (initial) this.show(this.defaultValue)
  }

  reveal(id) {
    const target = id && document.getElementById(id)
    const pane = target && target.closest("[data-pane]")
    if (!pane) return false
    this.show(pane.dataset.pane)
    requestAnimationFrame(() => target.scrollIntoView({ block: "start" }))
    return true
  }

  show(key) {
    this.paneTargets.forEach((pane) => { pane.hidden = pane.dataset.pane !== key })
    this.itemTargets.forEach((item) => {
      if (item.dataset.pane === key) item.setAttribute("aria-current", "true")
      else item.removeAttribute("aria-current")
    })
  }

  detailTop() {
    const detail = this.element.querySelector(".md-detail")
    if (detail && detail.getBoundingClientRect().top < 0) detail.scrollIntoView({ block: "start" })
  }
}
