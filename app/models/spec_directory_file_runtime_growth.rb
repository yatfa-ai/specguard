# frozen_string_literal: true

# Which FILES of ONE area got SLOWER or FASTER between the latest run and the previous run ON THE
# SAME BRANCH — per spec file: the summed example duration then, the summed example duration now,
# and the movement between them, ranked by how far each moved.
#
# The fourth and last cell of the {area, file} × {count, runtime} square this application serves
# growth over, and the one that was empty. `SpecDirectoryRuntimeGrowth` names the areas whose time
# moved most and then dead-ends on the only question a row like `spec/models 120s → 210s` provokes
# — WHICH FILE DID THAT. That dead end was identified at the COUNT grain and removed by
# `SpecDirectoryFileGrowth`; the identical dead end on the RUNTIME pair had been removed for nobody.
#
# == Why the count drill-in cannot stand in
#
# `SpecDirectoryFileGrowth` is the same two runs and the same files, measuring the other quantity,
# and its class comment is explicit that "this measures no durations at all". A file where somebody
# made an existing example slow adds ZERO examples, so its `ABS(latest_count - previous_count)` is
# `0`: it sorts last on that list and falls off the cap. It is not a row there missing a column —
# it is not on that list at all. The independence runs both ways, exactly as it does one grain up:
# splitting one slow spec into four fast ones is `+3` examples and *less* time; a `sleep` in a
# shared `before` is `0` examples and minutes.
#
# `SpecDirectoryFiles` is the other neighbour and it stops one RUN short: it carries per-file
# `total_seconds` for the LATEST RUN ONLY (its own class comment: "ONE code area's spec files in ONE
# run"), so the previous run's per-file seconds exist in no object on any surface. The subtraction
# this object performs is not merely unserved — it is unavailable anywhere else.
#
# == It compares populations; it matches no tests
#
# The premise every panel in this family stands on, restated because a duration at the file grain is
# the one a reader is most tempted to read as a correspondence: this sums each file's rows in each
# run and subtracts two numbers. No `example_id` crosses the run boundary and no example is paired
# with another example — an edit that joins these runs on `example_id` in order to say "this test
# got slower" has left what this object is allowed to say, whatever the numbers come out as.
#
# == What the finer grain buys, given that
#
# The parent panel discloses a doubt and then leaves the reader holding it: a directory that was
# RENAMED reads there as one area gaining time and another losing the same amount, with nothing
# having got slower and nothing faster. This object does not resolve that doubt either — it cannot,
# and it asserts nothing new. What it does is put the operands where a HUMAN can resolve it.
# `spec/models/user_spec.rb 0s → 47s` beside `spec/models/legacy_user_spec.rb 47s → 0s` reads as a
# relocation at a glance, and `spec/models/billing_spec.rb 3s → 50s` does not.
#
# == The comparability gate is the PARENT'S verdict, not a second spelling of it
#
# The NINE states in which there is no comparison to draw — `latest_unmeasured`,
# `previous_unmeasured`, `assembled_differently`, `neither_recorded`, `previous_unrecorded`,
# `latest_unrecorded`, `neither_timed`, `previous_untimed`, `latest_untimed` — are
# `SpecDirectoryRuntimeGrowth`'s, and they are INHERITED here rather than re-derived. `.for` takes
# the parent panel's own object and refuses to build anything the moment that panel is not
# comparable.
#
# That is `SpecDirectoryFileGrowth`'s rule with the parent swapped, and its two reasons carry over
# with the second one WIDENED by the runtime grain:
#
# 1. `SuiteTrajectory`'s class comment prices a THIRD spelling of the Overview delta's predicates,
#    and this would be a further one: `TestRun#suite_size_measured?` and `#assembled_like?` are
#    already asked by the panel above, on the same two runs, on the same page. Asking them again
#    could only ever produce the same answer or a bug.
#
# 2. SIX of the nine states CANNOT be re-derived here without changing what they mean — where the
#    count grain had two. They are computed from window totals across EVERY area, so they are facts
#    about a RUN, and everything this object reads is narrowed to one area. An area only the latest
#    run timed has zero previous-side timed rows, which is `previous_untimed` spelled identically
#    and meaning something else entirely: "the earlier run reported no timings ANYWHERE" versus
#    "this area was not timed". A drill-in that made that mistake would announce a run as having
#    reported no timings directly beneath a panel listing that run's per-area seconds. The three
#    TIMED states are new since the count grain, so the blast radius is larger here than it was
#    there, which is why the inheritance is if anything more load bearing at this cell than at its
#    sibling.
#
# The consequence is the rule the surface obeys: this drill-in is ABSENT whenever the panel it
# drills out of cannot compare. It is not a second opinion about two runs — it is a closer look at
# an answer the panel above has already given, and it must never assert a comparison its parent
# refuses.
#
# == NOT a `timed_shard_count` check, and that is a decision rather than an oversight
#
# The temptation is real and specific: the Overview runtime delta guards on equal
# `timed_shard_count` (`repositories/show.html.erb`) and this is a runtime read, so an object at the
# finest runtime grain looks like the one most owing that guard. It does not take it, for the reason
# `SpecDirectoryRuntimeGrowth` states and DECIDES for this family — quoted because the whole
# argument is that it is grain-independent:
#
# > That guard exists because a run's wall clock is a **MAX over its shards** … This read sums
# > **per-example rows** — machine time, not wall clock — so it has no MAX to fold and no shard
# > denominator to compare.
#
# A file-grain sum of `duration_seconds` is the same measurement one grouping narrower. It has no
# MAX to fold either, and narrowing a sum does not turn it into a maximum. Demanding a
# durations-shaped guard the measurement does not need would withhold comparisons that are sound.
# Where a shard genuinely went missing, `assembled_like?` is what catches it — and it is the
# PARENT'S `assembled_like?`, already asked, per the rule above.
#
# == Zero queries when there is nothing to compare
#
# The gate is a read of an object already in memory, so it runs BEFORE the query in all nine states
# and the drill-in costs the page nothing on a page that cannot compare — even with
# `?spec_directory=` set. The parent's own gate has already paid for itself; this adds no round trip
# to it.
#
# == The absences are the point, and there are two grains of them
#
# `SpecDirectoryRuntimeGrowth`'s disclosure, unchanged by the grain and stated over this AREA's
# rows. `SUM` skips NULLs silently and `duration_seconds` is nullable by design, so this object has
# to keep apart three things that all render as an empty cell: a file with no ROWS on a side, a file
# with rows none of which were TIMED on that side, and a file that genuinely took no time. The first
# two are not measurements and must never be spelled `0.00s` — `SpecObservation.humanized_duration`
# is the one seam that decides that, at every grain.
#
# What is deliberately NOT done with them is promote either into a state. The nine states are the
# parent's and are about the RUNS; an area or a file with no rows is a fact about the AREA, and it
# is `#recorded?` and the row predicates respectively — the same separation `SpecDirectoryFileGrowth`
# keeps.
#
# == One object, so the caption cannot drift from the table
#
# The rule every panel at every grain keeps: a caption is a claim ABOUT the list, so "the 30 of 41
# files either run recorded in this area" is only true if both figures were counted off the rows the
# table lists. Every figure here comes back from the one grouped aggregate that returned the rows,
# as windows counted before the `LIMIT` — see `SpecObservation.file_runtime_growth_between`.
#
# == An area neither run recorded is not an error
#
# `?spec_directory=` is a URL a reader types, edits and bookmarks, and two runs that touched nothing
# in the area they ask for is an ordinary answer rather than a malformed request: a stale bookmark,
# a directory deleted since, a typo. That is `#recorded?` being false — distinct from every one of
# the nine non-comparable states, which are about the RUNS and would be wrong to spell here.
class SpecDirectoryFileRuntimeGrowth
  # Builds the comparison for one area, or nothing at all.
  #
  # `growth` is the parent panel's own `SpecDirectoryRuntimeGrowth`, already built for this same pair
  # of runs. It is passed rather than rebuilt so the two panels cannot disagree about whether these
  # runs are comparable, and so this costs no second gate — see the class comment for why six of its
  # nine states are not re-derivable at this grain in any case.
  def self.for(test_run, previous_test_run, path, growth:,
               limit: SpecObservation::SPEC_DIRECTORY_FILE_RUNTIME_GROWTH_LIMIT)
    return new(path: path, state: growth.state) unless growth.comparable?

    from_tuples(path, SpecObservation.file_runtime_growth_between(test_run, previous_test_run, path,
                                                                  limit: limit))
  end

  # The five window totals ride on every row and are identical on all of them, so they are read off
  # the first; `to_i` over the nil of an empty read, where zero files and zero rows on both sides is
  # the honest count. An empty read is exactly the "neither run recorded anything in this area"
  # state — a group exists here if and only if a row exists — so it needs no separate count to
  # detect, and it is `#recorded?` rather than a state of its own.
  #
  # ⭐ NO STATE IS DERIVED HERE, which is the difference from the parent's `from_tuples` and the
  # whole of this object's gate discipline. That method reads its window totals and returns one of
  # six absence states off them; this one reads the same five figures and returns `:comparable`
  # regardless, because at this grain those totals are one AREA's and the six states they would spell
  # are claims about the RUNS. See the class comment.
  def self.from_tuples(path, tuples)
    rows = tuples.map do |file_path, prev_seconds, latest_seconds, prev_rec, latest_rec, prev_t, latest_t, *|
      Row.new(path: file_path, previous_seconds: prev_seconds, latest_seconds: latest_seconds,
              previous_recorded_count: prev_rec.to_i, latest_recorded_count: latest_rec.to_i,
              previous_timed_count: prev_t.to_i, latest_timed_count: latest_t.to_i)
    end

    _path, _prev_s, _latest_s, _prev_rec, _latest_rec, _prev_t, _latest_t,
      file_count, previous_recorded, latest_recorded, previous_timed, latest_timed = tuples.first

    new(path: path, state: :comparable, rows: rows, file_count: file_count.to_i,
        previous_recorded_count: previous_recorded.to_i, latest_recorded_count: latest_recorded.to_i,
        previous_timed_count: previous_timed.to_i, latest_timed_count: latest_timed.to_i)
  end
  private_class_method :from_tuples

  def initialize(path:, state:, rows: [], file_count: 0, previous_recorded_count: 0,
                 latest_recorded_count: 0, previous_timed_count: 0, latest_timed_count: 0)
    @path = path
    @state = state
    @rows = rows
    @file_count = file_count
    @previous_recorded_count = previous_recorded_count
    @latest_recorded_count = latest_recorded_count
    @previous_timed_count = previous_timed_count
    @latest_timed_count = latest_timed_count
  end

  # The area that was asked for, as it was asked for. Held even when nothing came back, because the
  # empty state has to name it — "no spec files" without a subject is a sentence about nothing.
  attr_reader :path

  # The parent panel's verdict on the two runs, carried verbatim. `:comparable` or one of its nine
  # refusals — never a state of this object's own devising, which is the whole point of it being
  # inherited.
  attr_reader :state

  # The comparison, largest movement in seconds first. Never longer than the limit it was built
  # with, and empty in every non-comparable state.
  attr_reader :rows

  # How many spec files the comparison COVERED in this area — every file either run recorded a row
  # for, counted before the `LIMIT` and therefore not `rows.size`. The list is capped, so its own
  # length answers "how many rows am I looking at" and nothing else; a caption built on it would read
  # "the files this area holds" on a page showing thirty of forty-one.
  attr_reader :file_count

  # How many per-example rows each run recorded IN THIS AREA, and how many of those carried a timing
  # — the denominators every figure on this panel is stated against, counted before the `LIMIT`.
  #
  # Both pairs, and never only the timed one: "12 examples reported a timing" is twelve of something
  # unstated, and the whole reading this panel turns on is whether a file got faster or merely went
  # quiet. Deliberately NOT the parent's identically-named figures, which are whole-run totals: every
  # figure here comes back from the one grouped aggregate that returned the rows, narrowed by the
  # same area predicate, and a caption mixing the two would divide an area's population by the
  # suite's.
  attr_reader :previous_recorded_count, :latest_recorded_count
  attr_reader :previous_timed_count, :latest_timed_count

  def comparable? = state == :comparable

  # Either run recorded at least one example in this area. False for an area that is a typo, a stale
  # bookmark, or a directory both runs are innocent of — distinct from every one of the nine
  # non-comparable states, which are about the RUNS and would be wrong to spell here.
  def recorded? = rows.any?

  # There are files the comparison covered that the list does not show.
  def truncated? = file_count > rows.size

  # At least one listed file's summed duration actually moved. False for an area whose every file
  # took the same time in both runs — a real and unremarkable answer ("nothing here got slower"),
  # worth saying in words rather than showing as a table of `±0`.
  #
  # Asked of the LISTED rows, which is sound in exactly one direction and that is the direction this
  # needs: the ranking is by absolute movement descending, so if any file moved at all the top row is
  # one that did. A false here is therefore a claim about every file the comparison covered.
  def any_movement? = rows.any?(&:moved?)

  # At least one LISTED file has both sides timed and did not move. Unmoved files can only appear in
  # the tail of a ranking by absolute movement, and they appear exactly when fewer files moved than
  # the cap has room for — so a list headed "the files that moved most" can contain files that did
  # not move. Not a defect (the reader is seeing where the movement ran out) but the caption has a
  # clause for it.
  def any_unmoved? = rows.any? { |row| row.comparable? && !row.moved? }

  # At least one LISTED file has no movement to state because a side of it was never timed. Those
  # rows sort LAST (the ordering key is NULL and the read asks for `NULLS LAST`), so they appear for
  # the same reason unmoved rows do, and they need their own clause: "not reported" in a Change
  # column is a different sentence from `±0`.
  def any_untimed? = rows.any? { |row| !row.comparable? }

  # At least one LISTED file is a TIMING GAP specifically: both runs ran it, and one of them reported
  # no duration for it. Narrower than `any_untimed?` on purpose — a file only one run HAS is also
  # uncomparable, but its cell already says "New file" or "File removed", and a sentence about runs
  # that "reported no timing" would be describing a different row from the one the reader is looking
  # at. Two absences, two cells, two sentences.
  def any_timing_gap? = rows.any?(&:timing_gap?)

  # There is a table worth rendering: some listed file either moved or has an absence to disclose.
  #
  # `any_movement?` alone is NOT that question, and the difference is the one this panel exists for.
  # A file that stopped reporting timings, a file only one run has — those rows moved by nothing
  # because there is nothing to subtract, and they are exactly the rows a reader must see rather than
  # have folded into "no file changed pace". That sentence is a claim that this area took the same
  # time in both runs, and it is false of an area half of which went unmeasured.
  def anything_to_show? = any_movement? || any_untimed?

  # One spec file's movement in seconds between two runs, both operands it was taken across, and what
  # each operand was summed over.
  #
  # Deliberately NOT `SpecDirectoryRuntimeGrowth::Row` reused or subclassed, though the arithmetic is
  # identical. Every string it renders names the grain — "New area" against "New file", "an area the
  # previous run did not record" against a file — and those readings are the whole product of the
  # struct: a shared Row would have to take its own nouns as arguments, which is a parameterised
  # sentence template standing where two plain sentences were, and the next grain to want a third
  # noun makes it three. The two structs are the same shape and not the same claim, which is the
  # disposition `SpecDirectoryFileGrowth::Row` takes on exactly this question against exactly this
  # parent.
  Row = Struct.new(:path, :previous_seconds, :latest_seconds, :previous_recorded_count,
                   :latest_recorded_count, :previous_timed_count, :latest_timed_count,
                   keyword_init: true) do
    # This file has a movement at all: both sides summed a real number of seconds. False whenever
    # either side timed nothing here, which is SQL NULL out of the aggregate and stays nil all the
    # way to the cell — a subtraction against it would be arithmetic on a zero that was never a
    # measurement of this file.
    def comparable? = !previous_seconds.nil? && !latest_seconds.nil?

    # Signed, and the sign carries the whole meaning: a file that gained 47 seconds and one that shed
    # 47 are opposite facts — and side by side in one area they are the two halves of the rename this
    # panel makes visible. Nil where there is nothing to subtract.
    def change = comparable? ? latest_seconds - previous_seconds : nil

    def moved? = comparable? && !change.zero?

    # This file is in the new run and not in the old one — asked of the ROWS and never of the
    # seconds, because a file both runs ran and neither timed also has two nil sums and is a
    # completely different fact. The object holding this row has already established, through the
    # parent panel's gate, that BOTH runs recorded rows, so a zero here is this run genuinely having
    # nothing in this file.
    def new_file? = previous_recorded_count.zero?

    def removed_file? = latest_recorded_count.zero?

    # Both runs RAN this file and one of them did not time it — the absence that is about the
    # reporting rather than about the file existing. Distinct from `new_file?`/`removed_file?`, whose
    # nil sums come from a side having no rows here at all, and which the Change cell names in their
    # own words.
    def timing_gap? = !comparable? && !new_file? && !removed_file?

    # Each operand, rendered — through the same seam one example's duration, one file's total and one
    # area's total are rendered through, so no two grains on this page can disagree about how a
    # duration is spelled, and a side that timed nothing says "not reported" rather than "0.00s".
    def previous_label = SpecObservation.humanized_duration(previous_seconds)

    def latest_label = SpecObservation.humanized_duration(latest_seconds)

    # How much of this file each side actually timed, always as a fraction and never as a bare count
    # — `SpecDirectoryDurations#coverage_label`'s rule, doubled because there are two sides: "12" in
    # a column of "12 of 40" reads as twelve of something unstated, and a total summed over a third
    # of a file is exactly the reading this column exists to qualify.
    def coverage_label
      "#{previous_timed_count} of #{previous_recorded_count} → " \
        "#{latest_timed_count} of #{latest_recorded_count}"
    end

    # What moved, rendered.
    #
    # A file present on only one side says so instead of printing a delta, for the reason the area
    # grain gives and which is sharper here: `+47s` against an absent side is arithmetic on a zero
    # that was never a measurement of this file, and it reads identically to an existing file that
    # got forty-seven seconds slower. At THIS grain that distinction is the panel's entire subject —
    # a file at "New file" beside one at "File removed" is the shape of a rename, and two files at
    # `+47s` and `−47s` is not. A file present on both sides but timed on only one gets its own
    # reading for the same reason and a different cause: nothing regressed, the telemetry did.
    #
    # `±0` for a file whose time did not move, on the rule `ApplicationHelper#suite_size_change`
    # sets: "compared, and it did not move" is a real answer and `+0` claims a direction it does not
    # have. A true minus (U+2212) and not a hyphen-minus, for that helper's typographic reason — this
    # renders in a `tabular-nums` column under and over other signed figures, and a hyphen is drawn
    # narrower and lower than the `+` it has to align with.
    #
    # A movement too small for the two decimals `humanized_duration` prints comes back "+< 0.01s"
    # rather than "+0.00s", which is that method's own rule and the reason it is reused here: a
    # measurement wearing the spelling of a zero is the one reading it exists to refuse.
    def change_label
      return "New file" if new_file?
      return "File removed" if removed_file?
      return "Not timed" unless comparable?
      return "±0" unless moved?

      "#{change.negative? ? "−" : "+"}#{SpecObservation.humanized_duration(change.abs)}"
    end

    # The same fact in words, for the `aria-label` on that cell.
    #
    # Both halves of the visible rendering fail when read aloud, exactly as they do one panel up: the
    # row announces as a path and several unattached numbers, and U+2212 — chosen above precisely
    # because it is not a hyphen — is announced inconsistently across screen readers, from "minus" to
    # nothing at all. So the direction and what it was measured against are spelled out rather than
    # left to the glyph.
    def change_reading
      return new_file_reading if new_file?
      return removed_file_reading if removed_file?
      return untimed_reading unless comparable?
      return "took the same time as it did in the previous run on this branch" unless moved?

      "#{SpecObservation.humanized_duration(change.abs)} " \
        "#{change.negative? ? "faster" : "slower"} than the previous run on this branch"
    end

    private

    # A new file normally announces its own total, which is the magnitude a reader wants. But a file
    # can be BOTH new and untimed, and "not reported of examples" is not a sentence — so the two
    # facts are said as two facts rather than run through one template.
    def new_file_reading
      return "a file the previous run did not record, and this run reported no timing for it" if latest_seconds.nil?

      "#{latest_label} of examples, a file the previous run did not record"
    end

    def removed_file_reading
      return "a file this run does not have, and the previous run reported no timing for it" if previous_seconds.nil?

      "#{previous_label} of examples in the previous run and none now"
    end

    # Which side went quiet, said as a fact about the REPORTING and never about the code. This is the
    # row whose visible cell reads "Not timed", and the one place a reader could otherwise infer a
    # speedup from an absence.
    def untimed_reading
      return "neither run reported a timing for this file" if previous_seconds.nil? && latest_seconds.nil?
      return "this run reported no timing for this file, so there is nothing to compare" if latest_seconds.nil?

      "the previous run on this branch reported no timing for this file, so there is nothing to compare"
    end
  end
end
