# frozen_string_literal: true

require "rails_helper"

RSpec.describe TestRun do
  let(:repository) { create_repository }

  it "requires the commit it ran against" do
    run = repository.test_runs.new(commit_sha: nil)

    expect(run).not_to be_valid
    expect(run.errors[:commit_sha]).to be_present
  end

  it "belongs to a repository" do
    run = TestRun.new(commit_sha: "abc123")

    expect(run).not_to be_valid
    expect(run.errors[:repository]).to be_present
  end

  describe "#annotated_ratio" do
    it "is 0.0 for a run that counted no specs" do
      run = repository.test_runs.create!(commit_sha: "abc123")

      expect(run.total_specs_count).to eq(0)
      expect(run.annotated_ratio).to eq(0.0)
      expect(run.annotated_ratio).to be_a(Float)
    end

    it "is 0.0 when the counters were never written at all" do
      run = repository.test_runs.create!(commit_sha: "abc123", annotated_specs_count: nil,
                                         total_specs_count: nil)

      expect(run.annotated_ratio).to eq(0.0)
      expect(run.annotated_ratio).to be_a(Float)
    end

    it "reports the share of counted specs that were annotated, to one decimal" do
      run = repository.test_runs.create!(commit_sha: "abc123", annotated_specs_count: 2,
                                         total_specs_count: 3)

      expect(run.annotated_ratio).to eq(66.7)
    end

    it "is 100.0 when every counted spec was annotated" do
      run = repository.test_runs.create!(commit_sha: "abc123", annotated_specs_count: 7,
                                         total_specs_count: 7)

      expect(run.annotated_ratio).to eq(100.0)
    end

    # Both ratios read the same counters now, so this is a real agreement rather than the old
    # coincidence: it used to hold only because a factory fabricated a `status: "unannotated"`
    # spec_intent, which the four NOT NULL intent columns make impossible for ingestion to write.
    it "agrees with the repository-wide ratio it is the source of" do
      run = repository.test_runs.create!(commit_sha: "abc123", annotated_specs_count: 2,
                                         total_specs_count: 3)
      create_spec_intent(repository: repository, line_number: 1, test_run: run)
      create_spec_intent(repository: repository, line_number: 2, test_run: run)

      expect(run.annotated_ratio).to eq(66.7)
      expect(repository.annotated_ratio).to eq(run.annotated_ratio)
    end
  end

  describe "#annotated_fraction" do
    # The unit the /ingest API reports. Kept beside #annotated_ratio deliberately: the two differ
    # by 100×, and in a JSON body that gap is invisible until a client is already wrong by it.
    it "is the same share as a 0-1 fraction" do
      run = repository.test_runs.create!(commit_sha: "abc123", annotated_specs_count: 119,
                                         total_specs_count: 142)

      expect(run.annotated_fraction).to eq(0.838)
      expect(run.annotated_ratio).to eq(83.8)
    end

    it "rounds to three decimals" do
      run = repository.test_runs.create!(commit_sha: "abc123", annotated_specs_count: 2,
                                         total_specs_count: 3)

      expect(run.annotated_fraction).to eq(0.667)
    end

    it "is 1.0 when every counted spec was annotated" do
      run = repository.test_runs.create!(commit_sha: "abc123", annotated_specs_count: 7,
                                         total_specs_count: 7)

      expect(run.annotated_fraction).to eq(1.0)
    end

    it "is 0.0 for a run that counted no specs" do
      run = repository.test_runs.create!(commit_sha: "abc123")

      expect(run.annotated_fraction).to eq(0.0)
      expect(run.annotated_fraction).to be_a(Float)
    end

    it "is 0.0 when the counters were never written at all" do
      run = repository.test_runs.create!(commit_sha: "abc123", annotated_specs_count: nil,
                                         total_specs_count: nil)

      expect(run.annotated_fraction).to eq(0.0)
    end
  end

  # The one formatting seam over `duration_seconds`. Both surfaces that render the column go
  # through it, so what it decides here is what the page shows in both places.
  describe "#duration_label" do
    def run_lasting(seconds)
      repository.test_runs.create!(commit_sha: "abc123", duration_seconds: seconds)
    end

    it "keeps the tenth for a suite that finished inside a minute" do
      expect(run_lasting(12.5).duration_label).to eq("12.5s")
      expect(run_lasting(1.0).duration_label).to eq("1.0s")
    end

    # The headline case: `372.4s` is a true number nobody reads as "six minutes".
    it "reads a longer run in minutes and seconds rather than raw seconds" do
      expect(run_lasting(372.4).duration_label).to eq("6m 12s")
      expect(run_lasting(59.4).duration_label).to eq("59.4s")
      expect(run_lasting(60.0).duration_label).to eq("1m")
    end

    it "reads a run over an hour in hours, minutes and seconds" do
      expect(run_lasting(3600.0).duration_label).to eq("1h 0m")
      expect(run_lasting(3612.0).duration_label).to eq("1h 0m 12s")
      expect(run_lasting(7325.0).duration_label).to eq("2h 2m 5s")
    end

    # The minute boundary, both sides of it. Rounding to the tenth AFTER choosing the sub-minute
    # branch would print `59.96` as `60.0s` — a string this format can otherwise never produce,
    # in the raw-seconds shape the h/m/s branch exists to retire, at the exact value where it
    # decided raw seconds stop being legible. So the branch is taken on the rounded value.
    it "does not print a rounded-up minute as raw seconds" do
      expect(run_lasting(59.96).duration_label).to eq("1m")
      expect(run_lasting(59.94).duration_label).to eq("59.9s")
      expect(run_lasting(59.96).duration_label).not_to eq("60.0s")
    end

    # A zero minute that sits between two non-zero parts has to survive: dropping it turns
    # "one hour and twelve seconds" into a string that reads as "one hour twelve minutes".
    it "keeps a zero minutes part when there are hours in front of it" do
      expect(run_lasting(3612.0).duration_label).not_to eq("1h 12s")
    end

    # `duration_seconds` is nullable and Ingest::Payload accepts nil explicitly, so "the client
    # sent no timing" is a state the column can be in — and it is not "the run took no time".
    it "says a missing timing was not reported rather than calling it zero" do
      run = run_lasting(nil)

      expect(run.duration_label).to eq("not reported")
      expect(run.duration_label).not_to eq("0.0s")
      expect(run).not_to be_duration_reported
    end

    # The other half of that distinction, and the reason `duration_reported?` asks `nil?` rather
    # than `present?`: a genuinely measured zero is a measurement and must print as one.
    it "prints a run that genuinely measured zero as zero" do
      run = run_lasting(0.0)

      expect(run.duration_label).to eq("0.0s")
      expect(run).to be_duration_reported
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
      it "is true for a run that counted tests" do
        expect(repository.test_runs.create!(commit_sha: "abc123", total_specs_count: 1)).to be_suite_size_measured
      end

      # The panel already words this state — "reported no tests at all… a fact about this run, not
      # about the suite" — and a delta taken against it would contradict that sentence two lines
      # above where it is printed.
      it "is false for a run that reported no tests" do
        expect(repository.test_runs.create!(commit_sha: "abc123", total_specs_count: 0))
          .not_to be_suite_size_measured
      end

      # The column is nullable (default `0`, no `null: false`). A NULL is "nothing was reported",
      # which is the answer a reported zero already gets — not a suite of unknown size that a
      # difference may be taken against.
      it "is false for a run whose count is NULL, not a whole suite of growth" do
        run = repository.test_runs.create!(commit_sha: "abc123", total_specs_count: 0)
        run.update_columns(total_specs_count: nil)

        expect(run.reload).not_to be_suite_size_measured
      end
    end

    describe "#assembled_like?" do
      # The entire unsharded corpus: written once, never re-derived, always comparable.
      it "is true for two runs that each arrived whole" do
        a = repository.test_runs.create!(commit_sha: "aaa111", total_specs_count: 10)
        b = repository.test_runs.create!(commit_sha: "bbb222", total_specs_count: 12)

        expect(a).to be_assembled_like(b)
      end

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
      it "says a run arrived whole when it recorded no shards" do
        expect(repository.test_runs.create!(commit_sha: "abc123").delivery_description)
          .to eq("reported in one piece")
      end

      it "counts the parts, singular at one" do
        ingest(shard_id: "0", ci_run_id: "gha-1", total: 5_000)

        expect(repository.test_runs.last.delivery_description).to eq("assembled from 1 shard report")
      end

      it "counts the parts, plural above one" do
        4.times { |i| ingest(shard_id: i.to_s, ci_run_id: "gha-1", total: 5_000) }

        expect(repository.test_runs.last.delivery_description).to eq("assembled from 4 shard reports")
      end
    end
  end

  # The database half of the run-identity invariant. `Ingest::RunRecorder` looks a run up before
  # inserting, but a lookup and an insert are two statements and four shards POST at once — the
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
    # `#shard_distribution_labels` destructures `|shard_id, seconds, spec_count|`, so a count in
    # position 0 would make the panel name a number as a shard. Pinned as the whole tuple rather
    # than as "includes the count", which a reordered pluck would also satisfy.
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
    it "withholds a per-test cost from a shard that reported no tests" do
      run = sharded_run([{ total: 5000, seconds: 61.0 }, { total: 0, seconds: 3.5 }])

      expect(run.shard_seconds_per_spec).to eq([0.0122, nil])
      expect(run.unsized_shard_count).to eq(1)
      expect(run).not_to be_every_shard_sized
      expect(run.shard_distribution_labels.last).to eq(["shard 2", "3.5s", "no tests reported", nil])
    end

    # ...and the spread that would have been taken over the rest is withheld with it, rather than
    # computed over a subset and described as the run's. The COUNT spread survives — a zero is a
    # real count — which is why the two are separate figures and not one.
    it "withholds the per-test spread when any shard has no denominator" do
      run = sharded_run([{ total: 5000, seconds: 61.0 }, { total: 0, seconds: 3.5 }])

      expect(run.seconds_per_spec_spread_percent).to be_nil
      expect(run).not_to be_seconds_per_spec_spread_material
      expect(run.spec_count_spread_percent).to eq(200.0)
    end

    # `nil`, never `0.0`, when there is no mean to divide by. A run whose shards all reported zero
    # tests has no dispersion TO measure, and a computed 0% would let "the shards are evenly sized"
    # be said about shards that reported nothing at all.
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

  # index is what makes the loser of that race an exception to rescue rather than a second row
  # with half the suite in it.
  describe "the run identity" do
    it "refuses a second row for a run this repository has already recorded" do
      repository.test_runs.create!(commit_sha: "deadbee", ci_run_id: "gha-42")

      expect { repository.test_runs.create!(commit_sha: "deadbee", ci_run_id: "gha-42") }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "lets two repositories record the same CI run id" do
      other = create_repository(user: create_user(github_uid: "2002", github_handle: "hubot"),
                                github_full_name: "acme/ledger")
      repository.test_runs.create!(commit_sha: "deadbee", ci_run_id: "gha-42")

      expect { other.test_runs.create!(commit_sha: "deadbee", ci_run_id: "gha-42") }
        .to change(TestRun, :count).by(1)
    end

    # The local path the roadmap's DoD protects: a laptop `bundle exec rspec` has no CI variables
    # to read, so every one of its runs is unnamed and every one still gets a row of its own.
    it "lets a repository record any number of runs that no CI provider named" do
      expect do
        3.times { repository.test_runs.create!(commit_sha: "deadbee", ci_run_id: nil) }
      end.to change(TestRun, :count).by(3)
    end
  end
end
