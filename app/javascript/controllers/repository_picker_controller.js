import { Controller } from "@hotwired/stimulus"

// Type-to-narrow over a <select>'s options. The repository picker can hold a few hundred entries,
// which a native select is genuinely bad at — GitHub's own list is the whole point of the field,
// and a list you cannot search is a list you scroll.
//
// Deliberately a narrowing pass over a real <select> rather than a custom combobox: the value
// submitted is then always one GitHub actually returned, keyboard and screen-reader behaviour is
// the platform's, and with JavaScript off the field degrades to a plain — still complete, still
// correct — select.
//
// The action is `refine` rather than the obvious CSS-colliding synonym, and that is load-bearing:
// Tailwind scans this directory as literal text, so writing that word here — as an identifier OR
// in a prose comment — emits Tailwind's filtering utility into the built stylesheet. Nothing in
// this controller is ever an HTML class, so that CSS is dead weight.
// See app/assets/tailwind/application.css, which documents the collision in full and excludes the
// DaisyUI half of it.
//
// Nothing here is a security boundary. The server re-asks GitHub whether the submitted repository
// is one the user administers, whatever the browser sent.
export default class extends Controller {
  static targets = ["query", "select", "count"]

  connect() {
    this.refine()
  }

  refine() {
    const needle = this.hasQueryTarget ? this.queryTarget.value.trim().toLowerCase() : ""
    let shown = 0

    for (const option of this.selectTarget.options) {
      // A placeholder option carries no value; it is not a repository and must not be hidden
      // away, or an empty search result leaves the select showing whatever was selected last.
      if (option.value === "") continue

      const matches = needle === "" || option.text.toLowerCase().includes(needle)
      option.hidden = !matches
      option.disabled = !matches
      if (matches) shown += 1
    }

    // A hidden option can still be the selected one, which reads as the search having done
    // nothing. Move the selection to the first match instead.
    const selected = this.selectTarget.selectedOptions[0]
    if (selected && selected.hidden) {
      const firstMatch = Array.from(this.selectTarget.options).find((o) => o.value !== "" && !o.hidden)
      this.selectTarget.value = firstMatch ? firstMatch.value : ""
    }

    if (this.hasCountTarget) {
      this.countTarget.textContent =
        shown === 1 ? "1 repository matches" : `${shown} repositories match`
    }
  }
}
