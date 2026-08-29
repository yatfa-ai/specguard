# frozen_string_literal: true

require "rails_helper"

# The half of the retention rule `Ingest::ObservationPruner` cannot reach: buckets nothing is
# writing to any more. That class bounds the bucket of the run it is handed, so a merged
# `feature/*` branch stopped converging the moment it stopped receiving runs. Everything below is
# about WHICH other bucket an ingest picks, that the pick keeps moving, and that it never leaves
# the repository it started in.
RSpec.describe Ingest::QuietBucketPruner do
  let(:repository) { create_repository }

  def run_with_observations(repo: repository, branch:, at:, rows: 1)
    run = create_test_run(repository: repo, branch: branch, created_at: at, total_specs_count: rows)

    rows.times do |index|
      run.spec_observations.create!(
        repository: repo, file_path: "spec/models/a_spec.rb", line_number: index + 1,
        status: "unannotated", example_id: "./spec/models/a_spec.rb[1:#{index + 1}]"
      )
    end

    run
  end

  def history(branch:, count:, repo: repository, from: 100.days.ago, rows: 1)
    (0...count).map do |index|
      run_with_observations(repo: repo, branch: branch, at: from + index.minutes, rows: rows)
    end
  end

  def observation_counts(runs) = runs.map { |run| run.spec_observations.count }

  describe "the reach it adds" do
    before { stub_const("SpecObservation::BRANCH_RETENTION_RUNS", 2) }

    # ⭐ The whole ticket in one example. `feature/x` has received no run in this delivery and never
    # will again; the ingest lands on `main`; `feature/x`'s expired rows go anyway.
    # @intent: { entity: "Ingest::QuietBucketPruner", action: "drain a quiet branch", behavior: "an ingest on main deletes expired observations of feature/x even though that branch receives no runs in this delivery", layer: "integration" }
    it "reduces the expired rows of a branch this delivery did not touch" do
      quiet = history(branch: "feature/x", count: 5, from: 100.days.ago)
      live = history(branch: "main", count: 1, from: 1.hour.ago)

      described_class.drain(live.last)

      expect(observation_counts(quiet)).to eq([0, 0, 0, 1, 1])
    end

    # The reach is one bucket per invocation and not "every bucket but the live one" — the ceiling
    # is per invocation, and convergence comes from successive deliveries rather than from one.
    # @intent: { entity: "Ingest::QuietBucketPruner", action: "drain one bucket per invocation", behavior: "a single drain reduces exactly one other bucket, leaving a second equally expired bucket for later deliveries", layer: "integration" }
    it "drains one other bucket and not all of them" do
      first = history(branch: "feature/a", count: 5)
      second = history(branch: "feature/b", count: 5)
      live = history(branch: "main", count: 1, from: 1.hour.ago)

      described_class.drain(live.last)

      drained = [observation_counts(first), observation_counts(second)].count { |counts| counts.include?(0) }
      expect(drained).to eq(1)
    end

    # @intent: { entity: "Ingest::QuietBucketPruner", action: "skip the live branch", behavior: "the branch of the handed run is never drained here, staying the current-branch pruner's responsibility", layer: "integration" }
    it "leaves the branch the run is on to the current-branch half" do
      live = history(branch: "main", count: 5)

      expect { described_class.drain(live.last) }.not_to change { observation_counts(live) }
    end

    # "The anonymous runs of every machine are not one branch" — the branch-less bucket is a bucket
    # like any other, and `IS DISTINCT FROM` rather than `!=` is what keeps it reachable. A plain
    # `branch != 'main'` drops NULL rows by three-valued logic, so a laptop's history would be the
    # one population this pass could never see.
    # @intent: { entity: "Ingest::QuietBucketPruner", action: "pick the branch-less bucket", behavior: "NULL-branch runs are selectable via IS DISTINCT FROM semantics, so the anonymous bucket is drained like any named one", layer: "integration" }
    it "picks the branch-less bucket when that is the one over the rule" do
      anonymous = history(branch: nil, count: 5)
      live = history(branch: "main", count: 1, from: 1.hour.ago)

      described_class.drain(live.last)

      expect(observation_counts(anonymous)).to eq([0, 0, 0, 1, 1])
    end

    # And the same seam from the other side: an ingest on the anonymous bucket must still reach the
    # named ones. `where.not(branch: nil)` would be correct here by accident; the named case above
    # is the one that fails without `IS DISTINCT FROM`.
    # @intent: { entity: "Ingest::QuietBucketPruner", action: "drain a named bucket from an anonymous ingest", behavior: "an ingest on the branch-less bucket still reaches named quiet branches, proving the seam works both directions", layer: "integration" }
    it "drains a named bucket from an ingest on the branch-less one" do
      quiet = history(branch: "feature/x", count: 5)
      live = history(branch: nil, count: 1, from: 1.hour.ago)

      described_class.drain(live.last)

      expect(observation_counts(quiet)).to eq([0, 0, 0, 1, 1])
    end

    # @intent: { entity: "Ingest::QuietBucketPruner", action: "drain with no eligible bucket", behavior: "when no other bucket exceeds the retention rule the drain deletes nothing at all", layer: "integration" }
    it "does nothing when no other bucket is over the rule" do
      history(branch: "feature/x", count: 2)
      live = history(branch: "main", count: 1, from: 1.hour.ago)

      expect { described_class.drain(live.last) }.not_to change(SpecObservation, :count)
    end

    # @intent: { entity: "Ingest::QuietBucketPruner", action: "report deletions", behavior: "drain returns the count of observation rows it actually deleted", layer: "integration" }
    it "reports the rows it deleted" do
      history(branch: "feature/x", count: 5)
      live = history(branch: "main", count: 1, from: 1.hour.ago)

      expect(described_class.drain(live.last)).to eq(3)
    end
  end

  # The one boundary that is not a convergence property but an isolation one. Widening the
  # candidate set past `repository_id` would let one tenant's ingest delete another's history.
  describe "the repository boundary" do
    before { stub_const("SpecObservation::BRANCH_RETENTION_RUNS", 2) }

    let(:other) do
      create_repository(user: create_user(github_uid: "2002", github_handle: "other"),
                        github_full_name: "acme/other-service")
    end

    # @intent: { entity: "Ingest::QuietBucketPruner", action: "drain within one repository", behavior: "an expired identically-shaped bucket in another repository is left fully intact by this repository's ingest", layer: "integration" }
    it "never crosses into a second repository holding expired rows" do
      elsewhere = history(branch: "feature/x", count: 5, repo: other)
      live = history(branch: "main", count: 1, from: 1.hour.ago)

      described_class.drain(live.last)

      expect(observation_counts(elsewhere)).to all(eq(1))
    end

    # The inverse, so the guard is not satisfied by a pass that simply found nothing: the same
    # ingest that leaves the other repository alone must be one that WOULD have drained a bucket
    # shaped exactly like it at home.
    # @intent: { entity: "Ingest::QuietBucketPruner", action: "drain home and spare the neighbour", behavior: "the same call that drains an identical bucket at home proves the isolation is a guard, not an empty pass", layer: "integration" }
    it "drains an identically shaped bucket of its own repository in the same call" do
      elsewhere = history(branch: "feature/x", count: 5, repo: other)
      mine = history(branch: "feature/x", count: 5, from: 90.days.ago)
      live = history(branch: "main", count: 1, from: 1.hour.ago)

      described_class.drain(live.last)

      expect(observation_counts(mine)).to eq([0, 0, 0, 1, 1])
      expect(observation_counts(elsewhere)).to all(eq(1))
    end
  end

  # ⭐ Research finding 2, as an executable guard. `ObservationPruner` deletes observations and
  # never deletes a `TestRun` row, so "this bucket has runs older than the window" stays true
  # forever — including after the bucket has been drained empty. A selection built on that
  # predicate re-picks the same emptied bucket on every ingest and visits exactly one bucket ever,
  # while looking from the outside like it is working.
  describe "that the selection advances" do
    before { stub_const("SpecObservation::BRANCH_RETENTION_RUNS", 2) }

    # @intent: { entity: "Ingest::QuietBucketPruner", action: "advance the selection", behavior: "once the first quiet bucket reaches the rule the next drain moves to a second bucket instead of re-visiting", layer: "integration" }
    it "moves to a second quiet bucket once the first is at the rule" do
      first = history(branch: "feature/a", count: 5)
      second = history(branch: "feature/b", count: 5)
      live = history(branch: "main", count: 1, from: 1.hour.ago)

      2.times { described_class.drain(live.last) }

      expect(observation_counts(first)).to eq([0, 0, 0, 1, 1])
      expect(observation_counts(second)).to eq([0, 0, 0, 1, 1])
    end

    # The stall stated directly rather than inferred from the pair above: the run rows of the
    # drained bucket are all still there, and it must still not be re-selected.
    # @intent: { entity: "Ingest::QuietBucketPruner", action: "skip a drained bucket", behavior: "a bucket whose observations are gone is not re-selected even though its TestRun rows remain past the window", layer: "integration" }
    it "does not re-select a bucket whose rows are gone though its runs remain" do
      drained = history(branch: "feature/a", count: 5)
      described_class.drain(history(branch: "main", count: 1, from: 1.hour.ago).last)
      expect(TestRun.where(branch: "feature/a").count).to eq(5)

      still_over = history(branch: "feature/b", count: 5, from: 95.days.ago)
      live = history(branch: "main", count: 1, from: 30.minutes.ago)

      described_class.drain(live.last)

      expect(observation_counts(drained)).to eq([0, 0, 0, 1, 1])
      expect(observation_counts(still_over)).to eq([0, 0, 0, 1, 1])
    end

    # @intent: { entity: "Ingest::QuietBucketPruner", action: "drain across deliveries", behavior: "successive ingests walk a repository's entire bucket backlog down to the retention rule", layer: "integration" }
    it "walks a repository's whole backlog down over successive deliveries" do
      buckets = (0...4).map { |index| history(branch: "feature/#{index}", count: 4) }
      live = history(branch: "main", count: 1, from: 1.hour.ago)

      6.times { described_class.drain(live.last) }

      expect(buckets.map { |bucket| observation_counts(bucket) }).to all(eq([0, 0, 1, 1]))
    end

    # The selection's guarantee in its own right: it is exact, not a heuristic that might pick a
    # bucket with nothing to do. A bucket with M > R runs still holding rows has at least M - R of
    # them outside a window that retains R, so a selected bucket always yields work — which is what
    # makes "one invocation, one bucket" progress rather than a lottery.
    # @intent: { entity: "Ingest::QuietBucketPruner", action: "select a bucket with work", behavior: "the pick is exact: only the first drain deletes rows and every later one returns zero, so no selected bucket yields nothing", layer: "integration" }
    it "never selects a bucket that would yield no deletes" do
      history(branch: "feature/a", count: 5)
      live = history(branch: "main", count: 1, from: 1.hour.ago)

      3.times do |index|
        deleted = described_class.drain(live.last)
        expect(deleted).to be_positive if index.zero?
        expect(deleted).to eq(0) if index.positive?
      end
    end
  end

  # One POST must not attempt an unbounded delete on the quiet half either, and the ceiling is
  # asserted as STATEMENTS rather than as a row total — a row total moves with the fixture, a
  # statement count is the thing that bounds what the request pays for.
  describe "the per-invocation ceiling" do
    before do
      stub_const("SpecObservation::BRANCH_RETENTION_RUNS", 2)
      stub_const("Ingest::ObservationPruner::DELETE_BATCH_SIZE", 2)
      stub_const("#{described_class}::MAX_BATCHES_PER_INGEST", 2)
    end

    # @intent: { entity: "Ingest::QuietBucketPruner", action: "drain under a stubbed ceiling", behavior: "one invocation reclaims exactly batch size times max batches regardless of a backlog several times larger", layer: "integration" }
    it "bounds one invocation by its own MAX_BATCHES_PER_INGEST rather than by the backlog" do
      history(branch: "feature/x", count: 8, rows: 3)
      live = history(branch: "main", count: 1, from: 1.hour.ago)

      expect(described_class.drain(live.last)).to eq(
        Ingest::ObservationPruner::DELETE_BATCH_SIZE * described_class::MAX_BATCHES_PER_INGEST
      )
    end

    # One selection, one boundary lookup, at most MAX_BATCHES_PER_INGEST deletes — pinned as an
    # absolute against a backlog several times the ceiling, so nothing here follows the backlog.
    # @intent: { entity: "Ingest::QuietBucketPruner", action: "drain with bounded statements", behavior: "the statement count is one selection, one boundary lookup, and at most max-batches deletes, independent of backlog", layer: "integration" }
    it "issues one selection, one boundary lookup and at most MAX_BATCHES_PER_INGEST deletes" do
      history(branch: "feature/x", count: 8, rows: 3)
      live = history(branch: "main", count: 1, from: 1.hour.ago)

      expect(count_queries { described_class.drain(live.last) })
        .to eq(2 + described_class::MAX_BATCHES_PER_INGEST)
    end

    # @intent: { entity: "Ingest::QuietBucketPruner", action: "drain with no candidates", behavior: "when nothing is over the rule the whole pass costs exactly the single selection query", layer: "integration" }
    it "costs exactly the selection when no bucket is over the rule" do
      live = history(branch: "main", count: 1, from: 1.hour.ago)

      expect(count_queries { described_class.drain(live.last) }).to eq(1)
    end

    # The ceiling the two halves add up to, stated in the named constants and in no numeral. A
    # sharded run POSTs once per shard and pays this per shard; that is per INVOCATION by design.
    # @intent: { entity: "Ingest::QuietBucketPruner", action: "stay under the sibling ceiling", behavior: "the quiet half's batches-per-ingest constant is strictly smaller than the current-branch half's, capping its share of one POST", layer: "unit" }
    it "spends strictly less of one ingest than the current-branch half does" do
      expect(described_class::MAX_BATCHES_PER_INGEST)
        .to be < Ingest::ObservationPruner::MAX_BATCHES_PER_INGEST
    end
  end

  # Criterion 6's other half. The assertion is not "the planner picks index X" — that is not this
  # suite's business and would pin a plan rather than a property. It is the property the plan has
  # to serve: the probe reads `spec_observations` only through `test_run_id`, so it can be an index
  # probe, and it is issued once however many buckets the repository has.
  describe "the selection probe" do
    before { stub_const("SpecObservation::BRANCH_RETENTION_RUNS", 2) }

    # @intent: { entity: "Ingest::QuietBucketPruner", action: "probe buckets in one statement", behavior: "the GROUP BY selection probe against spec_observations is issued once however many buckets the repository holds", layer: "integration" }
    it "costs one statement whatever the number of buckets" do
      (0...12).each { |index| history(branch: "feature/#{index}", count: 3) }
      live = history(branch: "main", count: 1, from: 1.hour.ago)

      probe = queries_against("spec_observations") { described_class.drain(live.last) }.grep(/GROUP BY/)

      expect(probe.size).to eq(1)
    end

    # The probe reaches `spec_observations` by `test_run_id` and by nothing else — an `EXISTS`
    # correlated on the indexed column. A predicate on any other column of that table is what a
    # sequential scan of it would look like from here.
    # @intent: { entity: "Ingest::QuietBucketPruner", action: "probe by test_run_id only", behavior: "the only column of spec_observations the probe references is test_run_id, keeping it index-serviceable rather than a sequential scan", layer: "integration" }
    it "reaches spec_observations only by test_run_id" do
      history(branch: "feature/x", count: 3)
      live = history(branch: "main", count: 1, from: 1.hour.ago)

      probe = queries_against("spec_observations") { described_class.drain(live.last) }
                .grep(/GROUP BY/).first

      expect(probe).to include("spec_observations")
      expect(probe.scan(/spec_observations"?\.\s*"?(\w+)/).flatten.uniq).to eq(["test_run_id"])
    end
  end
end
