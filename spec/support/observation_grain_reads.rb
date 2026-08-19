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
# window over) — and, for its two CROSS-RUN blocks, UP TO FOUR MORE for flakiness and UP TO TWO MORE
# for growth-by-area, which are not the only grains here whose count depends on state rather than
# only on shape: the DRILL-INS are ONE MORE EACH, and they are the grains whose count depends
# on what the CLIENT ASKED rather than on what the window holds — no `?spec_file=`, no read of that
# file's examples; no `?repeated_description=`, no read of that group's members; no
# `?unstable_test=`, no read of that test's run-by-run sequence; no `?unannotated_examples=`, no read
# of the run's unannotated population; and no
# `?spec_directory=`, no read of that area at any of the THREE grains one ask now opens — its files
# by wall clock, their example-count movement, and their runtime movement. Every gate is decided
# before any read, so an unasked
# drill-in costs nothing rather than costing an empty one. Each block that uses these bounds its OWN
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
#
# == The fifth arrival, which is the fourth one's argument reused rather than remade
#
# The drill-in into ONE description's examples is matched on `AS description_recorded_count`, the
# exact mirror of the pattern above, and it inherits that pattern's guarantee rather than needing one
# of its own: the constant emitting it is `DESCRIPTION_POPULATION_COUNTS`, which the paragraph above
# already establishes cannot share an alias with any other window pair on this table, BY A RULE
# WRITTEN BESIDE THE SQL. So this grain and the one above it are the two firmest matches here, and
# they are firm for one reason stated once.
#
# The order was rejected here for the same reason it was rejected there, and rather more sharply.
# `.with_description` and `.slowest_in` both rank this table by duration, and the two are told apart
# today only by Arel's quoting — the first passes the SQL literal `duration_seconds DESC NULLS LAST`
# because it needs `NULLS LAST`, exactly as `.in_file` does. That makes the by-duration reads THREE
# statements separated by an accident of quoting rather than two, and resting a third grain on it
# would be resting it on the same accident twice.
# == The SEVENTH arrival, which is the fifth one's argument reused a second time
#
# The drill-in into ONE unstable test's runs is matched on `AS unstable_test_recorded_count`, the
# third member of the alias family above, and it inherits their guarantee for the third time rather
# than needing one of its own: `SpecObservation::UNSTABLE_TEST_RUN_POPULATION_COUNTS` is its own
# constant PRECISELY so it cannot share an alias with `DESCRIPTION_POPULATION_COUNTS`, and that
# constant's comment says why in the sharpest form the rule has taken yet — the two pairs count the
# SAME COLUMN over DIFFERENT POPULATIONS, one run's rows against a thirty-run window's, so a shared
# alias would not be ill-fitting, it would report a window count under a run count's name on a block
# whose entire purpose is that those two are different.
#
# NOTHING ELSE HERE WAS A CANDIDATE, and unlike the arrivals above the alternatives are not merely
# worse, they are unavailable. This read GROUPS BY NOTHING — it is the ungrouped rows the flakiness
# composition sums over — so every grouping pattern in this file excludes it by construction. Its
# predicate (`repository_id` + `name` + a window of runs) is the composition's own predicate, and its
# ORDER BY is `array_position(…)`, which would in fact be unique but rests on the ordering strategy
# rather than on the projection — the accident this file has twice declined to rest a partition on.
# The alias is the only match here whose uniqueness is guaranteed BY A RULE WRITTEN BESIDE THE SQL,
# and it is now the guarantee that several of this file's grains stand on.
#
# == The EIGHTH arrival, where the alias family's guarantee is joined by a second one
#
# The drill-in into ONE run's UNANNOTATED examples is matched on `AS unannotated_recorded_count`, the
# fourth member of the alias family above, and it inherits that family's guarantee for the fourth
# time: `SpecObservation::UNANNOTATED_POPULATION_COUNTS` is its own constant PRECISELY so it cannot
# share an alias with any other window on this table, and its comment states the sharpest version of
# the rule yet — a `file_recorded_count` on these rows would report the run's unannotated population
# under a name claiming one FILE's, on the only block whose count a client is invited to reconcile
# against a headline figure.
#
# It is ALSO the first arrival whose read could have been matched on its PREDICATE without an
# accident: `"status" = 'unannotated'` is issued by no other read of this table, because no other read
# looks at that column at all. That option is not taken, and the reason is the one this file has given
# three times for rejecting an ORDER BY — the uniqueness would rest on an observation about today's
# call sites rather than on a rule written beside the SQL, and the day a second reader of `status`
# arrives (an annotated-side listing is the obvious one) it would end silently. The alias family's
# guarantee does not have that property, which is why it is the one used.
#
# ⚠️ ITS ORDER BY IS THE ONE PATTERN HERE THAT WOULD HAVE COLLIDED. `.unannotated_in` orders on
# `spec_file_path` — a QUOTED column reference, since it needs no SQL literal — which is the same
# column the by-file grouping matches on, and `GROUP BY "spec_observations"."spec_file_path"` is not
# what an ORDER BY emits, so the two do not in fact meet. That near miss is recorded rather than
# relied on: it is exactly the shape the three TIGHTENINGS above each discovered by being wrong first.
#
# == The growth grain has TWO READERS, and no pattern can separate them
#
# `growth_grain_reads` is the one accessor here that does not answer "did block X read". Both growth
# blocks on `GET /api/v1/repository` — `directory_growth` (the branch WINDOW's two endpoints) and
# `directory_run_growth` (the latest run against the PREVIOUS run on its branch) — call
# `SpecObservation.directory_growth_between`, so they emit the SAME statement and land in the same
# list. Tightening the pattern cannot fix that and should not be attempted: the two reads differ
# only in the run ids bound into them, which the log does not carry.
#
# What separates them is the GATE, not the SQL. `directory_growth` is constructed only under
# `?branch=`; `directory_run_growth` is constructed under every request. So a block measuring its
# own contribution measures a DIFFERENCE — unfiltered against named on one fixture — and
# `repository_directory_growth_spec.rb` does exactly that, with both terms asserted so the
# subtraction cannot be satisfied by both blocks going quiet. A bare count of two here is a fact
# about the endpoint and attributes nothing.
#
# A THIRD growth read exists and is NOT in that list: `directory_run_file_growth` issues
# `.file_growth_between`, the same comparison narrowed to ONE AREA. That narrow is a predicate the
# log DOES carry, so it separates cleanly and gets its own grain — see `GROWTH_ORDER`. The
# indistinguishability above is a property of the two AREA-grain reads specifically, not of growth
# reads in general.
#
module ObservationGrainReads
  # `queries_against` counts cached repeats and TRANSACTIONs, unlike `executed_sql` — see
  # `QueryCapture`, where the two rules and the difference between them are stated in full.
  def observation_reads(&) = queries_against("spec_observations", &)

  # The classified total: the sum of EVERY grain's reads. Defined here rather than at the call sites
  # for the reason the partition itself is — a sum written by hand is free to name a SUBSET, and the
  # omitted term is silently correct only while its fixture holds it at zero. That is not a tidiness
  # complaint: the two compose-several-drill-ins-at-once examples run SIX and SEVEN grains non-zero at
  # once, so they are among the places a cross-grain misclassification is likeliest to be observable —
  # and they were the two that shipped with no sum at all, because when a sum is hand-written the
  # fixture leaving the most grains live is the most tedious one to write it for.
  #
  # NEITHER IS THE MAXIMUM, ON EITHER MEASURE — and no counted leaderboard is given here on purpose:
  # every figure this paragraph has quoted for another fixture, and every denominator it has quoted
  # for the partition, went stale the first time a read was added here — whether that read opened a
  # NEW grain or landed in an EXISTING one. Both halves rot, and they rot on different commits: the
  # growth grain's second reader (see "TWO READERS" above) moved every total-reads figure quoted
  # here FOR ANOTHER FIXTURE while leaving the grain count untouched. The SINGLE-ASK blocks in
  # `repository_unstable_tests_spec.rb`, `repository_directory_growth_spec.rb` and
  # `repository_directory_runtime_file_growth_spec.rb` each leave at least as many grains live as
  # either example — the last of them more than either — and each issues MORE total reads than either,
  # because a cross-run grain can read several times where a drill-in reads once. So a block needs
  # this sum whenever its own fixture leaves SEVERAL GRAINS LIVE, which is not the same as composing
  # drill-ins and does not stop at five.
  # Appending a grain to `observation_reads_by_grain` extends this automatically; nothing downstream
  # has to be edited.
  #
  # Paired with `observation_reads`, this is the assertion the three TIGHTENED paragraphs above name
  # as the guard: a read double-classified into two grains makes the parts sum to MORE than the total,
  # and a read matching no grain at all makes them sum to LESS. Neither is visible to any per-grain
  # count, and neither is visible to a bare literal total, which cannot tell "one aggregate per grain"
  # from "one grain reading twice". Like every `observation_reads { ... }` pin beside it, this
  # re-executes its block — the established idiom in these files.
  def classified_observation_reads(&) = observation_reads_by_grain(&).sum(&:length)

  # The area predicate `SpecObservation.files_in_directory` narrows on — `DIRECTORY_EXPRESSION`
  # compared for EQUALITY against one area — which no other read of this table issues: the two
  # reads that share the expression GROUP on it, and neither compares it to anything.
  AREA_PREDICATE = /COALESCE\(substring\(spec_file_path from '\^\(\.\*\)\/\[\^\/\]\*\$'\), '\.'\) = /

  # The run-over-run RANKING, shared by BOTH growth reads: `.directory_growth_between` and
  # `.file_growth_between` both order by the absolute difference of two per-run `FILTER` counts, and
  # no other read of this table subtracts one run's count from another's.
  #
  # It is a whole grain on its own no longer, and that is the point of naming it here. The file-grain
  # read is the area read's own narrow — it carries `AREA_PREDICATE` — so it matches this ordering
  # AND the by-file grouping the durations drill-in is matched by, and would land in TWO grains at
  # once. A double-classified read makes the parts sum to MORE than the total, which is exactly the
  # defect `classified_observation_reads` exists to catch, so the two grains it collides with each
  # exclude it explicitly and it gets a grain of its own at the end.
  GROWTH_ORDER = /ORDER BY ABS\(COUNT\(\*\) FILTER \(WHERE test_run_id = /

  # The run-over-run RUNTIME ranking, shared by BOTH runtime growth reads:
  # `SpecObservation.directory_runtime_growth_between` and `.file_runtime_growth_between` both order
  # by the absolute difference of two per-run `FILTER` SUMS, where every other growth read subtracts
  # two `COUNT`s.
  #
  # ⭐ IT GETS ITS OWN GRAIN, AND THE ALTERNATIVE WAS NOT "WIDEN `GROWTH_ORDER`". The area read
  # shares the AREA GROUPING with `.directory_durations_in` and `.directory_growth_between` — the one
  # expression that cannot be un-shared, because the two surfaces must agree on what a directory is —
  # so the grain is separated on its ORDER BY, exactly as the area/growth split already is. Folding
  # it into `growth` (5) would put a read of a DIFFERENT QUANTITY into a list whose accessor callers
  # read as "the count-growth reads", turning every `growth.length == 1` pin into a `2` that
  # attributes nothing: `directory_run_growth` and `directory_runtime_growth` are constructed under
  # the SAME gate (every request, no parameter), so unlike the two readers already sharing grain 5,
  # no difference-of-fixtures could ever separate them again.
  #
  # `SUM(duration_seconds) FILTER (WHERE test_run_id = ` is issued nowhere else on this table: the
  # by-area and by-file duration rollups sum ONE run's rows and carry no `FILTER`, and every other
  # `FILTER (WHERE test_run_id = ` aggregate counts rather than sums. Matched POSITIVELY, on SQL only
  # these reads produce, on the rule stated at the top of this file.
  #
  # ⭐ IT STOPPED BEING ONE GRAIN'S PATTERN WHEN THE FILE-GRAIN RUNTIME READ ARRIVED, and that is the
  # sixth arrival of this file's one lesson — the exact shape `GROWTH_ORDER` records for the count
  # pair, one quantity over. `.file_runtime_growth_between` is the area read's own narrow: it carries
  # `AREA_PREDICATE`, so it matches this ordering AND the by-file grouping the durations drill-in is
  # matched by, and would land in TWO grains at once. So this grain excludes the narrow (11) and the
  # durations drill-in (6) excludes this ordering, and the intersection gets a grain of its own at
  # the end. Neither exclusion is decoration: a double-classified read makes the parts sum to MORE
  # than the total, which is exactly the defect `classified_observation_reads` exists to catch.
  RUNTIME_GROWTH_ORDER = /ORDER BY ABS\(SUM\(duration_seconds\) FILTER \(WHERE test_run_id = /

  # The area-grain ANNOTATION-DEBT ranking — `SpecObservation.unannotated_directories_in`, the ONE
  # read on this table that ranks a run's areas by how many of their examples carry no annotation.
  #
  # ⭐ AN ORDER BY, AND FOR THE REASON `GROWTH_ORDER` AND `RUNTIME_GROWTH_ORDER` ARE ONES rather than
  # in spite of the three paragraphs above that reject an ORDER BY match. Those three reject an
  # ordering that separates two reads BY ACCIDENT — Arel's quoting, or which of two reads happened to
  # need a `NULLS LAST` literal. This one separates them by the QUANTITY THEY RANK, which is the
  # difference the two reads actually have and the only one they can have: this read shares the AREA
  # GROUPING with `.directory_durations_in` and `.directory_growth_between`, and that expression is
  # `DIRECTORY_EXPRESSION`, deliberately one definition, because the API and the panel must not
  # disagree about what a directory is. It cannot be un-shared, so — exactly as the area/growth split
  # already is — the grain is separated on what it orders by.
  #
  # `COUNT(*) FILTER (WHERE status = 'unannotated')` **as an ORDER BY term**, which is issued by no
  # other read of this table. The near neighbour is `.unannotated_in`, which spells the same predicate
  # in a WHERE and emits `AS unannotated_recorded_count` besides, so the two cannot meet: a WHERE
  # clause is not a `DESC` and grain 13 matches on an alias this read does not select. Nothing here is
  # a residual definition — an unclassified read still belongs to no list and is caught by the total,
  # on this file's rule.
  #
  # ⚠️ IT NO LONGER ANCHORS ON `ORDER BY `, and the reason is a change to what this read RANKS rather
  # than to what it is. SPGD-711 put a term in front of it — `COUNT(*) FILTER (WHERE <reading> =
  # 'unreadable') DESC` — so the debt count is now the SECOND sort term and the anchored pattern
  # stopped matching, silently, by reporting zero reads for a grain that fired. The `DESC` suffix is
  # what keeps this a match on an ORDER BY rather than on the projection: `.unannotated_directories_in`
  # also SELECTS this expression, in the same statement, and without the suffix the pattern would still
  # classify correctly today for the accidental reason that both live in one read — the kind of
  # today's-call-sites reasoning this file rejects everywhere else.
  #
  # NOT retargeted at the new leading term. That one is spelled with `READING_EXPRESSION`, which
  # `SpecObservation::RUN_READING_COUNTS` shares by design, so a pattern built on it would be a
  # candidate for two reads at once — the exact double-classification `classified_observation_reads`
  # exists to catch. The debt count remains the quantity only this read ranks by.
  UNANNOTATED_DEBT_ORDER = /COUNT\(\*\) FILTER \(WHERE status = 'unannotated'\) DESC/

  # The RUN-grain reading counts — `SpecObservation.reading_counts_in`, the one read on this table
  # that answers how many of a run's examples SpecGuard has an authored, a derived or no reading of.
  #
  # Matched on `AS run_authored_count`, the fifth member of the alias family, and it inherits that
  # family's guarantee for the fifth time rather than needing one of its own:
  # `SpecObservation::RUN_READING_COUNTS` exists as a constant PRECISELY so this projection carries
  # aliases nothing else emits. That is not a preference here, it is the only firm option — this read
  # shares `READING_COUNTS` verbatim with `.unannotated_directories_in`, deliberately, so that a run's
  # headline and its by-area rollup cannot disagree about what a reading is, and the two would
  # otherwise be told apart only by the ABSENCE of a `GROUP BY`. A negative match is the residual
  # definition this file opens by refusing.
  #
  # ⚠️ THIS GRAIN IS UNGATED. Every other drill-in here fires only on the parameter that asks for it;
  # this one is served on every request, because a correction a client has to opt into leaves that
  # client reading the subtraction SPGD-711 exists to replace. A block bounding this endpoint's reads
  # of `spec_observations` should expect exactly one of these on any request that resolves a run.
  RUN_READINGS_PROJECTION = /AS run_authored_count/

  # `[area, file, example, description, flakiness, growth, directory_files, file_examples,
  # repeated_description_examples, directory_file_growth, runtime_growth,
  # directory_file_runtime_growth, unstable_test_runs, unannotated_examples,
  # unannotated_directories, run_readings]` — the sixteen grains,
  # each an array of the
  # statements matched. The single-run grains come first, in the order `serialized_latest_run` serves
  # them, and the two CROSS-RUN grains after them in the order `show` serves them — so a
  # destructuring caller reads the endpoint's own shape, and a caller written before a grain was
  # appended keeps naming the same lists it always did. The DRILL-INS are last rather than beside the
  # rollups they sit between, for exactly that reason: each was added after the grains before it, and
  # every existing caller destructures a prefix of this array. Appending is what keeps
  # `directory_files` at index 6 for the callers already naming it there.
  #
  # ⭐ APPENDING IS FREE FOR CALLERS AND IS NOT FREE FOR PROSE, AND THAT IS THE PART THAT KEEPS BEING
  # MISSED — AND IT IS NOT ONLY APPENDING. The comparison paragraphs in
  # `repository_spec_file_examples_spec.rb` and
  # `repository_repeated_description_examples_spec.rb` — and the one beside
  # `classified_observation_reads` above — rank their fixture AGAINST THIS PARTITION: how much of it
  # the fixture leaves live, and how it places against other fixtures on grains live and on total
  # reads. A read added here can falsify all three without touching a line either of those files
  # owns, and it does not have to be a NEW grain to do it: every grain appended since those
  # paragraphs were written has corrected THIS file's own count of the partition and left them
  # stale, and the growth grain's SECOND READER — `directory_run_growth`, see "The growth grain has
  # TWO READERS" above — moved every total-reads figure ANY OF THEM quoted FOR ANOTHER FIXTURE
  # without changing the grain count at all. So when you add a read here, whether it opens a new
  # grain or joins an existing one, RE-READ THOSE TWO REQUEST SPECS, and keep their prose free of
  # any suite-wide total or counted ranking — the claim they need is "this fixture leaves several
  # grains live", which no later read can falsify.
  #
  # `growth` (5), `directory_files` (6) and `runtime_growth` (10) each carry an EXCLUSION rather than
  # only their own pattern, and the exclusions are not decoration. `directory_file_growth` (9) is the
  # intersection of the first two — a count-growth-ordered read narrowed to one area, grouped by file
  # — and `directory_file_runtime_growth` (11) is the intersection of the last two, the same shape
  # one quantity over. Without the four exclusions those two statements would each be counted three
  # times. See `GROWTH_ORDER` and `RUNTIME_GROWTH_ORDER`.
  def observation_reads_by_grain(&)
    reads = observation_reads(&)
    [reads.grep(/GROUP BY COALESCE\(substring\(spec_file_path.*ORDER BY SUM\(duration_seconds\)/m),
     reads.grep(/GROUP BY "spec_observations"\."spec_file_path"/).grep_v(AREA_PREDICATE),
     reads.grep(/ORDER BY "spec_observations"\."duration_seconds" DESC/) +
       reads.grep(/COUNT\(\*\) FILTER \(WHERE outcome = 'pending'\)/),
     reads.grep(/HAVING \(COUNT\(\*\) > 1\)/) +
       reads.grep(/COUNT\(\*\) FILTER \(WHERE name IS NULL\)/),
     flakiness_grain_patterns.flat_map { |pattern| reads.grep(pattern) },
     reads.grep(GROWTH_ORDER).grep_v(AREA_PREDICATE),
     reads.grep(/GROUP BY "spec_observations"\."spec_file_path"/).grep(AREA_PREDICATE)
          .grep_v(GROWTH_ORDER).grep_v(RUNTIME_GROWTH_ORDER),
     reads.grep(/AS file_recorded_count/),
     reads.grep(/AS description_recorded_count/),
     reads.grep(GROWTH_ORDER).grep(AREA_PREDICATE),
     reads.grep(RUNTIME_GROWTH_ORDER).grep_v(AREA_PREDICATE),
     reads.grep(RUNTIME_GROWTH_ORDER).grep(AREA_PREDICATE),
     reads.grep(/AS unstable_test_recorded_count/),
     reads.grep(/AS unannotated_recorded_count/),
     reads.grep(UNANNOTATED_DEBT_ORDER),
     reads.grep(RUN_READINGS_PROJECTION)]
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
  def repeated_description_examples_grain_reads(&) = observation_reads_by_grain(&)[8]
  def directory_file_growth_grain_reads(&) = observation_reads_by_grain(&)[9]
  def runtime_growth_grain_reads(&) = observation_reads_by_grain(&)[10]
  def directory_file_runtime_growth_grain_reads(&) = observation_reads_by_grain(&)[11]
  def unstable_test_runs_grain_reads(&) = observation_reads_by_grain(&)[12]
  def unannotated_examples_grain_reads(&) = observation_reads_by_grain(&)[13]
  def unannotated_directories_grain_reads(&) = observation_reads_by_grain(&)[14]
  def run_readings_grain_reads(&) = observation_reads_by_grain(&)[15]
end

RSpec.configure do |config|
  config.include ObservationGrainReads
end
