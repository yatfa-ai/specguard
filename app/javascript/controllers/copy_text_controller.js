import { Controller } from "@hotwired/stimulus"

// Gets the source element's text off this page — to the clipboard, or to a downloaded file — and
// reports which of those actually happened. Used by the reveal-once API key panel, where
// re-reading the value later is impossible.
//
// The download is built here, from the text already rendered, because there is no server route
// that could serve it: `ApiKey` stores a digest, so the plaintext exists only in this DOM.
export default class extends Controller {
  static targets = ["source", "label", "status"]
  static values = {
    confirmation: { type: String, default: "Copied" },
    autoCopy: { type: Boolean, default: false },
    copiedMessage: { type: String, default: "" },
    copyFailedMessage: { type: String, default: "" },
    downloadFilename: { type: String, default: "specguard-api-key.txt" }
  }

  // The reveal-once panel copies without being asked: the one thing its reader must not do is
  // leave the page without the token. A clipboard write needs transient user activation in some
  // browsers, and the click that triggered this does not survive the redirect that renders the
  // panel — so the attempt genuinely can fail, and `status` is told which way it went. Claiming a
  // copy that did not happen is worse here than not copying at all.
  connect() {
    if (this.autoCopyValue) this.copy()
  }

  async copy() {
    if (await this.write()) {
      this.report(this.copiedMessageValue)
      this.confirmOnLabel()
    } else {
      this.report(this.copyFailedMessageValue)
    }
  }

  download() {
    const url = URL.createObjectURL(new Blob([this.text()], { type: "text/plain" }))
    const link = document.createElement("a")

    link.href = url
    link.download = this.downloadFilenameValue
    document.body.appendChild(link)
    link.click()
    link.remove()

    // Revoking in the same tick can cancel the download that was just started.
    setTimeout(() => URL.revokeObjectURL(url), 0)
  }

  text() {
    return this.sourceTarget.textContent.trim()
  }

  async write() {
    try {
      await navigator.clipboard.writeText(this.text())
      return true
    } catch {
      return false
    }
  }

  // No-ops without a message or a status target, so the call sites that only wanted a Copy button
  // keep the behaviour they had before there was a status line.
  report(message) {
    if (!message || !this.hasStatusTarget) return

    this.statusTarget.textContent = message
  }

  confirmOnLabel() {
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
