import { Controller } from "@hotwired/stimulus"

// Click a column header to sort that table's rows; click again to reverse. The sort is on the
// client and over the rows already on the page: the server decides WHICH rows (a capped ranking),
// this only reorders them. A cell may carry `data-sort` for an exact value; without one the cell's
// text is read (numbers with separators, "1 m 20 s" durations, "3 of 12" fractions, "+4" deltas).
export default class extends Controller {
  static targets = ["head", "body"]

  sort(event) {
    const th = event.currentTarget.closest("th")
    const index = Array.from(th.parentElement.children).indexOf(th)
    const next = th.getAttribute("aria-sort") === "ascending" ? "descending" : "ascending"
    this.headTargets.forEach((h) => h.removeAttribute("aria-sort"))
    th.setAttribute("aria-sort", next)

    const rows = Array.from(this.bodyTarget.rows)
    const dir = next === "ascending" ? 1 : -1
    const keyed = rows.map((row, position) => ({ row, position, key: this.#key(row.cells[index]) }))
    keyed.sort((a, b) => {
      if (a.key === b.key) return a.position - b.position
      if (a.key === null) return 1
      if (b.key === null) return -1
      if (typeof a.key === "number" && typeof b.key === "number") return (a.key - b.key) * dir
      return String(a.key).localeCompare(String(b.key), undefined, { numeric: true }) * dir
    })
    keyed.forEach(({ row }) => this.bodyTarget.appendChild(row))
  }

  #key(cell) {
    if (!cell) return null
    if (cell.dataset.sort !== undefined && cell.dataset.sort !== "") {
      const n = Number(cell.dataset.sort)
      return Number.isNaN(n) ? cell.dataset.sort.toLowerCase() : n
    }
    const text = cell.textContent.replace(/\s+/g, " ").trim()
    if (!text || /^(not reported|not timed|—|-)$/i.test(text)) return null
    const hms = text.match(/^(?:(\d+)\s*h)?\s*(?:(\d+)\s*m)?\s*(?:(\d+(?:\.\d+)?)\s*s)?$/i)
    if (hms && (hms[1] || hms[2] || hms[3])) {
      return (Number(hms[1] || 0) * 3600) + (Number(hms[2] || 0) * 60) + Number(hms[3] || 0)
    }
    const signed = text.match(/^([+\u2212\-±])\s*(\d[\d,]*(?:\.\d+)?)/)
    if (signed) return (signed[1] === "+" || signed[1] === "±" ? 1 : -1) * Number(signed[2].replace(/,/g, ""))
    const lead = text.match(/^<?\s*(\d[\d,]*(?:\.\d+)?)\s*(%|s\b|ms\b)?/)
    if (lead) return Number(lead[1].replace(/,/g, ""))
    return text.toLowerCase()
  }
}
