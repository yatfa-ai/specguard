# frozen_string_literal: true

require "rails_helper"

# The auth contract for this endpoint lives in `repositories_spec.rb` and is deliberately left
# untouched. This file covers only the `latest_run` block — the agent-readable twin of the suite
# figures `repositories#show` renders.
RSpec.describe "GET /api/v1/repository — latest_run", type: :request do
  let(:repository) { create_repository }
  let(:api_key) { repository.api_keys.create! }

  def get_repository(key: api_key)
    get "/api/v1/repository", headers: { "Authorization" => "Bearer #{key.raw_token}" }

    response.parsed_body
  end

  describe "a repository with an ingested run" do
    let!(:test_run) do
      create_test_run(repository: repository,
                      commit_sha: "a1b2c3d4e5f6",
                      branch: "main",
                      total_specs_count: 40,
                      annotated_specs_count: 10,
                      duration_seconds: 42.5)
    end

    it "reports the latest run's suite facts" do
      body = get_repository

      expect(response).to have_http_status(:ok)
      expect(body["latest_run"]).to eq(
        "commit_sha" => "a1b2c3d4e5f6",
        "branch" => "main",
        "total_specs" => 40,
        "annotated_specs" => 10,
        "annotated_ratio" => 0.25,
        "duration_seconds" => 42.5,
        "ingested_at" => test_run.created_at.iso8601
      )
    end

    # AC2. Read off the same accessor `repositories#show` assigns to `@latest_test_run` rather than
    # re-stating the fixture's numbers: two independent hand-written expectations would still both
    # pass if the endpoint started reading a *different* row.
    it "reports the same row, and the same figures, that repositories#show renders" do
      shown = repository.latest_test_run
      block = get_repository["latest_run"]

      expect(block["commit_sha"]).to eq(shown.commit_sha)
      expect(block["branch"]).to eq(shown.branch)
      expect(block["total_specs"]).to eq(shown.total_specs_count)
      expect(block["annotated_specs"]).to eq(shown.annotated_specs_count)
      expect(block["duration_seconds"]).to eq(shown.duration_seconds)
      expect(block["ingested_at"]).to eq(shown.created_at.iso8601)
    end

    it "leaves the existing repository and api_key blocks in place" do
      body = get_repository

      expect(body.dig("repository", "full_name")).to eq("acme/billing-service")
      expect(body["api_key"]).to have_key("last_used_at")
    end

    it "scopes latest_run to the key's own repository" do
      other = create_repository(user: create_user(github_uid: "2002", github_handle: "hubot"),
                                github_full_name: "acme/ledger")
      create_test_run(repository: other, commit_sha: "otherrepo", total_specs_count: 7)

      expect(get_repository.dig("latest_run", "commit_sha")).to eq("a1b2c3d4e5f6")
    end
  end

  # The `created_at desc, id desc` tie-break, which is the half of "same row" a single-run fixture
  # cannot exercise: two runs stamped the same instant order by id, so the endpoint and the
  # dashboard cannot name different commits for the same repository.
  describe "two runs ingested in the same instant" do
    it "breaks the created_at tie the same way Repository#latest_test_run does" do
      stamp = 1.hour.ago
      older = create_test_run(repository: repository, commit_sha: "older0", total_specs_count: 1)
      newer = create_test_run(repository: repository, commit_sha: "newer0", total_specs_count: 1)
      [older, newer].each { |run| run.update_columns(created_at: stamp) }

      expect(repository.latest_test_run).to eq(newer)
      expect(get_repository.dig("latest_run", "commit_sha")).to eq(repository.latest_test_run.commit_sha)
    end
  end

  # AC3. `null`, not a zeroed block: a repository whose CI has never reported must not be
  # indistinguishable from one that reported an empty suite.
  describe "a repository whose CI has never reported" do
    it "reports latest_run as null rather than a block of zeros" do
      body = get_repository

      expect(response).to have_http_status(:ok)
      expect(body).to have_key("latest_run")
      expect(body["latest_run"]).to be_nil
    end
  end

  # AC4. Both columns are nullable and Ingest::Payload accepts a body omitting either.
  describe "a run that reported no branch and no duration" do
    before do
      create_test_run(repository: repository, commit_sha: "nobranch", total_specs_count: 3,
                      annotated_specs_count: 1, branch: nil, duration_seconds: nil)
    end

    it "keeps branch null instead of substituting a name" do
      expect(get_repository["latest_run"]).to include("branch" => nil)
    end

    it "keeps duration_seconds null instead of asserting the run took no time" do
      expect(get_repository["latest_run"]).to include("duration_seconds" => nil)
    end
  end

  # AC5. `TestRun#annotated_fraction` floors at 0.0 by zero-denominator guard; emitting that here
  # would read as a *measured* zero share beside real fractions.
  describe "a run that reported zero tests" do
    before { create_test_run(repository: repository, commit_sha: "emptysuite", total_specs_count: 0) }

    it "reports no ratio rather than a confident 0.0" do
      expect(get_repository["latest_run"]).to include("annotated_ratio" => nil)
    end

    it "still reports the counts, so a client can see the suite was empty" do
      expect(get_repository["latest_run"]).to include("total_specs" => 0, "annotated_specs" => 0)
    end
  end

  # AC6. The unit trap: `TestRun#annotated_ratio` is a 0–100 percentage and `#annotated_fraction`
  # is the 0–1 fraction `/ingest` answers with. A client reading both endpoints must not find them
  # disagreeing by 100×.
  #
  # Written against an UNSHARDED run (no `ci_run_id`) on purpose. `Ingest::RunRecorder` folds every
  # shard of a sharded run onto one row and recomputes its counters as the SUM of the shards, so
  # mid-run the ingest response and a later GET legitimately describe different totals — asserting
  # they match across a sharded fixture would encode an invariant that does not hold.
  describe "agreement with the /ingest response for the same run" do
    it "answers the same annotated_ratio /ingest did, in the same 0–1 unit" do
      post "/api/v1/ingest",
           params: ingest_payload(
             commit_sha: "c0ffee1234",
             branch: "main",
             specs: [
               annotated_spec(file_path: "spec/models/invoice_spec.rb", line_number: 12),
               annotated_spec(file_path: "spec/requests/checkout_spec.rb", line_number: 30, layer: "request"),
               unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 7)
             ]
           ).to_json,
           headers: { "Content-Type" => "application/json",
                      "Authorization" => "Bearer #{api_key.raw_token}" }

      expect(response).to have_http_status(:accepted)
      ingested = response.parsed_body

      block = get_repository["latest_run"]

      expect(block["annotated_ratio"]).to eq(ingested["annotated_ratio"])
      expect(block["total_specs"]).to eq(ingested["total_specs"])
      expect(block["annotated_specs"]).to eq(ingested["annotated_specs"])
    end

    # Guards the direction the agreement above cannot catch on its own: both sides could drift to
    # the percentage together and still agree with each other.
    it "is the fraction, not the percentage the dashboard renders" do
      create_test_run(repository: repository, commit_sha: "quarter", total_specs_count: 40,
                      annotated_specs_count: 10)

      run = repository.latest_test_run

      expect(get_repository.dig("latest_run", "annotated_ratio")).to eq(run.annotated_fraction)
      expect(get_repository.dig("latest_run", "annotated_ratio")).not_to eq(run.annotated_ratio)
    end
  end
end
