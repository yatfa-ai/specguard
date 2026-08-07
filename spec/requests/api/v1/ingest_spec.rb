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

  # The defect this accumulation exists for: a 20,000-example suite is the size at which nobody
  # runs single-process, so every shard loads the formatter and POSTs its own slice. Creating a row
  # per request produced N rows with a split denominator, and `Repository#latest_test_run` picked
  # whichever shard finished last — an unstable headline for an unchanged suite.
  describe "a sharded CI run, delivered as one POST per shard" do
    # Annotations clustered in a minority of files, which is how teams actually annotate: whoever
    # reads a single shard's row reads anything from 8% to 71%, and never the 25% that is true.
    let(:shards) do
      [
        { total: 4900, annotated: 500 },
        { total: 4900, annotated: 400 },
        { total: 5100, annotated: 3600 },
        { total: 5100, annotated: 500 }
      ]
    end

    def shard_payload(total:, annotated:, ci_run_id: "gha-42", **attrs)
      specs = Array.new(total) do |index|
        index < annotated ? annotated_spec(line_number: index + 1) : unannotated_spec(line_number: index + 1)
      end

      ingest_payload(commit_sha: "deadbee", branch: "main", ci_run_id: ci_run_id, specs: specs, **attrs)
    end

    it "lands the whole run as one TestRun whose denominator is the whole suite" do
      expect { shards.each { |shard| ingest(shard_payload(**shard)) } }
        .to change(TestRun, :count).by(1)

      run = TestRun.last
      expect(run.total_specs_count).to eq(20_000)
      expect(run.annotated_specs_count).to eq(5000)
      expect(run.annotated_ratio).to eq(25.0)
    end

    # Summing would report ~4× the wall clock, because the shards ran at the same time. The number
    # has to be reconcilable with what the operator's CI dashboard shows for the build.
    it "reports the slowest shard's duration, not the sum of all four" do
      [61.0, 58.5, 74.25, 60.0].each_with_index do |duration, index|
        ingest(shard_payload(**shards[index], duration_seconds: duration))
      end

      expect(TestRun.last.duration_seconds).to eq(74.25)
    end

    it "widens the duration even when the slowest shard arrives first" do
      ingest(shard_payload(total: 2, annotated: 1, duration_seconds: 90.0))
      ingest(shard_payload(total: 2, annotated: 1, duration_seconds: 10.0))

      expect(TestRun.last.duration_seconds).to eq(90.0)
    end

    it "takes the first shard's duration when a later shard reports none" do
      ingest(shard_payload(total: 2, annotated: 1, duration_seconds: 12.5))
      ingest(shard_payload(total: 2, annotated: 1))

      expect(TestRun.last.duration_seconds).to eq(12.5)
    end

    # `update_counters` writes past the loaded instance, so an un-reloaded record would answer with
    # the previous shard's numbers — the client would read a total that never existed.
    it "answers each shard with the run's totals so far, not the stale ones" do
      ingest(shard_payload(total: 10, annotated: 4))
      ingest(shard_payload(total: 6, annotated: 2))

      expect(response.parsed_body).to include(
        "test_run_id" => TestRun.last.id,
        "total_specs" => 16,
        "annotated_specs" => 6,
        "annotated_ratio" => 0.375
      )
    end

    it "keeps the run under the commit and branch the first shard named" do
      shards.each { |shard| ingest(shard_payload(**shard)) }

      expect(TestRun.last).to have_attributes(commit_sha: "deadbee", branch: "main", ci_run_id: "gha-42")
    end

    # `commit_sha` cannot be the key: a re-run of the same commit is genuinely a second run, and
    # merging the two would hide a suite that changed between them.
    it "keeps two CI runs of the same commit apart when their run ids differ" do
      expect do
        ingest(shard_payload(total: 4, annotated: 2, ci_run_id: "gha-42"))
        ingest(shard_payload(total: 4, annotated: 2, ci_run_id: "gha-43"))
      end.to change(TestRun, :count).by(2)

      expect(TestRun.pluck(:total_specs_count)).to all(eq(4))
    end

    it "scopes accumulation to the repository behind the key, not to the run id alone" do
      other = create_repository(user: create_user(github_uid: "2002", github_handle: "hubot"),
                                github_full_name: "acme/ledger")

      expect do
        ingest(shard_payload(total: 4, annotated: 2))
        ingest(shard_payload(total: 4, annotated: 2), key: other.api_keys.create!)
      end.to change(TestRun, :count).by(2)

      expect(repository.test_runs.sole.total_specs_count).to eq(4)
      expect(other.test_runs.sole.total_specs_count).to eq(4)
    end
  end

  # The gesture the run identity alone could not survive.
  #
  # CI providers keep a build's id STABLE across a re-run — GitHub's `GITHUB_RUN_ID` is documented
  # as *"This number does not change if you re-run the workflow run"*, Buildkite retries a job
  # inside the same `BUILDKITE_BUILD_ID`, GitLab inside the same `CI_PIPELINE_ID`. An
  # implementation that keyed on the run id and *added* each arriving payload therefore could not
  # tell a re-delivery from a new slice, and "re-run failed jobs" produced a headline ratio that
  # was wrong rather than merely partial. `shard_id` is what closes that: the run's counts are
  # derived from its shards, so a shard reporting again replaces its own slice.
  describe "a sharded CI run that is re-run under the same run id" do
    let(:shards) do
      [
        { total: 4900, annotated: 500, shard_id: "1" },
        { total: 4900, annotated: 400, shard_id: "2" },
        { total: 5100, annotated: 3600, shard_id: "3" },
        { total: 5100, annotated: 500, shard_id: "4" }
      ]
    end

    def shard_payload(total:, annotated:, ci_run_id: "gha-42", **attrs)
      specs = Array.new(total) do |index|
        index < annotated ? annotated_spec(line_number: index + 1) : unannotated_spec(line_number: index + 1)
      end

      ingest_payload(commit_sha: "deadbee", branch: "main", ci_run_id: ci_run_id, specs: specs, **attrs)
    end

    def run_all_shards = shards.each { |shard| ingest(shard_payload(**shard)) }

    it "still lands the first attempt as one TestRun over the whole suite" do
      expect { run_all_shards }.to change(TestRun, :count).by(1)

      expect(TestRun.sole).to have_attributes(total_specs_count: 20_000, annotated_specs_count: 5000)
    end

    # "Re-run all jobs". Every shard reports a second time under the same run id. Adding would give
    # a 40,000 denominator for a 20,000-example suite.
    it "does not double the suite when every shard reports again" do
      run_all_shards

      expect { run_all_shards }.not_to change(TestRun, :count)

      expect(TestRun.sole).to have_attributes(total_specs_count: 20_000, annotated_specs_count: 5000)
      expect(TestRun.sole.annotated_ratio).to eq(25.0)
    end

    # **The blocking case.** "Re-run failed jobs" is the mainline recovery gesture for a sharded
    # suite — sharding a 20,000-example suite exists precisely so one flaky shard does not cost a
    # full re-run — so this is the ordinary path, not a corner. Re-adding shard 3 on top of itself
    # gave a 25,100 denominator for a 20,000-example suite, with the ratio dragged off by however
    # annotated that shard happened to be.
    it "reports the truth when only the failed shard is re-run" do
      run_all_shards

      ingest(shard_payload(**shards[2]))

      expect(TestRun.sole).to have_attributes(total_specs_count: 20_000, annotated_specs_count: 5000)
      expect(TestRun.sole.annotated_ratio).to eq(25.0)
    end

    # And the re-run is genuinely a *refresh*, not a no-op: a shard whose numbers changed between
    # attempts — someone pushed an annotation, a file moved between shards — replaces its own
    # slice rather than being ignored.
    it "takes the re-run shard's new numbers in place of its old ones" do
      run_all_shards

      ingest(shard_payload(total: 5100, annotated: 4100, shard_id: "3"))

      # Shard 3's 3,600 annotations become 4,100; the other three shards are untouched.
      expect(TestRun.sole).to have_attributes(total_specs_count: 20_000, annotated_specs_count: 5500)
    end

    it "keeps one row per shard rather than one per delivery" do
      run_all_shards
      run_all_shards

      expect(TestRun.sole.test_run_shards.count).to eq(4)
    end

    # `duration_seconds` is a MAX over the shards, and it is derived like the counts are — so when
    # the slowest shard is re-run and comes back faster, the run gets *faster*. An implementation
    # that only ever widened the maximum would be stuck at the old high-water mark forever.
    it "narrows the duration when the slowest shard is re-run and comes back faster" do
      shards.each_with_index { |shard, index| ingest(shard_payload(**shard, duration_seconds: [61.0, 58.5, 74.25, 60.0][index])) }
      expect(TestRun.sole.duration_seconds).to eq(74.25)

      ingest(shard_payload(**shards[2], duration_seconds: 59.0))

      expect(TestRun.sole.duration_seconds).to eq(61.0)
    end

    # A shard index is only unique *within* a run — every run has a shard "1". Scoping the key to
    # the run is what stops two builds' shard 1s from overwriting each other.
    it "does not let one run's shard overwrite another run's shard of the same name" do
      ingest(shard_payload(total: 10, annotated: 4, shard_id: "1"))
      ingest(shard_payload(total: 20, annotated: 9, shard_id: "1", ci_run_id: "gha-43"))

      expect(repository.test_runs.count).to eq(2)
      expect(repository.test_runs.order(:id).map(&:total_specs_count)).to eq([10, 20])
    end

    # The honest limit, pinned so it cannot regress silently into something worse and cannot be
    # mistaken for idempotency the design does not have. A client that shards without exposing an
    # index the gem recognises sends no `shard_id`, and its slices are genuinely
    # indistinguishable — so they are counted (losing one would be worse) but a redelivery is
    # counted again. `Ingest::RunRecorder#upsert_shard` and the client README's sharding section
    # both say so; this is the executable version of that sentence.
    it "cannot deduplicate shards the client did not name, and counts a redelivery twice" do
      ingest(shard_payload(total: 100, annotated: 25, shard_id: nil))
      ingest(shard_payload(total: 100, annotated: 25, shard_id: nil))

      expect(TestRun.sole.total_specs_count).to eq(200)
    end
  end

  # The local path the roadmap's DoD explicitly protects. Without a *partial* unique index this is
  # where a non-partial one would show itself: every laptop run in a repository collapsing into a
  # single ever-growing row.
  describe "a run that no CI provider named" do
    it "gives each unidentified run its own TestRun, exactly as before" do
      expect do
        ingest(ingest_payload(commit_sha: "deadbee", specs: [annotated_spec]))
        ingest(ingest_payload(commit_sha: "deadbee", specs: [annotated_spec]))
      end.to change(TestRun, :count).by(2)

      expect(TestRun.pluck(:ci_run_id)).to eq([nil, nil])
      expect(TestRun.pluck(:total_specs_count)).to eq([1, 1])
    end

    it "treats a blank ci_run_id as no run id at all rather than as a key" do
      expect do
        ingest(ingest_payload(ci_run_id: "   ", specs: [annotated_spec]))
        ingest(ingest_payload(ci_run_id: "", specs: [annotated_spec]))
      end.to change(TestRun, :count).by(2)

      expect(TestRun.pluck(:ci_run_id)).to eq([nil, nil])
    end
  end

  # Four shards POST at once. The lookup and the insert are not one operation, so the shard that
  # loses the race meets the partial unique index — and before the rescue that was a 500 with its
  # counts discarded. Driven through the recorder rather than over HTTP because a request spec runs
  # inside one transaction, which a genuinely concurrent connection could not see into; the seam is
  # the lookup, and what is faked is only its *timing*.
  describe "shards racing to create the same run" do
    let(:attributes) do
      { ci_run_id: "gha-42", commit_sha: "deadbee", duration_seconds: 30.0,
        total_specs_count: 3, annotated_specs_count: 1 }
    end
    let(:recorder) { Ingest::RunRecorder.new(repository, attributes, shard_id: "shard-2") }

    it "recovers when the row appears between the lookup and the insert, without losing counts" do
      winner = nil
      lookups = 0

      # First lookup answers nil — the state every shard sees before any insert has landed — and
      # the winning shard's row lands immediately afterwards, so our insert hits the index.
      #
      # The winner is recorded *through the recorder*, not written straight to `test_runs`: a run
      # with a `ci_run_id` keeps its counts in `test_run_shards`, so a hand-built row would be a
      # run with no slices — a state the recorder's own transaction makes unreachable, and faking
      # it would have this example assert against a shape production can never produce.
      allow(recorder).to receive(:find_run).and_wrap_original do |original|
        lookups += 1
        next original.call unless lookups == 1

        winner = Ingest::RunRecorder.record(repository,
                                            attributes.merge(total_specs_count: 5, annotated_specs_count: 2,
                                                             duration_seconds: 40.0),
                                            shard_id: "shard-1")
        nil
      end

      run = nil
      expect { run = recorder.record }.to change(TestRun, :count).by(1)

      expect(run.id).to eq(winner.id)
      expect(run).to have_attributes(total_specs_count: 8, annotated_specs_count: 3,
                                     duration_seconds: 40.0)
    end

    it "gives up rather than retrying forever when the collision never resolves" do
      # A row that is always absent on lookup and always present on insert — the pathological case
      # the attempt cap exists for. Retrying it forever would hang the request instead.
      allow(recorder).to receive(:find_run).and_return(nil)
      allow(recorder).to receive(:create_run).and_raise(ActiveRecord::RecordNotUnique, "duplicate key")

      expect { recorder.record }.to raise_error(ActiveRecord::RecordNotUnique)
      expect(recorder).to have_received(:create_run).exactly(Ingest::RunRecorder::MAX_ATTEMPTS).times
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

    # A run id sent as a JSON number would key its shards on `12345` while a client that sent the
    # same build's id as a string keyed on `"12345"` — one run split over a type difference, which
    # is the exact failure the field exists to remove.
    it "rejects a ci_run_id that is not a string" do
      ingest(ingest_payload(ci_run_id: 12_345))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("ci_run_id")
      expect(TestRun.count).to eq(0)
    end

    # Absence is the ordinary shape of a run nobody's CI provider named, and must never be a
    # rejection — the local path depends on it.
    it "accepts a run that omits ci_run_id entirely" do
      ingest(ingest_payload)

      expect(response).to have_http_status(:accepted)
      expect(TestRun.last.ci_run_id).to be_nil
    end

    # The same rule as `ci_run_id`, and the number case is *likelier* here: every runner that
    # publishes a shard index publishes `0`, `1`, `2`, so sending them unquoted is the natural
    # mistake. `0` and `"0"` keying different shards would let a shard fail to replace itself,
    # which is the one property these ids exist to provide.
    it "rejects a shard_id that is not a string" do
      ingest(ingest_payload(ci_run_id: "gha-42", shard_id: 0))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("shard_id")
      expect(TestRun.count).to eq(0)
    end

    it "accepts a run that omits shard_id entirely" do
      ingest(ingest_payload(ci_run_id: "gha-42"))

      expect(response).to have_http_status(:accepted)
      expect(TestRun.last.test_run_shards.sole.shard_id).to be_nil
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
