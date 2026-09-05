# frozen_string_literal: true

require "rails_helper"

# SPGD-752 success criterion 3, which is the criterion that decides the ticket: the seam between the
# two credentials holds IN BOTH DIRECTIONS, asserted rather than assumed.
#
# The asymmetry is why both directions need their own examples. A `sgk_` key sent to the user
# endpoint resolves no person, and a list built from `nil` is an obvious failure. A `sgu_` key sent
# to `POST /api/v1/ingest` resolves no repository, and that one is NOT obvious: the ingest path
# passes `current_repository` straight into its recorders on the strength of authentication having
# got that far, so a leaked `nil` surfaces as a 500 or as telemetry attributed to nothing.
RSpec.describe "API v1 — the credential seam", type: :request do
  let(:person) { create_user(github_uid: "1001", github_handle: "octocat") }
  let(:repository) { create_repository(user: person) }

  let(:repository_key) { repository.api_keys.create! }
  let(:user_key) { create_user_api_key(user: person) }

  def bearer(token) = { "Authorization" => "Bearer #{token}" }

  # The SECOND decision the ticket makes, and the one the 401s above cannot see: the seam is held by
  # discriminating on the PREFIX, so a cross-presented token is refused without reading anything.
  #
  # `queries_against` comes from spec/support/query_capture.rb. Counting reads of BOTH credential
  # tables — not one — is what makes this a guard rather than a restatement: the failure mode it
  # exists to catch is an implementation that probes `api_keys`, misses, then probes
  # `user_api_keys`. That implementation passes every example above, since it produces exactly the
  # same 401, and doubles the cost of every request in the process. Cached repeats and
  # transactions are deliberately in the count here; a refusal that reads nothing has none of
  # either.
  describe "the prefix, which decides before anything is read" do
    # `"api_keys"` is a substring of `"user_api_keys"`, so this one filter counts statements against
    # BOTH tables — which is exactly the population these examples need to see nothing of.
    def credential_reads(&)
      queries_against("api_keys", &)
    end

    # A WIDER population than `credential_reads`, and the difference is the whole point of it.
    #
    # `Api::BaseController` claims authentication costs one indexed read. Two different regressions
    # would falsify that, and they land on DIFFERENT TABLES: probing the second credential table
    # (caught by `credential_reads`), and reading the resolved person a second time to bind the
    # principal (invisible to it — that read is against `users`). A filter naming only the
    # credential tables reports "exactly one read" while the request makes two, so the cost claim
    # has to be measured over both tables or it is not measured at all.
    #
    # This is not hypothetical: `UserApiKey.authenticate` spelled with `joins(:user)` instead of
    # `eager_load(:user)` filters through the `users` row without populating the association, and
    # `bind_principal`'s `.user` then re-reads it by primary key on EVERY authenticated request.
    # `"users"` is quoted so the filter matches the table and not the substring in `user_api_keys`.
    def authentication_reads(&)
      queries_against(/api_keys|"users"/, &)
    end

    # @intent: { entity: "credential seam", action: "decide on the prefix", behavior: "a cross-presented token is refused 401 without a single statement touching either credential table", layer: "request" }
    it "reads no credential table at all when the prefix does not match the endpoint" do
      # Resolved OUTSIDE the measured block: minting a key is itself two statements against a
      # credential table, and a lazily-evaluated `let` inside would count them as the request's.
      token = repository_key.raw_token

      statements = credential_reads { get "/api/v1/repositories", headers: bearer(token) }

      expect(response).to have_http_status(:unauthorized)
      expect(statements).to be_empty
    end

    # The other direction of the same refusal. The mechanism is shared, so this is not a hole
    # today — but the header of this file argues that the two directions are asymmetric and each
    # needs its own examples, and that argument does not stop applying to the zero-read half. This
    # is the direction where a leaked `nil` repository would be recorded rather than raised, so it
    # is the one worth pinning twice.
    # @intent: { entity: "credential seam", action: "refuse a user key at ingest", behavior: "a user key sent to the ingest endpoint is refused before any read, the direction where a leaked nil would be recorded rather than raised", layer: "request" }
    it "reads no credential table when a user key is presented to the ingest endpoint" do
      token = user_key.raw_token

      statements = credential_reads do
        post "/api/v1/ingest", params: ingest_payload, as: :json, headers: bearer(token)
      end

      expect(response).to have_http_status(:unauthorized)
      expect(statements).to be_empty
    end

    # @intent: { entity: "credential seam", action: "refuse an unprefixed token", behavior: "a token with no recognized prefix is refused with zero credential reads on either table", layer: "request" }
    it "reads no credential table for a token carrying neither prefix" do
      statements = credential_reads do
        get "/api/v1/repositories", headers: bearer("nonsense-with-no-prefix")
      end

      expect(response).to have_http_status(:unauthorized)
      expect(statements).to be_empty
    end

    # The positive control for the zeroes above: without it they would also pass against an
    # endpoint that had stopped authenticating anything. Measured over `authentication_reads`, so
    # the SAME example is also the guard on the cost claim — it sees every table a valid
    # presentation touches to get its principal, not just the one it was resolved from.
    #
    # Two statements, and the second is not a read: the `SELECT` that resolves the key, and the
    # `last_used_at` stamp. Asserted three ways, because each catches a different regression.
    # @intent: { entity: "credential seam", action: "resolve in one read", behavior: "a valid presentation resolves with exactly one credential select plus the last_used_at stamp, the person never re-read on their own", layer: "request" }
    it "resolves a valid presentation in one read, and reads the person no second time" do
      token = user_key.raw_token

      statements = authentication_reads { get "/api/v1/repositories", headers: bearer(token) }

      expect(response).to have_http_status(:ok)

      # (1) One credential read, against the ONE table the endpoint declared for — the original
      # control, unchanged in what it claims.
      expect(statements.grep(/FROM "user_api_keys"/).size).to eq(1)
      expect(statements.grep(/FROM "api_keys"/)).to be_empty

      # (2) The person is never SELECTed on their own. The resolving statement reads `users`
      # through a JOIN and carries its columns back, so `bind_principal` has nothing left to
      # fetch; a statement whose own `FROM` is `users` means it went and got them again.
      expect(statements.grep(/FROM "users"/)).to be_empty

      # (3) The total, so a THIRD read appearing against any of these tables fails here even if it
      # is spelled in a way (1) and (2) do not recognise.
      expect(statements.size).to eq(2)
    end
  end

  describe "a repository key (`sgk_`) at a user-key endpoint" do
    # @intent: { entity: "credential seam", action: "refuse a repository key", behavior: "a repository key at the user endpoint answers 401 with the unauthorized JSON error", layer: "request" }
    it "is refused by GET /api/v1/repositories with 401" do
      get "/api/v1/repositories", headers: bearer(repository_key.raw_token)

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["error"]).to eq("unauthorized")
    end

    # The refusal is at the door, before any lookup — so it must not look like a use of the key on
    # the repository page's "Last used" column either.
    # @intent: { entity: "credential seam", action: "leave the key unstamped", behavior: "the door-refusal leaves the repository key last_used_at nil so the rejection never masquerades as a use", layer: "request" }
    it "does not stamp the refused key as used" do
      get "/api/v1/repositories", headers: bearer(repository_key.raw_token)

      expect(repository_key.reload.last_used_at).to be_nil
    end
  end

  # SPGD-804: the ONE 401 the platform can attribute. A revoked repository key is retired, not
  # deleted — the row remains, the digest still names it, and the platform stamped the instant the
  # token was retired. So when the dead token arrives and is refused, the failure path stamps the
  # presentation on the row it belongs to (`last_refused_at`), and the repository page and
  # `credential_health` can report "a key you revoked is still being presented". Every other 401
  # stays unattributable: a token that was never a key resolves to no row, and nothing is written.
  describe "a revoked repository key arriving at a repository-key endpoint" do
    def credential_reads(&)
      queries_against("api_keys", &)
    end

    # The positive case, and its exact shape: the 401 costs TWO reads of the table — resolution's
    # `authenticate` (which the revoked filter empties) and the failure path's one lookup on the
    # same unique digest index — plus the stamp, which is the point of the path. Asserted as
    # separate SELECT and UPDATE counts so a second lookup could not hide inside a total that also
    # contains the write.
    # @intent: { entity: "credential seam", action: "attribute a revoked presentation", behavior: "a revoked token is refused 401 and stamps last_refused_at on the retained row, costing resolution plus exactly one failure-path lookup plus the write", layer: "request" }
    it "refuses the revoked token and stamps the refused presentation on its row" do
      revoked_token = repository_key.raw_token
      repository_key.revoke!

      statements = credential_reads do
        get "/api/v1/repository", headers: bearer(revoked_token)
      end

      expect(response).to have_http_status(:unauthorized)
      # Two: the resolution SELECT, then the failure path's revoked-row lookup. A THIRD would be
      # the failure path wandering.
      expect(statements.grep(/FROM "api_keys"/).size).to eq(2)
      expect(statements.grep(/UPDATE "api_keys"/).size).to eq(1)
      expect(repository_key.reload.revoked_at).to be_present
      expect(repository_key.reload.last_refused_at).to be_present
    end

    # A LIVE key that fails for another reason cannot exist on this path — `authenticate` returns
    # nil only for an unknown digest or a revoked row — so the miss IS the unknown token: the same
    # two reads (resolution, then the lookup that finds nothing) and NO write. The unattributable
    # 401 stays unattributable.
    # @intent: { entity: "credential seam", action: "leave an unknown token unattributable", behavior: "a token that was never a key is refused with resolution plus one empty lookup and no write anywhere", layer: "request" }
    it "writes nothing for a token that was never a key" do
      statements = credential_reads do
        get "/api/v1/repository", headers: bearer("sgk_not-a-key-anywhere")
      end

      expect(response).to have_http_status(:unauthorized)
      expect(statements.grep(/FROM "api_keys"/).size).to eq(2)
      expect(statements.grep(/UPDATE "api_keys"/)).to be_empty
      expect(ApiKey.where.not(last_refused_at: nil)).to be_empty
    end

    # The class guard stated in `attribute_refused_revocation`, asserted: a `sgu_` token failing
    # for a reason of its own (here: no such user key at all) is resolved against ITS OWN table —
    # which this filter sees, because `"api_keys"` is a substring of `"user_api_keys"` — and must
    # probe no `api_keys` row. So the assertion is on the quoted `FROM "api_keys"` spelling, which
    # cannot match the user-key table: the failure-path lookup is `ApiKey`-class-guarded, and this
    # is what proves it.
    # @intent: { entity: "credential seam", action: "guard the credential class", behavior: "a failing user-key presentation resolves its own table and reads no api_keys row at all", layer: "request" }
    it "never probes the repository-key table for a user-key failure" do
      statements = credential_reads do
        get "/api/v1/repositories", headers: bearer("sgu_not-a-key-anywhere")
      end

      expect(response).to have_http_status(:unauthorized)
      # The resolution itself ran (against `user_api_keys` — its own table), so the population is
      # not empty; what must be empty is the `api_keys` half.
      expect(statements).to be_present
      expect(statements.grep(/FROM "api_keys"/)).to be_empty
      expect(statements.grep(/UPDATE/)).to be_empty
    end

    # The cost claim, held on the OTHER path: a valid presentation never reaches the failure-path
    # lookup at all — the stamping is gated on `authenticate` returning nil. This is the control
    # the two examples above need: without it, an implementation that ran the revoked-row lookup
    # before the nil check would still pass them (a revoked token finds its row either way) while
    # quietly adding a read to every valid request.
    #
    # TWO reads here, and both are owed: the resolution, and the keys SELECT
    # `credential_health` has always loaded to build this body — neither is new. The one UPDATE is
    # the `last_used_at` stamp every authenticated request has always paid.
    # @intent: { entity: "credential seam", action: "keep the valid path flat", behavior: "a valid presentation costs resolution plus the credential_health keys load plus the last_used_at stamp, and never runs the failure-path lookup or a refusal write", layer: "request" }
    it "adds no lookup to a valid presentation" do
      token = repository_key.raw_token

      statements = credential_reads do
        get "/api/v1/repository", headers: bearer(token)
      end

      expect(response).to have_http_status(:ok)
      expect(statements.grep(/FROM "api_keys"/).size).to eq(2)
      expect(statements.grep(/UPDATE "api_keys"/).size).to eq(1)
      expect(statements.grep(/last_refused_at/)).to be_empty
    end
  end

  describe "a user key (`sgu_`) at a repository-key endpoint" do
    # @intent: { entity: "credential seam", action: "refuse a user key at show", behavior: "a user key at the repository endpoint answers 401", layer: "request" }
    it "is refused by GET /api/v1/repository with 401" do
      get "/api/v1/repository", headers: bearer(user_key.raw_token)

      expect(response).to have_http_status(:unauthorized)
    end

    # @intent: { entity: "credential seam", action: "refuse a user key at ingest", behavior: "a user key at the ingest endpoint answers 401 before the payload is read", layer: "request" }
    it "is refused by POST /api/v1/ingest with 401" do
      post "/api/v1/ingest", params: ingest_payload, as: :json,
                             headers: bearer(user_key.raw_token)

      expect(response).to have_http_status(:unauthorized)
    end

    # The specific harm the 401 above prevents, asserted directly: a leaked `nil` repository would
    # not raise where it is written, it would record a run against nothing.
    # @intent: { entity: "credential seam", action: "record nothing", behavior: "the refused ingest writes neither a test run nor an ingest rejection, so a leaked nil repository records nothing against nothing", layer: "request" }
    it "records no run and no rejection from the refused ingest" do
      post "/api/v1/ingest", params: ingest_payload, as: :json,
                             headers: bearer(user_key.raw_token)

      expect(TestRun.count).to eq(0)
      expect(IngestRejection.count).to eq(0)
    end

    # @intent: { entity: "credential seam", action: "leave the key unstamped", behavior: "the refusal leaves the user key last_used_at nil", layer: "request" }
    it "does not stamp the refused key as used" do
      get "/api/v1/repository", headers: bearer(user_key.raw_token)

      expect(user_key.reload.last_used_at).to be_nil
    end
  end

  # SPGD-752 success criterion 4, over HTTP. The model spec proves the resolution site refuses an
  # archived owner; this proves nothing downstream un-refuses it.
  describe "a key belonging to an archived person" do
    # @intent: { entity: "credential seam", action: "retire an archived person", behavior: "archiving the person un-authenticates a token that answered 200 moments earlier", layer: "request" }
    it "stops authenticating the request that worked a moment earlier" do
      get "/api/v1/repositories", headers: bearer(user_key.raw_token)
      expect(response).to have_http_status(:ok)

      person.update!(archived_at: Time.current)

      get "/api/v1/repositories", headers: bearer(user_key.raw_token)
      expect(response).to have_http_status(:unauthorized)
    end
  end

  # `Api::BaseController` fails CLOSED: a controller that has declared no credential answers 401 to
  # everything, valid keys included. That is the safe direction and it is deliberate — but on its
  # own it is silent, and a forgotten declaration would present to whoever holds a key as "my key
  # stopped working" with nothing naming the controller.
  #
  # This is the guard that makes it loud instead, and it is why the trade is acceptable: the
  # omission fails HERE, at the name of the offending class, rather than in production.
  describe "the declaration every endpoint must make" do
    # @intent: { entity: "credential declaration", action: "fail closed", behavior: "the base controller declares no accepted credential, so an undeclared endpoint answers 401 to everything", layer: "request" }
    it "is absent by default, so an endpoint that says nothing accepts nothing" do
      expect(Api::BaseController.accepted_credentials).to be_empty
    end

    # @intent: { entity: "credential declaration", action: "cover every route", behavior: "every routed controller under the api namespace declares its accepted credential, naming any that forgot in the failure message", layer: "request" }
    it "is made by every routed endpoint" do
      undeclared = Rails.application.routes.routes.filter_map { |route|
        controller = route.defaults[:controller]
        next unless controller&.start_with?("api/")

        klass = "#{controller.camelize}Controller".safe_constantize
        klass&.name if klass && klass <= Api::BaseController && klass.accepted_credentials.empty?
      }.uniq

      expect(undeclared).to be_empty,
                            "these endpoints declare no credential and will 401 every request: " \
                            "#{undeclared.join(", ")}"
    end
  end

  # SPGD-952: there are THREE credential classes now, and the dispatch that decides among them
  # still costs nothing because the prefixes are same-length and mutually exclusive — no one of
  # them is a prefix of another, so `authenticate_api_key!`'s scan over the declaration can match
  # at most one class and never has to probe a second table. This is the invariant the base
  # controller's comment rests on; if a fourth credential ships with a prefix that breaks it, it
  # fails HERE, at the invariant, rather than as a doubled read count in production.
  describe "the prefix discipline across every credential class" do
    # @intent: { entity: "credential prefix", action: "keep the dispatch unambiguous", behavior: "every credential prefix is the same length and a prefix of no sibling, so prefix dispatch always names exactly one table", layer: "request" }
    it "keeps every prefix the same length and disjoint from its siblings" do
      prefixes = [ApiKey, UserApiKey, AgentApiKey].map { |klass| klass::TOKEN_PREFIX }

      expect(prefixes.uniq.size).to eq(prefixes.size), "two credential classes share a prefix"
      expect(prefixes.map(&:length).uniq.size).to eq(1), "credential prefixes drifted apart in length"
      prefixes.permutation(2).each do |first, second|
        expect(second).not_to start_with(first),
                              "the #{first.inspect} prefix is a prefix of #{second.inspect}"
      end
    end

    # The third direction of the zero-read refusal, for the credential this slice adds: an `sga_`
    # token at an endpoint that accepts neither the agent nor the repository credential is turned
    # away before any table is read.
    # @intent: { entity: "credential prefix", action: "refuse an agent key at an undeclaring endpoint", behavior: "an sga_ token at a user-key-only endpoint answers 401 with zero credential reads", layer: "request" }
    it "reads no credential table when an agent key is presented to a user-key-only endpoint" do
      # Built from its OWN repository rather than the file's `repository` let: that let is
      # evaluated lazily, and referencing it inside the measured block would count the mint as
      # one of the request's statements — the same trap the first example in this file documents.
      repo = create_repository(user: person, github_full_name: "acme/not-reachable")
      token = create_agent_api_key(user: person, repositories: [repo], permissions: []).raw_token

      statements = queries_against("api_keys") do
        post "/api/v1/repositories/#{repo.id}/api_keys", headers: bearer(token)
      end

      expect(response).to have_http_status(:unauthorized)
      expect(statements).to be_empty
    end
  end
end
