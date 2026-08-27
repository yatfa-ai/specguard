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

    # The LOSER of the race the rescue names: two concurrent page renders for the same person, one
    # of which read `find_or_initialize_by` before the other's row existed and so holds a `new`
    # record that is about to collide.
    #
    # Staged deterministically rather than with threads — handing `.capture` a fresh unsaved row for
    # a `user_id` that already has one IS the loser's state, and no amount of scheduling makes it
    # more so. The contract the rescue's own comment states is that the loser was writing the same
    # GitHub answer, so it has "nothing to add and nothing to report": it neither raises nor
    # overwrites, and hands back the row that won.
    it "hands back the winner's row when it loses a race for the same person" do
      winner = create_registration_grant(user: user, registrable: ["acme/billing-service"])
      allow(described_class).to receive(:find_or_initialize_by)
        .with(user_id: user.id).and_return(described_class.new(user_id: user.id))

      result = described_class.capture(user: user, sources: sources(repos: [repo("acme/ledger")]))

      expect(result).to eq(winner)
      expect(result.registrable_full_names).to eq(["acme/billing-service"])
      expect(described_class.where(user_id: user.id).count).to eq(1)
    end

    # The SAME race, refused by POSTGRES rather than by the Rails validation — the half that only
    # exists because the validation is a read-then-write check both renders can pass.
    #
    # The raise is stated rather than provoked, and that is a limit of the harness rather than a
    # choice: a genuine duplicate INSERT aborts the surrounding transactional example, so the
    # `find_by` this branch exists to perform could not run afterwards. What the example pins is
    # `RecordNotUnique`'s membership of the rescue list — drop it from `:76` and this fails, while
    # nothing else in the suite notices.
    it "hands back the winner's row when Postgres is the one that refuses the duplicate" do
      winner = create_registration_grant(user: user, registrable: ["acme/billing-service"])
      loser = described_class.new(user_id: user.id)
      allow(described_class).to receive(:find_or_initialize_by).with(user_id: user.id).and_return(loser)
      allow(loser).to receive(:save!).and_raise(ActiveRecord::RecordNotUnique, "duplicate key value")

      result = described_class.capture(user: user, sources: sources(repos: [repo("acme/ledger")]))

      expect(result).to eq(winner)
      expect(result.registrable_full_names).to eq(["acme/billing-service"])
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

  # One row per person. A per-key grant would narrow a key's reach below its holder's, and would let
  # one person hold several divergent opinions about their own GitHub access.
  #
  # The rule is enforced TWICE and the two halves are pinned separately, because neither example
  # can observe the other's half. This one is the RAILS VALIDATION: the factory writes through
  # `create!`, so `validates :user_id, uniqueness: true` refuses before an INSERT is ever issued and
  # Postgres is never consulted. The next example is the database half.
  it "permits only one grant per person — the Rails validation refuses the second" do
    create_registration_grant(user: user)

    expect { create_registration_grant(user: user) }.to raise_error(ActiveRecord::RecordInvalid)
  end

  # The DATABASE half of that same rule, and the half that actually holds the line.
  #
  # `validates :user_id, uniqueness: true` is a read-then-write check — SELECT, then INSERT — so two
  # concurrent page renders both pass it, both INSERT, and one person ends up holding two divergent
  # grant rows that `find_by(user_id:)` then picks between arbitrarily. Since a grant is what
  # authorizes `POST /api/v1/repositories` for a session-less `sgu_` key, that is an authorization
  # record rather than a cosmetic one, and the unique index is the only thing that refuses it.
  #
  # The index is asserted directly rather than through a write, because no write CAN reach it: the
  # validation always answers first. Drop `unique: true` from the migration and only this example
  # fails.
  it "is the unique index on user_id that enforces that rule under concurrency" do
    index = ActiveRecord::Base.connection.indexes("github_registration_grants")
                              .find { |candidate| candidate.columns == ["user_id"] }

    expect(index).to be_present
    expect(index.unique).to be(true)
  end
end
