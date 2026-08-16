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
    let(:one_file) { run.spec_observations.where(spec_file_path: "spec/d3/f3_spec.rb") }
    # The exact SELECT `SpecObservation.coverage_in` runs, built off the constant it runs it from
    # rather than retyped, so a sixth counter added there is a sixth counter EXPLAINed here. `pick`
    # is `limit(1).pluck`, hence the `.limit(1)`.
    let(:coverage) do
      run.spec_observations.select(Arel.sql(SpecObservation::COVERAGE_COUNTS.values.join(", "))).limit(1)
    end

    # One run's worth of rows, spread over 25 files in 5 DIRECTORIES so both rollups have something
    # to group and neither is a single group wearing the shape of a rollup. Five files per
    # directory, so the by-directory totals are not the by-file totals renamed: a directory here is
    # five files' worth of wall clock and outranks any one of them.
    def seed(test_run)
      now = Time.current
      rows = (1..rows_per_run).map do |index|
        path = "spec/d#{index % 5}/f#{index % 25}_spec.rb"
        {
          test_run_id: test_run.id, repository_id: test_run.repository_id,
          example_id: "./#{path}[1:#{index}]",
          spec_file_path: path, file_path: path,
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
        expect(one_file.pluck(:spec_file_path).uniq).to eq(["spec/d3/f3_spec.rb"])
      end

      # The rung above, through the read the directory panel actually makes, and asserted the same
      # way for the same reason: a rollup that loses or double-counts an area's rows is still a
      # plausible-looking list of directories, and only the run's own total catches it. It is also
      # what pins the two rollups to ONE population — the by-file totals above sum to this same
      # figure, so a directory grouping that dropped the rows of a file it could not place would
      # disagree with its own sibling rather than merely look short.
      it "rolls the whole run up by directory through the read the panel makes" do
        directories = described_class.directory_durations_in(run, limit: 100)

        expect(directories.size).to eq(5)
        expect(directories.sum { |_path, total, _recorded, _timed| total })
          .to be_within(0.001).of(run.spec_observations.sum(:duration_seconds))
        # And every row the run wrote is under exactly one of those areas.
        expect(directories.sum { |_path, _total, recorded, _timed| recorded }).to eq(rows_per_run)
      end

      # The grain is genuinely coarser than the one below it, asserted rather than assumed: five
      # files to a directory here, so a rollup that had silently stayed at the file grain (a
      # grouping expression that captured the whole path) would come back with 25 rows and totals
      # equal to the by-file ones.
      it "groups the areas above the files, not alongside them" do
        directories = described_class.directory_durations_in(run, limit: 100)
        files = described_class.file_durations_in(run, limit: 100)

        expect(directories.map(&:first).sort).to eq(%w[spec/d0 spec/d1 spec/d2 spec/d3 spec/d4])
        expect(files.size).to eq(25)
        expect(directories.sum { |_path, _total, recorded, _timed| recorded })
          .to eq(files.sum { |_path, _total, recorded, _timed| recorded })
      end
    end

    # The read whose grain is the DESCRIPTION rather than the file, the area or the example — the
    # one grain `seed` above deliberately does not produce, because every row it writes carries a
    # unique `name`. That is the ordinary suite, and it is exactly why these examples build the
    # repeated population explicitly: a run with no repetition is the state this read has to return
    # nothing for, and asserting against a fixture that accidentally contained repetition would
    # certify neither half.
    describe "the descriptions one run recorded more than once" do
      before { seed(run) }

      # Rows sharing one description, appended to a run whose 500 seeded rows are all unique. Timed
      # by default and untimed on request, because "this group cost 90 seconds" and "this group was
      # never measured" are the two states the ranking has to keep apart.
      def repeat(name, durations, path: "spec/d0/f0_spec.rb", test_run: run)
        now = Time.current
        rows = durations.each_with_index.map do |seconds, index|
          key = "#{path}-#{name}-#{index}"
          { test_run_id: test_run.id, repository_id: test_run.repository_id,
            example_id: "./#{path}[9:#{key}]", spec_file_path: path, file_path: path,
            line_number: 900 + index, name: name, duration_seconds: seconds,
            status: "unannotated", created_at: now, updated_at: now }
        end

        described_class.insert_all(rows)
      end

      def names_returned = described_class.repeated_descriptions_in(run, limit: 100).map(&:first)

      # The whole predicate: a description ONE example carries is not a repetition, and the 500
      # uniquely-named rows the seed wrote are the proof that `HAVING COUNT(*) > 1` is doing the
      # work rather than the fixture being small.
      it "returns the descriptions carried by more than one example, and no others" do
        repeat("shared across a loop", [1.0, 2.0])

        expect(names_returned).to eq(["shared across a loop"])
      end

      # Ranked by what the repetition COSTS and specifically not by how many examples are in it —
      # the ordering the panel's whole claim rests on. The three-example group here outranks the
      # eight-example one, which is the assertion that would fail if this were ordered by
      # `COUNT(*)`.
      it "ranks the groups by summed wall clock rather than by how many examples share the name" do
        repeat("three slow examples", [30.0, 30.0, 30.0])
        repeat("eight fast examples", Array.new(8, 0.25))

        expect(names_returned).to eq(["three slow examples", "eight fast examples"])
      end

      # `SUM(...) DESC` is NULLS FIRST in Postgres, so the naive ordering does not merely include
      # the group nobody timed — it names it the most expensive repetition in the run. The same
      # hazard `.directory_durations_in` carries `NULLS LAST` for, at this grain.
      it "sorts a group nothing timed to the end rather than to the head of the ranking" do
        repeat("timed group", [0.5, 0.5])
        repeat("untimed group", [nil, nil])

        expect(names_returned).to eq(["timed group", "untimed group"])
        expect(described_class.repeated_descriptions_in(run, limit: 100).last[1]).to be_nil
      end

      # Each group states what its own total was summed over, because `SUM` skips NULLs silently
      # and a half-measured group is otherwise indistinguishable, as a number, from a complete one.
      it "counts each group's examples and how many of them reported a timing" do
        repeat("half measured", [4.0, nil, 2.0])

        _name, total, recorded, timed = described_class.repeated_descriptions_in(run, limit: 100).first

        expect(total).to be_within(0.001).of(6.0)
        expect(recorded).to eq(3)
        expect(timed).to eq(2)
      end

      # The files are what let a reader go and look, and a group spanning two of them is a
      # disclosure the panel makes rather than an error. `ARRAY_AGG(DISTINCT …) FILTER (…)`, so the
      # list is de-duplicated and a null never arrives as a nil element inside it.
      it "names the distinct spec files the group's examples ran in" do
        repeat("spans two files", [1.0], path: "spec/d0/a_spec.rb")
        repeat("spans two files", [1.0], path: "spec/d1/b_spec.rb")

        expect(described_class.repeated_descriptions_in(run, limit: 100).first[4])
          .to contain_exactly("spec/d0/a_spec.rb", "spec/d1/b_spec.rb")
      end

      # A null name is not a description and two nulls are not one test. Pooling them would invent
      # the largest repetition in the run out of rows that share nothing at all — here, the three
      # most expensive rows the run wrote.
      it "excludes the rows carrying no description rather than pooling them into one group" do
        repeat(nil, [50.0, 50.0, 50.0], path: "spec/d0/unnamed_spec.rb")

        expect(names_returned).to be_empty
      end

      # `COUNT(*) OVER ()` runs after `GROUP BY` and its `HAVING` and before the `LIMIT`, so it
      # counts repeated DESCRIPTIONS and counts all of them however few come back. Without it a
      # capped list's own length is the only figure available, and three repetitions and three
      # hundred would render identically.
      it "reports how many repeated descriptions the run holds, before the cap" do
        6.times { |index| repeat("group #{index}", [index + 1.0, index + 1.0]) }

        capped = described_class.repeated_descriptions_in(run, limit: 2)

        expect(capped.size).to eq(2)
        expect(capped.map { |row| row[5] }.uniq).to eq([6])
      end

      # The two window totals describe the whole repeated population rather than the head of it
      # that fit on the page — on a truncated run those are different numbers, and a coverage
      # sentence built on the listed rows would be a claim about the page.
      it "reports the examples every repeated description covers and times, before the cap" do
        repeat("first group", [1.0, nil])
        repeat("second group", [2.0, 2.0, nil])

        _name, _total, _recorded, _timed, _paths, groups, repeated_recorded, repeated_timed =
          described_class.repeated_descriptions_in(run, limit: 1).first

        expect(groups).to eq(2)
        expect(repeated_recorded).to eq(5)
        expect(repeated_timed).to eq(3)
      end

      # The gate an empty ranking cannot provide for itself: a run that wrote no rows and a run
      # whose every description is unique both return nothing, and only the first of them is
      # silence.
      it "counts the run's rows and the ones carrying no description, in one read" do
        repeat(nil, Array.new(7, 0.1), path: "spec/d0/unnamed_spec.rb")

        expect(described_class.description_presence_in(run))
          .to eq(recorded_count: rows_per_run + 7, unnamed_count: 7)
      end

      it "reports a run that wrote no rows as zero of both rather than as an absence" do
        empty_run = create_test_run(repository: repository)

        expect(described_class.description_presence_in(empty_run))
          .to eq(recorded_count: 0, unnamed_count: 0)
      end
    end

    # The read whose grain is the run's ANNOTATION STATUS — the slice behind the dashboard's
    # *"SpecGuard cannot see the other N tests"*, and the only read on this model that looks at
    # `status` at all.
    #
    # `seed` above writes every row `unannotated`, which is the faithful default (a suite mid-adoption
    # is mostly unannotated, and the ingest fixtures say so) and is exactly the fixture that would
    # certify nothing here: a predicate that had been dropped altogether returns the same 500 rows.
    # So these examples ANNOTATE part of the seeded run explicitly, and every assertion is about what
    # the predicate leaves behind.
    describe "the examples one run recorded without an annotation" do
      before { seed(run) }

      # Flips seeded rows to `annotated`, which is the only status `Ingest::Payload::STATUSES` admits
      # beside the one this read selects — the fact that makes "not unannotated" the same set as
      # "annotated" and lets the API reconcile this list against `total_specs - annotated_specs`.
      def annotate(count)
        run.spec_observations.order(:id).limit(count).update_all(status: "annotated")
      end

      it "returns the run's unannotated rows and no annotated one" do
        annotate(3)
        rows = described_class.unannotated_in(run, limit: rows_per_run).to_a

        expect(rows.size).to eq(rows_per_run - 3)
        expect(rows.map(&:status).uniq).to eq(["unannotated"])
        expect(rows.map(&:test_run_id).uniq).to eq([run.id])
      end

      # The window is counted after the WHERE and before the LIMIT, so it describes the run's whole
      # unannotated population rather than the page — which is the figure the API serves as
      # `recorded_count` and invites a client to reconcile against the run's counters.
      it "counts the whole unannotated population on every row of a capped page" do
        annotate(100)
        rows = described_class.unannotated_in(run, limit: 10).to_a

        expect(rows.size).to eq(10)
        expect(rows.map { it["unannotated_recorded_count"] }.uniq).to eq([rows_per_run - 100])
      end

      # File-navigable, and a total order at every term — which the cap makes load-bearing rather
      # than tidy: a reader annotating one page and asking again must be walking a list, not
      # re-rolling one. `seed` writes `line_number` ascending across 25 files, so a read that had
      # kept insertion order would come back in `id` order and disagree here.
      it "orders by file, then line, then id, the same way twice" do
        first = described_class.unannotated_in(run, limit: 40).to_a
        second = described_class.unannotated_in(run, limit: 40).to_a

        expect(first.map { [it.spec_file_path, it.line_number, it.id] })
          .to eq(first.map { [it.spec_file_path, it.line_number, it.id] }.sort)
        expect(first.map(&:id)).to eq(second.map(&:id))
        expect(first.map(&:spec_file_path).uniq.size).to be > 1
      end

      # A fully-annotated run is the state the metric exists to REACH, so it is an ordinary empty
      # read rather than an error — and the window has no row to ride on, which is why the caller's
      # count is a `to_i` over nil rather than an assumption that one row came back.
      it "returns nothing for a run whose every example is annotated" do
        annotate(rows_per_run)

        expect(described_class.unannotated_in(run).to_a).to be_empty
      end

      # Scoped to ONE run, asserted rather than assumed: the whole point of the API block is that it
      # describes the run `run_anchor` names, and a read that had narrowed on `status` alone would
      # return the other run's rows too and still look right on a single-run fixture.
      it "narrows to the run it was handed and not to the repository" do
        other = create_test_run(repository: repository, commit_sha: "feedfacecafebabf")
        seed(other)

        expect(described_class.unannotated_in(other, limit: rows_per_run).map(&:test_run_id).uniq)
          .to eq([other.id])
      end

      # == Where in the run the worklist STARTS
      #
      # The read's default is the whole run in one order, capped — which is a worklist nobody can
      # choose a place in. These examples are about the two narrowings that let a reader start where
      # the work is, and each is asserted against the seeded run's OTHER rows rather than only against
      # its own: a predicate that had been dropped returns a superset that still looks like a list of
      # unannotated examples.
      describe "narrowed to one file or one area" do
        # `seed` writes `spec/d#{i % 5}/f#{i % 25}_spec.rb`, so a file number and its directory number
        # are congruent mod 5 — `f3` lives in `d3`, alongside `f8`, `f13`, `f18` and `f23`.
        let(:one_file) { "spec/d3/f3_spec.rb" }
        let(:one_area) { "spec/d3" }

        it "returns one file's unannotated rows and no other file's" do
          annotate(3)
          rows = described_class.unannotated_in(run, limit: rows_per_run, spec_file: one_file).to_a

          expect(rows).to be_present
          expect(rows.map(&:spec_file_path).uniq).to eq([one_file])
          expect(rows.map(&:status).uniq).to eq(["unannotated"])
          # And the run holds more unannotated rows than that, so the narrow is a predicate doing
          # work rather than a fixture that has only one file in it.
          expect(described_class.unannotated_in(run, limit: rows_per_run).size).to be > rows.size
        end

        it "counts the FILE's unannotated population rather than the run's" do
          in_file = run.spec_observations.where(spec_file_path: one_file).count
          rows = described_class.unannotated_in(run, limit: 5, spec_file: one_file).to_a

          expect(rows.size).to eq(5)
          expect(rows.map { it["unannotated_recorded_count"] }.uniq).to eq([in_file])
          expect(in_file).to be < rows_per_run
        end

        it "returns one area's unannotated rows and no other area's" do
          rows = described_class.unannotated_in(run, limit: rows_per_run, spec_directory: one_area).to_a

          expect(rows.map(&:spec_file_path).uniq.sort)
            .to eq(["spec/d3/f13_spec.rb", "spec/d3/f18_spec.rb", "spec/d3/f23_spec.rb",
                    "spec/d3/f3_spec.rb", "spec/d3/f8_spec.rb"])
          expect(rows.map { it["unannotated_recorded_count"] }.uniq).to eq([rows.size])
        end

        # ⭐ THE PREFIX TRAP, and the reason this example inserts its own rows. `DIRECTORY_EXPRESSION`
        # is the IMMEDIATE PARENT of the including file compared for EQUALITY — `spec/d3/nested` is
        # its own area, not part of `spec/d3` — and a `LIKE 'spec/d3%'` written to make "the whole
        # subtree" work would be a fifth directory semantics on this table. The seeded run is flat, so
        # nothing in it could tell an equality from a prefix; a subdirectory has to exist for the
        # assertion to mean anything.
        it "excludes a SUBDIRECTORY's rows, because an area is the immediate parent and not a prefix" do
          nested = "spec/d3/nested/deep_spec.rb"
          now = Time.current
          described_class.insert_all([{ test_run_id: run.id, repository_id: run.repository_id,
                                        example_id: "./#{nested}[1:1]", spec_file_path: nested,
                                        file_path: nested, line_number: 1, name: "nested example",
                                        duration_seconds: 0.1, outcome: "passed",
                                        status: "unannotated", created_at: now, updated_at: now }])

          paths = described_class.unannotated_in(run, limit: rows_per_run, spec_directory: one_area)
                                 .map(&:spec_file_path)

          expect(paths).not_to include(nested)
          # And the row IS in the run and IS unannotated, so its absence above is the equality doing
          # work rather than the insert having failed.
          expect(described_class.unannotated_in(run, limit: rows_per_run, spec_directory: "spec/d3/nested")
                                .map(&:spec_file_path)).to eq([nested])
        end

        # Both narrowings AND, with no precedence rule between them: a coherent pair is the
        # intersection, which for a file inside the area it names is the file.
        it "intersects the two when both are given" do
          rows = described_class.unannotated_in(run, limit: rows_per_run, spec_file: one_file,
                                                     spec_directory: one_area).to_a

          expect(rows.map(&:spec_file_path).uniq).to eq([one_file])
          expect(rows.size)
            .to eq(described_class.unannotated_in(run, limit: rows_per_run, spec_file: one_file).size)
        end

        # And a contradictory pair is an honest empty intersection rather than one of the two being
        # silently dropped — which is what a precedence rule would have made it.
        it "returns nothing when the file named is not in the area named" do
          rows = described_class.unannotated_in(run, limit: rows_per_run, spec_file: one_file,
                                                     spec_directory: "spec/d1").to_a

          expect(rows).to be_empty
        end

        # An unknown path is an ordinary empty read at this grain, exactly as it is one rung up: no
        # error, and specifically no prefix match onto the neighbour it was nearly spelled as.
        it "answers a path this run recorded nothing for with no rows" do
          expect(described_class.unannotated_in(run, spec_file: "spec/d3/f3_spec.rbx").to_a).to be_empty
          expect(described_class.unannotated_in(run, spec_directory: "spec/d").to_a).to be_empty
        end

        # The narrow does not loosen the run bound: a second run's rows at the same path stay out.
        it "still narrows to the run it was handed" do
          other = create_test_run(repository: repository, commit_sha: "feedfacecafebabf")
          seed(other)

          expect(described_class.unannotated_in(other, limit: rows_per_run, spec_file: one_file)
                                .map(&:test_run_id).uniq).to eq([other.id])
        end
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
      # Not a query counter, so none of the shared helpers in spec/support/query_capture.rb fit: it
      # keeps the FIRST matching statement to feed EXPLAIN, and must run under
      # `unprepared_statement` so the captured SQL carries its literals.
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

      # The same certification for the SQL the drill-down panel ACTUALLY runs, captured off the
      # wire rather than EXPLAINed from the hand-written `one_file` above it — that relation is the
      # predicate alone, and the panel's read adds a projection, an ordering and a cap on top of
      # it. A plan assertion against the shorter copy would be asserting nothing about the panel.
      #
      # This is the read the composite index exists FOR, which the by-file ROLLUP's example above
      # says in as many words: a whole-run grouping gets nothing from the wider index, and this
      # equality predicate on both of its columns is what earns it. So the assertion names that
      # index specifically rather than matching the shared `INDEXED_BY_RUN` — falling back to the
      # narrow `test_run_id` index here would mean reading every row of the run to answer a
      # question about one file, which at the design point is the whole cost this panel avoids.
      #
      # The ORDER BY is on `duration_seconds`, which no index here leads on, so the file's rows are
      # sorted after they are read. That is bounded by the size of the FILE — twenty rows at this
      # seed — and is exactly why the read must not instead ride
      # `index_spec_observations_on_test_run_id_and_duration_seconds`, whose backward scan would
      # walk the run from its slowest example down, discarding every row belonging to another file.
      #
      # An EQUALITY predicate, and deliberately not a subtree: "every row under `spec/d3/`" is a
      # PREFIX predicate, which is what a `text_pattern_ops` index serves and this read issues none
      # of. That is what let the panel ship with no migration.
      it "reads the panel's one-file drill-down off the by-file index" do
        plan = plan_for_actual_sql { described_class.in_file(run, "spec/d3/f3_spec.rb").to_a }

        expect(plan).to include("index_spec_observations_on_test_run_id_and_spec_file_path")
        expect(plan).not_to match(/Seq Scan on spec_observations/)
      end

      # The same certification for the description drill-down beside it, and the assertion is
      # deliberately the SHARED `INDEXED_BY_RUN` matcher rather than a named index — which is the
      # whole finding this example carries.
      #
      # There is no `(test_run_id, name)` index and this read does not want one: it narrows on
      # `test_run_id`, reads one run's rows through the index that leads on it, and sorts the
      # matching handful afterwards. `index_spec_observations_on_repository_id_and_name` DOES exist
      # and is NOT the path here, for the reason `.repeated_descriptions_in` states at this exact
      # grain — it leads on `repository_id`, which serves a WINDOW of runs, and a single-run narrow
      # does not begin with it. What has to stay true at the design point is what this asserts: one
      # run reached through an index rather than every run's rows walked.
      #
      # The ORDER BY is on `duration_seconds`, which no index here leads on, so the group's rows are
      # sorted after they are read — bounded by the size of the RUN, and precisely why this must not
      # instead ride `index_spec_observations_on_test_run_id_and_duration_seconds`, whose backward
      # scan would walk the run from its slowest example down, discarding every row carrying another
      # description.
      #
      # Captured off the wire rather than EXPLAINed from a hand-written copy, for the reason the
      # example above gives: the predicate alone is not the read the panel makes, which adds a
      # projection, an ordering and a cap on top of it.
      it "reads the panel's one-description drill-down off an index rather than scanning the table" do
        plan = plan_for_actual_sql { described_class.with_description(run, "example 3").to_a }

        expect(plan).to match(INDEXED_BY_RUN)
        expect(plan).not_to match(/Seq Scan on spec_observations/)
      end

      # The same certification for the ANNOTATION drill-in, and the assertion is deliberately the
      # SHARED `INDEXED_BY_RUN` matcher rather than a named index — which is the finding this example
      # carries.
      #
      # There is no `(test_run_id, status)` index and this read does not want one: `status` is two
      # values over the whole table, which is the shape an index serves worst, and it is the RUN
      # narrow that makes the read affordable. What has to stay true at the design point is what this
      # asserts — one run reached through an index rather than every run's rows walked — and the
      # `status` predicate then filters the rows already read.
      #
      # The ORDER BY leads on `spec_file_path`, which `index_spec_observations_on_test_run_id_and_spec_file_path`
      # DOES lead on after the run, so the planner is free to take the sort from that index or to read
      # the narrower one and sort afterwards; both are bounded by the RUN. The matcher tolerates
      # either for that reason, exactly as it tolerates the two access methods its own comment names.
      #
      # Captured off the wire rather than EXPLAINed from a hand-written copy, for the reason the two
      # examples above give: the predicate alone is not the read the block makes, which adds a
      # projection, an ordering and a cap on top of it.
      it "reads the run's unannotated examples off an index rather than scanning the table" do
        plan = plan_for_actual_sql { described_class.unannotated_in(run).to_a }

        expect(plan).to match(/#{INDEXED_BY_RUN.source}|index_spec_observations_on_test_run_id_and_spec_file_path/)
        expect(plan).not_to match(/Seq Scan on spec_observations/)
      end

      # THE SAME CERTIFICATION FOR THE TWO NARROWED SHAPES OF THAT READ, and they are two examples
      # rather than one because they buy different things and could fail apart.
      #
      # `spec_file` narrows on the SECOND COLUMN of
      # `index_spec_observations_on_test_run_id_and_spec_file_path`, so it is strictly cheaper than the
      # un-narrowed read above and the planner has a composite index to reach for. `spec_directory` is
      # an EXPRESSION predicate over a column no index expresses that way, so it buys nothing and is
      # the run-bounded scan `.files_in_directory` already ships — which is the point: the bound that
      # has to hold at the 20,000-example design point is the RUN, and it is the run narrow that
      # supplies it in both cases. The assertion is therefore the same one, and it is the shared
      # matcher rather than a named index for the reason the example above gives.
      #
      # Captured off the wire rather than EXPLAINed from a hand-written copy, on this section's rule:
      # a narrowing added to the model and not to the certification would leave the certification
      # measuring a statement the endpoint no longer makes.
      it "reads ONE FILE's unannotated examples off an index rather than scanning the table" do
        plan = plan_for_actual_sql do
          described_class.unannotated_in(run, spec_file: "spec/d3/f3_spec.rb").to_a
        end

        expect(plan).to match(/#{INDEXED_BY_RUN.source}|index_spec_observations_on_test_run_id_and_spec_file_path/)
        expect(plan).not_to match(/Seq Scan on spec_observations/)
      end

      it "reads ONE AREA's unannotated examples off an index rather than scanning the table" do
        plan = plan_for_actual_sql { described_class.unannotated_in(run, spec_directory: "spec/d3").to_a }

        expect(plan).to match(/#{INDEXED_BY_RUN.source}|index_spec_observations_on_test_run_id_and_spec_file_path/)
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

      # The same certification for the rung above, and the reason no migration came with it. The
      # view comment this slice deleted told future authors a subtree rollup was waiting on a
      # `text_pattern_ops` index; that index type serves a prefix PREDICATE — "every row under
      # `spec/models/`" — and this read issues none. It narrows on `test_run_id`, a plain column
      # with a plain index, and GROUPS on an expression, which decides nothing about the access
      # path. So the ACCESS PATH is the by-file one above: one run reached through an index, for
      # the reason the bare grouping two examples up states — the aggregate has to touch the heap
      # for `duration_seconds` either way, so no wider index buys a whole-run grouping anything.
      #
      # MEASURED here rather than argued from the sibling: this is the assertion that would have
      # sent the slice to a migration had the premise been wrong, so it is the one that must run
      # against a real planner with real statistics at the 20-run seed.
      it "reads the panel's by-directory rollup off an index rather than scanning the table" do
        plan = plan_for_actual_sql { described_class.directory_durations_in(run) }

        expect(plan).to match(INDEXED_BY_RUN)
        expect(plan).not_to match(/Seq Scan on spec_observations/)
      end

      # The AGGREGATION STRATEGY, which is a different fact from the access path and was being
      # smuggled in under it. The example above cannot see this: `INDEXED_BY_RUN` matches the scan
      # at the bottom of the plan and stayed green when `COUNT(DISTINCT name)` was added, while the
      # aggregation above that scan changed from `HashAggregate` to `Sort` + `GroupAggregate`. A
      # certification that cannot distinguish the two plans it is offered certifies nothing about
      # the difference — the project's own Vacuous Green shape, pointed at the measurement rather
      # than at a gate.
      #
      # So the strategy is pinned explicitly, and pinned as the WORSE one it actually is. A
      # `DISTINCT` aggregate disqualifies hashed aggregation in Postgres, so this read sorts every
      # one of the run's rows on the directory expression and on `name` before grouping them. That
      # is the price of the distinct-description column and `.directory_durations_in`'s comment
      # prices it in measured sort memory and buffer counts; what this example is for is making an
      # edit that changes the price VISIBLE. Drop the `DISTINCT` and this reddens on the
      # `GroupAggregate`; add a second sort or lose the index scan underneath it and the sort key
      # or the sibling example above reddens instead.
      #
      # The sort key is asserted, not just the `Sort` node: a plan can sort for the ORDER BY alone
      # — the by-file rollup above does, on `SUM(duration_seconds)` — and matching a bare `Sort`
      # would pass on that one too, which is exactly the indiscriminate assertion this example
      # exists to stop being.
      it "pays for the distinct-description count with a sort, and says so in the plan" do
        plan = plan_for_actual_sql { described_class.directory_durations_in(run) }

        expect(plan).to include("GroupAggregate")
        expect(plan).to match(/Sort Key: .*substring.*, name/)
        expect(plan).not_to include("HashAggregate")
      end

      # The falsifier for the example above, and the reason it is not asserting an accident: the
      # SAME read WITHOUT the `DISTINCT` aggregate — everything else identical, same seed, same
      # statistics — hash-aggregates. So `GroupAggregate` above is caused by the column this slice
      # added rather than by the size of the table or the shape of the grouping, and a future edit
      # that removes the `DISTINCT` will be told what it just changed.
      it "hash-aggregates the same grouping when the DISTINCT aggregate is taken away" do
        without_distinct = described_class.where(test_run_id: run.id)
          .group(Arel.sql(SpecObservation::DIRECTORY_EXPRESSION))
          .select(Arel.sql("#{SpecObservation::DIRECTORY_EXPRESSION}, SUM(duration_seconds), COUNT(*), COUNT(name)"))

        plan = plan_for(without_distinct)

        expect(plan).to include("HashAggregate")
        expect(plan).to match(INDEXED_BY_RUN)
      end

      # The same certification for the rung BETWEEN those two, and the reason it also ships without
      # a migration — which is the claim most worth measuring here, because this read is the one
      # that looks like it wants a `text_pattern_ops` index and does not.
      #
      # It adds an EXPRESSION predicate over the by-directory rollup above: `DIRECTORY_EXPRESSION =
      # ?`. No index on this table can serve that, and it therefore decides nothing about the access
      # path — `where(test_run_id:)` still does, exactly as it does for the rollup. A
      # `text_pattern_ops` index would serve `spec_file_path LIKE 'spec/d3/%'`, a PREFIX predicate;
      # this read issues none, and the example directly above in "what they return" pins that the
      # narrowing is an equality at one depth rather than a subtree. If a future edit turns it into
      # a prefix `LIKE`, that example fails first and this one records what the plan cost.
      #
      # This comment used to add "and the grouping hash-aggregates on top". Measured, it does not:
      # at this seed the planner estimates three groups and sorts, while `.file_durations_in` — same
      # table, same absence of a `DISTINCT` aggregate, 25 groups — hashes. For this read the
      # strategy is a cost tiebreak that moves with the data, so nothing here asserts one. Where a
      # strategy IS forced rather than chosen, it is pinned: see the by-directory rollup above,
      # whose `DISTINCT` aggregate rules hashing out and whose sort is asserted for that reason.
      it "reads the panel's one-directory drill-down off an index rather than scanning the table" do
        plan = plan_for_actual_sql { described_class.files_in_directory(run, "spec/d3") }

        expect(plan).to match(INDEXED_BY_RUN)
        expect(plan).not_to match(/Seq Scan on spec_observations/)
      end

      # The same certification for the read that spans TWO runs, and the reason it ships without a
      # migration. Twice the rows is not a different shape: it narrows on `test_run_id` with an `IN`
      # list of two, which `index_spec_observations_on_test_run_id` serves exactly as it serves one,
      # and the `FILTER` aggregates and window totals are expressions over the rows that scan
      # already reads. The `text_pattern_ops` index a subtree rollup would want serves a prefix
      # PREDICATE and this read issues none.
      #
      # A two-value `IN` list makes the `Bitmap Index Scan` branch of `INDEXED_BY_RUN` MORE likely
      # than the single-id reads above do, and that is not a regression: the comment on that matcher
      # records that it was widened deliberately because which of the two Postgres picks is decided
      # by dead-tuple bloat and RSpec ordering rather than by the query. Narrowing it back to the
      # plain `Index Scan` spelling would redden this example on ordering alone. The reach here is
      # carried by the `Seq Scan` assertion beside it: unscope this aggregate from its two runs and
      # the plan walks every run's rows whatever access method it had before.
      #
      # == A THIRD access path, which only this read can have
      #
      # It has its own matcher rather than the shared `INDEXED_BY_RUN`, and the extra spelling is
      # `Index Only Scan`. This is the one read here that projects NOTHING outside an index: it
      # narrows on `test_run_id` and groups and counts on `spec_file_path`, both columns of
      # `index_spec_observations_on_test_run_id_and_spec_file_path`, so Postgres can answer it
      # without touching the heap at all. Every sibling above has to fetch `duration_seconds` or
      # `outcome` and therefore never can — which is why the shared constant is left exactly as it
      # is rather than widened on their behalf.
      #
      # Whether that path is TAKEN depends on the visibility map, which depends on when the table
      # was last vacuumed — the same class of planner tiebreak, decided by the same suite-ordering
      # accident, that the shared matcher was widened for. Observed here both ways. It is a
      # STRONGER plan than the two the shared matcher already accepts, not a weaker one, so
      # accepting it concedes nothing: all three spellings say the rows were reached through an
      # index leading with `test_run_id`, and the `Seq Scan` assertion is what makes that claim
      # falsifiable.
      INDEXED_OR_COVERED_BY_RUN =
        /(?:Index Scan using|Index Only Scan using|Bitmap Index Scan on) index_spec_observations_on_test_run_id\w*/

      # The second run is one of the nineteen the seed already built rather than a twenty-first,
      # so this example certifies the plan at exactly the table size and statistics the examples
      # above are certified at.
      it "reads the panel's two-run by-area comparison off an index rather than scanning the table" do
        previous_run = repository.test_runs.where.not(id: run.id).first
        plan = plan_for_actual_sql { described_class.directory_growth_between(run, previous_run) }

        expect(plan).to match(INDEXED_OR_COVERED_BY_RUN)
        expect(plan).not_to match(/Seq Scan on spec_observations/)
      end

      # The same certification for the two-run comparison that sums DURATIONS instead of counting
      # rows, and it ships without a migration for the same reason the count read above does: it
      # narrows on `test_run_id` with an `IN` list of two, which `index_spec_observations_on_test_run_id`
      # serves exactly as it serves one, and groups on an EXPRESSION, which decides nothing about
      # the access path. The `FILTER` aggregates and window totals are expressions over rows that
      # scan already reads.
      #
      # The ONE honest difference from the read above, and the reason this asserts the SHARED
      # matcher rather than the widened one beside it: `SUM(duration_seconds)` projects a column
      # that is in no index leading with `test_run_id`, so Postgres has to touch the heap and an
      # `Index Only Scan` is not available to this query at all. That is the same tradeoff
      # `.directory_durations_in` carries — the two spellings are not interchangeable and using the
      # wider one here would accept a plan this read cannot have.
      it "reads the panel's two-run by-area RUNTIME comparison off an index rather than scanning" do
        previous_run = repository.test_runs.where.not(id: run.id).first
        plan = plan_for_actual_sql { described_class.directory_runtime_growth_between(run, previous_run) }

        expect(plan).to match(INDEXED_BY_RUN)
        expect(plan).not_to match(/Seq Scan on spec_observations/)
      end

      # The same certification for the two-run comparison NARROWED to one area, and the reason it
      # ships without a migration either. The extra predicate changes nothing about the access path:
      # it narrows on `test_run_id` with the same two-value `IN` list the read above does, and the
      # area predicate is an EXPRESSION over `spec_file_path` that no index can serve — it only ever
      # removes rows from a scan that was already happening.
      #
      # The `text_pattern_ops` index a SUBTREE narrow would want serves a prefix predicate, and this
      # read issues none: the example in "what they return" pins that the narrowing is an equality
      # at one depth. If a future edit turns it into a prefix `LIKE`, that example fails first and
      # this one records what the plan cost.
      #
      # `INDEXED_OR_COVERED_BY_RUN` rather than the shared matcher, for the reason the by-area count
      # read above claims it: this projects nothing outside
      # `index_spec_observations_on_test_run_id_and_spec_file_path` — it narrows on `test_run_id`,
      # and groups, counts and filters on `spec_file_path` — so an `Index Only Scan` is available to
      # it and is a STRONGER plan than the two the shared matcher accepts, not a weaker one. Which
      # of the three Postgres picks turns on the visibility map, hence on when the table was last
      # vacuumed; the `Seq Scan` assertion beside it is what keeps the claim falsifiable whichever
      # it picks.
      it "reads the panel's two-run one-area comparison off an index rather than scanning the table" do
        previous_run = repository.test_runs.where.not(id: run.id).first
        plan = plan_for_actual_sql { described_class.file_growth_between(run, previous_run, "spec/d3") }

        expect(plan).to match(INDEXED_OR_COVERED_BY_RUN)
        expect(plan).not_to match(/Seq Scan on spec_observations/)
      end

      # The same certification for the two-run one-area comparison that sums DURATIONS, and it ships
      # without a migration for the reasons its two parents each give one half of: it narrows on
      # `test_run_id` with the same two-value `IN` list, and the area predicate is an EXPRESSION no
      # index can serve, which only ever removes rows from a scan that was already happening.
      #
      # `INDEXED_BY_RUN` rather than the widened matcher the COUNT narrow beside it claims, and the
      # difference is inherited from `.directory_runtime_growth_between` rather than re-reasoned:
      # `SUM(duration_seconds)` projects a column that is in no index leading with `test_run_id`, so
      # Postgres has to touch the heap and an `Index Only Scan` is not available to this query at
      # all. Using the wider spelling here would accept a plan this read cannot have — which is
      # precisely the false-ACCEPT a query count would also give.
      it "reads the two-run one-area RUNTIME comparison off an index rather than scanning" do
        previous_run = repository.test_runs.where.not(id: run.id).first
        plan = plan_for_actual_sql do
          described_class.file_runtime_growth_between(run, previous_run, "spec/d3")
        end

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

      # The certification for the read whose grain is the DESCRIPTION, and the reason it ships
      # without a migration — MEASURED here rather than argued from the by-directory sibling, for
      # the reason that example states about itself: this is the assertion that would have sent the
      # slice to a migration had the premise been wrong, so it is the one that has to run against a
      # real planner with real statistics at the 20-run seed.
      #
      # The premise is that a whole-run `GROUP BY name` is the same shape as a whole-run `GROUP BY`
      # an expression: `where(test_run_id:)` decides the ACCESS PATH, which is what this example
      # asserts. It does NOT claim the strategy above that scan — this comment used to say "and the
      # grouping hash-aggregates on top" and that is measurably false, because the read's
      # `ARRAY_AGG(DISTINCT spec_file_path)` disqualifies hashed aggregation exactly as the
      # by-directory rollup's `COUNT(DISTINCT name)` does. What makes the access path worth
      # measuring rather than assuming is that unlike
      # `DIRECTORY_EXPRESSION` there IS an index over `name` on this table —
      # `index_spec_observations_on_repository_id_and_name` — and it is NOT the path here, because
      # it leads on `repository_id`. That index is what `.outcome_composition_in` rides for a
      # WINDOW of runs; a single-run narrow does not begin with its leading column, and reaching
      # for it would mean walking a whole repository's rows to answer a question about one run.
      #
      # `SUM(duration_seconds)` projects a column outside every index leading with `test_run_id`,
      # so the aggregate has to touch the heap and an `Index Only Scan` is not available to this
      # query — the same tradeoff `.directory_durations_in` carries, which is why this asserts the
      # shared matcher rather than the widened `INDEXED_OR_COVERED_BY_RUN` beside it.
      it "reads the panel's repeated-description ranking off an index rather than scanning" do
        plan = plan_for_actual_sql { described_class.repeated_descriptions_in(run) }

        expect(plan).to match(INDEXED_BY_RUN)
        expect(plan).not_to match(/Seq Scan on spec_observations/)
      end

      # The second read that panel makes, and the one that answers for the rows the ranking above
      # had to exclude. Certified separately because it is a separate round trip — the ranking
      # drops null names in its WHERE clause, so no window over it could ever have counted them —
      # and a plan assertion on the ranking alone would say nothing about the query that produces
      # the caption beside it.
      it "counts the run's described and undescribed rows off an index rather than scanning" do
        plan = plan_for_actual_sql { described_class.description_presence_in(run) }

        expect(plan).to match(INDEXED_BY_RUN)
        expect(plan).not_to match(/Seq Scan on spec_observations/)
      end
    end
  end

  # The reads that span RUNS — everything above this point is bounded to one run on purpose, and
  # these four are the first that are not. Each of them is a step of the "Tests whose outcome
  # changed" panel; what they return is asserted here, and what the PAGE does with them is
  # spec/requests/repository_unstable_tests_spec.rb.
  describe "the questions a window of runs has to answer" do
    let(:rows_per_run) { 300 }
    let(:repository) { create_repository }
    # Twenty runs in the table and six of them in the window, so "read the window through an index"
    # is a decision the planner makes rather than a foregone conclusion — the same reason the
    # single-run block above seeds twenty.
    let(:runs) { (1..20).map { |i| create_test_run(repository: repository, commit_sha: "sha#{i}") } }
    let(:window) { runs.first(6) }
    let(:window_ids) { window.map(&:id) }

    # `example 7` is the unstable one: it fails in every other run of the window and passes in the
    # rest. `example 13` fails in all of them — a broken test, not an unstable one, and the row
    # that keeps the candidate ordering honest. Every hundredth row carries no name at all.
    def outcome_for(index, run_index)
      return run_index.even? ? "failed" : "passed" if index == 7
      return "failed" if index == 13

      "passed"
    end

    def seed(test_run, run_index)
      now = Time.current
      rows = (1..rows_per_run).map do |index|
        {
          test_run_id: test_run.id, repository_id: repository.id,
          example_id: "./spec/f#{index % 15}_spec.rb[1:#{index}]",
          spec_file_path: "spec/f#{index % 15}_spec.rb", file_path: "spec/f#{index % 15}_spec.rb",
          line_number: index, name: (index % 100).zero? ? nil : "example #{index}",
          duration_seconds: 0.1, outcome: outcome_for(index, run_index),
          status: "unannotated", created_at: now, updated_at: now
        }
      end

      SpecObservation.insert_all(rows)
    end

    before { runs.each_with_index { |test_run, index| seed(test_run, index) } }

    describe "what they return" do
      it "counts the window's runs that recorded rows and those that reported an outcome" do
        expect(described_class.window_outcome_reporting(window_ids))
          .to eq(runs_with_rows: 6, runs_reporting_outcomes: 6)
      end

      # The gate the panel's whole honesty rests on. A window whose client sent no outcomes has
      # rows in every run and reports in none of them, and the two figures are what tell those
      # apart — a single count could not.
      it "separates a window that recorded rows from one that said how they ended" do
        SpecObservation.where(test_run_id: window_ids).update_all(outcome: nil)

        expect(described_class.window_outcome_reporting(window_ids))
          .to eq(runs_with_rows: 6, runs_reporting_outcomes: 0)
      end

      it "answers for a window of no runs without asking the database anything" do
        expect(described_class.window_outcome_reporting([]))
          .to eq(runs_with_rows: 0, runs_reporting_outcomes: 0)
      end

      # Only what failed, fewest failures first — and the total riding back on every row, counted
      # after the grouping and before the limit.
      it "names the descriptions that failed in the window, least-failing first" do
        expect(described_class.unstable_candidates_in(window_ids))
          .to eq([["example 7", 2], ["example 13", 2]])
      end

      it "keeps the least-failing end of the list when the cap bites" do
        expect(described_class.unstable_candidates_in(window_ids, limit: 1))
          .to eq([["example 7", 2]])
      end

      # A null name is not a test this read can follow across runs, so it never becomes a group.
      it "never groups the unnamed rows into a description of their own" do
        expect(described_class.unstable_candidates_in(window_ids).map(&:first)).to all(be_present)
      end

      it "composes each candidate over the whole window" do
        composed = described_class.outcome_composition_in(
          repository_id: repository.id, run_ids: window_ids, names: ["example 7"]
        )

        # name, recorded, runs, reported, failed, failed runs, outcomes, files —
        # `SpecObservation::UNSTABLE_COMPOSITION`'s order, which is what the caller destructures by.
        expect(composed).to eq([["example 7", 6, 6, 6, 3, 3, %w[failed passed], ["spec/f7_spec.rb"]]])
      end

      # The composition is bounded to the window, not to the repository's whole history — the seven
      # runs outside it hold the same descriptions and must not be counted into these figures.
      it "counts only the runs of the window it was given" do
        composed = described_class.outcome_composition_in(
          repository_id: repository.id, run_ids: window_ids.first(2), names: ["example 13"]
        )

        expect(composed).to eq([["example 13", 2, 2, 2, 2, 2, ["failed"], ["spec/f13_spec.rb"]]])
      end

      it "counts the rows of the window that carried no description" do
        expect(described_class.unnamed_row_count_in(repository_id: repository.id, run_ids: window_ids))
          .to eq(18)
      end

      # The fifth read, and the one the four above cannot stand in for: they are the composition's
      # steps, and every one of them destroys the run axis on purpose. This is the same rows
      # UNGROUPED, so the sequence the aggregate summed over is legible again — a window whose
      # failures are the last four runs and one whose failures are scattered produce the same
      # `outcome_composition_in` tuple and different sequences here.
      it "returns one description's rows across the window, in the order the window was given" do
        sequence = described_class.outcome_sequence_in(
          repository_id: repository.id, run_ids: window_ids, name: "example 7"
        )

        expect(sequence.map(&:test_run_id)).to eq(window_ids)
        expect(sequence.map(&:outcome)).to eq(%w[failed passed failed passed failed passed])
      end

      # ORDERED BY THE WINDOW'S OWN ORDER and not by `id` or `created_at` — the property the whole
      # block rests on, asserted against a window handed in BACKWARDS. Ordering by either column
      # would answer this identically to the example above, which is what makes the reversal the
      # only assertion that separates them.
      it "follows the order it was handed rather than the table's own" do
        sequence = described_class.outcome_sequence_in(
          repository_id: repository.id, run_ids: window_ids.reverse, name: "example 7"
        )

        expect(sequence.map(&:test_run_id)).to eq(window_ids.reverse)
      end

      # The population counts ride back on every row, counted after the WHERE and before the LIMIT,
      # so the cap is disclosed against the sequence's real population rather than against itself.
      # `COUNT(outcome)` and not `COUNT(*)`: a run that recorded the test and reported nothing is
      # not a pass, and a truncated list whose silence a client could not count would put that
      # separation out of reach.
      it "rides the window's own counts back on the rows, before the cap" do
        SpecObservation.where(test_run_id: window_ids.first, name: "example 7").update_all(outcome: nil)

        sequence = described_class.outcome_sequence_in(
          repository_id: repository.id, run_ids: window_ids, name: "example 7", limit: 2
        )

        expect(sequence.length).to eq(2)
        expect(sequence.first["unstable_test_recorded_count"]).to eq(6)
        expect(sequence.first["unstable_test_reported_outcome_count"]).to eq(5)
      end

      # The cap takes the OLD end, because the window is handed in newest-first: "it has failed
      # since before this list starts" still names a regression, where a list cut the other way
      # answers "how is it doing lately" with the state of a month ago.
      it "keeps the head of the window when the cap bites" do
        sequence = described_class.outcome_sequence_in(
          repository_id: repository.id, run_ids: window_ids, name: "example 7", limit: 2
        )

        expect(sequence.map(&:test_run_id)).to eq(window_ids.first(2))
      end

      # Bounded to the window it was given, not to the repository's whole history — the fourteen
      # runs outside it hold the same description and must not appear in the sequence.
      it "reads only the runs of the window it was given" do
        sequence = described_class.outcome_sequence_in(
          repository_id: repository.id, run_ids: window_ids.first(2), name: "example 7"
        )

        expect(sequence.map(&:test_run_id)).to eq(window_ids.first(2))
      end

      # A description the window recorded nothing under is an ordinary answer and not an error — a
      # renamed test, an edited description, a stale bookmark.
      it "answers for a description the window never recorded, with no rows" do
        expect(described_class.outcome_sequence_in(
          repository_id: repository.id, run_ids: window_ids, name: "example 7 "
        )).to be_empty
      end

      it "answers for a window of no runs without asking the database anything" do
        expect(count_queries do
          expect(described_class.outcome_sequence_in(
            repository_id: repository.id, run_ids: [], name: "example 7"
          )).to be_empty
        end).to eq(0)
      end
    end

    # One index scan per step, and never a walk of every run's rows. Which index Postgres reaches
    # for is left to Postgres — the matchers accept the plain scan, the index-only scan and the
    # bitmap, for the reason `INDEXED_BY_RUN` above documents at length: the choice between them is
    # decided by table bloat and RSpec ordering rather than by anything about the query. The
    # `Seq Scan` refusal is what carries each assertion's reach: unscope any of these reads from
    # its window and the plan turns into a sequential scan of the whole table.
    describe "the plan Postgres chooses for each of them" do
      SCAN = /(?:Index Only Scan using|Index Scan using|Bitmap Index Scan on)/

      before { ActiveRecord::Base.connection.execute("ANALYZE spec_observations") }

      # The plan for the SQL each read ACTUALLY runs, captured off the wire rather than EXPLAINed
      # from a hand-written copy — a copy is a second definition of the query that can drift from
      # the one the panel makes. `unprepared_statement` inlines the binds, because `EXPLAIN` cannot
      # be handed a `$1`.
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

      # Observed: two index probes per run of the window, both off a `test_run_id` index, neither
      # of them touching a row past the one that answers it. The point of the lateral is that the
      # cost follows the window's LENGTH and not the suite's size — the aggregate spelling of this
      # question reads every row in the window to produce two integers.
      it "probes the window's runs through an index rather than reading the window" do
        plan = plan_for_actual_sql { described_class.window_outcome_reporting(window_ids) }

        expect(plan).to match(/#{SCAN} index_spec_observations_on_test_run_id\w*/)
        expect(plan).not_to match(/Seq Scan on spec_observations/)
      end

      # Observed: `index_spec_observations_on_test_run_id_and_outcome` — the index
      # `COVERAGE_COUNTS` declines to use and reserves in as many words for "the 'which tests
      # failed' list a later slice will want". This is that read, and the narrowing it makes
      # possible is what keeps the composition below off the whole window.
      it "narrows to the window's failures off the by-outcome index" do
        plan = plan_for_actual_sql { described_class.unstable_candidates_in(window_ids) }

        expect(plan).to include("index_spec_observations_on_test_run_id_and_outcome")
        expect(plan).to match(SCAN)
        expect(plan).not_to match(/Seq Scan on spec_observations/)
      end

      # Observed: `index_spec_observations_on_repository_id_and_name`, the second index this table
      # has carried unread. `repository_id` leads it, which is why the composition is scoped by
      # repository as well as by window — without that column there is no index on `name` to walk
      # and the grouping falls back to reading the runs whole.
      it "composes the candidates off the by-name index rather than scanning the table" do
        plan = plan_for_actual_sql do
          described_class.outcome_composition_in(repository_id: repository.id, run_ids: window_ids,
                                                 names: ["example 7", "example 13"])
        end

        expect(plan).to include("index_spec_observations_on_repository_id_and_name")
        expect(plan).to match(SCAN)
        expect(plan).not_to match(/Seq Scan on spec_observations/)
      end

      # A btree indexes its nulls, so `name IS NULL` is a range of that same index and the count
      # costs what the unnamed rows cost rather than what the window does.
      it "counts the unnamed rows off the by-name index too" do
        plan = plan_for_actual_sql do
          described_class.unnamed_row_count_in(repository_id: repository.id, run_ids: window_ids)
        end

        expect(plan).to include("index_spec_observations_on_repository_id_and_name")
        expect(plan).to match(SCAN)
        expect(plan).not_to match(/Seq Scan on spec_observations/)
      end

      # The drill-in below the composition, on the same index and for the same reason: it narrows on
      # `repository_id` AND `name`, which is what that index leads on, and without the first column
      # there would be no index on `name` to walk. The `array_position` ORDER BY sorts the rows
      # AFTERWARDS and is bounded by ONE DESCRIPTION over at most thirty runs — thirty rows here,
      # against the 6,000 the window holds — which is what makes this read constant in the size of
      # the suite rather than merely cheaper than the window.
      it "reads one description's run sequence off the by-name index rather than scanning" do
        plan = plan_for_actual_sql do
          described_class.outcome_sequence_in(repository_id: repository.id, run_ids: window_ids,
                                              name: "example 7").to_a
        end

        expect(plan).to include("index_spec_observations_on_repository_id_and_name")
        expect(plan).to match(SCAN)
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

    describe ".directory_durations_in" do
      # The panel's whole claim, and the one thing that makes this rung worth its own query: an
      # area's wall clock is the sum of every file under it, so a directory holding several
      # middling files outranks one holding a single heavier one. The by-file read on the same rows
      # orders these two areas the other way round — `refund_spec.rb` at 9.0 is the heaviest FILE
      # in the run and `spec/models` is not the heaviest AREA — which is the assertion that would
      # fail if this method were the by-file rollup relabelled.
      it "totals each directory's examples, heaviest directory first" do
        observe(run, duration: 1.5, line_number: 1, spec_file_path: "spec/models/order_spec.rb")
        observe(run, duration: 2.5, line_number: 2, spec_file_path: "spec/models/refund_spec.rb")
        observe(run, duration: 9.0, line_number: 3, spec_file_path: "spec/requests/checkout_spec.rb")
        observe(run, duration: 4.0, line_number: 4, spec_file_path: "spec/requests/refunds_spec.rb")
        observe(run, duration: 0.5, line_number: 5, spec_file_path: "spec/system/smoke_spec.rb")

        expect(described_class.directory_durations_in(run)).to eq(
          [["spec/requests", 13.0, 2, 2, 2, 2, 3],
           ["spec/models", 4.0, 2, 2, 2, 2, 3],
           ["spec/system", 0.5, 1, 1, 1, 1, 3]]
        )
      end

      # The IMMEDIATE parent, not an ancestor and not the whole prefix: `spec/models/orders` is its
      # own area and its time does not roll into `spec/models`. Every row therefore sits at the
      # depth of its own file, the areas are disjoint, and the totals sum to the run — the property
      # a nesting rollup would lose by counting the deep rows twice.
      it "groups on the immediate parent, so nested areas do not roll into their ancestors" do
        observe(run, duration: 1.0, line_number: 1, spec_file_path: "spec/models/order_spec.rb")
        observe(run, duration: 2.0, line_number: 2, spec_file_path: "spec/models/orders/refund_spec.rb")

        expect(described_class.directory_durations_in(run)).to eq(
          [["spec/models/orders", 2.0, 1, 1, 1, 1, 2],
           ["spec/models", 1.0, 1, 1, 1, 1, 2]]
        )
      end

      # A spec file at the repository root has no parent segment to capture, and the expression
      # comes back SQL NULL for it. An unnamed area on a ranked panel is worse than a named one, and
      # DROPPING the row would understate the run's wall clock at the one grain that is supposed to
      # account for all of it — so it is coalesced to `.`, which is what `Pathname#dirname` calls
      # that directory.
      it "names the repository root rather than losing the rows that sit in it" do
        observe(run, duration: 3.0, line_number: 1, spec_file_path: "smoke_spec.rb")
        observe(run, duration: 1.0, line_number: 2, spec_file_path: "spec/models/order_spec.rb")

        expect(described_class.directory_durations_in(run)).to eq(
          [[".", 3.0, 1, 1, 1, 1, 2],
           ["spec/models", 1.0, 1, 1, 1, 1, 2]]
        )
      end

      # Grouped by the area that RAN the example, so a shared example group's time lands on each
      # including area rather than on `spec/support` — the rule `Ingest::ObservationRecorder` writes
      # `spec_file_path` for, one rung up from where `.file_durations_in` asserts it.
      it "attributes a shared example group's time to the area that included it" do
        observe(run, duration: 1.5, line_number: 4, file_path: "spec/support/shared_examples.rb",
                     spec_file_path: "spec/models/order_spec.rb",
                     example_id: "./spec/models/order_spec.rb[1:1:1]")
        observe(run, duration: 2.5, line_number: 4, file_path: "spec/support/shared_examples.rb",
                     spec_file_path: "spec/requests/refund_spec.rb",
                     example_id: "./spec/requests/refund_spec.rb[1:1:1]")

        directories = described_class.directory_durations_in(run)

        expect(directories.map(&:first)).to eq(["spec/requests", "spec/models"])
        expect(directories.map(&:first)).not_to include("spec/support")
      end

      # THE example this read exists to get right, and the one the obvious implementation fails
      # twice over — and it costs more here than one rung down, because an area is a bigger
      # population than a file. `group(...).sum(:duration_seconds)` casts a NULL sum to `0.0` on the
      # way back into Ruby, and `SUM(...) DESC` is NULLS FIRST in Postgres, so an area NONE of whose
      # examples were timed comes back as a measured zero AND is named the heaviest area in the run.
      # Both halves are asserted because they fail differently.
      it "hands back a nil for an area that reported no timing at all, sorted below every total" do
        observe(run, duration: nil, line_number: 1, spec_file_path: "spec/system/never_ran_spec.rb")
        observe(run, duration: nil, line_number: 2, spec_file_path: "spec/system/also_never_spec.rb")
        observe(run, duration: 0.25, line_number: 3, spec_file_path: "spec/models/quick_spec.rb")

        directories = described_class.directory_durations_in(run)

        expect(directories).to eq([["spec/models", 0.25, 1, 1, 1, 1, 2],
                                   ["spec/system", nil, 2, 0, 2, 2, 2]])
        expect(directories.last[1]).to be_nil
      end

      # An area whose examples were only partly timed has a total covering only part of it. The
      # total alone cannot say so — it is an ordinary-looking number — so the two counts come back
      # in the same pass, off the same rows, rather than as a second question a caller might not
      # think to ask.
      it "counts each area's rows against the ones that carried a duration" do
        observe(run, duration: 4.0, line_number: 1, spec_file_path: "spec/models/order_spec.rb")
        observe(run, duration: nil, line_number: 2, spec_file_path: "spec/models/order_spec.rb")
        observe(run, duration: nil, line_number: 3, spec_file_path: "spec/models/refund_spec.rb")

        expect(described_class.directory_durations_in(run)).to eq([["spec/models", 4.0, 3, 1, 3, 3, 1]])
      end

      # THE third figure, and the one the panel's headline sentence needs: how many distinct
      # descriptions an area's examples carry. Four examples over two descriptions is the shape the
      # reading is about — a `COUNT(*)` retyped as a distinct count, or a distinct count taken over
      # `example_id` rather than `name`, both come back as 4 here and neither is a behavior count.
      it "counts each area's distinct descriptions, not its examples" do
        observe(run, duration: 1.0, line_number: 1, name: "settles an invoice",
                     spec_file_path: "spec/models/order_spec.rb")
        observe(run, duration: 1.0, line_number: 2, name: "settles an invoice",
                     spec_file_path: "spec/models/order_spec.rb")
        observe(run, duration: 1.0, line_number: 3, name: "settles an invoice",
                     spec_file_path: "spec/models/refund_spec.rb")
        observe(run, duration: 1.0, line_number: 4, name: "refuses a negative total",
                     spec_file_path: "spec/models/refund_spec.rb")

        expect(described_class.directory_durations_in(run)).to eq([["spec/models", 4.0, 4, 4, 2, 4, 1]])
      end

      # THE inverted Vacuous Green this pair of aggregates exists to refuse. `COUNT(DISTINCT name)`
      # skips NULLs silently, so an area whose producer sent no descriptions at all comes back as
      # ZERO distinct behaviors against its whole example count — read as a density, the most
      # redundant area obtainable, invented out of silence rather than measured. The count of NAMED
      # rows rides back in the same tuple so that zero is separable from a measurement: 0 distinct
      # over 0 named is "nothing to count", which is not "nothing distinct to count".
      it "reports no named rows for an area whose examples carry no description at all" do
        observe(run, duration: 1.0, line_number: 1, name: nil, spec_file_path: "spec/models/order_spec.rb")
        observe(run, duration: 1.0, line_number: 2, name: nil, spec_file_path: "spec/models/order_spec.rb")
        observe(run, duration: 1.0, line_number: 3, name: nil, spec_file_path: "spec/models/refund_spec.rb")

        expect(described_class.directory_durations_in(run)).to eq([["spec/models", 3.0, 3, 3, 0, 0, 1]])
      end

      # The partial case, and the one a whole-area check passes straight over: the distinct count is
      # taken across SOME of the area's rows, so the population it was counted over is not
      # `recorded_count`. Both figures come back, so the excluded rows are subtractable rather than
      # silent — 2 distinct over 3 named of 5 recorded, where reading 2 against 5 overstates the
      # repetition by counting rows the aggregate never saw.
      it "counts an area's distinct descriptions over its named rows, not over all of them" do
        observe(run, duration: 1.0, line_number: 1, name: "settles an invoice",
                     spec_file_path: "spec/models/order_spec.rb")
        observe(run, duration: 1.0, line_number: 2, name: "settles an invoice",
                     spec_file_path: "spec/models/order_spec.rb")
        observe(run, duration: 1.0, line_number: 3, name: "refuses a negative total",
                     spec_file_path: "spec/models/order_spec.rb")
        observe(run, duration: 1.0, line_number: 4, name: nil, spec_file_path: "spec/models/refund_spec.rb")
        observe(run, duration: 1.0, line_number: 5, name: nil, spec_file_path: "spec/models/refund_spec.rb")

        expect(described_class.directory_durations_in(run)).to eq([["spec/models", 5.0, 5, 5, 2, 3, 1]])
      end

      # One description in two AREAS is one distinct behavior in each of them, not one across the
      # run: the counts are per group, and a distinct count taken over the whole run before the
      # grouping would report one of these two areas as carrying no description of its own.
      it "counts each area's descriptions against that area rather than against the run" do
        observe(run, duration: 2.0, line_number: 1, name: "settles an invoice",
                     spec_file_path: "spec/models/order_spec.rb")
        observe(run, duration: 1.0, line_number: 2, name: "settles an invoice",
                     spec_file_path: "spec/requests/order_spec.rb")

        expect(described_class.directory_durations_in(run)).to eq(
          [["spec/models", 2.0, 1, 1, 1, 1, 2],
           ["spec/requests", 1.0, 1, 1, 1, 1, 2]]
        )
      end

      it "reads the run it was asked about and no other" do
        other = create_test_run(repository: repository, commit_sha: "0ther")
        observe(run, duration: 1.0, line_number: 1, spec_file_path: "spec/ours/a_spec.rb")
        observe(other, duration: 99.0, line_number: 1, spec_file_path: "spec/theirs/a_spec.rb")

        expect(described_class.directory_durations_in(run)).to eq([["spec/ours", 1.0, 1, 1, 1, 1, 1]])
      end

      # Its OWN limit, not the by-file one. The two constants happen to be equal today, which is
      # why the default is asserted through `HEAVIEST_DIRECTORIES_LIMIT` by name — a reuse of
      # `HEAVIEST_FILES_LIMIT` would pass this example and silently make one edit move both rungs.
      it "caps at the limit it was given, and defaults to the panel's own" do
        12.times { |i| observe(run, duration: i.to_f + 1, line_number: i + 1, spec_file_path: "spec/d#{i}/a_spec.rb") }

        expect(described_class.directory_durations_in(run).size)
          .to eq(described_class::HEAVIEST_DIRECTORIES_LIMIT)
        expect(described_class.directory_durations_in(run, limit: 3).map(&:first))
          .to eq(["spec/d11", "spec/d10", "spec/d9"])
      end

      # What the capped list is the head OF, in the same round trip. Without it the caller holds a
      # length that equals its own limit and cannot tell three areas from three hundred.
      # `COUNT(*) OVER ()` runs after `GROUP BY` and before `LIMIT`, so it counts AREAS rather than
      # rows and counts all of them however few come back.
      it "reports how many directories the run touched in total, whatever the limit returns" do
        12.times { |i| observe(run, duration: i.to_f + 1, line_number: i + 1, spec_file_path: "spec/d#{i}/a_spec.rb") }

        expect(described_class.directory_durations_in(run, limit: 3).map(&:last)).to eq([12, 12, 12])
        expect(described_class.directory_durations_in(run, limit: 100).map(&:last).uniq).to eq([12])
      end

      # Groups, not rows and not FILES: twelve examples in twelve files under two directories
      # touched two areas. Both wrong readings — the row count and the file count — are ruled out
      # at once, and neither would be distinguishable with one file per area.
      it "counts the directories rather than the files or examples in them" do
        12.times do |i|
          observe(run, duration: 1.0, line_number: i + 1, spec_file_path: "spec/d#{i % 2}/f#{i}_spec.rb")
        end

        expect(described_class.directory_durations_in(run).map(&:last)).to eq([2, 2])
      end

      # Two areas totalling the same is ordinary, so the order has to be total, or two requests
      # against unchanged rows list them differently.
      it "breaks ties by directory, so equal totals have one order" do
        observe(run, duration: 1.5, line_number: 1, spec_file_path: "spec/b/a_spec.rb")
        observe(run, duration: 1.5, line_number: 2, spec_file_path: "spec/a/a_spec.rb")

        expect(described_class.directory_durations_in(run).map(&:first)).to eq(["spec/a", "spec/b"])
      end

      it "reads no directories for a run that recorded nothing" do
        expect(described_class.directory_durations_in(run)).to eq([])
      end
    end

    # The rung BETWEEN the two above: one area's files, rather than every area's total or one
    # file's examples. The read that closes area → file → example, and the one whose absence made
    # the heaviest area on the page the hardest place in the suite to look inside.
    describe ".files_in_directory" do
      # THE question this read exists for, and the reason the by-file rollup could not answer it:
      # `spec/models` here holds three files none of which is the run's heaviest, and a by-file top
      # ten would surface `spec/requests/checkout_spec.rb` instead of any of them.
      it "totals each file of the area it was asked about, heaviest file first" do
        observe(run, duration: 3.5, line_number: 1, spec_file_path: "spec/models/order_spec.rb")
        observe(run, duration: 1.0, line_number: 2, spec_file_path: "spec/models/refund_spec.rb")
        observe(run, duration: 2.0, line_number: 3, spec_file_path: "spec/models/user_spec.rb")
        observe(run, duration: 9.0, line_number: 4, spec_file_path: "spec/requests/checkout_spec.rb")

        expect(described_class.files_in_directory(run, "spec/models")).to eq(
          [["spec/models/order_spec.rb", 3.5, 1, 1, 3, 3, 3],
           ["spec/models/user_spec.rb", 2.0, 1, 1, 3, 3, 3],
           ["spec/models/refund_spec.rb", 1.0, 1, 1, 3, 3, 3]]
        )
      end

      # THE fence this slice draws, and the assertion that fails the moment it is crossed. The
      # predicate is an EQUALITY on the area, so `spec/models/orders` is its own area exactly as it
      # is its own row in `.directory_durations_in` — a prefix `LIKE 'spec/models/%'` would gather
      # it in, double-count its rows against the rollup one rung up, and re-open the drill-down
      # tree that read's comment says is a different question.
      it "reads the area at its own depth, gathering no nested area into it" do
        observe(run, duration: 1.0, line_number: 1, spec_file_path: "spec/models/order_spec.rb")
        observe(run, duration: 2.0, line_number: 2, spec_file_path: "spec/models/orders/refund_spec.rb")

        expect(described_class.files_in_directory(run, "spec/models"))
          .to eq([["spec/models/order_spec.rb", 1.0, 1, 1, 1, 1, 1]])
        expect(described_class.files_in_directory(run, "spec/models/orders"))
          .to eq([["spec/models/orders/refund_spec.rb", 2.0, 1, 1, 1, 1, 1]])
      end

      # The area name is computed by the SAME expression the rollup above groups by, so the path a
      # link carries is a path this read can answer. A repository-root file's area is `.` there and
      # has to be `.` here, or the one row the rollup names that way opens an empty panel.
      it "answers for the repository root under the name the rollup gives it" do
        observe(run, duration: 3.0, line_number: 1, spec_file_path: "smoke_spec.rb")
        observe(run, duration: 1.0, line_number: 2, spec_file_path: "spec/models/order_spec.rb")

        expect(described_class.files_in_directory(run, ".")).to eq([["smoke_spec.rb", 3.0, 1, 1, 1, 1, 1]])
      end

      # Keyed on the INCLUDING file, so a shared example group's time lands on the area that RAN it
      # — the rule `Ingest::ObservationRecorder` writes `spec_file_path` for, and the rule the
      # rollup one rung up is asserted against. A read keyed on `file_path` would list
      # `spec/support/shared_examples.rb` under an area that never included it.
      it "lists a shared example group's row under the file that ran it" do
        observe(run, duration: 1.5, line_number: 4, file_path: "spec/support/shared_examples.rb",
                     spec_file_path: "spec/models/order_spec.rb",
                     example_id: "./spec/models/order_spec.rb[1:1:1]")

        expect(described_class.files_in_directory(run, "spec/models").map(&:first))
          .to eq(["spec/models/order_spec.rb"])
        expect(described_class.files_in_directory(run, "spec/support")).to eq([])
      end

      # THE example this read exists to get right, and the one the obvious implementation fails
      # twice over: `group(...).sum(:duration_seconds)` casts a NULL sum to `0.0` on the way back
      # into Ruby, and `SUM(...) DESC` is NULLS FIRST in Postgres — so a file NONE of whose
      # examples were timed comes back as a measured zero AND is named the heaviest file in the
      # area. Both halves are asserted because they fail differently.
      it "hands back a nil for a file that reported no timing at all, sorted below every total" do
        observe(run, duration: nil, line_number: 1, spec_file_path: "spec/models/never_ran_spec.rb")
        observe(run, duration: 0.25, line_number: 2, spec_file_path: "spec/models/quick_spec.rb")

        files = described_class.files_in_directory(run, "spec/models")

        expect(files).to eq([["spec/models/quick_spec.rb", 0.25, 1, 1, 2, 2, 1],
                             ["spec/models/never_ran_spec.rb", nil, 1, 0, 2, 2, 1]])
        expect(files.last[1]).to be_nil
      end

      it "counts each file's rows against the ones that carried a duration" do
        observe(run, duration: 4.0, line_number: 1, spec_file_path: "spec/models/order_spec.rb")
        observe(run, duration: nil, line_number: 2, spec_file_path: "spec/models/order_spec.rb")

        expect(described_class.files_in_directory(run, "spec/models"))
          .to eq([["spec/models/order_spec.rb", 4.0, 2, 1, 1, 2, 1]])
      end

      it "reads the run it was asked about and no other" do
        other = create_test_run(repository: repository, commit_sha: "0ther")
        observe(run, duration: 1.0, line_number: 1, spec_file_path: "spec/models/ours_spec.rb")
        observe(other, duration: 99.0, line_number: 1, spec_file_path: "spec/models/theirs_spec.rb")

        expect(described_class.files_in_directory(run, "spec/models"))
          .to eq([["spec/models/ours_spec.rb", 1.0, 1, 1, 1, 1, 1]])
      end

      # Its OWN limit, not the by-file rollup's and not the by-file drill-down's. The default is
      # asserted through `SPEC_DIRECTORY_FILES_LIMIT` by name, so a reuse of either sibling constant
      # cannot pass this example by happening to be equal today.
      it "caps at the limit it was given, and defaults to the panel's own" do
        (described_class::SPEC_DIRECTORY_FILES_LIMIT + 2).times do |i|
          observe(run, duration: i.to_f + 1, line_number: i + 1,
                       spec_file_path: "spec/models/f#{format('%03d', i)}_spec.rb")
        end

        expect(described_class.files_in_directory(run, "spec/models").size)
          .to eq(described_class::SPEC_DIRECTORY_FILES_LIMIT)
        expect(described_class.files_in_directory(run, "spec/models", limit: 2).map(&:first))
          .to eq(["spec/models/f026_spec.rb", "spec/models/f025_spec.rb"])
      end

      # What the capped list is the head OF, in the same round trip. `COUNT(*) OVER ()` runs after
      # `GROUP BY` and before `LIMIT`, so it counts the area's FILES rather than the rows on the
      # page — twelve files holding twenty-four examples is twelve, not twenty-four and not the cap.
      it "reports how many files the area holds, whatever the limit returns" do
        12.times do |i|
          2.times do |j|
            observe(run, duration: 1.0, line_number: (i * 2) + j,
                         spec_file_path: "spec/models/f#{i}_spec.rb")
          end
        end

        expect(described_class.files_in_directory(run, "spec/models", limit: 3).map { |row| row[4] })
          .to eq([12, 12, 12])
        expect(described_class.files_in_directory(run, "spec/models", limit: 100).map { |row| row[4] }.uniq)
          .to eq([12])
      end

      # The two figures a list of FILES cannot show and the caption is spent on: how many EXAMPLES
      # the area holds and how many of them were timed, counted over the whole area rather than
      # over the files that fit. `SUM(COUNT(...)) OVER ()` is what reaches them from a read grouped
      # by file — and the cap is what makes the distinction real, so the limit here is below the
      # file count on purpose.
      it "reports the area's own example counts, counted before the cap" do
        4.times do |i|
          observe(run, duration: 1.0, line_number: (i * 2) + 1, spec_file_path: "spec/models/f#{i}_spec.rb")
          observe(run, duration: nil, line_number: (i * 2) + 2, spec_file_path: "spec/models/f#{i}_spec.rb")
        end

        rows = described_class.files_in_directory(run, "spec/models", limit: 1)

        expect(rows.size).to eq(1)
        expect(rows.map { |row| row[5] }).to eq([8])
        expect(rows.map { |row| row[6] }).to eq([4])
      end

      # Two files totalling the same is ordinary inside one area, so the order has to be total or
      # two requests against unchanged rows list them differently.
      it "breaks ties by path, so equal totals have one order" do
        observe(run, duration: 1.5, line_number: 1, spec_file_path: "spec/models/b_spec.rb")
        observe(run, duration: 1.5, line_number: 2, spec_file_path: "spec/models/a_spec.rb")

        expect(described_class.files_in_directory(run, "spec/models").map(&:first))
          .to eq(["spec/models/a_spec.rb", "spec/models/b_spec.rb"])
      end

      # An area this run recorded nothing for is an ordinary answer — a stale bookmark, a deleted
      # directory, a typo — and not an error. No rows, and specifically not the whole run's files.
      it "reads no files for an area the run recorded nothing in" do
        observe(run, duration: 1.0, line_number: 1, spec_file_path: "spec/models/order_spec.rb")

        expect(described_class.files_in_directory(run, "spec/ghosts")).to eq([])
      end
    end

    # The one read on this table that spans two runs. Everything above is scoped to a single
    # `test_run_id`; this counts each area's rows in each of two runs and subtracts the integers.
    #
    # The examples deliberately never assert anything about a particular EXAMPLE surviving from one
    # run to the other, because the method cannot and must not know: `example_id` is positional, so
    # the two populations are compared as populations. Every fixture below is written so that the
    # per-example rows of the two runs are unrelated — same paths, different line numbers — and the
    # expected counts hold regardless.
    describe ".directory_growth_between" do
      let(:previous_run) { create_test_run(repository: repository, commit_sha: "prev123") }

      # One area's worth of rows in one run, at line numbers that cannot collide within it.
      def observe_area(test_run, directory, count, from: 1)
        count.times do |i|
          observe(test_run, duration: 1.0, line_number: from + i,
                            spec_file_path: "#{directory}/a_spec.rb")
        end
      end

      # The pivot itself: one row per AREA carrying both runs' counts, not one row per (area, run)
      # pair left for a caller to fold together.
      it "puts both runs' counts for an area on one row" do
        observe_area(previous_run, "spec/models", 2)
        observe_area(previous_run, "spec/requests", 1, from: 10)
        observe_area(run, "spec/models", 5)
        observe_area(run, "spec/requests", 1, from: 10)

        expect(described_class.directory_growth_between(run, previous_run)).to eq(
          [["spec/models", 2, 5, 2, 3, 6],
           ["spec/requests", 1, 1, 2, 3, 6]]
        )
      end

      # THE example this ranking exists for, and the one a `DESC`-only ordering on the signed change
      # passes right over. `spec/legacy` lost four examples and `spec/models` gained two: the bigger
      # movement is the deletion, and a panel asking "which areas moved" that ranked the signed
      # change would put every shrinkage below every growth and off the end of the cap. Asserted at
      # `limit: 1` as well, so the claim is about which area SURVIVES the cap rather than only about
      # the order two surviving rows happen to sit in.
      it "ranks by absolute movement, so a shrinkage outranks a smaller growth" do
        observe_area(previous_run, "spec/legacy", 6)
        observe_area(previous_run, "spec/models", 1, from: 20)
        observe_area(run, "spec/legacy", 2)
        observe_area(run, "spec/models", 3, from: 20)

        expect(described_class.directory_growth_between(run, previous_run)).to eq(
          [["spec/legacy", 6, 2, 2, 7, 5],
           ["spec/models", 1, 3, 2, 7, 5]]
        )
        expect(described_class.directory_growth_between(run, previous_run, limit: 1).map(&:first))
          .to eq(["spec/legacy"])
      end

      # An area the earlier run never wrote a row for comes back with a real 0 on that side rather
      # than being dropped — the caller needs the row in order to say "new area" at all. It is the
      # SUM totals beside it that let the caller tell this from a run that recorded nothing
      # anywhere, which is why they are asserted here rather than only in their own example.
      it "reports an area only the latest run recorded, with a zero for the run that did not" do
        observe_area(previous_run, "spec/models", 3)
        observe_area(run, "spec/models", 3)
        observe_area(run, "spec/system", 4, from: 20)

        expect(described_class.directory_growth_between(run, previous_run)).to eq(
          [["spec/system", 0, 4, 2, 3, 7],
           ["spec/models", 3, 3, 2, 3, 7]]
        )
      end

      it "reports an area only the previous run recorded, with a zero for the run that did not" do
        observe_area(previous_run, "spec/models", 3)
        observe_area(previous_run, "spec/system", 4, from: 20)
        observe_area(run, "spec/models", 3)

        expect(described_class.directory_growth_between(run, previous_run)).to eq(
          [["spec/system", 4, 0, 2, 7, 3],
           ["spec/models", 3, 3, 2, 7, 3]]
        )
      end

      # The two runs' rows are counted apart, which is the whole method: a single `COUNT(*)` over
      # the `IN` list would give each area the SUM of both sides and every change would be zero.
      # Same paths in both runs and different totals, so a read that conflated them would produce
      # `[9, 9]` here rather than `[4, 5]`.
      it "counts each run's rows against that run and not against the pair" do
        observe_area(previous_run, "spec/models", 4)
        observe_area(run, "spec/models", 5)

        expect(described_class.directory_growth_between(run, previous_run))
          .to eq([["spec/models", 4, 5, 1, 4, 5]])
      end

      # A third run on the same repository is not part of this comparison, and its rows must not
      # reach either column or either total. The obvious way to get this wrong — narrowing on
      # `repository_id`, or on the branch — is what this rules out.
      it "reads the two runs it was asked about and no others" do
        other = create_test_run(repository: repository, commit_sha: "0ther99")
        observe_area(previous_run, "spec/models", 1)
        observe_area(run, "spec/models", 2)
        observe_area(other, "spec/theirs", 50)

        expect(described_class.directory_growth_between(run, previous_run))
          .to eq([["spec/models", 1, 2, 1, 1, 2]])
      end

      # Two areas that moved the same distance is ordinary — a rename moves exactly that way — so
      # the order has to be total, or two requests against unchanged rows list them differently.
      it "breaks ties by directory, so equal movements have one order" do
        observe_area(previous_run, "spec/b", 3)
        observe_area(previous_run, "spec/a", 3, from: 20)
        observe_area(run, "spec/b", 5)
        observe_area(run, "spec/a", 5, from: 20)

        expect(described_class.directory_growth_between(run, previous_run).map(&:first))
          .to eq(["spec/a", "spec/b"])
      end

      # Its OWN limit, not the by-duration one. The two constants happen to be equal today, which is
      # exactly why the default is asserted through `MOVED_DIRECTORIES_LIMIT` by name: a reuse of
      # `HEAVIEST_DIRECTORIES_LIMIT` would pass this example and silently make one edit move both
      # panels.
      it "caps at the limit it was given, and defaults to the panel's own" do
        12.times { |i| observe_area(run, "spec/d#{i}", i + 1, from: (i * 20) + 1) }
        observe_area(previous_run, "spec/models", 1)

        expect(described_class.directory_growth_between(run, previous_run).size)
          .to eq(described_class::MOVED_DIRECTORIES_LIMIT)
        expect(described_class.directory_growth_between(run, previous_run, limit: 3).map(&:first))
          .to eq(["spec/d11", "spec/d10", "spec/d9"])
      end

      # What the capped list is the head OF, in the same round trip — and it counts AREAS across
      # BOTH runs, which is the figure a caption saying "of the N areas either run recorded" needs.
      # `COUNT(*) OVER ()` runs after `GROUP BY` and before `LIMIT`, so a truncated read reports the
      # same total an untruncated one does. Twelve areas in the latest run and one that only the
      # previous run has: thirteen, which neither run alone could have produced.
      it "reports how many areas the comparison covered, whatever the limit returns" do
        12.times { |i| observe_area(run, "spec/d#{i}", i + 1, from: (i * 20) + 1) }
        observe_area(previous_run, "spec/gone", 1)

        expect(described_class.directory_growth_between(run, previous_run, limit: 3).map { |row| row[3] })
          .to eq([13, 13, 13])
        expect(described_class.directory_growth_between(run, previous_run, limit: 100).map { |row| row[3] }.uniq)
          .to eq([13])
      end

      # The two per-run totals, and the reason they are on the query rather than derived by the
      # caller: summing the returned rows' counts would total a CAPPED three of them and answer a
      # question about the page instead of about the run.
      #
      # The previous run is what makes this sharp rather than merely tidy. It recorded one row, in
      # an area whose movement does not survive the cap — so the rows on hand carry ZERO of its
      # examples while the run recorded one. A caller deriving the figure from the rows would read
      # "the previous run recorded nothing", which is precisely the state the panel withholds the
      # whole comparison for: the defect would be a page announcing no comparison on two runs that
      # are perfectly comparable.
      it "reports what each run recorded in total, before the limit" do
        12.times { |i| observe_area(run, "spec/d#{i}", 1, from: (i * 20) + 1) }
        observe_area(run, "spec/d0", 1, from: 500)
        observe_area(previous_run, "spec/gone", 1)

        rows = described_class.directory_growth_between(run, previous_run, limit: 3)

        expect(rows.map { |row| row[4] }.uniq).to eq([1])
        expect(rows.map { |row| row[5] }.uniq).to eq([13])
        expect(rows.sum { |row| row[1] }).to eq(0)
        expect(rows.sum { |row| row[2] }).to eq(4)
      end

      # Zero groups, which for this read means neither run wrote a row — a group exists here if and
      # only if a row does. The caller depends on that equivalence to name the state, so it is
      # pinned rather than left as a property of the SQL.
      it "reads nothing at all for two runs that recorded no examples" do
        expect(described_class.directory_growth_between(run, previous_run)).to eq([])
      end

      # The same area key as every other rollup on this table, so the panel's areas cannot be a
      # different partition of the suite from the by-duration panel's. Asserted through the shape
      # that would break first if the expression were re-derived here: the IMMEDIATE parent, with a
      # root-level file coalesced rather than dropped.
      it "areas the rows exactly as the by-duration rollup does" do
        observe(previous_run, duration: 1.0, line_number: 1, spec_file_path: "spec/models/a_spec.rb")
        observe(run, duration: 1.0, line_number: 1, spec_file_path: "spec/models/orders/a_spec.rb")
        observe(run, duration: 1.0, line_number: 2, spec_file_path: "smoke_spec.rb")

        expect(described_class.directory_growth_between(run, previous_run).map(&:first))
          .to match_array([".", "spec/models", "spec/models/orders"])
      end
    end

    # The read above at one grain down, narrowed to ONE area — which FILES of it moved, rather than
    # which areas of the suite did.
    #
    # Every fixture below is built so a file-grain answer and an area-grain answer differ. An area
    # that moved by nothing can hold two files that moved by a great deal in opposite directions —
    # which is exactly the rename the panel above discloses it cannot see — so a read that had
    # quietly become the area read narrowed would be green under any fixture where the two agree,
    # and none of these agree.
    describe ".file_growth_between" do
      let(:previous_run) { create_test_run(repository: repository, commit_sha: "prev123") }

      # One file's worth of rows in one run, at line numbers that cannot collide within it. `from`
      # is what keeps the two runs' example ids from lining up: a correspondence between the runs is
      # the one thing this read never claims, so no fixture here supplies one.
      def observe_file(test_run, path, count, from: 1)
        count.times do |i|
          observe(test_run, duration: 1.0, line_number: from + i, spec_file_path: path)
        end
      end

      # The pivot itself: one row per FILE carrying both runs' counts, not one row per (file, run)
      # pair left for a caller to fold together.
      it "puts both runs' counts for a file on one row" do
        observe_file(previous_run, "spec/models/order_spec.rb", 2)
        observe_file(previous_run, "spec/models/user_spec.rb", 1, from: 10)
        observe_file(run, "spec/models/order_spec.rb", 5, from: 20)
        observe_file(run, "spec/models/user_spec.rb", 1, from: 30)

        expect(described_class.file_growth_between(run, previous_run, "spec/models")).to eq(
          [["spec/models/order_spec.rb", 2, 5, 2, 3, 6],
           ["spec/models/user_spec.rb", 1, 1, 2, 3, 6]]
        )
      end

      # THE ranking this read exists for, and the one a `DESC`-only ordering on the signed change
      # passes right over — a file that LOST examples is half of the rename this panel was built to
      # make visible, and signed ranking puts every loss below every gain and off the end of the
      # cap. Asserted at `limit: 1` as well, so the claim is about which file SURVIVES the cap
      # rather than only about the order two surviving rows sit in.
      it "ranks by absolute movement, so a shrinkage outranks a smaller growth" do
        observe_file(previous_run, "spec/models/legacy_spec.rb", 6)
        observe_file(previous_run, "spec/models/order_spec.rb", 1, from: 20)
        observe_file(run, "spec/models/legacy_spec.rb", 2, from: 40)
        observe_file(run, "spec/models/order_spec.rb", 3, from: 60)

        expect(described_class.file_growth_between(run, previous_run, "spec/models")).to eq(
          [["spec/models/legacy_spec.rb", 6, 2, 2, 7, 5],
           ["spec/models/order_spec.rb", 1, 3, 2, 7, 5]]
        )
        expect(described_class.file_growth_between(run, previous_run, "spec/models", limit: 1).map(&:first))
          .to eq(["spec/models/legacy_spec.rb"])
      end

      # THE shape the whole panel is for, and the one that only exists at this grain: an area that
      # moved by NOTHING, holding one file that appeared and one that vanished by the same amount.
      # One rung up this is a single `±0` row and the reader is told the page cannot tell a
      # relocation from a gain-and-a-loss; here both operands are on the table. The read still
      # asserts no correspondence between the two files — it counts rows — which is why the fixture
      # gives them different line numbers throughout.
      it "shows a vanished file and an appeared one as two rows where the area itself did not move" do
        observe_file(previous_run, "spec/models/user_spec.rb", 4)
        observe_file(run, "spec/models/users_spec.rb", 4, from: 50)

        expect(described_class.file_growth_between(run, previous_run, "spec/models")).to eq(
          [["spec/models/user_spec.rb", 4, 0, 2, 4, 4],
           ["spec/models/users_spec.rb", 0, 4, 2, 4, 4]]
        )
        expect(described_class.directory_growth_between(run, previous_run))
          .to eq([["spec/models", 4, 4, 1, 4, 4]])
      end

      # A file the earlier run never wrote a row for comes back with a real 0 on that side rather
      # than being dropped — the caller needs the row in order to say "new file" at all.
      it "reports a file only the latest run recorded, with a zero for the run that did not" do
        observe_file(previous_run, "spec/models/order_spec.rb", 3)
        observe_file(run, "spec/models/order_spec.rb", 3, from: 20)
        observe_file(run, "spec/models/refund_spec.rb", 4, from: 40)

        expect(described_class.file_growth_between(run, previous_run, "spec/models")).to eq(
          [["spec/models/refund_spec.rb", 0, 4, 2, 3, 7],
           ["spec/models/order_spec.rb", 3, 3, 2, 3, 7]]
        )
      end

      # THE fence this read draws, and the assertion that fails the moment it is crossed. The
      # predicate is an EQUALITY on the area — the same one `.files_in_directory` uses and through
      # the same constant — so `spec/models/orders` is its own area exactly as it is its own row in
      # the panel this drills out of. A prefix `LIKE 'spec/models/%'` would gather it in and this
      # panel would double-count rows against the one above it on a single click.
      it "reads the area at its own depth, gathering no nested area into it" do
        observe_file(previous_run, "spec/models/order_spec.rb", 1)
        observe_file(previous_run, "spec/models/orders/refund_spec.rb", 5, from: 10)
        observe_file(run, "spec/models/order_spec.rb", 3, from: 20)
        observe_file(run, "spec/models/orders/refund_spec.rb", 1, from: 40)

        expect(described_class.file_growth_between(run, previous_run, "spec/models"))
          .to eq([["spec/models/order_spec.rb", 1, 3, 1, 1, 3]])
        expect(described_class.file_growth_between(run, previous_run, "spec/models/orders"))
          .to eq([["spec/models/orders/refund_spec.rb", 5, 1, 1, 5, 1]])
      end

      # The area name is computed by the SAME expression the panel above groups by, so the path a
      # link carries is a path this read can answer. A repository-root file's area is `.` up there
      # and has to be `.` here, or the one row that panel names that way opens an empty drill-in.
      it "answers for the repository root under the name the panel above gives it" do
        observe_file(previous_run, "smoke_spec.rb", 1)
        observe_file(run, "smoke_spec.rb", 3, from: 10)
        observe_file(run, "spec/models/order_spec.rb", 1, from: 20)

        expect(described_class.file_growth_between(run, previous_run, "."))
          .to eq([["smoke_spec.rb", 1, 3, 1, 1, 3]])
      end

      # The two runs' rows are counted apart, which is the whole method: a single `COUNT(*)` over
      # the `IN` list would give each file the SUM of both sides and every change would be zero.
      it "counts each run's rows against that run and not against the pair" do
        observe_file(previous_run, "spec/models/order_spec.rb", 4)
        observe_file(run, "spec/models/order_spec.rb", 5, from: 20)

        expect(described_class.file_growth_between(run, previous_run, "spec/models"))
          .to eq([["spec/models/order_spec.rb", 4, 5, 1, 4, 5]])
      end

      # A third run on the same repository is not part of this comparison, and its rows must not
      # reach either column or either total — including a run that touched the very same file.
      it "reads the two runs it was asked about and no others" do
        other = create_test_run(repository: repository, commit_sha: "0ther99")
        observe_file(previous_run, "spec/models/order_spec.rb", 1)
        observe_file(run, "spec/models/order_spec.rb", 2, from: 20)
        observe_file(other, "spec/models/order_spec.rb", 50, from: 100)

        expect(described_class.file_growth_between(run, previous_run, "spec/models"))
          .to eq([["spec/models/order_spec.rb", 1, 2, 1, 1, 2]])
      end

      # Keyed on the INCLUDING file, so a shared example group's rows land on the file that RAN
      # them — the rule `Ingest::ObservationRecorder` writes `spec_file_path` for, and the rule both
      # rollups above are asserted against. A read keyed on `file_path` would list
      # `spec/support/shared_examples.rb` under an area that never included it.
      it "counts a shared example group's row against the file that ran it" do
        observe(previous_run, duration: 1.0, line_number: 4, file_path: "spec/support/shared_examples.rb",
                              spec_file_path: "spec/models/order_spec.rb",
                              example_id: "./spec/models/order_spec.rb[1:1:1]")
        observe(run, duration: 1.0, line_number: 9, file_path: "spec/support/shared_examples.rb",
                     spec_file_path: "spec/models/order_spec.rb",
                     example_id: "./spec/models/order_spec.rb[1:1:2]")

        expect(described_class.file_growth_between(run, previous_run, "spec/models").map(&:first))
          .to eq(["spec/models/order_spec.rb"])
        expect(described_class.file_growth_between(run, previous_run, "spec/support")).to eq([])
      end

      # Two files that moved the same distance is ordinary — a rename moves exactly that way, and
      # this panel puts both halves of one on the page — so the order has to be total, or two
      # requests against unchanged rows list them differently.
      it "breaks ties by path, so equal movements have one order" do
        observe_file(previous_run, "spec/models/b_spec.rb", 3)
        observe_file(previous_run, "spec/models/a_spec.rb", 3, from: 20)
        observe_file(run, "spec/models/b_spec.rb", 5, from: 40)
        observe_file(run, "spec/models/a_spec.rb", 5, from: 60)

        expect(described_class.file_growth_between(run, previous_run, "spec/models").map(&:first))
          .to eq(["spec/models/a_spec.rb", "spec/models/b_spec.rb"])
      end

      # Its OWN limit, and the default is asserted through `SPEC_DIRECTORY_FILE_GROWTH_LIMIT` BY
      # NAME. The neighbouring `SPEC_DIRECTORY_FILES_LIMIT` caps one run's listing of the same
      # area's files and this caps the two-run UNION of them, so a reuse of it would pass any
      # example asserting a bare number and silently make one edit move both panels.
      it "caps at the limit it was given, and defaults to the panel's own" do
        32.times { |i| observe_file(run, "spec/models/f#{i}_spec.rb", i + 1, from: (i * 40) + 1) }
        observe_file(previous_run, "spec/models/gone_spec.rb", 1)

        expect(described_class.file_growth_between(run, previous_run, "spec/models").size)
          .to eq(described_class::SPEC_DIRECTORY_FILE_GROWTH_LIMIT)
        expect(described_class.file_growth_between(run, previous_run, "spec/models", limit: 3).map(&:first))
          .to eq(["spec/models/f31_spec.rb", "spec/models/f30_spec.rb", "spec/models/f29_spec.rb"])
      end

      # What the capped list is the head OF, in the same round trip — and it counts FILES across
      # BOTH runs, which is the figure a caption saying "of the N either run recorded" needs.
      # `COUNT(*) OVER ()` runs after `GROUP BY` and before `LIMIT`, so a truncated read reports the
      # same total an untruncated one does.
      #
      # Twelve files in the latest run and one only the previous run has: thirteen, a figure neither
      # run alone could produce. Deliberately not equal to any single file's row count — the biggest
      # here holds twelve — because a `COUNT(*)` where the window total belongs reads the leading
      # GROUP's size, and a fixture where those two numbers coincide is green under exactly that
      # mutation.
      it "reports how many files the comparison covered, whatever the limit returns" do
        12.times { |i| observe_file(run, "spec/models/f#{i}_spec.rb", i + 1, from: (i * 40) + 1) }
        observe_file(previous_run, "spec/models/gone_spec.rb", 1)

        expect(described_class.file_growth_between(run, previous_run, "spec/models", limit: 3)
                              .map { |row| row[3] }).to eq([13, 13, 13])
        expect(described_class.file_growth_between(run, previous_run, "spec/models", limit: 100)
                              .map { |row| row[3] }.uniq).to eq([13])
      end

      # The two per-run totals, counted before the cap and narrowed to THIS AREA — and the reason
      # they are on the query rather than derived by the caller: summing the returned rows' counts
      # would total a CAPPED three of them and answer a question about the page.
      #
      # The previous run is what makes this sharp. It recorded one row, in a file whose movement
      # does not survive the cap, so the rows on hand carry ZERO of its examples while the run
      # recorded one in this area. A caller deriving the figure from the rows would read "the
      # previous run recorded nothing here" off a comparison that is perfectly sound.
      it "reports what each run recorded in this area in total, before the limit" do
        12.times { |i| observe_file(run, "spec/models/f#{i}_spec.rb", 1, from: (i * 40) + 1) }
        observe_file(run, "spec/models/f0_spec.rb", 1, from: 900)
        observe_file(previous_run, "spec/models/gone_spec.rb", 1)

        rows = described_class.file_growth_between(run, previous_run, "spec/models", limit: 3)

        expect(rows.map { |row| row[4] }.uniq).to eq([1])
        expect(rows.map { |row| row[5] }.uniq).to eq([13])
        expect(rows.sum { |row| row[1] }).to eq(0)
        expect(rows.sum { |row| row[2] }).to eq(4)
      end

      # Those totals are the AREA's and deliberately not the RUNS'. The caller's caption states what
      # this panel was measured over, and this panel is measured over one area — while the read one
      # rung up returns whole-run totals under the same position. Rows in a SECOND area are what
      # tells the two apart, and a read that reported the run's totals here would divide an area's
      # population by the suite's.
      it "counts its totals over the asked-for area and not over the whole run" do
        observe_file(previous_run, "spec/models/order_spec.rb", 2)
        observe_file(previous_run, "spec/requests/checkout_spec.rb", 40, from: 100)
        observe_file(run, "spec/models/order_spec.rb", 5, from: 200)
        observe_file(run, "spec/requests/checkout_spec.rb", 60, from: 400)

        expect(described_class.file_growth_between(run, previous_run, "spec/models"))
          .to eq([["spec/models/order_spec.rb", 2, 5, 1, 2, 5]])
      end

      # Zero groups, which for this read means neither run wrote a row IN THIS AREA — a group exists
      # here if and only if a row does. `?spec_directory=` is a URL a reader types and bookmarks, so
      # a typo and a deleted directory both arrive here and neither is an error; the caller depends
      # on the empty read to name that state, so it is pinned rather than left to the SQL.
      it "reads nothing at all for an area neither run recorded" do
        observe_file(previous_run, "spec/models/order_spec.rb", 1)
        observe_file(run, "spec/models/order_spec.rb", 2, from: 20)

        expect(described_class.file_growth_between(run, previous_run, "spec/ghosts")).to eq([])
      end
    end

    # The second read that spans two runs, over the same rows and the same areas as the one above,
    # ranking them by an INDEPENDENT quantity. Every fixture below is built so that the two rankings
    # genuinely disagree — an area that moved in seconds and not in examples, and one that moved in
    # examples and not in seconds — because a read that had quietly become the count read relabelled
    # would be green under any fixture where the two happen to agree.
    describe ".directory_runtime_growth_between" do
      let(:previous_run) { create_test_run(repository: repository, commit_sha: "prev123") }

      # One area's worth of rows in one run, at line numbers that cannot collide within it. Each
      # example carries `each` seconds; a nil `each` is the row a client sent with no timing.
      def observe_area(test_run, directory, count, each: 1.0, from: 1)
        count.times do |i|
          observe(test_run, duration: each, line_number: from + i,
                            spec_file_path: "#{directory}/a_spec.rb")
        end
      end

      # The pivot itself: one row per AREA carrying both runs' summed seconds and the coverage each
      # was summed over, not one row per (area, run) pair left for a caller to fold together.
      it "puts both runs' summed seconds for an area on one row" do
        observe_area(previous_run, "spec/models", 2, each: 1.0)
        observe_area(previous_run, "spec/requests", 1, each: 2.0, from: 10)
        observe_area(run, "spec/models", 2, each: 4.0)
        observe_area(run, "spec/requests", 1, each: 2.0, from: 10)

        expect(described_class.directory_runtime_growth_between(run, previous_run)).to eq(
          [["spec/models", 2.0, 8.0, 2, 2, 2, 2, 2, 3, 3, 3, 3],
           ["spec/requests", 2.0, 2.0, 1, 1, 1, 1, 2, 3, 3, 3, 3]]
        )
      end

      # THE example this whole read exists for, and the one the count read beside it cannot answer.
      # `spec/models` gained no examples at all and got 30 seconds slower; `spec/system` gained two
      # examples and a tenth of a second. Rank these areas by `ABS(latest_count - previous_count)`
      # and the slowdown sorts LAST — which at the shipped cap of ten is off the panel entirely.
      it "names an area that got slower without gaining a single example" do
        observe_area(previous_run, "spec/models", 2, each: 1.0)
        observe_area(previous_run, "spec/system", 1, each: 0.1, from: 20)
        observe_area(run, "spec/models", 2, each: 16.0)
        observe_area(run, "spec/system", 3, each: 0.1, from: 20)

        rows = described_class.directory_runtime_growth_between(run, previous_run)

        expect(rows.map(&:first)).to eq(["spec/models", "spec/system"])
        expect(rows.first[1..2]).to eq([2.0, 32.0])
        expect(rows.last[1]).to eq(0.1)
        expect(rows.last[2]).to be_within(0.001).of(0.3)
        # And the sibling read, over the very same rows, ranks them the other way round and puts
        # the 30-second regression second.
        expect(described_class.directory_growth_between(run, previous_run).map(&:first))
          .to eq(["spec/system", "spec/models"])
      end

      # The other direction of the same independence: four fast specs where one slow one used to be
      # is a GAIN of three examples and a LOSS of nine seconds. A panel ranking counts calls this
      # the biggest growth in the suite; this one calls it the biggest win.
      it "reports an area that gained examples and lost time" do
        observe_area(previous_run, "spec/models", 1, each: 10.0)
        observe_area(run, "spec/models", 4, each: 0.25)

        expect(described_class.directory_runtime_growth_between(run, previous_run))
          .to eq([["spec/models", 10.0, 1.0, 1, 4, 1, 4, 1, 1, 4, 1, 4]])
      end

      # Ranked by ABSOLUTE movement, both directions — a suite that took 300 seconds out of one area
      # answers "which areas changed pace" exactly as much as one that added them, and a `DESC`-only
      # ordering on the signed change would put every win below every regression and off the cap.
      # Asserted at `limit: 1` too, so the claim is about which area SURVIVES the cap.
      it "ranks by absolute movement, so a speedup outranks a smaller slowdown" do
        observe_area(previous_run, "spec/legacy", 1, each: 12.0)
        observe_area(previous_run, "spec/models", 1, each: 1.0, from: 20)
        observe_area(run, "spec/legacy", 1, each: 2.0)
        observe_area(run, "spec/models", 1, each: 4.0, from: 20)

        expect(described_class.directory_runtime_growth_between(run, previous_run).map(&:first))
          .to eq(["spec/legacy", "spec/models"])
        expect(described_class.directory_runtime_growth_between(run, previous_run, limit: 1).map(&:first))
          .to eq(["spec/legacy"])
      end

      # THE hazard this read is built around. An area none of whose examples were timed sums to SQL
      # NULL, the subtraction against it is NULL, and `DESC` alone is NULLS FIRST in Postgres — so
      # without `NULLS LAST` the area nobody MEASURED heads a panel about slowdowns, above a real
      # 8-second regression. Both halves asserted: the nil comes back as a nil (never a 0.0 the
      # caller would render "0.00s"), and it sorts last.
      it "sums an untimed area to nil and ranks it last rather than first" do
        observe_area(previous_run, "spec/quiet", 3, each: nil)
        observe_area(previous_run, "spec/models", 1, each: 1.0, from: 20)
        observe_area(run, "spec/quiet", 3, each: nil)
        observe_area(run, "spec/models", 1, each: 9.0, from: 20)

        rows = described_class.directory_runtime_growth_between(run, previous_run)

        expect(rows.map(&:first)).to eq(["spec/models", "spec/quiet"])
        expect(rows.last[1]).to be_nil
        expect(rows.last[2]).to be_nil
      end

      # An area timed on ONE side only is the same hazard wearing a worse face: it is not a 12-second
      # win, it is a run that stopped reporting. The subtraction is NULL either way, so it sorts last
      # beside the never-timed area — and the caller gets the real total on the side that has one.
      it "leaves an area timed on only one side unranked rather than calling it a win" do
        observe_area(previous_run, "spec/models", 2, each: 6.0)
        observe_area(previous_run, "spec/system", 1, each: 1.0, from: 20)
        observe_area(run, "spec/models", 2, each: nil)
        observe_area(run, "spec/system", 1, each: 3.0, from: 20)

        rows = described_class.directory_runtime_growth_between(run, previous_run)

        expect(rows.map(&:first)).to eq(["spec/system", "spec/models"])
        expect(rows.last[1..2]).to eq([12.0, nil])
        # And its coverage says which side went quiet: two rows recorded, none timed.
        expect(rows.last[3..6]).to eq([2, 2, 2, 0])
      end

      # `SUM` skips NULLs silently, so a total covering half an area is indistinguishable from a
      # total covering all of it unless the row says which. Both counts per side, so a caller can
      # state a total against what it was summed over.
      it "states how much of each side each total was summed over" do
        observe_area(previous_run, "spec/models", 2, each: 1.0)
        observe_area(previous_run, "spec/models", 2, each: nil, from: 50)
        observe_area(run, "spec/models", 4, each: 1.0)

        expect(described_class.directory_runtime_growth_between(run, previous_run))
          .to eq([["spec/models", 2.0, 4.0, 4, 4, 2, 4, 1, 4, 4, 2, 4]])
      end

      # The two runs' rows are summed apart, which is the whole method: a single `SUM` over the `IN`
      # list would give each area the total of both sides and every change would be zero. Same paths
      # in both runs and different totals, so a read that conflated them would produce `[9.0, 9.0]`
      # here rather than `[4.0, 5.0]`.
      it "sums each run's rows against that run and not against the pair" do
        observe_area(previous_run, "spec/models", 2, each: 2.0)
        observe_area(run, "spec/models", 2, each: 2.5)

        expect(described_class.directory_runtime_growth_between(run, previous_run).map { |row| row[1..2] })
          .to eq([[4.0, 5.0]])
      end

      # A rollup that loses an area's rows, or counts one twice, is still a plausible-looking list of
      # directories — and only each run's OWN total catches it. Asserted per side, because the two
      # sides are separate `FILTER`s and a bug that leaked rows across the boundary would still
      # reconcile against the pair's combined total.
      it "reconciles each side against that run's own total, so no area's rows are lost or doubled" do
        observe_area(previous_run, "spec/models", 3, each: 1.5)
        observe_area(previous_run, "spec/system", 2, each: 0.25, from: 20)
        observe_area(run, "spec/models", 3, each: 2.0, from: 40)
        observe_area(run, "spec/system", 2, each: 0.5, from: 60)

        rows = described_class.directory_runtime_growth_between(run, previous_run, limit: 100)

        expect(rows.sum { |row| row[1] })
          .to be_within(0.001).of(previous_run.spec_observations.sum(:duration_seconds))
        expect(rows.sum { |row| row[2] })
          .to be_within(0.001).of(run.spec_observations.sum(:duration_seconds))
        # And every row each run wrote is under exactly one of those areas.
        expect(rows.sum { |row| row[3] }).to eq(previous_run.spec_observations.count)
        expect(rows.sum { |row| row[4] }).to eq(run.spec_observations.count)
      end

      # A third run on the same repository is not part of this comparison, and its seconds must not
      # reach either column or either total. The obvious way to get this wrong — narrowing on
      # `repository_id`, or on the branch — is what this rules out.
      it "reads the two runs it was asked about and no others" do
        other = create_test_run(repository: repository, commit_sha: "0ther99")
        observe_area(previous_run, "spec/models", 1, each: 1.0)
        observe_area(run, "spec/models", 1, each: 2.0)
        observe_area(other, "spec/theirs", 50, each: 100.0)

        expect(described_class.directory_runtime_growth_between(run, previous_run))
          .to eq([["spec/models", 1.0, 2.0, 1, 1, 1, 1, 1, 1, 1, 1, 1]])
      end

      # Two areas that moved the same distance is ordinary — a rename moves exactly that way — so
      # the order has to be total, or two requests against unchanged rows list them differently.
      it "breaks ties by directory, so equal movements have one order" do
        observe_area(previous_run, "spec/b", 1, each: 1.0)
        observe_area(previous_run, "spec/a", 1, each: 1.0, from: 20)
        observe_area(run, "spec/b", 1, each: 3.0)
        observe_area(run, "spec/a", 1, each: 3.0, from: 20)

        expect(described_class.directory_runtime_growth_between(run, previous_run).map(&:first))
          .to eq(["spec/a", "spec/b"])
      end

      # Its OWN limit, not the count comparison's. The two constants happen to be equal today, which
      # is exactly why the default is asserted through `RETIMED_DIRECTORIES_LIMIT` by name: a reuse
      # of `MOVED_DIRECTORIES_LIMIT` would pass this example and silently make one edit move two
      # panels that rank the same areas by different quantities.
      #
      # Every area is in BOTH runs, so every area has a real movement to be ranked by — a fixture
      # where each area sat on one side only would rank nothing at all (the key is NULL and sorts
      # last) and would be green under an implementation with no ordering to speak of.
      it "caps at the limit it was given, and defaults to the panel's own" do
        12.times { |i| observe_area(previous_run, "spec/d#{i}", 1, each: 1.0, from: (i * 40) + 1) }
        12.times { |i| observe_area(run, "spec/d#{i}", 1, each: i + 1.0, from: (i * 40) + 20) }

        expect(described_class.directory_runtime_growth_between(run, previous_run).size)
          .to eq(described_class::RETIMED_DIRECTORIES_LIMIT)
        expect(described_class.directory_runtime_growth_between(run, previous_run, limit: 3).map(&:first))
          .to eq(["spec/d11", "spec/d10", "spec/d9"])
      end

      # What the capped list is the head OF, in the same round trip — counted across BOTH runs,
      # which is the figure a caption saying "of the N areas either run recorded" needs. `COUNT(*)
      # OVER ()` runs after `GROUP BY` and before `LIMIT`, so a truncated read reports the same
      # total an untruncated one does. Twelve areas in the latest run and one only the previous run
      # has: thirteen, which neither run alone could have produced.
      it "reports how many areas the comparison covered, whatever the limit returns" do
        12.times { |i| observe_area(run, "spec/d#{i}", 1, each: i + 1.0, from: (i * 20) + 1) }
        observe_area(previous_run, "spec/gone", 1, each: 1.0)

        expect(described_class.directory_runtime_growth_between(run, previous_run, limit: 3).map { |row| row[7] })
          .to eq([13, 13, 13])
        expect(described_class.directory_runtime_growth_between(run, previous_run, limit: 100)
                              .map { |row| row[7] }.uniq).to eq([13])
      end

      # The four per-run totals, and the reason they are on the query rather than derived by the
      # caller: summing the returned rows would total a CAPPED three of them and answer a question
      # about the page instead of about the run.
      #
      # The previous run is what makes this sharp. It recorded two rows — one timed, one not — in an
      # area whose movement does not survive the cap, so the rows on hand carry NONE of its examples
      # while the run recorded two. A caller deriving these from the rows would read "the previous
      # run recorded nothing" and withhold a comparison between two perfectly comparable runs.
      it "reports what each run recorded and timed in total, before the limit" do
        12.times { |i| observe_area(run, "spec/d#{i}", 1, each: i + 1.0, from: (i * 20) + 1) }
        observe_area(run, "spec/d0", 1, each: nil, from: 500)
        observe_area(previous_run, "spec/gone", 1, each: 1.0)
        observe_area(previous_run, "spec/gone", 1, each: nil, from: 600)

        rows = described_class.directory_runtime_growth_between(run, previous_run, limit: 3)

        expect(rows.map { |row| row[8] }.uniq).to eq([2])
        expect(rows.map { |row| row[9] }.uniq).to eq([13])
        expect(rows.map { |row| row[10] }.uniq).to eq([1])
        expect(rows.map { |row| row[11] }.uniq).to eq([12])
        expect(rows.map(&:first)).not_to include("spec/gone")
      end

      # Zero groups, which for this read means neither run wrote a row — a group exists here if and
      # only if a row does. The caller depends on that equivalence to name the state.
      it "reads nothing at all for two runs that recorded no examples" do
        expect(described_class.directory_runtime_growth_between(run, previous_run)).to eq([])
      end

      # Two runs that recorded rows and timed none of them is NOT an empty read: the groups are
      # there, with real counts and nil sums. That is what lets the caller say "reported no timings"
      # rather than "recorded no per-example detail" — one blank panel, two different things to fix.
      it "reads real groups with nil sums for two runs that timed nothing" do
        observe_area(previous_run, "spec/models", 2, each: nil)
        observe_area(run, "spec/models", 3, each: nil, from: 50)

        expect(described_class.directory_runtime_growth_between(run, previous_run))
          .to eq([["spec/models", nil, nil, 2, 3, 0, 0, 1, 2, 3, 0, 0]])
      end

      # The same area key as every other rollup on this table, so this panel's areas cannot be a
      # different partition of the suite from the other three. Asserted through the shape that would
      # break first if the expression were re-derived here: the IMMEDIATE parent, with a root-level
      # file coalesced rather than dropped.
      it "areas the rows exactly as the by-duration rollup does" do
        observe(previous_run, duration: 1.0, line_number: 1, spec_file_path: "spec/models/a_spec.rb")
        observe(run, duration: 1.0, line_number: 1, spec_file_path: "spec/models/orders/a_spec.rb")
        observe(run, duration: 1.0, line_number: 2, spec_file_path: "smoke_spec.rb")

        expect(described_class.directory_runtime_growth_between(run, previous_run).map(&:first))
          .to match_array([".", "spec/models", "spec/models/orders"])
      end
    end

    # The read above at one grain down, narrowed to ONE area — which FILES of it got slower, rather
    # than which areas of the suite did. The fourth and last of the {area, file} × {count, runtime}
    # comparisons this model serves, and the intersection of the two reads directly above it.
    #
    # ⭐ EVERY FIXTURE BELOW IS BUILT SO ALL THREE NEIGHBOURING READS WOULD ANSWER DIFFERENTLY, which
    # is what the two independence risks here demand. A read that had quietly become the AREA runtime
    # read narrowed would be green under any fixture whose area holds one file; a read that had
    # become the file COUNT read relabelled would be green under any fixture where the two agree. So
    # no fixture here has one file in the area, and no fixture here moves counts and seconds together.
    describe ".file_runtime_growth_between" do
      let(:previous_run) { create_test_run(repository: repository, commit_sha: "prev123") }

      # One file's worth of rows in one run, at line numbers that cannot collide within it. Each
      # example carries `each` seconds; a nil `each` is the row a client sent with no timing. `from`
      # is what keeps the two runs' example ids from lining up: a correspondence between the runs is
      # the one thing this read never claims, so no fixture here supplies one.
      def observe_file(test_run, path, count, each: 1.0, from: 1)
        count.times do |i|
          observe(test_run, duration: each, line_number: from + i, spec_file_path: path)
        end
      end

      # The pivot itself: one row per FILE carrying both runs' summed seconds and the coverage each
      # was summed over, not one row per (file, run) pair left for a caller to fold together.
      it "puts both runs' summed seconds for a file on one row" do
        observe_file(previous_run, "spec/models/order_spec.rb", 2, each: 1.0)
        observe_file(previous_run, "spec/models/user_spec.rb", 1, each: 2.0, from: 10)
        observe_file(run, "spec/models/order_spec.rb", 2, each: 4.0, from: 20)
        observe_file(run, "spec/models/user_spec.rb", 1, each: 2.0, from: 30)

        expect(described_class.file_runtime_growth_between(run, previous_run, "spec/models")).to eq(
          [["spec/models/order_spec.rb", 2.0, 8.0, 2, 2, 2, 2, 2, 3, 3, 3, 3],
           ["spec/models/user_spec.rb", 2.0, 2.0, 1, 1, 1, 1, 2, 3, 3, 3, 3]]
        )
      end

      # ⭐ THE EXAMPLE THIS WHOLE READ EXISTS FOR, and the one NEITHER neighbour can answer.
      # `order_spec.rb` gained no examples at all and got 30 seconds slower; `user_spec.rb` gained
      # two examples and a tenth of a second. The file COUNT read over these very same rows ranks
      # them the other way round and puts the 30-second regression LAST — which at a cap is off the
      # list entirely. And the AREA runtime read cannot name either file: one grain up this is a
      # single `spec/models` row.
      it "names a file that got slower without gaining a single example" do
        observe_file(previous_run, "spec/models/order_spec.rb", 2, each: 1.0)
        observe_file(previous_run, "spec/models/user_spec.rb", 1, each: 0.1, from: 20)
        observe_file(run, "spec/models/order_spec.rb", 2, each: 16.0, from: 40)
        observe_file(run, "spec/models/user_spec.rb", 3, each: 0.1, from: 60)

        rows = described_class.file_runtime_growth_between(run, previous_run, "spec/models")

        expect(rows.map(&:first)).to eq(["spec/models/order_spec.rb", "spec/models/user_spec.rb"])
        expect(rows.first[1..2]).to eq([2.0, 32.0])
        expect(rows.last[1]).to eq(0.1)
        expect(rows.last[2]).to be_within(0.001).of(0.3)
        # The count read beside it, over the SAME rows, ranks them the other way round.
        expect(described_class.file_growth_between(run, previous_run, "spec/models").map(&:first))
          .to eq(["spec/models/user_spec.rb", "spec/models/order_spec.rb"])
        # And the area read one grain up cannot name a file at all.
        expect(described_class.directory_runtime_growth_between(run, previous_run).map(&:first))
          .to eq(["spec/models"])
      end

      # The other direction of the same independence: four fast examples where one slow one used to
      # be is a GAIN of three examples and a LOSS of nine seconds.
      it "reports a file that gained examples and lost time" do
        observe_file(previous_run, "spec/models/order_spec.rb", 1, each: 10.0)
        observe_file(run, "spec/models/order_spec.rb", 4, each: 0.25, from: 20)

        expect(described_class.file_runtime_growth_between(run, previous_run, "spec/models"))
          .to eq([["spec/models/order_spec.rb", 10.0, 1.0, 1, 4, 1, 4, 1, 1, 4, 1, 4]])
      end

      # THE ranking this read exists for, and the one a `DESC`-only ordering on the SIGNED change
      # passes right over: a file that got FASTER is half of the rename this grain makes visible, and
      # signed ranking puts every speedup below every slowdown and off the end of the cap. Asserted
      # at `limit: 1` as well, so the claim is about which file SURVIVES the cap rather than only
      # about the order two surviving rows sit in.
      it "ranks by absolute movement, so a speedup outranks a smaller slowdown" do
        observe_file(previous_run, "spec/models/legacy_spec.rb", 1, each: 12.0)
        observe_file(previous_run, "spec/models/order_spec.rb", 1, each: 1.0, from: 20)
        observe_file(run, "spec/models/legacy_spec.rb", 1, each: 2.0, from: 40)
        observe_file(run, "spec/models/order_spec.rb", 1, each: 3.0, from: 60)

        expect(described_class.file_runtime_growth_between(run, previous_run, "spec/models").map(&:first))
          .to eq(["spec/models/legacy_spec.rb", "spec/models/order_spec.rb"])
        expect(described_class.file_runtime_growth_between(run, previous_run, "spec/models", limit: 1)
                              .map(&:first))
          .to eq(["spec/models/legacy_spec.rb"])
      end

      # THE shape that only exists at this grain: an area whose summed time moved by NOTHING, holding
      # one file that appeared and one that vanished carrying the same seconds. One rung up this is a
      # single `±0` row and the reader is told the panel cannot tell a relocation from a coincidence;
      # here both operands are on the page.
      it "shows a rename as one file at nil-then-seconds beside one at seconds-then-nil" do
        observe_file(previous_run, "spec/models/legacy_user_spec.rb", 2, each: 3.0)
        observe_file(run, "spec/models/user_spec.rb", 2, each: 3.0, from: 20)

        expect(described_class.file_runtime_growth_between(run, previous_run, "spec/models")).to eq(
          [["spec/models/legacy_user_spec.rb", 6.0, nil, 2, 0, 2, 0, 2, 2, 2, 2, 2],
           ["spec/models/user_spec.rb", nil, 6.0, 0, 2, 0, 2, 2, 2, 2, 2, 2]]
        )
        # And the area one grain up did not move at all, which is the dead end this resolves.
        expect(described_class.directory_runtime_growth_between(run, previous_run).map { |row| row[1..2] })
          .to eq([[6.0, 6.0]])
      end

      # ⭐ A FILE TIMED ON ONE SIDE ONLY — the absence this grain exists to keep separate from the
      # two above. Both runs RAN `order_spec.rb`; the latest sent no durations for it. `SUM` over
      # nothing is NULL and NOT zero, and both RECORDED counts are real on both sides, which is what
      # lets the caller say "the telemetry went quiet" rather than "this file now takes no time".
      it "reads a real recorded count with a nil sum for a file only one run timed" do
        observe_file(previous_run, "spec/models/order_spec.rb", 2, each: 4.0)
        observe_file(run, "spec/models/order_spec.rb", 3, each: nil, from: 20)

        expect(described_class.file_runtime_growth_between(run, previous_run, "spec/models"))
          .to eq([["spec/models/order_spec.rb", 8.0, nil, 2, 3, 2, 0, 1, 2, 3, 2, 0]])
      end

      # The same absence one step further: rows on both sides, timings on neither. Real groups, real
      # recorded counts, nil sums and zero timed counts — never an empty read, which is the state a
      # caller must be able to tell apart from "neither run recorded anything here".
      it "reads real groups with nil sums for a file neither run timed" do
        observe_file(previous_run, "spec/models/order_spec.rb", 2, each: nil)
        observe_file(run, "spec/models/order_spec.rb", 3, each: nil, from: 20)

        expect(described_class.file_runtime_growth_between(run, previous_run, "spec/models"))
          .to eq([["spec/models/order_spec.rb", nil, nil, 2, 3, 0, 0, 1, 2, 3, 0, 0]])
      end

      # ⭐ NULLS LAST, AND IT IS THE ORDERING'S WHOLE POINT. The untimed file's ordering key is NULL,
      # and `DESC` alone is NULLS FIRST — which would name the file NOBODY MEASURED the biggest mover
      # in the area and put it at the head of a list about slowdowns. Asserted with a real mover
      # present, so the claim is about where the NULL row sorts relative to a row that moved.
      it "sorts a file it cannot compare below every file it can" do
        observe_file(previous_run, "spec/models/order_spec.rb", 1, each: 1.0)
        observe_file(previous_run, "spec/models/ghost_spec.rb", 1, each: nil, from: 20)
        observe_file(run, "spec/models/order_spec.rb", 1, each: 3.0, from: 40)
        observe_file(run, "spec/models/ghost_spec.rb", 1, each: nil, from: 60)

        expect(described_class.file_runtime_growth_between(run, previous_run, "spec/models").map(&:first))
          .to eq(["spec/models/order_spec.rb", "spec/models/ghost_spec.rb"])
      end

      # The tie-break, which is the half of the ordering a client is told it can reproduce: two files
      # that moved by the same absolute seconds are ordered by PATH, not by whichever the aggregate
      # happened to emit first.
      it "breaks a tie on equal movement by path" do
        observe_file(previous_run, "spec/models/z_spec.rb", 1, each: 5.0)
        observe_file(previous_run, "spec/models/a_spec.rb", 1, each: 1.0, from: 20)
        observe_file(run, "spec/models/z_spec.rb", 1, each: 1.0, from: 40)
        observe_file(run, "spec/models/a_spec.rb", 1, each: 5.0, from: 60)

        expect(described_class.file_runtime_growth_between(run, previous_run, "spec/models").map(&:first))
          .to eq(["spec/models/a_spec.rb", "spec/models/z_spec.rb"])
      end

      # ⭐ THE NARROW IS AN EQUALITY AT ONE DEPTH, never a prefix — the same claim
      # `.file_growth_between` pins, and it has to be pinned separately here because a second
      # hand-copy of the area expression is exactly what would drift. A subtree file must NOT appear
      # under its parent's ask, and the parent's ask must not appear under the subtree's.
      it "narrows to one area exactly, and never to its subtree" do
        observe_file(previous_run, "spec/models/order_spec.rb", 1, each: 1.0)
        observe_file(previous_run, "spec/models/orders/refund_spec.rb", 1, each: 1.0, from: 20)
        observe_file(run, "spec/models/order_spec.rb", 1, each: 9.0, from: 40)
        observe_file(run, "spec/models/orders/refund_spec.rb", 1, each: 9.0, from: 60)

        expect(described_class.file_runtime_growth_between(run, previous_run, "spec/models").map(&:first))
          .to eq(["spec/models/order_spec.rb"])
        expect(described_class.file_runtime_growth_between(run, previous_run, "spec/models/orders")
                              .map(&:first))
          .to eq(["spec/models/orders/refund_spec.rb"])
      end

      # A root-level file is COALESCED into `"."` rather than dropped, which is the same area key
      # every other rollup on this table uses — so this read's areas cannot be a different partition
      # of the suite from the other three.
      it "areas a root-level file as the by-duration rollup does" do
        observe_file(previous_run, "smoke_spec.rb", 1, each: 1.0)
        observe_file(run, "smoke_spec.rb", 1, each: 4.0, from: 20)

        expect(described_class.file_runtime_growth_between(run, previous_run, ".").map(&:first))
          .to eq(["smoke_spec.rb"])
      end

      # ⭐ THE WINDOW TOTALS ARE COUNTED BEFORE THE `LIMIT`, which is what lets a caption say "the 3
      # of 5 files" without describing a different row set from the table under it. All five figures
      # are identical on every returned row and are the AREA's, and the assertion is made at two
      # different caps over one fixture so the figures cannot be `rows.size` in disguise.
      it "counts every file and every row in the area before the limit applies" do
        observe_file(previous_run, "spec/models/a_spec.rb", 2, each: 1.0)
        observe_file(previous_run, "spec/models/b_spec.rb", 2, each: 2.0, from: 20)
        observe_file(previous_run, "spec/models/c_spec.rb", 2, each: 3.0, from: 40)
        observe_file(previous_run, "spec/models/d_spec.rb", 1, each: nil, from: 60)
        observe_file(run, "spec/models/a_spec.rb", 1, each: 8.0, from: 80)
        observe_file(run, "spec/models/b_spec.rb", 1, each: 16.0, from: 100)
        observe_file(run, "spec/models/c_spec.rb", 1, each: 32.0, from: 120)
        observe_file(run, "spec/models/d_spec.rb", 1, each: 1.0, from: 140)

        capped = described_class.file_runtime_growth_between(run, previous_run, "spec/models", limit: 2)
        uncapped = described_class.file_runtime_growth_between(run, previous_run, "spec/models", limit: 100)

        expect(capped.length).to eq(2)
        expect(uncapped.length).to eq(4)
        # `[file_count, previous_recorded, latest_recorded, previous_timed, latest_timed]` — the same
        # five under a cap of two as under a cap that reaches every row. The timed pair differs from
        # the recorded pair on the previous side (7 rows, 6 timed), so a read that had folded the two
        # into one figure could not pass this.
        expect(capped.map { |row| row[7..11] }.uniq).to eq([[4, 7, 4, 6, 4]])
        expect(uncapped.map { |row| row[7..11] }.uniq).to eq([[4, 7, 4, 6, 4]])
      end

      # The AREA's totals and never the RUN's — the hazard `.file_growth_between` states and which is
      # doubled here, because there are two pairs of them. Rows outside the asked-for area move both
      # the suite's recorded and its timed totals and must move neither of these.
      it "counts only the asked-for area's rows in its totals" do
        observe_file(previous_run, "spec/models/order_spec.rb", 2, each: 1.0)
        observe_file(previous_run, "spec/services/payment_spec.rb", 9, each: 1.0, from: 20)
        observe_file(run, "spec/models/order_spec.rb", 3, each: 1.0, from: 40)
        observe_file(run, "spec/services/payment_spec.rb", 14, each: 1.0, from: 60)

        expect(described_class.file_runtime_growth_between(run, previous_run, "spec/models"))
          .to eq([["spec/models/order_spec.rb", 2.0, 3.0, 2, 3, 2, 3, 1, 2, 3, 2, 3]])
      end

      # An area neither run recorded is an EMPTY READ and not an error — a stale bookmark, a typo, a
      # directory deleted since. A group exists here if and only if a row does, which is what lets
      # the caller detect this state without a second count.
      it "returns nothing at all for an area neither run recorded" do
        observe_file(previous_run, "spec/models/order_spec.rb", 2, each: 1.0)
        observe_file(run, "spec/models/order_spec.rb", 2, each: 2.0, from: 20)

        expect(described_class.file_runtime_growth_between(run, previous_run, "spec/ghosts")).to eq([])
      end

      # A third run's rows are not in this comparison. The read narrows on an `IN` list of exactly
      # two ids, and a suite with history either side of the pair must not leak into either operand.
      it "reads only the two runs it was given" do
        other_run = create_test_run(repository: repository, commit_sha: "other99")
        observe_file(previous_run, "spec/models/order_spec.rb", 1, each: 1.0)
        observe_file(other_run, "spec/models/order_spec.rb", 1, each: 100.0, from: 20)
        observe_file(run, "spec/models/order_spec.rb", 1, each: 2.0, from: 40)

        expect(described_class.file_runtime_growth_between(run, previous_run, "spec/models"))
          .to eq([["spec/models/order_spec.rb", 1.0, 2.0, 1, 1, 1, 1, 1, 1, 1, 1, 1]])
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
