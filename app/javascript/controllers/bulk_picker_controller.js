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
  chooseShown(event) {
    const wanted = event.target.checked

    for (const pick of this.shownPicks()) {
      pick.checked = wanted
    }

    this.tally()
  }

  tally() {
    const shown = this.shownPicks()
    // Counted over EVERY pick, not only the shown ones: a selection made before narrowing is still
    // part of the submission, and a count that dropped it would under-report what is about to
    // happen — on the one control a reader uses to check the batch before pressing the button.
    const chosen = this.pickTargets.filter((pick) => pick.checked && !pick.disabled)

    if (this.hasAllTarget) {
      // Reflects the rows it acts on, so it cannot read as "everything is selected" while a
      // narrowed-away row sits unticked, or as unticked while every shown row is ticked.
      const shownChosen = shown.filter((pick) => pick.checked)
      this.allTarget.checked = shown.length > 0 && shownChosen.length === shown.length
      this.allTarget.indeterminate = shownChosen.length > 0 && shownChosen.length < shown.length
    }

    if (this.hasCountTarget) {
      const selected = `${chosen.length} selected`
      this.countTarget.textContent =
        shown.length === this.selectablePicks().length
          ? selected
          : `${selected} · ${shown.length} shown`
    }
  }

  shownPicks() {
    return this.selectablePicks().filter((pick) => !pick.closest("[data-bulk-picker-target~='row']").hidden)
  }

  selectablePicks() {
    return this.pickTargets.filter((pick) => !pick.disabled)
  }
}
