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
    # The exact SELECT `SpecObservation.coverage_in` runs, built off the constant it runs it from
    # rather than retyped, so a sixth counter added there is a sixth counter EXPLAINed here. `pick`
    # is `limit(1).pluck`, hence the `.limit(1)`.
    let(:coverage) do
      run.spec_observations.select(Arel.sql(SpecObservation::COVERAGE_COUNTS.values.join(", "))).limit(1)
    end

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

      # The same aggregate through the read the panel actually makes. Asserted against the run's
      # own total for the reason the example above is: a rollup that loses or double-counts a
      # file's rows is still a plausible-looking list of files, and the sum is what catches it.
      it "rolls the whole run up by file through the read the panel makes" do
        files = described_class.file_durations_in(run, limit: 100)

        expect(files.size).to eq(25)
        expect(files.sum { |_path, total, _recorded, _timed| total })
          .to be_within(0.001).of(run.spec_observations.sum(:duration_seconds))
        # And every row the run wrote is under exactly one of those files.
        expect(files.sum { |_path, _total, recorded, _timed| recorded }).to eq(rows_per_run)
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

      # One run's rows reached THROUGH `index_spec_observations_on_test_run_id` (or a composite
      # that leads with it), rather than by walking every run's. Postgres reaches them two ways
      # depending on how many dead tuples sit behind the live ones — a plain `Index Scan`, or a
      # `Bitmap Index Scan` over the same index once the heap is scattered enough for one bitmap
      # pass to price better than many random fetches. Each example here inserts ten thousand rows
      # and rolls them back, so the table this runs against carries progressively more dead tuples
      # the later in a suite run it is reached, and which of the two the planner picks is decided
      # by that bloat and by RSpec's random ordering — NOT by anything about the query.
      #
      # Pinning the plain `Index Scan` spelling therefore pins a cost tiebreak that has no bearing
      # on the criterion, and it reddens on ordering alone: this matcher was widened after exactly
      # that happened. What these examples are about is stated in the comments on each of them —
      # one run read through an index — and the `Seq Scan` assertion beside this one is what
      # carries their reach: unscope any of these aggregates from a single run and the plan turns
      # into a sequential scan of every run's rows, whichever access method it had before.
      INDEXED_BY_RUN =
        /(?:Index Scan using|Bitmap Index Scan on) index_spec_observations_on_test_run_id\w*/

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

      # The plan for whatever SQL the block causes to be run against this table — for a read whose
      # projection is not on the relation (a `pluck` of aggregates) and therefore has no `to_sql`
      # worth EXPLAINing.
      def plan_for_actual_sql
        captured = nil
        subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
          captured ||= payload[:sql] if payload[:name] != "SCHEMA" && payload[:sql].to_s.include?("spec_observations")
        end
        ActiveRecord::Base.connection.unprepared_statement { yield }

        ActiveRecord::Base.connection.select_values("EXPLAIN #{captured}").join("\n")
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
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

        expect(plan).to match(INDEXED_BY_RUN)
        expect(plan).not_to match(/Seq Scan on spec_observations/)
      end

      it "reads one file of one run straight off the by-file index" do
        plan = plan_for(one_file)

        expect(plan).to include("index_spec_observations_on_test_run_id_and_spec_file_path")
        expect(plan).not_to match(/Seq Scan on spec_observations/)
      end

      # The plan for the SQL `.file_durations_in` ACTUALLY runs, captured off the wire rather than
      # EXPLAINed from a hand-written copy of it — a copy is a second definition of the query that
      # can drift from the one the panel makes, and a plan assertion against the copy would then be
      # asserting nothing about the page. `unprepared_statement` inlines the bind, because `EXPLAIN`
      # cannot be handed a `$1`.
      #
      # The ORDER BY and LIMIT this read adds over the bare grouping above sort the AGGREGATE'S
      # output — one row per file, not per example — so what has to stay true at the design point is
      # that one run's rows are still reached through an index rather than by walking every run's.
      it "reads the panel's by-file rollup off an index rather than scanning the table" do
        plan = plan_for_actual_sql { described_class.file_durations_in(run) }

        expect(plan).to match(INDEXED_BY_RUN)
        expect(plan).not_to match(/Seq Scan on spec_observations/)
      end

      # The "no extra cost" claim for the outcome counters, ASSERTED rather than reasoned about.
      # The two `FILTER` aggregates are new expressions over a row set the existing `COUNT(*)`
      # already reads, so they should add no scan — but that is a claim about a plan, and a query
      # count alone would accept a plan that had quietly fallen back to reading every run's rows.
      #
      # Postgres picks the narrow `test_run_id` index and aggregates on top, for the reason the
      # by-file case above states: `outcome` and `duration_seconds` have to come off the heap
      # either way, so the wider indexes buy the aggregate nothing on a whole-run grouping. It is
      # specifically NOT `index_spec_observations_on_test_run_id_and_outcome` — that index is for
      # NARROWING to the failures, and reaching for it here would mean a second round trip for a
      # figure this one scan already has the rows for.
      it "counts a whole run's outcomes off an index rather than scanning the table" do
        plan = plan_for(coverage)

        expect(plan).to match(INDEXED_BY_RUN)
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

  # The read `repositories#show` makes off these rows — the first read anything in the application
  # has ever made of this table.
  describe "the ranking the by-duration index was built for" do
    let(:repository) { create_repository }
    let(:run) { create_test_run(repository: repository) }

    # One example of one run. `duration_seconds:` is passed explicitly at every call site,
    # including the nils: an untimed row is the state this whole section turns on, and a builder
    # that defaulted it would let a caller write one without meaning to.
    def observe(test_run, duration:, line_number:, name: "example #{line_number}", **attrs)
      SpecObservation.create!(
        { test_run: test_run, repository: test_run.repository, name: name,
          example_id: "./spec/a_spec.rb[1:#{line_number}]", file_path: "spec/a_spec.rb",
          spec_file_path: "spec/a_spec.rb", line_number: line_number, status: "unannotated",
          duration_seconds: duration }.merge(attrs)
      )
    end

    it "returns one run's examples slowest first" do
      observe(run, duration: 0.5, line_number: 1)
      observe(run, duration: 9.5, line_number: 2)
      observe(run, duration: 3.0, line_number: 3)

      expect(described_class.slowest_in(run).map(&:duration_seconds)).to eq([9.5, 3.0, 0.5])
    end

    # THE example this read exists to get right. `duration_seconds: :desc` is NULLS FIRST in
    # Postgres, so a naive ordering does not merely include the untimed row — it puts it at the
    # HEAD of a list captioned "slowest", naming an example that never ran as the slowest thing in
    # the suite. Both halves are asserted, because "absent" and "not first" fail differently: a
    # `NULLS LAST` ordering with no exclusion passes the second and fails the first.
    it "excludes an untimed example rather than sorting it to the head" do
      observe(run, duration: nil, line_number: 1, name: "never ran")
      observe(run, duration: 2.0, line_number: 2, name: "ran")

      names = described_class.slowest_in(run).map(&:name)

      expect(names.first).to eq("ran")
      expect(names).not_to include("never ran")
    end

    # The exclusion is in the WHERE clause, and that is what this asserts — not merely that the nil
    # is gone. Rejected in Ruby after a `LIMIT`, the same fixture hands back 2 rows instead of 3:
    # the untimed rows are fetched, counted against the cap, and only then discarded, so the list
    # gets shorter on exactly the runs the exclusion matters for.
    it "fills the limit from timed rows, however many untimed ones sit above them" do
      observe(run, duration: nil, line_number: 1)
      observe(run, duration: nil, line_number: 2)
      3.times { |i| observe(run, duration: (i + 1).to_f, line_number: 10 + i) }

      expect(described_class.slowest_in(run, limit: 3).count).to eq(3)
    end

    it "caps at the limit it was given" do
      12.times { |i| observe(run, duration: i.to_f + 1, line_number: i + 1) }

      expect(described_class.slowest_in(run).size).to eq(described_class::SLOWEST_LIMIT)
      expect(described_class.slowest_in(run, limit: 3).size).to eq(3)
    end

    it "reads the run it was asked about and no other" do
      other = create_test_run(repository: repository, commit_sha: "0ther")
      observe(run, duration: 1.0, line_number: 1, name: "ours")
      observe(other, duration: 99.0, line_number: 1, name: "theirs")

      expect(described_class.slowest_in(run).map(&:name)).to eq(["ours"])
    end

    # Ties are ordinary at this grain — a suite's fast examples cluster on the same rounded float —
    # so the order has to be total, or two requests against unchanged rows can list them
    # differently.
    it "breaks ties by id, so equal durations have one order" do
      first = observe(run, duration: 1.5, line_number: 1)
      second = observe(run, duration: 1.5, line_number: 2)

      expect(described_class.slowest_in(run).map(&:id)).to eq([first.id, second.id])
    end

    describe ".coverage_in" do
      it "counts this run's rows and the ones that carried a duration" do
        observe(run, duration: 1.0, line_number: 1)
        observe(run, duration: nil, line_number: 2)
        observe(run, duration: 3.0, line_number: 3)

        expect(described_class.coverage_in(run)).to include(recorded_count: 3, timed_count: 2)
      end

      it "reads zeroes for a run that recorded nothing, rather than nils" do
        expect(described_class.coverage_in(run).values).to all(eq(0))
      end

      # The denominator is the rows, never `TestRun#total_specs_count` — which is derived from
      # shard reports and can legitimately disagree with how many rows the run wrote.
      it "counts rows even where the run's own suite size says otherwise" do
        run.update!(total_specs_count: 4_000)
        observe(run, duration: 1.0, line_number: 1)

        expect(described_class.coverage_in(run)).to include(recorded_count: 1, timed_count: 1)
      end

      it "counts the outcomes it reads by name, off the same rows" do
        observe(run, duration: 1.0, line_number: 1, outcome: "failed")
        observe(run, duration: 1.0, line_number: 2, outcome: "pending")
        observe(run, duration: 1.0, line_number: 3, outcome: "passed")
        observe(run, duration: 1.0, line_number: 4, outcome: "passed")

        expect(described_class.coverage_in(run))
          .to eq(recorded_count: 4, timed_count: 4, reported_outcome_count: 4,
                 failed_count: 1, pending_count: 1)
      end

      # THE state the outcome half of this aggregate exists to keep separable. `outcome` is
      # nullable and nothing platform-side validates it, so a run whose client sends none stores a
      # nil on every row — and `failed_count` is then a legitimate zero that means "this run said
      # nothing", not "this run had no failures". Only `reported_outcome_count` can tell a caller
      # which zero it is holding, so both halves are asserted.
      it "separates a run that reported no outcome at all from one that reported no failure" do
        observe(run, duration: 1.0, line_number: 1, outcome: nil)
        observe(run, duration: 1.0, line_number: 2, outcome: nil)

        expect(described_class.coverage_in(run))
          .to include(recorded_count: 2, reported_outcome_count: 0, failed_count: 0)
      end

      # `Ingest::ObservationRecorder#attributes` collapses `""` to nil through `presence_of`, so
      # "the client sent nothing" and "the client sent a blank" are ONE state in this column and
      # there is deliberately no example for a second one — a fixture writing `""` here would be
      # asserting against a row nothing in production can produce.

      it "counts one run's outcomes and no other run's" do
        other = create_test_run(repository: repository, commit_sha: "0ther")
        observe(run, duration: 1.0, line_number: 1, outcome: "passed")
        observe(other, duration: 1.0, line_number: 1, outcome: "failed")

        expect(described_class.coverage_in(run)).to include(failed_count: 0, reported_outcome_count: 1)
      end
    end

    describe ".file_durations_in" do
      it "totals each file's examples, heaviest file first" do
        observe(run, duration: 1.5, line_number: 1, spec_file_path: "spec/models/order_spec.rb")
        observe(run, duration: 2.5, line_number: 2, spec_file_path: "spec/models/order_spec.rb")
        observe(run, duration: 9.0, line_number: 3, spec_file_path: "spec/models/refund_spec.rb")
        observe(run, duration: 0.5, line_number: 4, spec_file_path: "spec/models/user_spec.rb")

        expect(described_class.file_durations_in(run)).to eq(
          [["spec/models/refund_spec.rb", 9.0, 1, 1, 3],
           ["spec/models/order_spec.rb", 4.0, 2, 2, 3],
           ["spec/models/user_spec.rb", 0.5, 1, 1, 3]]
        )
      end

      # The row is grouped by the file that RAN the example, so a shared example group's time lands
      # on each including file rather than on the `spec/support/` helper that defines it — the rule
      # `Ingest::ObservationRecorder` writes `spec_file_path` for, pinned end-to-end in
      # spec/requests/api/v1/ingest_spec.rb.
      it "attributes a shared example group's time to the file that included it" do
        observe(run, duration: 1.5, line_number: 4, file_path: "spec/support/shared_examples.rb",
                     spec_file_path: "spec/models/order_spec.rb",
                     example_id: "./spec/models/order_spec.rb[1:1:1]")
        observe(run, duration: 2.5, line_number: 4, file_path: "spec/support/shared_examples.rb",
                     spec_file_path: "spec/models/refund_spec.rb",
                     example_id: "./spec/models/refund_spec.rb[1:1:1]")

        files = described_class.file_durations_in(run)

        expect(files.map(&:first)).to eq(["spec/models/refund_spec.rb", "spec/models/order_spec.rb"])
        expect(files.map(&:first)).not_to include("spec/support/shared_examples.rb")
      end

      # THE example this read exists to get right, and the one the obvious implementation fails
      # twice over. `group(...).sum(:duration_seconds)` casts a NULL sum to `0.0` on the way back
      # into Ruby, and `SUM(...) DESC` is NULLS FIRST in Postgres — so a file NONE of whose
      # examples were timed comes back as a measured zero AND is named the heaviest file in the
      # run. Both halves are asserted because they fail differently.
      it "hands back a nil for a file that reported no timing at all, sorted below every total" do
        observe(run, duration: nil, line_number: 1, spec_file_path: "spec/models/never_ran_spec.rb")
        observe(run, duration: nil, line_number: 2, spec_file_path: "spec/models/never_ran_spec.rb")
        observe(run, duration: 0.25, line_number: 3, spec_file_path: "spec/models/quick_spec.rb")

        files = described_class.file_durations_in(run)

        expect(files).to eq([["spec/models/quick_spec.rb", 0.25, 1, 1, 2],
                             ["spec/models/never_ran_spec.rb", nil, 2, 0, 2]])
        expect(files.last[1]).to be_nil
      end

      # A file whose examples were only partly timed has a total covering only part of it. The
      # total alone cannot say so — it is an ordinary-looking number — so the two counts come back
      # in the same pass, off the same rows, rather than as a second question a caller might not
      # think to ask.
      it "counts each file's rows against the ones that carried a duration" do
        observe(run, duration: 4.0, line_number: 1, spec_file_path: "spec/models/order_spec.rb")
        observe(run, duration: nil, line_number: 2, spec_file_path: "spec/models/order_spec.rb")
        observe(run, duration: nil, line_number: 3, spec_file_path: "spec/models/order_spec.rb")

        expect(described_class.file_durations_in(run)).to eq([["spec/models/order_spec.rb", 4.0, 3, 1, 1]])
      end

      it "reads the run it was asked about and no other" do
        other = create_test_run(repository: repository, commit_sha: "0ther")
        observe(run, duration: 1.0, line_number: 1, spec_file_path: "spec/ours_spec.rb")
        observe(other, duration: 99.0, line_number: 1, spec_file_path: "spec/theirs_spec.rb")

        expect(described_class.file_durations_in(run)).to eq([["spec/ours_spec.rb", 1.0, 1, 1, 1]])
      end

      it "caps at the limit it was given, and defaults to the panel's own" do
        12.times { |i| observe(run, duration: i.to_f + 1, line_number: i + 1, spec_file_path: "spec/f#{i}_spec.rb") }

        expect(described_class.file_durations_in(run).size).to eq(described_class::HEAVIEST_FILES_LIMIT)
        expect(described_class.file_durations_in(run, limit: 3).map(&:first))
          .to eq(["spec/f11_spec.rb", "spec/f10_spec.rb", "spec/f9_spec.rb"])
      end

      # What the capped list is the head OF, in the same round trip. Without it the caller holds a
      # length that equals its own limit and cannot tell three files from three hundred — and a
      # count taken after the `LIMIT`, which is what `rows.size` is, reports the cap back as if it
      # were the suite. `COUNT(*) OVER ()` runs after `GROUP BY` and before `LIMIT`, so it counts
      # FILES rather than rows and counts all of them however few come back.
      it "reports how many files the run touched in total, whatever the limit returns" do
        12.times { |i| observe(run, duration: i.to_f + 1, line_number: i + 1, spec_file_path: "spec/f#{i}_spec.rb") }

        expect(described_class.file_durations_in(run, limit: 3).map(&:last)).to eq([12, 12, 12])
        expect(described_class.file_durations_in(run, limit: 100).map(&:last).uniq).to eq([12])
      end

      # Groups, not rows: a run whose twelve examples sit in two files touched two files. The
      # cheapest wrong reading of this column is the row count, and one example per file cannot
      # tell the two apart.
      it "counts the files rather than the examples in them" do
        12.times { |i| observe(run, duration: 1.0, line_number: i + 1, spec_file_path: "spec/f#{i % 2}_spec.rb") }

        expect(described_class.file_durations_in(run).map(&:last)).to eq([2, 2])
      end

      # Two files totalling the same is ordinary — a run where several files hold one fast example
      # each — so the order has to be total, or two requests against unchanged rows list them
      # differently.
      it "breaks ties by path, so equal totals have one order" do
        observe(run, duration: 1.5, line_number: 1, spec_file_path: "spec/b_spec.rb")
        observe(run, duration: 1.5, line_number: 2, spec_file_path: "spec/a_spec.rb")

        expect(described_class.file_durations_in(run).map(&:first)).to eq(["spec/a_spec.rb", "spec/b_spec.rb"])
      end

      it "reads no files for a run that recorded nothing" do
        expect(described_class.file_durations_in(run)).to eq([])
      end
    end

    describe "how a row states itself" do
      it "labels itself by name" do
        row = observe(run, duration: 1.0, line_number: 12, name: "Invoice finalize locks the items")

        expect(row.label).to eq("Invoice finalize locks the items")
      end

      # `name` is nullable — `Ingest::ObservationRecorder` writes it through `presence_of` — and a
      # blank label is a row the reader can neither identify nor go and find.
      it "falls back to its definition site where the client sent no name" do
        row = observe(run, duration: 1.0, line_number: 12, name: nil)

        expect(row.label).to eq("spec/a_spec.rb:12")
      end

      it "treats a blank name as no name" do
        expect(observe(run, duration: 1.0, line_number: 12, name: "").label).to eq("spec/a_spec.rb:12")
      end

      # `line_number` is the DEFINITION site's line, so the coordinate is built from `file_path`.
      # Pairing it with `spec_file_path` — the including file, different only for a shared example
      # group — would print two halves that come from different files.
      it "locates itself by the file the line number belongs to" do
        row = observe(run, duration: 1.0, line_number: 7, file_path: "spec/support/shared.rb",
                           spec_file_path: "spec/models/invoice_spec.rb")

        expect(row.location_label).to eq("spec/support/shared.rb:7")
      end

      # `TestRun.humanized_seconds` rounds to a tenth, which renders a real 0.04s measurement as
      # "0.0s" — a measurement wearing the spelling of a zero, at the head of a "slowest" list.
      it "renders a sub-minute duration at a precision that cannot print a real measurement as zero" do
        expect(observe(run, duration: 0.04, line_number: 1).duration_label).to eq("0.04s")
        expect(observe(run, duration: 12.5, line_number: 2).duration_label).to eq("12.50s")
      end

      it "says a duration is below its own resolution rather than printing a zero" do
        expect(observe(run, duration: 0.004, line_number: 1).duration_label).to eq("< 0.01s")
      end

      # A minute and over reads in the words this page already gives a run or a shard.
      it "hands a long example to the page's own duration wording" do
        expect(observe(run, duration: 252.0, line_number: 1).duration_label).to eq("4m 12s")
      end

      it "says an untimed row reported nothing, rather than formatting a nil as zero" do
        expect(observe(run, duration: nil, line_number: 1).duration_label).to eq("not reported")
      end

      # The row half of the outcome disclosure. `outcome` is nullable and nothing platform-side
      # validates the string, so the cell quotes what arrived rather than interpreting it.
      it "quotes the outcome CI reported, in CI's own word for it" do
        expect(observe(run, duration: 1.0, line_number: 1, outcome: "failed").outcome_label).to eq("failed")
        expect(observe(run, duration: 1.0, line_number: 2, outcome: "passed").outcome_label).to eq("passed")
      end

      # THE example this column exists for, and the `#duration_label` nil-guard wearing the worse
      # colour: "the client sent no outcome" made indistinguishable from "this test passed", on a
      # row that is in a "slowest" list and may have been slow because it was hanging.
      it "says a row with no outcome reported none, and does not wear a pass's colour" do
        row = observe(run, duration: 1.0, line_number: 1, outcome: nil)

        expect(row.outcome_label).to eq("not reported")
        expect(row.outcome_tone).to eq(:neutral)
        expect(row.outcome_tone).not_to eq(observe(run, duration: 1.0, line_number: 2,
                                                        outcome: "passed").outcome_tone)
      end

      it "tones the three names the producer is known to send" do
        expect(observe(run, duration: 1.0, line_number: 1, outcome: "failed").outcome_tone).to eq(:error)
        expect(observe(run, duration: 1.0, line_number: 2, outcome: "pending").outcome_tone).to eq(:warning)
        expect(observe(run, duration: 1.0, line_number: 3, outcome: "passed").outcome_tone).to eq(:success)
      end

      # Nothing platform-side validates this string — `Ingest::Payload` does not — so an
      # unrecognised value has to be echoed and left uncoloured. Folding it into the pass tone
      # would be the page asserting a verdict over a value nobody checked.
      it "echoes an outcome it does not recognise without colouring it as a pass" do
        row = observe(run, duration: 1.0, line_number: 1, outcome: "aborted")

        expect(row.outcome_label).to eq("aborted")
        expect(row.outcome_tone).to eq(:neutral)
      end
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
