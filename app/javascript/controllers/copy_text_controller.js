import { Controller } from "@hotwired/stimulus"

// Copies the source element's text to the clipboard and briefly swaps the trigger's label.
// Used by the reveal-once API key panel, where re-reading the value later is impossible.
export default class extends Controller {
  static targets = ["source", "label"]
  static values = { confirmation: { type: String, default: "Copied" } }

  async copy() {
    const text = this.sourceTarget.textContent.trim()

    try {
      await navigator.clipboard.writeText(text)
    } catch {
      return
    }

    if (!this.hasLabelTarget) return

    const original = this.labelTarget.textContent
    this.labelTarget.textContent = this.confirmationValue
    setTimeout(() => { this.labelTarget.textContent = original }, 1500)
  }
}
