# frozen_string_literal: true

# The slowest tests in a REPOSITORY — one durable test per row, its wall clock summed across a
# branch's recent runs — together with everything the surface listing them has to state about the
# window they were drawn from and the population they were ranked out of.
#
# The read {SpecObservation}'s own class comment has been describing in the future tense since the
# table existed. It draws the boundary in these words:
#
#   They are per-run facts, not a history: "the slowest tests in this run" is a question this table
#   answers with a single indexed query; "the slowest tests in this repository" spans runs and
#   belongs to the work that settles cross-run identity.
#
# That work landed — `spec_identity_id` is written on every row by {Ingest::ObservationRecorder} and
# resolved by {Ingest::IdentityResolver} — and until this object nothing aggregated it. Every read on
# this table either bounds itself to one run ({SlowestExamples}, {SpecFileDurations},
# {SpecDirectoryDurations}) or spans runs while grouping on something else: {UnstableTests} groups on
# `name`, deliberately and for a question about outcomes, and {NearDuplicateClusters} reaches
# `spec_identities` but weighs every cluster inside a SINGLE run. This is the first `GROUP BY
# spec_identity_id` in the application, and the difference it makes is one sentence long: **a test
# that moved keeps its runtime history.**
#
# == ⭐ Which is the whole point, so it is worth saying what "moved" costs the alternatives
#
# Group on `(file_path, line_number)` and a test that slid four lines down in a refactor is two rows
# splitting one history, each reporting half the wall clock — `SpecObservation`'s class comment
# records that coordinate as positional and explicitly unstable. Group on `example_id` and the same
# happens on any reorder, `scoped_id` being positional too. Group on `name` — which {UnstableTests}
# does, on purpose, and which nothing here relitigates — and a test survives a move but not a
# rename, and an edited description starts a fresh history halfway through the window. The identity
# is semantic and outlives all three edits, and this ranking is where that finally buys something.
#
# == Two steps, because the honest spelling of this question is unaffordable
#
# "Group the window by identity and order by the sum" reads every row of every run: 600,000 of them
# at thirty runs of the roadmap's 20,000-example design point, per render. `SpecObservation`'s
# `.unstable_candidates_in` states the same arithmetic for its own grain and refuses it the same
# way, and this mirrors that two-step exactly:
#
# 1. **Candidates** — `.slowest_identity_candidates_in`, the NEWEST run's slowest identities, capped.
#    ONE run, reached through an index that LEADS WITH `test_run_id` — which one is the planner's to
#    pick, and the measured pick is not the obvious one. `EXPLAIN` takes the `(test_run_id, outcome)`
#    bitmap rather than `…_on_test_run_id_and_duration_seconds`: the aggregate visits the heap for
#    `spec_identity_id` either way, so the wider index buys a whole-run grouping nothing. What has to
#    stay true is that one run is read through an index instead of every run's rows being walked, and
#    that — not a cost tiebreak Postgres may revisit — is what the certification asserts.
# 2. **Composition** — `.identity_duration_composition_in`, those identities ONLY across the window,
#    on `index_spec_observations_on_spec_identity_id`. The bound is **candidates × the runs those
#    identities appear in at all**, NOT `limit × window`: that index is on `spec_identity_id` alone,
#    so the window arrives as a FILTER after the fetch rather than as an index condition that narrows
#    it (measured: 200 rows fetched, 140 removed, 60 kept, against a window holding 1,800). Which
#    leaves it bounded by RETENTION — `BRANCH_RETENTION_RUNS` caps a branch at 60 runs, so a
#    candidate's rows are capped whatever window is asked for.
#
# Both bounds above are MEASURED, and both corrected an earlier claim this comment made from the
# armchair; `.slowest_identity_candidates_in` and `.identity_duration_composition_in` carry the
# `EXPLAIN` output the corrections came from. The number this read follows is the CANDIDATE COUNT,
# and the number the naive spelling follows is the row count — which is the whole of why it is two
# steps.
#
# Three bounded statements for the whole panel — a gate, a candidate step and a composition — and
# none of them grows with the size of the suite. The count is not constant in STATE, and that is the
# point of asking the gating question first rather than a shape to be tidied away: a window whose
# anchor recorded nothing costs one read and stops.
#
# == ⭐ The ranking is anchored on the newest run, and that is a PARTITION
#
# The candidates are the newest run's slowest tests; the window then supplies their history. So a
# test that ran in the first twenty runs of the window and not in the newest is **not here** — and
# per the project's *Vacuous Green* constraint that is a claim this object has to STATE rather than
# leave to be discovered by someone wondering where a deleted test's forty seconds went.
#
# It is the right partition, not merely the affordable one. A test absent from the newest run is not
# in the suite being asked about: it was deleted, renamed past its own identity, or not selected by
# this run's filter, and a ranking that resurrected it would answer "what is slow in this suite" with
# the contents of a suite that no longer exists. `#anchor_run` names the run that decided it.
#
# The partition has a SECOND edge, on a different axis, and it is stated here for the same reason.
# The cap is applied on each candidate's ANCHOR-RUN duration; the list is then ordered on its WINDOW
# TOTAL. Those are two different orderings, so a test sitting eleventh in the anchor run is absent
# even if its total across the window would have led the list — a cheap-today test with a long
# history is exactly the shape that falls through. It is inherent to narrowing before aggregating
# (the alternative being the whole-window group-by the two steps exist to refuse), and `#truncated?`
# with `#unexamined_count` disclose that the cap bit. But "the slowest tests in this repository" is
# not quite the claim the rows support, and this object states its partitions rather than letting
# them be discovered.
#
# == ⭐ An empty list has three meanings and they are three states, never one blank panel
#
# {Ingest::IdentityResolutionJob} is enqueued from the ingest controller, whose own header comment
# says *"anything reading the embeddings will trail a run that just landed"* — so a window whose
# newest run has resolved nothing is the ORDINARY state for the seconds after an ingest, and it
# produces the identical empty ranking as a repository that has never sent per-example detail. The
# gate is asked first, on its own, and stops: `#recorded?` separates "no rows at all" from "rows,
# none of them resolved yet", `#resolved?` names the second, and only `#any?` may be read as "nothing
# was slow". {UnstableTests} asks its own gating question the same way and for the same hazard.
#
# == The list and its captions are one object
#
# {UnstableTests}' rule, unchanged: a caption is a claim ABOUT the list, so "ranked over the 4,812 of
# 4,900 rows the newest run resolved" is only true if those figures counted the rows the ranking was
# drawn from. It derives no figure of its own — every number comes back from the reads in
# {SpecObservation}, and the coverage fraction is spelled through `.coverage_fraction`, the one seam
# every single-sided coverage label on this application goes through.
class SlowestTests
  # @param repository [Repository] the grain of the RANKING, and the tenant the anchor is checked
  #   against — see `.validate_anchor!`.
  # @param runs [Array<TestRun>] the window, ALREADY LOADED and OLDEST FIRST — the same rows the
  #   "Suite growth" chart, the "Tests whose outcome changed" panel and the window growth panel are
  #   drawn on, handed in rather than re-queried. Every panel that fetched "the last thirty runs on
  #   this branch" for itself would be its own window, agreeing today with no structural reason to
  #   keep agreeing, on a page where each captions the others' branch.
  # @param branch [String, nil] the branch every figure is drawn on, for the caption.
  def self.for(repository, runs, branch: nil, limit: SpecObservation::SLOWEST_LIMIT)
    anchor = runs.last
    window = { branch: branch, run_count: runs.size, anchor_run: anchor }

    # No run, no anchor, no partition — and nothing asked of the database. `UNREAD` rather than
    # zeroes, on the rule the states below obey.
    return new(state: :no_runs, **window, **UNREAD) if anchor.nil?

    validate_anchor!(repository, anchor)
    rank(runs, anchor, window, limit)
  end

  # What a state that never reached a read reports for the figures that read would have produced:
  # `nil` on every one of them, never `0`.
  #
  # {UnstableTests} argues this at length where it serves a nil `unnamed_count` and the argument is
  # unchanged here: a zero exclusion count is indistinguishable, on the wire, from a window measured
  # to have excluded nothing, and these keys exist precisely so a client can tell how much of the
  # window the ranking had to drop. Absence at zero cost. Every reader of these must therefore sit
  # behind the predicate that gates its state, or handle the nil.
  UNREAD = { recorded_count: nil, unresolved_count: nil, candidate_count: nil, resolved_count: nil,
             timed_count: nil }.freeze

  private_constant :UNREAD

  # The gate, then the two steps behind it.
  #
  # Separate from `.for` so the question asked of the anchor alone stays legible above it, and
  # private because the anchoring rule is this object's own: a caller that picked its own anchor
  # would be a second spelling of the partition the ⭐ section exists to state.
  def self.rank(runs, anchor, window, limit)
    presence = SpecObservation.identity_presence_in(anchor)
    resolved_rows = presence[:recorded_count] - presence[:unresolved_count]

    # Nothing below this line may be read as a fact about a suite's runtime, so nothing below this
    # line is asked. Two states and never one: a run that wrote no rows has no per-example grain to
    # discuss, and a run whose rows are all still unresolved has one that is a few seconds away.
    return new(state: :unrecorded, **window, **UNREAD, **presence) if presence[:recorded_count].zero?
    return new(state: :unresolved, **window, **UNREAD, **presence) unless resolved_rows.positive?

    candidates = SpecObservation.slowest_identity_candidates_in(anchor, limit: limit)
    identity_ids = candidates.map(&:first)
    _id, candidate_count, timed_count = candidates.first

    new(state: :ranked, **window, **presence,
        # The first two off any row, because both ride back on every one of them. `resolved_count` is
        # NOT among them: it is the gate's own figure, threaded through rather than re-counted, on
        # `.slowest_identity_candidates_in`'s ⚠️ — the same predicate over the same population
        # measured in two statements is two snapshots the caption can be caught between.
        candidate_count: candidate_count.to_i, timed_count: timed_count.to_i,
        resolved_count: resolved_rows,
        tuples: SpecObservation.identity_duration_composition_in(
          run_ids: runs.map(&:id), spec_identity_ids: identity_ids
        ))
  end
  private_class_method :rank

  # The anchor must be the ranked repository's own run, and it is CHECKED rather than trusted for
  # {NearDuplicateClusters}' reason — which is this object's reason too, because it is the very same
  # read that carries the exposure. `SpecObservation.identity_presence_in` is `where(test_run_id:)`
  # with no tenant predicate, being a read whose run is normally its caller's own, so a foreign
  # anchor makes `#recorded_count` and `#unresolved_count` report ANOTHER TENANT'S row counts beside
  # a list of this one's tests. Caption and list would then be halves of two different populations,
  # which is the one property this object's class comment claims for itself.
  #
  # A raise rather than a silent scoping: the window is documented as handed in, so a window from the
  # wrong repository is a caller's bug and quietly substituting the right rows would hide it.
  def self.validate_anchor!(repository, anchor)
    return if anchor.repository_id == repository.id

    raise ArgumentError,
          "run #{anchor.id} belongs to repository #{anchor.repository_id}, not #{repository.id} — " \
          "the anchored window must be the ranked repository's own"
  end
  private_class_method :validate_anchor!

  def initialize(state:, branch: nil, run_count: 0, anchor_run: nil, recorded_count: nil,
                 unresolved_count: nil, candidate_count: nil, resolved_count: nil, timed_count: nil,
                 tuples: [])
    @state = state
    @branch = branch
    @run_count = run_count
    @anchor_run = anchor_run
    @recorded_count = recorded_count
    @unresolved_count = unresolved_count
    @candidate_count = candidate_count
    @resolved_count = resolved_count
    @timed_count = timed_count
    @rows = tuples.map { |tuple| Row.new(**ROW_ATTRIBUTES.zip(tuple).to_h) }.sort_by(&:sort_key)
  end

  # How a composition tuple is read into a `Row`. Built by NAME off
  # `SpecObservation::IDENTITY_DURATION_COMPOSITION` rather than by position, so a counter added to
  # that constant cannot silently land in the wrong attribute here — {UnstableTests}' `ROW_ATTRIBUTES`
  # makes the same choice for the same hazard, and `.directory_durations_in` carries the scar from
  # when a tuple grew and a caller kept reading the old position.
  ROW_ATTRIBUTES = [:spec_identity_id, *SpecObservation::IDENTITY_DURATION_COMPOSITION.keys].freeze

  private_constant :ROW_ATTRIBUTES

  # ⭐ Which of the four states this is — one ranked, three not. A symbol rather than a reassembly of
  # `#recorded?` / `#resolved?` / `#any?` in the right order, because that reassembly is exactly what
  # the ⭐ section above says a reader should not have to perform: `:no_runs`, `:unrecorded`,
  # `:unresolved` and `:ranked` are one blank panel and four different things to say about it, and
  # only the last of them may be rendered as "nothing in this suite is slow". {SpecDirectoryWindowGrowth}
  # exposes its own for the same reason and the views `case` on it.
  #
  # The predicates below are kept beside it rather than replaced by it: they are what the states are
  # DEFINED in terms of, and a surface asking only "is there anything to draw" should not have to
  # enumerate three symbols to find out.
  attr_reader :state

  # The branch every figure here was drawn on, and the one the panels around it are drawn on.
  # Runtimes compared across branches are runtimes of different code, so the window is
  # branch-anchored exactly as those are.
  attr_reader :branch

  # How many runs the window holds — the denominator of every "seen in N of M runs" on a row.
  attr_reader :run_count

  # The run the candidates were taken from, and therefore the run that decided WHICH tests are here
  # at all. Named rather than implied, because the ⭐ partition above is a fact about the list that
  # the reader cannot recover from the rows.
  attr_reader :anchor_run

  # How many rows the anchor run wrote, and how many of them carry no durable identity and were
  # therefore excluded from the ranking. Rows, not tests — an unresolved row is precisely a row this
  # object cannot say WHICH test it belongs to.
  #
  # ⚠️ **Counted over the anchor run and never over the repository**, and that scoping is
  # load-bearing rather than incidental. `SpecObservation.identity_presence_in` carries the warning
  # this obeys: SPGD-367 leaves a failed embed's `spec_identity_id` NULL **forever**, so a
  # repository-wide exclusion count is monotonic in a way it must not be — a suite whose every
  # current test resolves cleanly would go on reporting a growing count of exclusions from runs long
  # past. The figure here is a fact about the population this ranking was drawn from, which is the
  # only population an exclusion count can honestly be stated over.
  #
  # `nil` — never `0` — in `:no_runs`, where no read happened. See `UNREAD`.
  attr_reader :recorded_count, :unresolved_count

  # How many identities the anchor run holds IN TOTAL before the cap, and how many of its resolved
  # rows carried a duration out of how many there were.
  #
  # `nil` in every state that returned before the candidate step, which is every state but
  # `:ranked`. See `UNREAD`.
  attr_reader :candidate_count, :resolved_count, :timed_count

  # The ranking, slowest first — one row per durable test, its wall clock summed over the window.
  attr_reader :rows

  # Whether the anchor run wrote per-example rows AT ALL — the question that decides whether this
  # panel has anything to discuss rather than what it says. A repository whose CI has never sent
  # per-example detail has no runtime history at this grain, and the sibling panels draw the same
  # line with their own `recorded?`.
  def recorded? = recorded_count.to_i.positive?

  # ⭐ Whether the anchor run's rows have been MATCHED to durable tests yet — the Vacuous Green gate,
  # and the state that must never be served as an empty ranking.
  #
  # {Ingest::IdentityResolutionJob} runs asynchronously and the ingest controller's own header says
  # every reader of the embeddings trails a run that just landed. So "this run's tests have not been
  # identified yet" is a normal state lasting seconds, and rendered as an empty list it reads as
  # "nothing in this suite is slow" — which is "nobody told us" wearing the spelling of "everything
  # is fast". Only `#any?` may be read as the second, and only behind this.
  def resolved? = resolved_count.to_i.positive?

  # Whether any of the anchor's rows were excluded from the ranking for having no durable identity.
  # {NearDuplicateClusters} names the same disclosure with the same words one read over.
  def excluded_unresolved_rows? = unresolved_count.to_i.positive?

  def any? = rows.any?

  # How much of the ranked population carried a timing, rendered — through `.coverage_fraction`, the
  # single seam every one-sided coverage label on this application is spelled through, so no two
  # grains can state the same coverage in two prose inventions that agree today.
  #
  # The denominator is the anchor's RESOLVED rows and not its recorded ones: `#unresolved_count` is a
  # separate exclusion with a separate sentence, and folding the two into one fraction would report a
  # timing gap for rows that were dropped before timing was ever asked about.
  def coverage_label = SpecObservation.coverage_fraction(timed_count, resolved_count)

  # Every resolved row of the anchor carried a duration — the state worth SAYING rather than leaving
  # to be inferred from two equal numbers, exactly as {SlowestExamples} says it one grain down.
  def complete? = resolved? && timed_count == resolved_count

  # Resolved rows of the anchor that carried no duration. Not a defect: an example that never ran has
  # no duration to report, so a nil is a faithful record.
  def untimed_count = resolved_count.to_i - timed_count.to_i

  # Identities the anchor run holds that the ranking never examined, because the cap bit. A capped
  # list that does not disclose its cap is read as the whole story — the lie by omission
  # `UnstableTests#truncated?` and `SpecFileDurations#truncated?` both refuse.
  def truncated? = candidate_count.to_i > rows.size

  def unexamined_count = candidate_count.to_i - rows.size

  # One durable test, across the whole window — how long it took in total, how much of the window it
  # was seen in, and every description and file it wore while it was.
  Row = Struct.new(:spec_identity_id, :total_seconds, :recorded_count, :timed_count, :run_count,
                   :slowest_seconds, :names, :file_paths, keyword_init: true) do
    # Slowest first, and a test nobody timed is NOT a test that cost nothing: the nil flag leads the
    # key rather than the total being coerced to zero, which is the `DESC NULLS LAST` rule
    # {NearDuplicateClusters} and `.file_durations_in` both sort by. `recorded_count` breaks the tie
    # and the identity breaks that one, so a repository whose tests total equally has one stable
    # order rather than one the planner picks afresh per request.
    def sort_key = [total_seconds.nil? ? 1 : 0, -(total_seconds || 0.0), -recorded_count,
                    spec_identity_id]

    # This test was recorded under more than one spec file across the window — ⭐ **the moved test,
    # visible**. Per the project's semantic-identity rule a test that moved is the same test and its
    # history follows it, so this is the guarantee being kept rather than an anomaly; the reader is
    # told because a history that spans two files is a fact about where to go looking.
    def moved? = files_seen.size > 1

    # Its DESCRIPTION changed across the window while its identity did not — a reword close enough
    # in meaning that {Ingest::IdentityResolver} matched it to the same test above
    # `SpecIdentity::MATCH_SIMILARITY`. The same disclosure as `#moved?` on the other axis, and the
    # one {UnstableTests} structurally cannot make: grouped on `name`, a rename is two tests there.
    def renamed? = descriptions.size > 1

    # Whether anything timed this test at all. A row that reaches the list untimed is ordinary — see
    # `.slowest_identity_candidates_in` on why untimed groups are kept — and this is what keeps its
    # blank duration from being read as a zero.
    def timed? = timed_count.positive?

    # Rows of this test's history that carried no duration, and therefore are not in its total.
    def untimed_count = recorded_count - timed_count

    # The wall clock this test cost across the window, rendered — "not reported" and never `0.00s`
    # for a group nothing timed, which is what `.humanized_duration` exists to keep straight.
    def duration_label = SpecObservation.humanized_duration(total_seconds)

    # The single longest run of it. Beside the total because 60 seconds is one minute-long test or
    # sixty one-second runs of a cheap one, and a ranking ordered on the sum alone cannot tell the
    # reader which they are looking at.
    def slowest_label = SpecObservation.humanized_duration(slowest_seconds)

    # How much of its own history carried a timing — always the fraction, through the same seam the
    # object above uses, because "9" in a column of "9 of 12" reads as nine of something unstated.
    def coverage_label = SpecObservation.coverage_fraction(timed_count, recorded_count)

    # How much of the window this test was seen in. The denominator is passed rather than held: a
    # row does not know the window, and a row that invented one would be the drift this object's
    # class comment exists to refuse.
    def appearance_label(window_run_count) = "#{run_count} of #{window_run_count}"

    # This test ran more than once in at least one run of the window — a table-driven loop, a shared
    # example group, or two verbatim-identical tests, which {NearDuplicateClusters} records resolve
    # to ONE identity by both the unique text digest and the resolver's cosine-1.0 match. Disclosed
    # because it is what separates "slow in twelve runs" from "run three times in each of four".
    def repeated_within_run? = recorded_count > run_count

    # The descriptions and files this test was seen wearing, sorted so two rows carrying the same set
    # read the same way. `Array()` because both aggregates are `ARRAY_AGG(…) FILTER (…)`, which is
    # SQL NULL rather than an empty array for a group with nothing to collect — a nil the caller
    # would otherwise have to know about at every call site.
    def descriptions = Array(names).sort

    def files_seen = Array(file_paths).sort
  end
end
