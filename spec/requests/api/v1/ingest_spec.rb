# frozen_string_literal: true

require "rails_helper"

RSpec.describe "POST /api/v1/ingest", type: :request do
  let(:repository) { create_repository }
  let(:api_key) { repository.api_keys.create! }

  # `path:` defaults to the canonical spelling, so every existing caller is unchanged. It is a
  # parameter at all because the router recognises `/api/v1/ingest/` as the SAME action, and the
  # boundary-refusal seam has to be pinned against that spelling too.
  def ingest(body, key: api_key, headers: {}, path: "/api/v1/ingest")
    post path,
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

    # @intent: { entity: "POST /api/v1/ingest", action: "accept a well-formed run", behavior: "a structurally valid JSON envelope from a repository key is acknowledged with 202 Accepted rather than an error status", layer: "request" }
    it "accepts it with 202" do
      ingest(body)

      expect(response).to have_http_status(:accepted)
    end

    # @intent: { entity: "TestRun", action: "record a run", behavior: "one POST creates exactly one row carrying the repository, commit, branch, duration and spec counts belonging to that delivery", layer: "request" }
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

    # @intent: { entity: "TestRun", action: "derive spec counts", behavior: "total and annotated counts are computed server-side from the specs array, so client-supplied counter values are ignored on the wire", layer: "request" }
    it "derives the counts itself rather than trusting the ones the client sent" do
      ingest(body.merge(total_specs_count: 999, annotated_specs_count: 999))

      expect(TestRun.last.total_specs_count).to eq(3)
      expect(TestRun.last.annotated_specs_count).to eq(2)
    end

    # @intent: { entity: "POST /api/v1/ingest", action: "answer with the documented body", behavior: "the 202 response is exactly the published field set: run id, totals, ratio, recorded and identified counts, and embedding status", layer: "request" }
    it "returns the documented body" do
      ingest(body)

      expect(response.parsed_body).to eq(
        "test_run_id" => TestRun.last.id,
        "total_specs" => 3,
        "annotated_specs" => 2,
        "annotated_ratio" => 0.667,
        "recorded_specs" => 3,
        "identified_specs" => 3,
        "embedding_status" => "queued"
      )
    end

    # The 100× trap: `TestRun#annotated_ratio` is 66.7 and the dashboard prints it with a `%`,
    # while the API field is documented as a 0–1 fraction. Pinned here because the two are
    # indistinguishable in a JSON body until a client is already 100× wrong.
    # @intent: { entity: "annotated_ratio", action: "render the fraction", behavior: "the API field is a 0-1 fraction even though the model and dashboard carry the same figure as a percentage, so the two scales never leak across", layer: "request" }
    it "reports annotated_ratio as a 0-1 fraction, not the dashboard's percentage" do
      ingest(body)

      expect(response.parsed_body["annotated_ratio"]).to eq(0.667)
      expect(TestRun.last.annotated_ratio).to eq(66.7)
    end

    # Identity resolution is `Ingest::IdentityResolutionJob`'s and writes `spec_identities`.
    # `spec_intents` is a different table with a different (positional) key and no writer at all —
    # see `db/migrate/20260811120000_create_spec_identities.rb` for why identity did not go there.
    # @intent: { entity: "SpecIntent", action: "avoid side writes", behavior: "a successful delivery leaves the positional spec_intents table untouched because identity resolution owns that seam asynchronously", layer: "request" }
    it "persists no spec_intents" do
      expect { ingest(body) }.not_to change(SpecIntent, :count)
    end

    # The seam is filled, so it may finally say so — and only because it genuinely enqueued.
    # @intent: { entity: "POST /api/v1/ingest", action: "report embedding status", behavior: "queued is answered only when an IdentityResolutionJob was genuinely enqueued, and the job argument is the run id alone", layer: "request" }
    it "reports queued, and has a job to show for it" do
      expect { ingest(body) }.to have_enqueued_job(Ingest::IdentityResolutionJob)

      expect(response.parsed_body["embedding_status"]).to eq("queued")
      # The run's id and nothing else: a 20,000-example payload as a job argument would be
      # megabytes of JSON in `solid_queue_jobs`, and the specs are already in the database.
      expect(enqueued_jobs.sole["arguments"]).to eq([TestRun.last.id])
    end

    # The synchronous half answers 202 before any per-spec work, so nothing is resolved yet at the
    # moment the client reads the body. Asserted rather than assumed: a resolution that had crept
    # into the request would be 20,000 embeddings inside the run's `FOR UPDATE` lock.
    # @intent: { entity: "SpecIdentity", action: "defer resolution inline", behavior: "nothing is resolved during the request: no identity rows appear and every observation keeps a null spec_identity_id until the job runs", layer: "request" }
    it "resolves nothing inline — the identity work is genuinely asynchronous" do
      expect { ingest(body) }.not_to change(SpecIdentity, :count)

      expect(TestRun.last.spec_observations.pluck(:spec_identity_id)).to all(be_nil)
    end

    # The columns the resolver reads. Until now `Ingest::Payload` validated the intent triple,
    # counted it into `annotated_specs_count` and then dropped it, which forced every cross-run
    # read onto `name` alone and made annotating a test change nothing about its identity.
    # @intent: { entity: "SpecObservation", action: "store the intent triple", behavior: "entity, action and behavior sent for an annotated example are persisted verbatim on that example row for the resolver to read later", layer: "request" }
    it "keeps the intent triple the client sent, at the observation" do
      ingest(body)

      annotated = TestRun.last.spec_observations.where.not(intent_entity: nil)

      expect(annotated.count).to eq(2)
      expect(annotated.first.slice(:intent_entity, :intent_action, :intent_behavior).values)
        .to eq(["Invoice", "finalize", "locks the line items once the invoice is finalized"])
    end

    # @intent: { entity: "SpecObservation", action: "null the intent columns", behavior: "an unannotated example stores nulls for entity, action and behavior instead of any defaulted or invented triple", layer: "request" }
    it "leaves an unannotated example's intent columns null rather than inventing a triple" do
      ingest(body)

      unannotated = TestRun.last.spec_observations.find_by(status: "unannotated")

      expect(unannotated.intent_entity).to be_nil
      expect(unannotated.intent_action).to be_nil
      expect(unannotated.intent_behavior).to be_nil
    end

    # THE FIELD THE ENVELOPE REQUIRED AND STORAGE THEN DROPPED. `layer` is in the schema's
    # `required` list and constrained to a four-token enum, so `Ingest::Payload#validate_intent`
    # rejected every run that omitted it — and then `intent_attributes` wrote the other three and
    # discarded this one, which is the inversion `intent_layer` closes.
    #
    # Asserted by READING THE ROW BACK, never by expecting the recorder to have been called with
    # something: a message expectation would pass against a column that was never added and against
    # an `upsert_all` that silently dropped the key.
    # @intent: { entity: "SpecObservation", action: "store the declared layer", behavior: "the intent_layer column keeps the layer value each annotated example declared, read back from the row rather than from the recorder call", layer: "request" }
    it "keeps the layer each annotated example declared, at the observation" do
      ingest(body)

      layers = TestRun.last.spec_observations.where.not(intent_entity: nil)
                      .order(:line_number).pluck(:intent_layer)

      expect(layers).to eq(%w[unit request])
    end

    # The other half of the pair above, and the reason the column is nullable. This is partly
    # STRUCTURAL rather than a choice the recorder makes freely: `validate_intent` requires `intent`
    # to be ABSENT when `status == "unannotated"`, so what is pinned here is the recorder's handling
    # of a nil intent — and specifically the `presence_of` path, which is what keeps `""` from
    # reaching the column. A blank string would make "declared no layer" indistinguishable from a
    # layer whose name is empty, so `be_nil` is asserted rather than `be_blank`.
    # @intent: { entity: "SpecObservation", action: "null the layer column", behavior: "an unannotated example stores a null layer, never an empty string, so absence stays distinguishable from a blank name", layer: "request" }
    it "leaves an unannotated example's layer null rather than defaulting or blanking it" do
      ingest(body)

      unannotated = TestRun.last.spec_observations.find_by(status: "unannotated")

      expect(unannotated.intent_layer).to be_nil
      expect(unannotated.intent_layer).not_to eq("")
    end

    # THE `upsert_all` ALL-KEYS-OR-NONE TRAP, which is why `intent_attributes` returns all four keys
    # unconditionally instead of merging a layer in when one is present.
    #
    # `upsert_all` builds ONE statement from the FIRST row's keys, so a recorder that omitted
    # `intent_layer` for the unannotated spec leading this payload would take the column off the
    # whole delivery — and the annotated example behind it would store a null layer with nothing
    # raised and a 202 returned. The failure is completely silent, which is why the ORDER here is
    # load bearing and stated: unannotated FIRST, annotated SECOND. Reversing the fixture makes this
    # example pass against the broken recorder.
    # @intent: { entity: "SpecObservation", action: "keep layers under mixed keys", behavior: "upsert_all takes its column list from the first row, so an unannotated spec leading the payload still cannot strip the layer off later rows", layer: "request" }
    it "keeps an annotated example's layer when the first spec of the delivery is unannotated" do
      ingest(ingest_payload(specs: [unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 1),
                                    annotated_spec(file_path: "spec/requests/checkout_spec.rb",
                                                   line_number: 2, layer: "request")]))

      expect(response).to have_http_status(:accepted)

      annotated = TestRun.last.spec_observations.find_by(status: "annotated")
      expect(annotated.intent_layer).to eq("request")
    end

    # THE ASSERTION THAT SEPARATES A DECLARATION FROM A GUESS, and the point of storing the field at
    # all. This example DECLARES `layer: "request"` while living under `spec/models/` — a directory
    # that implies `unit` — so a recorder that inferred the layer from the path, or that let an
    # inference override the annotation, stores `"unit"` here and is red.
    #
    # Nothing derived may ever be written to this column (see the migration): a column mixing an
    # author's claim with a directory guess could answer neither "what did this test say it was?"
    # nor "where does this file sit?".
    # @intent: { entity: "SpecObservation", action: "honour the declared layer", behavior: "a spec declaring request while living under spec/models keeps request, so path-derived inference never overrides the annotation", layer: "request" }
    it "stores the DECLARED layer even when the file's directory implies a different one" do
      ingest(ingest_payload(specs: [annotated_spec(file_path: "spec/models/invoice_spec.rb",
                                                   line_number: 4, layer: "request")]))

      observation = TestRun.last.spec_observations.sole

      expect(observation.file_path).to start_with("spec/models/")
      expect(observation.intent_layer).to eq("request")
    end

    # @intent: { entity: "TestRun", action: "scope by credential", behavior: "the run is attributed to the repository that owns the presented API key and no other repository gains a run", layer: "request" }
    it "scopes the run to the repository behind the key" do
      other = create_repository(user: create_user(github_uid: "2002", github_handle: "hubot"),
                                github_full_name: "acme/ledger")
      ingest(body, key: other.api_keys.create!)

      expect(TestRun.last.repository).to eq(other)
      expect(repository.test_runs).to be_empty
    end

    # @intent: { entity: "TestRun", action: "allow omitted metadata", behavior: "when branch and duration are absent from the envelope their columns stay null rather than being defaulted", layer: "request" }
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

    # @intent: { entity: "TestRun", action: "accumulate shards into one run", behavior: "four POSTs sharing a ci_run_id land as a single row whose denominator and annotated numerator cover the whole suite", layer: "request" }
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
    # @intent: { entity: "TestRun", action: "take the slowest shard duration", behavior: "duration is a maximum over the shards because they ran concurrently, never a sum of their wall clocks", layer: "request" }
    it "reports the slowest shard's duration, not the sum of all four" do
      [61.0, 58.5, 74.25, 60.0].each_with_index do |duration, index|
        ingest(shard_payload(**shards[index], duration_seconds: duration))
      end

      expect(TestRun.last.duration_seconds).to eq(74.25)
    end

    # @intent: { entity: "TestRun", action: "widen the duration", behavior: "a later shard reporting a longer duration raises the run maximum even when the slowest shard arrived first", layer: "request" }
    it "widens the duration even when the slowest shard arrives first" do
      ingest(shard_payload(total: 2, annotated: 1, duration_seconds: 90.0))
      ingest(shard_payload(total: 2, annotated: 1, duration_seconds: 10.0))

      expect(TestRun.last.duration_seconds).to eq(90.0)
    end

    # @intent: { entity: "TestRun", action: "keep a lone duration", behavior: "when only the first shard reports a duration the run keeps that measurement instead of losing it to later nils", layer: "request" }
    it "takes the first shard's duration when a later shard reports none" do
      ingest(shard_payload(total: 2, annotated: 1, duration_seconds: 12.5))
      ingest(shard_payload(total: 2, annotated: 1))

      expect(TestRun.last.duration_seconds).to eq(12.5)
    end

    # `update_counters` writes past the loaded instance, so an un-reloaded record would answer with
    # the previous shard's numbers — the client would read a total that never existed.
    # @intent: { entity: "POST /api/v1/ingest", action: "answer with running totals", behavior: "each shard response reflects the run accumulated so far, including counts written by update_counters past the loaded instance", layer: "request" }
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

    # @intent: { entity: "TestRun", action: "fix run identity", behavior: "commit and branch stay as the first shard named them, so late arrivals cannot re-key the accumulated run", layer: "request" }
    it "keeps the run under the commit and branch the first shard named" do
      shards.each { |shard| ingest(shard_payload(**shard)) }

      expect(TestRun.last).to have_attributes(commit_sha: "deadbee", branch: "main", ci_run_id: "gha-42")
    end

    # `commit_sha` cannot be the key: a re-run of the same commit is genuinely a second run, and
    # merging the two would hide a suite that changed between them.
    # @intent: { entity: "TestRun", action: "separate runs by run id", behavior: "two builds of the same commit with different ci_run_ids are two runs, never merged into one row", layer: "request" }
    it "keeps two CI runs of the same commit apart when their run ids differ" do
      expect do
        ingest(shard_payload(total: 4, annotated: 2, ci_run_id: "gha-42"))
        ingest(shard_payload(total: 4, annotated: 2, ci_run_id: "gha-43"))
      end.to change(TestRun, :count).by(2)

      expect(TestRun.pluck(:total_specs_count)).to all(eq(4))
    end

    # @intent: { entity: "TestRun", action: "scope accumulation by repository", behavior: "the ci_run_id key is scoped to the repository behind the credential, so the same run id in two repositories never collides", layer: "request" }
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

    # @intent: { entity: "TestRun", action: "land the first attempt", behavior: "delivering every named shard once produces a single run whose totals already span the whole suite", layer: "request" }
    it "still lands the first attempt as one TestRun over the whole suite" do
      expect { run_all_shards }.to change(TestRun, :count).by(1)

      expect(TestRun.sole).to have_attributes(total_specs_count: 20_000, annotated_specs_count: 5000)
    end

    # "Re-run all jobs". Every shard reports a second time under the same run id. Adding would give
    # a 40,000 denominator for a 20,000-example suite.
    # @intent: { entity: "TestRun", action: "stay idempotent on full redelivery", behavior: "every shard reporting a second time under the same run id leaves the denominator unchanged instead of doubling it", layer: "request" }
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
    # @intent: { entity: "TestRun", action: "stay truthful on partial re-run", behavior: "re-running only the failed shard keeps the run totals correct, the exact gesture a sharded suite exists to support", layer: "request" }
    it "reports the truth when only the failed shard is re-run" do
      run_all_shards

      ingest(shard_payload(**shards[2]))

      expect(TestRun.sole).to have_attributes(total_specs_count: 20_000, annotated_specs_count: 5000)
      expect(TestRun.sole.annotated_ratio).to eq(25.0)
    end

    # And the re-run is genuinely a *refresh*, not a no-op: a shard whose numbers changed between
    # attempts — someone pushed an annotation, a file moved between shards — replaces its own
    # slice rather than being ignored.
    # @intent: { entity: "TestRun", action: "refresh a re-run shard", behavior: "a shard whose numbers changed between attempts replaces its own slice rather than being ignored as a duplicate", layer: "request" }
    it "takes the re-run shard's new numbers in place of its old ones" do
      run_all_shards

      ingest(shard_payload(total: 5100, annotated: 4100, shard_id: "3"))

      # Shard 3's 3,600 annotations become 4,100; the other three shards are untouched.
      expect(TestRun.sole).to have_attributes(total_specs_count: 20_000, annotated_specs_count: 5500)
    end

    # @intent: { entity: "TestRunShard", action: "keep one row per shard", behavior: "repeat deliveries of a named shard update the same shard row instead of appending one row per POST", layer: "request" }
    it "keeps one row per shard rather than one per delivery" do
      run_all_shards
      run_all_shards

      expect(TestRun.sole.test_run_shards.count).to eq(4)
    end

    # `duration_seconds` is a MAX over the shards, and it is derived like the counts are — so when
    # the slowest shard is re-run and comes back faster, the run gets *faster*. An implementation
    # that only ever widened the maximum would be stuck at the old high-water mark forever.
    # @intent: { entity: "TestRun", action: "narrow the duration", behavior: "when the slowest shard re-runs faster the run maximum comes down, so it is a true max and not a high-water mark", layer: "request" }
    it "narrows the duration when the slowest shard is re-run and comes back faster" do
      shards.each_with_index { |shard, index| ingest(shard_payload(**shard, duration_seconds: [61.0, 58.5, 74.25, 60.0][index])) }
      expect(TestRun.sole.duration_seconds).to eq(74.25)

      ingest(shard_payload(**shards[2], duration_seconds: 59.0))

      expect(TestRun.sole.duration_seconds).to eq(61.0)
    end

    # A shard index is only unique *within* a run — every run has a shard "1". Scoping the key to
    # the run is what stops two builds' shard 1s from overwriting each other.
    # @intent: { entity: "TestRunShard", action: "scope shard names to runs", behavior: "a shard id is unique only within its run, so two builds sharing a shard name never overwrite each other", layer: "request" }
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
    # @intent: { entity: "TestRun", action: "count unnamed shard redeliveries", behavior: "slices the client did not name are counted on arrival, so a redelivery of an unnamed slice is honestly counted twice", layer: "request" }
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
    # @intent: { entity: "TestRun", action: "give unnamed runs their own rows", behavior: "without a ci_run_id each delivery is its own run, so local laptop runs never collapse into one growing row", layer: "request" }
    it "gives each unidentified run its own TestRun, exactly as before" do
      expect do
        ingest(ingest_payload(commit_sha: "deadbee", specs: [annotated_spec]))
        ingest(ingest_payload(commit_sha: "deadbee", specs: [annotated_spec]))
      end.to change(TestRun, :count).by(2)

      expect(TestRun.pluck(:ci_run_id)).to eq([nil, nil])
      expect(TestRun.pluck(:total_specs_count)).to eq([1, 1])
    end

    # @intent: { entity: "TestRun", action: "blank means absent", behavior: "a whitespace ci_run_id is treated as no run id at all and cannot act as an accumulation key", layer: "request" }
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

    # @intent: { entity: "Ingest::RunRecorder", action: "recover from a lost race", behavior: "when the run row appears between lookup and insert the loser rescues the uniqueness error and folds its counts into the winner", layer: "request" }
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

    # @intent: { entity: "Ingest::RunRecorder", action: "cap collision retries", behavior: "an unresolvable unique violation is re-raised after a bounded number of attempts instead of retrying forever", layer: "request" }
    it "gives up rather than retrying forever when the collision never resolves" do
      # A row that is always absent on lookup and always present on insert — the pathological case
      # the attempt cap exists for. Retrying it forever would hang the request instead.
      allow(recorder).to receive(:find_run).and_return(nil)
      allow(recorder).to receive(:create_run).and_raise(ActiveRecord::RecordNotUnique, "duplicate key")

      expect { recorder.record }.to raise_error(ActiveRecord::RecordNotUnique)
      expect(recorder).to have_received(:create_run).exactly(Ingest::RunRecorder::MAX_ATTEMPTS).times
    end
  end

  # The other half of the same shape, sixty lines further down `Ingest::RunRecorder` and read here
  # next to its twin on purpose: the run identity above has a partial unique index and a rescue,
  # and so does the *shard* identity — `#upsert_shard` reads a shard row before it writes one, and
  # a retried job overlapping the original is two deliveries of the same shard reaching that write
  # together. The loser meets `index_test_run_shards_on_test_run_id_and_shard_id`.
  #
  # Driven through the recorder for the reason the group above gives, and faked the way
  # `spec/support/uniqueness_race.rb` describes: what is stubbed is only the *timing* of the
  # lookup. `find_or_initialize_by` is allowed to run for real at a moment when the row genuinely
  # does not exist, the winner's delivery lands immediately afterwards, and the write, the index,
  # the rescue and the recompute are all the production path. Nothing fabricates the exception —
  # a stubbed `and_raise` would pass over whether this write can survive a real conflict at all
  # (see `#upsert_shard`'s savepoint), which is the question the example exists to answer. The cap
  # example above uses `and_raise` deliberately, for a collision that by construction never
  # resolves; this one must not.
  describe "two deliveries of the same shard racing each other" do
    let(:attributes) do
      { ci_run_id: "gha-42", commit_sha: "deadbee", duration_seconds: 30.0,
        total_specs_count: 3, annotated_specs_count: 1 }
    end
    let(:recorder) { Ingest::RunRecorder.new(repository, attributes, shard_id: "shard-1") }

    # The winner reports the same shard through the recorder rather than by hand, so the row the
    # loser collides with is one production actually writes, and so the run it belongs to has the
    # slices a run with a `ci_run_id` is required to have.
    def land_the_winner
      Ingest::RunRecorder.record(repository,
                                 attributes.merge(total_specs_count: 5, annotated_specs_count: 2,
                                                  duration_seconds: 40.0),
                                 shard_id: "shard-1")
    end

    # Wrapped rather than replaced, and re-applied on every call, because `run.lock!` reloads the
    # run and drops its association cache — the proxy the write goes through is not the one that
    # existed when the run was found.
    def fake_the_lookup_timing(run, &landing)
      allow(run).to receive(:test_run_shards).and_wrap_original do |original_shards|
        original_shards.call.tap do |shards|
          allow(shards).to receive(:find_or_initialize_by).and_wrap_original do |original, *args|
            original.call(*args).tap { landing.call }
          end
        end
      end
    end

    # @intent: { entity: "Ingest::RunRecorder", action: "survive a shard write race", behavior: "two deliveries of the same shard writing at once leave one shard row, last writer winning, with the run recomputed from it", layer: "request" }
    it "overwrites the winner's row rather than raising when both deliveries write at once" do
      winner = nil
      raced = false

      allow(recorder).to receive(:find_or_create_run).and_wrap_original do |original|
        original.call.tap do |run|
          fake_the_lookup_timing(run) do
            next if raced

            raced = true
            winner = land_the_winner
          end
        end
      end

      run = nil
      expect { run = recorder.record }.not_to raise_error

      # One row, not two: the index refused the loser's insert instead of letting it split this
      # slice's counts across a pair of rows the SUM would then double.
      expect(raced).to be(true)
      expect(TestRun.sole.id).to eq(winner.id)
      expect(TestRun.sole.test_run_shards.count).to eq(1)

      # Last writer wins, which is the declared semantic for a shard reporting twice. The loser
      # arrived second, so its 3/1/30.0 is what the surviving row holds and what the run's
      # recomputed totals report — not the winner's 5/2/40.0, and not the two of them added.
      expect(TestRun.sole.test_run_shards.sole)
        .to have_attributes(shard_id: "shard-1", total_specs_count: 3, annotated_specs_count: 1,
                            duration_seconds: 30.0)
      expect(run).to have_attributes(total_specs_count: 3, annotated_specs_count: 1,
                                     duration_seconds: 30.0)
    end
  end

  # Missing annotations are never an ingestion failure — only malformed ones are. Adoption of the
  # protocol has to be opt-in and gradual, so a suite that annotates nothing still reports.
  describe "a run with no annotations" do
    # @intent: { entity: "POST /api/v1/ingest", action: "accept an unannotated suite", behavior: "a run of only unannotated specs is accepted with a zero ratio, because adoption of the protocol is gradual by design", layer: "request" }
    it "accepts a run of entirely unannotated specs" do
      ingest(ingest_payload(specs: [unannotated_spec(line_number: 1),
                                    unannotated_spec(line_number: 2)]))

      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body["annotated_ratio"]).to eq(0.0)
      expect(TestRun.last.total_specs_count).to eq(2)
      expect(TestRun.last.annotated_specs_count).to eq(0)
    end

    # `null`, not `0.0`: nothing was counted, so there was no share to measure. The counts stay in
    # the body so a client can still see the suite was empty. `GET /api/v1/repository` answers the
    # same run the same way — pinned directly in repository_latest_run_spec.rb, since two request
    # specs that cannot see each other is what let these two endpoints disagree in the first place.
    # @intent: { entity: "POST /api/v1/ingest", action: "accept an empty spec list", behavior: "an empty specs array still answers 202 with zero counts and a null ratio, since nothing was measured", layer: "request" }
    it "accepts a run that reported no specs at all" do
      ingest(ingest_payload(specs: []))

      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body).to include("total_specs" => 0, "annotated_specs" => 0,
                                              "annotated_ratio" => nil)
    end

    # The discriminator between "this REQUEST carried no specs" and "the RUN has no specs". Only
    # the second is what `null` reports, because `RunRecorder#recompute_totals` re-derives the
    # run's counts as a SUM over every shard rather than from the payload in hand — so an empty
    # shard arriving on a run that already has examples gets a NUMBER, and the example above gets
    # its `null` from the run being empty, not from its own `specs: []`.
    #
    # Worth pinning rather than inferring: the public integration guide documents when a client
    # must parse this field as nullable, and stating the rule per-request instead of per-run sends
    # a sharded reporter looking for a `null` it will never see.
    # @intent: { entity: "POST /api/v1/ingest", action: "answer numbers for an empty shard", behavior: "an empty shard of a run that already has specs gets a numeric ratio because the run totals are recomputed from all shards", layer: "request" }
    it "reports a number, not null, for an empty shard of a run that has specs" do
      ingest(ingest_payload(commit_sha: "deadbee", ci_run_id: "gha-42", shard_id: "1",
                            specs: [unannotated_spec(line_number: 1), unannotated_spec(line_number: 2)]))

      ingest(ingest_payload(commit_sha: "deadbee", ci_run_id: "gha-42", shard_id: "2", specs: []))

      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body).to include("total_specs" => 2, "annotated_specs" => 0,
                                              "annotated_ratio" => 0.0)
    end

    # The two endpoints serving this field lived in two request specs that cannot see each other,
    # and they answered the same run `0.0` and `null` respectively for as long as that was true.
    # A single `TestRun#annotated_fraction` is what makes them agree; this reads BOTH bodies in one
    # example so the agreement is asserted rather than inferred from two files independently.
    # @intent: { entity: "annotated_ratio", action: "agree across endpoints", behavior: "the ingest response and the repository show read the same run with the same null ratio, so the two surfaces cannot drift", layer: "request" }
    it "agrees with GET /api/v1/repository about the same run" do
      ingest(ingest_payload(specs: []))
      ingested = response.parsed_body

      get "/api/v1/repository", headers: { "Authorization" => "Bearer #{api_key.raw_token}" }
      latest_run = response.parsed_body["latest_run"]

      expect(latest_run["annotated_ratio"]).to eq(ingested["annotated_ratio"])
      expect(latest_run["annotated_ratio"]).to be_nil
    end
  end

  # `name` is RSpec's `full_description`, sent by the shipped formatter for every example. In a
  # suite that annotates nothing it is the only thing describing a test, so it is the field the
  # cold-start case rests on — and the envelope used to drop it at the door.
  describe "the text that represents a test" do
    # @intent: { entity: "SpecObservation", action: "accept a named spec", behavior: "an unannotated spec carrying a name is accepted and the name is stored verbatim as the example representation", layer: "request" }
    it "accepts an unannotated spec carrying a name" do
      ingest(ingest_payload(specs: [unannotated_spec(name: "User is valid with a handle")]))

      expect(response).to have_http_status(:accepted)
      expect(TestRun.sole.spec_observations.sole.name).to eq("User is valid with a handle")
    end

    # A test with neither can be counted and nothing else: nothing downstream could ever say a
    # word about it, and there is no field on which to record that condition. Rejected and named,
    # rather than accepted and silently unrepresentable. No conforming client is affected — the
    # formatter has always sent `name`.
    # @intent: { entity: "POST /api/v1/ingest", action: "reject an unrepresentable spec", behavior: "a spec with neither intent nor name is refused with a 400 that names the offending file and line, and nothing is persisted", layer: "request" }
    it "rejects a spec with neither an intent nor a name, naming the offending spec" do
      ingest(ingest_payload(specs: [unannotated_spec(file_path: "spec/models/user_spec.rb",
                                                     line_number: 40).except(:name)]))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("spec/models/user_spec.rb:40", "name is required")
      expect(TestRun.count).to eq(0)
    end

    # The annotation is a different field from the name, and this is what keeps the rejection above
    # from quietly becoming "annotations are mandatory".
    # @intent: { entity: "POST /api/v1/ingest", action: "accept an intent in lieu of a name", behavior: "an annotated spec without a name passes, since its intent triple already represents it downstream", layer: "request" }
    it "accepts an annotated spec that carries no name, because its intent already represents it" do
      ingest(ingest_payload(specs: [annotated_spec.except(:name)]))

      expect(response).to have_http_status(:accepted)
    end

    # @intent: { entity: "POST /api/v1/ingest", action: "reject a blank name", behavior: "a name that is present but not a non-empty string is refused, and the run is not written", layer: "request" }
    it "rejects a name that is present but not a non-empty string" do
      ingest(ingest_payload(specs: [unannotated_spec(name: "   ")]))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("name must be a non-empty string")
      expect(TestRun.count).to eq(0)
    end

    # @intent: { entity: "POST /api/v1/ingest", action: "reject a mistyped name", behavior: "a name of the wrong type is refused even when the spec also carries an intent that would outrank it", layer: "request" }
    it "rejects a name of the wrong type even when an intent would outrank it" do
      ingest(ingest_payload(specs: [annotated_spec(name: 42)]))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("name must be a non-empty string")
    end

    # The class's stated contract is *collect every failure, never raise on the first* — a client
    # fixing a malformed suite has to see the whole list, not one entry per round trip.
    # @intent: { entity: "POST /api/v1/ingest", action: "collect every spec error", behavior: "each offending spec contributes one entry to details alongside envelope errors, so a client fixes the whole suite in one round trip", layer: "request" }
    it "reports one error per offending spec, collected alongside the envelope's other errors" do
      ingest(ingest_payload(specs: [unannotated_spec(line_number: 1, name: ""),
                                    unannotated_spec(line_number: 2, name: 42),
                                    unannotated_spec(line_number: 3).except(:name),
                                    annotated_spec(line_number: 4, behavior: "no")]))

      details = response.parsed_body["details"]

      expect(response).to have_http_status(:bad_request)
      expect(details.size).to eq(4)
      expect(details.grep(/name/).size).to eq(3)
    end

    # One error, not two: a blank name on a spec with no intent breaks one rule about one field.
    # @intent: { entity: "POST /api/v1/ingest", action: "report one error per rule broken", behavior: "a spec that is both nameless and unrepresentable yields a single detail entry, not one per violated rule", layer: "request" }
    it "does not double-report a spec that is both nameless and unrepresentable" do
      ingest(ingest_payload(specs: [unannotated_spec(name: "")]))

      expect(response.parsed_body["details"].size).to eq(1)
    end
  end

  # The seam is handed the *whole* population, not the annotated slice: an unannotated example is
  # represented by its name (Ingest::SpecSignal), so narrowing here would decide that a suite
  # mid-adoption — or one at zero annotations, which is every suite on day one — has nothing to
  # embed.
  describe "what the embedding seam is handed" do
    let(:specs) do
      [annotated_spec(file_path: "spec/models/invoice_spec.rb", line_number: 1),
       annotated_spec(file_path: "spec/models/order_spec.rb", line_number: 2),
       unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 3)]
    end

    # @intent: { entity: "POST /api/v1/ingest", action: "hand the whole population to the seam", behavior: "the embedding seam receives every spec, annotated or not, so mid-adoption suites still have something to embed", layer: "request" }
    it "receives every spec in the run, annotated or not" do
      handed = nil
      allow_any_instance_of(Api::V1::IngestsController)
        .to receive(:enqueue_embeddings).and_wrap_original do |original, run, given|
          handed = given
          original.call(run, given)
        end

      ingest(ingest_payload(specs: specs))

      expect(handed.size).to eq(3)
      expect(handed.map { |spec| spec["file_path"] })
        .to eq(%w[spec/models/invoice_spec.rb spec/models/order_spec.rb spec/models/user_spec.rb])
    end

    # Widening what the seam sees must not weaken what it claims. The rule is the same one it was
    # written under: `"queued"` only when a job was genuinely enqueued.
    # @intent: { entity: "POST /api/v1/ingest", action: "queue for a mixed population", behavior: "the queued status holds for a mixed population, since the seam was widened without weakening what it claims", layer: "request" }
    it "reports queued for a mixed population, annotated and not" do
      ingest(ingest_payload(specs: specs))

      expect(response.parsed_body["embedding_status"]).to eq("queued")
    end

    # The other half of that rule, and the one that keeps it from being vacuous: a payload with
    # nothing to represent schedules nothing and says so.
    # @intent: { entity: "POST /api/v1/ingest", action: "report pending for nothing to embed", behavior: "a payload with no representable spec schedules no job and answers pending rather than queued", layer: "request" }
    it "reports pending, and enqueues nothing, when there is no spec to embed" do
      expect { ingest(ingest_payload(specs: [])) }
        .not_to have_enqueued_job(Ingest::IdentityResolutionJob)

      expect(response.parsed_body["embedding_status"]).to eq("pending")
    end

    # @intent: { entity: "POST /api/v1/ingest", action: "count the population and the slice", behavior: "the response separates the whole-spec total from the annotated slice so both adoption figures are visible", layer: "request" }
    it "counts the whole population and the annotated slice separately" do
      ingest(ingest_payload(specs: specs))

      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body).to include("total_specs" => 3, "annotated_specs" => 2)
    end
  end

  describe "an intent that fails the OpenTestIntent schema" do
    # @intent: { entity: "POST /api/v1/ingest", action: "reject a short behavior", behavior: "a behavior under the schema minimum is refused with a 400 naming the file and line, and no run is written", layer: "request" }
    it "rejects a behavior below the schema's minimum length, naming the offending spec" do
      ingest(ingest_payload(specs: [annotated_spec(line_number: 12),
                                    annotated_spec(file_path: "spec/models/order_spec.rb",
                                                   line_number: 40, behavior: "works")]))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("bad_request")
      expect(response.parsed_body["message"]).to include("spec/models/order_spec.rb:40", "/behavior")
      expect(TestRun.count).to eq(0)
    end

    # @intent: { entity: "POST /api/v1/ingest", action: "reject an unknown intent property", behavior: "an intent carrying a property outside the OpenTestIntent schema is refused with the path named", layer: "request" }
    it "rejects a property the schema does not allow" do
      ingest(ingest_payload(specs: [annotated_spec(severity: "high")]))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("/severity")
    end

    # @intent: { entity: "POST /api/v1/ingest", action: "reject a layer outside the enum", behavior: "an intent layer not in the four-token enum is refused with the field path in the message", layer: "request" }
    it "rejects a layer outside the enum" do
      ingest(ingest_payload(specs: [annotated_spec(layer: "acceptance")]))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("/layer")
    end

    # @intent: { entity: "POST /api/v1/ingest", action: "reject a missing intent", behavior: "a spec marked annotated with no intent object is refused, since the status claims a triple that is not there", layer: "request" }
    it "rejects an annotated spec with no intent at all" do
      ingest(ingest_payload(specs: [annotated_spec.merge(intent: nil)]))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("intent is required")
    end

    # @intent: { entity: "POST /api/v1/ingest", action: "list every schema offender", behavior: "multiple failing specs each contribute to details so the client sees all of them, not just the first", layer: "request" }
    it "reports every offending spec, not just the first" do
      ingest(ingest_payload(specs: [annotated_spec(line_number: 1, behavior: "no"),
                                    annotated_spec(line_number: 2, layer: "acceptance")]))

      expect(response.parsed_body["details"].size).to eq(2)
    end
  end

  describe "a malformed envelope" do
    # @intent: { entity: "POST /api/v1/ingest", action: "reject a missing commit", behavior: "a body without commit_sha is refused with a 400 and no run row is created", layer: "request" }
    it "rejects a missing commit_sha" do
      ingest({ specs: [] })

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("commit_sha")
      expect(TestRun.count).to eq(0)
    end

    # @intent: { entity: "POST /api/v1/ingest", action: "reject a blank commit", behavior: "a whitespace-only commit_sha fails validation the same way a missing one does", layer: "request" }
    it "rejects a blank commit_sha" do
      ingest(ingest_payload(commit_sha: "   "))

      expect(response).to have_http_status(:bad_request)
    end

    # @intent: { entity: "POST /api/v1/ingest", action: "reject a missing specs array", behavior: "a body without specs is refused with the field named in the message", layer: "request" }
    it "rejects a missing specs array" do
      ingest({ commit_sha: "abc123" })

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("specs")
    end

    # @intent: { entity: "POST /api/v1/ingest", action: "reject a non-array specs", behavior: "specs given as an object instead of an array is refused as a bad envelope", layer: "request" }
    it "rejects specs that is not an array" do
      ingest({ commit_sha: "abc123", specs: { "0" => annotated_spec } })

      expect(response).to have_http_status(:bad_request)
    end

    # Distinct from both neighbours: the body *is* an object and `specs` *is* an array — it is one
    # entry inside it that is not an object, which is what a client whose serializer emits
    # positional tuples instead of objects puts on the wire. The label assertion is the point of
    # the example: an entry this malformed has no `file_path`/`line_number` to be named by, so the
    # diagnostic falls back to the bare index, and that is the only handle a client gets on it.
    #
    # The entry's *type* is load-bearing, and two candidates do not work here:
    #
    #   - `nil` never reaches `Payload` at all. The controller reads `request.request_parameters`,
    #     and Rails' `deep_munge` compacts nils out of arrays first — so a nil entry is silently
    #     dropped and the run is *accepted*, which is a property of the parsing stack rather than
    #     of this validator and is not what this example is about.
    #   - a bare string reaches it but cannot tell `label`'s two arms apart: `String#[]("file_path")`
    #     answers nil rather than raising, so the example would still pass against a `label` whose
    #     `spec.is_a?(Hash)` guard had been deleted.
    #
    # An array entry survives munging *and* makes the guard observable.
    # @intent: { entity: "POST /api/v1/ingest", action: "reject a non-object entry", behavior: "a specs member that is not a JSON object is refused and diagnosed by its bare index, since it has no coordinates to name", layer: "request" }
    it "rejects a specs entry that is not a JSON object" do
      ingest(ingest_payload(specs: [annotated_spec, ["spec/models/invoice_spec.rb", 12]]))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("specs[1]")
      expect(response.parsed_body["message"]).to include("must be a JSON object")
      expect(TestRun.count).to eq(0)
    end

    # `label` is `[file_path, line_number].compact.join(":")`, so it has FOUR forms, not the two a
    # reader would guess from the neighbours above: both coordinates, file alone, line alone, and
    # neither. The two partial forms are the ones worth pinning, because they are what a reporter
    # under development actually produces — omitting `line_number` is the first-run mistake — and
    # because the line-only form renders a BARE INTEGER where a reader scanning for a path expects
    # one. The public integration guide documents these forms; an example each is what stops that
    # documentation drifting from `Payload#label`.
    # @intent: { entity: "POST /api/v1/ingest", action: "label by available coordinates", behavior: "spec diagnostics fall back to whichever of file path or line number is present when only one coordinate arrived", layer: "request" }
    it "names a spec by whichever coordinate it has when it has only one" do
      ingest(ingest_payload(specs: [annotated_spec(file_path: "spec/c_spec.rb").except(:line_number)]))

      expect(response.parsed_body["details"])
        .to contain_exactly("specs[0] spec/c_spec.rb: line_number is required and must be a positive integer")

      ingest(ingest_payload(specs: [annotated_spec(line_number: 9).except(:file_path)]))

      expect(response.parsed_body["details"])
        .to contain_exactly("specs[0] 9: file_path is required and must be a non-empty string")
    end

    # @intent: { entity: "POST /api/v1/ingest", action: "reject a missing file path", behavior: "a spec without file_path is refused with the field named", layer: "request" }
    it "rejects a spec with no file_path" do
      ingest(ingest_payload(specs: [annotated_spec.except(:file_path)]))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("file_path")
    end

    # @intent: { entity: "POST /api/v1/ingest", action: "reject a non-positive line number", behavior: "a line_number of zero or less is refused with the field named", layer: "request" }
    it "rejects a non-positive line_number" do
      ingest(ingest_payload(specs: [annotated_spec(line_number: 0)]))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("line_number")
    end

    # @intent: { entity: "POST /api/v1/ingest", action: "reject an unknown status", behavior: "a spec status outside the allowed vocabulary is refused with the field named", layer: "request" }
    it "rejects an unknown status" do
      ingest(ingest_payload(specs: [annotated_spec.merge(status: "skipped")]))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("status")
    end

    # Dropping it silently would lose an annotation whose author believed it had shipped.
    # @intent: { entity: "POST /api/v1/ingest", action: "reject a contradictory intent", behavior: "an unannotated spec that nevertheless carries an intent is refused rather than silently dropping the annotation", layer: "request" }
    it "rejects an unannotated spec that nevertheless carries an intent" do
      ingest(ingest_payload(specs: [unannotated_spec.merge(intent: annotated_spec[:intent])]))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("must be null")
    end

    # Per-example `duration`, the envelope's `duration_seconds` one grain down. It reaches a
    # `t.float` column through `upsert_all`, whose cast is a bare `to_f` — so before this validator
    # a Hash raised `NoMethodError` inside `Ingest::RunRecorder`'s transaction (a 500 from an
    # endpoint whose whole contract is a collected 400), and `"abc"`/`true`/`"-3"` became `0.0`,
    # `1.0` and `-3.0`: not nil, therefore `timed`, therefore counted and summed and ranked as
    # genuine measurements. `outcome` is deliberately left unvalidated beside it because it is
    # echoed verbatim; `duration` is arithmetic.
    #
    # Not reachable from the shipped RSpec formatter, which always sends a Float. The population is
    # the one the envelope validators already exist for: third-party and non-Ruby producers.
    describe "a spec's own duration" do
      # The branch that used to 500. Asserted as a *status* rather than as "no exception", because
      # `NoMethodError` escaping the transaction is exactly what produced the 500.
      # @intent: { entity: "POST /api/v1/ingest", action: "reject a Hash duration as 400", behavior: "a per-example duration arriving as a Hash is a collected validation failure, not a NoMethodError that 500s", layer: "request" }
      it "answers 400, not 500, for a Hash duration, and persists nothing" do
        ingest(ingest_payload(specs: [unannotated_spec(file_path: "spec/models/user_spec.rb",
                                                       line_number: 40,
                                                       duration: { seconds: 1, nanos: 5 })]))

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["message"]).to include("spec/models/user_spec.rb:40",
                                                          "duration must be a non-negative number")
        expect(TestRun.count).to eq(0)
        expect(SpecObservation.count).to eq(0)
      end

      # @intent: { entity: "POST /api/v1/ingest", action: "reject an Array duration", behavior: "a per-example duration arriving as an Array is refused with the standard numeric message", layer: "request" }
      it "rejects an Array duration" do
        ingest(ingest_payload(specs: [unannotated_spec(duration: [1.5])]))

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["message"]).to include("duration must be a non-negative number")
        expect(TestRun.count).to eq(0)
      end

      # `"1.5"` is the plausible one — a producer that stringified its numbers — and `to_f` would
      # have accepted it silently. `"abc"` and `true` are the ones that fabricate 0.0 and 1.0.
      # @intent: { entity: "POST /api/v1/ingest", action: "reject a String duration", behavior: "a stringified duration is refused even when it parses as a number, since to_f would have accepted it silently", layer: "request" }
      it "rejects a String duration even when it looks like a number" do
        ["1.5", "abc", "-3"].each do |value|
          ingest(ingest_payload(specs: [unannotated_spec(duration: value)]))

          expect(response).to have_http_status(:bad_request)
          expect(response.parsed_body["message"]).to include("duration must be a non-negative number")
        end

        expect(SpecObservation.count).to eq(0)
      end

      # @intent: { entity: "POST /api/v1/ingest", action: "reject a boolean duration", behavior: "a boolean duration is refused rather than being coerced to 1.0 and counted as a measurement", layer: "request" }
      it "rejects a boolean duration, which would otherwise be recorded as 1.0" do
        ingest(ingest_payload(specs: [unannotated_spec(duration: true)]))

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["message"]).to include("duration must be a non-negative number")
        expect(SpecObservation.count).to eq(0)
      end

      # The same rule the envelope applies at the run grain, applied at the grain the run is
      # composed of — a negative timing is not a measurement at either.
      # @intent: { entity: "POST /api/v1/ingest", action: "reject a negative duration", behavior: "the non-negative rule for run duration applies at the example grain too, so negative timings never become measurements", layer: "request" }
      it "rejects a negative duration, matching duration_seconds' rule one level up" do
        ingest(ingest_payload(specs: [unannotated_spec(duration: -0.5)]))

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["message"]).to include("duration must be a non-negative number")
        expect(SpecObservation.count).to eq(0)
      end

      # The refusal now runs through `payload.valid? == false`, so it takes the whole 400 path —
      # including the rejection row SPGD-563 writes there. Before this change the request 500'd and
      # left no record at all, so the refusal was invisible to the observability built for it.
      # @intent: { entity: "IngestRejection", action: "record a duration refusal", behavior: "a refused per-example duration leaves a rejection row with the collected details, keeping the refusal observable", layer: "request" }
      it "leaves an IngestRejection row behind, as every other refusal does" do
        expect { ingest(ingest_payload(specs: [unannotated_spec(duration: { seconds: 1 })])) }
          .to change(IngestRejection, :count).by(1)

        expect(IngestRejection.last.details).to eq(response.parsed_body["details"])
      end

      # "Collected rather than raised" has to hold for this field too, or a client with one bad
      # duration fixes it and discovers the next error on the following round trip.
      # @intent: { entity: "POST /api/v1/ingest", action: "collect duration errors with others", behavior: "one bad duration does not hide the other specs failures, all of which appear in the same details list", layer: "request" }
      it "does not suppress the other specs' errors" do
        ingest(ingest_payload(specs: [unannotated_spec(line_number: 1, duration: "abc"),
                                      unannotated_spec(line_number: 2, name: ""),
                                      unannotated_spec(line_number: 0)]))

        details = response.parsed_body["details"]

        expect(response).to have_http_status(:bad_request)
        expect(details.size).to eq(3)
        expect(details.grep(/duration/).size).to eq(1)
        expect(details.grep(/name/).size).to eq(1)
        expect(details.grep(/line_number/).size).to eq(1)
      end

      # The accepted shapes, unchanged from `main`: the formatter's Float, an Integer, a zero, and
      # the nil the client sends for an example that never ran.
      # @intent: { entity: "SpecObservation", action: "accept valid durations", behavior: "nil, zero, Integer and Float durations all pass through to the columns unchanged, including the null for an unrun example", layer: "request" }
      it "still accepts nil and any non-negative Integer or Float" do
        ingest(ingest_payload(specs: [unannotated_spec(file_path: "spec/a_spec.rb", line_number: 1, duration: 0.42),
                                      unannotated_spec(file_path: "spec/b_spec.rb", line_number: 2, duration: 0),
                                      unannotated_spec(file_path: "spec/c_spec.rb", line_number: 3, duration: 7),
                                      unannotated_spec(file_path: "spec/d_spec.rb", line_number: 4, duration: nil)]))

        expect(response).to have_http_status(:accepted)
        expect(TestRun.sole.spec_observations.pluck(:file_path, :duration_seconds)).to match_array(
          [["spec/a_spec.rb", 0.42], ["spec/b_spec.rb", 0.0], ["spec/c_spec.rb", 7.0], ["spec/d_spec.rb", nil]]
        )
      end
    end

    # @intent: { entity: "POST /api/v1/ingest", action: "reject a negative run duration", behavior: "a negative duration_seconds on the envelope is refused with the field named", layer: "request" }
    it "rejects a negative duration_seconds" do
      ingest(ingest_payload(duration_seconds: -1))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("duration_seconds")
    end

    # The same rule as `ci_run_id` and `shard_id` below, and the coercion costs more here, not
    # less: `branch` is the axis every windowed surface narrows on — `unstable_tests` is served
    # only for a branch-narrowed window, and the history and growth panels are all branch-scoped.
    # A branch arriving as a non-string would split one branch's window in two, and the drill-ins
    # read position *within* a window against a commit_sha serialized from that same fetch.
    # @intent: { entity: "POST /api/v1/ingest", action: "reject a mistyped branch", behavior: "branch must be a string because every windowed surface narrows on it, so other types are refused", layer: "request" }
    it "rejects a branch that is not a string" do
      ingest(ingest_payload(branch: 42))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("branch")
      expect(TestRun.count).to eq(0)
    end

    # The counterweight, as `ci_run_id` and `shard_id` each have below: absence is ordinary — an
    # unrecognised CI provider POSTs a null branch and the formatter's git fallback is built for
    # exactly that — so a validator that rejected absence would satisfy the example above while
    # breaking the shape the platform designed an affordance for.
    # @intent: { entity: "POST /api/v1/ingest", action: "allow an omitted branch", behavior: "an envelope without branch is ordinary and accepted, leaving the column null", layer: "request" }
    it "accepts a run that omits branch entirely" do
      ingest(ingest_payload)

      expect(response).to have_http_status(:accepted)
      expect(TestRun.last.branch).to be_nil
    end

    # A run id sent as a JSON number would key its shards on `12345` while a client that sent the
    # same build's id as a string keyed on `"12345"` — one run split over a type difference, which
    # is the exact failure the field exists to remove.
    # @intent: { entity: "POST /api/v1/ingest", action: "reject a mistyped run id", behavior: "a ci_run_id of the wrong type is refused so one build can never split over a type difference", layer: "request" }
    it "rejects a ci_run_id that is not a string" do
      ingest(ingest_payload(ci_run_id: 12_345))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("ci_run_id")
      expect(TestRun.count).to eq(0)
    end

    # Absence is the ordinary shape of a run nobody's CI provider named, and must never be a
    # rejection — the local path depends on it.
    # @intent: { entity: "POST /api/v1/ingest", action: "allow an omitted run id", behavior: "an envelope without ci_run_id is the local path and must be accepted with the column null", layer: "request" }
    it "accepts a run that omits ci_run_id entirely" do
      ingest(ingest_payload)

      expect(response).to have_http_status(:accepted)
      expect(TestRun.last.ci_run_id).to be_nil
    end

    # The same rule as `ci_run_id`, and the number case is *likelier* here: every runner that
    # publishes a shard index publishes `0`, `1`, `2`, so sending them unquoted is the natural
    # mistake. `0` and `"0"` keying different shards would let a shard fail to replace itself,
    # which is the one property these ids exist to provide.
    # @intent: { entity: "POST /api/v1/ingest", action: "reject a mistyped shard id", behavior: "a numeric shard_id is refused so 0 and the string form can never key different shards", layer: "request" }
    it "rejects a shard_id that is not a string" do
      ingest(ingest_payload(ci_run_id: "gha-42", shard_id: 0))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("shard_id")
      expect(TestRun.count).to eq(0)
    end

    # @intent: { entity: "POST /api/v1/ingest", action: "allow an omitted shard id", behavior: "an envelope without shard_id is accepted and the shard row stores a null id", layer: "request" }
    it "accepts a run that omits shard_id entirely" do
      ingest(ingest_payload(ci_run_id: "gha-42"))

      expect(response).to have_http_status(:accepted)
      expect(TestRun.last.test_run_shards.sole.shard_id).to be_nil
    end

    # One of the two exceptions to "`details` carries every failure found": `Payload#validate`
    # RETURNS on a non-object body rather than falling through to the six field validators, so this
    # response carries exactly ONE entry, and it names no field because there is no field to name
    # when the body itself is the wrong shape. (The other is an unparseable body, refused above
    # `Payload` entirely — see "rejects a body that is not JSON at all" below.)
    #
    # `contain_exactly` rather than `include` is the point of the example: it is what fails if the
    # early return is dropped and the field validators start piling on entries about a body that
    # was never readable.
    # @intent: { entity: "POST /api/v1/ingest", action: "reject a non-object body", behavior: "a JSON body that is not an object answers with exactly one field-less detail, not a pile of field errors", layer: "request" }
    it "rejects a JSON body that is not an object" do
      ingest([ingest_payload].to_json)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("JSON object")
      expect(response.parsed_body["details"]).to contain_exactly("the request body must be a JSON object")
    end

    # The second field-less refusal, and the one a client hits before `Payload` is ever reached — a
    # truncated upload, a half-flushed buffer. Like the non-object case it answers with exactly one
    # entry naming no field, which is the pair the integration guide documents as the exceptions to
    # `details` being a per-field list.
    # @intent: { entity: "POST /api/v1/ingest", action: "reject an unparseable body", behavior: "a body that is not JSON at all is refused in the API error shape with a single field-less detail, and nothing persists", layer: "request" }
    it "rejects a body that is not JSON at all, in the API's own error shape" do
      ingest("{ not json")

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("bad_request")
      expect(response.parsed_body["details"]).to contain_exactly("The request body could not be parsed as JSON.")
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

    # `key:` is forwarded rather than fixed, because who the credential resolves to is the whole
    # subject of the attribution examples below — the same corrupt bytes have to be postable with a
    # good key, no key, a bad one and a user key. `path:` is forwarded for the same reason one
    # spelling down: the router recognises the trailing-slash form as the same action, so the same
    # corrupt bytes have to be postable at both spellings.
    def ingest_raw_gzip(bytes, key: api_key, path: "/api/v1/ingest")
      ingest(bytes, key: key, headers: { "Content-Encoding" => "gzip" }, path: path)
    end

    # @intent: { entity: "POST /api/v1/ingest", action: "accept a gzipped body", behavior: "a Content-Encoding gzip envelope is inflated by the middleware and answered with 202 like the plain one", layer: "request" }
    it "accepts it with 202" do
      ingest_gzipped(body)

      expect(response).to have_http_status(:accepted)
    end

    # The whole acceptance criterion in one example: not "gzip works" but "gzip is
    # indistinguishable". Both bodies are posted in the same example and their answers compared to
    # each other rather than to a hand-copied literal, so the two can never drift apart silently.
    # @intent: { entity: "POST /api/v1/ingest", action: "answer identically for gzip", behavior: "the same body compressed and uncompressed return the same response document compared to each other, so they cannot drift", layer: "request" }
    it "answers exactly what the same body answers uncompressed" do
      ingest(body)
      identity = response.parsed_body

      ingest_gzipped(body)

      expect(response.parsed_body.except("test_run_id")).to eq(identity.except("test_run_id"))
      expect(identity).to include("total_specs" => 3, "annotated_specs" => 2, "annotated_ratio" => 0.667)
    end

    # @intent: { entity: "TestRun", action: "record identically for gzip", behavior: "the persisted run from a gzipped delivery matches the uncompressed one attribute for attribute", layer: "request" }
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
    # @intent: { entity: "POST /api/v1/ingest", action: "carry a multi-chunk body", behavior: "a body spanning many inflate chunks arrives whole, so a misread content length cannot truncate the JSON", layer: "request" }
    it "carries a body far larger than one inflate chunk without truncating it" do
      specs = Array.new(400) { |i| annotated_spec(file_path: "spec/models/m#{i}_spec.rb", line_number: i + 1) }
      large = ingest_payload(specs: specs)
      expect(large.to_json.bytesize).to be > GzipRequestBody::READ_CHUNK_BYTES

      ingest_gzipped(large)

      expect(response).to have_http_status(:accepted)
      expect(TestRun.sole.total_specs_count).to eq(400)
    end

    # @intent: { entity: "POST /api/v1/ingest", action: "let validation see gzipped bodies", behavior: "a gzipped body that inflates fine but fails payload validation is refused by the endpoint validator, not the middleware", layer: "request" }
    it "leaves the endpoint's own validation in charge of a gzipped body that is bad JSON-wise" do
      ingest_gzipped(ingest_payload(duration_seconds: -1))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("duration_seconds")
    end

    # The hazard the middleware's own comment declares deliberate, made legible at the level a
    # reader cares about it: `lib/middleware/gzip_request_body.rb:53-57` — "`Zlib.gzip(a) +
    # Zlib.gzip(b)` inflates to `a` alone and the request succeeds… if one ever appears, this is
    # the line to revisit". This example is that line appearing. It pins today's answer, it does
    # not endorse it; if it fails, that comment is what to revisit.
    #
    # The two members carry *different* spec counts so the recorded run says which one landed. A
    # status-only assertion would be vacuous here — 202 is also what a correct implementation that
    # read both members would answer — so the count is the whole claim: a client that concatenated
    # two gzip streams has half its run recorded as a complete run, and nothing anywhere says so.
    # `delivery_health` is structurally blind to it because the request *succeeded*: there is no
    # rejection row to find.
    # @intent: { entity: "POST /api/v1/ingest", action: "inflate only the first gzip member", behavior: "a concatenated gzip stream is read as its first member alone and still answers 202, a documented hazard pinned not endorsed", layer: "request" }
    it "records only the first member of a concatenated gzip body, and still answers 202" do
      first = ingest_payload(
        commit_sha: "0000000f1a",
        specs: Array.new(2) { |i| annotated_spec(file_path: "spec/models/first#{i}_spec.rb", line_number: i + 1) }
      )
      second = ingest_payload(
        commit_sha: "0000000f1b",
        specs: Array.new(5) { |i| annotated_spec(file_path: "spec/models/second#{i}_spec.rb", line_number: i + 1) }
      )

      ingest(Zlib.gzip(first.to_json) + Zlib.gzip(second.to_json),
             headers: { "Content-Encoding" => "gzip" })

      expect(response).to have_http_status(:accepted)
      expect(TestRun.sole.total_specs_count).to eq(2)
      expect(TestRun.sole.commit_sha).to eq("0000000f1a")
      expect(response.parsed_body["total_specs"]).to eq(2)
    end

    describe "when the body is not the gzip it claims to be" do
      # @intent: { entity: "GzipRequestBody", action: "refuse corrupt gzip as 400", behavior: "bytes that are not gzip at all get the API bad_request shape with the corrupt message, never a 500", layer: "request" }
      it "answers 400 in the API's own error shape, not a 500" do
        ingest_raw_gzip("this is not gzip at all")

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to include("error" => "bad_request",
                                                "message" => GzipRequestBody::CORRUPT_MESSAGE)
        expect(response.parsed_body["details"]).to eq([GzipRequestBody::CORRUPT_MESSAGE])
        expect(TestRun.count).to eq(0)
      end

      # @intent: { entity: "GzipRequestBody", action: "refuse an over-cap inflate", behavior: "a body inflating past the configured ceiling is refused with 400 and the too-large message", layer: "request" }
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
    # @intent: { entity: "GzipRequestBody", action: "distinguish gzip failure from JSON failure", behavior: "a corrupt gzip and a good gzip around broken JSON produce their two distinct messages, telling a working inflater from none at all", layer: "request" }
    it "tells a broken gzip apart from a broken JSON body inside a good gzip" do
      ingest_raw_gzip("this is not gzip at all")

      expect(response.parsed_body["message"]).to eq(GzipRequestBody::CORRUPT_MESSAGE)

      ingest_gzipped("{ not json")

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to eq(JsonParseErrorResponder::MESSAGE)
    end

    # The inflater sits above the auth filter, so it necessarily runs for an unauthenticated
    # request too. It must not turn a 401 into anything else.
    # @intent: { entity: "POST /api/v1/ingest", action: "keep 401 for a gzipped request", behavior: "the inflater runs above auth but must never turn an unauthenticated gzipped request into anything but 401", layer: "request" }
    it "still answers 401 for a gzipped body with no API key" do
      ingest_gzipped(body, key: nil)

      expect(response).to have_http_status(:unauthorized)
      expect(TestRun.count).to eq(0)
    end

    # The refusals decided ABOVE the controller, and the row each one now leaves behind.
    #
    # `Ingest::RejectionRecorder` is called from inside `IngestsController#create`, so the three
    # families that never reach it — a corrupt gzip, an over-cap inflate, and a body that will not
    # parse — used to store NOTHING. `RejectedIngests#refusing?` stayed false on the strength of an
    # absent row and the panel rendered "No rejected deliveries", which was a positive claim and a
    # false one. That is the design point rather than an edge: a gem gzipping against an
    # installation older than `GzipRequestBody` 400s here on every run.
    describe "the row a boundary refusal leaves behind" do
      # @intent: { entity: "IngestRejection", action: "record a corrupt-gzip refusal", behavior: "a corrupt gzip refused at the boundary leaves a rejection row attributed to the repository whose token it carried", layer: "request" }
      it "records the corrupt-gzip refusal against the repository whose token it carried" do
        expect { ingest_raw_gzip("this is not gzip at all") }
          .to change(IngestRejection, :count).by(1)

        rejection = IngestRejection.sole
        expect(rejection.repository).to eq(repository)
        expect(rejection.details).to eq([GzipRequestBody::CORRUPT_MESSAGE])
        expect(rejection.total_reasons_count).to eq(1)
      end

      # The spelling the router treats as identical and an exact string match did not.
      #
      # `routes.recognize_path` resolves `/api/v1/ingest`, `/api/v1/ingest/` AND `/api/v1/ingest//`
      # to the same `ingests#create`, and all three really dispatch. A gem that builds its URL by
      # joining a configured base to a path is exactly how a trailing slash arrives in production,
      # so a seam that recorded only the canonical spelling would have re-created this ticket's own
      # defect one grain over — a real delivery, really refused, storing nothing, with an empty
      # panel as the only symptom.
      #
      # The DOUBLED spelling is pinned deliberately alongside the single one: `chomp("/")` strips
      # only one trailing slash and passes the example above while still failing this one.
      ["/api/v1/ingest/", "/api/v1/ingest//"].each do |spelling|
        # @intent: { entity: "IngestRejection", action: "record at every routing spelling", behavior: "a corrupt gzip POSTed to a trailing-slash or double-slash spelling of the path still records, because the router resolves them to the same action", layer: "request" }
        it "records a corrupt gzip POSTed to #{spelling}, which routes to the same action" do
          expect { ingest_raw_gzip("this is not gzip at all", path: spelling) }
            .to change(IngestRejection, :count).by(1)

          rejection = IngestRejection.sole
          expect(rejection.repository).to eq(repository)
          expect(rejection.details).to eq([GzipRequestBody::CORRUPT_MESSAGE])
        end
      end

      # The other half of the biconditional, and the reason the trailing-slash fix is a STRIP
      # followed by equality rather than a `start_with?`. `/api/v1/ingest/extra` is not this
      # endpoint — the router 404s it — so no row may be attributed to it. Without this, widening
      # the gate to a prefix match would pass every example above and quietly start billing
      # refusals to a repository for requests that never reached the ingest action.
      # @intent: { entity: "IngestRejection", action: "ignore a merely similar path", behavior: "a path that only starts with the ingest path is not this endpoint and leaves no row attributed to it", layer: "request" }
      it "records nothing for a path that merely starts with the ingest path" do
        expect { ingest_raw_gzip("this is not gzip at all", path: "/api/v1/ingest/extra") }
          .not_to change(IngestRejection, :count)
      end

      # @intent: { entity: "IngestRejection", action: "record an over-cap refusal", behavior: "an inflate past the cap is recorded as its own reason so the panel can show it distinctly", layer: "request" }
      it "records an over-cap inflate as its own reason" do
        stub_const("GzipRequestBody::MAX_INFLATED_BYTES", 1024)

        expect { ingest_raw_gzip(Zlib.gzip("a" * (4 * 1024 * 1024))) }
          .to change(IngestRejection, :count).by(1)

        expect(IngestRejection.sole.details).to eq([GzipRequestBody::TOO_LARGE_MESSAGE])
      end

      # Valid gzip wrapping invalid JSON: inflates cleanly, then dies at the parser. A different
      # middleware answers this one, so it is a genuinely separate limb rather than the same code
      # reached twice.
      # @intent: { entity: "IngestRejection", action: "record an unparseable gzipped body", behavior: "valid gzip wrapping invalid JSON leaves a rejection row carrying the parse-error message", layer: "request" }
      it "records an unparseable body as its own reason" do
        expect { ingest_gzipped("{ not json") }
          .to change(IngestRejection, :count).by(1)

        expect(IngestRejection.sole.details).to eq([JsonParseErrorResponder::MESSAGE])
      end

      # The parse-error limb is not gzip-specific and must record on a plain identity-encoded body
      # too — which is the form every client that never compresses sends.
      # @intent: { entity: "IngestRejection", action: "record an unparseable plain body", behavior: "the parse-error limb also records for an identity-encoded body, the form every non-compressing client sends", layer: "request" }
      it "records an unparseable body that was never gzipped at all" do
        expect { ingest("{ not json") }.to change(IngestRejection, :count).by(1)

        expect(IngestRejection.sole.details).to eq([JsonParseErrorResponder::MESSAGE])
      end

      # The column the table was built to make legible: `CreateIngestRejections` names the design
      # failure as a VERSION FLOOR, and without the gem's version on the row "every delivery is
      # refused" and "every delivery from the OLD GEM is refused" are the same picture. This is the
      # path that most needs it, since a version floor 400s here rather than at the controller.
      # @intent: { entity: "IngestRejection", action: "store the user agent", behavior: "the sending gem version from the User-Agent is kept on the rejection row so a version floor is legible", layer: "request" }
      it "stores the sending gem's user agent, which is what makes a version floor legible" do
        ingest("this is not gzip at all",
               headers: { "Content-Encoding" => "gzip", "User-Agent" => "specguard-rspec/0.1.0" })

        expect(IngestRejection.sole.user_agent).to eq("specguard-rspec/0.1.0")
      end

      # The attribution rule, which this ticket fixes the ORDERING of without widening. A row is
      # owned by a repository or it is not written — `repository_id` stays `null: false` and a
      # nullable one would turn a per-repository panel into a global error log.
      #
      # Table-driven so the three ways to fail authentication are asserted on the same terms.
      {
        "no token at all" => -> { nil },
        "a well-formed token that resolves nothing" => -> { instance_double(ApiKey, raw_token: "sgk_nope") },
        "a valid user key for the other table" => -> { create_user_api_key }
      }.each do |description, build_key|
        # @intent: { entity: "IngestRejection", action: "write rows only for resolved credentials", behavior: "no token, an unresolvable token and a user-table token all leave no row, because attribution requires an ingest repository", layer: "request" }
        it "writes no row for #{description}" do
          expect { ingest_raw_gzip("this is not gzip at all", key: instance_exec(&build_key)) }
            .not_to change(IngestRejection, :count)

          expect(response).to have_http_status(:bad_request)
        end
      end

      # The prefix gate, pinned by the claim it actually makes.
      #
      # ⚠️ The row-count example above does NOT cover this, and believing it did would be the whole
      # mistake: a `sgu_` token writes no row whether or not the gate exists, because its digest is
      # not in `api_keys` and the lookup returns nil on its own. Deleting the gate leaves that
      # example green — measured, not assumed. So the gate cannot be pinned by its OUTCOME, only by
      # its MECHANISM, which is what `Api::BaseController` states it as: "The prefix decides WHICH
      # table before any of them is read — and, on a mismatch, that no table is read at all."
      # @intent: { entity: "ApiKey", action: "gate by token prefix", behavior: "a token belonging to the other credential table selects no api_keys lookup at all, the prefix deciding which table is read", layer: "request" }
      it "reads no table at all for a token belonging to the other credential" do
        allow(ApiKey).to receive(:authenticate).and_call_original

        ingest_raw_gzip("this is not gzip at all", key: create_user_api_key)

        expect(ApiKey).not_to have_received(:authenticate)
      end

      # Criterion 4, and the reason it is asserted by COMPARISON rather than against copied
      # literals: the recorded and unrecorded paths are posted in the same example and their
      # answers compared to each other, so the two cannot drift apart silently. The no-key request
      # takes the identical 400 limb and writes no row, which makes it the exact control for "did
      # bookkeeping edit the client's answer".
      # @intent: { entity: "POST /api/v1/ingest", action: "answer identically recorded or not", behavior: "the corrupt-gzip 400 bytes are the same whether or not bookkeeping wrote a rejection row", layer: "request" }
      it "answers the same bytes whether or not the refusal was recorded" do
        ingest_raw_gzip("this is not gzip at all", key: nil)
        unrecorded = [response.status, response.body, response.headers["content-length"]]
        expect(IngestRejection.count).to eq(0)

        ingest_raw_gzip("this is not gzip at all")
        recorded = [response.status, response.body, response.headers["content-length"]]

        expect(IngestRejection.count).to eq(1)
        expect(recorded).to eq(unrecorded)
      end

      # `Ingest::RejectionRecorder`'s standing decision, which has to hold at this layer too: a
      # write that fails must not turn a clean 400 into a 500, and must not fail silently either.
      # Provoked rather than asserted in the abstract, exactly as the controller path's own spec
      # does it.
      describe "when the rejection cannot be written" do
        before do
          allow(IngestRejection).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "boom")
        end

        # @intent: { entity: "POST /api/v1/ingest", action: "keep the 400 when recording fails", behavior: "a failure writing the rejection row still answers the client the 400 already determined", layer: "request" }
        it "still answers the client the 400 it had already determined" do
          ingest_raw_gzip("this is not gzip at all")

          expect(response).to have_http_status(:bad_request)
          expect(response.parsed_body["message"]).to eq(GzipRequestBody::CORRUPT_MESSAGE)
        end

        # @intent: { entity: "POST /api/v1/ingest", action: "report a recording failure", behavior: "a rejection write that raises is reported to Rails.error as handled rather than swallowed silently", layer: "request" }
        it "reports the failure rather than swallowing it" do
          expect(Rails.error).to receive(:report)
            .with(instance_of(ActiveRecord::StatementInvalid), hash_including(handled: true))

          ingest_raw_gzip("this is not gzip at all")

          expect(response).to have_http_status(:bad_request)
        end
      end

      # The resolution half is this layer's OWN failure mode — the controller path never had it,
      # because it is handed a `current_repository` that is already resolved. If the lookup that
      # decides who to bill the refusal to raises, the client must still get its 400.
      # @intent: { entity: "POST /api/v1/ingest", action: "keep the 400 when lookup fails", behavior: "a raising credential lookup cannot turn the boundary 400 into a 500, and the failure is reported", layer: "request" }
      it "does not let a failing credential lookup turn the 400 into a 500" do
        allow(ApiKey).to receive(:authenticate).and_raise(ActiveRecord::StatementInvalid, "boom")
        allow(Rails.error).to receive(:report)

        ingest_raw_gzip("this is not gzip at all")

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["message"]).to eq(GzipRequestBody::CORRUPT_MESSAGE)
        expect(Rails.error).to have_received(:report)
          .with(instance_of(ActiveRecord::StatementInvalid), hash_including(handled: true))
      end

      # An `IngestRejection` means a DELIVERY that authenticated and was then refused for its
      # payload, which is narrower than the `/api/` scope both middlewares carry. `/api/v1/repository`
      # takes the same `sgk_` credential, so a corrupt body sent there resolves a perfectly good
      # repository — and recording it would claim a delivery was refused when none was attempted,
      # replacing the false "No rejected deliveries" with a false row instead.
      # @intent: { entity: "IngestRejection", action: "scope rows to the ingest endpoint", behavior: "a corrupt gzip on another /api endpoint resolves a repository but writes no row, since no ingest delivery was attempted", layer: "request" }
      it "writes no row for a boundary refusal on a non-ingest endpoint" do
        expect do
          post "/api/v1/repository",
               params: "this is not gzip at all",
               headers: { "Content-Type" => "application/json",
                          "Content-Encoding" => "gzip",
                          "Authorization" => "Bearer #{api_key.raw_token}" }
        end.not_to change(IngestRejection, :count)
      end
    end
  end

  # The grain everything about *tests* rather than about suites has to be asked at. Before
  # `spec_observations` a 20,000-example run retained two integers, and the five per-example fields
  # the shipped formatter has always sent — `id`, `spec_file_path`, `name`, `duration`, `outcome` —
  # were read off the wire and dropped.
  describe "the per-example rows a run leaves behind" do
    # @intent: { entity: "SpecObservation", action: "store one row per example", behavior: "each reported spec becomes a row carrying its name and repository, annotated or not", layer: "request" }
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
    # @intent: { entity: "SpecObservation", action: "key rows by example id", behavior: "a table-driven loop repeating one coordinate yields three rows, kept apart by their distinct ids", layer: "request" }
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
    # @intent: { entity: "SpecObservation", action: "attribute shared examples to the runner", behavior: "two inclusions of a shared group share a coordinate but keep separate rows attributed by the file that ran them", layer: "request" }
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

    # @intent: { entity: "SpecObservation", action: "round-trip duration and outcome", behavior: "per-example timings and outcomes persist unchanged, including the nulls for an example that never ran", layer: "request" }
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
    # @intent: { entity: "SpecObservation", action: "collapse a repeated id gracefully", behavior: "a client repeating an example id gets one row and a 202 instead of a unique-index 500 losing the run", layer: "request" }
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
    # @intent: { entity: "SpecObservation", action: "keep id-less examples distinct", behavior: "a payload with empty ids keeps every example row instead of collapsing to one", layer: "request" }
    it "keeps every example of a payload that carries no ids at all" do
      specs = (1..3).map { |index| unannotated_spec(file_path: "spec/#{index}_spec.rb", line_number: index, id: "") }

      ingest(ingest_payload(specs: specs))

      expect(TestRun.sole.spec_observations.count).to eq(3)
      expect(TestRun.sole.spec_observations.pluck(:example_id).uniq).to eq([nil])
    end

    # @intent: { entity: "SpecObservation", action: "leave unsharded rows shardless", behavior: "an unsharded run stores rows with no shard pointer, since no shard delivered them", layer: "request" }
    it "stores an unsharded run's rows with no shard, because it has none to point at" do
      ingest(ingest_payload(specs: [unannotated_spec]))

      expect(TestRun.sole.test_run_shards).to be_empty
      expect(TestRun.sole.spec_observations.pluck(:test_run_shard_id)).to eq([nil])
    end

    # An anonymous slice — sharded, but with no `shard_id` to tell the slices apart — gets a fresh
    # `TestRunShard` row per POST, so the shard *counters* double on a redelivery and cannot not.
    # The rows are saved by the conflict key instead, which is keyed on the run and the example
    # rather than on the delivery.
    # @intent: { entity: "SpecObservation", action: "dedup rows of an anonymous slice", behavior: "an unnamed sharded slice doubles its counters but not its rows, the row key conflicting where the counters cannot", layer: "request" }
    it "does not double an anonymous slice's rows, though it doubles its counters" do
      body = ingest_payload(ci_run_id: "gha-9", specs: [unannotated_spec(file_path: "spec/a_spec.rb", line_number: 1)])

      ingest(body)
      ingest(body)

      run = TestRun.sole
      expect(run.test_run_shards.count).to eq(2)
      expect(run.total_specs_count).to eq(2)
      expect(run.spec_observations.count).to eq(1)
    end

    # ...and the precondition of the example above, asserted rather than assumed, because the two
    # halves are one fact: Postgres treats NULLs as distinct in a unique index, which is what lets
    # an id-less producer keep one row per example instead of collapsing to one row per run, and is
    # equally what leaves an id-less redelivery nothing to conflict with. An anonymous slice is the
    # one shape where the delete matches nothing, so the two meet and the rows double.
    #
    # This is a KNOWN GAP, pinned here so it stays deliberate. It is not fixable by keying: the
    # only other candidate is `(file_path, line_number)`, which is the coordinate a table-driven
    # loop puts N examples on — the guard two examples up exists precisely to stop that key ever
    # being adopted. The fix is the client-side one `Ingest::RunRecorder#upsert_shard` already
    # prescribes for the doubled counters: name the shards, or send ids.
    # @intent: { entity: "SpecObservation", action: "double id-less redeliveries honestly", behavior: "an anonymous slice with empty ids doubles its rows on redelivery, a known gap with no usable key, pinned as deliberate", layer: "request" }
    it "does double an id-less anonymous slice's rows, having no key with which not to" do
      body = ingest_payload(
        ci_run_id: "gha-10",
        specs: [unannotated_spec(file_path: "spec/a_spec.rb", line_number: 1, id: "")]
      )

      ingest(body)
      ingest(body)

      run = TestRun.sole
      expect(run.test_run_shards.count).to eq(2)
      expect(run.spec_observations.count).to eq(2)
      expect(run.spec_observations.pluck(:example_id)).to eq([nil, nil])
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

      # @intent: { entity: "SpecObservation", action: "attach rows to their shard", behavior: "every example row points at the TestRunShard that delivered it across the four-shard run", layer: "request" }
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
      # @intent: { entity: "SpecObservation", action: "stay row-idempotent on shard re-run", behavior: "a named shard delivering twice leaves the row count unchanged so the suite totals once", layer: "request" }
      it "leaves that shard's row count unchanged, so the suite still totals once" do
        run_all_shards

        expect { ingest(shard_payload(2)) }.not_to change(SpecObservation, :count)

        expect(TestRun.sole.spec_observations.count).to eq(12)
      end

      # @intent: { entity: "SpecObservation", action: "replace a re-run shard rows", behavior: "a re-run shard with fewer examples drops its stale rows instead of keeping them alongside the fresh ones", layer: "request" }
      it "replaces the re-run shard's rows rather than keeping the stale ones beside them" do
        run_all_shards
        ingest(shard_payload(2, examples: 2))

        run = TestRun.sole
        expect(run.spec_observations.count).to eq(11)
        expect(run.spec_observations.where("file_path LIKE 'spec/shard2/%'").pluck(:file_path))
          .to match_array(%w[spec/shard2/e1_spec.rb spec/shard2/e2_spec.rb])
      end

      # @intent: { entity: "SpecObservation", action: "stay row-idempotent on full re-run", behavior: "every shard delivering a second time leaves the recorded rows exactly once", layer: "request" }
      it "re-running every shard leaves the suite counted once" do
        run_all_shards

        expect { run_all_shards }.not_to change(SpecObservation, :count)
      end

      # Criterion 9 in one example: the new table is a second, finer record of the same delivery,
      # and the headline counters are deliberately *not* re-derived from it.
      # @intent: { entity: "TestRun", action: "derive counters from shards", behavior: "the run totals come from the shard rows and are not re-derived from the observation table beneath them", layer: "request" }
      it "leaves the run's own counters deriving from its shards, untouched" do
        run_all_shards

        expect(TestRun.sole).to have_attributes(total_specs_count: 12, annotated_specs_count: 0)
      end
    end

    # Everything above models a *static* split: `shard_payload` gives each shard its own
    # `spec/shard#{n}/` namespace, so the four slices are disjoint by construction and every row a
    # redelivery touches is one its own delete already reached. A queue-based splitter — Knapsack
    # Pro queue mode, `parallel_tests --group-by runtime` — rebalances between runs, which is the
    # entire reason to use one, and `example_id` is `./spec/foo_spec.rb[1:1]`, so it travels with
    # the file. That puts an example on the far side of a delete keyed on the shard, where the
    # conflict clause is the only thing that can reach it — and which of the two colliding rows
    # wins is then a decision, not a detail.
    describe "a splitter that moves an example from one shard to another between runs" do
      def deliver(shard, examples)
        specs = examples.map do |name, duration|
          unannotated_spec(file_path: "spec/#{name}_spec.rb", line_number: 1,
                           id: "./spec/#{name}_spec.rb[1:1]", duration: duration)
        end

        ingest(ingest_payload(ci_run_id: "gha-queue", shard_id: shard, specs: specs))
      end

      def measurements = TestRun.sole.spec_observations.pluck(:example_id, :duration_seconds)

      def shard_of(name)
        TestRun.sole.spec_observations.find_by!(example_id: "./spec/#{name}_spec.rb[1:1]").test_run_shard_id
      end

      # A owns e1; B owns e2 and e3.
      before do
        deliver("A", [["e1", 1.0]])
        deliver("B", [["e2", 9.0], ["e3", 2.0]])
      end

      # The measurement this whole clause is for. Under `DO NOTHING` the platform kept the 9.0 and
      # threw the 0.5 away: A's delete could not reach a row owned by B, so the fresh measurement
      # arrived as a conflict and lost it to the stale one — silently, with nothing in the data to
      # say the number was a run out of date.
      # @intent: { entity: "SpecObservation", action: "keep the newest measurement", behavior: "an example moved between shards carries its latest duration, the conflict clause beating the stale row the delete cannot reach", layer: "request" }
      it "keeps the newest measurement, not the row the delete could not reach" do
        deliver("A", [["e1", 1.0], ["e2", 0.5]])

        expect(measurements).to match_array(
          [["./spec/e1_spec.rb[1:1]", 1.0], ["./spec/e2_spec.rb[1:1]", 0.5], ["./spec/e3_spec.rb[1:1]", 2.0]]
        )
      end

      # Ownership moves with the measurement, or the row would report a duration taken by a shard
      # the data says never ran it.
      # @intent: { entity: "SpecObservation", action: "move shard ownership with the example", behavior: "a rebalanced example is re-pointed at the shard that actually ran it in this delivery", layer: "request" }
      it "re-points the moved example at the shard that actually ran it" do
        deliver("A", [["e1", 1.0], ["e2", 0.5]])

        expect(shard_of("e2")).to eq(TestRun.sole.test_run_shards.find_by!(shard_id: "A").id)
      end

      # `Ingest::ObservationRecorder::REMEASURABLE` decides what a collision may move, and the
      # embed-failure stamp is deliberately NOT in it — the same reasoning that keeps
      # `spec_identity_id` out. A redelivery says what the test COST this time; it says nothing
      # whatever about whether the embedding provider was reachable when the resolver last asked. So
      # the moved row keeps its place in `Ingest::IdentityResolver`'s retry backlog while its
      # measurement moves onto it, which is what lets a rescue survive a rebalancing splitter.
      # @intent: { entity: "SpecObservation", action: "preserve the embed-failure stamp on move", behavior: "a moved row keeps its embed retry backlog while its measurement updates, so resolver rescues survive rebalancing", layer: "request" }
      it "re-measures the moved example without clearing its embed-failure stamp" do
        failed_at = 2.hours.ago.change(usec: 0)
        TestRun.sole.spec_observations.where(example_id: "./spec/e2_spec.rb[1:1]")
               .update_all(embed_failed_at: failed_at, embed_failure_count: 2)

        deliver("A", [["e1", 1.0], ["e2", 0.5]])

        moved = TestRun.sole.spec_observations.find_by!(example_id: "./spec/e2_spec.rb[1:1]")
        expect(moved.duration_seconds).to eq(0.5)
        expect(moved).to have_attributes(embed_failed_at: failed_at, embed_failure_count: 2)
      end

      # The other half of that decision, and it is a different path rather than an exception to the
      # one above: a row its OWN shard re-delivers is deleted and recreated, which the recorder's
      # class comment calls starting a new history. The recreated row is genuinely
      # unresolved-and-unattempted and earns a fresh stamp on its own merits if the provider is
      # still down. What must not happen is a row silently keeping a stamp for an attempt that no
      # longer refers to it.
      # @intent: { entity: "SpecObservation", action: "reset the stamp on recreation", behavior: "a row its own shard re-delivered starts a fresh embed history rather than inheriting an attempt that no longer refers to it", layer: "request" }
      it "starts the stamp afresh on a row its own shard recreated" do
        TestRun.sole.spec_observations.where(example_id: "./spec/e1_spec.rb[1:1]")
               .update_all(embed_failed_at: 2.hours.ago, embed_failure_count: 2)

        deliver("A", [["e1", 1.0]])

        expect(TestRun.sole.spec_observations.find_by!(example_id: "./spec/e1_spec.rb[1:1]"))
          .to have_attributes(embed_failed_at: nil, embed_failure_count: 0)
      end

      # The other side of the move, asserted so it is not mistaken for loss: B re-running without
      # the example it gave away does not take that row with it, because the row is A's now and B's
      # delete no longer matches it.
      # @intent: { entity: "SpecObservation", action: "not reclaim a given-up example", behavior: "the shard that gave an example away cannot delete it back when it re-runs without it", layer: "request" }
      it "does not take the moved example back when the shard it left re-runs without it" do
        deliver("A", [["e1", 1.0], ["e2", 0.5]])
        deliver("B", [["e3", 2.0]])

        expect(measurements).to match_array(
          [["./spec/e1_spec.rb[1:1]", 1.0], ["./spec/e2_spec.rb[1:1]", 0.5], ["./spec/e3_spec.rb[1:1]", 2.0]]
        )
      end

      # The consequence `Ingest::ObservationRecorder` states rather than hides: an example moving
      # the *other* way is absent between the two deliveries, because the shard that gave it up
      # deletes it and the shard that took it has not reported yet. A sharded run is whole only
      # once every shard has reported — the counters have had this property all along — so it
      # converges rather than drifting.
      # @intent: { entity: "SpecObservation", action: "converge across a rebalance", behavior: "a moved example is absent only between the two deliveries that move it, and the run is whole again once all shards report", layer: "request" }
      it "loses an example only between the delivery that gave it up and the one that took it" do
        deliver("A", [])

        expect(measurements.map(&:first)).to match_array(["./spec/e2_spec.rb[1:1]", "./spec/e3_spec.rb[1:1]"])

        deliver("B", [["e1", 4.0], ["e2", 9.0], ["e3", 2.0]])

        expect(measurements).to match_array(
          [["./spec/e1_spec.rb[1:1]", 4.0], ["./spec/e2_spec.rb[1:1]", 9.0], ["./spec/e3_spec.rb[1:1]", 2.0]]
        )
      end
    end
  end

  # WHAT THE RESPONSE SAYS ABOUT PER-EXAMPLE IDENTITY — the axis two earlier examples pin the
  # platform-side behaviour of and never ask the client-facing question about.
  #
  # Both live in "the per-example rows a run leaves behind": "keeps every example of a payload that
  # carries no ids at all" and "does double an id-less anonymous slice's rows, having no key with
  # which not to". They assert that an id-less payload keeps its rows and that an id-less anonymous
  # slice doubles them on redelivery. Both are statements about what the DATABASE ends up holding,
  # and both are deliberate: the doubling has no platform-side fix, because the only other
  # candidate conflict key is `(file_path, line_number)` and that is the coordinate a table-driven
  # loop puts N examples on. The fix is client-side — send ids — and until now the response gave a
  # client nothing to act on: a payload omitting every id returned a body byte-identical to one
  # sending them all. Safety and honesty are different questions; these are the second.
  describe "the id coverage the response reports" do
    def coverage_from(specs)
      ingest(ingest_payload(specs: specs))

      response.parsed_body.slice("total_specs", "recorded_specs", "identified_specs")
    end

    # @intent: { entity: "POST /api/v1/ingest", action: "report full id coverage", behavior: "when every example carried an id the identified count equals the rows recorded", layer: "request" }
    it "reports an id count equal to the rows when every example carried one" do
      specs = (1..3).map { |n| unannotated_spec(file_path: "spec/#{n}_spec.rb", line_number: n) }

      expect(coverage_from(specs)).to eq(
        "total_specs" => 3, "recorded_specs" => 3, "identified_specs" => 3
      )
    end

    # ⭐ THE POINT OF THE SLICE. This body and the one above are no longer the same document, which
    # is the whole difference between a producer that can see it is giving up redelivery safety and
    # one that cannot. The zero is a MEASURED statement — "no row carried an id" — so it is `0` and
    # not `null`; only `annotated_ratio` is nullable here, and only because 0/0 is undefined.
    # @intent: { entity: "POST /api/v1/ingest", action: "report zero id coverage honestly", behavior: "a payload with no ids gets a measured zero, not a null, while the rows it wrote are still counted", layer: "request" }
    it "reports a zero id count, against the rows it still wrote, for a payload carrying no ids" do
      specs = (1..3).map { |n| unannotated_spec(file_path: "spec/#{n}_spec.rb", line_number: n, id: "") }

      expect(coverage_from(specs)).to eq(
        "total_specs" => 3, "recorded_specs" => 3, "identified_specs" => 0
      )
    end

    # @intent: { entity: "POST /api/v1/ingest", action: "count ids on a mixed payload", behavior: "the identified figure counts exactly the rows carrying an id when only some do", layer: "request" }
    it "counts exactly the rows carrying an id when a payload mixes the two" do
      specs = [
        unannotated_spec(file_path: "spec/a_spec.rb", line_number: 1),
        unannotated_spec(file_path: "spec/b_spec.rb", line_number: 2, id: ""),
        unannotated_spec(file_path: "spec/c_spec.rb", line_number: 3),
        unannotated_spec(file_path: "spec/d_spec.rb", line_number: 4, id: "")
      ]

      expect(coverage_from(specs)).to eq(
        "total_specs" => 4, "recorded_specs" => 4, "identified_specs" => 2
      )
    end

    # ⭐ THE GRAIN EXAMPLE, and the reason `recorded_specs` is served at all rather than leaving a
    # client to subtract from `total_specs`.
    #
    # This producer sent an id on EVERY example and has no shortfall whatsoever. But it repeated
    # one, so `Ingest::ObservationRecorder#build_rows` collapsed the repeat to its first occurrence
    # and wrote two rows for the three specs the run counts. All three numbers are asserted in ONE
    # example precisely so the disagreement is visible: `identified == recorded`, while
    # `total_specs` is strictly greater than both.
    #
    # A client computing `total_specs - identified_specs` reads a phantom missing id here and goes
    # hunting a bug that does not exist. `recorded_specs - identified_specs` is the shortfall, and
    # it is zero, which is the truth. The two figures are the same grain — rows — and `total_specs`
    # is a different one: the run's suite size, re-derived by SUM over `test_run_shards` from what
    # the client REPORTED.
    # @intent: { entity: "POST /api/v1/ingest", action: "report no phantom shortfall", behavior: "a repeated id makes total exceed recorded, but identified equals recorded, so the true shortfall is zero", layer: "request" }
    it "reports no shortfall for a payload that carries every id but repeats one" do
      specs = [
        unannotated_spec(file_path: "spec/a_spec.rb", line_number: 1, id: "dup", name: "first"),
        unannotated_spec(file_path: "spec/b_spec.rb", line_number: 2, id: "dup", name: "second"),
        unannotated_spec(file_path: "spec/c_spec.rb", line_number: 3, id: "kept")
      ]

      body = coverage_from(specs)

      expect(body).to eq("total_specs" => 3, "recorded_specs" => 2, "identified_specs" => 2)
      expect(body["identified_specs"]).to eq(body["recorded_specs"])
      expect(body["total_specs"]).to be > body["recorded_specs"]
      # ...and the rows really are what the row-grain pair counted, rather than two numbers that
      # happen to agree with each other while describing nothing.
      expect(TestRun.sole.spec_observations.pluck(:example_id)).to match_array(%w[dup kept])
    end

    # Zeroes rather than nils for a run that recorded nothing, on the house rule pinned at
    # `spec/models/spec_observation_spec.rb` — "reads zeroes for a run that recorded nothing".
    # Counts read `0`; only ratios read `null`, and `annotated_ratio` is the one field here that
    # does, because a run of nothing has no share to report.
    # @intent: { entity: "POST /api/v1/ingest", action: "read zeroes for an empty run", behavior: "a run that recorded nothing answers zeroes for the counts and null only for the ratio, per the house rule", layer: "request" }
    it "reports zeroes, not nulls, for a run that recorded no rows at all" do
      ingest(ingest_payload(specs: []))

      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body).to include(
        "total_specs" => 0, "recorded_specs" => 0, "identified_specs" => 0, "annotated_ratio" => nil
      )
    end

    # ONE round trip for both figures, not two — the cost this slice deliberately adds to the
    # ingest path, bounded here so it stays one. `coverage_in` selects every counter in
    # `SpecObservation::COVERAGE_COUNTS` in a single SELECT, so a second statement carrying this
    # expression would mean someone had fetched the numerator and the denominator separately: two
    # reads of one run's rows, free to disagree with each other.
    # @intent: { entity: "SpecObservation", action: "answer coverage in one query", behavior: "both coverage figures come out of a single COUNT select on the ingest path, never a second read that could disagree", layer: "request" }
    it "adds exactly one query to the ingest path to answer for both figures" do
      body = ingest_payload(specs: [unannotated_spec(file_path: "spec/a_spec.rb", line_number: 1)])

      coverage_reads = queries_against(/COUNT\(example_id\)/) { ingest(body) }

      expect(coverage_reads.size).to eq(1)
    end
  end

  # The other end of the sentence above: rows arrive here one per example per run, and until
  # `Ingest::ObservationPruner` existed nothing ever took one away for age. The rule is
  # `SpecObservation::BRANCH_RETENTION_RUNS` runs OF ONE BRANCH, enforced at the write path
  # because that is where the growth happens — there is no scheduler and no recurring job.
  describe "the retention rule the ingest path enforces" do
    # Two rather than the shipped sixty, so an example is three POSTs rather than sixty-one. What
    # the number IS, and the floor it may never go under, is pinned in
    # spec/services/ingest/observation_pruner_spec.rb against the real constants.
    before { stub_const("SpecObservation::BRANCH_RETENTION_RUNS", 2) }

    def ingest_on(branch, name:)
      ingest(ingest_payload(branch: branch, specs: [unannotated_spec(file_path: "spec/#{name}_spec.rb")]))
      TestRun.order(:id).last
    end

    # @intent: { entity: "SpecObservation", action: "prune a fallen run", behavior: "once a branch exceeds its retention window the oldest run loses its example rows when the next one lands", layer: "request" }
    it "empties the run that falls out of the branch's window when the next one lands" do
      first = ingest_on("main", name: "a")
      second = ingest_on("main", name: "b")
      third = ingest_on("main", name: "c")

      expect(first.spec_observations.count).to eq(0)
      expect(second.spec_observations.count).to eq(1)
      expect(third.spec_observations.count).to eq(1)
    end

    # The pruned run is still a run. Its row and both counters are derived from `test_run_shards`
    # and are no business of this rule, so the suite-size trajectory reads it exactly as before.
    # Every attribute is compared, `updated_at` included: nothing in the prune path writes to the
    # pruned run — `recompute_totals` writes `update_columns` on the CURRENT run, and
    # `SpecObservation belongs_to :test_run` carries no `touch:` — so an exclusion here would only
    # hide a regression that gave the rule a reach over `test_runs` it is not supposed to have.
    # @intent: { entity: "TestRun", action: "leave the pruned run intact", behavior: "pruning deletes observations only, leaving the pruned run row and both counters exactly as they were", layer: "request" }
    it "leaves the pruned run's row and both counters exactly as they were" do
      first = ingest_on("main", name: "a")
      before_prune = first.attributes

      ingest_on("main", name: "b")
      ingest_on("main", name: "c")

      expect(first.reload.attributes).to eq(before_prune)
    end

    # @intent: { entity: "SpecObservation", action: "bound a sharded branch too", behavior: "the branch retention window applies to sharded runs after each shard transaction commits", layer: "request" }
    it "bounds a sharded run's branch too, after the shard's own transaction" do
      3.times do |index|
        ingest(ingest_payload(branch: "main", ci_run_id: "gha-#{index}", shard_id: "1",
                              specs: [unannotated_spec(file_path: "spec/s_spec.rb")]))
      end

      runs = TestRun.order(:id).to_a
      expect(runs.map { |run| run.spec_observations.count }).to eq([0, 1, 1])
      expect(runs.map { |run| run.test_run_shards.count }).to eq([1, 1, 1])
    end

    # @intent: { entity: "SpecObservation", action: "keep branches independent", behavior: "feature branch runs never evict trunk history because the window is counted per branch", layer: "request" }
    it "does not let a feature branch's runs evict the trunk's" do
      main = ingest_on("main", name: "a")
      3.times { |index| ingest_on("feature/#{index}", name: "f#{index}") }

      expect(main.spec_observations.count).to eq(1)
    end

    # @intent: { entity: "SpecObservation", action: "bucket branch-less runs separately", behavior: "runs with no branch form their own retention bucket and never touch branched windows", layer: "request" }
    it "keeps branch-less runs in their own bucket" do
      anonymous = ingest_on(nil, name: "a")
      ingest_on("main", name: "b")
      ingest_on("main", name: "c")

      expect(anonymous.spec_observations.count).to eq(1)
    end

    # ⭐ The other half of the rule, end to end through a real POST. `feature/gone` is merged: it
    # will never receive another delivery, so `Ingest::ObservationPruner` — which only ever bounds
    # the bucket of the run it is handed — could not reach it, and its history sat outside the one
    # rule bounding this table for as long as the repository lived. An ingest on `main` drains it.
    #
    # Built directly rather than by POSTing to `feature/gone`, and that is not a shortcut: the
    # current-branch half leaves a live branch sitting EXACTLY at the rule, so no sequence of
    # deliveries to a branch can put that branch over it. A bucket over the rule is by construction
    # one whose rows predate the rule reaching it, which is the population this half exists for.
    def quiet_history(branch:, count:)
      (0...count).map do |index|
        run = create_test_run(repository: repository, branch: branch, total_specs_count: 1,
                              created_at: 100.days.ago + index.minutes)
        run.spec_observations.create!(repository: repository, file_path: "spec/gone_spec.rb",
                                      line_number: 1, status: "unannotated")
        run
      end
    end

    # @intent: { entity: "SpecObservation", action: "drain an abandoned branch", behavior: "a merged branch the repository stopped writing to is drained by an ingest elsewhere, closing the gap the write-path rule could not reach", layer: "request" }
    it "drains a branch the repository has stopped writing to entirely" do
      quiet = quiet_history(branch: "feature/gone", count: 5)

      ingest_on("main", name: "a")

      expect(quiet.map { |run| run.spec_observations.count }).to eq([0, 0, 0, 1, 1])
    end

    # @intent: { entity: "SpecObservation", action: "scope quiet-bucket drains per repository", behavior: "draining one repository quiet branch leaves another repository history untouched", layer: "request" }
    it "leaves a second repository's quiet branch alone" do
      elsewhere = create_repository(user: create_user(github_uid: "3003", github_handle: "third"),
                                    github_full_name: "acme/third-service")
      theirs = (0...5).map do |index|
        run = create_test_run(repository: elsewhere, branch: "feature/gone", total_specs_count: 1,
                              created_at: 100.days.ago + index.minutes)
        run.spec_observations.create!(repository: elsewhere, file_path: "spec/gone_spec.rb",
                                      line_number: 1, status: "unannotated")
        run
      end

      ingest_on("main", name: "a")

      expect(theirs.map { |run| run.spec_observations.count }).to all(eq(1))
    end

    # ⚠️ **The two halves of the rule fail DIFFERENTLY, and both sides are pinned here so the
    # asymmetry cannot rot into symmetry.** Either example passing alone proves nothing: "the
    # ingest survives a prune failure" is satisfied by rescuing both, and "a prune failure fails
    # the ingest" is satisfied by rescuing neither. It is the PAIR that says which is which.
    #
    # The reasoning, which is a policy choice rather than a default either way:
    #
    #   * `Ingest::ObservationPruner` bounds the rows THIS delivery just wrote. Its persistent
    #     failure mode is the table having outgrown the one rule bounding it, which is the last
    #     thing that should fail invisibly — and an ingest is idempotent, so the client's retry
    #     costs a duplicate delivery of a slice that replaces itself. It fails the request.
    #   * `Ingest::QuietBucketPruner` works on rows an OLDER delivery wrote, on a branch this
    #     client may have nothing to do with. Billing a caller a 500 for that would convert
    #     opportunistic housekeeping into an outage on a request whose data already committed.
    #     It answers 202 and goes to `Rails.error.report` — loud in the reporter, silent in the
    #     response.
    describe "how each half of the rule fails" do
      let(:timeout) { [ActiveRecord::StatementInvalid, "canceling statement due to statement timeout"] }

      # @intent: { entity: "POST /api/v1/ingest", action: "absorb a quiet-half failure", behavior: "a failing quiet-bucket prune answers an unchanged 202 and reports the error with component context, never a 500", layer: "request" }
      it "answers the quiet half's failure with an unchanged 202 and an error report" do
        allow(Ingest::QuietBucketPruner).to receive(:drain).and_raise(*timeout)
        # Captured and asserted afterwards rather than matched inline: one of the assertions is a
        # NEGATIVE on the argument list, and raising that from inside a `.with` block re-enters
        # the reporter being stubbed and buries the diagnostic in its own re-report.
        reported = nil
        allow(Rails.error).to receive(:report) { |error, **options| reported = [error, options] }

        expect { ingest(ingest_payload(branch: "main")) }.to change(TestRun, :count).by(1)

        expect(response).to have_http_status(:accepted)
        expect(response.parsed_body["test_run_id"]).to eq(TestRun.last.id)

        # The SHAPE of the report, not merely that one happened. `source` is a subscriber-FILTERING
        # key in Rails' reporter rather than a label, so this call leaves it at its default and
        # names the emitter in `context[:component]` — matching `Ingest::RejectionRecorder#report`,
        # the only other reporter call on this path. A bespoke `source` on one of two siblings is
        # how a subscriber scoped to the default silently drops half of them, which stays invisible
        # right up until these reports are the thing someone is looking for.
        error, options = reported
        expect(error).to be_a(ActiveRecord::StatementInvalid)
        expect(options).to include(handled: true, severity: :warning)
        expect(options).not_to have_key(:source)
        expect(options[:context]).to include(component: "Ingest::QuietBucketPruner",
                                             repository_id: Repository.last.id)
      end

      # @intent: { entity: "POST /api/v1/ingest", action: "fail on a current-branch prune error", behavior: "a raising observation prune fails the ingest, because unbounded table growth must not fail invisibly", layer: "request" }
      it "still fails the ingest when the current-branch half raises" do
        allow(Ingest::ObservationPruner).to receive(:prune).and_raise(*timeout)

        expect { ingest(ingest_payload(branch: "main")) }.to raise_error(ActiveRecord::StatementInvalid)
      end

      # The half that raises is the half that is contained, and no wider: a failure in the quiet
      # half must not swallow one in its sibling, which would be the asymmetry collapsing the other
      # way — into a rescue around both.
      # @intent: { entity: "POST /api/v1/ingest", action: "contain each failure to its half", behavior: "the quiet half rescue may not swallow a current-branch prune failure, keeping the asymmetry from collapsing", layer: "request" }
      it "does not let the quiet half's rescue cover the current-branch half" do
        allow(Ingest::ObservationPruner).to receive(:prune).and_raise(*timeout)
        allow(Ingest::QuietBucketPruner).to receive(:drain).and_return(0)

        expect { ingest(ingest_payload(branch: "main")) }.to raise_error(ActiveRecord::StatementInvalid)
      end
    end

    # ⚠️ The prune must run AFTER the ingest transaction commits, never inside it.
    # `Ingest::RunRecorder#record` holds `run.lock!` across its whole insert-and-recompute, and
    # the length of that hold is measured and load-bearing — 8 concurrent shards, 6 of 8 lost to
    # `PG::TRDeadlockDetected`, before the lock moved to where it is. The prune needs none of that
    # protection, since the only rows it touches belong to runs older than the retained window.
    #
    # Transaction DEPTH is what discriminates here and a spy on call order would not: under
    # transactional tests the example's own transaction is non-joinable, so `RunRecorder`'s block
    # opens a savepoint and everything inside it runs one level deeper than everything outside.
    #
    # ⚠️ BOTH halves of the rule are pinned, not just the original one. The quiet half is the
    # newer call and the more tempting one to fold inward — it is opportunistic work with no
    # ordering constraint of its own, so nothing about reading `#record` suggests its placement
    # matters. It carries the same deadlock exposure for the same reason. Without the second wrap,
    # moving `drain_quiet_bucket` inside the transaction leaves the whole suite green.
    #
    # ⚠️ And on BOTH ingest paths, which is the gap this example had before the quiet half existed
    # and which is worth stating plainly: `ingest_payload` carries no `ci_run_id`, so it lands on
    # `#record_unsharded_run`. The single-payload version of this example therefore guarded only
    # the UNSHARDED path — while the incident it cites, 8 concurrent shards with 6 of 8 lost to
    # `PG::TRDeadlockDetected`, is a property of the SHARDED one, whose `run.lock!` is the lock in
    # question. `#record_unsharded_run` takes no such lock at all, so the path with the real
    # exposure was the path with no pin. Both are parametrised here; each was verified to fail by
    # moving its own call inside its own transaction.
    {
      "unsharded" => {},
      "sharded" => { ci_run_id: "gha-42", shard_id: "1" }
    }.each do |path, extra|
      # @intent: { entity: "POST /api/v1/ingest", action: "prune after commit on both paths", behavior: "both prune halves run at a shallower transaction depth than the recording they follow, on the sharded and unsharded paths alike", layer: "request" }
      it "prunes outside the transaction that recorded the run — #{path}" do
        depths = {}

        allow(Ingest::ObservationRecorder).to receive(:record).and_wrap_original do |original, *args, **options|
          depths[:record] = ActiveRecord::Base.connection.open_transactions
          original.call(*args, **options)
        end
        allow(Ingest::ObservationPruner).to receive(:prune).and_wrap_original do |original, *args|
          depths[:prune] = ActiveRecord::Base.connection.open_transactions
          original.call(*args)
        end
        allow(Ingest::QuietBucketPruner).to receive(:drain).and_wrap_original do |original, *args|
          depths[:drain] = ActiveRecord::Base.connection.open_transactions
          original.call(*args)
        end

        ingest(ingest_payload(branch: "main", **extra))

        expect(depths[:prune]).to be < depths[:record]
        expect(depths[:prune]).to eq(ActiveRecord::Base.connection.open_transactions)

        expect(depths[:drain]).to be < depths[:record]
        expect(depths[:drain]).to eq(ActiveRecord::Base.connection.open_transactions)
      end
    end

    # A query budget on the ingest path. `count_queries` comes from spec/support/query_capture.rb,
    # the same subscriber the dashboard's page budgets use.
    #
    # Pinned as ABSOLUTES and in a pair, so the retention rule's own statements are ATTRIBUTED
    # rather than silently absorbed into a single total that could hide any number of them. Both
    # halves of the rule are in these figures, and they cost differently:
    #
    #   * `Ingest::QuietBucketPruner`'s selection probe is ONE statement on EVERY ingest, in both
    #     figures below. On these fixtures it comes back empty — there is one branch and it is the
    #     one being written to — so it issues no boundary lookup and no delete. That flat one is
    #     the price of the quiet half being unconditional, and it is what the pair is here to keep
    #     visible: if this ever starts scaling with the number of buckets, these numbers move.
    #   * `Ingest::ObservationPruner` costs ONE more on a branch that has not yet filled its
    #     window — the boundary lookup, which comes back empty and issues no delete at all;
    #   * and TWO more on a branch at its window — that boundary lookup plus one bounded delete,
    #     which comes back short and stops the loop rather than spending the rest of the ceiling.
    #   * `SpecObservation.coverage_in` is ONE statement on EVERY ingest, in both figures below —
    #     the aggregate the `202` reports `recorded_specs` / `identified_specs` from. It is the one
    #     read on this path that is not about writing the run: everything else in the response
    #     comes off `test_run.*`, which `Ingest::RunRecorder` returns with the run's derived totals
    #     already loaded, and per-example identity is not among them because it is a fact about the
    #     ROWS rather than about what the shards reported. Both figures come out of this single
    #     SELECT — a second statement here would mean a numerator and a denominator fetched
    #     separately, free to disagree — and it is bounded by the same
    #     `/COUNT\(example_id\)/` guard in "the id coverage the response reports".
    #
    # The difference between the two figures is exactly that one delete. Neither figure follows the
    # size of the backlog: the ceilings on the delete statements are
    # `Ingest::ObservationPruner::MAX_BATCHES_PER_INGEST` and
    # `Ingest::QuietBucketPruner::MAX_BATCHES_PER_INGEST`, each asserted directly against a backlog
    # several times its size in the two pruners' own specs.
    describe "what one ingest costs" do
      # The repository and its key are lazy `let`s, so touching them here keeps their inserts out
      # of the counted block — otherwise the first measurement counts the fixture rather than the
      # request.
      before { api_key }

      # @intent: { entity: "POST /api/v1/ingest", action: "spend a fixed query budget", behavior: "a single ingest on an unfilled window issues a bounded, constant number of statements regardless of suite size", layer: "request" }
      it "spends a fixed budget, of which the rule is two statements on an unfilled window" do
        expect(count_queries { ingest(ingest_payload(branch: "main")) }).to eq(9)
      end

      # @intent: { entity: "POST /api/v1/ingest", action: "spend one more at the window", behavior: "a filled window adds exactly the bounded boundary delete to the fixed budget, and no more", layer: "request" }
      it "spends exactly one more once the window is full and a run falls out of it" do
        ingest(ingest_payload(branch: "main"))
        ingest(ingest_payload(branch: "main"))

        expect(count_queries { ingest(ingest_payload(branch: "main")) }).to eq(10)
      end
    end
  end

  # The full auth matrix is proved once in spec/requests/api/v1/repositories_spec.rb. All this
  # endpoint owes is evidence that it inherits the filter rather than re-plumbing it.
  describe "authentication" do
    # @intent: { entity: "POST /api/v1/ingest", action: "reject a missing credential", behavior: "no Authorization header means 401 with the standard error body and nothing recorded", layer: "request" }
    it "rejects a request with no Authorization header with 401" do
      expect { ingest(ingest_payload, key: nil) }.not_to change(TestRun, :count)

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["error"]).to eq("unauthorized")
    end

    # @intent: { entity: "POST /api/v1/ingest", action: "reject a bad credential", behavior: "a well-formed token that resolves nothing is answered 401 the same as an absent one", layer: "request" }
    it "rejects a bad key with 401" do
      ingest(ingest_payload, key: nil, headers: { "Authorization" => "Bearer sgk_not-a-key" })

      expect(response).to have_http_status(:unauthorized)
    end

    # @intent: { entity: "ApiKey", action: "stamp last use", behavior: "a successful authenticated ingest writes last_used_at on the credential that was presented", layer: "request" }
    it "records when the key was last used" do
      ingest(ingest_payload)

      expect(api_key.reload.last_used_at).to be_present
    end
  end
end
