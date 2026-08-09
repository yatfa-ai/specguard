# frozen_string_literal: true

# Which DESCRIPTIONS more than one example of ONE run recorded, ranked by the wall clock those
# examples cost between them — together with everything a surface listing them has to state before
# it is allowed to call any of it redundancy.
#
# The first object on this page whose grain is the description rather than the file, the area or the
# example. That grain was reachable nowhere: `GROUP BY name` exists twice in this application and
# both are narrowed to failures (see `SpecObservation.repeated_descriptions_in`), so on a green
# suite — the normal case — nothing grouped examples by description at all. The one place the
# measurement did exist, `UnstableTests::Row#shared_description?`, computes it in order to REJECT
# those groups as matching-rule false positives. Here they are the subject.
#
# == It presents, and does not judge
#
# A description carried by several examples of one run is evidence of repetition AND the ordinary
# shape of a table-driven loop or a shared example group — `SpecObservation`'s own comment on
# `UNSTABLE_COMPOSITION` names all three causes in one sentence. Nothing in these rows decides
# which, and nothing here tries: the ranking says what it cost and where it lives, the surface says
# the reading is for review, and no method on this object returns a verdict. That is
# `SpecObservation#outcome_label`'s echo-don't-judge rule at this grain, and it is why there is no
# `#redundant?` here to be tempted by.
#
# == Why the list and its captions are one object
#
# `SpecFileDurations` states the rule and it is unchanged by the grain: a caption is a claim ABOUT
# the list, so "these groups cover 40 of 63 examples, 31 of them timed" is only true if every figure
# in it was counted off the same run's same rows the totals were summed over. This object derives no
# figure of its own — every number on the panel comes back from `.repeated_descriptions_in`, one
# grouped aggregate, plus `.description_presence_in` for the two figures that read must exclude
# before it can group (see below).
#
# == Ranked by cost, never by group size
#
# An eight-example group costing two seconds matters less than a three-example group costing ninety.
# The question is redundancy WEIGHED AGAINST duration, so the ordering is the summed wall clock the
# duration rollups on this page already rank by, `NULLS LAST` included — a group nobody timed must
# not head a list about what repetition costs.
#
# == The two silences, and why one of them needs a second read
#
# `SUM` skips NULLs silently and `duration_seconds` is nullable by design, so every group states how
# many of its own examples reported a timing and the panel states the same figure over the whole
# repeated population. `SpecDirectoryDurations` argues at length why each row carries its own.
#
# The other silence is the rows that carry no description. They cannot be grouped — a null is not a
# description, and pooling every unnamed example of the run would invent the largest repetition on
# the page out of rows that share nothing — so they are excluded in SQL, which means no window over
# that read can see them. `#unnamed_row_count` is the second round trip that answers for them, and
# `#recorded_count` rides along with it because an empty ranking over a run that wrote NO rows and
# an empty ranking over a suite whose every description is unique are the same empty list, and only
# the first of them is silence.
class RepeatedDescriptions
  def self.for(test_run, limit: SpecObservation::REPEATED_DESCRIPTIONS_LIMIT)
    tuples = SpecObservation.repeated_descriptions_in(test_run, limit: limit)
    rows = tuples.map do |name, total, recorded, timed, file_paths, *|
      Row.new(name: name, total_seconds: total, recorded_count: recorded.to_i,
              timed_count: timed.to_i, file_paths: file_paths)
    end

    # Off any row, because the three window totals ride back the same on all of them; `to_i` over
    # the nil of an empty read, where "no repeated descriptions" is the honest count.
    window = tuples.first&.last(3).to_a
    presence = SpecObservation.description_presence_in(test_run)

    new(rows: rows, group_count: window[0].to_i,
        repeated_recorded_count: window[1].to_i, repeated_timed_count: window[2].to_i,
        recorded_count: presence[:recorded_count], unnamed_row_count: presence[:unnamed_count])
  end

  def initialize(rows:, group_count:, repeated_recorded_count:, repeated_timed_count:,
                 recorded_count:, unnamed_row_count:)
    @rows = rows
    @group_count = group_count
    @repeated_recorded_count = repeated_recorded_count
    @repeated_timed_count = repeated_timed_count
    @recorded_count = recorded_count
    @unnamed_row_count = unnamed_row_count
  end

  # The ranking, costliest first. Never longer than the limit it was built with.
  attr_reader :rows

  # How many descriptions of this run are carried by more than one example IN TOTAL — the
  # denominator `rows.size` is not. The list is capped, so its own length answers "how many rows am
  # I looking at" and nothing else, and a caption built on it reads "the 10 costliest repeated
  # descriptions" on a run that has eighty: a truncated list silently wearing the shape of a
  # complete one. Counted in the same pass as the totals, so it cannot describe a different row set
  # from the one listed.
  attr_reader :group_count

  # How many EXAMPLES those groups cover between them, and how many of those reported a timing —
  # both over every repeated description the run holds rather than over the ten that fit, because
  # on a truncated run those are different populations and the caption is about the finding rather
  # than about the page.
  attr_reader :repeated_recorded_count, :repeated_timed_count

  # How many rows this run recorded at all. Not a figure the ranking needs — it is the figure that
  # decides whether an EMPTY ranking means anything. See the class comment: a run that wrote no
  # per-example rows and a suite whose every description is unique produce the identical empty list,
  # and printing "no repeated descriptions" over the first is Vacuous Green.
  attr_reader :recorded_count

  # How many of those rows carried no description and were therefore excluded before the grouping.
  # Stated rather than dropped: a panel that examined nine tenths of a run and said nothing about
  # the other tenth is a claim about a population it did not read. `SpecObservation.unnamed_row_count_in`
  # refuses the same silence one panel over, for a window instead of a run.
  attr_reader :unnamed_row_count

  # Whether this run recorded per-example rows AT ALL — the question that decides whether the
  # surface has anything to say, and the one an empty `rows` cannot answer here. A run ingested
  # before those rows existed, or one whose client sends no per-example detail, has no descriptions
  # to compare and must not be told it has no repetition.
  #
  # The `recorded?` / `named?` / `any?` split is the `recorded?` / `comparable?` / `any?` split
  # `UnstableTests` draws, at this grain: "this run reported no tests", "this run reported no
  # descriptions" and "nothing was repeated" are three different facts and the panel says them
  # differently.
  def recorded? = recorded_count.positive?

  # At least one row carried a description, so the grouping had something to group. False for a
  # producer that sends no `name` at all — `Ingest::ObservationRecorder#attributes` writes it
  # through `presence_of`, so such a run stores a nil on every row — and an empty ranking over that
  # run is "nobody told us what these tests are called", never "every test here is unique".
  def named? = named_row_count.positive?

  # How many rows the grouping could see. The complement of the excluded rows, over the run's own
  # population, so the two figures in the caption sum to the run rather than to two different reads.
  def named_row_count = recorded_count - unnamed_row_count

  # Anything was repeated at all. The honest zero, and reachable only behind `named?`.
  def any? = rows.any?

  # There are repeated descriptions this run holds that the list does not show — the state the
  # caption has to SAY rather than leave a reader to infer from a list whose length happens to equal
  # a limit they cannot see.
  def truncated? = group_count > rows.size

  # Rows were excluded for carrying no description. Asked so the caption can omit the clause
  # entirely on the ordinary run: "0 examples carried no description" is a sentence about arithmetic
  # rather than about this run, and `UnstableTests`' exclusion sentence is rendered under the same
  # condition for the same reason.
  def excluded_unnamed_rows? = unnamed_row_count.positive?

  # At least one group has a total to rank. False for a run that recorded examples and timed none of
  # them — every group's SUM is NULL, so there is a list of repetitions but no ranking, and a column
  # of "not reported" under a heading promising "costliest first" would be a ranking of nothing.
  def any_timed? = rows.any?(&:timed?)

  # Every example under every repeated description of this run reported a timing — over the whole
  # repeated population and not over the listed head, so a truncated run cannot read as complete on
  # the strength of the ten rows that fit. The state worth SAYING rather than leaving a reader to
  # compare two figures to reach.
  def complete? = any? && repeated_timed_count == repeated_recorded_count

  # What the summed wall clock on this panel was measured over, always as a fraction and never as a
  # bare count — the denominator is the point, for the reason every coverage column on this page
  # gives.
  def coverage_label = "#{repeated_timed_count} of #{repeated_recorded_count}"

  # One description, the examples of one run that share it, and what they cost between them.
  Row = Struct.new(:name, :total_seconds, :recorded_count, :timed_count, :file_paths,
                   keyword_init: true) do
    # This group has a measured total. False when every one of its examples went untimed, which is
    # SQL NULL out of the aggregate and stays nil all the way to the cell.
    def timed? = !total_seconds.nil?

    def complete? = timed_count == recorded_count

    # The total, rendered — through the same seam one example's duration and one area's total are
    # rendered through, so no two grains on this page can disagree about how a duration is spelled,
    # and a group nobody timed says "not reported" rather than "0.00s".
    def duration_label = SpecObservation.humanized_duration(total_seconds)

    # How much of the group this total covers. Always the fraction: "8" in a column of "6 of 8"
    # reads as eight of something unstated, and a fully timed group has to be visibly complete
    # rather than merely unremarked.
    def coverage_label = "#{timed_count} of #{recorded_count}"

    # The spec files these examples ran in. `Array()` because the aggregate is `ARRAY_AGG(…)
    # FILTER (…)`, which is SQL NULL rather than an empty array for a group with nothing to collect
    # — a nil the caller would otherwise have to know about at every call site. Sorted, so two
    # groups spanning the same files read the same way.
    def files_seen = Array(file_paths).sort

    # The examples sharing this description ran in more than one spec file. Worth SAYING, and worth
    # saying without a verdict attached: one description across several files is the shape a shared
    # example group included by several suites makes, and it is equally the shape of two teams
    # writing the same test twice. Which of them it is does not follow from these rows.
    def multi_file? = files_seen.size > 1
  end
end
