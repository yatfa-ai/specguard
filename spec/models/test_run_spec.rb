# frozen_string_literal: true

require "rails_helper"

RSpec.describe TestRun do
  let(:repository) { create_repository }

  # @intent: { entity: "TestRun", action: "validate its commit", behavior: "a run without a commit_sha fails validation with an error on that column, so no run enters the table unnamed", layer: "unit" }
  it "requires the commit it ran against" do
    run = repository.test_runs.new(commit_sha: nil)

    expect(run).not_to be_valid
    expect(run.errors[:commit_sha]).to be_present
  end

  # @intent: { entity: "TestRun", action: "require its repository", behavior: "a bare TestRun with no repository association is invalid with the error on :repository, pinning the belongs_to contract", layer: "unit" }
  it "belongs to a repository" do
    run = TestRun.new(commit_sha: "abc123")

    expect(run).not_to be_valid
    expect(run.errors[:repository]).to be_present
  end

  describe "#annotated_ratio" do
    # @intent: { entity: "TestRun", action: "floor annotated_ratio at zero", behavior: "a run with no counted specs still returns the Float 0.0 rather than nil, because the percentage feeds a rendered meter", layer: "unit" }
    it "is 0.0 for a run that counted no specs" do
      run = repository.test_runs.create!(commit_sha: "abc123")

      expect(run.total_specs_count).to eq(0)
      expect(run.annotated_ratio).to eq(0.0)
      expect(run.annotated_ratio).to be_a(Float)
    end

    # @intent: { entity: "TestRun", action: "treat unwritten counters as zero share", behavior: "nil annotated_specs_count and total_specs_count still yield Float 0.0 from annotated_ratio instead of raising or returning nil", layer: "unit" }
    it "is 0.0 when the counters were never written at all" do
      run = repository.test_runs.create!(commit_sha: "abc123", annotated_specs_count: nil,
                                         total_specs_count: nil)

      expect(run.annotated_ratio).to eq(0.0)
      expect(run.annotated_ratio).to be_a(Float)
    end

    # @intent: { entity: "TestRun", action: "report the annotated share as a percentage", behavior: "annotated_ratio divides annotated_specs_count by total_specs_count and rounds to one decimal, so 2 of 3 reads 66.7", layer: "unit" }
    it "reports the share of counted specs that were annotated, to one decimal" do
      run = repository.test_runs.create!(commit_sha: "abc123", annotated_specs_count: 2,
                                         total_specs_count: 3)

      expect(run.annotated_ratio).to eq(66.7)
    end

    # @intent: { entity: "TestRun", action: "report full annotation as one hundred", behavior: "when annotated and total counts are equal annotated_ratio returns exactly 100.0", layer: "unit" }
    it "is 100.0 when every counted spec was annotated" do
      run = repository.test_runs.create!(commit_sha: "abc123", annotated_specs_count: 7,
                                         total_specs_count: 7)

      expect(run.annotated_ratio).to eq(100.0)
    end

    # Read off this run's own counters — `annotated_specs_count` over `total_specs_count` — so the
    # `spec_intents` rows sitting beside the run are not an input and cannot move the figure. Worth
    # pinning because those rows are written here by the factory and never by ingestion: the four
    # intent columns are NOT NULL, so an unannotated spec is not a row that can exist.
    # @intent: { entity: "TestRun", action: "read only its own counters", behavior: "spec_intents rows attached to the run do not move annotated_ratio, which is computed solely from the run's stored count columns", layer: "unit" }
    it "is unmoved by the intent rows sitting beside the run" do
      run = repository.test_runs.create!(commit_sha: "abc123", annotated_specs_count: 2,
                                         total_specs_count: 3)
      create_spec_intent(repository: repository, line_number: 1, test_run: run)
      create_spec_intent(repository: repository, line_number: 2, test_run: run)

      expect(run.annotated_ratio).to eq(66.7)
    end
  end

  describe "#annotated_fraction" do
    # The unit the /ingest API reports. Kept beside #annotated_ratio deliberately: the two differ
    # by 100×, and in a JSON body that gap is invisible until a client is already wrong by it.
    # @intent: { entity: "TestRun", action: "report the same share as a 0-1 fraction", behavior: "annotated_fraction and annotated_ratio express the same share in different units, 0.838 against 83.8, so the JSON contract cannot drift from the meter", layer: "unit" }
    it "is the same share as a 0-1 fraction" do
      run = repository.test_runs.create!(commit_sha: "abc123", annotated_specs_count: 119,
                                         total_specs_count: 142)

      expect(run.annotated_fraction).to eq(0.838)
      expect(run.annotated_ratio).to eq(83.8)
    end

    # @intent: { entity: "TestRun", action: "round the fraction to three decimals", behavior: "annotated_fraction rounds 2 of 3 to 0.667 rather than carrying full float precision", layer: "unit" }
    it "rounds to three decimals" do
      run = repository.test_runs.create!(commit_sha: "abc123", annotated_specs_count: 2,
                                         total_specs_count: 3)

      expect(run.annotated_fraction).to eq(0.667)
    end

    # @intent: { entity: "TestRun", action: "report full annotation as one", behavior: "annotated_fraction returns 1.0 when every counted spec was annotated", layer: "unit" }
    it "is 1.0 when every counted spec was annotated" do
      run = repository.test_runs.create!(commit_sha: "abc123", annotated_specs_count: 7,
                                         total_specs_count: 7)

      expect(run.annotated_fraction).to eq(1.0)
    end

    # The zero-denominator honesty rule, and the reason it is written on the DENOMINATOR. A guard
    # placed on the numerator or on the result would pass both examples below and still turn a
    # genuinely measured zero share into `nil` — so the `0` of `5` case is pinned right beside them.
    # @intent: { entity: "TestRun", action: "return nil with no counted specs", behavior: "an empty run yields nil from annotated_fraction, distinguishing an unmeasured share from a measured zero", layer: "unit" }
    it "is nil, not 0.0, for a run that counted no specs" do
      run = repository.test_runs.create!(commit_sha: "abc123")

      expect(run.annotated_fraction).to be_nil
    end

    # @intent: { entity: "TestRun", action: "return nil for unwritten counters", behavior: "nil counters also produce nil from annotated_fraction, keeping the zero-denominator honesty rule on the denominator", layer: "unit" }
    it "is nil when the counters were never written at all" do
      run = repository.test_runs.create!(commit_sha: "abc123", annotated_specs_count: nil,
                                         total_specs_count: nil)

      expect(run.annotated_fraction).to be_nil
    end

    # @intent: { entity: "TestRun", action: "keep a measured zero share", behavior: "0 annotated of 5 counted returns the Float 0.0, so a genuinely measured zero is never collapsed into the nil absence", layer: "unit" }
    it "is a measured 0.0 when specs were counted and none of them were annotated" do
      run = repository.test_runs.create!(commit_sha: "abc123", annotated_specs_count: 0,
                                         total_specs_count: 5)

      expect(run.annotated_fraction).to eq(0.0)
      expect(run.annotated_fraction).to be_a(Float)
    end

    # The percentage keeps its own `0.0` floor deliberately — it feeds a rendered meter, not a JSON
    # contract. Pinned here so the two are not "fixed" into agreement by a later reader.
    # @intent: { entity: "TestRun", action: "leave the ratio's zero floor alone", behavior: "the same empty run still gets 0.0 from annotated_ratio, pinning that the two seams deliberately disagree about the zero case", layer: "unit" }
    it "leaves #annotated_ratio's 0.0 floor alone" do
      run = repository.test_runs.create!(commit_sha: "abc123")

      expect(run.annotated_ratio).to eq(0.0)
    end
  end

  # The one formatting seam over `duration_seconds`. Both surfaces that render the column go
  # through it, so what it decides here is what the page shows in both places.
  describe "#duration_label" do
    def run_lasting(seconds)
      repository.test_runs.create!(commit_sha: "abc123", duration_seconds: seconds)
    end

    # @intent: { entity: "TestRun", action: "format sub-minute durations with a tenth", behavior: "duration_label keeps one decimal in raw seconds for runs under a minute, from 12.5s down to 1.0s", layer: "unit" }
    it "keeps the tenth for a suite that finished inside a minute" do
      expect(run_lasting(12.5).duration_label).to eq("12.5s")
      expect(run_lasting(1.0).duration_label).to eq("1.0s")
    end

    # The headline case: `372.4s` is a true number nobody reads as "six minutes".
    # @intent: { entity: "TestRun", action: "read longer runs in minutes and seconds", behavior: "a run over a minute renders as m/s parts — 372.4 seconds becomes 6m 12s — while 59.4 stays in seconds and exactly one minute becomes 1m", layer: "unit" }
    it "reads a longer run in minutes and seconds rather than raw seconds" do
      expect(run_lasting(372.4).duration_label).to eq("6m 12s")
      expect(run_lasting(59.4).duration_label).to eq("59.4s")
      expect(run_lasting(60.0).duration_label).to eq("1m")
    end

    # @intent: { entity: "TestRun", action: "read hour-plus runs in three parts", behavior: "durations at or over an hour render as h/m/s, with 1h 0m for the exact hour and trailing seconds dropped only when zero", layer: "unit" }
    it "reads a run over an hour in hours, minutes and seconds" do
      expect(run_lasting(3600.0).duration_label).to eq("1h 0m")
      expect(run_lasting(3612.0).duration_label).to eq("1h 0m 12s")
      expect(run_lasting(7325.0).duration_label).to eq("2h 2m 5s")
    end

    # The minute boundary, both sides of it. Rounding to the tenth AFTER choosing the sub-minute
    # branch would print `59.96` as `60.0s` — a string this format can otherwise never produce,
    # in the raw-seconds shape the h/m/s branch exists to retire, at the exact value where it
    # decided raw seconds stop being legible. So the branch is taken on the rounded value.
    # @intent: { entity: "TestRun", action: "branch on the rounded duration", behavior: "59.96 seconds renders as 1m rather than the impossible 60.0s, because the sub-minute branch is chosen after rounding to the tenth", layer: "unit" }
    it "does not print a rounded-up minute as raw seconds" do
      expect(run_lasting(59.96).duration_label).to eq("1m")
      expect(run_lasting(59.94).duration_label).to eq("59.9s")
      expect(run_lasting(59.96).duration_label).not_to eq("60.0s")
    end

    # A zero minute that sits between two non-zero parts has to survive: dropping it turns
    # "one hour and twelve seconds" into a string that reads as "one hour twelve minutes".
    # @intent: { entity: "TestRun", action: "keep a zero minutes part between hours and seconds", behavior: "3612 seconds renders as 1h 0m 12s so the dropped zero cannot be misread as one hour twelve minutes", layer: "unit" }
    it "keeps a zero minutes part when there are hours in front of it" do
      expect(run_lasting(3612.0).duration_label).not_to eq("1h 12s")
    end

    # `duration_seconds` is nullable and Ingest::Payload accepts nil explicitly, so "the client
    # sent no timing" is a state the column can be in — and it is not "the run took no time".
    # @intent: { entity: "TestRun", action: "distinguish a missing timing from zero", behavior: "a nil duration_seconds renders as 'not reported', leaves duration_reported? false, and never prints as 0.0s", layer: "unit" }
    it "says a missing timing was not reported rather than calling it zero" do
      run = run_lasting(nil)

      expect(run.duration_label).to eq("not reported")
      expect(run.duration_label).not_to eq("0.0s")
      expect(run).not_to be_duration_reported
    end

    # The other half of that distinction, and the reason `duration_reported?` asks `nil?` rather
    # than `present?`: a genuinely measured zero is a measurement and must print as one.
    # @intent: { entity: "TestRun", action: "print a measured zero as zero", behavior: "a genuinely measured 0.0 duration renders 0.0s with duration_reported? true, the opposite half of the nil distinction", layer: "unit" }
    it "prints a run that genuinely measured zero as zero" do
      run = run_lasting(0.0)

      expect(run.duration_label).to eq("0.0s")
      expect(run).to be_duration_reported
    end
  end

  # The SUM over a run's shards, and the seam that lets a caller holding a WINDOW of runs hand it
  # in from one grouped aggregate instead of paying a `pick` per row (`ShardCountPreloading`, for
  # the repositories grid). These are the two states the request specs cannot separate cheaply and
  # that the sibling count seams get wrong by design: an absence, and a measured zero.
  describe "#machine_seconds and its preload seam" do
    # `queries_against` is the shared subscriber in `spec/support/query_capture.rb`, the same one
    # the repositories grid's budget guard counts with. One subscriber for both levels of the same
    # guard: there it bounds what a PAGE asks across a window of rows, here what ONE primed row asks.

    def run_with_shards(*durations)
      run = repository.test_runs.create!(commit_sha: "machinesecs0", ci_run_id: "gha-machine",
                                         duration_seconds: durations.compact.max)
      durations.each_with_index do |seconds, index|
        run.test_run_shards.create!(shard_id: (index + 1).to_s, duration_seconds: seconds)
      end
      run
    end

    # @intent: { entity: "TestRun", action: "sum its shard durations", behavior: "machine_seconds adds the durations of every shard row that reported, 253.75 from four shards, and reports itself as measured", layer: "unit" }
    it "sums the shards that reported when nothing primed it" do
      run = run_with_shards(61.0, 58.5, 74.25, 60.0)

      expect(run.machine_seconds).to eq(253.75)
      expect(run).to be_machine_seconds_reported
    end

    # @intent: { entity: "TestRun", action: "answer a primed sum without querying", behavior: "after preload_machine_seconds the sum is served from memory with zero queries against test_run_shards", layer: "unit" }
    it "answers a primed sum without asking the shards" do
      run = run_with_shards(61.0, 58.5, 74.25, 60.0)
      primed = TestRun.find(run.id).preload_machine_seconds(253.75)

      queries = queries_against("test_run_shards") { expect(primed.machine_seconds).to eq(253.75) }

      expect(queries).to be_empty
    end

    # The seam returns the run so it can be chained behind the two count seams, which is how
    # `ShardCountPreloading` primes a row.
    # @intent: { entity: "TestRun", action: "return itself from the preload seam", behavior: "preload_machine_seconds returns the same run object so it can chain behind the count seams in ShardCountPreloading", layer: "unit" }
    it "returns the run so the three seams chain" do
      run = repository.test_runs.create!(commit_sha: "machinesecs1")

      expect(run.preload_machine_seconds(1.0)).to be(run)
    end

    # A run with no shard rows is absent from the grouped result entirely. That absence means "no
    # shard reported" and NOT the really-counted zero the two count seams turn it into — so the nil
    # is primed through unchanged, and it has to STICK: a truthiness memo would accept it and then
    # re-ask the database for it on the first read.
    # @intent: { entity: "TestRun", action: "hold a primed nil as an absence", behavior: "a primed nil sticks as nil across reads, keeps machine_seconds_reported? false and renders 'not reported', with no re-query of the shards table", layer: "unit" }
    it "holds a primed nil as an absence, without re-asking for it" do
      run = run_with_shards(61.0)
      primed = TestRun.find(run.id).preload_machine_seconds(nil)

      queries = queries_against("test_run_shards") do
        expect(primed.machine_seconds).to be_nil
        expect(primed).not_to be_machine_seconds_reported
        expect(primed.machine_seconds_label).to eq("not reported")
      end

      expect(queries).to be_empty
    end

    # And the state that absence is not. `0.0` is a measurement, so it keeps its type and renders
    # as the zero it is — never as the "not reported" a `present?` check would file it under.
    # @intent: { entity: "TestRun", action: "hold a primed zero as a measurement", behavior: "a primed 0.0 keeps its type and renders 0.0s with machine_seconds_reported? true, never filing under not reported", layer: "unit" }
    it "holds a primed zero as the measurement it is" do
      run = repository.test_runs.create!(commit_sha: "machinesecs2").preload_machine_seconds(0.0)

      expect(run.machine_seconds).to eq(0.0)
      expect(run).to be_machine_seconds_reported
      expect(run.machine_seconds_label).to eq("0.0s")
    end
  end

  # Whether a run's `total_specs_count` may be differenced against another run's. Both predicates
  # ask one question of one side of that subtraction — *is this a measurement of the whole suite?*
  # — and the Overview withholds its delta unless both sides answer yes.
  #
  # Runs are built through `Ingest::RunRecorder` wherever sharding is the point, not with
  # `test_run_shards.create!`. The whole defect these guard against is a shape the RECORDER
  # produces — `total_specs_count` re-derived as the SUM over the shards recorded so far — so a
  # fixture that writes the row and its shards by hand can build a half-delivered run that agrees
  # with itself in ways a real one never does, and the guard would be tested against fiction.
  describe "comparing one run's suite size against another's" do
    def ingest(shard_id:, ci_run_id:, total:, commit_sha: "abc1230000", branch: "main")
      Ingest::RunRecorder.record(
        repository,
        { commit_sha: commit_sha, branch: branch, ci_run_id: ci_run_id,
          total_specs_count: total, annotated_specs_count: 0, duration_seconds: 1.0 },
        shard_id: shard_id
      )
    end

    describe "#suite_size_measured?" do
      # @intent: { entity: "TestRun", action: "measure suite size from a positive count", behavior: "suite_size_measured? is true whenever total_specs_count holds a positive integer", layer: "unit" }
      it "is true for a run that counted tests" do
        expect(repository.test_runs.create!(commit_sha: "abc123", total_specs_count: 1)).to be_suite_size_measured
      end

      # The panel already words this state — "reported no tests at all… a fact about this run, not
      # about the suite" — and a delta taken against it would contradict that sentence two lines
      # above where it is printed.
      # @intent: { entity: "TestRun", action: "refuse suite size for a reported zero", behavior: "total_specs_count of 0 is a fact about the run, not a suite size, so suite_size_measured? is false", layer: "unit" }
      it "is false for a run that reported no tests" do
        expect(repository.test_runs.create!(commit_sha: "abc123", total_specs_count: 0))
          .not_to be_suite_size_measured
      end

      # The column is nullable (default `0`, no `null: false`). A NULL is "nothing was reported",
      # which is the answer a reported zero already gets — not a suite of unknown size that a
      # difference may be taken against.
      # @intent: { entity: "TestRun", action: "refuse suite size for a NULL count", behavior: "a NULL total_specs_count — a run nothing was reported for — is not measurable either and fails suite_size_measured?", layer: "unit" }
      it "is false for a run whose count is NULL, not a whole suite of growth" do
        run = repository.test_runs.create!(commit_sha: "abc123", total_specs_count: 0)
        run.update_columns(total_specs_count: nil)

        expect(run.reload).not_to be_suite_size_measured
      end
    end

    describe "#assembled_like?" do
      # The entire unsharded corpus: written once, never re-derived, always comparable.
      # @intent: { entity: "TestRun", action: "match two whole runs", behavior: "two unsharded runs each arrived in one piece, so assembled_like? is true and their counts may be differenced", layer: "unit" }
      it "is true for two runs that each arrived whole" do
        a = repository.test_runs.create!(commit_sha: "aaa111", total_specs_count: 10)
        b = repository.test_runs.create!(commit_sha: "bbb222", total_specs_count: 12)

        expect(a).to be_assembled_like(b)
      end

      # @intent: { entity: "TestRun", action: "match runs with equal shard counts", behavior: "two runs assembled from the same number of shard reports are assembled alike, and their 40-example delta is a real difference", layer: "unit" }
      it "is true for two runs assembled from the same number of shards" do
        4.times { |i| ingest(shard_id: i.to_s, ci_run_id: "gha-1", total: 5_000) }
        4.times { |i| ingest(shard_id: i.to_s, ci_run_id: "gha-2", total: 5_010, commit_sha: "def4560000") }

        yesterday, today = repository.test_runs.order(:id).to_a

        expect(today).to be_assembled_like(yesterday)
        expect(today.total_specs_count - yesterday.total_specs_count).to eq(40)
      end

      # The state the whole guard exists for, built the only way it actually occurs: shard 0 of
      # four has POSTed and the other three are still running. `latest_test_run` picks this row up
      # the instant it lands, because `created_at` is stamped by that first POST.
      # @intent: { entity: "TestRun", action: "refuse a run that is still arriving", behavior: "a sharded run with only one of four shards POSTed is not assembled like the complete one, blocking a phantom 14,990-example deletion", layer: "unit" }
      it "is false while a sharded run is still arriving" do
        4.times { |i| ingest(shard_id: i.to_s, ci_run_id: "gha-1", total: 5_000) }
        ingest(shard_id: "0", ci_run_id: "gha-2", total: 5_010, commit_sha: "def4560000")

        yesterday, in_flight = repository.test_runs.order(:id).to_a

        expect(in_flight.shard_count).to eq(1)
        expect(yesterday.shard_count).to eq(4)
        expect(in_flight).not_to be_assembled_like(yesterday)
        # What the Overview would have printed without the guard, stated so the number is on the
        # record rather than implied: a deletion of three quarters of the suite that no commit made.
        expect(in_flight.total_specs_count - yesterday.total_specs_count).to eq(-14_990)
      end

      # The persistent form. A job cancelled after two of four shards leaves a half-sized row in
      # the history forever, and the NEXT complete run would read the missing half as growth.
      # @intent: { entity: "TestRun", action: "refuse a part-cancelled run", behavior: "a run cancelled after two of four shards stays permanently unalike the next complete run, whose 10,000 delta is missing half a suite, not growth", layer: "unit" }
      it "is false against a run that was cancelled part-way through" do
        2.times { |i| ingest(shard_id: i.to_s, ci_run_id: "gha-1", total: 5_000) }
        4.times { |i| ingest(shard_id: i.to_s, ci_run_id: "gha-2", total: 5_000, commit_sha: "def4560000") }

        cancelled, complete = repository.test_runs.order(:id).to_a

        expect(complete).not_to be_assembled_like(cancelled)
        expect(complete.total_specs_count - cancelled.total_specs_count).to eq(10_000)
      end

      # A laptop `bundle exec rspec` sitting beside a sharded CI run. Both may well be complete,
      # but nothing in the payload says so — `Ingest::Payload` accepts a shard *index* and never a
      # total — so the honest answer is that they are not known to be the same measurement.
      # @intent: { entity: "TestRun", action: "refuse an unsharded against a sharded run", behavior: "a laptop run beside a sharded CI run is not known to be the same measurement, so assembled_like? is false", layer: "unit" }
      it "is false for an unsharded run against a sharded one" do
        4.times { |i| ingest(shard_id: i.to_s, ci_run_id: "gha-1", total: 5_000) }
        laptop = repository.test_runs.create!(commit_sha: "def456", branch: "main", total_specs_count: 20_000)

        expect(laptop).not_to be_assembled_like(repository.test_runs.find_by(ci_run_id: "gha-1"))
      end
    end

    # The phrase a sentence names a run's composition by when two runs disagree. Zero shards is not
    # "0 reports" — it is a run that arrived whole, and wording it as a count of parts would read
    # as a delivery that lost all of them.
    describe "#delivery_description" do
      # @intent: { entity: "TestRun", action: "describe a whole run", behavior: "a run with no shard rows is described as reported in one piece, not as a delivery that lost all its parts", layer: "unit" }
      it "says a run arrived whole when it recorded no shards" do
        expect(repository.test_runs.create!(commit_sha: "abc123").delivery_description)
          .to eq("reported in one piece")
      end

      # @intent: { entity: "TestRun", action: "count one shard singularly", behavior: "delivery_description says 'assembled from 1 shard report' for a single-shard run", layer: "unit" }
      it "counts the parts, singular at one" do
        ingest(shard_id: "0", ci_run_id: "gha-1", total: 5_000)

        expect(repository.test_runs.last.delivery_description).to eq("assembled from 1 shard report")
      end

      # @intent: { entity: "TestRun", action: "count shards plurally", behavior: "delivery_description pluralises to 'assembled from 4 shard reports' once more than one shard reported", layer: "unit" }
      it "counts the parts, plural above one" do
        4.times { |i| ingest(shard_id: i.to_s, ci_run_id: "gha-1", total: 5_000) }

        expect(repository.test_runs.last.delivery_description).to eq("assembled from 4 shard reports")
      end
    end
  end

  # The state `#suite_size_measured?` above cannot express, and the reason this predicate exists:
  # `Ingest::ObservationPruner` deletes `spec_observations` and never deletes the owning run, so a
  # pruned run keeps answering off its own untouched counters while every per-example rollup goes
  # empty — byte-identically to a run that genuinely recorded nothing.
  #
  # Every example here is about the RULE and never about row counts. Nothing below creates or
  # deletes a single observation, deliberately: `Ingest::QuietBucketPruner` is opportunistic and
  # names its own permanently unreachable remainder, so a past-boundary run may still physically
  # hold rows, and an example asserting zero rows for one would be wrong on exactly the population
  # that pruner exists for.
  describe "#observations_retained?" do
    # `created_at` is explicit on every run, one minute apart, for `Ingest::ObservationPruner`'s own
    # reason: the boundary is `(created_at, id)`, and runs created inside the same millisecond would
    # order by id alone — true, but it would stop these examples saying anything about the timestamp
    # half of the comparison.
    def history(branch:, count:, from: 100.days.ago)
      (0...count).map do |index|
        create_test_run(repository: repository, branch: branch, created_at: from + index.minutes,
                        total_specs_count: 1)
      end
    end

    describe "the window it reports" do
      before { stub_const("SpecObservation::BRANCH_RETENTION_RUNS", 3) }

      # The boundary run is the Nth and the Nth is RETAINED, mirroring the pruner's strict `<`. An
      # off-by-one here would disclose a whole run of history as aged out a run early — or, worse,
      # report a genuinely emptied run as retained.
      # @intent: { entity: "TestRun", action: "age out only runs past the R-run window", behavior: "exactly the R most recent runs of the branch report observations_retained? true while older ones turn false, mirroring the pruner's strict boundary", layer: "unit" }
      it "reports the R most recent runs of the branch as retained and everything older as aged out" do
        runs = history(branch: "main", count: 5)

        expect(runs.map(&:observations_retained?)).to eq([false, false, true, true, true])
      end

      # The pruner's own "nothing to do" case: a nil boundary, which is every branch of every
      # repository until it has run R times.
      # @intent: { entity: "TestRun", action: "retain everything before the window fills", behavior: "a branch with fewer than R runs has no boundary, so every run reports retained", layer: "unit" }
      it "reports every run as retained on a branch that has run fewer than R times" do
        runs = history(branch: "main", count: 2)

        expect(runs.map(&:observations_retained?)).to all(be(true))
      end

      # Exactly R runs is the nil-boundary case too — `offset(R - 1)` picks the last row rather
      # than running off the end — and it is the normal state of a branch that has just filled its
      # window, not an edge case.
      # @intent: { entity: "TestRun", action: "retain everything at exactly R runs", behavior: "a branch holding exactly R runs still has a nil boundary, so all runs report retained rather than aging the oldest out", layer: "unit" }
      it "reports every run as retained on a branch holding exactly R runs" do
        runs = history(branch: "main", count: 3)

        expect(runs.map(&:observations_retained?)).to all(be(true))
      end
    end

    # ⭐ The keying the rule is built on, asked of the DISCLOSURE. Recency across a repository is
    # interleaved, so a predicate keyed on "the last N runs of this repository" would report
    # `main`'s history as aged out first — and `main` is what every cross-run read is anchored to.
    describe "branch keying" do
      before { stub_const("SpecObservation::BRANCH_RETENTION_RUNS", 3) }

      # @intent: { entity: "TestRun", action: "bucket each branch independently", behavior: "interleaved runs from eight feature branches do not age out main's history, because recency is counted per branch", layer: "unit" }
      it "buckets each branch on its own though the other's runs are interleaved among them" do
        start = 100.days.ago
        main = (0...3).map do |i|
          create_test_run(repository: repository, branch: "main", created_at: start + (i * 10).minutes,
                          total_specs_count: 1)
        end
        features = (0...8).map do |i|
          create_test_run(repository: repository, branch: "feature/#{i}",
                          created_at: start + ((i * 3) + 1).minutes, total_specs_count: 1)
        end

        expect(main.map(&:observations_retained?)).to all(be(true))
        expect(features.map(&:observations_retained?)).to all(be(true))
      end

      # `branch: nil` compiles to `branch IS NULL` — its own bucket, exactly as
      # `Ingest::ObservationPruner#branch_runs` treats it, and NOT a bucket every unnamed run shares
      # with the named ones. Pinned from both sides at once: the named branch is past its boundary
      # while the anonymous bucket, holding fewer runs, is entirely inside its own.
      # @intent: { entity: "TestRun", action: "bucket unnamed runs apart", behavior: "branch-less runs form their own IS NULL bucket, retained while the same repository's named branch is past its boundary", layer: "unit" }
      it "buckets the runs that named no branch on their own, apart from a named branch past its boundary" do
        start = 100.days.ago
        named = history(branch: "main", count: 5, from: start)
        anonymous = (0...2).map do |i|
          create_test_run(repository: repository, branch: nil, created_at: start + ((i * 7) + 2).minutes,
                          total_specs_count: 1)
        end

        expect(named.map(&:observations_retained?)).to eq([false, false, true, true, true])
        expect(anonymous.map(&:observations_retained?)).to all(be(true))
      end

      # One repository's runs never bound another's, on the branch every repository has.
      # @intent: { entity: "TestRun", action: "scope retention to one repository", behavior: "another repository's many runs never bound this one's, even on the shared 'main' branch name", layer: "unit" }
      it "scopes the bucket to one repository" do
        other = create_repository(user: create_user(github_uid: "2002", github_handle: "hubot"),
                                  github_full_name: "acme/other-service")
        start = 100.days.ago
        4.times do |i|
          create_test_run(repository: other, branch: "main", created_at: start + i.minutes, total_specs_count: 1)
        end
        mine = history(branch: "main", count: 2, from: start)

        expect(mine.map(&:observations_retained?)).to all(be(true))
      end
    end

    # ⭐ THE PROPERTY THE WHOLE DESIGN RESTS ON. The disclosure derives its boundary from the
    # pruner's own spelling rather than from a marker column precisely so the two cannot disagree —
    # so this asserts the two boundaries AGREE, at a stubbed constant, over the same
    # `(repository, branch)`. Lowering `BRANCH_RETENTION_RUNS` cannot move one without the other,
    # and a divergence would mean the endpoint publishing a rule the enforcement does not follow.
    describe "agreement with the pruner that enforces the rule" do
      before { stub_const("SpecObservation::BRANCH_RETENTION_RUNS", 3) }

      # @intent: { entity: "TestRun", action: "agree with the pruner's boundary", behavior: "the retained set is exactly the runs at or after Ingest::ObservationPruner's own oldest-retained boundary, both directions of the strict comparison, for exactly R runs", layer: "unit" }
      it "draws its boundary where Ingest::ObservationPruner draws its own" do
        runs = history(branch: "main", count: 6)

        # The pruner's boundary, read through the object that enforces it rather than re-spelled.
        pruner = Ingest::ObservationPruner.new(repository_id: repository.id, branch: "main")
        boundary = pruner.send(:oldest_retained_run)

        aged_out, retained = runs.partition { |run| !run.observations_retained? }

        # Every run the predicate calls retained is at or after the pruner's boundary; every run it
        # calls aged out is strictly before it — which is the pruner's own strict `<`.
        expect(retained).to all(satisfy { |run| ([run.created_at, run.id] <=> boundary) >= 0 })
        expect(aged_out).to all(satisfy { |run| ([run.created_at, run.id] <=> boundary).negative? })
        expect(retained.length).to eq(SpecObservation::BRANCH_RETENTION_RUNS)
      end

      # The same agreement observed through the pruner's ACTUAL EFFECT rather than through its
      # private boundary: the runs it really empties are exactly the ones the predicate reports as
      # aged out. This is allowed to count rows — it is an assertion about `ObservationPruner`,
      # which is not opportunistic and does delete on the branch it is handed.
      # @intent: { entity: "TestRun", action: "match the runs a prune empties", behavior: "after a real prune the runs whose observations were deleted are exactly the ones the predicate reported aged out", layer: "unit" }
      it "reports as aged out exactly the runs a prune on that branch empties" do
        runs = history(branch: "main", count: 5)
        runs.each do |run|
          run.spec_observations.create!(
            repository: repository, file_path: "spec/models/a_spec.rb", line_number: 1,
            status: "unannotated", example_id: "./spec/models/a_spec.rb[1:1]"
          )
        end

        predicted_aged_out = runs.reject(&:observations_retained?)

        Ingest::ObservationPruner.prune(runs.last)

        emptied = runs.select { |run| run.spec_observations.count.zero? }

        expect(emptied.map(&:id)).to eq(predicted_aged_out.map(&:id))
        expect(emptied).not_to be_empty
      end
    end

    # The constant is not stubbed here: the predicate has to be right at the shipping value, and a
    # branch nowhere near 60 runs is the ordinary state of every repository.
    # @intent: { entity: "TestRun", action: "retain at the shipping retention bound", behavior: "with BRANCH_RETENTION_RUNS unstubbed, a young branch's few runs all report retained, the ordinary state of every repository", layer: "unit" }
    it "reports a young branch's runs as retained at the real retention bound" do
      runs = history(branch: "main", count: 3)

      expect(SpecObservation::BRANCH_RETENTION_RUNS).to be > 3
      expect(runs.map(&:observations_retained?)).to all(be(true))
    end
  end

  # The denominator each shard's duration was measured over. `test_run_shards.total_specs_count`
  # was written by `Ingest::RunRecorder#upsert_shard` on every sharded POST since sharding shipped
  # and read by nothing, so the panel could show four wall clocks and no way to tell a shard that
  # ran long because it held four times the tests from one that held the same tests four times
  # dearer. These are the shapes the request specs cannot reach cheaply: a set with no mean, a
  # suite too fast for the tenth of a millisecond, and the ordering contract the API depends on.
  describe "each shard's test count beside its duration" do
    def sharded_run(rows, commit_sha: "shardedrun00")
      run = repository.test_runs.create!(commit_sha: commit_sha, ci_run_id: "gha-#{commit_sha}",
                                         total_specs_count: rows.sum { |row| row[:total] },
                                         duration_seconds: rows.filter_map { |row| row[:seconds] }.max)
      rows.each_with_index do |row, index|
        run.test_run_shards.create!(shard_id: row.fetch(:name, (index + 1).to_s),
                                    total_specs_count: row[:total], duration_seconds: row[:seconds])
      end
      run
    end

    # APPENDED, never prepended. `#longest_shard_label` reads `shard_durations.first&.first` and
    # `#shard_distribution_labels` binds the tuple positionally — `|(shard_id, seconds,
    # spec_count), rate|`, the inner parentheses being the zip against `#shard_seconds_per_spec`
    # rather than a change of order — so a count in position 0 would make the panel name a number
    # as a shard. Pinned as the whole tuple rather than as "includes the count", which a reordered
    # pluck would also satisfy.
    # @intent: { entity: "TestRun", action: "rank shards with counts as third element", behavior: "shard_durations returns [id, seconds, count] tuples slowest-first so positional labels name a shard and not a number", layer: "unit" }
    it "carries the count as the third element, slowest first" do
      run = sharded_run([{ total: 5000, seconds: 61.0 }, { total: 4000, seconds: 74.25 }])

      expect(run.shard_durations).to eq([["2", 74.25, 4000], ["1", 61.0, 5000]])
      expect(run.longest_shard_label).to eq("shard 2")
    end

    # `#shard_reports` is the same three columns UNRANKED, and the ordering is the entire reason it
    # is a separate method: `#shard_durations` sorts `duration_seconds: :desc`, which is NULLS
    # FIRST in Postgres, so on a run with a silent shard its head is the shard that reported
    # nothing. `GET /api/v1/repository` gates on `multi_shard?` alone and would serve that row at
    # the top of a list a client reads as slowest-first.
    # @intent: { entity: "TestRun", action: "serve unranked reports to ungated callers", behavior: "shard_reports keeps delivery order with counts appended, so a silent NULL-duration shard that would head the ranked read sits in its own place", layer: "unit" }
    it "serves an unranked delivery-ordered tuple for callers that are not behind the gate" do
      run = sharded_run([{ total: 5000, seconds: 61.0 }, { total: 4000, seconds: nil },
                         { total: 3000, seconds: 74.25 }])

      expect(run.shard_reports).to eq([["1", 61.0, 5000], ["2", nil, 4000], ["3", 74.25, 3000]])
      # The hazard, stated as the difference between the two: the silent shard heads the ranked
      # read and sits in its own place in the unranked one.
      expect(run.shard_durations.first).to eq(["2", nil, 4000])
    end

    # A shard that loaded no specs is a real row — the column is `null: false, default: 0` — with a
    # wall clock and no denominator. No division happens and no zero stands in for the quotient.
    # @intent: { entity: "TestRun", action: "withhold cost from a testless shard", behavior: "a shard with zero tests gets nil instead of a rate, is counted as unsized, and renders 'no tests reported' rather than dividing by zero", layer: "unit" }
    it "withholds a per-test cost from a shard that reported no tests" do
      run = sharded_run([{ total: 5000, seconds: 61.0 }, { total: 0, seconds: 3.5 }])

      expect(run.shard_seconds_per_spec).to eq([0.0122, nil])
      expect(run.unsized_shard_count).to eq(1)
      expect(run).not_to be_every_shard_costed
      expect(run.shard_distribution_labels.last).to eq(["shard 2", "3.5s", "no tests reported", nil])
    end

    # The other way `#every_shard_costed?` goes false, pinned as the DIFFERENT fact it is. Both a
    # zero count and a null duration leave a shard with no rate, so both sink the predicate — but
    # only the first is what `#unsized_shard_count` counts, and the panel's zero-denominator
    # sentence quotes that count as its own evidence. Wiring the sentence to the predicate instead
    # would render "0 of these 2 shards reported no tests at all" on exactly this run.
    #
    # Unreachable from the panel — `#wall_clock_decomposable?` withholds the whole decomposition on
    # `#some_shard_untimed?` — which is why it is pinned here, on the model, where the gate is not
    # in the way. This is the assertion that fails if the two are ever fused back together.
    # @intent: { entity: "TestRun", action: "distinguish an untimed shard from an unsized one", behavior: "a NULL-duration shard also sinks every_shard_costed? but adds nothing to unsized_shard_count, keeping the zero-denominator sentence honest", layer: "unit" }
    it "has no per-test cost for an untimed shard either, and does not call that shard unsized" do
      run = sharded_run([{ total: 5000, seconds: 61.0 }, { total: 4000, seconds: nil }])

      expect(run).not_to be_every_shard_costed
      expect(run.unsized_shard_count).to eq(0)
      expect(run.untimed_shard_count).to eq(1)
    end

    # ...and the spread that would have been taken over the rest is withheld with it, rather than
    # computed over a subset and described as the run's. The COUNT spread survives — a zero is a
    # real count — which is why the two are separate figures and not one.
    # @intent: { entity: "TestRun", action: "withhold the per-test spread without denominators", behavior: "an unsized shard makes seconds_per_spec_spread_percent nil while the count spread, computable from real counts, still reads 200.0", layer: "unit" }
    it "withholds the per-test spread when any shard has no denominator" do
      run = sharded_run([{ total: 5000, seconds: 61.0 }, { total: 0, seconds: 3.5 }])

      expect(run.seconds_per_spec_spread_percent).to be_nil
      expect(run).not_to be_seconds_per_spec_spread_material
      expect(run.spec_count_spread_percent).to eq(200.0)
    end

    # `nil`, never `0.0`, when there is no mean to divide by. A run whose shards all reported zero
    # tests has no dispersion TO measure, and a computed 0% would let "the shards are evenly sized"
    # be said about shards that reported nothing at all.
    # @intent: { entity: "TestRun", action: "return nil spreads with no mean", behavior: "all-zero shard counts yield nil count spread so 'evenly sized' cannot be claimed about shards that reported nothing", layer: "unit" }
    it "has no count spread at all when every shard reported zero tests" do
      run = sharded_run([{ total: 0, seconds: 61.0 }, { total: 0, seconds: 58.5 }])

      expect(run.spec_count_spread_percent).to be_nil
      expect(run).not_to be_spec_count_spread_material
      expect(run.seconds_per_spec_spread_percent).to be_nil
    end

    # Three magnitudes, three units. `humanized_seconds` is right for the three run-level figures
    # that sit within a few lines of each other and wrong here: `74.25 / 5000` through it prints
    # `0.0s`, a computed zero on the panel whose rule is that a figure it cannot stand behind is
    # withheld with its reason rather than rounded away.
    # @intent: { entity: "TestRun", action: "pick the resolving cost unit", behavior: "the per-test cost renders in s/test, ms/test or 'under 0.1ms/test' according to magnitude, never rounding a measurable cost to a computed zero", layer: "unit" }
    it "states a per-test cost in the unit that resolves it" do
      seconds_each = sharded_run([{ total: 8, seconds: 61.0 }], commit_sha: "slowsuite000")
      millis_each = sharded_run([{ total: 5000, seconds: 74.25 }], commit_sha: "unitsuite000")
      # 100,000 examples in 4 seconds is 40 microseconds each — below what a tenth of a
      # millisecond resolves, so it states a bound instead of rounding to `0.0ms/test`.
      micros_each = sharded_run([{ total: 100_000, seconds: 4.0 }], commit_sha: "fastsuite000")

      expect(seconds_each.shard_distribution_labels.first.last).to eq("7.6s/test")
      expect(millis_each.shard_distribution_labels.first.last).to eq("14.9ms/test")
      expect(micros_each.shard_distribution_labels.first.last).to eq("under 0.1ms/test")
    end

    # The two spreads are separately computable from the same tuple, and a run can have one
    # without the other — which is the whole point, since they take opposite actions.
    # @intent: { entity: "TestRun", action: "separate count-driven from cost-driven spread", behavior: "identical counts with differing durations yield only a cost spread, identical per-test costs with differing counts yield only a count spread", layer: "unit" }
    it "separates a count-driven spread from a cost-driven one" do
      cost_driven = sharded_run([{ total: 5000, seconds: 74.25 }, { total: 5000, seconds: 58.5 }],
                                commit_sha: "costdriven00")
      count_driven = sharded_run([{ total: 6000, seconds: 72.0 }, { total: 4800, seconds: 57.6 }],
                                 commit_sha: "countdriven0")

      expect(cost_driven.spec_count_spread_percent).to eq(0.0)
      expect(cost_driven).to be_seconds_per_spec_spread_material
      expect(cost_driven).not_to be_spec_count_spread_material

      # Identical 12.0ms/test on both shards: every second of this run's spread is the split.
      expect(count_driven.seconds_per_spec_spread_percent).to eq(0.0)
      expect(count_driven).to be_spec_count_spread_material
      expect(count_driven).not_to be_seconds_per_spec_spread_material
    end
  end

  # The database half of the run-identity invariant. `Ingest::RunRecorder` looks a run up before
  # inserting, but a lookup and an insert are two statements and four shards POST at once — the
  # index is what makes the loser of that race an exception to rescue rather than a second row
  # with half the suite in it.
  describe "the run identity" do
    # @intent: { entity: "TestRun", action: "refuse a duplicate CI run per repository", behavior: "a second row with the same (repository, ci_run_id) raises RecordNotUnique, making the insert race safe", layer: "unit" }
    it "refuses a second row for a run this repository has already recorded" do
      repository.test_runs.create!(commit_sha: "deadbee", ci_run_id: "gha-42")

      expect { repository.test_runs.create!(commit_sha: "deadbee", ci_run_id: "gha-42") }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    # @intent: { entity: "TestRun", action: "allow the same CI id across repositories", behavior: "two repositories can each record the same ci_run_id, so the uniqueness is scoped per repository", layer: "unit" }
    it "lets two repositories record the same CI run id" do
      other = create_repository(user: create_user(github_uid: "2002", github_handle: "hubot"),
                                github_full_name: "acme/ledger")
      repository.test_runs.create!(commit_sha: "deadbee", ci_run_id: "gha-42")

      expect { other.test_runs.create!(commit_sha: "deadbee", ci_run_id: "gha-42") }
        .to change(TestRun, :count).by(1)
    end

    # The local path the roadmap's DoD protects: a laptop `bundle exec rspec` has no CI variables
    # to read, so every one of its runs is unnamed and every one still gets a row of its own.
    # @intent: { entity: "TestRun", action: "allow unlimited unnamed runs", behavior: "runs with a nil ci_run_id — every laptop rspec invocation — never collide and each get their own row", layer: "unit" }
    it "lets a repository record any number of runs that no CI provider named" do
      expect do
        3.times { repository.test_runs.create!(commit_sha: "deadbee", ci_run_id: nil) }
      end.to change(TestRun, :count).by(3)
    end
  end
end
