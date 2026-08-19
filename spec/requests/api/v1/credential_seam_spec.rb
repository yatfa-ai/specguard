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
    it "reads no credential table when a user key is presented to the ingest endpoint" do
      token = user_key.raw_token

      statements = credential_reads do
        post "/api/v1/ingest", params: ingest_payload, as: :json, headers: bearer(token)
      end

      expect(response).to have_http_status(:unauthorized)
      expect(statements).to be_empty
    end

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
    it "is refused by GET /api/v1/repositories with 401" do
      get "/api/v1/repositories", headers: bearer(repository_key.raw_token)

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["error"]).to eq("unauthorized")
    end

    # The refusal is at the door, before any lookup — so it must not look like a use of the key on
    # the repository page's "Last used" column either.
    it "does not stamp the refused key as used" do
      get "/api/v1/repositories", headers: bearer(repository_key.raw_token)

      expect(repository_key.reload.last_used_at).to be_nil
    end
  end

  describe "a user key (`sgu_`) at a repository-key endpoint" do
    it "is refused by GET /api/v1/repository with 401" do
      get "/api/v1/repository", headers: bearer(user_key.raw_token)

      expect(response).to have_http_status(:unauthorized)
    end

    it "is refused by POST /api/v1/ingest with 401" do
      post "/api/v1/ingest", params: ingest_payload, as: :json,
                             headers: bearer(user_key.raw_token)

      expect(response).to have_http_status(:unauthorized)
    end

    # The specific harm the 401 above prevents, asserted directly: a leaked `nil` repository would
    # not raise where it is written, it would record a run against nothing.
    it "records no run and no rejection from the refused ingest" do
      post "/api/v1/ingest", params: ingest_payload, as: :json,
                             headers: bearer(user_key.raw_token)

      expect(TestRun.count).to eq(0)
      expect(IngestRejection.count).to eq(0)
    end

    it "does not stamp the refused key as used" do
      get "/api/v1/repository", headers: bearer(user_key.raw_token)

      expect(user_key.reload.last_used_at).to be_nil
    end
  end

  # SPGD-752 success criterion 4, over HTTP. The model spec proves the resolution site refuses an
  # archived owner; this proves nothing downstream un-refuses it.
  describe "a key belonging to an archived person" do
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
    it "is absent by default, so an endpoint that says nothing accepts nothing" do
      expect(Api::BaseController.accepted_credential).to be_nil
    end

    it "is made by every routed endpoint" do
      undeclared = Rails.application.routes.routes.filter_map { |route|
        controller = route.defaults[:controller]
        next unless controller&.start_with?("api/")

        klass = "#{controller.camelize}Controller".safe_constantize
        klass&.name if klass && klass <= Api::BaseController && klass.accepted_credential.nil?
      }.uniq

      expect(undeclared).to be_empty,
                            "these endpoints declare no credential and will 401 every request: " \
                            "#{undeclared.join(", ")}"
    end
  end
end
