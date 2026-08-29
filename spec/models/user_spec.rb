# frozen_string_literal: true

require "rails_helper"

RSpec.describe User do
  let(:auth) do
    OmniAuth::AuthHash.new(
      "provider" => "github", "uid" => "1001",
      "info" => { "nickname" => "octocat", "email" => "octocat@example.com",
                  "image" => "https://example.test/avatar.png" }
    )
  end

  # @intent: { entity: "User", action: "provision from an OmniAuth hash", behavior: "from_github_omniauth persists a new user carrying the nickname, email and avatar URL of the GitHub identity", layer: "unit" }
  it "creates a user from a GitHub identity" do
    user = described_class.from_github_omniauth(auth)

    expect(user).to be_persisted
    expect(user.github_handle).to eq("octocat")
    expect(user.email).to eq("octocat@example.com")
    expect(user.avatar_url).to eq("https://example.test/avatar.png")
  end

  # @intent: { entity: "User", action: "key the identity on the GitHub uid", behavior: "a second sign-in under the same uid with a renamed nickname reuses the existing row and updates the handle instead of creating a second user", layer: "unit" }
  it "keys on the GitHub uid, so a renamed handle stays the same user" do
    original = described_class.from_github_omniauth(auth)
    renamed = described_class.from_github_omniauth(
      OmniAuth::AuthHash.new(auth.to_hash.deep_merge("info" => { "nickname" => "octocat-renamed" }))
    )

    expect(renamed.id).to eq(original.id)
    expect(renamed.github_handle).to eq("octocat-renamed")
    expect(described_class.count).to eq(1)
  end

  # The whole reason `created_api_keys` is `dependent: :nullify` and not `dependent: :destroy` like
  # every other association in this codebase. A key belongs to the *repository*; the person who
  # minted it is an attribution, not an owner. Deleting a departed collaborator must never revoke
  # the credential the owner's CI is authenticating with — it must only forget who minted it.
  describe "deleting a user who minted keys on someone else's repository" do
    let(:owner) { described_class.create!(github_uid: "1001", github_handle: "octocat") }
    let(:collaborator) { described_class.create!(github_uid: "9999", github_handle: "departing-dev") }
    let(:repository) { create_repository(user: owner) }

    # @intent: { entity: "User", action: "nullify minted-key attribution on delete", behavior: "destroying a collaborator leaves their minted API keys in place and still authenticating, with created_by_user cleared to nil", layer: "unit" }
    it "nullifies the attribution and leaves the key working" do
      api_key = repository.api_keys.create!(name: "CI — main", created_by_user: collaborator)
      raw_token = api_key.raw_token

      expect { collaborator.destroy }.not_to change(ApiKey, :count)

      expect(api_key.reload.created_by_user).to be_nil
      # Not just present — still a live credential on the Bearer path.
      expect(ApiKey.authenticate(raw_token)).to eq(api_key)
    end

    # @intent: { entity: "User", action: "leave other users' keys attributed", behavior: "deleting the collaborator does not touch keys whose created_by_user is someone else, keeping the owner's attribution intact", layer: "unit" }
    it "does not touch keys minted by anyone else" do
      owners_key = repository.api_keys.create!(name: "Owner's key", created_by_user: owner)

      collaborator.destroy

      expect(owners_key.reload.created_by_user).to eq(owner)
    end
  end

  # The other half of the rule the block above states. `created_api_keys` and
  # `granted_repository_memberships` are *attributions* and nullify; `repositories` and
  # `repository_memberships` are what the person actually holds, and they REFUSE the deletion
  # outright rather than cascading.
  #
  # The distinction is the whole point: cascading from the owning side deletes other people's data
  # — every collaborator's membership on the user's repositories, and every byte of telemetry
  # beneath them — from one `user.destroy` call. Nothing in `app` or `lib` calls it today, so this
  # is prevention, landing before a "remove user" surface exists. Be honest about its reach: a user
  # is undestroyable the moment they register a repository or are invited to one, and archive rather
  # than delete is the intended answer for a departing user.
  describe "deleting a user who still holds repositories or memberships" do
    let(:owner) { create_user }
    let(:teammate) { create_user(github_uid: "9999", github_handle: "someone-else") }
    let(:repository) { create_repository(user: owner) }

    # @intent: { entity: "User", action: "refuse to delete a repository owner", behavior: "destroy returns false with a base error and every repository, run, intent, observation, key and user row is unchanged afterwards", layer: "unit" }
    it "refuses to delete an owner, and takes none of their repository's telemetry with it" do
      run = create_test_run(repository: repository)
      create_spec_intent(repository: repository, test_run: run)
      SpecObservation.create!(repository: repository, test_run: run, status: "annotated",
                              file_path: "spec/models/invoice_spec.rb", line_number: 12,
                              example_id: "./spec/models/invoice_spec.rb[1:1]")
      repository.api_keys.create!(name: "CI — main")
      counted = [Repository, TestRun, SpecIntent, SpecObservation, ApiKey, described_class]
      before = counted.to_h { |model| [model, model.count] }

      expect(owner.destroy).to be(false)

      expect(owner.errors[:base]).to be_present
      expect(owner.reload).to be_persisted
      expect(counted.to_h { |model| [model, model.count] }).to eq(before)
    end

    # A membership is this user's access to somebody ELSE's repository. Cascading it away on delete
    # is how a user deletion quietly edits another owner's member list.
    # @intent: { entity: "User", action: "refuse to delete a membership holder", behavior: "destroying someone who holds a membership on another's repository is refused so a user deletion cannot edit the owner's member list", layer: "unit" }
    it "refuses to delete someone who holds a membership on a repository they do not own" do
      membership = create_membership(repository: repository, user: teammate)

      expect(teammate.destroy).to be(false)
      expect(teammate.errors[:base]).to be_present
      expect(membership.reload).to be_persisted
      expect(repository.reload.members).to eq([teammate])
    end

    # `:restrict_with_error`, not `:restrict_with_exception` — a refusal a form can render. The bang
    # still raises, because a caller who chose it asked for the exception.
    # @intent: { entity: "User", action: "raise from destroy! but not destroy", behavior: "the restrict_with_error strategy makes plain destroy return false while destroy! raises ActiveRecord::RecordNotDestroyed", layer: "unit" }
    it "raises from destroy! while destroy merely returns false" do
      create_repository(user: owner)

      expect { owner.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
    end

    # The second line of defence, and the reason the model guard is not the only thing standing
    # here: `delete` skips every callback, so the foreign key is what stops the row going and
    # leaving `repositories.user_id` — which is `NOT NULL` — pointing at nobody.
    # @intent: { entity: "User", action: "enforce ownership at the foreign key", behavior: "bypassing callbacks with delete raises ActiveRecord::InvalidForeignKey because repositories.user_id cannot dangle", layer: "unit" }
    it "raises a foreign key violation when the callbacks are bypassed with delete" do
      repository

      expect { owner.delete }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    # The permitted case, stated positively so the guard's actual reach is on the record: someone
    # who signed in and went no further is still deletable.
    # @intent: { entity: "User", action: "delete a user who holds nothing", behavior: "someone who only signed in and went no further destroys cleanly, stating the guard's actual reach", layer: "unit" }
    it "still deletes a user who owns nothing and holds nothing" do
      loiterer = create_user(github_uid: "4242", github_handle: "just-looking")

      expect(loiterer.destroy).to be_truthy
      expect(described_class.exists?(loiterer.id)).to be(false)
    end
  end

  describe "handle normalization" do
    # @intent: { entity: "User", action: "canonicalize stored handles", behavior: "a mixed-case padded github_handle is stored trimmed and downcased", layer: "unit" }
    it "stores a mixed-case, padded handle in canonical form" do
      user = create_user(github_handle: "  Octocat  ")

      expect(user.reload.github_handle).to eq("octocat")
    end

    # @intent: { entity: "User", action: "canonicalize the OAuth nickname", behavior: "from_github_omniauth stores a mixed-case nickname in the same canonical lowercase form", layer: "unit" }
    it "normalizes the handle taken from a GitHub identity" do
      user = described_class.from_github_omniauth(
        OmniAuth::AuthHash.new(auth.to_hash.deep_merge("info" => { "nickname" => "Octocat" }))
      )

      expect(user.reload.github_handle).to eq("octocat")
    end

    # @intent: { entity: "User", action: "keep a whitespace-only handle invalid", behavior: "normalization does not manufacture a blank value, so a padded-blank handle still trips the presence validation", layer: "unit" }
    it "leaves a blank handle blank so the presence validation still fires" do
      user = described_class.new(github_uid: "1001", github_handle: "   ")

      expect(user).not_to be_valid
      expect(user.errors[:github_handle]).to be_present
    end
  end

  describe "archiving" do
    # @intent: { entity: "User", action: "flip active on archived_at", behavior: "a user is active until archived_at is set and inactive once it is, the two flags tracking one column", layer: "unit" }
    it "is inactive once archived, and active until then" do
      user = create_user

      expect(user).to be_active
      expect(user).not_to be_archived

      user.update!(archived_at: Time.current)

      expect(user).to be_archived
      expect(user).not_to be_active
    end

    # @intent: { entity: "User", action: "partition the table by the two scopes", behavior: "active and archived scopes each return exactly their own rows with no overlap", layer: "unit" }
    it "partitions the table between the two scopes" do
      active = create_user(github_uid: "1001", github_handle: "octocat")
      archived = create_user(github_uid: "9999", github_handle: "departed")
      archived.update!(archived_at: Time.current)

      expect(described_class.active).to contain_exactly(active)
      expect(described_class.archived).to contain_exactly(archived)
    end

    # There is deliberately NO `default_scope`, and this is the assertion that keeps it that way. A
    # blanket scope would take archived people out of every unscoped read in the app — including
    # association traversals, which is where the attribution this whole state exists to preserve is
    # actually rendered (the members list, "who minted this key", "who granted this membership").
    # @intent: { entity: "User", action: "keep archived rows visible to unscoped reads", behavior: "with no default scope, User.all, handle lookups and attribution associations still see the archived person whose membership history must render", layer: "unit" }
    it "leaves unscoped reads and association traversals seeing the archived row" do
      owner = create_user(github_uid: "1001", github_handle: "octocat")
      departing = create_user(github_uid: "9999", github_handle: "departing-dev")
      repository = create_repository(user: owner)
      key = repository.api_keys.create!(name: "CI — main", created_by_user: departing)
      membership = create_membership(repository: repository, user: departing)

      departing.update!(archived_at: Time.current)

      expect(described_class.all).to include(departing)
      expect(described_class.find_by(github_handle: "departing-dev")).to eq(departing)
      expect(key.reload.created_by_user).to eq(departing)
      expect(membership.reload.user).to eq(departing)
      expect(repository.members.reload).to include(departing)
    end

    # THE DEFINITION OF DONE FOR THIS WHOLE DIRECTION, stated as a test: archiving is the
    # alternative to deleting, and it is only worth having because it destroys nothing. `User#destroy`
    # still cascades into repositories and, through them, every test run, spec intent and API key on
    # them — so if archiving ever grew a destroy or a nullify, this is the example that says so.
    # @intent: { entity: "User", action: "destroy and nullify nothing on archive", behavior: "setting archived_at changes no row counts and leaves every attribution column still naming the archived owner, from minted keys to granted memberships", layer: "unit" }
    it "destroys and nullifies nothing" do
      owner = create_user(github_uid: "1001", github_handle: "octocat")
      colleague = create_user(github_uid: "2002", github_handle: "hubot")
      repository = create_repository(user: owner)
      test_run = create_test_run(repository: repository)
      spec_intent = create_spec_intent(repository: repository)
      own_key = repository.api_keys.create!(name: "CI — main", created_by_user: owner)
      colleague_membership = create_membership(repository: repository, user: colleague)
      colleague_membership.update!(granted_by_user: owner)

      counts = lambda do
        [Repository.count, TestRun.count, SpecIntent.count, ApiKey.count, RepositoryMembership.count]
      end

      expect { owner.update!(archived_at: Time.current) }.not_to change(&counts)

      # Every row still there, and every attribution column still naming the archived person —
      # "still exists" is not enough if the columns pointing at them were nulled.
      expect(repository.reload.user).to eq(owner)
      expect(test_run.reload.repository).to eq(repository)
      expect(spec_intent.reload.repository).to eq(repository)
      expect(own_key.reload.created_by_user).to eq(owner)
      expect(colleague_membership.reload.granted_by_user).to eq(owner)
      expect(colleague_membership.user).to eq(colleague)
      expect(owner.reload.repositories).to contain_exactly(repository)
    end
  end

  describe ".resolve_by_handle" do
    # @intent: { entity: "User", action: "resolve typed handles case-insensitively", behavior: "resolve_by_handle finds the same single user whatever case or padding the caller typed, reporting match_count 1", layer: "unit" }
    it "resolves a handle regardless of the case and padding the caller typed" do
      user = create_user(github_handle: "Octocat")

      ["OCTOCAT", "octocat", " Octocat ", "OctoCat"].each do |typed|
        resolution = described_class.resolve_by_handle(typed)

        expect(resolution).to be_found, "expected #{typed.inspect} to resolve, got #{resolution.status}"
        expect(resolution.user).to eq(user)
        expect(resolution.match_count).to eq(1)
      end
    end

    # @intent: { entity: "User", action: "report an unknown handle as not found", behavior: "a handle nobody holds yields a not_found resolution with no user, no raise, and none of the malformed or ambiguous flags", layer: "unit" }
    it "reports a handle nobody holds as not found, without raising" do
      create_user(github_handle: "octocat")

      resolution = described_class.resolve_by_handle("nobody-here")

      expect(resolution).to be_not_found
      expect(resolution).not_to be_ambiguous
      expect(resolution).not_to be_malformed
      expect(resolution.user).to be_nil
      expect(resolution.match_count).to eq(0)
    end

    # "that is not a GitHub handle" and "nobody has signed in with that handle" are different facts,
    # and a caller that cannot tell them apart gives the wrong advice: an owner who pasted a profile
    # URL would be told to go ask their colleague to re-authenticate.
    # @intent: { entity: "User", action: "reject non-handle-shaped queries as malformed", behavior: "blanks, slashes, spaces, URLs, leading hyphens and overlong strings are malformed — a distinct verdict from not_found so callers give the right advice", layer: "unit" }
    it "reports a query that is not handle-shaped as malformed, distinctly from not found" do
      create_user(github_handle: "octocat")

      ["", "   ", nil, "octo/cat", "octo cat", "https://github.com/octocat", "-octocat", "a" * 40].each do |typed|
        resolution = described_class.resolve_by_handle(typed)

        expect(resolution).to be_malformed, "expected #{typed.inspect} to be malformed, got #{resolution.status}"
        expect(resolution).not_to be_not_found
        expect(resolution).not_to be_found
        expect(resolution.user).to be_nil
        expect(resolution.match_count).to eq(0)
      end
    end

    # `from_github_omniauth` falls back to the display name when `nickname` is blank, so a row can
    # hold a string GitHub never issued as a login. Sign-in must keep working (decision b), but such
    # a value is not an identity anyone can be invited by — resolving it must not hand back the row.
    # @intent: { entity: "User", action: "refuse fallback-manufactured handles", behavior: "a handle produced from the display-name fallback, with a space in it, resolves as malformed rather than handing back the row", layer: "unit" }
    it "does not resolve a handle the fallback chain manufactured" do
      user = described_class.from_github_omniauth(
        OmniAuth::AuthHash.new(auth.to_hash.deep_merge("info" => { "nickname" => "", "name" => "The Octocat" }))
      )

      expect(user.reload.github_handle).to eq("the octocat")
      expect(described_class.resolve_by_handle("The Octocat")).to be_malformed
      expect(described_class.resolve_by_handle("the octocat")).to be_malformed
      expect(described_class.resolve_by_handle("the octocat")).not_to be_found
    end

    # A row holds whatever handle its owner had at their last sign-in, so a recycled GitHub handle
    # can legitimately sit on two rows. Picking one would grant access to the wrong person.
    context "when a recycled handle sits on two rows" do
      let!(:renamer) { create_user(github_uid: "1001", github_handle: "octocat") }
      let!(:claimant) { create_user(github_uid: "2002", github_handle: "Octocat") }

      # @intent: { entity: "User", action: "tolerate a recycled handle on two rows", behavior: "two users may both hold the same normalized handle because uniqueness was traded away for rename tolerance", layer: "unit" }
      it "keeps both rows — the collision is legal, not a validation error" do
        expect(renamer).to be_persisted
        expect(claimant).to be_persisted
        expect(described_class.where(github_handle: "octocat").count).to eq(2)
      end

      # @intent: { entity: "User", action: "report ambiguity instead of choosing", behavior: "a handle held by two rows resolves ambiguous with match_count 2 and no user, so the resolver never picks the wrong person", layer: "unit" }
      it "reports ambiguity instead of picking a row" do
        resolution = described_class.resolve_by_handle("OCTOCAT")

        expect(resolution).to be_ambiguous
        expect(resolution).not_to be_found
        expect(resolution.match_count).to eq(2)
        expect(resolution.user).to be_nil
        expect(resolution.user).not_to eq(renamer)
        expect(resolution.user).not_to eq(claimant)
      end
    end

    # Archived rows are not part of the invitable set. The three shapes below are the whole rule,
    # and the middle one is a correctness win rather than only a new state: an owner used to be
    # blocked from inviting a real colleague by a departed one holding the same recycled string.
    context "when a matching row is archived" do
      # @intent: { entity: "User", action: "report archived-only matches as archived", behavior: "a handle every match of which is archived resolves :archived, not :not_found, because re-auth advice cannot be acted on by an archived person", layer: "unit" }
      it "reports :archived rather than :not_found when every match is archived" do
        create_user(github_uid: "9999", github_handle: "departed").update!(archived_at: Time.current)

        resolution = described_class.resolve_by_handle("Departed")

        expect(resolution).to be_archived
        # The distinction this status exists for: :not_found would tell the owner to go ask them to
        # sign in once, which is advice an archived person cannot act on.
        expect(resolution).not_to be_not_found
        expect(resolution).not_to be_found
        expect(resolution).not_to be_ambiguous
        expect(resolution.user).to be_nil
        expect(resolution.match_count).to eq(1)
      end

      # @intent: { entity: "User", action: "prefer the active row over an archived twin", behavior: "an active and an archived row sharing a handle resolve found on the active one with match_count 1", layer: "unit" }
      it "resolves :found on the active row when an archived row shares the handle" do
        active = create_user(github_uid: "1001", github_handle: "octocat")
        create_user(github_uid: "2002", github_handle: "Octocat").update!(archived_at: Time.current)

        resolution = described_class.resolve_by_handle("octocat")

        expect(resolution).to be_found
        expect(resolution).not_to be_ambiguous
        expect(resolution.user).to eq(active)
        expect(resolution.match_count).to eq(1)
      end

      # @intent: { entity: "User", action: "count only active rows toward ambiguity", behavior: "two active twins still resolve ambiguous with match_count 2 even when a third archived row shares the handle", layer: "unit" }
      it "still reports ambiguity among the active rows, counting only those" do
        create_user(github_uid: "1001", github_handle: "twin")
        create_user(github_uid: "2002", github_handle: "twin")
        create_user(github_uid: "3003", github_handle: "twin").update!(archived_at: Time.current)

        resolution = described_class.resolve_by_handle("twin")

        expect(resolution).to be_ambiguous
        expect(resolution.user).to be_nil
        # 2, not 3 — the count names how many people it will not choose between, and it will never
        # choose the archived one.
        expect(resolution.match_count).to eq(2)
      end

      # @intent: { entity: "User", action: "collapse multiple archived matches to archived", behavior: "any number of archived rows sharing a handle resolves :archived once, not ambiguous, since no choice remains to make", layer: "unit" }
      it "reports :archived once, however many archived rows share the handle" do
        create_user(github_uid: "1001", github_handle: "departed").update!(archived_at: Time.current)
        create_user(github_uid: "2002", github_handle: "departed").update!(archived_at: Time.current)

        resolution = described_class.resolve_by_handle("departed")

        # Not :ambiguous. There is no choice left to be ambiguous about — none of them can be added.
        expect(resolution).to be_archived
        expect(resolution).not_to be_ambiguous
        expect(resolution.user).to be_nil
        expect(resolution.match_count).to eq(2)
      end
    end
  end

  # How this user reaches GitHub. There is no secret in this table any more: the OAuth token column
  # and its encryption went with SPGD-424, and what remains is a public numeric installation id.
  describe "connected GitHub installations" do
    describe "#github_installed?" do
      # @intent: { entity: "User", action: "report a completed installation flow", behavior: "github_installed? is true for a user with an installation row", layer: "unit" }
      it "is true for a user who has been through the installation flow" do
        expect(create_user).to be_github_installed
      end

      # What every user looks like between signing in and first connecting anything. Sign-in asks
      # GitHub for identity and connects nothing, so this is the ordinary state on arrival rather
      # than an edge case.
      # @intent: { entity: "User", action: "report no installation at sign-in", behavior: "a user whose installation_id is nil — everyone between sign-in and first connect — reads not installed", layer: "unit" }
      it "is false for a user who has signed in and gone no further" do
        expect(create_user(installation_id: nil)).not_to be_github_installed
      end

      # @intent: { entity: "User", action: "lose installation status with the rows", behavior: "destroying the github_installations rows flips github_installed? back to false on reload", layer: "unit" }
      it "is false again once the installations are gone" do
        user = create_user
        user.github_installations.destroy_all

        expect(user.reload).not_to be_github_installed
      end
    end

    # `:destroy`, unlike `repositories` and `repository_memberships`, which are `:restrict_with_error`.
    # An installation row is nobody else's data and holds no credential, so it takes nothing away
    # from a colleague — and it must not quietly make a user undestroyable for having connected
    # GitHub once.
    # @intent: { entity: "User", action: "cascade installations on destroy", behavior: "destroying a user deletes their github_installations rows rather than being refused, since an installation is nobody else's data", layer: "unit" }
    it "goes with the user rather than holding the user back" do
      user = create_user(github_uid: "7001", github_handle: "departing")

      expect { user.destroy }.to change(GithubInstallation, :count).by(-1)
      expect(user).to be_destroyed
    end
  end
end
