# frozen_string_literal: true

# THE BATCH SOMEBODY TICKED, HELD HERE WHILE THEY TAKE A TRIP TO GITHUB AND COME BACK.
#
# The bulk summary's fix buttons — "Connect your GitHub repositories", "Reconnect to GitHub",
# "Choose repositories on GitHub" — send the reader to github.com and back, and they carry the
# reader's selection so that pressing the button which actually RESOLVES the refusal costs no more
# than pressing the one beside it that merely re-submits.
#
# Everything they carry rides out through GitHub's `state` parameter, which is part of a URL on
# somebody else's site, so the carry has a byte budget that is not ours to set and not one we can
# raise. `GithubHelper::MAX_RETURN_TO_BYTES` states its derivation in full. Carrying the NAMES in
# that URL fit 28 of the 100 batch sizes the product accepts (`BulkRegistration::MAX_BATCH`), and
# above 28 the list was dropped ENTIRELY — so a person who ticked thirty repositories, was refused,
# pressed the button that fixes it, and came back, landed on an unticked list and re-picked thirty
# by hand. Precisely the cost the button exists to remove.
#
# This is the remedy, and the remedy is to stop putting the list in the URL: the row holds the
# names, the URL holds a ~22-byte handle to the row, and `organization` + handle fits at EVERY size
# in `1..MAX_BATCH`. The all-or-nothing drop stops being reachable for these paths — not because the
# bound moved, but because nothing large is being measured against it any more.
#
# ## What this is NOT, and why the two cheaper-looking places are both wrong
#
# NOT the session. This app has no `config/initializers/session_store.rb`, so it is on Rails'
# default COOKIE store with its 4KB ceiling. A hundred names is ~2.6KB raw before encryption and
# encoding inflation, and the session already carries the GitHub user token and its expiry
# (`GithubUserSession::TOKEN_KEY` / `EXPIRES_KEY`) — the credential `github_authorization_needed?`
# turns on. A batch-sized stash risks `CookieOverflow`, and a NEAR miss is worse than an overflow:
# it quietly evicts the token instead, breaking verification with nothing raised anywhere.
#
# NOT `Rails.cache`. `config/environments/test.rb` sets `cache_store = :null_store`, and
# production's `cache_store` line is commented out. A cache-backed handle would silently no-op under
# test — every acceptance test passing or failing for reasons unrelated to the code — and would have
# no configured backing in production either.
#
# ## One row per TRIP, not one row per person
#
# `GithubRegistrationGrant` is the nearest neighbour in shape, and it is deliberately one row per
# user, replaced wholesale, because a grant is a statement about a PERSON that is only ever true in
# its latest version. A pending selection is the opposite: it is a statement about ONE trip, and a
# person can have two summaries open in two tabs. One row per user would mean the second tab's
# render silently overwrites the first tab's selection, and the first tab's button would then come
# back ticking a batch its reader never chose — a wrong answer that looks exactly like a right one.
#
# So the handle names a ROW, and `user_id` is the scope every read is made THROUGH rather than the
# key it is made BY.
#
# ## Nothing here is trusted, and that is what makes it safe to hand out
#
# A redeemed selection decides one thing: which of the rows the picker was going to render anyway
# start out TICKED. It grants nothing. `BulkRegistrationsController#new` says the same of the names
# it already accepts in the query string, and `BulkRegistration` re-verifies every name against
# GitHub on submit — so a name in a redeemed selection that this person may not register is refused
# at submit exactly as a typed one is, and a name absent from the listing simply matches no row.
#
# That is why redemption can be a plain `find_by` and needs no ownership check beyond the scope: the
# worst a resolved selection can do is pre-tick boxes.
class PendingBulkSelection < ApplicationRecord
  # How long a handle may be redeemed for.
  #
  # An hour, where `GithubRegistrationGrant::MAX_AGE` is seven days, and the difference is what the
  # two rows are FOR. A grant stands in for a session that cannot ask GitHub, and is redeemed by an
  # agent that may run weekly. This is one person walking to github.com and pressing back — a trip
  # measured in seconds, generously bounded at an hour for somebody who wanders off mid-way, gets
  # distracted by GitHub's own picker, or has to sign in again on the far side.
  #
  # Nothing breaks past it: an expired handle resolves to nothing and the reader lands on the right
  # account with an unticked list, which is exactly today's over-28 behaviour. The bound exists so
  # that a row is not kept indefinitely, not because an old selection is dangerous.
  MAX_AGE = 1.hour

  belongs_to :user

  validates :token, presence: true, uniqueness: true
  validates :organization, presence: true
  validates :captured_at, presence: true

  # Take a selection and hand back the row whose token is the handle.
  #
  # Returns `nil` — never raises — when there is nothing worth persisting or when the write did not
  # land. Every caller is a page render that has already got what it came for: the summary is being
  # shown either way, and a failed capture costs the reader their ticks on the return leg rather
  # than costing them the page. `GithubRegistrationGrant.capture` takes the same position for the
  # same reason.
  #
  # A blank organization or an empty name list yields `nil` rather than an empty row, because a
  # handle that resolves to nothing is worse than no handle: `GithubHelper#bulk_picker_carries_names?`
  # reads the emitted path to decide whether the page may PROMISE ticks, and a handle on the path
  # is that promise.
  def self.capture(user:, organization:, full_names:)
    return nil if user.nil? || organization.blank?

    names = BulkRegistration.normalized_names(full_names)
    return nil if names.empty?

    sweep_expired(user)

    create!(user: user, organization: organization.to_s, full_names: names,
            token: SecureRandom.urlsafe_base64(16), captured_at: Time.current)
  rescue ActiveRecord::ActiveRecordError => e
    # The reader loses their ticks on the return leg and is told nothing was carried, which is a
    # state this page already renders correctly. Logged rather than swallowed silently, because a
    # capture failing every time is a real defect and the summary would otherwise look healthy.
    Rails.logger.warn("[PendingBulkSelection] capture: #{e.class}: #{e.message}")
    nil
  end

  # Redeem a handle for the names it holds, for THIS person.
  #
  # Answers `[]` for every way a handle can fail to name a live selection of this person's — unknown,
  # already expired, or belonging to somebody else — and the three are deliberately one answer,
  # because they are one state to the reader: the list comes back unticked. It degrades to what an
  # over-bound batch did before this existed (right account, unticked list) rather than erroring.
  #
  # `user_id` is part of the WHERE rather than a check applied after the find, so another person's
  # handle is not found at all. A refusal applied afterwards would have had to hold the row — and a
  # row held is a row that can be logged, counted, or leaked by a timing difference.
  def self.redeem(user:, token:)
    return [] if user.nil? || token.blank?

    selection = find_by(user_id: user.id, token: token.to_s)
    return [] if selection.nil? || selection.stale?

    selection.full_names
  end

  # This person's rows that are past `MAX_AGE`, cleared on their next capture.
  #
  # Note what this does NOT do: it does not clear the previous row. A capture sweeps only what is
  # already EXPIRED, so a person who renders a refused summary ten times inside the hour leaves ten
  # live rows, and they are cleared an hour later by a capture that may never come. That is not an
  # oversight to be read past — `create` fires once per summary RENDER, and this controller
  # documents re-rendering as ordinary ("the cost is that a refresh re-submits, and that is
  # survivable precisely because the operation is idempotent by construction"), so a reader who
  # refreshes is the expected case rather than the odd one.
  #
  # The growth that permits is bounded by TIME, not by the next press: at most one person's renders
  # within one `MAX_AGE` window, each holding at most `BulkRegistration::MAX_BATCH` names. That is
  # the bound this design accepts, and it is acceptable for three reasons worth stating rather than
  # leaving to be re-derived:
  #
  #   - It cannot accumulate ACROSS windows. Whatever a person leaves behind stops being redeemable
  #     after an hour and is deleted by their next capture, so the steady state for somebody who
  #     keeps using the feature is an hour's worth of their own renders, not a lifetime's.
  #   - The rows are small and hold nothing granted. A selection decides which checkboxes start
  #     ticked; every name is re-verified against GitHub on submit, so a row left lying about is
  #     inert rather than dangerous.
  #   - Nothing here is per-request or per-visitor. A row is written only on the REFUSED summary of
  #     a signed-in person who ticked repositories — a page reached deliberately, by somebody who
  #     already authenticated.
  #
  # The one case this leaves is the person who refreshes a refused summary and never returns: their
  # rows expire on schedule but are deleted by nobody, because deletion is carried by their next
  # capture. Those rows are unredeemable within the hour and are a bounded per-person residue, which
  # is why a scheduled job is not warranted rather than merely not present. Should this table ever
  # grow past that reasoning — a periodic `where(captured_at: ...(Time.current - MAX_AGE))
  # .delete_all` across all users is the whole of the job, and it needs no state of its own.
  #
  # Sweeping the person's OTHER rows unconditionally here would make the growth bound tighter, and
  # is deliberately NOT done: it would reintroduce exactly the two-tabs clobber the "one row per
  # TRIP" decision above exists to prevent.
  def self.sweep_expired(user, now: Time.current)
    where(user_id: user.id).where(captured_at: ...(now - MAX_AGE)).delete_all
  end
  private_class_method :sweep_expired

  # Past the bound, and therefore redeeming nothing. `captured_at` is `NOT NULL` and validated, so
  # this is never nil on a persisted row; an unsaved one is treated as stale rather than as fresh,
  # because the safe reading of "I cannot tell how old this is" is "too old".
  def stale?(now: Time.current)
    return true if captured_at.nil?

    captured_at < now - MAX_AGE
  end
end
