# frozen_string_literal: true

# The tests whose outcome CHANGED across a branch's recent runs — together with everything the
# surface listing them has to state about the window they were drawn from and the rule they were
# matched by.
#
# The first read this application makes that MATCHES A TEST TO ITSELF across runs. Every reader
# before it either bounds itself to one run on purpose — `SlowestExamples`, `SpecFileDurations`,
# `SpecDirectoryDurations`, `SpecObservation::COVERAGE_COUNTS` — or, in `SpecDirectoryGrowth`'s
# case, spans two runs while pairing nothing inside them: it counts rows per area on each side and
# subtracts two integers, and its own comment is explicit that no example crosses the run boundary.
# That is the difference this object turns on. "The slowest tests in this run" is a question one
# run's rows answer and "did this area grow" is a question two populations answer, but "is this
# test flaky" is a question about ONE test seen in several runs, and it cannot be asked without a
# rule for deciding that two rows in two runs are the same test. This is that question, and the
# rule it needs is the next section.
#
# == The rule is the durable identity, and the panel says so
#
# Tests are matched across runs by their `spec_identity_id` — the durable semantic identity
# `Ingest::IdentityResolver` derives from the `@intent` triple when entity/action/behavior are all
# present, and from the description when they are not — and by nothing positional. Not by file, not
# by the `file_path:line_number` coordinate, which `SpecObservation`'s class comment records as
# positional and explicitly unstable across refactors, and — since SPGD-758 — not by `name` either.
# The project's identity rule is semantic: a test that moves within a file or to another file is the
# same test and its history follows it, and flakiness is exactly the question that cannot be asked
# without that. This is the same grain `SlowestTests` ranks the duration axis at, and for the same
# reason: grouped on `name`, an annotated test reworded mid-window was two half-histories, and a
# test that failed under the old description and passed under the new satisfied `Row#changed?` in
# NEITHER half — the flakiest possible signal, invisible precisely because it was renamed.
#
# The UNANNOTATED case is owner-settled and unchanged (Project Goals, SPGD-1): an unannotated
# test's identity is derived from its description, so a reword still starts a new history, and that
# is intended rather than a limitation to apologise for. An annotated test survives a reword — the
# `@intent` carries identity ahead of the description — and both its duration history and its
# OUTCOME history follow it. `Row#renamed?` discloses that a row's history spans two descriptions.
#
# Nothing about that rule is written to the database beyond the resolver's own writes: this is a
# read-time `GROUP BY` whose rule the panel states in its own caption, which is what keeps it
# revisable. Exact string equality is the degenerate case of the soft match the goals describe —
# an unchanged description produces a byte-identical vector, so a cosine-1.0 match returns these
# same groups — and when a similarity provider lands, this read is where the threshold widens.
# Nothing here is undone by it.
#
# == Why the list and its captions are one object
#
# `SlowestExamples` states the rule and it is the same rule here, one grain wider: a caption is a
# claim ABOUT the list. "3 of the last 30 runs on main reported outcomes" is only true if that
# figure counted the same window the groups below it were grouped over. Fetched into separate
# ivars they are two things that agree today with no structural reason to keep agreeing. It derives
# no figure of its own — every number comes back from the reads in `SpecObservation`.
#
# == Five bounded reads, none of them growing with the suite
#
# 1. `.window_outcome_reporting` — how many of the window's runs reported anything at all, and how
#    many of them said how any example ended. Asked FIRST and on its own, because fewer than two
#    such runs means the comparison cannot be made and everything below it would be a figure about
#    silence. At most two index probes per run.
# 2. `.unstable_identity_candidates_in` — the durable tests that failed anywhere in the window,
#    capped.
# 3. `.unstable_outcome_composition_in` — those identities only, across the whole window.
# 4. `.unnamed_row_count_in` — the rows that carried no description, and
# 5. `.unresolved_row_count_in` — the rows that reached no identity. Two exclusion counts of the
#    same window grain, one per column the matching can be denied by.
#
# The count is constant in the length of the window and in the size of the suite. It is not
# constant in STATE — an incomparable window costs one read and stops, and a window with no
# failures at all never runs the composition — which is the point of asking the gating question
# first rather than a shape to be tidied away.
class UnstableTests
  # @param runs [Array<TestRun>] the window, ALREADY LOADED — the same rows the "Suite growth"
  #   panel is drawn on, handed in rather than re-queried. Every panel that fetched "the last thirty
  #   runs on this branch" separately would be its own window, agreeing today with no structural
  #   reason to keep agreeing, and this one's captions name the others' branch.
  def self.for(repository, runs, branch: nil)
    run_ids = runs.map(&:id)
    reporting = SpecObservation.window_outcome_reporting(run_ids)

    window = { branch: branch, run_count: runs.size, **reporting }
    # Nothing below this line may be read as a fact about outcomes on a window that reported fewer
    # than two of them, so nothing below this line is asked. See `#comparable?`.
    #
    # THREE ZEROS AND TWO NILS, and the split is the point. `candidate_count` and `examined_count`
    # are OUTCOME-derived — the candidate step reads `outcome`, and in a window nothing was
    # examined in they are the true counts of an examination that correctly did not happen.
    # Neither `unnamed_count` nor `unresolved_count` is: neither `.unnamed_row_count_in` nor
    # `.unresolved_row_count_in` carries an outcome predicate at all, so both are real and
    # answerable facts here that this branch simply never asks. Serving `0` for either would be a
    # fabricated exclusion count — indistinguishable, on the wire, from a window measured to have
    # excluded nothing — and these keys exist precisely so a client can tell how much of the
    # window the matching had to drop.
    #
    # `nil` rather than the count, because asking would cost second reads and the API doc states as
    # a deliberate property that an incomparable window costs ONE read and stops. Absence at zero
    # cost, on the precedent SPGD-474 set for the same fabrication.
    unless reporting[:runs_reporting_outcomes] >= 2
      return new(**window, groups: [], candidate_count: 0, examined_count: 0,
                 unnamed_count: nil, unresolved_count: nil)
    end

    candidates = SpecObservation.unstable_identity_candidates_in(run_ids)
    identity_ids = candidates.map(&:first)

    new(**window,
        groups: SpecObservation.unstable_outcome_composition_in(run_ids: run_ids,
                                                                spec_identity_ids: identity_ids),
        # Off any row, because the count rides back on all of them; `to_i` on the nil of a window
        # in which nothing failed, where "no candidates" is the honest count.
        candidate_count: candidates.first&.last.to_i,
        examined_count: identity_ids.size,
        unnamed_count: SpecObservation.unnamed_row_count_in(repository_id: repository.id, run_ids: run_ids),
        unresolved_count: SpecObservation.unresolved_row_count_in(repository_id: repository.id,
                                                                  run_ids: run_ids))
  end

  def initialize(branch:, run_count:, runs_with_rows:, runs_reporting_outcomes:, groups:,
                 candidate_count:, examined_count:, unnamed_count:, unresolved_count:)
    @branch = branch
    @run_count = run_count
    @runs_with_rows = runs_with_rows
    @runs_reporting_outcomes = runs_reporting_outcomes
    @candidate_count = candidate_count
    @examined_count = examined_count
    @unnamed_count = unnamed_count
    @unresolved_count = unresolved_count
    @changed = groups.map { |tuple| Row.new(**ROW_ATTRIBUTES.zip(tuple).to_h) }.select(&:changed?)
                     .sort_by { |row| [-row.failed_run_count, -row.run_count, row.spec_identity_id] }
  end

  # How a composition tuple is read into a `Row`. Built by NAME off
  # `SpecObservation::UNSTABLE_COMPOSITION` rather than by position, so a counter added to that
  # constant cannot silently land in the wrong attribute here. Ten values in a row is exactly the
  # signature two of them get quietly swapped in — the objection `SlowestExamples#initialize`
  # answers with keywords, made structural.
  ROW_ATTRIBUTES = [:spec_identity_id, *SpecObservation::UNSTABLE_COMPOSITION.keys].freeze

  private_constant :ROW_ATTRIBUTES

  # The branch every figure here was drawn on, and the one the "Suite growth" panel above is drawn
  # on. Outcomes compared across branches are outcomes of different code, so the window is
  # branch-anchored exactly as that panel's is — same `?branch=` selector, same anchor run, same
  # `Repository::TRAJECTORY_LIMIT`.
  attr_reader :branch

  # How many runs the window holds, and how many of them wrote example rows at all. The second is
  # not derivable from the first: a run ingested before per-example rows existed, or one whose
  # client sends no per-example detail, is a run of the window with nothing at this grain.
  attr_reader :run_count, :runs_with_rows

  # How many runs of the window said how ANY of their examples ended — the figure every claim on
  # this panel is worded against, and the one that decides whether there is a comparison to make.
  attr_reader :runs_reporting_outcomes

  # How many distinct descriptions failed somewhere in the window, and how many of those the
  # composition step actually examined. Equal unless the candidate cap bit.
  attr_reader :candidate_count, :examined_count

  # How many rows of the window carried no description and were therefore excluded from the
  # matching. Rows, not tests — an unnamed row is precisely a row this panel cannot say is a test.
  #
  # `nil` — never `0` — wherever `#comparable?` is false, because that branch returns before the
  # count is read and a zero there would be an exclusion figure nothing measured. Every reader of
  # this must therefore sit behind a `comparable?` guard or handle the nil.
  # `RepositoriesHelper#unstable_tests_unnamed_clause` is the former, and the guard is over its
  # CALLER rather than over it: it is reached only through `#unstable_tests_exclusion_sentence`,
  # which the repository page renders inside the `<% if @unstable_tests.comparable? %>` branch of its
  # "Tests whose outcome changed" panel (`id: "unstable-tests"`). The API serializer
  # (`RepositoryOverview#serialized_unstable_tests`, which emits the `unnamed_count:`
  # key) is the latter — it serves the nil through as `null`.
  attr_reader :unnamed_count

  # How many rows of the window reached no durable identity and were therefore excluded from the
  # matching — the sibling exclusion of the one above, at the same window grain, for the column
  # the identity-grained matching (since SPGD-758) is denied by instead. Rows, not tests: an
  # unresolved row is precisely a row this panel cannot say WHICH test is.
  #
  # `nil` — never `0` — on the same branch and for the same reason as `unnamed_count` above: a
  # zero there would be a fabricated exclusion count, and this key is served through the same
  # serializer beside that one.
  attr_reader :unresolved_count

  # Whether this window has any per-example grain AT ALL — the question that decides whether the
  # panel is rendered rather than what it says. A repository whose CI has never sent per-example
  # detail has no cross-run test history to discuss, and a panel explaining that at length would be
  # discussing a table it has no rows in. The sibling panels draw the same line with their own
  # `recorded?`.
  def recorded? = runs_with_rows.positive?

  # Whether an outcome COMPARISON can be made at all: two runs that reported outcomes is the
  # minimum, because one run's outcome cannot have changed from anything.
  #
  # This is the panel's Vacuous Green gate and it is why there is no zero behind it. `outcome` is
  # nullable and nothing validates it, so a window whose client sends no outcomes stores a nil on
  # every row of every run — and such a window produces no failures, therefore no candidates,
  # therefore an empty list. Rendered as "no test changed its outcome" that empty list is "nobody
  # told us" in the words of "everything is stable". The zero is real; what it counts is silence.
  # `SlowestExamples#outcomes_reported?` draws the same line for a single run.
  def comparable? = runs_reporting_outcomes >= 2

  # The tests whose outcome changed across the window, most-failing first — each one a durable
  # test that failed in some of the runs it appeared in and reported some other outcome in others.
  #
  # Only groups whose identity belonged to at most one example per run. An identity carried by
  # two examples in a single run is not a key for that run, so its `failed` and its `passed` are
  # two tests rather than one test that flipped, and calling it flaky would be a false positive
  # manufactured by the matching rule. Those groups are reported — separately, as what they are —
  # by `#shared_description_rows`.
  def rows = @changed.reject(&:shared_description?)

  # The groups the rule could not rule on: tests that varied in outcome across the window AND were
  # carried by more than one example in at least one run of it. Listed rather than dropped,
  # because a dropped group is a silence the reader has no way to notice, and named as what they
  # are rather than as flakiness, because nothing here establishes which of it.
  def shared_description_rows = @changed.select(&:shared_description?)

  def any? = rows.any?

  # Durable tests that failed in the window and were never examined, because the candidate cap bit.
  # A capped list that does not disclose its cap is read as the whole story — the same lie by
  # omission `SpecFileDurations#truncated?` refuses one panel over.
  def truncated? = candidate_count > examined_count

  def unexamined_count = candidate_count - examined_count

  # One durable test, across the whole window — how often it was seen, how often it failed, and
  # which words the runs used for what happened to it.
  Row = Struct.new(:spec_identity_id, :recorded_count, :run_count, :reported_outcome_count,
                   :failed_count, :failed_run_count, :outcomes, :file_paths, :names, :latest_name,
                   keyword_init: true) do
    # The description a reader recognises — the identity's MOST RECENT one, which is the label the
    # drill-in (`UnstableTestRuns`, keyed positionally on `name`) resolves the row to its runs
    # under. Load-bearing for that reason: the row must keep a usable `name` even though the
    # grouping key moved off it.
    def name = latest_name

    # Its outcome CHANGED: it failed somewhere in the window and reported some other outcome
    # somewhere else in it.
    #
    # Both halves are needed and neither is redundant. The failure is what put the identity in
    # front of this object at all (see `SpecObservation.unstable_identity_candidates_in`) and is
    # asserted again here rather than assumed, because this predicate is what the surface's whole
    # claim rests on. The other half is a comparison against `reported_outcome_count` and NOT against
    # `recorded_count`: a run that recorded the test and said nothing about how it ended is not
    # evidence that it passed, and counting that silence as a second outcome would manufacture a
    # flip out of a client that stopped sending outcomes.
    def changed? = failed_count.positive? && reported_outcome_count > failed_count

    # This identity was carried by more than one example in at least one run of the window, so it
    # is not a key for that run and its differing outcomes are not known to be one test's. At the
    # identity grain this means several examples RESOLVED TO ONE IDENTITY within a single run — a
    # table-driven loop, a shared example group, or two verbatim-identical tests, which the
    # resolver's cosine-1.0 match agrees are one — rather than the several-same-description reading
    # the name-grained rule had. `COUNT(*)` against `COUNT(DISTINCT test_run_id)`, taken in the
    # same pass as everything else.
    def shared_description? = recorded_count > run_count

    # This test's DESCRIPTION changed across the window while its identity did not — the disclosure
    # `SlowestTests::Row#renamed?` makes for the duration axis, and which grouping on `name`
    # structurally could not make until SPGD-758 moved this read to the identity. An annotated
    # test reworded mid-window is ONE row here wearing both descriptions; the failed-then-passed
    # rename that used to vanish into two half-histories appears, and says what it is.
    def renamed? = descriptions.size > 1

    # The same test was recorded under more than one spec file across the window. Per the
    # project's semantic-identity rule a test that MOVED is the same test and keeps its history, so
    # this is a disclosure rather than a defect — but a reader looking for a flaky test in one file
    # needs to know the history spans two.
    def multi_file? = files_seen.size > 1

    # Runs that recorded this description and said nothing about how it ended. Not a pass, and not
    # counted as one anywhere above.
    def unreported_outcome_count = recorded_count - reported_outcome_count

    # How much of the window this description was seen in — always the fraction, because "12" alone
    # reads as twelve of something unstated and the denominator is the point.
    def appearance_label(window_run_count) = SpecObservation.coverage_fraction(run_count, window_run_count)

    # How much of its own history it failed in. The denominator is the runs it APPEARED in, never
    # the window: a test added halfway through the window failed in two of the fifteen runs that
    # ran it, and dividing by thirty would report a stability it was never measured for.
    def failure_label = SpecObservation.coverage_fraction(failed_run_count, run_count)

    # The words this description was seen wearing, echoed verbatim and sorted so two rows carrying
    # the same set read the same way. Never reworded and never folded into a verdict —
    # `SpecObservation#outcome_label` carries why: nothing platform-side validates this string, so
    # quoting what arrived is the only reading that cannot be wrong.
    def outcome_words = Array(outcomes).sort

    # The descriptions this test was seen wearing, sorted so two rows carrying the same set read
    # the same way. `Array()` because the aggregate is `ARRAY_AGG(…) FILTER (…)`, which is SQL
    # NULL rather than an empty array for a group with nothing to collect — a nil the caller would
    # otherwise have to know about at every call site. Two of them is `#renamed?`.
    def descriptions = Array(names).sort

    # The spec files this test was recorded under. `Array()` because both aggregates are
    # `ARRAY_AGG(…) FILTER (…)`, which is SQL NULL rather than an empty array for a group with
    # nothing to collect — a nil the caller would otherwise have to know about at every call site.
    def files_seen = Array(file_paths).sort
  end
end
