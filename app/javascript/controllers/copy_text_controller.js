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

    // Capture the pristine label once. Re-reading it per click would capture the
    // confirmation text on a second click inside the window, sticking the label there.
    this.pristineLabel ??= this.labelTarget.textContent

    // A second click extends the window instead of stacking a second restore timer.
    clearTimeout(this.restoreTimer)
    this.labelTarget.textContent = this.confirmationValue
    this.restoreTimer = setTimeout(() => {
      this.labelTarget.textContent = this.pristineLabel
      this.restoreTimer = null
    }, 1500)
  }

  // Turbo can detach the element while a restore is pending; don't fire against a dead node.
  disconnect() {
    clearTimeout(this.restoreTimer)
  }
}
