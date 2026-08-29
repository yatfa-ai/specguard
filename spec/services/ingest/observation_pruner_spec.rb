# frozen_string_literal: true

require "rails_helper"

# The retention rule for `spec_observations`, which before this class did not exist: rows left the
# table when their run or their repository was destroyed and never for age. Everything below is
# about WHICH rows go and which stay, and the interesting half of that is the branch keying — a
# repository-wide bound would pass a naive "the table stopped growing" test and delete exactly the
# history the product reads.
RSpec.describe Ingest::ObservationPruner do
  let(:repository) { create_repository }

  # One run on a branch, carrying one observation, at a stated instant. `created_at` is explicit on
  # every run here because the boundary is `(created_at, id)` and a set of runs created inside the
  # same millisecond would order by id alone — true, but it would stop these examples from saying
  # anything about the timestamp half of the comparison.
  def run_with_observation(branch:, at:, rows: 1, total_specs_count: 1)
    run = create_test_run(repository: repository, branch: branch, created_at: at,
                          total_specs_count: total_specs_count)

    rows.times do |index|
      run.spec_observations.create!(
        repository: repository, file_path: "spec/models/a_spec.rb", line_number: index + 1,
        status: "unannotated", example_id: "./spec/models/a_spec.rb[1:#{index + 1}]"
      )
    end

    run
  end

  # `count` runs on one branch, oldest first, one minute apart so the ordering is unambiguous.
  def history(branch:, count:, from: 100.days.ago, rows: 1)
    (0...count).map { |index| run_with_observation(branch: branch, at: from + index.minutes, rows: rows) }
  end

  def observation_counts(runs) = runs.map { |run| run.spec_observations.count }

  describe "the rule itself" do
    # The floor, pinned as an assertion rather than left in a comment. SPGD-282's branch-anchored
    # flakiness window reads `Repository::TRAJECTORY_LIMIT` runs deep at this table's grain, so a
    # retention below that depth is a shipping panel rendering blanks — and a retention EQUAL to it
    # empties that window's last point the instant one more run lands, which is the normal state of
    # a busy branch rather than an edge case.
    # @intent: { entity: "Ingest::ObservationPruner", action: "retain branch runs", behavior: "the retention constant exceeds the deepest reader window (TRAJECTORY_LIMIT), so a pruned branch still populates every shipping comparison", layer: "unit" }
    it "retains strictly more runs than the deepest reader reads" do
      expect(SpecObservation::BRANCH_RETENTION_RUNS).to be > Repository::TRAJECTORY_LIMIT
    end

    # @intent: { entity: "Ingest::ObservationPruner", action: "prune under a stated ceiling", behavior: "batch size and batches-per-ingest constants are declared positive, bounding one ingest invocation independently of backlog size", layer: "unit" }
    it "bounds one POST's deletes by a stated ceiling rather than by the size of the backlog" do
      expect(described_class::DELETE_BATCH_SIZE).to be_positive
      expect(described_class::MAX_BATCHES_PER_INGEST).to be_positive
    end
  end

  describe "the window it keeps" do
    before { stub_const("SpecObservation::BRANCH_RETENTION_RUNS", 3) }

    # @intent: { entity: "Ingest::ObservationPruner", action: "prune a branch window", behavior: "observations on the R most recent runs survive and everything older on that branch is emptied", layer: "integration" }
    it "keeps the R most recent runs of the branch and empties everything older" do
      runs = history(branch: "main", count: 5)

      described_class.prune(runs.last)

      expect(observation_counts(runs)).to eq([0, 0, 1, 1, 1])
    end

    # The run's own row and both of its counters are a function of `test_run_shards`, not of these
    # rows, so pruning a run's observations must leave the suite-size history it feeds completely
    # intact — a pruned run is a point on the growth chart exactly as it was.
    # @intent: { entity: "Ingest::ObservationPruner", action: "prune without touching run metadata", behavior: "pruned runs keep their TestRun rows and both suite-size counters, so growth-chart history is a function of shards alone", layer: "integration" }
    it "leaves the pruned runs' rows and both counters untouched" do
      runs = history(branch: "main", count: 5)
      oldest = runs.first

      expect { described_class.prune(runs.last) }.not_to change(TestRun, :count)

      expect(oldest.reload.total_specs_count).to eq(1)
      expect(oldest.annotated_specs_count).to eq(0)
      expect(oldest.branch).to eq("main")
    end

    # @intent: { entity: "Ingest::ObservationPruner", action: "prune an under-filled branch", behavior: "a branch with fewer than R runs loses no observations at all", layer: "integration" }
    it "does nothing at all on a branch that has run fewer than R times" do
      runs = history(branch: "main", count: 3)

      expect { described_class.prune(runs.last) }.not_to change(SpecObservation, :count)
    end

    # The boundary is the Nth run, and the Nth run is KEPT — an off-by-one here is a whole run of
    # history deleted a run early, invisibly.
    # @intent: { entity: "Ingest::ObservationPruner", action: "prune at the boundary", behavior: "the Nth run itself is kept and only the run behind it is emptied, pinning the off-by-one", layer: "integration" }
    it "keeps the boundary run itself and deletes the one behind it" do
      runs = history(branch: "main", count: 4)

      described_class.prune(runs.last)

      expect(observation_counts(runs)).to eq([0, 1, 1, 1])
    end
  end

  # ⭐ The regression the whole design exists for. Recency across a repository is interleaved: on a
  # repository whose CI reports on every PR the most recent runs are routinely all `feature/*`, so
  # a rule keyed on "the last N runs of this repository" evicts `main` FIRST — and `main` is what
  # every cross-run read is anchored to.
  describe "branch keying" do
    before { stub_const("SpecObservation::BRANCH_RETENTION_RUNS", 3) }

    # @intent: { entity: "Ingest::ObservationPruner", action: "prune main among interleaved feature runs", behavior: "retention is keyed per branch, so main keeps all its runs even when newer feature runs dominate recent history", layer: "integration" }
    it "retains every one of main's R runs though R+5 feature runs are interleaved among them" do
      start = 100.days.ago
      main = (0...3).map { |i| run_with_observation(branch: "main", at: start + (i * 10).minutes) }
      features = (0...8).map { |i| run_with_observation(branch: "feature/#{i}", at: start + ((i * 3) + 1).minutes) }

      described_class.prune(main.last)

      expect(observation_counts(main)).to eq([1, 1, 1])
      expect(observation_counts(features)).to all(eq(1))
    end

    # The protection above read from the other side: `main`'s two runs past the window keep their
    # rows through a prune on `feature/x`, because no invocation of THIS class reaches a branch
    # other than the one it was handed. That single-bucket reach is the contract, and it is why
    # the rule needs a second pass rather than a wider one here.
    #
    # ⚠️ **This example is the reason {Ingest::QuietBucketPruner} is a separate entry point.**
    # `main` and `feature/x` are the same repository (`let(:repository)` is file-level) and with
    # the retention stubbed to 3, `main` genuinely has two expired runs — so a drain-one-quiet-
    # bucket change folded INTO `.prune` would select `main` and this example would go red. It is
    # left passing unchanged, deliberately: `.prune` still means "bound the bucket I was handed",
    # and the quiet half is its own class with its own caller and its own failure policy. That
    # separation is also forced from the other direction, since the two halves must be independently
    # rescuable — see the asymmetry pinned in spec/requests/api/v1/ingest_spec.rb.
    #
    # The frozen-tail consequence this comment used to draw is no longer the codebase's position:
    # a branch that stops receiving runs is now drained by the ingests still arriving on the
    # repository's live branches. What stays true is the sentence this example actually asserts —
    # `.prune` alone reaches one bucket. See spec/services/ingest/quiet_bucket_pruner_spec.rb.
    # @intent: { entity: "Ingest::ObservationPruner", action: "prune one bucket", behavior: "an invocation reaches only the branch it was handed; other branches of the same repository, even expired, are untouched", layer: "integration" }
    it "bounds the branch the run is on and no other" do
      main = history(branch: "main", count: 5)
      feature = history(branch: "feature/x", count: 5, from: 90.days.ago)

      described_class.prune(feature.last)

      expect(observation_counts(main)).to eq([1, 1, 1, 1, 1])
      expect(observation_counts(feature)).to eq([0, 0, 1, 1, 1])
    end

    # "The anonymous runs of every machine are not one branch" — so a laptop's runs are their own
    # bucket, and the bucket has two edges: it is not evicted BY a named branch, and it does not
    # evict one.
    # @intent: { entity: "Ingest::ObservationPruner", action: "prune the branch-less bucket", behavior: "branch-less runs form their own bucket that neither evicts a named branch nor is evicted by one", layer: "integration" }
    it "gives branch-less runs their own bucket, in both directions" do
      anonymous = history(branch: nil, count: 5)
      main = history(branch: "main", count: 5, from: 90.days.ago)

      described_class.prune(anonymous.last)

      expect(observation_counts(anonymous)).to eq([0, 0, 1, 1, 1])
      expect(observation_counts(main)).to eq([1, 1, 1, 1, 1])
    end

    # @intent: { entity: "Ingest::ObservationPruner", action: "prune branch-less runs per repository", behavior: "branch-less buckets are scoped by repository, so pruning mine never pools or drains another repository's anonymous runs", layer: "integration" }
    it "does not pool one repository's branch-less runs with another's" do
      other = create_repository(user: create_user(github_uid: "2002", github_handle: "other"),
                                github_full_name: "acme/other-service")
      elsewhere = (0...5).map do |index|
        run = create_test_run(repository: other, branch: nil, created_at: 100.days.ago + index.minutes)
        run.spec_observations.create!(repository: other, file_path: "spec/x_spec.rb", line_number: 1,
                                      status: "unannotated")
        run
      end
      mine = history(branch: nil, count: 5, from: 90.days.ago)

      described_class.prune(mine.last)

      expect(observation_counts(elsewhere)).to all(eq(1))
    end
  end

  # The readers this table has today, asked after a prune on a branch that has run far past the
  # window. They read the RECENT end, which is the end retention keeps.
  describe "what the surfaces still read afterwards" do
    before { stub_const("SpecObservation::BRANCH_RETENTION_RUNS", 3) }

    # @intent: { entity: "Ingest::ObservationPruner", action: "prune then read surfaces", behavior: "after a deep prune the previous-run comparison still resolves both sides with comparable growth rows", layer: "integration" }
    it "still answers a previous-run comparison with rows on both sides" do
      runs = history(branch: "main", count: 12)
      latest = runs.last

      described_class.prune(latest)

      previous = repository.previous_test_run_on_branch(latest)
      expect(previous).to eq(runs[-2])

      growth = SpecDirectoryGrowth.for(latest, previous)
      expect(growth.state).to eq(:comparable)
      expect(growth.rows).not_to be_empty
    end
  end

  # The floor from the other side: not "the constant is big enough" but "a window that deep is
  # actually populated after a prune". Runs the REAL constants rather than a stub, because the
  # thing under test is the relationship between the two numbers.
  describe "the depth a shipping reader still finds" do
    # @intent: { entity: "Ingest::ObservationPruner", action: "prune at real retention depth", behavior: "with shipped constants, every run of a TRAJECTORY_LIMIT-deep window retains its observations while older runs empty", layer: "integration" }
    it "leaves observations on every run of a TRAJECTORY_LIMIT-deep branch window" do
      runs = history(branch: "main", count: SpecObservation::BRANCH_RETENTION_RUNS + 1)

      described_class.prune(runs.last)

      window = runs.last(Repository::TRAJECTORY_LIMIT)
      expect(observation_counts(window)).to all(eq(1))
      expect(runs.first.spec_observations.count).to eq(0)
    end
  end

  # The first ingest after this ships meets an unbounded backlog. One POST must not attempt it, and
  # the property that replaces "delete it all" is convergence.
  describe "the per-invocation ceiling" do
    before do
      stub_const("SpecObservation::BRANCH_RETENTION_RUNS", 2)
      stub_const("#{described_class}::DELETE_BATCH_SIZE", 2)
      stub_const("#{described_class}::MAX_BATCHES_PER_INGEST", 2)
    end

    # @intent: { entity: "Ingest::ObservationPruner", action: "prune under a stubbed ceiling", behavior: "one invocation deletes at most batch size times max batches, leaving the rest of the backlog for later passes", layer: "integration" }
    it "deletes at most DELETE_BATCH_SIZE * MAX_BATCHES_PER_INGEST rows in one invocation" do
      runs = history(branch: "main", count: 5, rows: 3)

      expect(described_class.prune(runs.last)).to eq(4)
      expect(SpecObservation.where(test_run_id: runs.first(3)).count).to eq(5)
    end

    # @intent: { entity: "Ingest::ObservationPruner", action: "prune repeatedly", behavior: "successive invocations converge the branch onto the retention rule instead of attempting the whole backlog at once", layer: "integration" }
    it "converges on the rule over successive invocations" do
      runs = history(branch: "main", count: 5, rows: 3)

      3.times { described_class.prune(runs.last) }

      expect(observation_counts(runs)).to eq([0, 0, 0, 3, 3])
    end

    # Pinned as an absolute, not as a comparison against a baseline: one boundary lookup plus at
    # most `MAX_BATCHES_PER_INGEST` deletes, and nothing that scales with the backlog.
    # @intent: { entity: "Ingest::ObservationPruner", action: "prune a huge backlog", behavior: "cost stays at one boundary lookup plus at most max-batches deletes regardless of backlog size", layer: "integration" }
    it "issues one boundary lookup and at most MAX_BATCHES_PER_INGEST deletes, on a huge backlog" do
      runs = history(branch: "main", count: 8, rows: 3)

      expect(count_queries { described_class.prune(runs.last) }).to eq(3)
    end

    # @intent: { entity: "Ingest::ObservationPruner", action: "stop on an empty batch", behavior: "the loop stops at the first short batch rather than spending the whole ceiling on no-op deletes", layer: "integration" }
    it "stops early rather than spending the ceiling on statements that delete nothing" do
      runs = history(branch: "main", count: 3, rows: 1)

      expect(count_queries { described_class.prune(runs.last) }).to eq(2)
    end

    # @intent: { entity: "Ingest::ObservationPruner", action: "prune an unfilled window", behavior: "a branch that has not yet filled its window costs exactly one query and deletes nothing", layer: "integration" }
    it "costs one query on a branch that has not yet filled its window" do
      runs = history(branch: "main", count: 1)

      expect(count_queries { described_class.prune(runs.last) }).to eq(1)
    end
  end
end
