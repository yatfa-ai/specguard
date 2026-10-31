# frozen_string_literal: true

# WHERE ONE AREA'S ANNOTATION DEBT SITS, rolled up by spec file — the rung between
# `UnannotatedDirectories` above and `UnannotatedExamples` below, and the one the worklist's own
# cap kept out of reach.
#
# `UnannotatedDirectories` names the areas the debt is concentrated in, and each one is a
# `?spec_directory=` away from `UnannotatedExamples`' worklist. What that ask could not answer was
# which of the picked area's files hold the work: the worklist is a capped hundred ordered
# file-navigably, so a file whose rows fall past the hundredth was named nowhere and reachable
# only by a reader who already knew its path. This object names the files, and every row is a
# `?spec_file=` away from a worklist that starts at that file's own rows — the same ladder the
# duration drill-ins built (`SpecDirectoryDurations` → `SpecDirectoryFiles` → `SpecFileExamples`),
# closed on the debt axis where SPGD-622 closed it one rung up.
#
# == Why the list and its count are one object
#
# `UnannotatedDirectories` states the rule and every drill-in on this endpoint repeats it: a
# caption is a claim ABOUT the list. "the 10 files in this area carrying the most unannotated
# tests, of 17 there carrying any" is only true if both figures were counted off the same run's
# same rows the list was taken from — fetched separately they are figures that agree today with no
# structural reason to keep agreeing. This object derives no figure of its own: every number comes
# back from `SpecObservation.unannotated_files_in`, one grouped aggregate, one round trip.
#
# == A file with no debt is NOT a row, where an area with none IS
#
# The sibling's class comment calls its zero-debt row a decision rather than a leak, and this
# object makes the opposite call on purpose. That ranking surveys where a run's debt stands, so
# "this area has none" is a fact about the survey and `directory_count` covers the run's every
# area. This is a worklist of work within one area: a file every one of whose examples carries an
# `@intent` has nothing on it to annotate, so it is omitted and `file_count` — read off a window
# evaluated after the read's `HAVING` — counts the files CARRYING DEBT, not the area's every file.
# A reader who wants that inventory has it one panel over, in "Spec files in this directory".
# `SpecObservation.unannotated_files_in` holds the argument in full.
#
# == It presents, and does not judge
#
# The rule `UnannotatedDirectories` states twice and this inherits unchanged: the rows ship the
# OPERANDS — `unannotated_count` and the `recorded_count` it was counted against — and never the
# fraction. There is no `#coverage_label` and no threshold anywhere on the Row. A file at 40/40 is
# a file nobody has annotated yet and equally a file of generated specs nobody intends to; nothing
# here decides which. The reading is the reader's, and the operands are what let them have one.
#
# == The three readings ride along, even where a column does not show them
#
# Every Row carries `authored_count`, `derived_count` and `unreadable_count` —
# `SpecObservation::READINGS` over this file's examples, summed to `recorded_count` — where it
# could have carried only the two a caption spends. It carries all three because the read plucks
# them anyway, on the shared-{READING_COUNTS} rule that keeps a file's readings and the area's
# readings one rung up from ever disagreeing about what a reading is; a tuple position read by
# nothing would be exactly the kind of silent renumbering `UnannotatedDirectories::DIRECTORY_
# COUNT_INDEX` exists to prevent, and a Row that dropped a counted column would invite the next
# caller to recompute it.
class UnannotatedFiles
  # `spec_directory` is positional — the ask IS the pick here, exactly as `SpecDirectoryFiles`'s
  # `path` is one rung over. It is held for the link each row renders (`drill_down_path` composes
  # file and area on one URL) and for the caption that names its subject.
  def self.for(test_run, spec_directory, limit: SpecObservation::UNANNOTATED_FILES_LIMIT)
    tuples = SpecObservation.unannotated_files_in(test_run, spec_directory: spec_directory,
                                                             limit: limit)
    rows = tuples.map do |path, unannotated, recorded, _file_count, authored, derived, unreadable|
      Row.new(path: path, unannotated_count: unannotated.to_i, recorded_count: recorded.to_i,
              authored_count: authored.to_i, derived_count: derived.to_i,
              unreadable_count: unreadable.to_i)
    end

    # Off any row, because the window carries the same total on all of them; `to_i` on the nil of
    # an empty read, where "no files carrying debt" is the honest count.
    #
    # BY INDEX, not by `.last` — the discipline `UnannotatedDirectories.for` states in full: the
    # window is not the last expression plucked but index 3 of seven, and reading the end of the
    # tuple is correct only for as long as the window happens to sit there, which it would stop
    # doing SILENTLY. `fetch` raises where `.last` would guess.
    new(rows: rows, spec_directory: spec_directory,
        file_count: tuples.first&.fetch(FILE_COUNT_INDEX).to_i)
  end

  # Where `COUNT(*) OVER ()` sits in one tuple of `SpecObservation.unannotated_files_in`. Named
  # here, beside the only read of it, so the tuple shape is a stated contract between the two
  # objects rather than a positional habit — and at index 3, where the sibling's window count
  # sits on its own tuple, because the two shapes are one tuple one grain down.
  FILE_COUNT_INDEX = 3

  def initialize(rows:, spec_directory:, file_count:)
    @rows = rows
    @spec_directory = spec_directory
    @file_count = file_count
  end

  # The area this list is of, as it was asked for. Held even when nothing came back, because the
  # empty state has to name its subject.
  attr_reader :spec_directory

  # The ranking, most UNREADABLE examples first, then most unannotated, ties broken by path — see
  # `SpecObservation.unannotated_files_in`, where the order is argued. Never longer than the limit
  # it was built with, and never longer than `file_count`.
  attr_reader :rows

  # How many spec files of this area CARRY DEBT — the denominator `rows.size` is not, and also
  # not the area's every file, which is what `SpecDirectoryFiles#file_count` counts over the same
  # grain. Counted after the read's `HAVING`, in the same pass as the rows, so it cannot describe
  # a different row set from the one listed.
  attr_reader :file_count

  # Whether the ranking was CUT — the area holds `file_count` files carrying debt and this list
  # holds `rows.size` of them. The caption's whole job, on the argument
  # `UnannotatedDirectories#truncated?` states: a truncated list silently wearing the shape of a
  # complete one is the one thing a disclosure may not do.
  #
  # Both operands come back from the one grouped read that built the rows, so this cannot
  # describe a different population from the list it captions.
  def truncated? = file_count > rows.size

  # One spec file's readings, and the population they were counted against —
  # `UnannotatedDirectories::Row` one grain down, same fields, same rules. `unannotated_count` is
  # kept as its own counted column rather than recomputed as `derived + unreadable`, on the same
  # reason the read names: it is the figure that reconciles against `total_specs -
  # annotated_specs`, and a caller must be able to read it without having to know that identity.
  #
  # No `#coverage_label`, no `#fraction`, no `#complete?` — the Row ships OPERANDS and the reading
  # is the reader's, which is the class comment's rule.
  Row = Struct.new(:path, :unannotated_count, :recorded_count, :authored_count, :derived_count,
                   :unreadable_count, keyword_init: true)
end
