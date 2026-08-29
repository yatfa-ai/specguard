# frozen_string_literal: true

require "rails_helper"

# SPGD-798: `GET /api/v1/repositories/:id` — the repository overview, for a repository named by id,
# under an `sgu_` user key.
#
# ## What was missing, and why the gap was not cosmetic
#
# An agent holding a user key could enumerate its person's repositories (`GET /api/v1/repositories`)
# and then open NONE of them: that list serves six identity fields and the singular overview route
# answers only to an `sgk_` repository key. The workaround was not merely awkward, it was
# unavailable — `ApiKey` is digest-only and reveal-once, so an EXISTING repository's key is not
# recoverable, and the only way through was minting N new production ingest keys purely to read.
#
# ## The two halves this file has to prove, because they fail independently
#
# 1. THE NEW ROUTE ANSWERS — the right body, for both access paths, refusing the ones it must.
# 2. THE OLD ROUTE DID NOT MOVE. The body is now assembled by `RepositoryOverview` rather than read
#    off `current_repository` in the controller, which is a refactor of ~3,500 lines of serializer
#    under a shipped contract. The regression net for that is the existing per-block request specs
#    (`repository_latest_run_spec.rb` and its siblings), which pass UNMODIFIED — that is the claim,
#    and it is worth more than anything this file could restate. What this file adds is the
#    EQUIVALENCE: the two routes are asserted against each other, block for block, so the two cannot
#    drift apart later even though both would still pass their own examples.
RSpec.describe "API v1 — GET /api/v1/repositories/:id", type: :request do
  # The three-way fixture `user_repositories_spec.rb` establishes for `#index`, reused deliberately:
  # OWNED and MEMBER are the two halves of `accessible_by`'s union, and INVISIBLE is the one that
  # proves the scope is not `Repository.all`.
  let(:person) { create_user(github_uid: "1001", github_handle: "octocat") }
  let(:stranger) { create_user(github_uid: "2002", github_handle: "hubot") }

  let!(:owned) { create_repository(user: person, github_full_name: "acme/billing-service") }
  let!(:shared) do
    create_repository(user: stranger, github_full_name: "acme/ledger").tap do |repository|
      create_membership(repository: repository, user: person)
    end
  end
  let!(:invisible) { create_repository(user: stranger, github_full_name: "acme/secret-payroll") }

  let(:user_api_key) { create_user_api_key(user: person) }

  def bearer(token) = { "Authorization" => "Bearer #{token}" }

  # `query:` rather than named keywords, so an example can send the shapes a real client's malformed
  # query string parses into — an Array, a nested hash — the same way it sends a path.
  def get_repository(id: owned.id, token: user_api_key.raw_token, query: {})
    get "/api/v1/repositories/#{id}", params: query, headers: bearer(token)

    response.parsed_body
  end

  # The run every drill-in example below reads. Written by `Ingest::RunRecorder` rather than
  # inserted by hand — the rule every sibling spec on this endpoint states, because an area is the
  # parent directory of a `spec_file_path` a real payload carried and an untimed example is
  # `result&.run_time` coming back nil on a real client.
  def ingest(repository, specs, commit_sha: "feedfacecafe0001", branch: "main", **attrs)
    Ingest::RunRecorder.record(
      repository,
      { commit_sha: commit_sha, branch: branch, total_specs_count: specs.size,
        annotated_specs_count: 0, duration_seconds: 60.0 }.merge(attrs),
      specs: specs.map(&:deep_stringify_keys)
    )
  end

  # One example on the wire, through the SHARED builder rather than a hand-written hash — the row
  # shape is `Ingest::Payload`'s and a local copy of it drifts from what a real client sends (and,
  # missing a NOT NULL column, does not even reach the table).
  def example_row(file_path:, line_number: 1, **attrs)
    unannotated_spec(file_path: file_path, line_number: line_number, **attrs)
  end

  # SUCCESS CRITERION 1 — an owned repository answers with the overview.
  describe "a repository the person owns" do
    # @intent: { entity: "UserRepositoryOverview", action: "answer the route", behavior: "an owned repository responds 200 on the user-keyed singular overview route", layer: "request" }
    it "answers 200" do
      get_repository

      expect(response).to have_http_status(:ok)
    end

    # @intent: { entity: "UserRepositoryOverview", action: "identify the repository", behavior: "the repository block echoes the id, full name and name of the repository the path named", layer: "request" }
    it "identifies the repository that was asked for" do
      expect(get_repository["repository"])
        .to include("id" => owned.id, "full_name" => "acme/billing-service", "name" => "billing-service")
    end

    # ⭐ THE CRITERION STATED AS AN EQUIVALENCE RATHER THAN AS A LIST OF KEYS, which is the form that
    # keeps working. A hand-written list of the top-level blocks would be a second copy of the
    # contract, free to fall behind the endpoint the day a block is added — and the block added
    # without a line here is exactly the one that would go unserved on this route and unnoticed.
    #
    # Asserted against the SINGULAR route's own live response, so the claim is "these two routes
    # serve the same blocks" rather than "this route serves the fourteen blocks I typed in 2026".
    # @intent: { entity: "UserRepositoryOverview", action: "match the sgk_ route blocks", behavior: "the user-keyed body carries every top-level block the repository-keyed route serves except api_key", layer: "request" }
    it "serves exactly the blocks the sgk_ route serves, minus api_key" do
      ingest(owned, [example_row(file_path: "spec/models/user_spec.rb")])

      user_keyed = get_repository.keys

      get "/api/v1/repository", headers: bearer(owned.api_keys.create!.raw_token)
      repository_keyed = response.parsed_body.keys

      expect(repository_keyed).to include("api_key")
      expect(user_keyed).to eq(repository_keyed - ["api_key"])
    end

    # ⭐ THE ONE HONEST PAYLOAD DIFFERENCE, and the assertion is ABSENCE rather than nullity. The
    # block describes the credential that made the request; this request was made with a user key,
    # which has no `last_used_at` or `rotated_at` of the kind that block reports, and the
    # repository's own `sgk_` keys are not the caller's to describe. A block of nulls would be a
    # sentence about a credential that does not exist, and a client reading `null` cannot tell "this
    # request had no repository key" from "the key has no name" — only one of which is true.
    # @intent: { entity: "UserRepositoryOverview", action: "omit the api_key block", behavior: "a request made with a user key serves no api_key key at all rather than a block of nulls", layer: "request" }
    it "omits the api_key block entirely rather than serving it full of nulls" do
      body = get_repository

      expect(body).not_to have_key("api_key")
    end

    # The block that LOOKS like it should have travelled with `api_key` and correctly did not: it
    # reports on the repository's keys as a SET, which is repository-scoped like everything else
    # here. It is arguably worth MORE under a user key, where the caller holds none of them and an
    # `sgk_` key is reveal-once and therefore unaskable any other way.
    # @intent: { entity: "UserRepositoryOverview", action: "serve credential_health", behavior: "the overview still reports the repository's key rotation set even when the caller holds a repository key of their own", layer: "request" }
    it "still answers credential_health, which is about the repository's keys and not the caller's" do
      stranded = owned.api_keys.create!(name: "Stale CI Key")
      stranded.regenerate!

      expect(get_repository["credential_health"])
        .to include("rotated_and_unused" => true,
                    "keys" => [a_hash_including("name" => "Stale CI Key")])
    end

    # @intent: { entity: "UserRepositoryOverview", action: "serve delivery_health", behavior: "the overview keeps the repository-scoped delivery health block with its refusing flag", layer: "request" }
    it "still answers delivery_health, which is repository-scoped" do
      expect(get_repository["delivery_health"]).to include("refusing" => false)
    end

    # The run-grain half is not merely PRESENT but correct — a body assembled from the wrong
    # repository, or from a repository with its runs dropped, would still carry every key.
    # @intent: { entity: "UserRepositoryOverview", action: "read the latest run", behavior: "the latest_run block reports the commit sha of the run the repository itself recorded, not another repository's", layer: "request" }
    it "reads the repository's own latest run" do
      ingest(owned, [example_row(file_path: "spec/models/user_spec.rb")],
             commit_sha: "abc123abc123abc1")

      expect(get_repository["latest_run"]).to include("commit_sha" => "abc123abc123abc1")
    end
  end

  # SUCCESS CRITERION 2 — the OTHER half of `accessible_by`'s union. This is the half a
  # `where(user_id:)` written out by hand would fail, and the half that has no workaround at all: a
  # member may hold no `sgk_` key for the repository and, lacking `keys.manage`, may have no way to
  # mint one.
  describe "a repository shared with the person through a membership" do
    # @intent: { entity: "UserRepositoryOverview", action: "answer for a membership", behavior: "a repository shared through a membership responds 200 and names that repository in the body", layer: "request" }
    it "answers 200 with the overview" do
      body = get_repository(id: shared.id)

      expect(response).to have_http_status(:ok)
      expect(body["repository"]).to include("id" => shared.id, "full_name" => "acme/ledger")
    end

    # @intent: { entity: "UserRepositoryOverview", action: "match owned blocks", behavior: "a membership-opened overview serves the identical set of top-level blocks an owned one does", layer: "request" }
    it "serves the same blocks it serves for an owned repository" do
      expect(get_repository(id: shared.id).keys).to eq(get_repository(id: owned.id).keys)
    end

    # The rule rather than the output, on the precedent `user_repositories_spec.rb` sets for the
    # same distinction: a second hand-written copy of the access rule would pass the example above
    # and fail this one the day a third access path is added to `accessible_by`.
    # @intent: { entity: "UserRepositoryOverview", action: "open accessible repositories", behavior: "every id Repository.accessible_by admits for the person answers 200 on this route", layer: "request" }
    it "opens exactly what `Repository.accessible_by` admits" do
      Repository.accessible_by(person).pluck(:id).each do |id|
        get_repository(id: id)

        expect(response).to have_http_status(:ok), "expected #{id} to be openable"
      end
    end
  end

  # SUCCESS CRITERION 3 and 4 — the refusals, and the shape of them.
  describe "a repository the person may not open" do
    # ⭐ 404 AND NOT 403, AND THE TWO ARE DELIBERATELY INDISTINGUISHABLE. A 403 would require asking
    # a SECOND, unscoped question purely to tell a caller that something they may not open is
    # nevertheless there — which turns id enumeration into a census of the platform. The scoped
    # relation never has the row in hand to refuse.
    # @intent: { entity: "UserRepositoryOverview", action: "refuse invisibly", behavior: "a repository outside the person's access answers 404 so unscoped existence is never confirmed", layer: "request" }
    it "answers 404 rather than 403" do
      get_repository(id: invisible.id)

      expect(response).to have_http_status(:not_found)
    end

    # The 404 above is only worth anything if it is the SAME 404 a non-existent id gets. Asserted as
    # an equivalence rather than as two separate status checks: a body that differed between the two
    # would disclose existence just as loudly as a 403 does, one response at a time.
    # @intent: { entity: "UserRepositoryOverview", action: "mirror the absent-id answer", behavior: "the forbidden response has the same status and body as the one for an unregistered id", layer: "request" }
    it "is indistinguishable from the answer for an id that was never registered" do
      forbidden = get_repository(id: invisible.id)
      forbidden_status = response.status

      absent = get_repository(id: Repository.maximum(:id) + 1_000)

      expect(response.status).to eq(forbidden_status)
      expect(absent).to eq(forbidden)
    end

    # @intent: { entity: "UserRepositoryOverview", action: "disclose nothing", behavior: "the refusal body never leaks the hidden repository's full name even though the row exists", layer: "request" }
    it "discloses nothing about the repository it refused" do
      get_repository(id: invisible.id)

      expect(Repository.exists?(invisible.id)).to be(true)
      expect(response.body).not_to include("secret-payroll")
    end

    # CRITERION 4. `find_by` rather than `find` is what makes this fall out for free: a
    # `RecordNotFound` from an `ActionController::API` with no rescue registered is a 500, and "no
    # such id" is an ordinary answer rather than an exception. The malformed shapes cast to no
    # integer, match no row, and land on the same 404 with no special-casing anywhere.
    [
      ["a non-numeric id", "not-an-id"],
      ["an id with a numeric prefix", "1-billing-service"],
      ["an injection attempt", "1) OR (1=1"],
      ["a negative id", "-1"],
      ["a huge id", "99999999999999999999"]
    ].each do |shape, id|
      # @intent: { entity: "UserRepositoryOverview", action: "sink malformed ids", behavior: "a non-numeric, prefixed, injected, negative or oversized id lands on the same 404 without raising", layer: "request" }
      it "answers 404 rather than raising for #{shape}" do
        get_repository(id: CGI.escape(id.to_s))

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  # ⚠️ SUCCESS CRITERION 5, AND IT NEEDS ITS OWN EXAMPLES — the ticket says so explicitly, and the
  # reason is worth restating where somebody might otherwise delete this group as redundant.
  #
  # `credential_seam_spec.rb`'s route-table walk asserts per CONTROLLER CLASS, not per action, and
  # `Api::V1::UserRepositoriesController` already declared `accepts_user_credential` before this
  # route existed — so the new action passes that walk TRIVIALLY, whether or not it refuses `sgk_`.
  # The seam spec is therefore not evidence about this route, and only the examples below are.
  describe "an sgk_ repository key presented to this route" do
    let(:repository_key) { owned.api_keys.create! }

    # @intent: { entity: "UserRepositoryOverview", action: "refuse repository keys", behavior: "an sgk_ credential presented to this route is rejected with 401 before any repository is read", layer: "request" }
    it "is refused with 401" do
      get_repository(token: repository_key.raw_token)

      expect(response).to have_http_status(:unauthorized)
    end

    # The refusal is held by the PREFIX, before any table is read — which is what makes it a seam
    # rather than a lookup that happens to fail. A implementation that probed `api_keys`, missed,
    # then probed `user_api_keys` would produce this identical 401 while doubling the cost of every
    # request, and would pass the example above.
    # @intent: { entity: "UserRepositoryOverview", action: "decide by prefix", behavior: "the sgk_ refusal happens without a single statement against the api_keys table", layer: "request" }
    it "reads no credential table at all, because the prefix decides first" do
      token = repository_key.raw_token

      statements = queries_against("api_keys") { get_repository(token: token) }

      expect(response).to have_http_status(:unauthorized)
      expect(statements).to be_empty
    end

    # @intent: { entity: "UserRepositoryOverview", action: "leave the key unstamped", behavior: "a refused repository key gets no last_used_at, so failed probes do not refresh apparent activity", layer: "request" }
    it "does not stamp the refused key as used" do
      key = repository_key

      get_repository(token: key.raw_token)

      expect(key.reload.last_used_at).to be_nil
    end

    # The direction that would be the real harm: a repository key naming a repository this person
    # cannot open must not become a way to read it. It is refused for being the wrong KIND of
    # credential, before the question of which repository it names arises at all.
    # @intent: { entity: "UserRepositoryOverview", action: "refuse cross-use", behavior: "a repository key naming a repository the person cannot open is still refused as a wrong-kind credential", layer: "request" }
    it "cannot be used to open a repository through the plural route" do
      get_repository(id: invisible.id, token: invisible.api_keys.create!.raw_token)

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "a credential that is not valid at all" do
    # @intent: { entity: "UserRepositoryOverview", action: "require a credential", behavior: "a request with no Authorization header is refused 401", layer: "request" }
    it "refuses a missing Authorization header" do
      get "/api/v1/repositories/#{owned.id}"

      expect(response).to have_http_status(:unauthorized)
    end

    # @intent: { entity: "UserRepositoryOverview", action: "refuse unknown tokens", behavior: "a well-formed sgu_ token that matches no stored digest is refused 401", layer: "request" }
    it "refuses a well-formed but unknown sgu_ token" do
      get_repository(token: "sgu_#{SecureRandom.hex(24)}")

      expect(response).to have_http_status(:unauthorized)
    end

    # A key belonging to somebody who can open nothing is a VALID credential — so this is a 404,
    # not a 401, and the distinction is the seam working correctly rather than an inconsistency.
    # @intent: { entity: "UserRepositoryOverview", action: "distinguish authz from authn", behavior: "a valid key whose person can open nothing gets 404, because the credential itself resolved fine", layer: "request" }
    it "answers 404 — not 401 — for a valid key whose person may open nothing" do
      loner = create_user(github_uid: "3003", github_handle: "nobody")

      get_repository(token: create_user_api_key(user: loner).raw_token)

      expect(response).to have_http_status(:not_found)
    end
  end

  # SUCCESS CRITERION 6 — each of the seven drill-in parameters produces the same block it produces
  # on the singular route, driven by the same concern.
  #
  # The positive path and the malformed path are BOTH needed and neither substitutes for the other:
  # a guard that swallowed a parameter entirely would answer 200 to every malformed shape and pass
  # the whole shared-example set, and only the positive example beside it separates "guarded" from
  # "ignored". That is the shared examples' own stated requirement of a host.
  describe "the seven drill-in query parameters" do
    let!(:run) do
      ingest(owned,
             [example_row(file_path: "spec/models/user_spec.rb", line_number: 1, name: "repeated", duration: 5.0),
              example_row(file_path: "spec/models/user_spec.rb", line_number: 2, name: "repeated", duration: 4.0),
              example_row(file_path: "spec/jobs/mailer_spec.rb", line_number: 3, name: "sends", duration: 1.0)],
             commit_sha: "abc123abc123abc1")
    end

    # ⭐ THE POSITIVE PATH, ASSERTED AS AN EQUIVALENCE AGAINST THE SINGULAR ROUTE. The criterion is
    # "the same block, driven by the same concern", and comparing the two live responses states
    # exactly that — where asserting the block's own contents would merely re-test the serializer
    # (which its own spec file already does) and would say nothing about the two routes agreeing.
    #
    # A route that read a parameter under a DIFFERENT guard, or forgot to include the concern at
    # all, fails here: it would serve the unfiltered block while the singular route served the
    # narrowed one.
    {
      "branch" => { branch: "main" },
      "spec_directory" => { spec_directory: "spec/models" },
      "spec_file" => { spec_file: "spec/models/user_spec.rb" },
      "repeated_description" => { repeated_description: "repeated" },
      "unstable_test" => { unstable_test: "repeated" },
      "commit_sha" => { commit_sha: "abc123abc123abc1" },
      "unannotated_examples" => { unannotated_examples: "1" }
    }.each do |name, query|
      # @intent: { entity: "UserRepositoryOverview", action: "honour drill-in parameters", behavior: "each of the seven narrowing query parameters yields the same filtered body the sgk_ route gives, minus api_key", layer: "request" }
      it "answers ?#{name}= with the same body the sgk_ route answers, minus api_key" do
        user_keyed = get_repository(query: query)

        get "/api/v1/repository", params: query,
                                  headers: bearer(owned.api_keys.create!.raw_token)
        repository_keyed = response.parsed_body.except("api_key")

        expect(response).to have_http_status(:ok)
        expect(user_keyed).to eq(repository_keyed)
      end
    end

    # THE MALFORMED SHAPES, pinned once for every surface that reads the parameter and included here
    # rather than re-listed. `?branch[]=`, `?branch[a]=b` and `?branch[][a]=b` are an Array, an
    # `ActionController::Parameters` and an Array of them — none is a String, and an unguarded
    # `.presence` on any of them reaches a `where` that raises. A 500 on a URL anyone can type.
    #
    # Each host method asserts the UNFILTERED answer specifically rather than merely a 200, which is
    # what the shared examples require of a host: a 200 alone would also be produced by a guard that
    # swallowed the parameter, and the positive examples above are what rule that out.
    describe "a parameter that is not the thing it names" do
      let(:unfiltered) { get_repository }

      def expect_branch_param_treated_as_no_ask(query)
        expect(get_repository(query: query)).to eq(unfiltered)
        expect(response).to have_http_status(:ok)
      end

      %i[spec_directory spec_file repeated_description unstable_test commit_sha
         unannotated_examples].each do |param|
        define_method(:"expect_#{param}_param_treated_as_no_ask") do |query|
          expect(get_repository(query: query)).to eq(unfiltered)
          expect(response).to have_http_status(:ok)
        end
      end

      it_behaves_like "a surface that treats a malformed branch parameter as no ask"
      it_behaves_like "a surface that treats a malformed spec-directory parameter as no ask"
      it_behaves_like "a surface that treats a malformed spec-file parameter as no ask"
      it_behaves_like "a surface that treats a malformed repeated-description parameter as no ask"
      it_behaves_like "a surface that treats a malformed unstable-test parameter as no ask"
      it_behaves_like "a surface that treats a malformed commit-sha parameter as no ask"
      it_behaves_like "a surface that treats a malformed unannotated-examples parameter as no ask"
    end
  end

  # SUCCESS CRITERION 9 (the ticket's "if it is cheap to do so"). `Api::BaseController` claims a
  # valid presentation costs ONE indexed read, and the population has to span BOTH credential tables
  # AND `users` or the claim is not measured: the two regressions it watches for land on different
  # tables — probing the second credential table, and re-reading the resolved person to bind the
  # principal — and a filter naming either alone reports a clean count while the other regresses.
  #
  # Scoped to AUTHENTICATION, not to the whole response. The overview's own reads are many and are
  # bounded by their own specs; what is asserted here is that reaching this new route costs
  # authentication no more than reaching any other one.
  describe "what authenticating this route costs" do
    # ⚠️ THE POPULATION IS NARROWED TO *READS THAT RESOLVE A CREDENTIAL*, and the two things it
    # deliberately excludes are excluded for stated reasons rather than to make a number come out.
    #
    #   - `ApiKey#touch_last_used!`'s UPDATE is a WRITE. The claim is about what resolution READS.
    #   - `credential_health`'s `SELECT … FROM "api_keys" WHERE "repository_id" = $1` is the
    #     RESPONSE PAYLOAD — the block reporting on the repository's own keys, which this route
    #     serves precisely because a user-key caller holds none of them. It reads `api_keys` by
    #     `repository_id`, never by a digest, so it is not a credential probe and counting it would
    #     make this guard fail for the endpoint doing its job.
    #
    # The two assertions below are separate because the two regressions `Api::BaseController`'s
    # cost claim watches for land on DIFFERENT tables, and a single filter naming either one alone
    # reports a clean count while the other regresses.
    def selects(pattern, &)
      queries_against(pattern, &).grep(/\ASELECT/)
    end

    # Resolved OUTSIDE the measured block: minting a key is itself statements against a credential
    # table, and a lazily-evaluated `let` inside would count them as the request's.
    let(:token) { user_api_key.raw_token }
    let(:id) { owned.id }

    # ⚠️ FORCED HERE, OUTSIDE EVERY MEASURED BLOCK, AND THAT IS NOT STYLE. These are lazy `let`s,
    # and minting a `UserApiKey` runs a uniqueness check — `SELECT … WHERE token_digest = $1` —
    # which is a SELECT against a credential table keyed on the very column these guards filter on.
    # Referenced first inside the block, the FIXTURE's own statement is counted as the REQUEST's and
    # every count below reads one too high. This bit once already.
    before do
      token
      id
    end

    # REGRESSION ONE: an implementation that probes `api_keys`, misses, then probes `user_api_keys`.
    # It produces an identical response and doubles the cost of every request. `token_digest` is the
    # column every credential lookup keys on, in BOTH tables, so this population spans the seam.
    # @intent: { entity: "Authentication", action: "read one credential table", behavior: "resolving the caller issues exactly one SELECT keyed on token_digest across either credential table", layer: "request" }
    it "reads a credential table exactly once, whichever table it is" do
      statements = selects(/token_digest/) { get "/api/v1/repositories/#{id}", headers: bearer(token) }

      expect(response).to have_http_status(:ok)
      expect(statements.size).to eq(1)
    end

    # REGRESSION TWO, which the filter above is structurally blind to: binding the principal by
    # re-reading the person. `UserApiKey.authenticate` spelled with `joins(:user)` instead of
    # `eager_load(:user)` filters through the `users` row without populating the association, and
    # `bind_principal`'s `.user` then re-reads it by primary key on every authenticated request —
    # a second statement that carries no `token_digest` and would pass the example above.
    # @intent: { entity: "Authentication", action: "join the person", behavior: "the single credential statement also carries the users join so the principal is never re-read by id", layer: "request" }
    it "brings the person back in that same statement rather than re-reading them" do
      statements = selects(/"users"/) { get "/api/v1/repositories/#{id}", headers: bearer(token) }

      expect(response).to have_http_status(:ok)
      expect(statements.size).to eq(1)
      expect(statements.first).to include("token_digest")
    end
  end

  # ⚠️ THE ROUTE THIS ONE COULD HAVE TAKEN OFF THE AIR. `:id` is a greedy dynamic segment, and
  # `/api/v1/repositories/registrable` matches it perfectly — declared in the wrong order, the
  # literal route would resolve to `#show` with `params[:id] == "registrable"` and answer 404.
  #
  # The note on `get "repositories/registrable"` reasoned that a literal "cannot be swallowed as an
  # id (there is no `:id` member route in this namespace)". That parenthesis stopped being true when
  # this route shipped, so what protects it now is declaration order — which is invisible, and is
  # exactly the kind of thing a later tidy-up sorts alphabetically. This example is the guard.
  describe "the sibling route the member route must not swallow" do
    # @intent: { entity: "Routing", action: "keep the sibling route", behavior: "/api/v1/repositories/registrable still recognises to the registrable action rather than being eaten as an :id", layer: "request" }
    it "still resolves /repositories/registrable to #registrable" do
      expect(Rails.application.routes.recognize_path("/api/v1/repositories/registrable", method: :get))
        .to include(controller: "api/v1/user_repositories", action: "registrable")
    end

    # @intent: { entity: "Routing", action: "answer the sibling route", behavior: "the registrable endpoint responds 200 with a repositories payload rather than falling into #show", layer: "request" }
    it "still answers the registrable endpoint rather than a 404 from #show" do
      create_registration_grant(user: person)

      get "/api/v1/repositories/registrable", headers: bearer(user_api_key.raw_token)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to have_key("repositories")
    end
  end

  # SUCCESS CRITERION 7, from this side. The existing per-block specs are the real regression net —
  # they pass unmodified, which is the claim — and this is the property they cannot state on their
  # own, because each of them only ever looks at one route: the two routes must not merely both
  # work, they must agree.
  describe "the extraction, which must have changed nothing" do
    # @intent: { entity: "UserRepositoryOverview", action: "stay byte-identical", behavior: "both routes serve exactly equal blocks for the same repository once api_key is subtracted", layer: "request" }
    it "serves byte-identical blocks on both routes for the same repository" do
      ingest(owned,
             [example_row(file_path: "spec/models/user_spec.rb", line_number: 1, duration: 3.0),
              example_row(file_path: "spec/jobs/mailer_spec.rb", line_number: 2, duration: 1.0)])

      user_keyed = get_repository

      get "/api/v1/repository", headers: bearer(owned.api_keys.create!.raw_token)

      expect(response.parsed_body.except("api_key")).to eq(user_keyed)
    end

    # The `api_key` block is the one thing that does not travel, so the singular route must still
    # serve it in FULL — an extraction that dropped it would pass every equivalence above, since
    # they all subtract it before comparing.
    # @intent: { entity: "RepositoryOverview", action: "keep the api_key block", behavior: "the sgk_ route still serves the full api_key block with its name and reporting pointers after the extraction", layer: "request" }
    it "still serves the whole api_key block on the sgk_ route" do
      key = owned.api_keys.create!(name: "CI Key")

      get "/api/v1/repository", headers: bearer(key.raw_token)

      expect(response.parsed_body["api_key"])
        .to include("name" => "CI Key", "acceptance_reported_by" => "delivery_health",
                    "rotation_reported_by" => "credential_health")
    end
  end

  # @intent: { entity: "UserApiKey", action: "stamp usage", behavior: "a successful user-keyed overview request writes last_used_at on the credential that made it", layer: "request" }
  it "stamps the user key as used" do
    expect(user_api_key.last_used_at).to be_nil

    get_repository

    expect(user_api_key.reload.last_used_at).to be_present
  end
end
