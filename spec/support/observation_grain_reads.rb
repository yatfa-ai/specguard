# Which GRAIN each read of `spec_observations` belongs to, for the request specs that bound what
# `GET /api/v1/repository` asks of that table.
#
# HERE RATHER THAN IN THE FILE THAT FIRST NEEDED IT, and for the reason `QueryCapture` gives one
# level down: the same classification is now needed by two request specs — the endpoint's own
# contract file and the flakiness file beside it — and RSpec scopes a `def` to its own example
# group, so a sibling's helper is invisible and the only way to reuse it is to copy it. Two copies
# of a partition are two lists free to drift on which read belongs to which grain, and a guard that
# counts one query more or less than its sibling is worse than no guard, because it still reports a
# number. So the partition is DEFINED ONCE, here, exactly as the subscriber it is built on is.
#
# EVERY GRAIN IS MATCHED POSITIVELY, on SQL only its own read can produce, and none is defined as
# "the reads that are not the others". A residual definition silently ADOPTS any further read of
# this table — an `exists?` gate, a preload, an N+1 — into whichever grain owns the leftovers, and
# the block that owns them then reports a number for work it did not do. Matched positively, an
# unclassified read belongs to no list and is caught by a total instead, which is the guard that can
# actually name it.
#
# The endpoint reads `spec_observations` once per single-run grain it serves — once for the by-file
# rollup, once for the by-area one, TWICE for the per-example ranking (a capped scan and a coverage
# aggregate), TWICE for the by-description one (a grouped aggregate and the presence count it cannot
# window over) — and UP TO FOUR MORE for the cross-run flakiness block, which is the only grain here
# whose count depends on state rather than only on shape. Each block that uses these bounds its OWN
# grain rather than the table, because a bare total cannot tell "one aggregate per grain" from "one
# grain reading twice", and it has to be rebaselined by hand every time a grain is added — the
# silent rebaseline `queries_against` was chosen over `baseline + 1` to avoid.
#
# == Why some grains are several patterns rather than one
#
# The per-example grain is TWO patterns because it is two different statements —
# `SpecObservation.slowest_in`'s capped backward scan and `.coverage_in`'s FILTER aggregate — and
# collapsing them into one loose pattern would let either stop being issued without a red example.
# The by-description grain is TWO for the same reason, and its pair is not interchangeable: the
# grouped read EXCLUDES null names in its WHERE clause, so no window over it could have counted the
# rows it dropped, and `.description_presence_in` is the second round trip that answers for them.
# The flakiness grain is FOUR for the same reason, one per read of `UnstableTests.for`, which is
# also what lets a block assert "one read, then it stopped" on an incomparable window: the four are
# ordered here as that method issues them.
#
# == The one pattern that had to be TIGHTENED, and why
#
# The per-example coverage read was originally matched on `COUNT(*) FILTER (WHERE outcome =
# 'failed')`. That string is NOT unique to it: `SpecObservation::UNSTABLE_COMPOSITION` selects the
# same expression, so the flakiness composition read would be classified into the per-example grain
# and counted twice — once in each list — the moment a branch-scoped comparable window was
# exercised. It is matched on `'pending'` instead, which only `COVERAGE_COUNTS` selects. The
# tightening is a correction to a pattern that was unambiguous when it was written and stopped being
# so when a second reader of this table learned to count failures; the guard against it recurring is
# the sum-of-grains-equals-the-total assertion, which is what makes a double-classified read show up
# as a total that is smaller than its parts.
#
# The by-description patterns were chosen under that lesson rather than after it. `GROUP BY
# "spec_observations"."name"` is the obvious match and is the WRONG one: three reads on this table
# group on `name` — `.unstable_candidates_in`, `.outcome_composition_in` and
# `.repeated_descriptions_in` — so it would adopt two of the flakiness grain's four the moment a
# branch-scoped window was exercised. `HAVING (COUNT(*) > 1)` is issued by the third alone. Its
# partner is matched on `COUNT(*) FILTER (WHERE name IS NULL)`, which only `.description_presence_in`
# selects: the flakiness grain's own unnamed-row read is a `.count` over `where(name: nil)` and
# spells that condition as the QUOTED-COLUMN form the fourth pattern below matches, so the two
# cannot collide.
module ObservationGrainReads
  # `queries_against` counts cached repeats and TRANSACTIONs, unlike `executed_sql` — see
  # `QueryCapture`, where the two rules and the difference between them are stated in full.
  def observation_reads(&) = queries_against("spec_observations", &)

  # `[area, file, example, description, flakiness]` — the five grains, each an array of the
  # statements matched. The single-run grains come first and the cross-run one last, in the order
  # `serialized_latest_run` serves them, so a destructuring caller reads the endpoint's own shape.
  def observation_reads_by_grain(&)
    reads = observation_reads(&)
    [reads.grep(/GROUP BY COALESCE\(substring\(spec_file_path/),
     reads.grep(/GROUP BY "spec_observations"\."spec_file_path"/),
     reads.grep(/ORDER BY "spec_observations"\."duration_seconds" DESC/) +
       reads.grep(/COUNT\(\*\) FILTER \(WHERE outcome = 'pending'\)/),
     reads.grep(/HAVING \(COUNT\(\*\) > 1\)/) +
       reads.grep(/COUNT\(\*\) FILTER \(WHERE name IS NULL\)/),
     flakiness_grain_patterns.flat_map { |pattern| reads.grep(pattern) }]
  end

  # `UnstableTests.for`'s four reads, in the order it issues them: the gating outcome-reporting
  # probe, the capped candidate list, the composition over those candidates, and the unnamed-row
  # exclusion count. Exposed so a block can assert WHICH of the four fired — an incomparable window
  # is "the first one and no other", which a bare count of one cannot say.
  #
  # `"name" IS NULL` does not match the candidate read's `"name" IS NOT NULL`, and
  # `ARRAY_AGG(DISTINCT outcome)` is selected by no other read this endpoint issues.
  def flakiness_grain_patterns
    [/FILTER \(WHERE probe\.has_rows\)/,
     /ORDER BY COUNT\(\*\) ASC, name ASC/,
     /ARRAY_AGG\(DISTINCT outcome\)/,
     /"spec_observations"\."name" IS NULL/]
  end

  def area_grain_reads(&) = observation_reads_by_grain(&)[0]
  def file_grain_reads(&) = observation_reads_by_grain(&)[1]
  def example_grain_reads(&) = observation_reads_by_grain(&)[2]
  def description_grain_reads(&) = observation_reads_by_grain(&)[3]
  def flakiness_grain_reads(&) = observation_reads_by_grain(&)[4]
end

RSpec.configure do |config|
  config.include ObservationGrainReads
end
