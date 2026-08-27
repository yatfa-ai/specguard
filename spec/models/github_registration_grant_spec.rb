# frozen_string_literal: true

require "rails_helper"

# The grant's own rules, at the grain the request specs cannot see.
#
# `spec/requests/github_registration_grant_spec.rb` is where the mint is exercised over the real
# browser read it hangs off, and `spec/requests/api/v1/user_repository_registration_spec.rb` is
# where redemption is exercised over HTTP. What is left for here is the handful of decisions that
# are decisions rather than plumbing: what a reading has to be before it may become a grant, how
# names are compared, and where the age bound falls.
RSpec.describe GithubRegistrationGrant do
  let(:user) { create_user }

  def repo(full_name, admin: true) = github_repo(full_name, admin: admin)

  def sources(repos:, truncated: false, error: nil, installed: true)
    InstallationRepositories::Sources.new(repos: repos, truncated: truncated, error: error,
                                          installed: installed, outcomes: [])
  end

  describe ".capture" do
    it "stores the administered set and the visible set separately" do
      grant = described_class.capture(
        user: user,
        sources: sources(repos: [repo("acme/billing-service"), repo("acme/ledger", admin: false)])
      )

      expect(grant.registrable_full_names).to eq(["acme/billing-service"])
      expect(grant.visible_full_names).to match_array(%w[acme/billing-service acme/ledger])
    end

    # GitHub logins and repository names are compared case-insensitively everywhere else this
    # question is asked, so the stored form is the compared form and the comparison never has to
    # remember to downcase one side.
    it "stores names downcased" do
      grant = described_class.capture(user: user, sources: sources(repos: [repo("ACME/Billing-Service")]))

      expect(grant.registrable_full_names).to eq(["acme/billing-service"])
    end

    # A repository reachable through two of the same person's installations is one repository.
    it "stores a name once however many installations reached it" do
      grant = described_class.capture(
        user: user,
        sources: sources(repos: [repo("acme/billing-service"), repo("ACME/billing-service")])
      )

      expect(grant.registrable_full_names).to eq(["acme/billing-service"])
    end

    # The rule the whole mechanism rests on: in a grant, an absent name is a REFUSAL. So a reading
    # that was cut short may not become one — it would refuse repositories this person genuinely
    # administers, and would be indistinguishable from GitHub having said no.
    it "refuses to build a grant from a truncated reading" do
      result = described_class.capture(user: user,
                                       sources: sources(repos: [repo("acme/billing-service")], truncated: true))

      expect(result).to be_nil
      expect(described_class.where(user_id: user.id)).to be_empty
    end

    it "refuses to build a grant when an installation could not be read" do
      result = described_class.capture(user: user,
                                       sources: sources(repos: [repo("acme/billing-service")], error: :unavailable))

      expect(result).to be_nil
      expect(described_class.where(user_id: user.id)).to be_empty
    end

    # An empty COMPLETE reading is an answer, not a gap: this person administers nothing right now,
    # and a grant that says so is correct. Distinct from the two examples above, and it is the
    # example that stops "refuse anything empty" passing them.
    it "does build an empty grant from a complete reading of nothing" do
      grant = described_class.capture(user: user, sources: sources(repos: []))

      expect(grant.registrable_full_names).to eq([])
      expect(grant).to be_persisted
    end

    it "answers nil rather than raising when there is nobody to grant to" do
      expect(described_class.capture(user: nil, sources: sources(repos: []))).to be_nil
    end
  end

  describe "#stale?" do
    def grant_captured(captured_at) = described_class.new(user: user, captured_at: captured_at)

    it "is false for a grant taken just now" do
      expect(grant_captured(Time.current)).not_to be_stale
    end

    # The boundary stated rather than left to an operator: `MAX_AGE` old exactly is still inside the
    # bound, and a second past it is not.
    it "is false at exactly the bound and true past it" do
      # Whole seconds: the column's cast truncates sub-microsecond precision, so a `Time.current`
      # carried straight into both sides of the comparison lands the "exactly" case a few hundred
      # nanoseconds on the wrong side of the boundary it is trying to state.
      now = Time.current.change(usec: 0)

      expect(grant_captured(now - described_class::MAX_AGE)).not_to be_stale(now: now)
      expect(grant_captured(now - described_class::MAX_AGE - 1.second)).to be_stale(now: now)
    end

    # "I cannot tell how old this is" reads as "too old". A persisted row cannot be in this state —
    # the column is `NOT NULL` and validated — which is exactly why the answer has to be decided
    # rather than left to a comparison against nil.
    it "is true for a grant carrying no stamp at all" do
      expect(grant_captured(nil)).to be_stale
    end
  end

  describe "#registrable? and #visible?" do
    subject(:grant) do
      create_registration_grant(user: user, registrable: ["acme/billing-service"],
                                visible: %w[acme/billing-service acme/ledger])
    end

    it "matches regardless of case or surrounding whitespace" do
      expect(grant).to be_registrable("ACME/Billing-Service")
      expect(grant).to be_registrable("  acme/billing-service  ")
    end

    # The distinction the second array exists for, and the only thing it does: `visible?` is true of
    # a repository this person may NOT register, so a refusal can name the right fix.
    it "sees a repository it does not grant" do
      expect(grant).to be_visible("acme/ledger")
      expect(grant).not_to be_registrable("acme/ledger")
    end

    it "answers no to a name it has never heard of" do
      expect(grant).not_to be_visible("someone-else/private-thing")
      expect(grant).not_to be_registrable("someone-else/private-thing")
    end
  end

  # One row per person, and the database is what says so — not whichever code path happens to be
  # writing. A per-key grant would narrow a key's reach below its holder's, and would let one
  # person hold several divergent opinions about their own GitHub access.
  it "permits only one grant per person" do
    create_registration_grant(user: user)

    expect { create_registration_grant(user: user) }.to raise_error(ActiveRecord::RecordInvalid)
  end
end
