# frozen_string_literal: true

require "rails_helper"

# The row that says "this person reached SpecGuard through that installation" — half of the
# ownership proof and not the half about the person. It says a repository was handed to SpecGuard by
# SOMEBODY with administrative rights; every member of an organization can see that organization's
# installation, so it says nothing about who is holding the row. The other half is read live, per
# user (`InstallationRepositories`).
#
# It holds one public numeric id and no credential, so what there is to pin here is not storage but
# discipline: `record` is called from a callback a person can edit and revisit at will, and every
# example below is about one of the ways that arrives.
RSpec.describe GithubInstallation do
  # `create_user` connects an installation by default (id 5001, account "acme"), because almost
  # every spec in the suite needs a user who can register a repository. This file is about the row
  # itself, so it names both states explicitly.
  let(:user) { create_user }
  let(:unconnected) { create_user(github_uid: "2002", github_handle: "newcomer", installation_id: nil) }

  describe ".record" do
    # @intent: { entity: "GithubInstallation", action: "record a callback", behavior: "an unconnected user arriving from the flow gets one persisted row carrying the installation id and account login", layer: "unit" }
    it "records an installation for a user who had none" do
      installation = described_class.record(user: unconnected, installation_id: 7003, account_login: "octocat")

      expect(installation).to be_persisted
      expect(installation.installation_id).to eq(7003)
      expect(installation.account_login).to eq("octocat")
      expect(unconnected.github_installations.reload).to eq([installation])
    end

    # GitHub sends a user to the setup URL every time they pass through the installation flow —
    # including when they merely reconfigure which repositories are selected — so a second arrival
    # is the ordinary case, not an edge one. It has to update the row rather than grow a duplicate
    # or blow up on the uniqueness index.
    # @intent: { entity: "GithubInstallation", action: "record a callback", behavior: "a second pass through the flow updates the existing row's login instead of growing a duplicate", layer: "unit" }
    it "updates the existing row when the same user passes through the flow again" do
      first = described_class.record(user: user, installation_id: 5001, account_login: "acme")

      second = described_class.record(user: user, installation_id: 5001, account_login: "acme-renamed")

      expect(second.id).to eq(first.id)
      expect(user.github_installations.reload.count).to eq(1)
      expect(second.account_login).to eq("acme-renamed")
    end

    # A callback that arrives without a login says nothing about the account — it is silence, not a
    # correction — and blanking the name shown in the connected-accounts list is strictly worse than
    # keeping the one already known.
    # @intent: { entity: "GithubInstallation", action: "record a callback", behavior: "a callback carrying no login keeps the account name already known rather than blanking it", layer: "unit" }
    it "never blanks a known account login with a nil" do
      described_class.record(user: user, installation_id: 5001, account_login: "acme")

      refreshed = described_class.record(user: user, installation_id: 5001, account_login: nil)

      expect(refreshed.account_login).to eq("acme")
    end

    # @intent: { entity: "GithubInstallation", action: "record a callback", behavior: "a whitespace-only login is likewise ignored instead of erasing the stored name", layer: "unit" }
    it "leaves a known account login alone when a later callback carries a blank one" do
      described_class.record(user: user, installation_id: 5001, account_login: "acme")

      refreshed = described_class.record(user: user, installation_id: 5001, account_login: "   ")

      expect(refreshed.account_login).to eq("acme")
    end

    # The id arrives as a query parameter on a URL a person can edit, so "not a positive integer" is
    # an ordinary thing to receive rather than an exceptional one. The controller renders a sentence
    # for nil; a raise here would be a 500 for someone who mistyped a URL.
    [nil, "", "   ", 0, "0", -5, "-5", "abc", "  abc  "].each do |value|
      # @intent: { entity: "GithubInstallation", action: "record a callback", behavior: "a non-positive or malformed id parameter yields nil and writes no row rather than raising a 500", layer: "unit" }
      it "returns nil rather than raising for #{value.inspect}" do
        expect { expect(described_class.record(user: unconnected, installation_id: value)).to be_nil }
          .not_to change(described_class, :count)
      end
    end

    # GitHub's redirect carries the id as a string, and a stray space either side of it says nothing
    # about which installation was meant.
    # @intent: { entity: "GithubInstallation", action: "record a callback", behavior: "an id arriving as a padded string is stripped to its integer value", layer: "unit" }
    it "reads an id that arrives as a padded string" do
      installation = described_class.record(user: unconnected, installation_id: "  7003  ")

      expect(installation.installation_id).to eq(7003)
    end
  end

  describe "who may hold an installation id" do
    # Two administrators of the same organization legitimately install — or arrive back through —
    # the same installation, and each holds their own row for it. A global unique index would make
    # the second one's callback fail for no reason they could act on.
    # @intent: { entity: "GithubInstallation", action: "record a callback", behavior: "two users may each hold their own row for the same installation id", layer: "unit" }
    it "lets two people each hold the same installation" do
      mine = user.github_installations.first
      colleague = create_user(github_uid: "3003", github_handle: "colleague", installation_id: nil)

      theirs = described_class.record(user: colleague, installation_id: 5001, account_login: "acme")

      expect(theirs).to be_persisted
      expect(theirs.id).not_to eq(mine.id)
      expect(described_class.where(installation_id: 5001).pluck(:user_id)).to match_array([user.id, colleague.id])
    end

    # Scoped to the user, though — the same id twice for ONE person is a duplicate, and it is what
    # `record`'s find-or-initialize exists to avoid writing.
    # @intent: { entity: "GithubInstallation", action: "validate uniqueness", behavior: "the same installation twice for one person is refused with a taken error before any insert", layer: "unit" }
    it "refuses the same installation twice for one person" do
      duplicate = user.github_installations.build(installation_id: 5001)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:installation_id].join).to include("taken")
      expect { duplicate.save! }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  describe "#display_name" do
    # @intent: { entity: "GithubInstallation", action: "render a display name", behavior: "the connected-accounts label prefers the account login GitHub reported", layer: "unit" }
    it "names the connected account when GitHub told us one" do
      expect(user.github_installations.first.display_name).to eq("acme")
    end

    # A row recorded from a callback that carried no login must still be nameable, or the connected
    # accounts list renders a blank entry nobody can identify or disconnect with confidence.
    # @intent: { entity: "GithubInstallation", action: "render a display name", behavior: "with no login recorded the label falls back to the installation number so the row stays identifiable", layer: "unit" }
    it "falls back to the installation id when there is no account login" do
      installation = described_class.record(user: unconnected, installation_id: 7003)

      expect(installation.account_login).to be_nil
      expect(installation.display_name).to eq("Installation 7003")
    end
  end

  describe "validations" do
    # @intent: { entity: "GithubInstallation", action: "validate a row", behavior: "an installation row without an id fails validation with a blank error", layer: "unit" }
    it "requires an installation id" do
      installation = unconnected.github_installations.build(installation_id: nil)

      expect(installation).not_to be_valid
      expect(installation.errors[:installation_id].join).to include("blank")
    end

    # @intent: { entity: "GithubInstallation", action: "validate a row", behavior: "an installation row with no user fails validation on the association", layer: "unit" }
    it "requires a user" do
      installation = described_class.new(installation_id: 7003)

      expect(installation).not_to be_valid
      expect(installation.errors[:user]).to be_present
    end

    # Zero and negatives are not installations GitHub could ever have issued, and the column is a
    # signed bigint that would happily store either.
    [0, -1].each do |value|
      # @intent: { entity: "GithubInstallation", action: "validate a row", behavior: "zero and negative ids fail the greater-than-zero check despite the column accepting them", layer: "unit" }
      it "rejects an installation id of #{value}" do
        installation = unconnected.github_installations.build(installation_id: value)

        expect(installation).not_to be_valid
        expect(installation.errors[:installation_id].join).to include("greater than 0")
      end
    end

    # The check is on what was ASSIGNED, not on what the bigint column silently truncated it to —
    # otherwise "12.5" would validate as 12 and be recorded as a different installation than the one
    # named.
    # @intent: { entity: "GithubInstallation", action: "validate a row", behavior: "a fractional id string is judged on the assigned value rather than its truncated integer cast", layer: "unit" }
    it "rejects an installation id that is not a whole number" do
      installation = unconnected.github_installations.build(installation_id: "12.5")

      expect(installation).not_to be_valid
      expect(installation.errors[:installation_id].join).to include("must be an integer")
    end

    # @intent: { entity: "GithubInstallation", action: "validate a row", behavior: "an id that is not a number at all is refused with a not-a-number error", layer: "unit" }
    it "rejects an installation id that is not a number at all" do
      installation = unconnected.github_installations.build(installation_id: "abc")

      expect(installation).not_to be_valid
      expect(installation.errors[:installation_id].join).to include("is not a number")
    end

    # @intent: { entity: "GithubInstallation", action: "validate a row", behavior: "a plain positive integer id passes validation untouched", layer: "unit" }
    it "accepts a plain positive id" do
      expect(unconnected.github_installations.build(installation_id: 7003)).to be_valid
    end
  end
end
