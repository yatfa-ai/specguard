# frozen_string_literal: true

require "rails_helper"

# The per-file growth drill-in's object: ONE area's spec files compared across two runs, together
# with the captions the surface listing them has to state.
#
# Its own file rather than examples inside spec/requests/repository_spec_directory_file_growth_spec.rb,
# for one reason that file cannot serve: this object's defining property is what it does when the
# panel it hangs off REFUSES to compare, and there are six such states. Through the page they are
# six fixtures that all render the same absence — a panel that is not there — so a request spec can
# tell "absent because the parent refused" from "absent because the object is broken" only by
# inference. Here the refusal is the return value and each state is named.
#
# == Why the runs are ingested rather than inserted
#
# Through `Ingest::RunRecorder` because the states this object turns on are shapes the RECORDER
# produces, and two of them cannot be built any other way: a run with a `total_specs_count` and no
# per-example rows is what a client posting only totals writes, and a shard count that differs
# between two runs comes from `test_run_shards` rows the recorder writes. A hand-built pair can
# trivially agree with itself in ways CI never does — the trap SPGD-91 names.
RSpec.describe SpecDirectoryFileGrowth do
  let(:repository) { create_repository }

  def ingest(commit_sha:, specs: nil, branch: "main", total: nil, shard_id: nil, **attrs)
    payload = { commit_sha: commit_sha, branch: branch,
                total_specs_count: total || specs&.size || 0,
                annotated_specs_count: 0, duration_seconds: 60.0 }.merge(attrs)
    options = specs.nil? ? {} : { specs: specs.map(&:deep_stringify_keys) }
    options[:shard_id] = shard_id if shard_id

    Ingest::RunRecorder.record(repository, payload, **options)
  end

  # `count` examples in one file, at line numbers that cannot collide within their run. `offset` is
  # what keeps the two runs' example ids from lining up: a correspondence between the runs is the
  # one thing this object never claims, so no fixture here supplies one.
  def file_specs(path, count, offset: 0)
    Array.new(count) do |i|
      unannotated_spec(file_path: path, line_number: offset + i + 1, duration: 0.1)
    end
  end

  # The two runs, earlier first, and the objects the page builds off them — the parent panel and
  # then this drill-in, in that order and with the parent handed in, exactly as the controller does
  # it. Returned together so every example below asserts about a drill-in built the way production
  # builds one.
  def build(previous_specs: nil, latest_specs: nil, previous_total: nil, latest_total: nil,
            path: "spec/models", limit: nil, **latest_attrs)
    ingest(commit_sha: "prev00000000001", specs: previous_specs, total: previous_total)
    repository.test_runs.last.update!(created_at: 2.hours.ago)
    ingest(commit_sha: "late00000000002", specs: latest_specs, total: latest_total, **latest_attrs)

    previous_run, latest_run = repository.test_runs.order(:created_at).to_a
    growth = SpecDirectoryGrowth.for(latest_run, previous_run)
    options = limit ? { limit: limit } : {}

    described_class.for(latest_run, previous_run, path, growth: growth, **options)
  end

  def rows_as_read(drill_in)
    drill_in.rows.map { |row| [row.path, row.previous_count, row.latest_count, row.change_label] }
  end

  describe "two comparable runs" do
    # `order_spec.rb` gained 3, `legacy_spec.rb` LOST 5, `user_spec.rb` did not move. Built so the
    # ranking's whole claim is testable: the biggest movement in the area is a deletion, so an
    # object ranking the SIGNED change puts `legacy_spec.rb` last instead of first.
    def moved_area
      build(
        previous_specs: file_specs("spec/models/order_spec.rb", 2) +
                        file_specs("spec/models/legacy_spec.rb", 6, offset: 100) +
                        file_specs("spec/models/user_spec.rb", 1, offset: 200),
        latest_specs: file_specs("spec/models/order_spec.rb", 5, offset: 300) +
                      file_specs("spec/models/legacy_spec.rb", 1, offset: 400) +
                      file_specs("spec/models/user_spec.rb", 1, offset: 500)
      )
    end

    # @intent: { entity: "SpecDirectoryFileGrowth", action: "rank the area's files by movement", behavior: "rows come out ordered by absolute change descending so a file that lost five examples tops one that gained three, each carrying the previous count, the latest count and a signed change label", layer: "unit" }
    it "carries each file's count then, its count now, and the movement between them" do
      expect(rows_as_read(moved_area)).to eq(
        [["spec/models/legacy_spec.rb", 6, 1, "−5"],
         ["spec/models/order_spec.rb", 2, 5, "+3"],
         ["spec/models/user_spec.rb", 1, 1, "±0"]]
      )
    end

    # @intent: { entity: "SpecDirectoryFileGrowth", action: "report its state flags for a moving area", behavior: "comparable, recorded and any_movement are all true with state :comparable when two fully recorded runs differenced to real per-file movement", layer: "unit" }
    it "is comparable, has recorded rows, and says the area's movement is real" do
      drill_in = moved_area

      expect(drill_in).to be_comparable
      expect(drill_in).to be_recorded
      expect(drill_in).to be_any_movement
      expect(drill_in.state).to eq(:comparable)
    end

    # The counts are this AREA's, never the runs'. The fixture puts a much larger population in a
    # second area precisely so an object reading the parent read's whole-run totals — the same
    # figures under the same names one rung up — produces visibly wrong denominators here.
    # @intent: { entity: "SpecDirectoryFileGrowth", action: "scope its totals to the asked-for area", behavior: "previous_recorded_count, latest_recorded_count and file_count count only the requested directory's rows, ignoring a much larger population sitting in a second area", layer: "unit" }
    it "counts its totals over the asked-for area and not over the whole run" do
      drill_in = build(
        previous_specs: file_specs("spec/models/order_spec.rb", 2) +
                        file_specs("spec/requests/checkout_spec.rb", 40, offset: 100),
        latest_specs: file_specs("spec/models/order_spec.rb", 5, offset: 200) +
                      file_specs("spec/requests/checkout_spec.rb", 60, offset: 400)
      )

      expect(drill_in.previous_recorded_count).to eq(2)
      expect(drill_in.latest_recorded_count).to eq(5)
      expect(drill_in.file_count).to eq(1)
    end

    # THE shape this object exists for. One rung up the area is a single `±0` row under a caption
    # admitting it cannot tell a relocation from a gain and a loss; here both halves are named, and
    # named as STATES rather than differenced against a zero that was never a measurement of that
    # file. The object still asserts no correspondence between the two — it counts rows.
    # @intent: { entity: "SpecDirectoryFileGrowth", action: "state vanished and appeared files outright", behavior: "a file present only in the earlier run reads as a removal and one present only in the later run as a new file, never as a count differenced against a zero that never measured that file", layer: "unit" }
    it "names a vanished file and an appeared one rather than differencing either from a zero" do
      drill_in = build(
        previous_specs: file_specs("spec/models/user_spec.rb", 4),
        latest_specs: file_specs("spec/models/users_spec.rb", 4, offset: 100)
      )

      expect(rows_as_read(drill_in)).to eq(
        [["spec/models/user_spec.rb", 4, 0, "File removed"],
         ["spec/models/users_spec.rb", 0, 4, "New file"]]
      )
      expect(drill_in.rows.first).to be_removed_file
      expect(drill_in.rows.last).to be_new_file
    end

    # U+2212 and `±` are announced inconsistently across screen readers — from "minus" to nothing at
    # all — and three numbers in a row announce as three unattached numbers. So the direction and
    # what it was measured against are spelled out. The two one-sided readings name the FILE grain:
    # the sibling one rung up says "area", and a struct reused across the two would say it here.
    # @intent: { entity: "SpecDirectoryFileGrowth", action: "spell movements out in words", behavior: "change_reading renders each movement as a full sentence naming the file grain — counts then and now, a file the previous run lacked, or unchanged — instead of bare signed numbers", layer: "unit" }
    it "spells every movement out in words" do
      drill_in = build(
        previous_specs: file_specs("spec/models/legacy_spec.rb", 6) +
                        file_specs("spec/models/user_spec.rb", 1, offset: 100),
        latest_specs: file_specs("spec/models/order_spec.rb", 3, offset: 200) +
                      file_specs("spec/models/user_spec.rb", 1, offset: 300)
      )
      readings = drill_in.rows.to_h { |row| [row.path, row.change_reading] }

      expect(readings["spec/models/legacy_spec.rb"]).to eq("6 examples in the previous run and none now")
      expect(readings["spec/models/order_spec.rb"]).to eq("3 examples, a file the previous run did not record")
      expect(readings["spec/models/user_spec.rb"]).to eq("unchanged since the previous run on this branch")
    end

    # An area whose every file holds the same number of examples in both runs. A real answer — and
    # the one a reader who suspected a rename most wants confirmed — and specifically NOT one of the
    # six no-comparison states: the runs compared fine and nothing moved.
    # @intent: { entity: "SpecDirectoryFileGrowth", action: "distinguish a steady area from a refused one", behavior: "an area where every file held exactly still stays comparable and recorded with any_movement false and both files counted, rather than collapsing into a no-comparison state", layer: "unit" }
    it "is comparable and recorded but shows no movement where every file held still" do
      drill_in = build(
        previous_specs: file_specs("spec/models/order_spec.rb", 3) +
                        file_specs("spec/models/user_spec.rb", 2, offset: 100),
        latest_specs: file_specs("spec/models/order_spec.rb", 3, offset: 200) +
                      file_specs("spec/models/user_spec.rb", 2, offset: 300)
      )

      expect(drill_in).to be_comparable
      expect(drill_in).to be_recorded
      expect(drill_in).not_to be_any_movement
      expect(drill_in.file_count).to eq(2)
    end

    # Two comparable runs that touched nothing in the area asked for. `?spec_directory=` is a URL a
    # reader types, edits and bookmarks, so a typo, a stale bookmark and a directory deleted before
    # both runs all arrive here — an ordinary answer, and deliberately NOT spelled as one of the six
    # states, which are facts about the RUNS. The path is held so the empty state can name it.
    # @intent: { entity: "SpecDirectoryFileGrowth", action: "answer for an unrecorded area without refusing", behavior: "asking about a directory neither run touched yields comparable true, recorded false, empty rows and a retained path, so a typo or stale bookmark is not misreported as incomparable runs", layer: "unit" }
    it "reports an area neither run recorded as unrecorded rather than as incomparable" do
      drill_in = build(
        previous_specs: file_specs("spec/models/order_spec.rb", 2),
        latest_specs: file_specs("spec/models/order_spec.rb", 5, offset: 100),
        path: "spec/ghosts"
      )

      expect(drill_in).to be_comparable
      expect(drill_in).not_to be_recorded
      expect(drill_in.path).to eq("spec/ghosts")
      expect(drill_in.rows).to be_empty
      expect(drill_in.file_count).to be_zero
    end

    # The cap and what it is the head OF. `file_count` is counted before the `LIMIT`, so it is the
    # figure a caption saying "of the N either run recorded" needs and `rows.size` is not — and
    # `truncated?` is what makes the surface SAY so rather than leaving a reader to infer it from a
    # list whose length happens to equal a limit they cannot see.
    # @intent: { entity: "SpecDirectoryFileGrowth", action: "cap the list while counting everything", behavior: "rows are truncated to the limit yet file_count still counts all files the comparison covered and truncated? flags the cut for the caption to disclose", layer: "unit" }
    it "caps the list while counting the comparison it is the head of" do
      drill_in = build(
        previous_specs: file_specs("spec/models/gone_spec.rb", 1),
        latest_specs: (0..11).flat_map { |i| file_specs("spec/models/f#{i}_spec.rb", i + 1, offset: i * 100) },
        limit: 3
      )

      expect(drill_in.rows.size).to eq(3)
      expect(drill_in.file_count).to eq(13)
      expect(drill_in).to be_truncated
    end

    # @intent: { entity: "SpecDirectoryFileGrowth", action: "report an uncut list as whole", behavior: "truncated? is false exactly when file_count equals rows.size, so a full listing never claims to hide files", layer: "unit" }
    it "is not truncated where the list shows every file the comparison covered" do
      drill_in = build(
        previous_specs: file_specs("spec/models/order_spec.rb", 2),
        latest_specs: file_specs("spec/models/order_spec.rb", 5, offset: 100)
      )

      expect(drill_in).not_to be_truncated
      expect(drill_in.file_count).to eq(drill_in.rows.size)
    end

    # The ranking is by absolute movement descending and the list is capped, so unmoved files can
    # only ever appear in the tail — and they appear exactly when fewer files moved than the cap has
    # room for. Asserted in BOTH directions, because a clause that is always true is a description
    # of nothing.
    # @intent: { entity: "SpecDirectoryFileGrowth", action: "say whether unmoved files made the list", behavior: "any_unmoved is true when a steady file sits inside the cap and flips to false once every listed file moved, asserted in both directions", layer: "unit" }
    it "knows whether the movement ran out before the list did" do
      ran_out = build(
        previous_specs: file_specs("spec/models/order_spec.rb", 2) +
                        file_specs("spec/models/user_spec.rb", 1, offset: 100),
        latest_specs: file_specs("spec/models/order_spec.rb", 5, offset: 200) +
                      file_specs("spec/models/user_spec.rb", 1, offset: 300)
      )

      expect(ran_out).to be_any_unmoved

      repository.test_runs.destroy_all
      every_row_moved = build(
        previous_specs: file_specs("spec/models/order_spec.rb", 2) +
                        file_specs("spec/models/user_spec.rb", 6, offset: 100),
        latest_specs: file_specs("spec/models/order_spec.rb", 5, offset: 200) +
                      file_specs("spec/models/user_spec.rb", 1, offset: 300)
      )

      expect(every_row_moved).not_to be_any_unmoved
    end

    # The default limit is this panel's OWN constant, asserted by name. Its neighbour
    # `SPEC_DIRECTORY_FILES_LIMIT` caps one run's listing of the same area's files, so a reuse of it
    # would pass every example above and silently make one edit move two panels.
    # @intent: { entity: "SpecDirectoryFileGrowth", action: "default to its own limit", behavior: "an unlimited build returns exactly SPEC_DIRECTORY_FILE_GROWTH_LIMIT rows, asserted distinct from the neighbouring SPEC_DIRECTORY_FILES_LIMIT so one edit cannot silently move two panels", layer: "unit" }
    it "defaults to the panel's own limit and not the neighbouring listing's" do
      drill_in = build(
        previous_specs: file_specs("spec/models/gone_spec.rb", 1),
        latest_specs: (0..31).flat_map { |i| file_specs("spec/models/f#{i}_spec.rb", i + 1, offset: i * 100) }
      )

      expect(drill_in.rows.size).to eq(SpecObservation::SPEC_DIRECTORY_FILE_GROWTH_LIMIT)
      expect(SpecObservation::SPEC_DIRECTORY_FILE_GROWTH_LIMIT)
        .not_to eq(SpecObservation::SPEC_DIRECTORY_FILES_LIMIT)
    end
  end

  # THE property this object is defined by: it is a closer look at an answer the panel above has
  # already given, never a second opinion about two runs. Where that panel refuses to compare, this
  # refuses identically and for the reason it was given — it does not re-derive the verdict, and two
  # of these six states are not derivable from one area's rows at all.
  describe "when the parent panel cannot compare" do
    # Each entry builds a real run pair in the named state, through the recorder, so what is
    # asserted is a state the PARENT actually produces rather than a symbol typed here and nowhere
    # else. A refusal the parent never issues would leave its example red.
    {
      latest_unmeasured: -> { { previous_specs: file_specs("spec/models/order_spec.rb", 3), latest_total: 0 } },
      previous_unmeasured: -> { { previous_total: 0, latest_specs: file_specs("spec/models/order_spec.rb", 3) } },
      previous_unrecorded: -> { { previous_total: 40, latest_specs: file_specs("spec/models/order_spec.rb", 3) } },
      latest_unrecorded: -> { { previous_specs: file_specs("spec/models/order_spec.rb", 3), latest_total: 40 } },
      neither_recorded: -> { { previous_total: 40, latest_total: 42 } }
    }.each do |state, fixture|
      # @intent: { entity: "SpecDirectoryFileGrowth", action: "inherit each parent refusal by name", behavior: "for each of the five recorder-produced no-comparison states the drill-in returns that exact state symbol, reports itself incomparable and produces no rows", layer: "unit" }
      it "refuses to compare, naming '#{state}', exactly as the panel above does" do
        drill_in = build(**instance_exec(&fixture))

        expect(drill_in.state).to eq(state)
        expect(drill_in).not_to be_comparable
        expect(drill_in.rows).to be_empty
      end
    end

    # The sixth, built apart because it is the only one whose cause is HOW the runs were assembled
    # rather than what they measured: a sharded run differenced against a complete one reports every
    # file shrinking. `shard_id` is what `Ingest::RunRecorder` turns into the `test_run_shards` row
    # `TestRun#assembled_like?` counts.
    # @intent: { entity: "SpecDirectoryFileGrowth", action: "refuse runs assembled from different parts", behavior: "a sharded latest run differenced against a complete previous one yields state :assembled_differently and comparable false rather than a bogus across-the-board shrinkage", layer: "unit" }
    it "refuses to compare two runs assembled from different numbers of parts" do
      drill_in = build(previous_specs: file_specs("spec/models/order_spec.rb", 4),
                       latest_specs: file_specs("spec/models/order_spec.rb", 2, offset: 100),
                       ci_run_id: "gha-1", shard_id: "0")

      expect(drill_in.state).to eq(:assembled_differently)
      expect(drill_in).not_to be_comparable
    end

    # The refusal is not merely reported, it is TOTAL: every figure the caption would be built from
    # is zero, so nothing downstream can render a sentence about a comparison that was not made.
    # @intent: { entity: "SpecDirectoryFileGrowth", action: "zero every figure on refusal", behavior: "in a refused state file_count, both recorded counts, recorded, any_movement and truncated are all zero or false, leaving no numbers a caption could build a comparison sentence from", layer: "unit" }
    it "carries no figures at all in a state it refused" do
      drill_in = build(previous_specs: file_specs("spec/models/order_spec.rb", 3), latest_total: 40)

      expect(drill_in.file_count).to be_zero
      expect(drill_in.previous_recorded_count).to be_zero
      expect(drill_in.latest_recorded_count).to be_zero
      expect(drill_in).not_to be_recorded
      expect(drill_in).not_to be_any_movement
      expect(drill_in).not_to be_truncated
    end

    # The area asked for is still named. The surface renders nothing in these states, but an object
    # that dropped its own subject on the way through the gate would be a trap for the next caller
    # that wants to say WHICH area it declined to compare.
    # @intent: { entity: "SpecDirectoryFileGrowth", action: "keep naming the asked-for area", behavior: "the path passed in survives the refusal unchanged so a later caller can still state which area was declined", layer: "unit" }
    it "still names the area it was asked about" do
      drill_in = build(previous_specs: file_specs("spec/models/order_spec.rb", 3), latest_total: 40,
                       path: "spec/models")

      expect(drill_in.path).to eq("spec/models")
    end
  end

  # The gate is a read of an object already in memory, so it runs BEFORE the query. An
  # implementation that queried first and gated afterwards would be green on every example above
  # and one round trip heavier on exactly the pages that have nothing to show.
  describe "what it costs" do
    # `count_queries` and `executed_sql` come from spec/support/query_capture.rb.

    # The statements THIS object issued, picked out by the one thing only this aggregate does:
    # count rows per run with `COUNT(*) FILTER (WHERE test_run_id = ...)` while grouping on
    # `spec_file_path`. The parent read counts the same way but groups on the area expression, and
    # the runtime siblings carry `SUM(duration_seconds)`.
    def file_growth_aggregates(&)
      executed_sql(&).select do |sql|
        sql.include?("COUNT(*) FILTER (WHERE test_run_id =") &&
          sql.include?("GROUP BY \"spec_observations\".\"spec_file_path\"") &&
          sql.exclude?("SUM(duration_seconds)")
      end
    end

    # @intent: { entity: "SpecDirectoryFileGrowth", action: "query nothing when the parent refuses", behavior: "building the drill-in under an incomparable parent issues no per-run count-filtered group-by on spec_observations at all", layer: "unit" }
    it "asks the observations table nothing where the parent panel cannot compare" do
      ingest(commit_sha: "prev00000000001", total: 40)
      repository.test_runs.last.update!(created_at: 2.hours.ago)
      ingest(commit_sha: "late00000000002", specs: file_specs("spec/models/order_spec.rb", 3))
      previous_run, latest_run = repository.test_runs.order(:created_at).to_a
      growth = SpecDirectoryGrowth.for(latest_run, previous_run)

      queries = file_growth_aggregates do
        described_class.for(latest_run, previous_run, "spec/models", growth: growth)
      end

      expect(growth).not_to be_comparable
      expect(queries).to be_empty
    end

    # ONE query for the whole comparison — the rows, the file count and both per-run totals — and it
    # does not grow with the area. Measured as a difference against ten times the examples, so an
    # implementation that counted per row, or took a second round trip for the captions, shows up
    # here whatever the absolute number happens to be.
    # @intent: { entity: "SpecDirectoryFileGrowth", action: "hold its query count flat", behavior: "the whole comparison costs exactly one query whether the area holds thirty examples or three hundred, so no per-row counting or second caption round trip creeps in", layer: "unit" }
    it "costs one query, and the same one whether the area holds thirty examples or three hundred" do
      ingest(commit_sha: "prev00000000001", specs: file_specs("spec/models/order_spec.rb", 10))
      repository.test_runs.last.update!(created_at: 2.hours.ago)
      ingest(commit_sha: "late00000000002", specs: file_specs("spec/models/order_spec.rb", 12, offset: 100))
      previous_run, latest_run = repository.test_runs.order(:created_at).to_a
      growth = SpecDirectoryGrowth.for(latest_run, previous_run)

      small = count_queries { described_class.for(latest_run, previous_run, "spec/models", growth: growth) }
      expect(small).to eq(1)

      big = create_repository(user: repository.user, github_full_name: "acme/bigger")
      Ingest::RunRecorder.record(
        big, { commit_sha: "prev00000000003", branch: "main", total_specs_count: 100,
               annotated_specs_count: 0, duration_seconds: 60.0 },
        specs: file_specs("spec/models/order_spec.rb", 100).map(&:deep_stringify_keys)
      )
      big.test_runs.last.update!(created_at: 2.hours.ago)
      Ingest::RunRecorder.record(
        big, { commit_sha: "late00000000004", branch: "main", total_specs_count: 120,
               annotated_specs_count: 0, duration_seconds: 60.0 },
        specs: file_specs("spec/models/order_spec.rb", 120, offset: 1_000).map(&:deep_stringify_keys)
      )
      big_previous, big_latest = big.test_runs.order(:created_at).to_a
      big_growth = SpecDirectoryGrowth.for(big_latest, big_previous)

      expect(count_queries { described_class.for(big_latest, big_previous, "spec/models", growth: big_growth) })
        .to eq(small)
    end
  end
end
