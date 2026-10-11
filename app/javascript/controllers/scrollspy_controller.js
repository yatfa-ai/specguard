import { Controller } from "@hotwired/stimulus"

// Marks the section index link of the section being read, and keeps the sticky bar's real height
// in a CSS variable so anchors, sticky table headers and the scroll offset all agree with it.
//
// The section being read is the last one whose top has passed a line a little below the bar —
// a position rule, not an intersection zone, so there is always exactly one answer (the first
// section at the very top, the last one at the very bottom).
export default class extends Controller {
  static targets = ["link", "bar"]

  connect() {
    const root = this.element
    this.measure = () => root.style.setProperty("--rc-bar-h", `${this.barTarget.offsetHeight}px`)
    this.measure()
    this.resize = new ResizeObserver(this.measure)
    this.resize.observe(this.barTarget)

    this.sections = this.linkTargets.map((l) => document.getElementById(l.hash.slice(1))).filter(Boolean)
    this.queued = false
    this.onScroll = () => {
      if (this.queued) return
      this.queued = true
      requestAnimationFrame(() => { this.queued = false; this.update() })
    }
    window.addEventListener("scroll", this.onScroll, { passive: true })
    window.addEventListener("resize", this.onScroll, { passive: true })
    this.update()
  }

  disconnect() {
    window.removeEventListener("scroll", this.onScroll)
    window.removeEventListener("resize", this.onScroll)
    this.resize?.disconnect()
  }

  pick(event) { this.#mark(event.currentTarget.hash.slice(1)) }

  update() {
    if (!this.sections.length) return
    const line = this.barTarget.offsetHeight + window.innerHeight * 0.25
    const atBottom = window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 4
    let current = this.sections[0]
    for (const section of this.sections) {
      if (section.getBoundingClientRect().top <= line) current = section
    }
    if (atBottom) current = this.sections[this.sections.length - 1]
    this.#mark(current.id)
  }

  #mark(id) {
    this.linkTargets.forEach((l) => {
      if (l.hash === `#${id}`) l.setAttribute("aria-current", "true"); else l.removeAttribute("aria-current")
    })
  }
}
