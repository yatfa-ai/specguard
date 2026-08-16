# frozen_string_literal: true

require "rails_helper"

# What a REFUSED delivery leaves behind.
#
# The accepted path is covered end to end in `spec/requests/api/v1/ingest_spec.rb`; this file is
# about the 400 — the path that, before `IngestRejection`, produced zero platform-side record while
# `authenticate_api_key!` had already stamped the one column the dashboard reads to say
# "Connected".
RSpec.describe "POST /api/v1/ingest — the record a refused delivery leaves", type: :request do
  let(:repository) { create_repository }
  let(:api_key) { repository.api_keys.create! }

  def ingest(body, key: api_key, headers: {})
    post "/api/v1/ingest",
         params: body.is_a?(String) ? body : body.to_json,
         headers: { "Content-Type" => "application/json" }
           .merge(key ? { "Authorization" => "Bearer #{key.raw_token}" } : {})
           .merge(headers)
  end

  # A body that authenticates and is then refused for its payload: the envelope is missing
  # `commit_sha`, which `Ingest::Payload` collects as an error.
  def refused_body = { specs: [] }

  describe "an authenticated request whose payload is refused" do
    it "writes exactly one row, attributed to the repository that authenticated" do
      expect { ingest(refused_body) }.to change(IngestRejection, :count).by(1)

      expect(IngestRejection.last.repository).to eq(repository)
    end

    it "stamps when the refusal happened" do
      ingest(refused_body)

      expect(IngestRejection.last.occurred_at).to be_within(5.seconds).of(Time.current)
    end

    # The row carries the endpoint's own words and nothing re-worded. Compared against the
    # response's `details` rather than against a literal, which is the whole claim: the owner reads
    # exactly what the client was told, so the two cannot drift apart into a platform-side
    # paraphrase.
    it "stores the payload's errors verbatim, identical to what the client was handed" do
      ingest(refused_body)

      expect(IngestRejection.last.details).to eq(response.parsed_body["details"])
      expect(IngestRejection.last.details).to be_present
    end

    # The concrete reason the header is on the row: a version floor is diagnosable only if the row
    # says which version reported.
    it "records the client's User-Agent" do
      ingest(refused_body, headers: { "User-Agent" => "specguard-rspec/0.3.1" })

      expect(IngestRejection.last.user_agent).to eq("specguard-rspec/0.3.1")
    end

    it "records a nil User-Agent rather than a placeholder when the client sent none" do
      ingest(refused_body, headers: { "User-Agent" => "" })

      expect(IngestRejection.last.user_agent).to be_nil
    end

    # Success criterion 2. The row is bookkeeping the client never asked for and must be invisible
    # in the answer it gets — status and every key of the body, not just the status.
    it "leaves the 400 response contract completely unchanged" do
      ingest(refused_body)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body.keys).to contain_exactly("error", "message", "details")
      expect(response.parsed_body["error"]).to eq("bad_request")
      expect(response.parsed_body["message"]).to eq(response.parsed_body["details"].first)
    end

    it "still stores nothing of the run itself — this is a record of the refusal, not a retry queue" do
      expect { ingest(refused_body) }.not_to change(TestRun, :count)

      expect(SpecObservation.count).to eq(0)
    end
  end

  # Success criterion 3, and the honesty bound the panel rests on. `ApiKey.authenticate` returns
  # nil, `render_unauthorized` returns BEFORE the stamp, and no repository is ever resolved — so
  # there is nothing to attribute a row to and none is invented.
  describe "a request that never authenticates" do
    it "writes no row for a missing Authorization header" do
      expect { ingest(refused_body, key: nil) }.not_to change(IngestRejection, :count)

      expect(response).to have_http_status(:unauthorized)
    end

    it "writes no row for a bad key, even though the payload would also have been refused" do
      expect do
        ingest(refused_body, key: nil, headers: { "Authorization" => "Bearer sgk_not-a-key" })
      end.not_to change(IngestRejection, :count)

      expect(response).to have_http_status(:unauthorized)
    end
  end

  # Success criterion 9. The accepted path must be untouched — a rejection table that started
  # writing rows for successful runs would make the panel's central claim false.
  describe "a delivery that is accepted" do
    it "writes no rejection row and still answers 202" do
      expect { ingest(ingest_payload) }.not_to change(IngestRejection, :count)

      expect(response).to have_http_status(:accepted)
      expect(TestRun.count).to eq(1)
    end
  end

  # Success criterion 4. Two rather than the shipped fifty, so an example is three POSTs.
  describe "the retention rule" do
    before { stub_const("IngestRejection::REPOSITORY_RETENTION_ROWS", 2) }

    it "keeps only the most recent N refusals of a repository" do
      3.times { ingest(refused_body) }

      expect(repository.ingest_rejections.count).to eq(2)
    end

    it "evicts the OLDEST, so what survives is the recent window the panel claims to show" do
      ingest({ specs: [], marker: "first" })
      oldest = IngestRejection.last
      2.times { ingest(refused_body) }

      expect(IngestRejection.where(id: oldest.id)).to be_empty
      expect(repository.ingest_rejections.count).to eq(2)
    end

    # The window is per REPOSITORY — see `IngestRejection::REPOSITORY_RETENTION_ROWS` for why it
    # cannot be per branch the way `Ingest::ObservationPruner`'s is. This is what "per repository"
    # has to mean: one repository's refusals never evict another's.
    it "bounds each repository on its own" do
      other = create_repository(user: create_user(github_uid: "2002", github_handle: "hubot"),
                                github_full_name: "acme/other-service")
      other_key = other.api_keys.create!
      2.times { ingest(refused_body, key: other_key) }

      3.times { ingest(refused_body) }

      expect(repository.ingest_rejections.count).to eq(2)
      expect(other.ingest_rejections.count).to eq(2)
    end
  end

  # The decision stated in `Ingest::RejectionRecorder`: a write that fails must not turn a clean
  # 400 into a 500, and must not fail silently either.
  describe "when the rejection cannot be written" do
    before do
      allow(IngestRejection).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "boom")
    end

    it "still answers the client the 400 it had already determined" do
      ingest(refused_body)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("bad_request")
    end

    # The loss is invisible on the dashboard by construction — the panel simply shows fewer rows —
    # so it has to be loud somewhere. This pins that it is, and that it is not a bare rescue.
    it "reports the failure rather than swallowing it" do
      expect(Rails.error).to receive(:report)
        .with(instance_of(ActiveRecord::StatementInvalid), hash_including(handled: true))

      ingest(refused_body)
    end
  end
end
