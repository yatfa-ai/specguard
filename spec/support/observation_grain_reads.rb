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
# window over) — and, for its two CROSS-RUN blocks, UP TO FOUR MORE for flakiness and UP TO ONE MORE
# for growth-by-area, which are not the only grains here whose count depends on state rather than
# only on shape: the TWO drill-ins are ONE MORE EACH, and they are the grains whose count depends on
# what the CLIENT ASKED rather than on what the window holds — no `?spec_directory=`, no read of
# that area's files; no `?spec_file=`, no read of that file's examples. Both gates are decided
# before any read, so an unasked drill-in costs nothing rather than costing an empty one. Each
# block that uses these bounds its OWN grain rather than the table, because a bare
# total cannot tell "one aggregate per grain" from "one grain reading twice", and it has to be
# rebaselined by hand every time a grain is added — the silent rebaseline `queries_against` was
# chosen over `baseline + 1` to avoid.
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
# == The patterns that had to be TIGHTENED, and why
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
# THE AREA PATTERN WAS TIGHTENED THE SECOND TIME THE SAME LESSON ARRIVED, when the growth-by-area
# block was added. `GROUP BY COALESCE(substring(spec_file_path …` is what an AREA is in this schema
# — `SpecObservation::DIRECTORY_EXPRESSION`, deliberately one definition — so it is selected by
# `.directory_durations_in` (one run's areas by wall clock) AND by `.directory_growth_between` (two
# runs' areas by example count), and the loose pattern would have adopted the second into the first.
# That is the failure mode this file exists to prevent, arriving through the ONE expression that
# cannot be un-shared: the two reads must group identically, or the API and the panel would disagree
# about what a directory is. So the grains are separated on their ORDER BY, which is where the two
# genuinely differ — `SUM(duration_seconds)` ranks a run's areas by time and `ABS(COUNT(*) FILTER
# (WHERE test_run_id = …))` ranks two runs' areas by movement — and each pattern is still matched on
# SQL only its own read produces.
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
# THE FILE PATTERN WAS TIGHTENED THE THIRD TIME THE SAME LESSON ARRIVED, when the drill-in into one
# area's files was added. `.file_durations_in` (the run's heaviest files) and `.files_in_directory`
# (ONE area's files) both `GROUP BY "spec_observations"."spec_file_path"` and both rank on
# `SUM(duration_seconds)` — they are the same rollup over two different populations, so nothing in
# the GROUP BY or the ORDER BY can tell them apart, and the loose pattern adopted the second into
# the first. The two are separated on the PREDICATE instead, which is where they genuinely differ:
# the drill-in narrows on `DIRECTORY_EXPRESSION = <area>` and the rollup narrows on the run alone.
# So the drill-in's grain is matched on that predicate BESIDE the grouping — a conjunction only it
# produces — and the file grain is matched on the grouping WITHOUT it. That second half is the one
# concession this file makes to a negative match, and it is a narrowing of one pattern rather than a
# residual definition: `file` still means "the whole-run by-file rollup" and still adopts nothing,
# because a read has to group by `spec_file_path` to be a candidate at all.
#
# == The fourth arrival, where the lesson did NOT have to be relearned
#
# The drill-in into ONE file's examples is the only grain here matched on a SELECT ALIAS rather than
# on a grouping, a predicate or an order, and the reason is that every other candidate was worse.
# It ranks by duration like the per-example grain does, and the two are told apart today only by
# Arel's quoting — `.in_file` orders on an unquoted `duration_seconds DESC NULLS LAST` (it needs
# `NULLS LAST`, so it passes a SQL literal) where `.slowest_in` orders on the quoted
# `"spec_observations"."duration_seconds" DESC`. Neither string is a candidate for the other, so
# matching on the order WOULD work; it is not done, because resting a partition on which of two
# reads happened to need a literal is resting it on an accident that a later `NULLS LAST` elsewhere
# would quietly end.
#
# `AS file_recorded_count` is emitted by `SpecObservation::FILE_POPULATION_COUNTS` and by nothing
# else, and — unlike all three tightenings above — that uniqueness did not have to be discovered by
# being wrong first. The sibling window pair `DESCRIPTION_POPULATION_COUNTS` is its own constant
# PRECISELY so the two cannot share an alias: both are read back as record ATTRIBUTES by name, so a
# shared alias would have one panel reading the other's population under its own name, which that
# constant's comment calls not merely ill-fitting but false. The alias is therefore guaranteed
# distinct by a rule already written down in the model, rather than by an observation about today's
# call sites — the firmest match in this file, and the only one whose guarantee lives beside the SQL
# it describes rather than here.
module ObservationGrainReads
  # `queries_against` counts cached repeats and TRANSACTIONs, unlike `executed_sql` — see
  # `QueryCapture`, where the two rules and the difference between them are stated in full.
  def observation_reads(&) = queries_against("spec_observations", &)

  # The area predicate `SpecObservation.files_in_directory` narrows on — `DIRECTORY_EXPRESSION`
  # compared for EQUALITY against one area — which no other read of this table issues: the two
  # reads that share the expression GROUP on it, and neither compares it to anything.
  AREA_PREDICATE = /COALESCE\(substring\(spec_file_path from '\^\(\.\*\)\/\[\^\/\]\*\$'\), '\.'\) = /

  # `[area, file, example, description, flakiness, growth, directory_files, file_examples]` — the
  # eight grains, each an array of the statements matched. The single-run grains come first, in the
  # order `serialized_latest_run` serves them, and the two CROSS-RUN grains after them in the order
  # `show` serves them — so a destructuring caller reads the endpoint's own shape, and a caller
  # written before a grain was appended keeps naming the same lists it always did. The two DRILL-INS
  # are last rather than beside the rollups they sit between, for exactly that reason: each was
  # added after the grains before it, and every existing caller destructures a prefix of this array.
  # Appending is what keeps `directory_files` at index 6 for the callers already naming it there.
  def observation_reads_by_grain(&)
    reads = observation_reads(&)
    [reads.grep(/GROUP BY COALESCE\(substring\(spec_file_path.*ORDER BY SUM\(duration_seconds\)/m),
     reads.grep(/GROUP BY "spec_observations"\."spec_file_path"/).grep_v(AREA_PREDICATE),
     reads.grep(/ORDER BY "spec_observations"\."duration_seconds" DESC/) +
       reads.grep(/COUNT\(\*\) FILTER \(WHERE outcome = 'pending'\)/),
     reads.grep(/HAVING \(COUNT\(\*\) > 1\)/) +
       reads.grep(/COUNT\(\*\) FILTER \(WHERE name IS NULL\)/),
     flakiness_grain_patterns.flat_map { |pattern| reads.grep(pattern) },
     reads.grep(/ORDER BY ABS\(COUNT\(\*\) FILTER \(WHERE test_run_id = /),
     reads.grep(/GROUP BY "spec_observations"\."spec_file_path"/).grep(AREA_PREDICATE),
     reads.grep(/AS file_recorded_count/)]
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
  def growth_grain_reads(&) = observation_reads_by_grain(&)[5]
  def directory_files_grain_reads(&) = observation_reads_by_grain(&)[6]
  def file_examples_grain_reads(&) = observation_reads_by_grain(&)[7]
end

RSpec.configure do |config|
  config.include ObservationGrainReads
end
