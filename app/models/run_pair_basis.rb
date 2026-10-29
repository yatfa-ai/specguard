# frozen_string_literal: true

# THE ONE PHRASE for what a run-pair figure is measured against (SPGD-1981).
#
# Every sentence on the console that names the comparand of a run-over-run figure used to spell
# exactly one thing: "the previous run on this branch". That was true of every figure the page
# could draw, because `Repository#previous_test_run_on_branch` is the only baseline any of them
# read. `?compare_to=` adds a second, EXPLICIT baseline — the newest run on a named branch at or
# before the run being read — and under that ask the old sentence is not vague, it is false: a
# reader told a delta is "since the previous run on this branch" has been told the wrong
# measurement, not a vaguer one, which is the register `SpecDirectoryWindowGrowth::Row` already
# set when the window panels hit the same falsehood.
#
# So the phrase is computed HERE, once, from the one fact that decides it — the branch the
# comparison was explicitly asked for, or nil for the default — and every surface that names the
# comparand asks this module rather than re-deriving it:
#
# * the run-pair growth presenters (`SpecDirectoryGrowth`, `SpecDirectoryRuntimeGrowth`,
#   `SpecDirectoryFileGrowth`), whose `change_reading` sentences are built in the model, take the
#   branch at construction and read the noun here;
# * the view helpers (`ApplicationHelper`'s three change readings,
#   `RepositoriesHelper#run_pair_basis_noun`) ask it with the `@comparison_baseline_branch` the
#   dashboard publishes.
#
# The noun is deliberately SHORT — "the newest run on main", not the full "…, <sha> linked,
# <age> ago — a different branch, asked for" the basis note renders. An aria-label travels with
# one cell; the full naming, the ask disclosure and the linked sha belong to the basis notes that
# sit beside the figures, which compose the longer sentence around this same noun. A second
# full-length builder here would be a second place the ask disclosure could drift from the note.
#
# `nil` means the default, and the default keeps the sentence the page has always made — byte for
# byte, because every caller hands nil when no `?compare_to=` was asked or honoured.
module RunPairBasis
  SAME_BRANCH = "the previous run on this branch"

  # The comparand as a noun phrase, embeddable mid-sentence: "unchanged since X", "N tests fewer
  # than X", "an area X did not record", "Since <sha> on main". A nil ask is the same-branch
  # sentence, spelled exactly as every site spelled it before this module existed.
  def self.noun(baseline_branch)
    baseline_branch ? "the newest run on #{baseline_branch}" : SAME_BRANCH
  end

  # The SHORT form two row states use, where the long form would not scan: "an area the previous
  # run did not record" keeps its bare comparand when no ask is active, exactly as it has always
  # read, and only an explicit ask names the branch there. Under an ask both forms coincide —
  # "the newest run on main" is both the long and the short answer — which is why the split is
  # invisible until it is needed.
  def self.short_noun(baseline_branch)
    baseline_branch ? noun(baseline_branch) : "the previous run"
  end
end
