import { Controller } from "@hotwired/stimulus"

// Flips [data-theme] between the two ported themes and remembers the choice.
// No rebuild is involved: every utility references var(--app-*) directly (@theme inline),
// so changing the attribute recolours the whole app at runtime.
export default class extends Controller {
  static values = { storageKey: { type: String, default: "specguard.theme" } }

  connect() {
    const stored = window.localStorage.getItem(this.storageKeyValue)
    if (stored) this.#apply(stored)
  }

  toggle() {
    const next = document.documentElement.dataset.theme === "winter" ? "dark" : "winter"
    this.#apply(next)
    window.localStorage.setItem(this.storageKeyValue, next)
  }

  #apply(theme) {
    document.documentElement.dataset.theme = theme
  }
}
