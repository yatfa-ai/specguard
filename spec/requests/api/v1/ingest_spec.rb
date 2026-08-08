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

  # A 20,000-example run is a 7.01 MiB JSON body and 0.33 MiB gzipped. The client gem bounds the
  # whole POST with one `write_timeout`, so on a modest CI uplink compression is the difference
  # between the run landing and the run never arriving. `GzipRequestBody` is what makes it
  # readable here; these are the end-to-end claims the middleware's own unit spec cannot make,
  # because they depend on the middleware being *in the stack* and in the right place in it.
  describe "a gzipped body" do
    let(:body) do
      ingest_payload(
        commit_sha: "beefcafe01",
        branch: "main",
        duration_seconds: 12.5,
        specs: [
          annotated_spec(file_path: "spec/models/invoice_spec.rb", line_number: 12),
          annotated_spec(file_path: "spec/requests/checkout_spec.rb", line_number: 30, layer: "request"),
          unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 7)
        ]
      )
    end

    def ingest_gzipped(payload, key: api_key)
      raw = payload.is_a?(String) ? payload : payload.to_json

      ingest(Zlib.gzip(raw), key: key, headers: { "Content-Encoding" => "gzip" })
    end

    def ingest_raw_gzip(bytes)
      ingest(bytes, headers: { "Content-Encoding" => "gzip" })
    end

    it "accepts it with 202" do
      ingest_gzipped(body)

      expect(response).to have_http_status(:accepted)
    end

    # The whole acceptance criterion in one example: not "gzip works" but "gzip is
    # indistinguishable". Both bodies are posted in the same example and their answers compared to
    # each other rather than to a hand-copied literal, so the two can never drift apart silently.
    it "answers exactly what the same body answers uncompressed" do
      ingest(body)
      identity = response.parsed_body

      ingest_gzipped(body)

      expect(response.parsed_body.except("test_run_id")).to eq(identity.except("test_run_id"))
      expect(identity).to include("total_specs" => 3, "annotated_specs" => 2, "annotated_ratio" => 0.667)
    end

    it "records a TestRun indistinguishable from the one the uncompressed body records" do
      ingest(body)
      identity_run = TestRun.find(response.parsed_body["test_run_id"])

      ingest_gzipped(body)
      gzipped_run = TestRun.find(response.parsed_body["test_run_id"])

      volatile = %w[id created_at updated_at]
      expect(gzipped_run.attributes.except(*volatile)).to eq(identity_run.attributes.except(*volatile))
    end

    # `ActionDispatch::Request#raw_post` reads exactly CONTENT_LENGTH bytes. A body that spans
    # several inflate chunks is where a mis-set length stops being a rounding error and starts
    # truncating the JSON — and a suite big enough to be worth compressing is always this shape.
    it "carries a body far larger than one inflate chunk without truncating it" do
      specs = Array.new(400) { |i| annotated_spec(file_path: "spec/models/m#{i}_spec.rb", line_number: i + 1) }
      large = ingest_payload(specs: specs)
      expect(large.to_json.bytesize).to be > GzipRequestBody::READ_CHUNK_BYTES

      ingest_gzipped(large)

      expect(response).to have_http_status(:accepted)
      expect(TestRun.sole.total_specs_count).to eq(400)
    end

    it "leaves the endpoint's own validation in charge of a gzipped body that is bad JSON-wise" do
      ingest_gzipped(ingest_payload(duration_seconds: -1))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("duration_seconds")
    end

    describe "when the body is not the gzip it claims to be" do
      it "answers 400 in the API's own error shape, not a 500" do
        ingest_raw_gzip("this is not gzip at all")

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to include("error" => "bad_request",
                                                "message" => GzipRequestBody::CORRUPT_MESSAGE)
        expect(response.parsed_body["details"]).to eq([GzipRequestBody::CORRUPT_MESSAGE])
        expect(TestRun.count).to eq(0)
      end

      it "answers 400 for a body that inflates past the cap" do
        stub_const("GzipRequestBody::MAX_INFLATED_BYTES", 1024)

        ingest_raw_gzip(Zlib.gzip("a" * (4 * 1024 * 1024)))

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["message"]).to include("inflates to more than")
        expect(TestRun.count).to eq(0)
      end
    end

    # The two failure families a gzipped request has, and the evidence the stack does not confuse
    # them: "your gzip is broken" and "your JSON is broken" are different bugs to go and fix.
    #
    # Asserted as one example on purpose, because either half alone is vacuous. With the inflater
    # missing from the stack entirely, a gzipped body reaches the JSON parser as raw bytes and
    # *both* of these requests come back as `JsonParseErrorResponder`'s parse error with a 400 —
    # so the second assertion passes for the wrong reason and proves nothing. Only the contrast
    # between the two messages tells a working inflater apart from no inflater at all.
    it "tells a broken gzip apart from a broken JSON body inside a good gzip" do
      ingest_raw_gzip("this is not gzip at all")

      expect(response.parsed_body["message"]).to eq(GzipRequestBody::CORRUPT_MESSAGE)

      ingest_gzipped("{ not json")

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to eq(JsonParseErrorResponder::MESSAGE)
    end

    # The inflater sits above the auth filter, so it necessarily runs for an unauthenticated
    # request too. It must not turn a 401 into anything else.
    it "still answers 401 for a gzipped body with no API key" do
      ingest_gzipped(body, key: nil)

      expect(response).to have_http_status(:unauthorized)
      expect(TestRun.count).to eq(0)
    end
  end

  # The grain everything about *tests* rather than about suites has to be asked at. Before
  # `spec_observations` a 20,000-example run retained two integers, and the five per-example fields
  # the shipped formatter has always sent — `id`, `spec_file_path`, `name`, `duration`, `outcome` —
  # were read off the wire and dropped.
  describe "the per-example rows a run leaves behind" do
    it "leaves one row per spec, annotated or not, each carrying the name the client sent" do
      body = ingest_payload(
        specs: [
          unannotated_spec(file_path: "spec/models/a_spec.rb", line_number: 3, name: "A is quiet"),
          unannotated_spec(file_path: "spec/models/b_spec.rb", line_number: 4, name: "B is quiet"),
          unannotated_spec(file_path: "spec/models/c_spec.rb", line_number: 5, name: "C is quiet"),
          annotated_spec(file_path: "spec/models/d_spec.rb", line_number: 6, name: "D is annotated")
        ]
      )

      expect { ingest(body) }.to change(SpecObservation, :count).by(4)

      run = TestRun.sole
      expect(run.spec_observations.pluck(:name)).to match_array(
        ["A is quiet", "B is quiet", "C is quiet", "D is annotated"]
      )
      expect(run.spec_observations.pluck(:repository_id).uniq).to eq([repository.id])
    end

    # The client's own measurement, turned into a platform guard: a table-driven loop writes the
    # `it` once, so all N examples report the same `(file_path, line_number)`. A key built on the
    # coordinate folds three examples onto one row and takes their durations with them.
    it "keeps three examples of one table-driven loop apart, though they share a coordinate" do
      body = ingest_payload(
        specs: (1..3).map do |index|
          unannotated_spec(
            file_path: "spec/models/table_spec.rb", line_number: 9,
            id: "./spec/models/table_spec.rb[1:#{index}]", name: "handles case #{index}"
          )
        end
      )

      ingest(body)

      rows = TestRun.sole.spec_observations
      expect(rows.count).to eq(3)
      expect(rows.pluck(:line_number).uniq).to eq([9])
      expect(rows.pluck(:example_id)).to match_array(
        (1..3).map { |index| "./spec/models/table_spec.rb[1:#{index}]" }
      )
    end

    # The other shape on the same coordinate: a shared example group reports
    # `spec/support/shared_examples.rb` as its definition site, and the file that actually ran the
    # example only ever appears as `spec_file_path`. Aggregating on `file_path` would attribute
    # every including file's time to a `spec/support/` helper that ran nothing.
    it "keeps a shared example group's two inclusions apart by the file that ran them" do
      shared = "spec/support/shared_examples.rb"
      body = ingest_payload(
        specs: [
          unannotated_spec(file_path: shared, line_number: 4, spec_file_path: "spec/models/order_spec.rb",
                           id: "./spec/models/order_spec.rb[1:1:1]", duration: 1.5),
          unannotated_spec(file_path: shared, line_number: 4, spec_file_path: "spec/models/refund_spec.rb",
                           id: "./spec/models/refund_spec.rb[1:1:1]", duration: 2.5)
        ]
      )

      ingest(body)

      rows = TestRun.sole.spec_observations
      expect(rows.count).to eq(2)
      expect(rows.pluck(:file_path).uniq).to eq([shared])
      expect(rows.group(:spec_file_path).sum(:duration_seconds)).to eq(
        "spec/models/order_spec.rb" => 1.5, "spec/models/refund_spec.rb" => 2.5
      )
    end

    it "round-trips duration and outcome per example, nulls included" do
      body = ingest_payload(
        specs: [
          unannotated_spec(file_path: "spec/a_spec.rb", line_number: 1, duration: 0.25, outcome: "passed"),
          unannotated_spec(file_path: "spec/b_spec.rb", line_number: 2, duration: 3.75, outcome: "failed"),
          unannotated_spec(file_path: "spec/c_spec.rb", line_number: 3, duration: 0.0, outcome: "pending"),
          unannotated_spec(file_path: "spec/d_spec.rb", line_number: 4, duration: nil, outcome: nil)
        ]
      )

      ingest(body)

      expect(TestRun.sole.spec_observations.pluck(:file_path, :duration_seconds, :outcome)).to match_array(
        [
          ["spec/a_spec.rb", 0.25, "passed"],
          ["spec/b_spec.rb", 3.75, "failed"],
          ["spec/c_spec.rb", 0.0, "pending"],
          ["spec/d_spec.rb", nil, nil]
        ]
      )
    end

    # `Ingest::Payload` validates `file_path`, `line_number`, `status` and `intent` — and nothing
    # else. `id` therefore arrives unchecked, and a repeat of one would violate the unique index
    # and take the whole ingest down with a 500. Storing one row is a better answer than losing the
    # run, and rejecting the payload belongs to envelope validation rather than to the writer.
    it "stores one row rather than 500ing when the client repeats an example id" do
      body = ingest_payload(
        specs: [
          unannotated_spec(file_path: "spec/a_spec.rb", line_number: 1, id: "dup", name: "first"),
          unannotated_spec(file_path: "spec/b_spec.rb", line_number: 2, id: "dup", name: "second")
        ]
      )

      ingest(body)

      expect(response).to have_http_status(:accepted)
      expect(TestRun.sole.spec_observations.pluck(:example_id, :name)).to eq([%w[dup first]])
      # The run's own denominator still counts what the client reported, which is two specs.
      expect(TestRun.sole.total_specs_count).to eq(2)
    end

    # A producer that sends no `id` at all — an older client, a third-party reporter — must not be
    # collapsed to a single row by the same dedup.
    it "keeps every example of a payload that carries no ids at all" do
      specs = (1..3).map { |index| unannotated_spec(file_path: "spec/#{index}_spec.rb", line_number: index, id: "") }

      ingest(ingest_payload(specs: specs))

      expect(TestRun.sole.spec_observations.count).to eq(3)
      expect(TestRun.sole.spec_observations.pluck(:example_id).uniq).to eq([nil])
    end

    it "stores an unsharded run's rows with no shard, because it has none to point at" do
      ingest(ingest_payload(specs: [unannotated_spec]))

      expect(TestRun.sole.test_run_shards).to be_empty
      expect(TestRun.sole.spec_observations.pluck(:test_run_shard_id)).to eq([nil])
    end

    # An anonymous slice — sharded, but with no `shard_id` to tell the slices apart — gets a fresh
    # `TestRunShard` row per POST, so the shard *counters* double on a redelivery and cannot not.
    # The rows do not, because their key is the run and the example rather than the delivery. That
    # asymmetry is documented in `Ingest::ObservationRecorder`; this is the assertion behind it.
    it "does not double an anonymous slice's rows, though it doubles its counters" do
      body = ingest_payload(ci_run_id: "gha-9", specs: [unannotated_spec(file_path: "spec/a_spec.rb", line_number: 1)])

      ingest(body)
      ingest(body)

      run = TestRun.sole
      expect(run.test_run_shards.count).to eq(2)
      expect(run.total_specs_count).to eq(2)
      expect(run.spec_observations.count).to eq(1)
    end

    describe "a four-shard run, one shard of which is re-run" do
      # Each shard owns its own files, exactly as a real splitter divides a suite, so the four
      # slices carry disjoint example ids the way a real run does.
      def shard_payload(index, examples: 3, ci_run_id: "gha-42")
        specs = (1..examples).map do |n|
          unannotated_spec(
            file_path: "spec/shard#{index}/e#{n}_spec.rb", line_number: n,
            id: "./spec/shard#{index}/e#{n}_spec.rb[1:1]", duration: index.to_f
          )
        end

        ingest_payload(commit_sha: "deadbee", ci_run_id: ci_run_id, shard_id: index.to_s, specs: specs)
      end

      def run_all_shards = (1..4).each { |index| ingest(shard_payload(index)) }

      it "stores every shard's rows against the TestRunShard row that delivered them" do
        run_all_shards

        run = TestRun.sole
        expect(run.spec_observations.count).to eq(12)
        expect(run.spec_observations.distinct.count(:test_run_shard_id)).to eq(4)
        expect(run.spec_observations.where(test_run_shard_id: nil)).to be_empty
        expect(run.test_run_shards.pluck(:id)).to match_array(run.spec_observations.distinct.pluck(:test_run_shard_id))
      end

      # The 25,100-denominator lesson carried one layer down: rows written per POST inherit none of
      # the counters' idempotency unless they are keyed the same way.
      it "leaves that shard's row count unchanged, so the suite still totals once" do
        run_all_shards

        expect { ingest(shard_payload(2)) }.not_to change(SpecObservation, :count)

        expect(TestRun.sole.spec_observations.count).to eq(12)
      end

      it "replaces the re-run shard's rows rather than keeping the stale ones beside them" do
        run_all_shards
        ingest(shard_payload(2, examples: 2))

        run = TestRun.sole
        expect(run.spec_observations.count).to eq(11)
        expect(run.spec_observations.where("file_path LIKE 'spec/shard2/%'").pluck(:file_path))
          .to match_array(%w[spec/shard2/e1_spec.rb spec/shard2/e2_spec.rb])
      end

      it "re-running every shard leaves the suite counted once" do
        run_all_shards

        expect { run_all_shards }.not_to change(SpecObservation, :count)
      end

      # Criterion 9 in one example: the new table is a second, finer record of the same delivery,
      # and the headline counters are deliberately *not* re-derived from it.
      it "leaves the run's own counters deriving from its shards, untouched" do
        run_all_shards

        expect(TestRun.sole).to have_attributes(total_specs_count: 12, annotated_specs_count: 0)
      end
    end
  end


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
