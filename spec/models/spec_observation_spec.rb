# frozen_string_literal: true

require "rails_helper"

RSpec.describe SpecObservation do
  describe "the questions one run's rows have to answer" do
    let(:rows_per_run) { 500 }
    let(:repository) { create_repository }
    let(:run) { create_test_run(repository: repository, total_specs_count: rows_per_run) }

    let(:slowest) { run.spec_observations.order(duration_seconds: :desc).limit(20) }
    let(:failures) { run.spec_observations.where(outcome: "failed") }
    # By `spec_file_path` — the file that *ran* the example — rather than by `file_path`, so a
    # shared example group's time lands on the including file and not on a `spec/support/` helper.
    let(:by_file) { run.spec_observations.group(:spec_file_path).select("spec_file_path, SUM(duration_seconds)") }
    let(:one_file) { run.spec_observations.where(spec_file_path: "spec/f3_spec.rb") }

    # One run's worth of rows, spread over 25 files so a by-file aggregate has something to group.
    def seed(test_run)
      now = Time.current
      rows = (1..rows_per_run).map do |index|
        {
          test_run_id: test_run.id, repository_id: test_run.repository_id,
          example_id: "./spec/f#{index % 25}_spec.rb[1:#{index}]",
          spec_file_path: "spec/f#{index % 25}_spec.rb", file_path: "spec/f#{index % 25}_spec.rb",
          line_number: index, name: "example #{index}",
          duration_seconds: (index % 97) / 10.0,
          outcome: (index % 50).zero? ? "failed" : "passed",
          status: "unannotated", created_at: now, updated_at: now
        }
      end

      SpecObservation.insert_all(rows)
    end

    # What the reads return needs one run's rows and nothing else — so this half seeds one run.
    # The planner half below is the only part that has to pay for nineteen more.
    describe "what they return" do
      before { seed(run) }

      it "gives the 20 slowest examples, in order, scoped to the run" do
        rows = slowest.to_a

        expect(rows.size).to eq(20)
        expect(rows.map(&:test_run_id).uniq).to eq([run.id])
        expect(rows.map(&:duration_seconds)).to eq(rows.map(&:duration_seconds).sort.reverse)
      end

      it "gives this run's failures and nobody else's" do
        expect(failures.count).to eq(rows_per_run / 50)
        expect(failures.pluck(:outcome).uniq).to eq(["failed"])
        expect(failures.pluck(:test_run_id).uniq).to eq([run.id])
      end

      it "totals duration for every file of the run, and only the run" do
        totals = run.spec_observations.group(:spec_file_path).sum(:duration_seconds)

        expect(totals.size).to eq(25)
        expect(totals.values.sum).to be_within(0.001).of(run.spec_observations.sum(:duration_seconds))
      end

      it "narrows to one file of one run" do
        expect(one_file.count).to eq(rows_per_run / 25)
        expect(one_file.pluck(:spec_file_path).uniq).to eq(["spec/f3_spec.rb"])
      end
    end

    # The only examples that need a populated table: a planner given three rows sequentially scans
    # everything, and an EXPLAIN assertion over that would say nothing about the indexes at all. At
    # twenty runs a single run is ~5% of the table, so "use the index" is a decision rather than a
    # foregone conclusion.
    describe "the plan Postgres chooses for each of them" do
      let(:runs) { 20 }

      before do
        seed(run)
        (runs - 1).times { seed(create_test_run(repository: repository)) }

        # Without stats the planner works off hard-coded defaults and its choice says nothing about
        # the data. `ANALYZE` is legal inside the transaction the suite wraps each example in.
        ActiveRecord::Base.connection.execute("ANALYZE spec_observations")
      end

      # Postgres's own plan for the exact SQL the relation would run, rather than
      # `ActiveRecord::Relation#explain`, whose proxy renders the plan only when inspected.
      def plan_for(relation)
        ActiveRecord::Base.connection.select_values("EXPLAIN #{relation.to_sql}").join("\n")
      end

      it "reads the slowest examples off the by-duration index" do
        plan = plan_for(slowest)

        expect(plan).to include("index_spec_observations_on_test_run_id_and_duration_seconds")
        expect(plan).not_to match(/Seq Scan on spec_observations/)
      end

      it "reads the failures off the by-outcome index" do
        plan = plan_for(failures)

        expect(plan).to include("index_spec_observations_on_test_run_id_and_outcome")
        expect(plan).not_to match(/Seq Scan on spec_observations/)
      end

      # Postgres picks the narrower `test_run_id` index here and hash-aggregates on top of it: the
      # aggregate has to touch the heap for `duration_seconds` either way, so the wider index buys
      # it nothing for a whole-run grouping. What matters for this criterion is that one run is
      # read through an index rather than by walking every run's rows, and that is what the plan
      # says. The composite index earns its place on the *narrowed* read below.
      it "reads the by-file totals off an index rather than scanning the table" do
        plan = plan_for(by_file)

        expect(plan).to match(/Index Scan using index_spec_observations_on_test_run_id\w* on spec_observations/)
        expect(plan).not_to match(/Seq Scan on spec_observations/)
      end

      it "reads one file of one run straight off the by-file index" do
        plan = plan_for(one_file)

        expect(plan).to include("index_spec_observations_on_test_run_id_and_spec_file_path")
        expect(plan).not_to match(/Seq Scan on spec_observations/)
      end
    end
  end

  describe "what happens when the things it hangs off go away" do
    let(:repository) { create_repository }
    let(:run) { create_test_run(repository: repository) }

    def observe(test_run, shard: nil, example_id: "./spec/a_spec.rb[1:1]")
      SpecObservation.create!(
        test_run: test_run, repository: test_run.repository, test_run_shard: shard,
        example_id: example_id, file_path: "spec/a_spec.rb", spec_file_path: "spec/a_spec.rb",
        line_number: 1, status: "unannotated"
      )
    end

    it "goes with its TestRun" do
      observe(run)

      expect { run.destroy }.to change(described_class, :count).by(-1)
    end

    it "goes with its Repository, shards and all" do
      shard = run.test_run_shards.create!(shard_id: "1")
      observe(run, shard: shard)

      expect { repository.destroy }.to change(described_class, :count).by(-1)
      expect(TestRun.where(id: run.id)).to be_empty
    end

    # The observation belongs to its run first and to the slice that delivered it second, so
    # losing the shard row must not lose the example.
    it "outlives the shard that delivered it, holding a null in its place" do
      shard = run.test_run_shards.create!(shard_id: "1")
      observation = observe(run, shard: shard)

      expect { shard.destroy }.not_to change(described_class, :count)
      expect(observation.reload.test_run_shard_id).to be_nil
    end
  end

  # The coordinate identifies the *code*, and a table-driven loop or a shared example group puts
  # many examples on one. `spec_intents` carries a unique index on exactly that triple; repeating
  # it here would collapse the grain this table exists to hold.
  it "carries no unique index on the location triple that collapses examples onto code" do
    location_indexes = ActiveRecord::Base.connection.indexes(:spec_observations).select do |index|
      index.unique && index.columns.sort == %w[file_path line_number repository_id]
    end

    expect(location_indexes).to be_empty
  end

  it "is unique only within one run, which is all the client claims for an example id" do
    unique = ActiveRecord::Base.connection.indexes(:spec_observations).select(&:unique)

    expect(unique.map(&:columns)).to eq([%w[test_run_id example_id]])
  end
end
