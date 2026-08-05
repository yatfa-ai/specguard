import { Controller } from "@hotwired/stimulus"

// Shows/hides a panel body. Kept deliberately dumb — no animation state, no ARIA guessing
// beyond aria-expanded on the trigger.
export default class extends Controller {
  static targets = ["body", "trigger"]
  static classes = ["hidden"]

  toggle() {
    const hiddenClass = this.hasHiddenClass ? this.hiddenClass : "hidden"
    const nowHidden = this.bodyTarget.classList.toggle(hiddenClass)

    if (this.hasTriggerTarget) this.triggerTarget.setAttribute("aria-expanded", String(!nowHidden))
  }
}
