# frozen_string_literal: true

# Where ONE run's wall clock went, rolled up by code AREA — the immediate parent directory of the
# file that ran each example — together with the coverage the surface listing it has to state.
#
# The sibling of `SpecFileDurations` one rung up, and deliberately not a variant of it. That panel
# answers "which FILES the run spent its time in"; this one answers "which AREAS", and the second
# is not derivable from the first: a by-file top ten shows ten files, and a directory holding forty
# files at two seconds each is eighty seconds of the run with not one of its rows in that list.
# Concentration re-concentrates at every rung, which is why each rung is summed rather than read
# off the one below it.
#
# It is also not a shard rollup. `TestRun#shard_durations` answers "which CI partition ran long"
# and its own comment is explicit that **a shard is not a code area** — partitions are arbitrary
# with respect to directory structure. The two grains cannot stand in for each other.
#
# == Why the list and its captions are one object
#
# `SpecFileDurations` states the rule and it is the same rule here, unchanged by the grain: a
# caption is a claim ABOUT the list, so "8 of 20 examples in this area reported a timing" is only
# true if both figures were counted off the same run's same rows the total was summed over. This
# object derives no figure of its own — every number on the panel comes back from
# `SpecObservation.directory_durations_in`: one grouped aggregate, one round trip, constant in the
# size of the suite.
#
# == The denominator is the rows, not the suite size
#
# Deliberately not `TestRun#total_specs_count`, for the reason `SpecFileDurations` and
# `SpecObservation`'s class comment give: that figure is re-derived by SUM over `test_run_shards`,
# and `Ingest::ObservationRecorder#record` returns a row count *"not always `specs.size`"*, so the
# two can legitimately differ. There is no by-directory counter anywhere else to borrow in any
# case — the per-area denominator only exists in these rows.
#
# == What a partial area means, and why every row carries its own coverage
#
# `SUM` skips NULLs silently, and the argument is `SpecFileDurations`' one grain up, where it
# costs more: excluding untimed rows changes each surviving group's own population, and an area is
# a bigger population than a file. An area whose examples were half untimed reports a total
# covering half of it, and an area none of whose examples were timed reports SQL NULL. So each row
# states how many of its examples reported a timing, and a row with none of them renders "not
# reported" rather than a zero it did not measure — `SpecObservation.humanized_duration` is the one
# seam that decides that, at every grain.
#
# == The third figure: how many DISTINCT DESCRIPTIONS an area's examples carry
#
# The area-grain reading this panel exists to let a reader state — "this area carries 340 examples
# and 6 minutes of wall clock for what looks like ~40 distinct behaviors" — needs a third figure,
# and it is counted in the same grouped aggregate as the other two for the reason above: a caption
# is a claim ABOUT the list, and a density counted by a second read describes a population this list
# was not built from.
#
# `COUNT(DISTINCT name)` skips NULLs the way `SUM` skips them, and `name` is nullable, so the same
# argument applies to the same rows a second time — and inverted, it costs the most on this panel of
# anywhere on the page. An area whose producer sent no descriptions would report ZERO distinct
# behaviors against 340 examples, which is the most extreme over-coverage reading obtainable, made
# out of silence rather than measured. So the per-area count of NAMED rows rides back beside the
# distinct count, the density is stated over those rows only, the excluded rows are visible beside
# it, and an area with no named rows SAYS SO rather than ranking first. `RepeatedDescriptions` draws
# the same `recorded?` / `named?` / `any?` distinction one grain down.
#
# == It presents, and does not judge
#
# `RepeatedDescriptions` states the rule and the area grain inherits it unchanged: a description
# carried by several examples is evidence of repetition AND the ordinary shape of a table-driven
# loop or a shared example group. Nothing here decides which. No method on this object or its rows
# returns a redundancy verdict — the figures are operands for a reader, and there is no
# `#over_covered?` here to be tempted by.
class SpecDirectoryDurations
  def self.for(test_run, limit: SpecObservation::HEAVIEST_DIRECTORIES_LIMIT)
    tuples = SpecObservation.directory_durations_in(test_run, limit: limit)
    rows = tuples.map do |path, total, recorded, timed, distinct_names, named, _directory_count|
      Row.new(path: path, total_seconds: total, recorded_count: recorded.to_i, timed_count: timed.to_i,
              distinct_name_count: distinct_names.to_i, named_count: named.to_i)
    end

    # Off any row, because the window carries the same total on all of them; `to_i` on the nil of
    # an empty read, where "no directories" is the honest count.
    #
    # BY INDEX, not by `.last`. Reading the end of the tuple was correct only for as long as the
    # window function happened to be the last expression plucked, and it went on being correct
    # SILENTLY — a description count served as a directory count renders a caption that is merely
    # wrong rather than a page that breaks. `fetch` raises where `.last` would guess, so the next
    # column added to that read fails here loudly instead.
    new(rows: rows, directory_count: tuples.first&.fetch(DIRECTORY_COUNT_INDEX).to_i)
  end

  # Where `COUNT(*) OVER ()` sits in one tuple of `SpecObservation.directory_durations_in`. Named
  # here, beside the only read of it, so the tuple shape is a stated contract between the two
  # objects rather than a positional habit.
  DIRECTORY_COUNT_INDEX = 6

  def initialize(rows:, directory_count:)
    @rows = rows
    @directory_count = directory_count
  end

  # The rollup, heaviest first. Never longer than the limit it was built with.
  attr_reader :rows

  # How many directories the run touched IN TOTAL — the denominator `rows.size` is not. The list is
  # capped, so its own length answers "how many rows am I looking at" and nothing else, and a
  # caption built on it reads "the 10 areas the run spent the most wall clock in" on a run that
  # touched eighty: a truncated list silently wearing the shape of a complete one, which is the
  # reading this whole panel exists to refuse one grain down. Counted in the same pass as the
  # totals, so it cannot describe a different row set from the one listed.
  attr_reader :directory_count

  # There are areas this run touched that the list does not show. The state the caption has to SAY
  # rather than leave a reader to infer from a list whose length happens to equal a limit they
  # cannot see — the same reason `#complete?` exists one column over.
  def truncated? = directory_count > rows.size

  # Whether this run recorded per-example rows AT ALL — the question that decides whether the
  # surface has anything to say. A group exists here if and only if a row exists, so this is `rows`
  # being non-empty and needs no separate count: the aggregate cannot return an area the run wrote
  # nothing for, and cannot omit one it did.
  #
  # A run ingested before those rows existed, or one whose client sends no per-example detail, has
  # no per-area grain to disclose. The `recorded?` / `any_timed?` split is `SpecFileDurations`', and
  # `SlowestExamples`' before it: "this run reported no tests" and "this run reported no timings"
  # are different facts and the panel says them differently.
  def recorded? = rows.any?

  # At least one area has a total to rank. False for a run that recorded examples and timed none of
  # them — every group's SUM is NULL, so there is a list of areas but no ranking, and a column of
  # "not reported" under a heading that promises "heaviest first" would be a ranking of nothing.
  def any_timed? = rows.any?(&:timed?)

  # Every listed area reported a timing for every one of its examples — the state worth SAYING
  # rather than leaving a reader to compare each row's two figures to reach it.
  def complete? = recorded? && rows.all?(&:complete?)

  # At least one LISTED area has a description to count, so the distinct-description column has
  # something to state. Read off the listed head, exactly like `#complete?` and `#fully_named?`
  # beside it and for the same reason: it selects which sentence the caption prints about the rows a
  # reader can see, and the list is capped. A run whose only described area ranks below the cap is
  # false here and correctly so — what the caption may NOT then do is turn that into a sentence
  # about the run, which is a claim about rows this object cannot see.
  #
  # False for a producer that sends no `name` at all — `Ingest::ObservationRecorder`
  # writes it through `presence_of`, so such a run stores a nil on every row — and a column of zeroes
  # over that run is "nobody told us what these tests are called", never "every area here repeats
  # itself completely". The `recorded?` / `any_named?` / `fully_named?` split is
  # `RepeatedDescriptions`' `recorded?` / `named?` / `any?` at this grain.
  def any_named? = rows.any?(&:named?)

  # Every example of every listed area carried a description, so each distinct count was counted over
  # the whole of its area. Read off the LISTED head, exactly like `#complete?` beside it and for the
  # same reason: it selects which sentence the caption prints about the rows a reader can see.
  def fully_named? = recorded? && rows.none?(&:excluded_unnamed_rows?)

  # One directory's share of one run's wall clock, what that share was measured over, and how many
  # distinct descriptions the examples it was measured over carry.
  Row = Struct.new(:path, :total_seconds, :recorded_count, :timed_count, :distinct_name_count,
                   :named_count, keyword_init: true) do
    # This area has a measured total. False when every one of its examples went untimed, which is
    # SQL NULL out of the aggregate and stays nil all the way to the cell.
    def timed? = !total_seconds.nil?

    def complete? = timed_count == recorded_count

    # The total, rendered — through the same seam one example's duration and one file's total are
    # rendered through, so no two grains on this page can disagree about how a duration is spelled,
    # and an unmeasured area says "not reported" rather than "0.00s".
    def duration_label = SpecObservation.humanized_duration(total_seconds)

    # How much of the area this total covers — through the same seam every coverage fraction on this
    # page is spelled through, so a complete area is visibly complete rather than merely unannotated,
    # and no two grains can disagree about how the fraction is worded.
    def coverage_label = SpecObservation.coverage_fraction(timed_count, recorded_count)

    # At least one of this area's examples carried a description, so `COUNT(DISTINCT name)` had
    # something to count. The predicate the distinct column is stated BEHIND, never a fact folded
    # into the number: `COUNT(DISTINCT name)` skips NULLs, so an area whose every row is unnamed
    # comes back as a flat zero that is indistinguishable, AS A NUMBER, from an area whose 340
    # examples genuinely share no description — and the second reading is the strongest
    # over-coverage claim this page can make. Zero distinct behaviors is never printed for silence.
    def named? = named_count.positive?

    # How many of this area's rows the distinct count could NOT see. The complement over the area's
    # own population, so the two figures sum to the row rather than to two different reads.
    def unnamed_count = recorded_count - named_count

    # Rows were excluded from the distinct count for carrying no description. Asked so the surface
    # can omit the clause entirely on the ordinary area: "0 examples carried no description" is a
    # sentence about arithmetic rather than about this area, and `RepeatedDescriptions` renders its
    # exclusion sentence under the same condition for the same reason.
    def excluded_unnamed_rows? = unnamed_count.positive?

    # How many distinct descriptions this area's NAMED examples carry, always as a fraction over the
    # rows the count was taken across and never as a bare count. "40" alone reads as forty of the
    # area, and the area is `recorded_count`, which is the one denominator this figure was NOT
    # counted over — the excluded rows are stated separately by `#unnamed_count`.
    #
    # An area with nothing named says so instead. Not "0 of 0", which is a fraction wearing the
    # shape of a measurement, and not "0", which is the invented maximal-redundancy reading this
    # whole method exists to refuse.
    def distinct_description_label
      return "no descriptions" unless named?

      "#{distinct_name_count} of #{named_count}"
    end

    # No `#over_covered?`, and no threshold anywhere on this Row. The ratio of distinct descriptions
    # to examples is equally the signature of a suite testing one behavior forty ways and of a
    # table-driven loop or a shared example group doing exactly what it should — `RepeatedDescriptions`
    # states the rule one grain down and refuses a `#redundant?` for the same reason. What is shipped
    # here are the operands; the reading is the reader's.
  end
end
