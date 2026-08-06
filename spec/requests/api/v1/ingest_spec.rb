# frozen_string_literal: true

require "rails_helper"

RSpec.describe "POST /api/v1/ingest", type: :request do
  let(:repository) { create_repository }
  let(:api_key) { repository.api_keys.create! }

  def ingest(body, key: api_key, headers: {})
    post "/api/v1/ingest",
         params: body.is_a?(String) ? body : body.to_json,
         headers: { "Content-Type" => "application/json" }
           .merge(key ? { "Authorization" => "Bearer #{key.raw_token}" } : {})
           .merge(headers)
  end

  describe "a well-formed run" do
    let(:body) do
      ingest_payload(
        commit_sha: "a1b2c3d4e5",
        branch: "main",
        duration_seconds: 42.5,
        specs: [
          annotated_spec(file_path: "spec/models/invoice_spec.rb", line_number: 12),
          annotated_spec(file_path: "spec/requests/checkout_spec.rb", line_number: 30, layer: "request"),
          unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 7)
        ]
      )
    end

    it "accepts it with 202" do
      ingest(body)

      expect(response).to have_http_status(:accepted)
    end

    it "records a TestRun whose counts are derived from the specs it was sent" do
      expect { ingest(body) }.to change(TestRun, :count).by(1)

      run = TestRun.last
      expect(run.repository).to eq(repository)
      expect(run.commit_sha).to eq("a1b2c3d4e5")
      expect(run.branch).to eq("main")
      expect(run.duration_seconds).to eq(42.5)
      expect(run.total_specs_count).to eq(3)
      expect(run.annotated_specs_count).to eq(2)
    end

    it "derives the counts itself rather than trusting the ones the client sent" do
      ingest(body.merge(total_specs_count: 999, annotated_specs_count: 999))

      expect(TestRun.last.total_specs_count).to eq(3)
      expect(TestRun.last.annotated_specs_count).to eq(2)
    end

    it "returns the documented body" do
      ingest(body)

      expect(response.parsed_body).to eq(
        "test_run_id" => TestRun.last.id,
        "total_specs" => 3,
        "annotated_specs" => 2,
        "annotated_ratio" => 0.667,
        "embedding_status" => "pending"
      )
    end

    # The 100× trap: `TestRun#annotated_ratio` is 66.7 and the dashboard prints it with a `%`,
    # while the API field is documented as a 0–1 fraction. Pinned here because the two are
    # indistinguishable in a JSON body until a client is already 100× wrong.
    it "reports annotated_ratio as a 0-1 fraction, not the dashboard's percentage" do
      ingest(body)

      expect(response.parsed_body["annotated_ratio"]).to eq(0.667)
      expect(TestRun.last.annotated_ratio).to eq(66.7)
    end

    # Slice 2 records the run only. The upsert of individual intents is slice 3's job, and writing
    # them here would hand that slice a `create!` path it would have to unpick.
    it "persists no spec_intents yet" do
      expect { ingest(body) }.not_to change(SpecIntent, :count)
    end

    # There is no queue and no job class in the tree yet, so nothing was scheduled. Saying
    # "queued" here would report work that does not exist.
    it "does not claim to have queued embeddings it has not queued" do
      ingest(body)

      expect(response.parsed_body["embedding_status"]).to eq("pending")
    end

    it "scopes the run to the repository behind the key" do
      other = create_repository(user: create_user(github_uid: "2002", github_handle: "hubot"),
                                github_full_name: "acme/ledger")
      ingest(body, key: other.api_keys.create!)

      expect(TestRun.last.repository).to eq(other)
      expect(repository.test_runs).to be_empty
    end

    it "leaves branch and duration blank when the client omits them" do
      ingest(ingest_payload)

      expect(response).to have_http_status(:accepted)
      expect(TestRun.last.branch).to be_nil
      expect(TestRun.last.duration_seconds).to be_nil
    end
  end

  # Missing annotations are never an ingestion failure — only malformed ones are. Adoption of the
  # protocol has to be opt-in and gradual, so a suite that annotates nothing still reports.
  describe "a run with no annotations" do
    it "accepts a run of entirely unannotated specs" do
      ingest(ingest_payload(specs: [unannotated_spec(line_number: 1),
                                    unannotated_spec(line_number: 2)]))

      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body["annotated_ratio"]).to eq(0.0)
      expect(TestRun.last.total_specs_count).to eq(2)
      expect(TestRun.last.annotated_specs_count).to eq(0)
    end

    it "accepts a run that reported no specs at all" do
      ingest(ingest_payload(specs: []))

      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body).to include("total_specs" => 0, "annotated_ratio" => 0.0)
    end
  end

  describe "an intent that fails the OpenTestIntent schema" do
    it "rejects a behavior below the schema's minimum length, naming the offending spec" do
      ingest(ingest_payload(specs: [annotated_spec(line_number: 12),
                                    annotated_spec(file_path: "spec/models/order_spec.rb",
                                                   line_number: 40, behavior: "works")]))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("bad_request")
      expect(response.parsed_body["message"]).to include("spec/models/order_spec.rb:40", "/behavior")
      expect(TestRun.count).to eq(0)
    end

    it "rejects a property the schema does not allow" do
      ingest(ingest_payload(specs: [annotated_spec(severity: "high")]))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("/severity")
    end

    it "rejects a layer outside the enum" do
      ingest(ingest_payload(specs: [annotated_spec(layer: "acceptance")]))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("/layer")
    end

    it "rejects an annotated spec with no intent at all" do
      ingest(ingest_payload(specs: [annotated_spec.merge(intent: nil)]))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("intent is required")
    end

    it "reports every offending spec, not just the first" do
      ingest(ingest_payload(specs: [annotated_spec(line_number: 1, behavior: "no"),
                                    annotated_spec(line_number: 2, layer: "acceptance")]))

      expect(response.parsed_body["details"].size).to eq(2)
    end
  end

  describe "a malformed envelope" do
    it "rejects a missing commit_sha" do
      ingest({ specs: [] })

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("commit_sha")
      expect(TestRun.count).to eq(0)
    end

    it "rejects a blank commit_sha" do
      ingest(ingest_payload(commit_sha: "   "))

      expect(response).to have_http_status(:bad_request)
    end

    it "rejects a missing specs array" do
      ingest({ commit_sha: "abc123" })

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("specs")
    end

    it "rejects specs that is not an array" do
      ingest({ commit_sha: "abc123", specs: { "0" => annotated_spec } })

      expect(response).to have_http_status(:bad_request)
    end

    it "rejects a spec with no file_path" do
      ingest(ingest_payload(specs: [annotated_spec.except(:file_path)]))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("file_path")
    end

    it "rejects a non-positive line_number" do
      ingest(ingest_payload(specs: [annotated_spec(line_number: 0)]))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("line_number")
    end

    it "rejects an unknown status" do
      ingest(ingest_payload(specs: [annotated_spec.merge(status: "skipped")]))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("status")
    end

    # Dropping it silently would lose an annotation whose author believed it had shipped.
    it "rejects an unannotated spec that nevertheless carries an intent" do
      ingest(ingest_payload(specs: [unannotated_spec.merge(intent: annotated_spec[:intent])]))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("must be null")
    end

    it "rejects a negative duration_seconds" do
      ingest(ingest_payload(duration_seconds: -1))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("duration_seconds")
    end

    it "rejects a JSON body that is not an object" do
      ingest([ingest_payload].to_json)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("JSON object")
    end

    it "rejects a body that is not JSON at all, in the API's own error shape" do
      ingest("{ not json")

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("bad_request")
      expect(TestRun.count).to eq(0)
    end
  end

  # The full auth matrix is proved once in spec/requests/api/v1/repositories_spec.rb. All this
  # endpoint owes is evidence that it inherits the filter rather than re-plumbing it.
  describe "authentication" do
    it "rejects a request with no Authorization header with 401" do
      expect { ingest(ingest_payload, key: nil) }.not_to change(TestRun, :count)

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["error"]).to eq("unauthorized")
    end

    it "rejects a bad key with 401" do
      ingest(ingest_payload, key: nil, headers: { "Authorization" => "Bearer sgk_not-a-key" })

      expect(response).to have_http_status(:unauthorized)
    end

    it "records when the key was last used" do
      ingest(ingest_payload)

      expect(api_key.reload.last_used_at).to be_present
    end
  end
end
