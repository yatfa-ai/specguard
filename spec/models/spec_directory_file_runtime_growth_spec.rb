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

  def rows_as_read(drill_in)
    drill_in.rows.map { |row| [row.path, row.previous_seconds, row.latest_seconds, row.change_label] }
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

    it "carries each file's seconds then, its seconds now, and the movement between them" do
      expect(rows_as_read(retimed_area)).to eq(
        [["spec/models/legacy_spec.rb", 12.0, 2.0, "−10.00s"],
         ["spec/models/order_spec.rb", 2.0, 8.0, "+6.00s"],
         ["spec/models/user_spec.rb", 3.0, 3.0, "±0"]]
      )
    end

    # ⭐ THE CLAIM THAT SEPARATES THIS CELL FROM THE ONE BESIDE IT, asserted over the very same rows:
    # not one file in that fixture changed its example count, so the count drill-in ranks nothing and
    # reports three unmoved files. A read that had become that one would be green on shape and silent
    # on the whole subject.
    it "ranks files the count drill-in over the same rows cannot rank at all" do
      drill_in = retimed_area
      previous_run, latest_run = repository.test_runs.order(:created_at).to_a
      counts = SpecDirectoryFileGrowth.for(latest_run, previous_run, "spec/models",
                                           growth: SpecDirectoryGrowth.for(latest_run, previous_run))

      expect(drill_in).to be_any_movement
      expect(counts.rows.map(&:change_label)).to eq(["±0", "±0", "±0"])
      expect(counts).not_to be_any_movement
    end

    it "is comparable, has recorded rows, and says the area's movement is real" do
      drill_in = retimed_area

      expect(drill_in).to be_comparable
      expect(drill_in).to be_recorded
      expect(drill_in).to be_any_movement
      expect(drill_in).to be_anything_to_show
      expect(drill_in.state).to eq(:comparable)
    end

    # ⭐ ALL FOUR DENOMINATORS ARE THIS AREA'S, never the runs'. The fixture puts a much larger
    # population in a second area precisely so an object reading the parent read's whole-run totals —
    # the same four figures under the same names one rung up — produces visibly wrong denominators.
    # The timed pair differs from the recorded pair inside the area too, so the two cannot be read
    # off each other.
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
    # Asserted through the LABELS as well as the operands, because "New file" against "+12.00s" is
    # the distinction the whole cell turns on: a delta against an absent side is arithmetic on a zero
    # that was never a measurement of this file.
    it "shows a relocation as a new file beside a removed one, and never as two deltas" do
      drill_in = build(
        previous_specs: file_specs("spec/models/legacy_user_spec.rb", 2, each: 6.0),
        latest_specs: file_specs("spec/models/user_spec.rb", 2, each: 6.0, offset: 100)
      )

      expect(rows_as_read(drill_in)).to eq(
        [["spec/models/legacy_user_spec.rb", 12.0, nil, "File removed"],
         ["spec/models/user_spec.rb", nil, 12.0, "New file"]]
      )
      expect(drill_in.rows.map(&:new_file?)).to eq([false, true])
      expect(drill_in.rows.map(&:removed_file?)).to eq([true, false])
      # Neither is a TIMING gap: both files were timed by the run that has them. Three absences,
      # three predicates, and this is what keeps them from collapsing into one.
      expect(drill_in.rows.map(&:timing_gap?)).to eq([false, false])
      expect(drill_in).not_to be_any_timing_gap
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
    it "reports a file only one run timed as a timing gap and never as a speedup" do
      drill_in = build(
        previous_specs: file_specs("spec/models/order_spec.rb", 2, each: 4.0) +
                        file_specs("spec/requests/checkout_spec.rb", 1, each: 1.0, offset: 50),
        latest_specs: file_specs("spec/models/order_spec.rb", 2, each: nil, offset: 100) +
                      file_specs("spec/requests/checkout_spec.rb", 1, each: 1.0, offset: 150)
      )

      row = drill_in.rows.sole

      expect(row.change_label).to eq("Not timed")
      expect(row.latest_label).to eq("not reported")
      expect(row.change).to be_nil
      expect(row).not_to be_comparable
      expect(row).to be_timing_gap
      expect(row).not_to be_new_file
      expect(row).not_to be_removed_file
      expect(drill_in).to be_any_timing_gap
      expect(drill_in).to be_any_untimed
      # It is still a table worth rendering, which `any_movement?` alone would deny — and denying it
      # would fold "this file stopped reporting" into "no file changed pace".
      expect(drill_in).not_to be_any_movement
      expect(drill_in).to be_anything_to_show
      # And the coverage the two sums were taken over, always as a fraction and never a bare count.
      expect(row.coverage_label).to eq("2 of 2 → 0 of 2")
    end

    # The reading each absence gets when read aloud, where the visible cell's glyphs fail. Three
    # different sentences for three different facts — a screen reader announcing U+2212
    # inconsistently is the reason the direction is spelled out rather than left to the character.
    it "says each absence in words, and says which side went quiet" do
      drill_in = build(
        previous_specs: file_specs("spec/models/gone_spec.rb", 1, each: 2.0) +
                        file_specs("spec/models/quiet_spec.rb", 1, each: 5.0, offset: 50),
        latest_specs: file_specs("spec/models/new_spec.rb", 1, each: 9.0, offset: 100) +
                      file_specs("spec/models/quiet_spec.rb", 1, each: nil, offset: 150)
      )
      readings = drill_in.rows.to_h { |row| [row.path, row.change_reading] }

      expect(readings["spec/models/new_spec.rb"])
        .to eq("9.00s of examples, a file the previous run did not record")
      expect(readings["spec/models/gone_spec.rb"])
        .to eq("2.00s of examples in the previous run and none now")
      expect(readings["spec/models/quiet_spec.rb"])
        .to eq("this run reported no timing for this file, so there is nothing to compare")
    end

    # A file that is BOTH new and untimed says the two facts as two facts rather than running them
    # through one template — "not reported of examples" is not a sentence.
    it "keeps a new file's absence apart from its missing timing" do
      drill_in = build(
        previous_specs: file_specs("spec/models/order_spec.rb", 1, each: 1.0),
        latest_specs: file_specs("spec/models/order_spec.rb", 1, each: 1.0, offset: 100) +
                      file_specs("spec/models/new_spec.rb", 1, each: nil, offset: 200)
      )
      row = drill_in.rows.find { |candidate| candidate.path == "spec/models/new_spec.rb" }

      expect(row.change_label).to eq("New file")
      expect(row.change_reading)
        .to eq("a file the previous run did not record, and this run reported no timing for it")
    end

    # A movement too small for two decimals says it is below the resolution rather than printing a
    # zero it did not measure — `SpecObservation.humanized_duration`'s own rule, reused rather than
    # respelled, which is what keeps this grain from disagreeing with the three above it.
    it "renders a sub-hundredth movement as below the resolution and not as zero" do
      drill_in = build(
        previous_specs: file_specs("spec/models/order_spec.rb", 1, each: 1.0),
        latest_specs: file_specs("spec/models/order_spec.rb", 1, each: 1.001, offset: 100)
      )

      expect(drill_in.rows.sole.change_label).to eq("+< 0.01s")
    end

    # An area neither run recorded is an ordinary answer — a stale bookmark, a typo, a directory
    # deleted since — and it is `recorded?` being false, DISTINCT from every one of the nine
    # non-comparable states, which are about the RUNS and would be wrong to spell here.
    it "reports an area neither run touched as unrecorded, not as a refusal to compare" do
      drill_in = build(
        previous_specs: file_specs("spec/models/order_spec.rb", 2, each: 1.0),
        latest_specs: file_specs("spec/models/order_spec.rb", 2, each: 2.0, offset: 100),
        path: "spec/ghosts"
      )

      expect(drill_in).to be_comparable
      expect(drill_in).not_to be_recorded
      expect(drill_in.state).to eq(:comparable)
      expect(drill_in.path).to eq("spec/ghosts")
    end

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

    it "is not truncated where the list shows every file the comparison covered" do
      drill_in = build(
        previous_specs: file_specs("spec/models/order_spec.rb", 2, each: 1.0),
        latest_specs: file_specs("spec/models/order_spec.rb", 2, each: 5.0, offset: 100)
      )

      expect(drill_in).not_to be_truncated
      expect(drill_in.file_count).to eq(drill_in.rows.size)
    end

    # ⭐ `any_unmoved?` IS ASKED OF COMPARABLE ROWS ONLY, which is what separates it from
    # `any_untimed?`. A file with a nil side did not "fail to move" — there was nothing to subtract —
    # and folding it in would make one clause true whenever the other is, describing nothing.
    # Asserted in BOTH directions, because a clause that is always true is a description of nothing.
    it "knows whether the movement ran out before the list did, ignoring rows it cannot compare" do
      ran_out = build(
        previous_specs: file_specs("spec/models/order_spec.rb", 1, each: 1.0) +
                        file_specs("spec/models/user_spec.rb", 1, each: 3.0, offset: 100),
        latest_specs: file_specs("spec/models/order_spec.rb", 1, each: 5.0, offset: 200) +
                      file_specs("spec/models/user_spec.rb", 1, each: 3.0, offset: 300)
      )

      expect(ran_out).to be_any_unmoved

      repository.test_runs.destroy_all
      only_untimed = build(
        previous_specs: file_specs("spec/models/order_spec.rb", 1, each: 1.0) +
                        file_specs("spec/models/quiet_spec.rb", 1, each: nil, offset: 100),
        latest_specs: file_specs("spec/models/order_spec.rb", 1, each: 5.0, offset: 200) +
                      file_specs("spec/models/quiet_spec.rb", 1, each: nil, offset: 300)
      )

      expect(only_untimed).to be_any_untimed
      expect(only_untimed).not_to be_any_unmoved
    end

    # The default limit is this cell's OWN constant, and the assertion has to pin WHICH constant
    # rather than which number: its neighbour `SPEC_DIRECTORY_FILE_GROWTH_LIMIT` caps the SAME files
    # ranked by the OTHER quantity and holds the SAME VALUE today, so every equality against `30`
    # passes under either. Stubbed instead — a limit read from the count drill-in's constant, or from
    # a literal, does not move when this one does, which is the whole failure this guards.
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
    # is `recorded?`.
    it "does not re-derive a run-level absence from one area's missing rows" do
      drill_in = build(
        previous_specs: file_specs("spec/requests/checkout_spec.rb", 4, each: 1.0),
        latest_specs: file_specs("spec/requests/checkout_spec.rb", 4, each: 1.0, offset: 100) +
                      file_specs("spec/models/order_spec.rb", 3, each: 2.0, offset: 200)
      )

      expect(drill_in.state).to eq(:comparable)
      expect(drill_in).to be_comparable
      expect(drill_in.rows.sole.change_label).to eq("New file")
    end

    # ⭐ THE SAME MISTAKE ONE ABSENCE OVER, and this one is available ONLY at the runtime grain — it
    # is the reason the inheritance matters more here than it did for the counts. `spec/models` is an
    # area only the LATEST run timed, inside two runs that both timed plenty elsewhere. An object
    # re-deriving from this area's rows would find zero previous-side TIMED rows and spell it
    # `previous_untimed`: "the earlier run reported no timings ANYWHERE", printed directly beneath a
    # panel listing that run's per-area seconds.
    it "does not re-derive a run-level timing absence from one area's missing timings" do
      drill_in = build(
        previous_specs: file_specs("spec/requests/checkout_spec.rb", 4, each: 1.0) +
                        file_specs("spec/models/order_spec.rb", 2, each: nil, offset: 50),
        latest_specs: file_specs("spec/requests/checkout_spec.rb", 4, each: 1.0, offset: 100) +
                      file_specs("spec/models/order_spec.rb", 2, each: 3.0, offset: 200)
      )

      expect(drill_in.state).to eq(:comparable)
      expect(drill_in.previous_timed_count).to be_zero
      expect(drill_in.rows.sole.change_label).to eq("Not timed")
      expect(drill_in.rows.sole).to be_timing_gap
    end

    # ⭐ AND THE PARENT IS THE RUNTIME ONE, NOT THE COUNT ONE — the substitution that would compile,
    # satisfy every call this object makes, and be wrong. These two runs recorded every row and timed
    # none of them: the COUNT parent finds that perfectly comparable and the RUNTIME parent refuses
    # it. Gated on the wrong parent, this object would build a table of nils under a comparable
    # verdict.
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
    it "carries no figures at all in a state it refused" do
      drill_in = build(previous_specs: file_specs("spec/models/order_spec.rb", 3, each: 1.0),
                       latest_total: 40)

      expect(drill_in.file_count).to be_zero
      expect(drill_in.previous_recorded_count).to be_zero
      expect(drill_in.latest_recorded_count).to be_zero
      expect(drill_in.previous_timed_count).to be_zero
      expect(drill_in.latest_timed_count).to be_zero
      expect(drill_in).not_to be_recorded
      expect(drill_in).not_to be_any_movement
      expect(drill_in).not_to be_any_timing_gap
      expect(drill_in).not_to be_anything_to_show
      expect(drill_in).not_to be_truncated
    end

    # The area asked for is still named. The surface renders nothing in these states, but an object
    # that dropped its own subject on the way through the gate would be a trap for the next caller
    # that wants to say WHICH area it declined to compare.
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
