# frozen_string_literal: true

require "rails_helper"

# The per-file RUNTIME growth drill-in's object: ONE area's spec files compared across two runs BY
# SUMMED DURATION, together with the captions a surface listing them has to state.
#
# The fourth and last cell of the {area, file} × {count, runtime} square, and its own file rather
# than examples inside the request spec for one reason that file cannot serve: this object's
# defining property is what it does when the panel it hangs off REFUSES to compare, and there are
# NINE such states — three more than its count sibling has. Through an API response they are nine
# fixtures that all serialize the same `null`, so a request spec can tell "absent because the parent
# refused" from "absent because the object is broken" only by inference. Here the refusal is the
# return value and each state is named.
#
# == Why the runs are ingested rather than inserted
#
# Through `Ingest::RunRecorder` because the states this object turns on are shapes the RECORDER
# produces, and several cannot be built any other way: a run with a `total_specs_count` and no
# per-example rows is what a client posting only totals writes; a run with rows and no durations is
# what a client whose reporter omits `run_time` writes (`Ingest::ObservationRecorder` stores
# `result&.run_time`); and a shard count that differs between two runs comes from `test_run_shards`
# rows the recorder writes. A hand-built pair can trivially agree with itself in ways CI never does.
RSpec.describe SpecDirectoryFileRuntimeGrowth do
  let(:repository) { create_repository }

  def ingest(commit_sha:, specs: nil, branch: "main", total: nil, shard_id: nil, **attrs)
    payload = { commit_sha: commit_sha, branch: branch,
                total_specs_count: total || specs&.size || 0,
                annotated_specs_count: 0, duration_seconds: 60.0 }.merge(attrs)
    options = specs.nil? ? {} : { specs: specs.map(&:deep_stringify_keys) }
    options[:shard_id] = shard_id if shard_id

    Ingest::RunRecorder.record(repository, payload, **options)
  end

  # `count` examples in one file, each timed at `each` seconds — or UNTIMED where `each` is nil,
  # which is the row a client whose reporter sends no `run_time` writes and the state half this
  # object's absences turn on. `offset` is what keeps the two runs' example ids from lining up: a
  # correspondence between the runs is the one thing this object never claims, so no fixture here
  # supplies one.
  def file_specs(path, count, each: 1.0, offset: 0)
    Array.new(count) do |i|
      unannotated_spec(file_path: path, line_number: offset + i + 1, duration: each)
    end
  end

  # The two runs, earlier first, and the objects the page builds off them — the PARENT panel and
  # then this drill-in, in that order and with the parent handed in, exactly as the controller does
  # it. Returned together so every example below asserts about a drill-in built the way production
  # builds one.
  def build(previous_specs: nil, latest_specs: nil, previous_total: nil, latest_total: nil,
            path: "spec/models", limit: nil, **latest_attrs)
    ingest(commit_sha: "prev00000000001", specs: previous_specs, total: previous_total)
    repository.test_runs.last.update!(created_at: 2.hours.ago)
    ingest(commit_sha: "late00000000002", specs: latest_specs, total: latest_total, **latest_attrs)

    previous_run, latest_run = repository.test_runs.order(:created_at).to_a
    growth = SpecDirectoryRuntimeGrowth.for(latest_run, previous_run)
    options = limit ? { limit: limit } : {}

    described_class.for(latest_run, previous_run, path, growth: growth, **options)
  end

  # The four figures the API serves off each row, in the model's own names. The signed `change` and
  # not a rendering of it: this object carries no labels — they land with the `repositories#show`
  # panel — so the operands ARE the assertion, which is also exactly what a client is handed.
  def rows_as_read(drill_in)
    drill_in.rows.map { |row| [row.path, row.previous_seconds, row.latest_seconds, row.change] }
  end

  describe "two comparable runs" do
    # `order_spec.rb` got 6s SLOWER on the same two examples, `legacy_spec.rb` shed 10s, and
    # `user_spec.rb` did not move. Built so two independent claims are testable at once: the biggest
    # movement in the area is a SPEEDUP, so an object ranking the signed change puts `legacy_spec.rb`
    # last instead of first — and NO file's example count moves at all, so an object that had quietly
    # become the count drill-in relabelled returns three `±0` rows and cannot rank them.
    def retimed_area
      build(
        previous_specs: file_specs("spec/models/order_spec.rb", 2, each: 1.0) +
                        file_specs("spec/models/legacy_spec.rb", 2, each: 6.0, offset: 100) +
                        file_specs("spec/models/user_spec.rb", 1, each: 3.0, offset: 200),
        latest_specs: file_specs("spec/models/order_spec.rb", 2, each: 4.0, offset: 300) +
                      file_specs("spec/models/legacy_spec.rb", 2, each: 1.0, offset: 400) +
                      file_specs("spec/models/user_spec.rb", 1, each: 3.0, offset: 500)
      )
    end

    # @intent: { entity: "SpecDirectoryFileRuntimeGrowth", action: "compare one area's files across two runs by summed duration", behavior: "each row exposes the summed seconds from both runs plus the signed difference, ordered by the magnitude of movement", layer: "unit" }
    it "carries each file's seconds then, its seconds now, and the movement between them" do
      expect(rows_as_read(retimed_area)).to eq(
        [["spec/models/legacy_spec.rb", 12.0, 2.0, -10.0],
         ["spec/models/order_spec.rb", 2.0, 8.0, 6.0],
         ["spec/models/user_spec.rb", 3.0, 3.0, 0.0]]
      )
    end

    # ⭐ THE CLAIM THAT SEPARATES THIS CELL FROM THE ONE BESIDE IT, asserted over the very same rows:
    # not one file in that fixture changed its example count, so the count drill-in ranks nothing and
    # reports three unmoved files. A read that had become that one would be green on shape and silent
    # on the whole subject.
    # @intent: { entity: "SpecDirectoryFileRuntimeGrowth", action: "compare one area's files across two runs by summed duration", behavior: "with unchanged example counts the runtime rows still move while the count sibling reports zero movement everywhere, proving this ranking is driven by timing and not rows", layer: "unit" }
    it "ranks files the count drill-in over the same rows cannot rank at all" do
      drill_in = retimed_area
      previous_run, latest_run = repository.test_runs.order(:created_at).to_a
      counts = SpecDirectoryFileGrowth.for(latest_run, previous_run, "spec/models",
                                           growth: SpecDirectoryGrowth.for(latest_run, previous_run))

      expect(drill_in.rows.map(&:moved?)).to eq([true, true, false])
      expect(counts.rows.map(&:change)).to eq([0, 0, 0])
      expect(counts).not_to be_any_movement
    end

    # @intent: { entity: "SpecDirectoryFileRuntimeGrowth", action: "compare one area's files across two runs by summed duration", behavior: "the drill-in reports itself comparable with the same state symbol the parent panel produced", layer: "unit" }
    it "is comparable, and carries the parent panel's verdict verbatim" do
      drill_in = retimed_area

      expect(drill_in).to be_comparable
      expect(drill_in.state).to eq(:comparable)
    end

    # ⭐ ALL FOUR DENOMINATORS ARE THIS AREA'S, never the runs'. The fixture puts a much larger
    # population in a second area precisely so an object reading the parent read's whole-run totals —
    # the same four figures under the same names one rung up — produces visibly wrong denominators.
    # The timed pair differs from the recorded pair inside the area too, so the two cannot be read
    # off each other.
    # @intent: { entity: "SpecDirectoryFileRuntimeGrowth", action: "compare one area's files across two runs by summed duration", behavior: "the four per-run denominator counts cover only files under the requested area, ignoring a heavier population recorded in other directories", layer: "unit" }
    it "counts all four of its totals over the asked-for area and not over the whole run" do
      drill_in = build(
        previous_specs: file_specs("spec/models/order_spec.rb", 2, each: 1.0) +
                        file_specs("spec/models/ghost_spec.rb", 1, each: nil, offset: 50) +
                        file_specs("spec/requests/checkout_spec.rb", 40, each: 1.0, offset: 100),
        latest_specs: file_specs("spec/models/order_spec.rb", 5, each: 1.0, offset: 200) +
                      file_specs("spec/requests/checkout_spec.rb", 60, each: 1.0, offset: 400)
      )

      expect(drill_in.previous_recorded_count).to eq(3)
      expect(drill_in.latest_recorded_count).to eq(5)
      expect(drill_in.previous_timed_count).to eq(2)
      expect(drill_in.latest_timed_count).to eq(5)
      expect(drill_in.file_count).to eq(2)
    end

    # ⭐ THE RENAME SHAPE, which is the whole reason this grain exists and which the area grain
    # cannot produce: one file appears carrying the seconds another lost. One rung up this is a
    # single `±0` row and the reader is told the panel cannot tell a relocation from a coincidence.
    #
    # Asserted through the PREDICATES as well as the operands, because "on one side only" against a
    # `+12.00s` delta is the distinction the whole cell turns on: a delta against an absent side is
    # arithmetic on a zero that was never a measurement of this file. `change` is nil on both rows
    # and the two predicates are what say WHICH absence each one is — the pair the API serves for
    # exactly this reason, since neither is derivable from a null `change`.
    # @intent: { entity: "SpecDirectoryFileRuntimeGrowth", action: "compare one area's files across two runs by summed duration", behavior: "a renamed file surfaces as one row absent from the latest run beside one absent from the previous run, with nil changes and predicate flags distinguishing new from removed while neither is a timing gap", layer: "unit" }
    it "shows a relocation as a new file beside a removed one, and never as two deltas" do
      drill_in = build(
        previous_specs: file_specs("spec/models/legacy_user_spec.rb", 2, each: 6.0),
        latest_specs: file_specs("spec/models/user_spec.rb", 2, each: 6.0, offset: 100)
      )

      expect(rows_as_read(drill_in)).to eq(
        [["spec/models/legacy_user_spec.rb", 12.0, nil, nil],
         ["spec/models/user_spec.rb", nil, 12.0, nil]]
      )
      expect(drill_in.rows.map(&:new_file?)).to eq([false, true])
      expect(drill_in.rows.map(&:removed_file?)).to eq([true, false])
      # Neither is a TIMING gap: both files were timed by the run that has them. Three absences,
      # three predicates, and this is what keeps them from collapsing into one.
      expect(drill_in.rows.map(&:timing_gap?)).to eq([false, false])
    end

    # ⭐ A FILE TIMED ON ONE SIDE ONLY — the absence this quantity adds and the count grain has no
    # way to express. Both runs RAN `order_spec.rb` and the latest reported no duration for it, so
    # there is nothing to subtract and the cell must say so. `0.00s` here would be "the telemetry
    # went quiet" made byte-identical to "this file now takes no time", which is the one reading the
    # whole object exists to refuse.
    #
    # The second area is LOAD BEARING and not scenery: without it the latest run times nothing at
    # all, which is a fact about the RUN — the parent refuses with `latest_untimed` and this object
    # correctly builds no rows. Keeping another area timed on both sides is what makes the gap a
    # fact about THIS FILE, which is the whole distinction the object exists to hold.
    # @intent: { entity: "SpecDirectoryFileRuntimeGrowth", action: "compare one area's files across two runs by summed duration", behavior: "a file the latest run ran but never timed keeps a nil latest side and nil change, flagged as a timing gap rather than presented as a speedup to zero", layer: "unit" }
    it "reports a file only one run timed as a timing gap and never as a speedup" do
      drill_in = build(
        previous_specs: file_specs("spec/models/order_spec.rb", 2, each: 4.0) +
                        file_specs("spec/requests/checkout_spec.rb", 1, each: 1.0, offset: 50),
        latest_specs: file_specs("spec/models/order_spec.rb", 2, each: nil, offset: 100) +
                      file_specs("spec/requests/checkout_spec.rb", 1, each: 1.0, offset: 150)
      )

      row = drill_in.rows.sole

      # The latest side is nil and STAYS nil all the way out — a `0.0` here is "the telemetry went
      # quiet" made byte-identical to "this file now takes no time".
      expect(row.previous_seconds).to eq(8.0)
      expect(row.latest_seconds).to be_nil
      expect(row.change).to be_nil
      expect(row).not_to be_comparable
      expect(row).not_to be_moved
      # A gap in the REPORTING, not in the file: both runs ran it, so it is neither side's absence.
      expect(row).to be_timing_gap
      expect(row).not_to be_new_file
      expect(row).not_to be_removed_file
      # And the area's own timed denominators disclose which side went quiet, counted over this area
      # and never over the run — the figures that keep a summed side from being read as complete.
      expect(drill_in.previous_timed_count).to eq(2)
      expect(drill_in.latest_timed_count).to be_zero
      expect(drill_in.previous_recorded_count).to eq(2)
      expect(drill_in.latest_recorded_count).to eq(2)
    end

    # ⭐ A FILE THAT IS BOTH NEW AND UNTIMED — the intersection of two of the three absences, and the
    # one a single nullable `change` cannot express. `new_file?` is asked of the ROWS and
    # `comparable?` of the SECONDS, so they answer independently here: this file is on one side only
    # AND that side reported no duration for it. A client is owed both facts, because "a file we
    # just added" and "a file nothing timed" are different things to go and fix, and folding them
    # would let the panel announce a magnitude it never measured.
    # @intent: { entity: "SpecDirectoryFileRuntimeGrowth", action: "compare one area's files across two runs by summed duration", behavior: "a file present only in the latest run and unmeasured there is flagged new_file while timing_gap stays false, keeping the two absences distinct", layer: "unit" }
    it "keeps a new file's absence apart from its missing timing" do
      drill_in = build(
        previous_specs: file_specs("spec/models/order_spec.rb", 1, each: 1.0),
        latest_specs: file_specs("spec/models/order_spec.rb", 1, each: 1.0, offset: 100) +
                      file_specs("spec/models/new_spec.rb", 1, each: nil, offset: 200)
      )
      row = drill_in.rows.find { |candidate| candidate.path == "spec/models/new_spec.rb" }

      expect(row).to be_new_file
      expect(row).not_to be_comparable
      expect(row.latest_seconds).to be_nil
      expect(row.previous_seconds).to be_nil
      expect(row.change).to be_nil
      # NOT a timing gap, which is the narrower fact: that predicate is for a file BOTH runs ran.
      # A row that answered true to both would be two different sentences about one cell.
      expect(row).not_to be_timing_gap
      expect(row).not_to be_removed_file
    end

    # An area neither run recorded is an ordinary answer — a stale bookmark, a typo, a directory
    # deleted since — and it is `:comparable` with NO ROWS, DISTINCT from every one of the nine
    # non-comparable states, which are about the RUNS and would be wrong to spell here. An object
    # that refused instead would tell a reader their two runs cannot be compared because they
    # mistyped a path.
    # @intent: { entity: "SpecDirectoryFileRuntimeGrowth", action: "compare one area's files across two runs by summed duration", behavior: "a directory neither run recorded yields a comparable state with zero rows and zero file count rather than a refusal naming a run-level defect", layer: "unit" }
    it "reports an area neither run touched as an empty comparison, not as a refusal to compare" do
      drill_in = build(
        previous_specs: file_specs("spec/models/order_spec.rb", 2, each: 1.0),
        latest_specs: file_specs("spec/models/order_spec.rb", 2, each: 2.0, offset: 100),
        path: "spec/ghosts"
      )

      expect(drill_in).to be_comparable
      expect(drill_in.rows).to be_empty
      expect(drill_in.file_count).to be_zero
      expect(drill_in.state).to eq(:comparable)
      expect(drill_in.path).to eq("spec/ghosts")
    end

    # @intent: { entity: "SpecDirectoryFileRuntimeGrowth", action: "compare one area's files across two runs by summed duration", behavior: "truncation is decided against the area's total file count, so a limited list still reports the full population and its truncated flag", layer: "unit" }
    it "truncates against the area's file count and not against its own length" do
      drill_in = build(
        previous_specs: file_specs("spec/models/gone_spec.rb", 1, each: 1.0),
        latest_specs: (0..11).flat_map do |i|
          file_specs("spec/models/f#{i}_spec.rb", 1, each: (i + 1) * 2.0, offset: i * 100)
        end,
        limit: 3
      )

      expect(drill_in.rows.size).to eq(3)
      expect(drill_in.file_count).to eq(13)
      expect(drill_in).to be_truncated
    end

    # @intent: { entity: "SpecDirectoryFileRuntimeGrowth", action: "compare one area's files across two runs by summed duration", behavior: "when the limit exceeds the file population the truncated flag is false and the row count equals the file count", layer: "unit" }
    it "is not truncated where the list shows every file the comparison covered" do
      drill_in = build(
        previous_specs: file_specs("spec/models/order_spec.rb", 2, each: 1.0),
        latest_specs: file_specs("spec/models/order_spec.rb", 2, each: 5.0, offset: 100)
      )

      expect(drill_in).not_to be_truncated
      expect(drill_in.file_count).to eq(drill_in.rows.size)
    end

    # ⭐ AN UNMOVED ROW AND AN UNCOMPARABLE ONE ARE DIFFERENT ROWS, which is the distinction the two
    # nil-valued sides make easy to lose. A file whose seconds did not move was COMPARED and came out
    # at zero; a file with a nil side was never compared at all — there was nothing to subtract. Both
    # ride in the tail of a ranking by absolute movement, so a reader meets them side by side, and a
    # `moved?` that answered false for both would make the two indistinguishable in the one place
    # they sit together. Asserted in BOTH directions on BOTH predicates.
    # @intent: { entity: "SpecDirectoryFileRuntimeGrowth", action: "compare one area's files across two runs by summed duration", behavior: "a compared row with zero movement is comparable and unmoved, while a never-compared row with nil sides is a timing gap, so the two predicates never collapse the distinction", layer: "unit" }
    it "tells a file that did not move apart from one it could not compare" do
      ran_out = build(
        previous_specs: file_specs("spec/models/order_spec.rb", 1, each: 1.0) +
                        file_specs("spec/models/user_spec.rb", 1, each: 3.0, offset: 100),
        latest_specs: file_specs("spec/models/order_spec.rb", 1, each: 5.0, offset: 200) +
                      file_specs("spec/models/user_spec.rb", 1, each: 3.0, offset: 300)
      )
      unmoved = ran_out.rows.find { |row| row.path == "spec/models/user_spec.rb" }

      expect(unmoved).to be_comparable
      expect(unmoved).not_to be_moved
      expect(unmoved.change).to eq(0.0)

      repository.test_runs.destroy_all
      # A file NEITHER run timed — the third absence, and the one whose nil sums come from the
      # timings rather than from the rows. It is not comparable, so it did not "fail to move".
      only_untimed = build(
        previous_specs: file_specs("spec/models/order_spec.rb", 1, each: 1.0) +
                        file_specs("spec/models/quiet_spec.rb", 1, each: nil, offset: 100),
        latest_specs: file_specs("spec/models/order_spec.rb", 1, each: 5.0, offset: 200) +
                      file_specs("spec/models/quiet_spec.rb", 1, each: nil, offset: 300)
      )
      quiet = only_untimed.rows.find { |row| row.path == "spec/models/quiet_spec.rb" }

      expect(quiet).not_to be_comparable
      expect(quiet).not_to be_moved
      expect(quiet.change).to be_nil
      expect(quiet).to be_timing_gap
    end

    # The default limit is this cell's OWN constant, and the assertion has to pin WHICH constant
    # rather than which number: its neighbour `SPEC_DIRECTORY_FILE_GROWTH_LIMIT` caps the SAME files
    # ranked by the OTHER quantity and holds the SAME VALUE today, so every equality against `30`
    # passes under either. Stubbed instead — a limit read from the count drill-in's constant, or from
    # a literal, does not move when this one does, which is the whole failure this guards.
    # @intent: { entity: "SpecDirectoryFileRuntimeGrowth", action: "compare one area's files across two runs by summed duration", behavior: "stubbing the runtime growth limit changes the row count while the count sibling's constant is untouched, proving the default comes from this object's own constant", layer: "unit" }
    it "defaults to this cell's own limit and not the count drill-in's" do
      stub_const("SpecObservation::SPEC_DIRECTORY_FILE_RUNTIME_GROWTH_LIMIT", 4)

      drill_in = build(
        previous_specs: file_specs("spec/models/gone_spec.rb", 1, each: 1.0),
        latest_specs: (0..11).flat_map do |i|
          file_specs("spec/models/f#{i}_spec.rb", 1, each: (i + 1) * 2.0, offset: i * 100)
        end
      )

      expect(drill_in.rows.size).to eq(4)
      expect(drill_in.file_count).to eq(13)
      # The value coincides with the count drill-in's today, which is exactly why the stub above is
      # the assertion and this is only a note: the two are separate constants because they rank the
      # same files by independent quantities.
      expect(SpecObservation::SPEC_DIRECTORY_FILE_GROWTH_LIMIT).to eq(30)
    end
  end

  # ⭐ THE PROPERTY THIS OBJECT IS DEFINED BY: it is a closer look at an answer the panel above has
  # already given, never a second opinion about two runs. Where that panel refuses to compare, this
  # refuses identically and for the reason it was given — it does not re-derive the verdict, and SIX
  # of these nine states are not derivable from one area's rows at all.
  describe "when the parent panel cannot compare" do
    # Each entry builds a real run pair in the named state, through the recorder, so what is asserted
    # is a state the PARENT actually produces rather than a symbol typed here and nowhere else. A
    # refusal the parent never issues would leave its example red.
    #
    # The last three are the ones the count sibling has no equivalent of and are the reason this list
    # is nine rather than six: a run can record every row and time none of them, which is a suite
    # whose client sends no `run_time` — and it must read as "this run reported no timings" and never
    # as "every file lost all its time".
    {
      latest_unmeasured: -> { { previous_specs: file_specs("spec/models/o_spec.rb", 3), latest_total: 0 } },
      previous_unmeasured: -> { { previous_total: 0, latest_specs: file_specs("spec/models/o_spec.rb", 3) } },
      previous_unrecorded: -> { { previous_total: 40, latest_specs: file_specs("spec/models/o_spec.rb", 3) } },
      latest_unrecorded: -> { { previous_specs: file_specs("spec/models/o_spec.rb", 3), latest_total: 40 } },
      neither_recorded: -> { { previous_total: 40, latest_total: 42 } },
      neither_timed: lambda {
        { previous_specs: file_specs("spec/models/o_spec.rb", 3, each: nil),
          latest_specs: file_specs("spec/models/o_spec.rb", 4, each: nil, offset: 100) }
      },
      previous_untimed: lambda {
        { previous_specs: file_specs("spec/models/o_spec.rb", 3, each: nil),
          latest_specs: file_specs("spec/models/o_spec.rb", 4, each: 1.0, offset: 100) }
      },
      latest_untimed: lambda {
        { previous_specs: file_specs("spec/models/o_spec.rb", 3, each: 1.0),
          latest_specs: file_specs("spec/models/o_spec.rb", 4, each: nil, offset: 100) }
      }
    }.each do |state, fixture|
      # @intent: { entity: "SpecDirectoryFileRuntimeGrowth", action: "compare one area's files across two runs by summed duration", behavior: "for every one of eight parent refusal fixtures the drill-in returns the parent's state symbol, no rows and not comparable", layer: "unit" }
      it "refuses to compare, naming '#{state}', exactly as the panel above does" do
        drill_in = build(**instance_exec(&fixture))

        expect(drill_in.state).to eq(state)
        expect(drill_in).not_to be_comparable
        expect(drill_in.rows).to be_empty
      end
    end

    # The ninth, built apart because it is the only one whose cause is HOW the runs were assembled
    # rather than what they measured: a sharded run differenced against a complete one reports every
    # file shrinking. `shard_id` is what `Ingest::RunRecorder` turns into the `test_run_shards` row
    # `TestRun#assembled_like?` counts.
    # @intent: { entity: "SpecDirectoryFileRuntimeGrowth", action: "compare one area's files across two runs by summed duration", behavior: "a sharded run differenced against a complete one is refused with the assembled_differently state rather than ranking mass shrinkage", layer: "unit" }
    it "refuses to compare two runs assembled from different numbers of parts" do
      drill_in = build(previous_specs: file_specs("spec/models/order_spec.rb", 4, each: 1.0),
                       latest_specs: file_specs("spec/models/order_spec.rb", 4, each: 9.0, offset: 100),
                       ci_run_id: "gha-1", shard_id: "0")

      expect(drill_in.state).to eq(:assembled_differently)
      expect(drill_in).not_to be_comparable
    end

    # ⭐ THE STATE IS THE PARENT'S AND IS NEVER RE-DERIVED, asserted through the shape that makes the
    # difference visible rather than through the symbol alone. Here `spec/models` is an area only the
    # LATEST run recorded, inside two runs that BOTH recorded plenty — so an object re-deriving its
    # verdict from this area's own rows would find zero previous-side rows and spell it
    # `previous_unrecorded`: "the earlier run recorded nothing ANYWHERE", printed directly beneath a
    # panel listing that run's areas. The inherited answer is `:comparable`, and the area's emptiness
    # on the previous side is the ROW's `new_file?`.
    # @intent: { entity: "SpecDirectoryFileRuntimeGrowth", action: "compare one area's files across two runs by summed duration", behavior: "when only the latest run recorded the requested area inside two otherwise full runs, the state stays comparable and the missing side is expressed as the row's new_file flag", layer: "unit" }
    it "does not re-derive a run-level absence from one area's missing rows" do
      drill_in = build(
        previous_specs: file_specs("spec/requests/checkout_spec.rb", 4, each: 1.0),
        latest_specs: file_specs("spec/requests/checkout_spec.rb", 4, each: 1.0, offset: 100) +
                      file_specs("spec/models/order_spec.rb", 3, each: 2.0, offset: 200)
      )

      expect(drill_in.state).to eq(:comparable)
      expect(drill_in).to be_comparable
      expect(drill_in.rows.sole).to be_new_file
      expect(drill_in.rows.sole.previous_seconds).to be_nil
    end

    # ⭐ THE SAME MISTAKE ONE ABSENCE OVER, and this one is available ONLY at the runtime grain — it
    # is the reason the inheritance matters more here than it did for the counts. `spec/models` is an
    # area only the LATEST run timed, inside two runs that both timed plenty elsewhere. An object
    # re-deriving from this area's rows would find zero previous-side TIMED rows and spell it
    # `previous_untimed`: "the earlier run reported no timings ANYWHERE", printed directly beneath a
    # panel listing that run's per-area seconds.
    # @intent: { entity: "SpecDirectoryFileRuntimeGrowth", action: "compare one area's files across two runs by summed duration", behavior: "when only the latest run timed the requested area inside two runs timed elsewhere, the state stays comparable and the row is a timing gap rather than a run-level previous_untimed refusal", layer: "unit" }
    it "does not re-derive a run-level timing absence from one area's missing timings" do
      drill_in = build(
        previous_specs: file_specs("spec/requests/checkout_spec.rb", 4, each: 1.0) +
                        file_specs("spec/models/order_spec.rb", 2, each: nil, offset: 50),
        latest_specs: file_specs("spec/requests/checkout_spec.rb", 4, each: 1.0, offset: 100) +
                      file_specs("spec/models/order_spec.rb", 2, each: 3.0, offset: 200)
      )

      expect(drill_in.state).to eq(:comparable)
      expect(drill_in.previous_timed_count).to be_zero
      expect(drill_in.rows.sole.previous_seconds).to be_nil
      expect(drill_in.rows.sole).not_to be_comparable
      expect(drill_in.rows.sole).to be_timing_gap
    end

    # ⭐ AND THE PARENT IS THE RUNTIME ONE, NOT THE COUNT ONE — the substitution that would compile,
    # satisfy every call this object makes, and be wrong. These two runs recorded every row and timed
    # none of them: the COUNT parent finds that perfectly comparable and the RUNTIME parent refuses
    # it. Gated on the wrong parent, this object would build a table of nils under a comparable
    # verdict.
    # @intent: { entity: "SpecDirectoryFileRuntimeGrowth", action: "compare one area's files across two runs by summed duration", behavior: "two runs that recorded rows but timed none of them are comparable to the count parent yet refused by the runtime parent, and this object follows the runtime verdict", layer: "unit" }
    it "inherits the runtime parent's verdict where the count parent would have allowed it" do
      ingest(commit_sha: "prev00000000001", specs: file_specs("spec/models/o_spec.rb", 3, each: nil))
      repository.test_runs.last.update!(created_at: 2.hours.ago)
      ingest(commit_sha: "late00000000002", specs: file_specs("spec/models/o_spec.rb", 5, each: nil, offset: 100))
      previous_run, latest_run = repository.test_runs.order(:created_at).to_a

      expect(SpecDirectoryGrowth.for(latest_run, previous_run)).to be_comparable
      expect(SpecDirectoryRuntimeGrowth.for(latest_run, previous_run)).not_to be_comparable
      expect(described_class.for(latest_run, previous_run, "spec/models",
                                 growth: SpecDirectoryRuntimeGrowth.for(latest_run, previous_run)))
        .not_to be_comparable
    end

    # The refusal is not merely reported, it is TOTAL: every figure a caption would be built from is
    # zero, so nothing downstream can render a sentence about a comparison that was not made. All
    # FOUR denominators, because a fabricated `anchor_timed_count` is exactly as misleading as a
    # fabricated recorded one and there are twice as many of them here.
    # @intent: { entity: "SpecDirectoryFileRuntimeGrowth", action: "compare one area's files across two runs by summed duration", behavior: "in a refused state every denominator — file count, both recorded counts, both timed counts — reads zero alongside empty rows and no truncation", layer: "unit" }
    it "carries no figures at all in a state it refused" do
      drill_in = build(previous_specs: file_specs("spec/models/order_spec.rb", 3, each: 1.0),
                       latest_total: 40)

      expect(drill_in.file_count).to be_zero
      expect(drill_in.previous_recorded_count).to be_zero
      expect(drill_in.latest_recorded_count).to be_zero
      expect(drill_in.previous_timed_count).to be_zero
      expect(drill_in.latest_timed_count).to be_zero
      expect(drill_in.rows).to be_empty
      expect(drill_in).not_to be_truncated
    end

    # The area asked for is still named. The surface renders nothing in these states, but an object
    # that dropped its own subject on the way through the gate would be a trap for the next caller
    # that wants to say WHICH area it declined to compare.
    # @intent: { entity: "SpecDirectoryFileRuntimeGrowth", action: "compare one area's files across two runs by summed duration", behavior: "even after refusing to compare the object still reports the directory path it was asked about", layer: "unit" }
    it "still names the area it was asked about" do
      drill_in = build(previous_specs: file_specs("spec/models/order_spec.rb", 3, each: 1.0),
                       latest_total: 40, path: "spec/models")

      expect(drill_in.path).to eq("spec/models")
    end
  end

  # ⭐ THE GATE IS A READ OF AN OBJECT ALREADY IN MEMORY, so it runs BEFORE the query. An
  # implementation that queried first and gated afterwards would be green on every example above and
  # one round trip heavier on exactly the pages that have nothing to show — including, per the
  # ticket's own bound, with `?spec_directory=` set.
  describe "what it costs" do
    # The statements THIS object issued, picked out by the one thing only this aggregate does: sum
    # durations per run with `SUM(duration_seconds) FILTER (WHERE test_run_id = ...)` while grouping
    # on `spec_file_path`. The AREA runtime read sums the same way but groups on the area expression,
    # and the count drill-in groups the same way but carries no `SUM(duration_seconds)`.
    def file_runtime_growth_aggregates(&)
      executed_sql(&).select do |sql|
        sql.include?("SUM(duration_seconds) FILTER (WHERE test_run_id =") &&
          sql.include?("GROUP BY \"spec_observations\".\"spec_file_path\"")
      end
    end

    # ⭐ ZERO QUERIES IN EVERY ONE OF THE NINE REFUSALS, asserted over all nine rather than over a
    # representative — the three TIMED states are the ones a naive implementation gets wrong, because
    # they are the only refusals the parent reached by RUNNING a query, and an object that mistook
    # "the parent already read the table" for "so may I" would pay for a second read precisely there.
    {
      latest_unmeasured: -> { { previous_specs: file_specs("spec/models/o_spec.rb", 3), latest_total: 0 } },
      previous_unmeasured: -> { { previous_total: 0, latest_specs: file_specs("spec/models/o_spec.rb", 3) } },
      previous_unrecorded: -> { { previous_total: 40, latest_specs: file_specs("spec/models/o_spec.rb", 3) } },
      latest_unrecorded: -> { { previous_specs: file_specs("spec/models/o_spec.rb", 3), latest_total: 40 } },
      neither_recorded: -> { { previous_total: 40, latest_total: 42 } },
      neither_timed: lambda {
        { previous_specs: file_specs("spec/models/o_spec.rb", 3, each: nil),
          latest_specs: file_specs("spec/models/o_spec.rb", 4, each: nil, offset: 100) }
      },
      previous_untimed: lambda {
        { previous_specs: file_specs("spec/models/o_spec.rb", 3, each: nil),
          latest_specs: file_specs("spec/models/o_spec.rb", 4, each: 1.0, offset: 100) }
      },
      latest_untimed: lambda {
        { previous_specs: file_specs("spec/models/o_spec.rb", 3, each: 1.0),
          latest_specs: file_specs("spec/models/o_spec.rb", 4, each: nil, offset: 100) }
      }
    }.each do |state, fixture|
      # @intent: { entity: "SpecDirectoryFileRuntimeGrowth", action: "compare one area's files across two runs by summed duration", behavior: "across all eight parent refusal states building the drill-in issues zero per-file aggregate queries, because the gate reads the already-built parent", layer: "unit" }
      it "asks the observations table nothing in '#{state}'" do
        attrs = instance_exec(&fixture)
        ingest(commit_sha: "prev00000000001", specs: attrs[:previous_specs], total: attrs[:previous_total])
        repository.test_runs.last.update!(created_at: 2.hours.ago)
        ingest(commit_sha: "late00000000002", specs: attrs[:latest_specs], total: attrs[:latest_total])
        previous_run, latest_run = repository.test_runs.order(:created_at).to_a
        growth = SpecDirectoryRuntimeGrowth.for(latest_run, previous_run)

        queries = file_runtime_growth_aggregates do
          described_class.for(latest_run, previous_run, "spec/models", growth: growth)
        end

        expect(growth.state).to eq(state)
        expect(growth).not_to be_comparable
        expect(queries).to be_empty
      end
    end

    # @intent: { entity: "SpecDirectoryFileRuntimeGrowth", action: "compare one area's files across two runs by summed duration", behavior: "the assembled_differently refusal also issues no aggregate query before declining", layer: "unit" }
    it "asks nothing where the two runs were assembled differently" do
      ingest(commit_sha: "prev00000000001", specs: file_specs("spec/models/o_spec.rb", 3, each: 1.0))
      repository.test_runs.last.update!(created_at: 2.hours.ago)
      ingest(commit_sha: "late00000000002", specs: file_specs("spec/models/o_spec.rb", 3, each: 9.0, offset: 100),
             ci_run_id: "gha-1", shard_id: "0")
      previous_run, latest_run = repository.test_runs.order(:created_at).to_a
      growth = SpecDirectoryRuntimeGrowth.for(latest_run, previous_run)

      expect(growth.state).to eq(:assembled_differently)
      expect(file_runtime_growth_aggregates do
        described_class.for(latest_run, previous_run, "spec/models", growth: growth)
      end).to be_empty
    end

    # ONE query for the whole comparison — the rows, the file count and all four per-run totals — and
    # it does not grow with the area. Measured as a difference against ten times the examples, so an
    # implementation that counted per row, or took a second round trip for the captions, shows up
    # here whatever the absolute number happens to be.
    # @intent: { entity: "SpecDirectoryFileRuntimeGrowth", action: "compare one area's files across two runs by summed duration", behavior: "issuing the comparison costs exactly one aggregate query and the count stays flat when the area grows tenfold, ruling out per-row or per-caption round trips", layer: "unit" }
    it "costs one query, and the same one whether the area holds twenty examples or two hundred" do
      ingest(commit_sha: "prev00000000001", specs: file_specs("spec/models/order_spec.rb", 10, each: 1.0))
      repository.test_runs.last.update!(created_at: 2.hours.ago)
      ingest(commit_sha: "late00000000002",
             specs: file_specs("spec/models/order_spec.rb", 12, each: 2.0, offset: 100))
      previous_run, latest_run = repository.test_runs.order(:created_at).to_a
      growth = SpecDirectoryRuntimeGrowth.for(latest_run, previous_run)

      small = count_queries { described_class.for(latest_run, previous_run, "spec/models", growth: growth) }
      expect(small).to eq(1)

      big = create_repository(user: repository.user, github_full_name: "acme/bigger")
      Ingest::RunRecorder.record(
        big, { commit_sha: "prev00000000003", branch: "main", total_specs_count: 100,
               annotated_specs_count: 0, duration_seconds: 60.0 },
        specs: file_specs("spec/models/order_spec.rb", 100, each: 1.0).map(&:deep_stringify_keys)
      )
      big.test_runs.last.update!(created_at: 2.hours.ago)
      Ingest::RunRecorder.record(
        big, { commit_sha: "late00000000004", branch: "main", total_specs_count: 120,
               annotated_specs_count: 0, duration_seconds: 60.0 },
        specs: file_specs("spec/models/order_spec.rb", 120, each: 2.0, offset: 1_000).map(&:deep_stringify_keys)
      )
      big_previous, big_latest = big.test_runs.order(:created_at).to_a
      big_growth = SpecDirectoryRuntimeGrowth.for(big_latest, big_previous)

      expect(count_queries { described_class.for(big_latest, big_previous, "spec/models", growth: big_growth) })
        .to eq(small)
    end
  end
end
