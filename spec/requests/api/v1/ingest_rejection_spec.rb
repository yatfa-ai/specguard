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

  # Success criterion 4's other axis. `REPOSITORY_RETENTION_ROWS` bounds how many refusals a
  # repository keeps and says nothing about how big one of them is — and `Ingest::Payload` emits one
  # error PER INVALID SPEC, so the size of a row is a function of the SUITE, not of how wrong the
  # payload is. That is not the tail case here: this table exists for a pipeline refusing every run,
  # and a version floor or an envelope skew refuses every spec at once.
  #
  # These examples are the fence the first round of this work did not have. Every other example in
  # this file refuses with `{ specs: [] }`, which produces exactly ONE error, so nothing here had
  # ever written a multi-reason row.
  describe "a refusal with more reasons than one row may hold" do
    # 30 malformed specs × 4 objections each (file_path, line_number, status, name) = 120 reasons,
    # which is six times the per-row bound and the same SHAPE as a 20,000-example suite refused for
    # its envelope — one reason per example — at a size an example can run.
    def many_reasons_body = { commit_sha: "a" * 40, specs: Array.new(30) { {} } }

    it "produces the shape these examples rest on — many more reasons than the bound" do
      ingest(many_reasons_body)

      expect(response.parsed_body["details"].size).to eq(120)
      expect(120).to be > IngestRejection::RETAINED_REASONS_PER_ROW
    end

    it "stores at most RETAINED_REASONS_PER_ROW of them" do
      ingest(many_reasons_body)

      expect(IngestRejection.last.details.size).to eq(IngestRejection::RETAINED_REASONS_PER_ROW)
    end

    # What was dropped is COUNTED, not discarded silently — this is what lets the panel say "and
    # 100 more", which is itself the diagnosis: every spec was refused, not one.
    it "records how many reasons the endpoint actually gave" do
      ingest(many_reasons_body)

      rejection = IngestRejection.last
      expect(rejection.total_reasons_count).to eq(120)
      expect(rejection.omitted_reasons_count).to eq(120 - IngestRejection::RETAINED_REASONS_PER_ROW)
      expect(rejection).to be_reasons_truncated
    end

    # The count bound alone does not bound the row: every per-spec message interpolates the client's
    # own `file_path`, and a client free to send a malformed path is free to send a huge one. Twenty
    # unbounded strings is still a multi-megabyte row, so both halves are needed for the ceiling to
    # be arithmetic rather than a hope about well-behaved clients.
    it "shortens a single pathological reason rather than storing it whole" do
      long_path = "x" * 5_000
      ingest({ commit_sha: "a" * 40,
               specs: [{ file_path: long_path, line_number: 0, status: "unannotated", name: "a" }] })

      stored = IngestRejection.last.details.first
      expect(response.parsed_body["details"].first.length).to be > 5_000
      expect(stored.length).to be <= IngestRejection::MAX_REASON_LENGTH
    end

    # The bound expressed as the thing it is actually protecting. Every client-controlled axis
    # pushed at once — many reasons, each one pathological, AND a pathological `User-Agent` — and
    # measured over the WHOLE ROW rather than over `details` alone, because `user_agent` sits on the
    # same row and is equally the client's to choose. Measuring one column would let a ~100 KB
    # header pass a fence whose name is a claim about the row.
    it "keeps the row under a stated size ceiling however large the payload or the client's header" do
      ingest({ commit_sha: "a" * 40,
               specs: Array.new(200) { { file_path: "x" * 5_000, line_number: 0 } } },
             headers: { "User-Agent" => "u" * 100_000 })

      expect(IngestRejection.last.attributes.to_json.bytesize).to be < 10_000
    end

    # The other client-controlled column on the row, on its own, so a regression in the header half
    # names itself instead of surfacing as a byte count drifting up.
    it "shortens a pathological User-Agent rather than storing it whole" do
      ingest(refused_body, headers: { "User-Agent" => "u" * 100_000 })

      stored = IngestRejection.last.user_agent
      expect(stored.length).to be <= IngestRejection::MAX_USER_AGENT_LENGTH
      expect(stored).to end_with("...")
    end

    # Success criterion 2, restated for the case that made bounding necessary. The bound is a
    # STORAGE rule and must not reach the client: the response still carries every reason, in full,
    # exactly as `origin/main` sent it. `truncate` returning a new String is what guarantees it —
    # these are the same String objects `render_bad_request` is about to serialise.
    it "leaves the client's 400 carrying every reason at full length" do
      long_path = "y" * 4_000
      ingest({ commit_sha: "a" * 40,
               specs: Array.new(30) { { file_path: long_path, line_number: 0 } } })

      details = response.parsed_body["details"]
      expect(details.size).to eq(90)
      expect(details).to all(satisfy { |reason| reason.length > 4_000 })
      expect(response).to have_http_status(:bad_request)
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

  # The two failures are reported as separate stages because they mean different things: a failed
  # write loses the refusal, while a failed prune leaves a committed row and a repository briefly
  # over its bound. The return value has to say which happened, or it says the opposite of the truth.
  describe "when the retention prune fails after the row is written" do
    before { allow(IngestRejection).to receive(:where).and_raise(ActiveRecord::StatementInvalid, "boom") }

    it "keeps the committed row and still answers the 400" do
      expect { ingest(refused_body) }.to change(IngestRejection, :count).by(1)

      expect(response).to have_http_status(:bad_request)
    end

    it "reports the prune failure under its own stage" do
      expect(Rails.error).to receive(:report)
        .with(instance_of(ActiveRecord::StatementInvalid), hash_including(context: hash_including(stage: "prune")))

      ingest(refused_body)
    end

    # The row is committed, so returning nil — "the write failed" — would be a lie about the one
    # thing the caller could observe.
    it "returns the row that was written" do
      repository_record = repository
      result = Ingest::RejectionRecorder.record(repository_record, ["boom"], user_agent: nil)

      expect(result).to be_a(IngestRejection)
      expect(result).to be_persisted
    end
  end
end
