import { Controller } from "@hotwired/stimulus"

// A <details> menu that closes when you click elsewhere, press Escape, or pick an item.
export default class extends Controller {
  connect() {
    this.out = (event) => { if (!this.element.contains(event.target)) this.element.open = false }
    this.esc = (event) => { if (event.key === "Escape" && this.element.open) { this.element.open = false; this.element.querySelector("summary")?.focus() } }
    document.addEventListener("click", this.out)
    document.addEventListener("keydown", this.esc)
  }

  disconnect() {
    document.removeEventListener("click", this.out)
    document.removeEventListener("keydown", this.esc)
  }
}
