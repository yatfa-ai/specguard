# frozen_string_literal: true

require "rails_helper"

# The pending selection's own rules, at the grain the request specs cannot see.
#
# `spec/requests/bulk_registration_spec.rb` is where this is exercised over the whole trip it exists
# for — summary, out through GitHub's `state`, back through the callback, onto a ticked picker — and
# that is the level the ticket's acceptance criteria are asserted at. What is left for here is the
# handful of decisions that are DECISIONS rather than plumbing: what may become a handle, who a
# handle answers for, where the age bound falls, and the one-row-per-TRIP rule that is the whole
# difference between this and `GithubRegistrationGrant`.
RSpec.describe PendingBulkSelection do
  let(:user) { create_user }

  describe ".capture" do
# @intent: { entity: "PendingBulkSelection", action: "capture a batch", behavior: "stores the submitted full names and returns a token that later redeems to exactly that list for the same user", layer: "unit" }
    it "persists the batch and hands back a handle that redeems it" do
      selection = described_class.capture(user: user, organization: "acme",
                                          full_names: %w[acme/api acme/web])

      expect(selection.token).to be_present
      expect(described_class.redeem(user: user, token: selection.token))
        .to match_array(%w[acme/api acme/web])
    end

    # The handle is what goes in the URL, and the byte budget it exists to fit inside is the whole
    # reason this table exists. Asserted as a BOUND rather than as an exact length, because
    # `SecureRandom.urlsafe_base64` is free to be re-tuned and only its ORDER matters here: tens of
    # bytes rather than the thousands a name list costs.
# @intent: { entity: "PendingBulkSelection", action: "mint a handle", behavior: "the generated token stays within 64 bytes so it fits a URL path where a full name list would not", layer: "unit" }
    it "hands back a handle small enough for the trip it is for" do
      selection = described_class.capture(user: user, organization: "acme",
                                          full_names: %w[acme/api])

      expect(selection.token.bytesize).to be <= 64
    end

    # Normalised through the same class method the controller and the service use, so a carried
    # batch and a submitted one are the same batch — a selection that redeemed to a differently-
    # shaped list would tick rows the reader's own submission would not have.
# @intent: { entity: "PendingBulkSelection", action: "normalise names", behavior: "URL forms and padded whitespace collapse to bare full names and duplicates are dropped so a carried batch matches a submitted one", layer: "unit" }
    it "normalises and de-duplicates the names it stores" do
      selection = described_class.capture(
        user: user, organization: "acme",
        full_names: ["acme/api", "https://github.com/acme/api", "  acme/web  "]
      )

      expect(selection.full_names).to match_array(%w[acme/api acme/web])
    end

    # A handle on the path is a PROMISE — `GithubHelper#bulk_picker_carries_names?` reads the emitted
    # path to decide whether the page may say "already selected". So a handle that resolves to
    # nothing is worse than no handle at all: it would buy the promise and not pay it.
# @intent: { entity: "PendingBulkSelection", action: "reject empty input", behavior: "an empty or blank full-name list returns nil rather than persisting a handle that promises nothing", layer: "unit" }
    it "mints nothing when there is no batch to carry" do
      expect(described_class.capture(user: user, organization: "acme", full_names: [])).to be_nil
      expect(described_class.capture(user: user, organization: "acme", full_names: [""])).to be_nil
    end

# @intent: { entity: "PendingBulkSelection", action: "reject missing org", behavior: "a nil or blank organization aborts capture so no row is created without a destination account", layer: "unit" }
    it "mints nothing when there is no account to come back to" do
      expect(described_class.capture(user: user, organization: nil, full_names: %w[acme/api])).to be_nil
      expect(described_class.capture(user: user, organization: "", full_names: %w[acme/api])).to be_nil
    end

    # Never raises: every caller is a page render that has already got what it came for. A database
    # that will not take the row costs the reader their ticks on the return leg — a state the page
    # renders correctly — and must not cost them the summary itself.
# @intent: { entity: "PendingBulkSelection", action: "survive save failures", behavior: "a RecordInvalid raised by create! is swallowed and capture returns nil so page rendering never blows up", layer: "unit" }
    it "answers nil rather than raising when the row will not save" do
      allow(described_class).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(described_class.new))

      expect(described_class.capture(user: user, organization: "acme", full_names: %w[acme/api]))
        .to be_nil
    end

    # THE RULE THIS TABLE DOES NOT SHARE WITH `github_registration_grants`, and the reason it has no
    # unique index on `user_id`.
    #
    # A grant is a statement about a PERSON, only ever true in its latest version, so it is replaced
    # wholesale. A pending selection is a statement about ONE TRIP, and a person can have two
    # summaries open in two tabs. Replacing wholesale would mean the second tab's render silently
    # overwrote the first tab's selection — and the first tab's button would then come back ticking
    # a batch its reader never chose, which is a wrong answer that looks exactly like a right one.
# @intent: { entity: "PendingBulkSelection", action: "keep rows per trip", behavior: "two captures by the same user get distinct tokens that each redeem to their own batch instead of the newest replacing the older", layer: "unit" }
    it "keeps one row per trip, so a second tab does not overwrite the first tab's batch" do
      first = described_class.capture(user: user, organization: "acme", full_names: %w[acme/api])
      second = described_class.capture(user: user, organization: "acme", full_names: %w[acme/web])

      expect(first.token).not_to eq(second.token)
      expect(described_class.redeem(user: user, token: first.token)).to eq(%w[acme/api])
      expect(described_class.redeem(user: user, token: second.token)).to eq(%w[acme/web])
    end

    # The sweep clears only what is already past `MAX_AGE`; see `PendingBulkSelection.sweep_expired`
    # for why that time bound is accepted rather than tightened. Asserted on the EXPIRED row only,
    # with a live one beside it, so a sweep that simply deleted everything for the user would fail
    # rather than pass — that implementation is exactly the two-tab bug above, arriving by another
    # route.
# @intent: { entity: "PendingBulkSelection", action: "sweep expired rows", behavior: "the next capture deletes rows older than MAX_AGE for that user while leaving that user live rows intact", layer: "unit" }
    it "clears this person's expired rows when they take their next trip, and only those" do
      stale = described_class.capture(user: user, organization: "acme", full_names: %w[acme/old])
      stale.update!(captured_at: described_class::MAX_AGE.ago - 1.minute)
      live = described_class.capture(user: user, organization: "acme", full_names: %w[acme/live])

      described_class.capture(user: user, organization: "acme", full_names: %w[acme/new])

      expect(described_class.exists?(id: stale.id)).to be(false)
      expect(described_class.exists?(id: live.id)).to be(true)
    end

# @intent: { entity: "PendingBulkSelection", action: "scope the sweep", behavior: "capture never deletes expired rows belonging to a different user even when both target the same organization", layer: "unit" }
    it "leaves another person's expired rows alone" do
      other = create_user(github_uid: "2002", github_handle: "hubot")
      theirs = described_class.capture(user: other, organization: "acme", full_names: %w[acme/old])
      theirs.update!(captured_at: described_class::MAX_AGE.ago - 1.minute)

      described_class.capture(user: user, organization: "acme", full_names: %w[acme/new])

      expect(described_class.exists?(id: theirs.id)).to be(true)
    end
  end

  describe ".redeem" do
    # Every way a handle can fail to name a live selection of this person's answers the SAME way,
    # because they are one state to the reader: the list comes back unticked, at the right account.
    # That is exactly what an over-bound batch delivered before handles existed, so every failure
    # here degrades to the old behaviour rather than erroring.
# @intent: { entity: "PendingBulkSelection", action: "redeem unknown handle", behavior: "an unrecognised token returns an empty list so the picker degrades to unticked rather than erroring", layer: "unit" }
    it "answers nothing for a handle nobody minted" do
      expect(described_class.redeem(user: user, token: "no-such-handle")).to eq([])
    end

# @intent: { entity: "PendingBulkSelection", action: "redeem blank handle", behavior: "nil and empty-string tokens both return an empty list instead of raising or falling back to another selection", layer: "unit" }
    it "answers nothing for a blank or missing handle" do
      expect(described_class.redeem(user: user, token: nil)).to eq([])
      expect(described_class.redeem(user: user, token: "")).to eq([])
    end

# @intent: { entity: "PendingBulkSelection", action: "expire old handles", behavior: "a token whose row is older than MAX_AGE no longer redeems its saved batch", layer: "unit" }
    it "answers nothing past the age bound" do
      selection = described_class.capture(user: user, organization: "acme", full_names: %w[acme/api])
      selection.update!(captured_at: described_class::MAX_AGE.ago - 1.minute)

      expect(described_class.redeem(user: user, token: selection.token)).to eq([])
    end

# @intent: { entity: "PendingBulkSelection", action: "honor the age window", behavior: "a selection one minute inside MAX_AGE still redeems its full list, pinning the cutoff as exclusive", layer: "unit" }
    it "still answers just inside the age bound" do
      selection = described_class.capture(user: user, organization: "acme", full_names: %w[acme/api])
      selection.update!(captured_at: described_class::MAX_AGE.ago + 1.minute)

      expect(described_class.redeem(user: user, token: selection.token)).to eq(%w[acme/api])
    end

    # THE ONE THAT IS ABOUT SOMEBODY ELSE'S DATA. `user_id` is part of the WHERE rather than a check
    # applied to a row already found, so another person's handle is not FOUND rather than found and
    # refused — there is no moment at which their batch is in hand to be logged, counted, or leaked
    # by a timing difference.
    #
    # The control matters as much as the assertion: the same token DOES redeem for its owner in the
    # line below, so this pins the SCOPE rather than passing on a handle that redeems for nobody.
# @intent: { entity: "PendingBulkSelection", action: "scope redemption", behavior: "a token minted by another user returns nothing for this user while still redeeming for its owner, so foreign batches are never surfaced", layer: "unit" }
    it "answers nothing for a handle belonging to somebody else" do
      other = create_user(github_uid: "2002", github_handle: "hubot")
      theirs = described_class.capture(user: other, organization: "acme",
                                       full_names: %w[acme/private-thing])

      expect(described_class.redeem(user: user, token: theirs.token)).to eq([])
      expect(described_class.redeem(user: other, token: theirs.token)).to eq(%w[acme/private-thing])
    end

# @intent: { entity: "PendingBulkSelection", action: "require a user", behavior: "redeeming with a nil user yields an empty list even for a token that exists", layer: "unit" }
    it "answers nothing when there is nobody to scope the read to" do
      selection = described_class.capture(user: user, organization: "acme", full_names: %w[acme/api])

      expect(described_class.redeem(user: nil, token: selection.token)).to eq([])
    end
  end

  describe "#stale?" do
    # An unsaved row is treated as stale rather than as fresh: the safe reading of "I cannot tell how
    # old this is" is "too old". `captured_at` is `NOT NULL` and validated, so this is unreachable
    # through a persisted row — which is the point of asserting it here rather than through one.
# @intent: { entity: "PendingBulkSelection", action: "judge staleness", behavior: "an unsaved record with no captured_at reads as stale so unknown age is treated conservatively", layer: "unit" }
    it "treats a selection of unknown age as too old" do
      expect(described_class.new.stale?).to be(true)
    end
  end
end
