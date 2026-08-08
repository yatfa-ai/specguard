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
    it "retains strictly more runs than the deepest reader reads" do
      expect(SpecObservation::BRANCH_RETENTION_RUNS).to be > Repository::TRAJECTORY_LIMIT
    end

    it "bounds one POST's deletes by a stated ceiling rather than by the size of the backlog" do
      expect(described_class::DELETE_BATCH_SIZE).to be_positive
      expect(described_class::MAX_BATCHES_PER_INGEST).to be_positive
    end
  end

  describe "the window it keeps" do
    before { stub_const("SpecObservation::BRANCH_RETENTION_RUNS", 3) }

    it "keeps the R most recent runs of the branch and empties everything older" do
      runs = history(branch: "main", count: 5)

      described_class.prune(runs.last)

      expect(observation_counts(runs)).to eq([0, 0, 1, 1, 1])
    end

    # The run's own row and both of its counters are a function of `test_run_shards`, not of these
    # rows, so pruning a run's observations must leave the suite-size history it feeds completely
    # intact — a pruned run is a point on the growth chart exactly as it was.
    it "leaves the pruned runs' rows and both counters untouched" do
      runs = history(branch: "main", count: 5)
      oldest = runs.first

      expect { described_class.prune(runs.last) }.not_to change(TestRun, :count)

      expect(oldest.reload.total_specs_count).to eq(1)
      expect(oldest.annotated_specs_count).to eq(0)
      expect(oldest.branch).to eq("main")
    end

    it "does nothing at all on a branch that has run fewer than R times" do
      runs = history(branch: "main", count: 3)

      expect { described_class.prune(runs.last) }.not_to change(SpecObservation, :count)
    end

    # The boundary is the Nth run, and the Nth run is KEPT — an off-by-one here is a whole run of
    # history deleted a run early, invisibly.
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

    it "retains every one of main's R runs though R+5 feature runs are interleaved among them" do
      start = 100.days.ago
      main = (0...3).map { |i| run_with_observation(branch: "main", at: start + (i * 10).minutes) }
      features = (0...8).map { |i| run_with_observation(branch: "feature/#{i}", at: start + ((i * 3) + 1).minutes) }

      described_class.prune(main.last)

      expect(observation_counts(main)).to eq([1, 1, 1])
      expect(observation_counts(features)).to all(eq(1))
    end

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
    it "gives branch-less runs their own bucket, in both directions" do
      anonymous = history(branch: nil, count: 5)
      main = history(branch: "main", count: 5, from: 90.days.ago)

      described_class.prune(anonymous.last)

      expect(observation_counts(anonymous)).to eq([0, 0, 1, 1, 1])
      expect(observation_counts(main)).to eq([1, 1, 1, 1, 1])
    end

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

    it "deletes at most DELETE_BATCH_SIZE * MAX_BATCHES_PER_INGEST rows in one invocation" do
      runs = history(branch: "main", count: 5, rows: 3)

      expect(described_class.prune(runs.last)).to eq(4)
      expect(SpecObservation.where(test_run_id: runs.first(3)).count).to eq(5)
    end

    it "converges on the rule over successive invocations" do
      runs = history(branch: "main", count: 5, rows: 3)

      3.times { described_class.prune(runs.last) }

      expect(observation_counts(runs)).to eq([0, 0, 0, 3, 3])
    end

    # Pinned as an absolute, not as a comparison against a baseline: one boundary lookup plus at
    # most `MAX_BATCHES_PER_INGEST` deletes, and nothing that scales with the backlog.
    it "issues one boundary lookup and at most MAX_BATCHES_PER_INGEST deletes, on a huge backlog" do
      runs = history(branch: "main", count: 8, rows: 3)

      expect(count_queries { described_class.prune(runs.last) }).to eq(3)
    end

    it "stops early rather than spending the ceiling on statements that delete nothing" do
      runs = history(branch: "main", count: 3, rows: 1)

      expect(count_queries { described_class.prune(runs.last) }).to eq(2)
    end

    it "costs one query on a branch that has not yet filled its window" do
      runs = history(branch: "main", count: 1)

      expect(count_queries { described_class.prune(runs.last) }).to eq(1)
    end
  end
end
