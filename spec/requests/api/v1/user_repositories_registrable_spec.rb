# frozen_string_literal: true

require "rails_helper"

# SPGD-768: WHAT MAY BE REGISTERED, served to a credential that cannot ask GitHub.
#
# The gap this closes is that an agent holding an `sgu_` key could only learn the answer by
# FAILING — guess a `github_full_name`, POST it, read the refusal. So the examples below are
# organised around the two things that made guessing necessary: the registrable set was served
# nowhere, and the grant's AGE (the one thing about this credential that expires) was reported
# nowhere.
RSpec.describe "API v1 — GET /api/v1/repositories/registrable", type: :request do
  let(:person) { create_user(github_uid: "1001", github_handle: "octocat") }
  let(:user_api_key) { create_user_api_key(user: person) }

  def get_registrable(token: user_api_key.raw_token)
    get "/api/v1/repositories/registrable", headers: { "Authorization" => "Bearer #{token}" }
  end

  def full_names = response.parsed_body["repositories"].map { |row| row["full_name"] }

  describe "with a current grant" do
    # The organization member's fixture, and each part of it is load-bearing. `acme/ledger` is
    # VISIBLE but not administered — the set this reading must not serve. `acme/checkout` is
    # administered AND already registered — the entry that must appear MARKED rather than dropped.
    before do
      create_registration_grant(user: person,
                                registrable: ["acme/billing-service", "acme/checkout"],
                                visible: ["acme/billing-service", "acme/checkout", "acme/ledger"])
    end

    # SUCCESS CRITERION 1, stated as the thing that was impossible before: the list arrives from a
    # read, with no registration attempted and nothing written.
    # @intent: { entity: "registrable reading", action: "serve the registrable set", behavior: "a GET hands back the administered names with no registration attempted and nothing written", layer: "request" }
    it "serves the registrable set without attempting a registration" do
      expect { get_registrable }.not_to change(Repository, :count)

      expect(response).to have_http_status(:ok)
      expect(full_names).to eq(["acme/billing-service", "acme/checkout"])
    end

    # SUCCESS CRITERION 2. MARKED, not excluded — an already-registered name is the answer to "why
    # did my POST say `has already been taken`", and dropping it would make that state
    # indistinguishable from having lost admin on it.
    # @intent: { entity: "registrable reading", action: "mark already-registered names", behavior: "a taken name stays in the list flagged registered rather than dropped, keeping it distinct from lost admin", layer: "request" }
    it "distinguishes an already-registered repository from one that is not yet registered" do
      create_repository(user: person, github_full_name: "acme/checkout")

      get_registrable

      expect(response.parsed_body["repositories"])
        .to eq([{ "full_name" => "acme/billing-service", "registered" => false },
                { "full_name" => "acme/checkout", "registered" => true }])
    end

    # The `registered` flag is about the NAME being taken, not about what this person can open —
    # which is what makes it useful. A repository somebody else registered refuses this person's
    # POST with `has already been taken` just the same, so a flag scoped to `accessible_by` would
    # read `false` and send them at a name that cannot be registered by anyone.
    # @intent: { entity: "registrable reading", action: "flag a stranger registration without disclosure", behavior: "a name registered by somebody else reads registered true and the row carries only the name and the flag, never an id or owner", layer: "request" }
    it "marks a name registered by somebody else as taken, without disclosing anything about it" do
      stranger = create_user(github_uid: "2002", github_handle: "hubot")
      create_repository(user: stranger, github_full_name: "acme/checkout")

      get_registrable

      expect(response.parsed_body["repositories"])
        .to include("full_name" => "acme/checkout", "registered" => true)
      # The name and the fact that it is taken, and nothing else about the record — no id, no
      # owner. Both are already GitHub's answer about this person's own admin access.
      #
      # Asserted on the PARSED KEYS rather than as `not_to include(theirs.id.to_s)` against the raw
      # body. That substring form was a guard that could not fail for the right reason and could
      # fail for a wrong one: this response carries no id-shaped field at all, so no code path could
      # emit one — while the body is mostly ISO-8601 timestamps, so a short id matches by accident.
      # Measured on this very request: id=8587 -> absent, id=3 -> PRESENT, inside
      # "2026-09-03T13:28:27Z". Whether it passed depended on how many digits the sequence had
      # handed out, which is why it survived alone and failed in a multi-file run. Pinning the key
      # set is exact, order-independent, and actually states the property — anything beyond these
      # two fields is a disclosure, whatever it is named and whatever digits it contains.
      expect(response.parsed_body["repositories"].flat_map(&:keys).uniq).to eq(%w[full_name registered])
      expect(response.body).not_to include("hubot")
    end

    # `visible_full_names` grants nothing — it exists only to decide WHICH refusal is true (see
    # `GrantVerifier`). Serving it would be a picker that offers what the write refuses.
    # @intent: { entity: "registrable reading", action: "serve only administered repos", behavior: "the wider visible set never reaches the list, so the reading offers nothing the write would refuse", layer: "request" }
    it "serves only what the person administers, never the wider visible set" do
      get_registrable

      expect(full_names).not_to include("acme/ledger")
      expect(response.body).not_to include("ledger")
    end

    # The three facts about the grant that were knowable nowhere. `expires_at` is asserted as
    # `captured_at + MAX_AGE` read from the constant, not as a literal seven days, so the response
    # cannot drift from the bound `stale?` actually divides on.
    # @intent: { entity: "registrable grant block", action: "report capture and expiry", behavior: "the grant object serves captured_at, an expires_at derived from the same MAX_AGE constant and a stale false", layer: "request" }
    it "reports when the record was taken, when it lapses, and that it is current" do
      captured_at = 2.days.ago
      person.github_registration_grant.update!(captured_at: captured_at)

      get_registrable

      expect(response.parsed_body["grant"])
        .to eq("captured_at" => captured_at.iso8601,
               "expires_at" => (captured_at + GithubRegistrationGrant::MAX_AGE).iso8601,
               "stale" => false)
    end

    # SUCCESS CRITERION 4, pinned at the GITHUB SEAM rather than at the database one. `queries_against`
    # counts SQL and could not see a GitHub round trip at all; `FakeGithubApi#calls` is the log the
    # suite's stub keeps for exactly this question. The claim is ZERO, not "few" — this request has
    # no user token to ask with, so a call from here would ask with nothing and get `:not_authorized`.
    # @intent: { entity: "registrable reading", action: "make no GitHub call", behavior: "the request asks GitHub nothing because it holds no user token to ask with; the stubbed call log stays empty", layer: "request" }
    it "makes no GitHub call at all" do
      github = stub_github

      get_registrable

      expect(response).to have_http_status(:ok)
      expect(github.calls).to be_empty
    end

    # The other half of criterion 4, and the one a call counter cannot see: `capture` REPLACES the
    # whole row. A refresh attempted from here would ask GitHub with no token, get an incomplete
    # reading — and, were `complete?` ever to admit it, overwrite a good grant with an empty one.
    # @intent: { entity: "GithubRegistrationGrant", action: "read without refreshing", behavior: "serving the reading neither captures, replaces nor restamps the grant row it read", layer: "request" }
    it "does not refresh, replace or restamp the grant it is reading" do
      grant = person.github_registration_grant
      before_state = grant.attributes

      expect(GithubRegistrationGrant).not_to receive(:capture)

      get_registrable

      expect(grant.reload.attributes).to eq(before_state)
    end

    # @intent: { entity: "user api key", action: "stamp last use", behavior: "a successful read sets last_used_at on the authenticating key", layer: "request" }
    it "records when the key was last used" do
      expect(user_api_key.last_used_at).to be_nil

      get_registrable

      expect(user_api_key.reload.last_used_at).to be_present
    end

    # @intent: { entity: "registrable reading", action: "answer an empty grant as a list", behavior: "a grant covering nothing yields an empty 200 list with a current grant block, not a refusal", layer: "request" }
    it "answers an empty list — not a refusal — for a grant that covers nothing" do
      person.github_registration_grant.update!(registrable_full_names: [], visible_full_names: [])

      get_registrable

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["repositories"]).to eq([])
      expect(response.parsed_body["grant"]["stale"]).to be(false)
    end

    # `github_full_name` is the ordering `#index` promises for the same reason: the only column on
    # this list a client could page or diff against.
    # @intent: { entity: "registrable reading", action: "order by full name", behavior: "the served list is sorted by name regardless of the order the grant recorded its sets in", layer: "request" }
    it "orders by full name whatever order the grant recorded them in" do
      person.github_registration_grant
            .update!(registrable_full_names: ["acme/zeta", "acme/alpha", "acme/middle"])

      get_registrable

      expect(full_names).to eq(["acme/alpha", "acme/middle", "acme/zeta"])
    end
  end

  # SUCCESS CRITERION 3. The two states `GrantVerifier#verdict_for` refuses on — `@grant.nil? ||
  # @grant.stale?` — answered with the SAME sentence, read from the constant.
  describe "with no usable grant" do
    # THE ANTI-DRIFT ASSERTION, and the reason it is written against the constant rather than
    # against the sentence: a copy of the wording pasted into the controller would pass an example
    # that quoted the words, and would then be free to diverge from the POST's refusal the day
    # either is edited. Interpolating the constant here means the example can only pass while the
    # two surfaces share one string.
    shared_examples "the gate's own refusal" do
      # @intent: { entity: "registrable refusal", action: "quote the shared not-granted message", behavior: "the forbidden body carries the constant message interpolated, so the GET cannot drift from the POST refusal wording", layer: "request" }
      it "answers with `MESSAGES[:not_granted]`, read from the constant rather than re-typed" do
        get_registrable

        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body["error"]).to eq("not_granted")
        expect(response.parsed_body["message"])
          .to eq("Your repositories #{InstallationRepositories::MESSAGES.fetch(:not_granted)}")
      end

      # The sentence the POST gives for the same account, on the same day, is the same sentence —
      # which is the property criterion 3 is actually about, asserted between the two SURFACES
      # rather than between one surface and a literal.
      # @intent: { entity: "registrable refusal", action: "mirror the POST refusal sentence", behavior: "the reading message and a refused POST for the same account on the same day contain the same sentence", layer: "request" }
      it "tells the caller what a refused POST would tell them" do
        get_registrable
        reading = response.parsed_body["message"]

        post "/api/v1/repositories", params: { github_full_name: "acme/billing-service" },
                                     headers: { "Authorization" => "Bearer #{user_api_key.raw_token}" }

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["message"]).to include(
          InstallationRepositories::MESSAGES.fetch(:not_granted)
        )
        expect(reading).to include(InstallationRepositories::MESSAGES.fetch(:not_granted))
      end

      # @intent: { entity: "registrable refusal", action: "serve no list beside the refusal", behavior: "a refused reading carries no repositories key a client might read instead of the reason", layer: "request" }
      it "serves no repository list to read instead of the refusal" do
        get_registrable

        expect(response.parsed_body).not_to have_key("repositories")
      end

      # @intent: { entity: "registrable refusal", action: "ask GitHub nothing", behavior: "the path to the refusal makes no GitHub round trip, verified against the stub call log", layer: "request" }
      it "asks GitHub nothing on the way to refusing" do
        github = stub_github

        get_registrable

        expect(github.calls).to be_empty
      end
    end

    context "when no grant was ever captured" do
      include_examples "the gate's own refusal"

      # "You never had one" and "yours lapsed" are different facts with the same fix, and a caller
      # that cannot tell them apart cannot say which. `null` here is what says which.
      # @intent: { entity: "registrable grant block", action: "report null for a never-captured grant", behavior: "when no grant exists the grant key is present and null, distinguishing never-had-one from lapsed", layer: "request" }
      it "reports no grant block at all, rather than an invented one" do
        get_registrable

        expect(response.parsed_body).to have_key("grant")
        expect(response.parsed_body["grant"]).to be_nil
      end
    end

    context "when the grant is past MAX_AGE" do
      # A minute past the bound rather than a round month, so the example is pinned to `MAX_AGE`
      # itself: widening the bound must make this fixture fresh again and fail here.
      let!(:lapsed) do
        create_registration_grant(user: person, registrable: ["acme/billing-service"],
                                  captured_at: (GithubRegistrationGrant::MAX_AGE + 1.minute).ago)
      end

      include_examples "the gate's own refusal"

      # A stale grant still reports its own age. "Your access lapsed four days ago" is actionable
      # in a way a bare refusal is not, and it is the fact that was visible on no surface at all.
      # @intent: { entity: "registrable grant block", action: "report a lapsed grant own dates", behavior: "a stale grant still serves its captured_at and computed expires_at with stale true, the age fact no other surface showed", layer: "request" }
      it "still reports when the lapsed record was taken and when it lapsed" do
        get_registrable

        expect(response.parsed_body["grant"])
          .to eq("captured_at" => lapsed.captured_at.iso8601,
                 "expires_at" => (lapsed.captured_at + GithubRegistrationGrant::MAX_AGE).iso8601,
                 "stale" => true)
      end

      # The bound is the model's, not a second copy of it living in the controller — asserted by
      # the fixture above, which is written as `MAX_AGE + 1.minute` rather than as a literal eight
      # days. A controller that re-compared the timestamp against a hard-coded seven days would
      # answer this fixture identically today and diverge the moment the constant moved.
      #
      # Deliberately NOT `expect_any_instance_of(...).to receive(:stale?)`: that pins the NUMBER OF
      # CALL SITES on an arbitrary instance rather than the behaviour, so a refactor that read the
      # same model method one more or one fewer time would fail an example about staleness for a
      # reason that has nothing to do with staleness. (`any_instance_of` appears 5 times in this
      # whole suite, and this is not one of the cases that needs it.)
    end
  end

  # The credential seam, in the direction `spec/requests/api/v1/credential_seam_spec.rb` walks it.
  # A new route is exactly where the `accepts_user_credential` declaration is forgotten, and this
  # endpoint reads a PERSON's GitHub permissions — the payload a repository key must never resolve.
  describe "the credential seam" do
    # @intent: { entity: "registrable credential seam", action: "refuse a repository key", behavior: "an sgk key resolves no person and the reading answers 401 rather than leaking a person permissions", layer: "request" }
    it "refuses an `sgk_` repository key with 401" do
      repository = create_repository(user: person)

      get_registrable(token: repository.api_keys.create!.raw_token)

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["error"]).to eq("unauthorized")
    end

    # @intent: { entity: "registrable credential seam", action: "refuse an unknown user token", behavior: "a token that authenticates no user answers 401", layer: "request" }
    it "refuses an unknown user token with 401" do
      get_registrable(token: "sgu_definitely-not-a-key")

      expect(response).to have_http_status(:unauthorized)
    end

    # @intent: { entity: "registrable credential seam", action: "refuse a missing header", behavior: "a request with no Authorization header answers 401", layer: "request" }
    it "refuses a missing Authorization header with 401" do
      get "/api/v1/repositories/registrable"

      expect(response).to have_http_status(:unauthorized)
    end

    # The refusal is at the door, before the grant is read — so a 401 must not have looked up a
    # person's permissions on the way to being refused.
    # @intent: { entity: "registrable credential seam", action: "read no grant after refusal", behavior: "a refused credential performs no grant lookup on the way to the 401, so the door refuses before the permissions read", layer: "request" }
    it "reads no grant for a refused credential" do
      create_registration_grant(user: person)
      repository = create_repository(user: person)
      token = repository.api_keys.create!.raw_token

      statements = queries_against("github_registration_grants") { get_registrable(token: token) }

      expect(response).to have_http_status(:unauthorized)
      expect(statements).to be_empty
    end
  end

  # The reading serves one person's grant and there is no parameter through which another's could
  # be asked for — the ownership is the CREDENTIAL, exactly as it is on `#create`.
  # @intent: { entity: "registrable reading", action: "serve only the holder grant", behavior: "there is no parameter naming another person and the reading serves only the credential holder own registrable set", layer: "request" }
  it "serves the holder's own grant and no way to name somebody else's" do
    stranger = create_user(github_uid: "2002", github_handle: "hubot")
    create_registration_grant(user: stranger, registrable: ["acme/stranger-only"])
    create_registration_grant(user: person, registrable: ["acme/billing-service"])

    get_registrable

    expect(full_names).to eq(["acme/billing-service"])
    expect(response.body).not_to include("stranger-only")
  end

  # The endpoint this one sits beside is untouched: a client reading `GET /api/v1/repositories` is
  # unaffected, and — the half a path is easy to get wrong — the literal segment is not swallowed
  # as a parameter of it.
  # @intent: { entity: "repositories index", action: "leave the sibling route alone", behavior: "the literal registrable segment is not swallowed by the repositories index, which serves its owned list exactly as before", layer: "request" }
  it "leaves `GET /api/v1/repositories` serving what it always served" do
    create_registration_grant(user: person, registrable: ["acme/billing-service", "acme/unregistered"])
    owned = create_repository(user: person, github_full_name: "acme/billing-service")

    get "/api/v1/repositories", headers: { "Authorization" => "Bearer #{user_api_key.raw_token}" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["repositories"].map { |row| row["full_name"] })
      .to eq([owned.github_full_name])
    expect(response.body).not_to include("unregistered")
  end
end
