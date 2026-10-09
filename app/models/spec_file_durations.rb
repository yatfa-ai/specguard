# frozen_string_literal: true

# Where ONE run's wall clock went, rolled up by spec file — together with the coverage the surface
# listing it has to state.
#
# The sibling of `SlowestExamples`, and deliberately not a variant of it. That panel answers
# "which individual tests are slow"; this one answers "which FILES the run spent its time in",
# and at the roadmap's 20,000-example design point the second is not derivable from the first: a
# top-ten ranked by individual cost shows 0.05% of the suite, and a file holding 400 examples at
# 50ms each is twenty seconds of the run that is structurally incapable of appearing in it.
#
# == Why the list and its captions are one object
#
# `SlowestExamples` states the rule and it is the same rule here: a caption is a claim ABOUT the
# list. "4 of 12 examples in this file reported a timing" is only true if those two figures were
# counted off the same run's same rows the total was summed over. Fetched separately they are two
# things that agree today with no structural reason to keep agreeing.
#
# It derives no figure of its own. Every number on the panel — each file's total, what that total
# was summed over, and how many files the run touched in all — comes back from
# `SpecObservation.file_durations_in`: one grouped aggregate, one round trip, constant in the
# size of the suite.
#
# == The denominator is the rows, not the suite size
#
# Deliberately not `TestRun#total_specs_count`, for the reason `SlowestExamples` gives and
# `SpecObservation`'s class comment states first: that figure is re-derived by SUM over
# `test_run_shards`, and `Ingest::ObservationRecorder#record` returns a row count *"not always
# `specs.size`"*, so the two can legitimately differ. There is no by-file counter anywhere else to
# borrow in any case — the per-file denominator only exists in these rows.
#
# == What a partial file means, and why every row carries its own coverage
#
# `SUM` skips NULLs silently. Excluding untimed rows is not an option at this grain the way it is
# for a ranking of examples, because exclusion changes each surviving group's own population: a
# file whose examples were half untimed reports a total covering half of it, and a file none of
# whose examples were timed reports SQL NULL. So each row states how many of its examples reported
# a timing, and a row with none of them renders "not reported" rather than a zero it did not
# measure — `SpecObservation.humanized_duration` is the one seam that decides that, at both grains.
class SpecFileDurations
  def self.for(test_run, limit: SpecObservation::HEAVIEST_FILES_LIMIT)
    tuples = SpecObservation.file_durations_in(test_run, limit: limit)
    rows = tuples.map do |path, total, recorded, timed, _file_count, *layers|
      # The five trailing operands ride in `SpecObservation::DECLARED_LAYER_KEYS` order — the closed
      # layer enum, then undeclared — and are zipped by that list, never by position at the call site.
      layer_counts = SpecObservation::DECLARED_LAYER_KEYS.zip(layers.map(&:to_i)).to_h
      Row.new(path: path, total_seconds: total, recorded_count: recorded.to_i, timed_count: timed.to_i,
              layer_counts: layer_counts)
    end

    # Off any row, because the window carries the same total on all of them; `to_i` on the nil of
    # an empty read, where "no files" is the honest count.
    #
    # BY INDEX, not by `.last`: the declared-layer operands ride AFTER `COUNT(*) OVER ()`, so the end
    # of the tuple is a layer count now, and reading it would serve a layer count as a file count
    # SILENTLY. `fetch` raises where `.last` would guess.
    new(rows: rows, file_count: tuples.first&.fetch(FILE_COUNT_INDEX).to_i)
  end

  # Where `COUNT(*) OVER ()` sits in one tuple of `SpecObservation.file_durations_in`. Named here,
  # beside the only read of it, so the tuple shape is a stated contract between the two objects.
  FILE_COUNT_INDEX = 4

  def initialize(rows:, file_count:)
    @rows = rows
    @file_count = file_count
  end

  # The rollup, heaviest first. Never longer than the limit it was built with.
  attr_reader :rows

  # How many files the run touched IN TOTAL — the denominator `rows.size` is not. The list is
  # capped, so its own length answers "how many rows am I looking at" and nothing else, and a
  # caption built on it reads "the 10 files the run spent the most wall clock in" on a run that
  # touched three hundred: a truncated list silently wearing the shape of a complete one, which is
  # the reading this whole panel exists to refuse one grain down. Counted in the same pass as the
  # totals, so it cannot describe a different row set from the one listed.
  attr_reader :file_count

  # There are files this run touched that the list does not show. The state the caption has to
  # SAY rather than leave a reader to infer from a list whose length happens to equal a limit they
  # cannot see — the same reason `#complete?` exists one column over.
  def truncated? = file_count > rows.size

  # Whether this run recorded per-example rows AT ALL — the question that decides whether the
  # surface has anything to say. A group exists here if and only if a row exists, so this is `rows`
  # being non-empty and needs no separate count: the aggregate cannot return a file the run wrote
  # nothing for, and cannot omit one it did.
  #
  # A run ingested before those rows existed, or one whose client sends no per-example detail, has
  # no per-file grain to disclose. The `recorded?` / `any_timed?` split is `SlowestExamples`'s
  # `recorded?` / `any?` split: "this run reported no tests" and "this run reported no timings" are
  # different facts and the panel says them differently.
  def recorded? = rows.any?

  # At least one file has a total to rank. False for a run that recorded examples and timed none of
  # them — every group's SUM is NULL, so there is a list of files but no ranking, and a column of
  # "not reported" under a heading that promises "heaviest first" would be a ranking of nothing.
  def any_timed? = rows.any?(&:timed?)

  # Every listed file reported a timing for every one of its examples — the state worth SAYING
  # rather than leaving a reader to compare each row's two figures to reach it.
  def complete? = recorded? && rows.all?(&:complete?)

  # One spec file's share of one run's wall clock, and what that share was measured over.
  Row = Struct.new(:path, :total_seconds, :recorded_count, :timed_count, :layer_counts, keyword_init: true) do
    # How many of this file's examples DECLARED each layer, plus how many declared none — operands,
    # never a label or verdict. `{unit:, integration:, request:, system:, undeclared:}`, a measured
    # zero where nothing declared that layer (never nil), summing to `recorded_count`. Counted off the
    # stored `intent_layer` only: no path inference. `undeclared` is `intent_layer IS NULL` and nothing
    # more — "no @intent declared a layer", not "SpecGuard cannot read this test".

    # Spelled for the panel, through the one spelling the directory rows and drill-ins use.
    def layer_counts_label = SpecDirectoryDurations.layer_counts_label(layer_counts)

    # This file has a measured total. False when every one of its examples went untimed, which is
    # SQL NULL out of the aggregate and stays nil all the way to the cell.
    def timed? = !total_seconds.nil?

    def complete? = timed_count == recorded_count

    # The total, rendered — through the same seam one example's duration is rendered through, so a
    # file total and an example measurement cannot disagree about how a duration is spelled, and an
    # unmeasured file says "not reported" rather than "0.00s".
    def duration_label = SpecObservation.humanized_duration(total_seconds)

    # How much of the file this total covers — through the same seam the other single-sided coverage
    # fractions are spelled through, so a complete file is visibly complete rather than merely
    # unannotated, and this row cannot disagree with the file panel drilled out of it about how the
    # fraction is worded.
    def coverage_label = SpecObservation.coverage_fraction(timed_count, recorded_count)
  end
end
