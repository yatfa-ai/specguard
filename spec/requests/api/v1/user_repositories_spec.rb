# frozen_string_literal: true

require "rails_helper"

# SPGD-752 success criterion 2: a `sgu_` user key authenticates `GET /api/v1/repositories`, and the
# body lists exactly `Repository.accessible_by(user)`.
RSpec.describe "API v1 — GET /api/v1/repositories", type: :request do
  # The fixture the criterion names, and each third of it is load-bearing: OWNED and MEMBER are the
  # two halves of `accessible_by`'s union — a response built from either alone passes half the suite
  # — and INVISIBLE is the one that proves the list is not simply `Repository.all`.
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

  def get_repositories(token: user_api_key.raw_token)
    get "/api/v1/repositories", headers: { "Authorization" => "Bearer #{token}" }
  end

  it "lists the repository the person owns and the one shared with them" do
    get_repositories

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["repositories"].map { |row| row["full_name"] })
      .to eq(["acme/billing-service", "acme/ledger"])
  end

  # The half of the criterion that is about what is NOT there. Asserted against the whole serialized
  # body rather than against the name list alone, so a repository leaking through any other field —
  # an id, a `name` — is caught too.
  it "does not disclose a repository the person can neither open nor learn exists" do
    get_repositories

    expect(Repository.exists?(invisible.id)).to be(true)
    expect(response.body).not_to include("secret-payroll")
    expect(response.parsed_body["repositories"].map { |row| row["id"] }).not_to include(invisible.id)
  end

  # Not a restatement of the example above. That one asserts the OUTPUT; this asserts the RULE the
  # output came from, which is what the ticket requires — administration lands on the same policy
  # object the dashboard uses rather than on a parallel implementation. A hand-written
  # `where(user_id:)` would pass the first example and fail this one the day a third access path is
  # added to `accessible_by`.
  it "serves exactly `Repository.accessible_by`, not a second copy of the rule" do
    get_repositories

    expect(response.parsed_body["repositories"].map { |row| row["id"] })
      .to match_array(Repository.accessible_by(person).pluck(:id))
  end

  it "names which of the two access paths each row arrived by" do
    get_repositories

    roles = response.parsed_body["repositories"].to_h { |row| [row["full_name"], row["role"]] }

    expect(roles).to eq("acme/billing-service" => "owner", "acme/ledger" => "member")
  end

  it "answers an empty list — not a 404 — for somebody who can open nothing" do
    loner = create_user(github_uid: "3003", github_handle: "nobody")

    get_repositories(token: create_user_api_key(user: loner).raw_token)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["repositories"]).to eq([])
  end

  it "records when the key was last used" do
    expect(user_api_key.last_used_at).to be_nil

    get_repositories

    expect(user_api_key.reload.last_used_at).to be_present
  end

  it "rejects an unknown user token with 401" do
    get_repositories(token: "sgu_definitely-not-a-key")

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body["error"]).to eq("unauthorized")
  end

  it "rejects a missing Authorization header with 401" do
    get "/api/v1/repositories"

    expect(response).to have_http_status(:unauthorized)
  end

  # SPGD-830. The machine half of the marker the browser's card grid has rendered since SPGD-820.
  # The verdict is an ORDERING between two recorded facts — the newest refusal against the newest
  # accepted run — so every example below states BOTH sides of it rather than asserting against a
  # window in hours.
  describe "delivery_health" do
    # Built the way `spec/requests/repositories_spec.rb` builds one, and for the reason stated
    # there: the production path stamps `api_keys.last_used_at` on the way IN, so a refused delivery
    # records a use. Nothing on this surface reads that column — the block compares one refusal's
    # `occurred_at` against one run's `created_at`, and both sides are stated here — so the shortcut
    # is faithful rather than merely convenient.
    def refuse(repository, at: Time.current)
      IngestRejection.create!(repository: repository, occurred_at: at,
                              details: ["commit_sha can't be blank"], total_reasons_count: 1)
    end

    def health_for(full_name)
      response.parsed_body["repositories"].find { |row| row["full_name"] == full_name }["delivery_health"]
    end

    # AC1. Served on EVERY entry, owned and member-role alike — the point being that a client can
    # read the key without first establishing whether this repository has any history.
    it "serves the block on every entry, whatever the role and whatever the history" do
      get_repositories

      expect(response.parsed_body["repositories"].map { |row| row["delivery_health"] })
        .to all(match("refusing" => be_in([true, false]), "last_rejection_at" => be_nil.or(be_a(String))))
      expect(response.parsed_body["repositories"].map { |row| row.key?("delivery_health") }).to eq([true, true])
    end

    # AC2. The ordinary refusing case, and the timestamp is the refusal's own `occurred_at` in
    # iso8601 rather than "some recent time".
    it "reads refusing with the refusal's own time when a rejection lands after the newest run" do
      create_test_run(repository: owned, created_at: 2.hours.ago)
      refuse(owned, at: 30.minutes.ago)

      get_repositories

      expect(health_for("acme/billing-service"))
        .to eq("refusing" => true, "last_rejection_at" => owned.ingest_rejections.first.occurred_at.iso8601)
    end

    # AC3. The key is PRESENT and says `false`. An absent key would read as "SpecGuard does not
    # track that", which is a different fact from "nothing was refused" — the sibling endpoint's own
    # stated rule, asserted here against `key?` so that omitting the block cannot pass as a nil.
    it "reads not-refusing with a null timestamp, and never omits the key, when nothing was refused" do
      create_test_run(repository: owned, created_at: 2.hours.ago)

      get_repositories

      row = response.parsed_body["repositories"].find { |entry| entry["full_name"] == "acme/billing-service" }

      expect(row["delivery_health"].key?("last_rejection_at")).to be(true)
      expect(row["delivery_health"]).to eq("refusing" => false, "last_rejection_at" => nil)
    end

    # AC4. THE INVERTING NIL LIMB, and the case a hand-rolled `>` gets wrong: a repository refused
    # with no accepted run EVER is not "no comparison available", it is the most refusing state
    # there is. A `last_rejection_at > nil` would raise; a `nil`-guarded `&&` would read `false`.
    it "reads refusing for a repository that has been refused and has never had a run accepted" do
      refuse(owned, at: 10.minutes.ago)

      expect(owned.test_runs).to be_empty

      get_repositories

      expect(health_for("acme/billing-service")).to include("refusing" => true)
    end

    # AC5. The verdict and the timestamp are INDEPENDENT facts. A repository that hit a bad payload
    # and has ingested cleanly since reads healthy — with no window to expire — but the refusal it
    # survived is still reported, so a client can see that it happened.
    it "reads not-refusing but still names the refusal when an accepted run lands on top of it" do
      refuse(owned, at: 3.hours.ago)
      create_test_run(repository: owned, created_at: 1.hour.ago)

      get_repositories

      expect(health_for("acme/billing-service"))
        .to eq("refusing" => false, "last_rejection_at" => owned.ingest_rejections.first.occurred_at.iso8601)
    end

    # AC6. FLAT IN N — the assertion this block exists to protect, since both reads are grouped
    # aggregates that would be invisible as an N+1 against a one-repository fixture. Same shape as
    # `spec/requests/api/v1/repository_latest_run_spec.rb`'s budget: the same count at one row as at
    # several. Every added repository carries a refusal and a run, so the extra entries exercise
    # both lookups rather than short-circuiting on absent history.
    it "issues the same number of queries for one repository as for several" do
      solo = create_user(github_uid: "4004", github_handle: "solo")
      solo_key = create_user_api_key(user: solo)
      only = create_repository(user: solo, github_full_name: "acme/only")
      refuse(only)
      create_test_run(repository: only)

      one = count_queries { get_repositories(token: solo_key.raw_token) }

      %w[acme/second acme/third acme/fourth].each do |name|
        repository = create_repository(user: solo, github_full_name: name)
        refuse(repository)
        create_test_run(repository: repository)
      end

      several = count_queries { get_repositories(token: solo_key.raw_token) }

      expect(response.parsed_body["repositories"].size).to eq(4)
      expect(several).to eq(one)
    end

    # AC7. The early return, asserted as the ABSENCE OF THE READS rather than as a query total — a
    # total would still pass if one aggregate were traded for another. An account that can open
    # nothing pays for neither.
    it "takes no rejection or run aggregate at all for an account with no repositories" do
      loner = create_user(github_uid: "3003", github_handle: "nobody")
      token = create_user_api_key(user: loner).raw_token

      rejection_reads = nil
      run_reads = queries_against("test_runs") do
        rejection_reads = queries_against("ingest_rejections") { get_repositories(token: token) }
      end

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["repositories"]).to eq([])
      expect(rejection_reads).to be_empty
      expect(run_reads).to be_empty
    end

    # AC8. THE RULE, not the output — the same distinction the `accessible_by` example above draws.
    # `RejectedIngests` forbids a second inline expression of the ordering rule because its two
    # `nil` limbs do not both fall out of a bare `>`, and a controller that re-spelled it would pass
    # every example above and diverge the day the rule changes on one side only.
    it "reaches the verdict through `RejectedIngests.verdict` rather than re-spelling the comparison" do
      refuse(owned, at: 10.minutes.ago)

      expect(RejectedIngests).to receive(:verdict).at_least(:once).and_call_original

      get_repositories

      expect(health_for("acme/billing-service")).to include("refusing" => true)
    end

    # AC9. The five fields that were here before are unchanged in NAME and in VALUE — the new block
    # is additive, and a client reading the old five is unaffected.
    it "leaves the five existing fields untouched" do
      refuse(owned)

      get_repositories

      expect(health_for("acme/billing-service")).to include("refusing" => true)
      expect(response.parsed_body["repositories"].first)
        .to include("id" => owned.id, "full_name" => "acme/billing-service", "name" => owned.name,
                    "registered_at" => owned.created_at.iso8601, "role" => "owner")
    end
  end
end
