# frozen_string_literal: true

# WHERE ONE RUN'S ANNOTATION DEBT IS, rolled up by code AREA — the ranking above `UnannotatedExamples`,
# and the rung that object's own class comment concedes was missing.
#
# `UnannotatedExamples` says it in its header: *"There is no ranking here and nothing to pick."* Every
# sibling drill-in on this endpoint opens the rows behind a LINE of a ranking the reader had already
# scanned — `SpecFileExamples` one file, `RepeatedDescriptionExamples` one description, `UnstableTestRuns`
# one test. That one opens a POPULATION, and it was the only one with no list above it to have chosen
# from. SPGD-608 added `?spec_file=` / `?spec_directory=` so a reader could start where the work is,
# which helps exactly the reader who ALREADY KNOWS which area to name. This object is what tells them.
#
# == Why it is not derivable from any ranking this endpoint already serves
#
# `SpecDirectoryDurations` ranks the same population — one run's areas — and cannot stand in for this
# one, for the reason its own comment gives one axis over: it ranks by WALL CLOCK, and its
# `coverage_label` is `SpecObservation.coverage_fraction(timed_count, recorded_count)`, which is TIMING
# coverage. An area of four hundred fast unannotated examples heads this list and appears nowhere near
# the head of that one. Concentration re-concentrates per quantity, not just per grain.
#
# == Why the list and its count are one object
#
# `SlowestExamples` states the rule and every drill-in repeats it: a caption is a claim ABOUT the list.
# "the 10 areas carrying the most unannotated examples, of 84 this run touched" is only true if both
# figures were counted off the same run's same rows the list was taken from — fetched separately they
# are figures that agree today with no structural reason to keep agreeing. This object derives no
# figure of its own: every number comes back from `SpecObservation.unannotated_directories_in`, one
# grouped aggregate, one round trip, constant in the size of the suite.
#
# == A ZERO-DEBT AREA IS A ROW, NOT AN OMISSION, and that is a decision rather than a leak
#
# The read groups the run's WHOLE population and applies `status = 'unannotated'` inside the aggregate,
# so an area every one of whose examples is annotated comes back as a genuine `unannotated_count: 0`
# against its real `recorded_count`. It sorts last by construction, so on any run with more areas than
# the cap it is cut and never seen; on a small run it is listed, and listed is correct — "this area has
# no debt" is the state the metric exists to reach, and `UnannotatedExamples` makes the same argument
# for its own empty read. Suppressing those rows would also make `directory_count` describe a different
# population from the siblings' identically-named key, which is the one thing a disclosure may not do.
#
# == It presents, and does not judge
#
# `SpecDirectoryDurations` states the rule and this inherits it unchanged: the rows ship the OPERANDS —
# `unannotated_count` and the `recorded_count` it was counted against — and never the fraction. There is
# no `#coverage_label` here and no threshold anywhere on the Row. An area at 40/40 is a module nobody
# has annotated yet and equally a module of generated specs nobody intends to; nothing here decides
# which. The reading is the reader's, and the operands are what let them have one.
class UnannotatedDirectories
  def self.for(test_run, limit: SpecObservation::UNANNOTATED_DIRECTORIES_LIMIT)
    tuples = SpecObservation.unannotated_directories_in(test_run, limit: limit)
    rows = tuples.map do |path, unannotated, recorded, _directory_count|
      Row.new(path: path, unannotated_count: unannotated.to_i, recorded_count: recorded.to_i)
    end

    # Off any row, because the window carries the same total on all of them; `to_i` on the nil of an
    # empty read, where "no directories" is the honest count.
    #
    # BY INDEX, not by `.last` — `SpecDirectoryDurations` states the argument and it is the same tuple
    # discipline here: reading the end of the tuple is correct only for as long as the window function
    # happens to be the last expression plucked, and it would go on being correct SILENTLY, since a
    # recorded count served as a directory count renders a caption that is merely wrong rather than a
    # response that breaks. `fetch` raises where `.last` would guess.
    new(rows: rows, directory_count: tuples.first&.fetch(DIRECTORY_COUNT_INDEX).to_i)
  end

  # Where `COUNT(*) OVER ()` sits in one tuple of `SpecObservation.unannotated_directories_in`. Named
  # here, beside the only read of it, so the tuple shape is a stated contract between the two objects
  # rather than a positional habit.
  DIRECTORY_COUNT_INDEX = 3

  def initialize(rows:, directory_count:)
    @rows = rows
    @directory_count = directory_count
  end

  # The ranking, most unannotated examples first, ties broken by path. Never longer than the limit it
  # was built with.
  attr_reader :rows

  # How many areas the run touched IN TOTAL — the denominator `rows.size` is not. The list is capped,
  # so its own length answers "how many rows am I looking at" and nothing else, and a caption built on
  # it reads "the areas carrying this run's annotation debt" on a run that touched eighty: a truncated
  # list silently wearing the shape of a complete one. Counted in the same pass as the rows, so it
  # cannot describe a different row set from the one listed.
  #
  # EVERY area, not every area with debt — the same population the identically-named key on
  # `SpecDirectoryDurations` discloses. See the class comment on why a zero-debt area is a row here.
  attr_reader :directory_count

  # There are areas this run touched that the list does not show. The state a caption has to SAY rather
  # than leave a reader to infer from a list whose length happens to equal a limit they cannot see.
  def truncated? = directory_count > rows.size

  # Whether this run recorded per-example rows AT ALL — the question that decides whether the surface
  # has anything to say. A group exists here if and only if a row exists, so this is `rows` being
  # non-empty and needs no separate count: the aggregate cannot return an area the run wrote nothing
  # for, and cannot omit one it did.
  #
  # A run ingested before those rows existed, or one whose client sends no per-example detail, has no
  # per-area grain to disclose. `SpecDirectoryDurations` draws the same line for the same reason.
  def recorded? = rows.any?

  # One area's annotation debt, and the population it was counted against.
  #
  # No `#coverage_label`, no `#fraction`, no `#complete?`. Two of those would be one line and all three
  # would be plausible, which is the argument against shipping them — `UnannotatedExamples` refuses
  # `recorded?` and `truncated?` on exactly this reasoning: a predicate no surface calls is a claim this
  # object makes that nothing has ever checked. This rollup is API-only; the serializer ships the two
  # integers and nothing derived from them. Whoever builds the dashboard panel should add what it calls,
  # with the spec that runs it.
  Row = Struct.new(:path, :unannotated_count, :recorded_count, keyword_init: true)
end
