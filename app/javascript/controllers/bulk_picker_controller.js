import { Controller } from "@hotwired/stimulus"

// The organization bulk picker: type to narrow a long list of repositories, tick what to register,
// and see how many are ticked without counting them.
//
// A narrowing pass over real form controls rather than a widget — the same choice
// repository_picker_controller.js makes and for the same reasons. Every row is a plain input inside
// a <label>, so keyboard and screen-reader behaviour is the platform's, and with JavaScript off the
// page degrades to a complete, correct, unnarrowed list that still submits.
//
// Two naming constraints apply in this directory and both are load-bearing:
//
//   - The action is `refine`, not the CSS-colliding synonym. Tailwind scans this directory as
//     literal text, so writing that word here — as an identifier OR in prose — emits DaisyUI's
//     filtering component into the built stylesheet, which nothing can apply.
//     See app/assets/tailwind/application.css.
//   - For the same reason the tick-box target is `pick`. The obvious name for it is a DaisyUI
//     component this app does not use and has not excluded, so spelling it out here would emit that
//     component's CSS off a Stimulus target name.
//
// Nothing here is a security boundary. The server re-asks GitHub whether every submitted repository
// is one the user administers, whatever the browser sent.
export default class extends Controller {
  static targets = ["query", "pick", "row", "count", "all"]

  // The server's per-batch bound (BulkRegistration::MAX_BATCH), handed over by the view. Advisory
  // only: `#create` still refuses an oversized batch, so this exists to say so BEFORE the submit
  // rather than after a 422 that leaves every name ticked. 0 / absent means "no cap known".
  static values = { max: Number }

  connect() {
    this.refine()
  }

  refine() {
    const needle = this.hasQueryTarget ? this.queryTarget.value.trim().toLowerCase() : ""

    for (const row of this.rowTargets) {
      const name = row.dataset.bulkPickerName || ""
      row.hidden = needle !== "" && !name.includes(needle)
    }

    this.tally()
  }

  // Applies to what is CURRENTLY SHOWN, never to the whole organization. Narrowing to "service" and
  // pressing this is how someone picks a subset of forty repositories; reaching past the narrowing
  // would register things they had deliberately taken out of view.
  //
  // Already-registered rows carry `disabled`, so they are skipped here as they are everywhere else.
  //
  // When the list is longer than one batch can carry, ticking fills only the room that is left, in
  // document order, rather than ticking a selection the server is certain to refuse. Unticking is
  // never limited.
  chooseShown(event) {
    const wanted = event.target.checked
    let room = this.capped() ? this.maxValue - this.chosenPicks().length : Infinity

    for (const pick of this.shownPicks()) {
      if (!wanted) {
        pick.checked = false
      } else if (!pick.checked && room > 0) {
        pick.checked = true
        room -= 1
      }
    }

    this.tally()
  }

  tally() {
    const shown = this.shownPicks()
    // Counted over EVERY pick, not only the shown ones: a selection made before narrowing is still
    // part of the submission, and a count that dropped it would under-report what is about to
    // happen — on the one control a reader uses to check the batch before pressing the button.
    const chosen = this.chosenPicks()
    const capped = this.capped()
    const full = capped && chosen.length >= this.maxValue

    if (this.hasAllTarget) {
      // Reflects the rows it acts on, so it cannot read as "everything is selected" while a
      // narrowed-away row sits unticked, or as unticked while every shown row is ticked.
      const shownChosen = shown.filter((pick) => pick.checked)
      const everyShownChosen = shown.length > 0 && shownChosen.length === shown.length
      // With the batch filled to its limit the control has done all it can: it reads checked (so the
      // next click unticks) instead of sitting indeterminate with a click that could only add nothing.
      const filled = full && shownChosen.length > 0
      this.allTarget.checked = everyShownChosen || filled
      this.allTarget.indeterminate = !this.allTarget.checked && shownChosen.length > 0
    }

    if (this.hasCountTarget) {
      let text = `${chosen.length} selected`
      const over = capped ? chosen.length - this.maxValue : 0

      if (over > 0) {
        text += ` — ${over} over the ${this.maxValue}-per-batch limit`
      } else if (full) {
        text += " (batch limit)"
      }

      if (shown.length !== this.selectablePicks().length) text += ` · ${shown.length} shown`

      this.countTarget.textContent = text
      this.countTarget.classList.toggle("text-app-warning", over > 0)
      this.countTarget.classList.toggle("text-app-muted", over <= 0)
    }
  }

  chosenPicks() {
    return this.pickTargets.filter((pick) => pick.checked && !pick.disabled)
  }

  // True only when the list is longer than one batch, so a list at or under the cap behaves exactly
  // as it did before the cap was known to the page.
  capped() {
    return this.maxValue > 0 && this.selectablePicks().length > this.maxValue
  }

  shownPicks() {
    return this.selectablePicks().filter((pick) => !pick.closest("[data-bulk-picker-target~='row']").hidden)
  }

  selectablePicks() {
    return this.pickTargets.filter((pick) => !pick.disabled)
  }
}
