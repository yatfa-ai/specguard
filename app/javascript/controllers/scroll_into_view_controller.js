import { Controller } from "@hotwired/stimulus"

// Brings the element it is attached to into view once, when it appears.
//
// It exists for one flow: the API key reveal. `repositories#show` is a very tall template — panels
// for the suite's growth, its heaviest files and directories, its slowest tests, its refused
// deliveries — and the control that mints or rotates a credential sits near the bottom of it while
// the reveal renders near the top. Turbo Drive preserves scroll position across the visit that
// follows the redirect, so the panel can render perfectly and arrive entirely off-screen, and the
// person who pressed the button sees nothing happen. The value is shown exactly once: only a
// SHA-256 digest is stored, so a reveal that is missed costs a rotation, which breaks whatever was
// still carrying the old token.
//
// == Why this rather than a scroll offset
//
// Nothing here names a pixel. `scrollIntoView` asks the browser where the element actually is, so
// it keeps working as the template grows — and it will grow. Anything computed from a known height,
// or a `window.scrollTo` with a constant in it, is correct on the day it is written and wrong on
// the next panel.
//
// The redirect that renders the reveal also carries a URL fragment, so a browser with no JavaScript
// at all still lands on the panel. This controller is the half that covers the case that fragment
// does not: Turbo owns the scroll on a Drive visit and does not always consult it. Measured, not
// assumed — driving `spec/system/api_key_reveal_spec.rb` against a page given a scroll-restoring
// listener, the fragment alone leaves both viewport examples failing and this controller is what
// makes them pass.
//
// == Why the scroll is deferred by a frame
//
// Turbo performs its own scroll — restore, anchor, or top — as part of rendering the new page, and
// Stimulus connects controllers from a MutationObserver callback that can run before that. Scrolling
// synchronously here would therefore be undone moments later by Turbo scrolling somewhere else.
// `requestAnimationFrame` puts this after the render's scroll rather than in a race with it.
//
// Instant rather than smooth, deliberately: a smooth scroll is still animating when the browser
// reports the element's position, which would make the system spec that guards this flow assert
// against a moving target.
//
// == Why once per instance
//
// `connect()` is not once-per-element — Stimulus re-runs it on the same instance whenever the
// element is re-inserted or moved. Re-scrolling would drag a reader who has deliberately scrolled
// away back to the panel. The reveal render additionally opts out of Turbo's snapshot cache (see
// `_revealed_token.html.erb`), so there is no restored snapshot to build a fresh instance from.
export default class extends Controller {
  connect() {
    if (this.scrolled) return

    this.scrolled = true
    requestAnimationFrame(() => this.element.scrollIntoView({ behavior: "auto", block: "start" }))
  }
}
