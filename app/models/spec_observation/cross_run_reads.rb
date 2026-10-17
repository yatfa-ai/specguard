# frozen_string_literal: true

# THE CROSS-RUN READS OF `SpecObservation`, MOVED OUT WHOLE — the eleven class methods that answer a
# question about a WINDOW of runs (or one identity's whole history) rather than about one run's rows:
# `window_outcome_reporting`, `unstable_identity_candidates_in`, `unstable_outcome_composition_in`,
# `unnamed_row_count_in`, `unresolved_row_count_in`, `outcome_sequence_in`, `identity_presence_in`,
# `declared_layers_by_identity`, `slowest_identity_candidates_in`, `identity_duration_composition_in`
# and `identity_run_durations_in`. `SpecObservation` `extend`s this module, so every caller keeps
# spelling them `SpecObservation.<method>` and the receiver is still the model class (`where`,
# `sanitize_sql_array`, `connection` and the constants resolve as before).
#
# MOVE ONLY. Every method body and comment below is byte-identical to what it was in
# `app/models/spec_observation.rb`; the sole code edit is `def self.x` -> `def x` (plus the extra
# indent), and the emitted SQL did not change. The comments still say "above", "below" and `{.foo}`,
# and those coordinates are RELATIVE TO THE OLD FILE — they were not rewritten, so read a position
# word as pointing into `SpecObservation`, not into this module.
#
# THE CONSTANTS STAY ON `SpecObservation`. This module is nested lexically inside the class, so the
# unqualified `SLOWEST_LIMIT`, `UNSTABLE_CANDIDATE_LIMIT`, `WINDOW_OUTCOME_REPORTING_SQL`,
# `UNSTABLE_COMPOSITION`, `UNSTABLE_TEST_RUNS_LIMIT`, `UNSTABLE_TEST_RUN_POPULATION_COUNTS` and
# `IDENTITY_DURATION_COMPOSITION` resolve exactly as they did, and a `stub_const("SpecObservation::...")`
# in a spec still bites because the lookup happens at call time. `in_declared_layer` and
# `declared_layer_predicate` stay on the model too (single-run reads use them) and are reached
# through the same receiver.
class SpecObservation < ApplicationRecord
  module CrossRunReads
    # @return [Hash{Symbol=>Integer}] `runs_with_rows` and `runs_reporting_outcomes`, both counted in
    #   runs of the window handed in, never in rows.
    def window_outcome_reporting(run_ids)
      return { runs_with_rows: 0, runs_reporting_outcomes: 0 } if run_ids.empty?

      row = connection.select_one(sanitize_sql_array([WINDOW_OUTCOME_REPORTING_SQL, { run_ids: run_ids }]))

      { runs_with_rows: row["runs_with_rows"].to_i, runs_reporting_outcomes: row["runs_reporting_outcomes"].to_i }
    end

    # Step one of two: the durable tests that recorded a FAILURE somewhere in the window — the only
    # identities whose outcome can have changed within it, since a test that never failed here has
    # nothing to have changed from.
    #
    # This is the read `index_spec_observations_on_test_run_id_and_outcome` was built for and which
    # `COVERAGE_COUNTS` above declines to use, in as many words: *"that index is built for NARROWING
    # to the failures — the 'which tests failed' list a later slice will want"*. This is that later
    # slice, and the narrowing is what makes the whole panel affordable. Grouping the window's rows
    # by identity directly is 600,000 rows aggregated per page load at the design point; grouping
    # only the failures is a scan of the failures.
    #
    # Nothing correct is lost. A test that reported only non-failing outcomes across the window may
    # well have varied — `pending` one run and `passed` the next — and that variance is deliberately
    # out of this panel's scope, which the panel states rather than leaves to be discovered.
    #
    # GROUPED ON `spec_identity_id`, on the precedent `.slowest_identity_candidates_in` set for the
    # duration axis and for the same reason SPGD-700 moved that read: an annotated test whose
    # description was reworded mid-window is ONE test here — the identity `Ingest::IdentityResolver`
    # kept across the reword — rather than two half-histories. A row with no identity is excluded
    # HERE because a null cannot be matched to itself across runs, and how many rows that excludes
    # is a separate question, asked by `.unresolved_row_count_in` and stated on the panel — silently
    # dropping them is the reading this must not produce. An UNANNOTATED test is keyed by its
    # description's identity (`signal_source: "name"`), so a reword still starts a new history there
    # — owner-settled, and unchanged by this read.
    #
    # == The ordering, and what the cap therefore keeps
    #
    # Fewest failures first. The cap is only ever reached by a window in which more than
    # `UNSTABLE_CANDIDATE_LIMIT` distinct identities failed — a suite that has gone broadly red —
    # and in that window the identities that failed in EVERY run are precisely the ones whose
    # outcome did not change. Keeping the least-failing end of the list therefore keeps the end this
    # panel can still say something true about, and `spec_identity_id` breaks ties so the kept set
    # is stable between two requests rather than whatever the planner returned first.
    #
    # `COUNT(*) OVER ()` is evaluated AFTER `GROUP BY` and BEFORE `LIMIT`, so it counts candidate
    # IDENTITIES and counts all of them however few are returned — the truncation-disclosure shape
    # `#file_durations_in` documents at length, riding back on every row for no second round trip.
    #
    # @return [Array<Array>] `[spec_identity_id, candidate_count]` per kept identity, where
    #   `candidate_count` is the same figure on every row: how many identities failed in the window
    #   in all.
    #
    # == `layer:` (SPGD-1755)
    #
    # With a {DECLARED_LAYER_KEYS} member the FAILED rows are narrowed through {.in_declared_layer} — the
    # one predicate {.slowest_identity_candidates_in} narrows through, never retyped — BEFORE the group,
    # the order and the cap. So an identity is a candidate under `request` exactly when it failed in at
    # least one example declared `request`, the 200 cap is applied to THAT population (a window broadly
    # red in `unit` cannot cut the wanted layer out), and the `COUNT(*) OVER ()` figure counts the layer's
    # candidates. The ordering counts failures WITHIN the narrowed rows, which is what "fewest failures
    # first" means for the population being ranked. `nil` — the default — is byte-identical SQL to before
    # the keyword existed. The composition step is deliberately NOT narrowed: see `UnstableTests.for`.
    #
    # @param layer [String, Symbol, nil] a {DECLARED_LAYER_KEYS} member; `KeyError` otherwise.
    def unstable_identity_candidates_in(run_ids, limit: UNSTABLE_CANDIDATE_LIMIT, layer: nil)
      return [] if run_ids.empty?

      in_declared_layer(where(test_run_id: run_ids, outcome: "failed"), layer)
        .where.not(spec_identity_id: nil)
        .group(:spec_identity_id)
        .order(Arel.sql("COUNT(*) ASC"), Arel.sql("spec_identity_id ASC"))
        .limit(limit)
        .pluck(Arel.sql("spec_identity_id"), Arel.sql("COUNT(*) OVER ()"))
    end

    # Step two of two: how each candidate identity behaved across the whole window — over the
    # candidates only, which is what keeps this off the whole window's rows.
    #
    # GROUPED ON `spec_identity_id` and, like `.identity_duration_composition_in`, it carries NO
    # `repository_id` predicate — and the omission is deliberate for that read's own stated reason:
    # the index here is on `spec_identity_id` alone, so a repository predicate buys this read no
    # index and risks costing it the one it needs — the planner would be offered
    # `index_spec_observations_on_repository_id` as an alternative to the identity index this bound
    # depends on. Tenancy is carried by the arguments instead, and structurally: the identity ids
    # come from `.unstable_identity_candidates_in` over runs already scoped to this repository, and a
    # `spec_identity` is `repository_id`-scoped, so the ids handed in are this repository's own.
    #
    # == What it costs, MEASURED rather than assumed
    #
    # The same bitmap shape the sibling identity read measured and accepted: the index is on
    # `spec_identity_id` ALONE, so the window predicate arrives as a FILTER after the fetch rather
    # than as an index condition that narrows it. The bound is **candidates × the runs those
    # identities appear in at all**, NOT `limit × window` — pinned in the certification the same way
    # the sibling pins it, by SHRINKING THE CANDIDATE LIST and measuring again rather than by
    # asserting one ceiling. That leaves it bounded by RETENTION: `BRANCH_RETENTION_RUNS` caps a
    # branch's history at 60 runs, so a candidate's rows are capped whatever window is asked for.
    #
    # @return [Array<Array>] `[spec_identity_id, *UNSTABLE_COMPOSITION.values]` per identity, in that
    #   order.
    def unstable_outcome_composition_in(run_ids:, spec_identity_ids:)
      return [] if spec_identity_ids.empty? || run_ids.empty?

      where(test_run_id: run_ids, spec_identity_id: spec_identity_ids)
        .group(:spec_identity_id)
        .pluck(Arel.sql("spec_identity_id"),
               *UNSTABLE_COMPOSITION.values.map { |sql| Arel.sql(sql) })
    end

    # How many rows of the window carried no description at all — the figure the panel states when it
    # excludes them.
    #
    # A null `name` is not a test this read can follow across runs: two nulls in two runs are not
    # known to be one example, so they are dropped from the matching rather than pooled. Dropping
    # them silently is the failure mode — a panel that examined a tenth of the window and said
    # nothing about the other nine is a claim about a population it did not read. `Ingest::Payload`
    # refuses a spec carrying neither intent nor name, but `Ingest::SpecSignal` records that
    # pre-validator rows exist, and an annotated spec from a producer sending no name stores a null
    # here today.
    #
    # `repository_id` leads for the same reason as above: `WHERE repository_id = ? AND name IS NULL`
    # walks `index_spec_observations_on_repository_id_and_name` — a btree indexes its nulls — so the
    # count costs what the unnamed rows cost and not what the window does.
    def unnamed_row_count_in(repository_id:, run_ids:)
      return 0 if run_ids.empty?

      where(repository_id: repository_id, test_run_id: run_ids, name: nil).count
    end

    # How many rows of the window reached no durable identity — the sibling exclusion of the count
    # above, for the identity-grained matching `UnstableTests` now does. Same signature, same window
    # scoping, stated beside the window read it captions: two counts of the same grain, one per
    # column the matching can be denied by.
    #
    # A null `spec_identity_id` is not a test this read can follow across runs: an unresolved row in
    # one run and an unresolved row in another are not known to be one example, so they are dropped
    # from the matching rather than pooled. Dropping them silently is the failure mode the count
    # above refuses for its own nulls, and the same refusal is made here.
    #
    # ⚠️ Deliberately WINDOW-scoped and never repository-wide, on the objection
    # `.identity_presence_in` records and this read does NOT cross: SPGD-367 leaves a failed embed's
    # `spec_identity_id` NULL forever, so a repository-wide count is monotonic in a way an exclusion
    # must not be. This window is `Repository#suite_size_trajectory` — the last
    # `TRAJECTORY_LIMIT` runs of one branch, sliding — so an old NULL row LEAVES the window as newer
    # runs arrive and the count cannot grow without bound. It counts what this window's matching
    # actually had to drop, which is the honest figure and the property the count above already has
    # for its own nulls. That is also why this is a sibling of `.unnamed_row_count_in` rather than a
    # widening of `identity_presence_in`: that method is single-run for single-run consumers, and it
    # stays that way.
    #
    # Both partial indexes carrying `spec_identity_id IS NULL` lead on `repository_id`, so the null
    # range is reached through them — but ⚠️ neither carries `test_run_id`, so the window predicate is
    # a FILTER, not an index condition. That is the same measured-and-accepted shape
    # `.identity_duration_composition_in` documents for its own window predicate; certified the same
    # way in the plan specs rather than assumed.
    def unresolved_row_count_in(repository_id:, run_ids:)
      return 0 if run_ids.empty?

      where(repository_id: repository_id, test_run_id: run_ids, spec_identity_id: nil).count
    end

    # ONE description's rows across a window of runs, IN WINDOW ORDER — the rung below
    # `.unstable_outcome_composition_in`, and the axis that read has to destroy to do its own job.
    #
    # The composition is `COUNT`s and `ARRAY_AGG(…)` under `GROUP BY spec_identity_id`: one row per
    # durable test for the whole window, which is exactly right for a RANKING and is why nothing here
    # changes it. What it cannot say is WHEN. "Failed in 4 of 30 runs" is the same pair of integers
    # whether those four were the last four — a regression, whose fix is to find the commit — or runs
    # 3, 11, 19 and 26 — flakiness, whose fix is somewhere else entirely. This read is the same rows
    # ungrouped, so the sequence the aggregate summed over is legible again.
    #
    # ORDERED BY THE WINDOW'S OWN ORDER, not by `created_at` and not by `id`. `array_position` over the
    # ids AS THEY WERE HANDED IN makes this sequence FOLLOW the window the caller already holds, so it
    # reads in the same direction as the `history` rows that same window produced and a reader walking
    # the two is walking them the same way. Ordering by `id` would be ordering by INGEST order, which
    # is the same series only while nothing is backfilled and no run is ingested out of order; ordering
    # by `created_at` would need a join to a table the caller has already loaded.
    #
    # SAME DIRECTION IS NOT SAME INDEX. The join key is the `test_run_id` / `commit_sha` ON THE ROW,
    # never its position: `history` holds one row per RUN and this holds one row per matching
    # OBSERVATION, and three ordinary shapes pull the two out of alignment. A run that recorded nothing
    # under this description contributes NO row — a test added mid-window, renamed, quarantined, or
    # living in a file one shard did not run — a description carried by two examples in one run
    # contributes TWO, and the cap takes rows off the END of the sequence as handed — which end that
    # is is the caller's orientation's to decide, not this read's (see below). Reading the run off the
    # index is precisely the manoeuvre that names the WRONG culprit commit, which is the one error this
    # drill-in cannot survive.
    #
    # WHICH END THE CAP TAKES OFF FOLLOWS THE WINDOW THE CALLER HANDS IN. This read orders by
    # `array_position` over the ids AS HANDED, so the cap's end is a property of the caller's
    # orientation and no sentence here may hardcode one — the method has exactly two callers today,
    # and their windows point in OPPOSITE directions:
    #
    # * `RepositoryWindowRankingSerializer#serialized_unstable_test_runs` hands the API window (`history_runs`,
    #   `Repository#recent_test_runs`) NEWEST first, so a truncated sequence keeps the RECENT runs
    #   and drops the old ones — the survivable direction: "it has failed since some point before
    #   this list starts" still names a regression.
    # * The web drill-in (`repositories#show`) hands the same thirty runs OLDEST first
    #   (`RunWindow.oldest_first` over `Repository#suite_size_trajectory`), so the cap there takes
    #   the NEWEST end — the end the regression reading is taken from. Truncation on that surface
    #   does not shorten the answer, it removes it, which is why that panel carries a cap alert and
    #   a reading sentence that withholds the regression branch
    #   (`UnstableTestsHelper#unstable_test_runs_capped_reading_sentence`) rather than treating the
    #   cap as a footnote.
    #
    # A comment (or a caller) that asserted either of these orders as THE order would be wrong
    # about the other surface — as an earlier version of this very paragraph was, for four days
    # after the web drill-in landed.
    #
    # `id ASC` breaks ties WITHIN a run, so a description carried by several examples in one run has
    # one stable order rather than one the planner picks afresh per request.
    #
    # Scoped by `repository_id` as well as by the window's runs, because it narrows on `name` — and
    # `repository_id` is the leading column of `index_spec_observations_on_repository_id_and_name`,
    # the only index on `name`, so without it there is no index to walk.
    #
    # == Query cost
    #
    # One statement, and CONSTANT IN THE SIZE OF THE SUITE — it reads one description's rows over at
    # most `Repository::TRAJECTORY_LIMIT` runs, never the window's rows and never the suite's. That is
    # the property that lets it sit under a ranking of 20,000 examples at all. Issued ONLY when the
    # parameter was sent. EXPLAIN-certified in `spec/models/spec_observation_spec.rb` beside the
    # composition's own certification, on the same seed.
    #
    # The ordering INLINES the ids rather than binding them, which is what `array_position` over a
    # literal array costs and is worth naming: the SQL text then varies per window, so each distinct
    # window is its own entry in the connection's prepared-statement cache rather than a re-bind of
    # one. That cache is bounded and LRU-evicting, and this read is issued only on an explicit ask, so
    # the price is an occasional re-prepare and not growth — but it is a price, and it is the reason
    # this ordering is not reached for by the reads that run on every request.
    def outcome_sequence_in(repository_id:, run_ids:, name:, limit: UNSTABLE_TEST_RUNS_LIMIT)
      return none if run_ids.empty?

      where(repository_id: repository_id, test_run_id: run_ids, name: name)
        .select(Arel.sql("spec_observations.*, #{UNSTABLE_TEST_RUN_POPULATION_COUNTS}"))
        .order(Arel.sql(sanitize_sql_array(["array_position(ARRAY[?]::bigint[], test_run_id)", run_ids])),
               id: :asc)
        .limit(limit)
    end

    # Whether ONE run's examples carry a durable identity at all, and how many of them do not — the
    # two facts a read grouped over `spec_identities` has to establish before anything it returns can
    # be read.
    #
    # The `spec_identities` grain's counterpart of `.description_presence_in`, and here for the same
    # reason that one exists: {NearDuplicateClusters} can only see examples that reached an identity,
    # and it excludes the rest *structurally* rather than in a WHERE clause — an observation with no
    # `spec_identity_id` is in no cluster because there is nothing to cluster it BY. No window over
    # that read could ever have counted them.
    #
    # `unresolved_count` is this grain's "rows with no resolvable text". {Ingest::IdentityResolver}
    # leaves exactly two kinds of row behind: one whose {Ingest::SpecSignal} is `:none`, which has no
    # text to embed and therefore no identity to have, and one whose embedding failed, which is left
    # unresolved on purpose so a later run can try again. Both are invisible to a cluster read, and a
    # panel that examined the resolved nine tenths of a suite and said nothing about the other tenth
    # is a claim about a population it did not read.
    #
    # `recorded_count` is what tells an empty cluster list apart from an empty suite. A repository
    # that ingested nothing and a repository whose every test reads differently from every other
    # produce the identical empty ranking, and rendering "nothing here is repeated" over the first is
    # *Vacuous Green* — "nobody told us" wearing the spelling of "there is no redundancy".
    #
    # == Scoped to the run, because the figures it is a caption FOR are
    #
    # {NearDuplicateClusters} weighs its clusters in one run's examples, so these two must be counted
    # over that same run's rows or the caption is a fraction whose halves were measured over different
    # populations — which is the property that object claims for itself. Repository-wide, the second
    # figure is also monotonic in a way it must not be: SPGD-367 leaves a failed embed's
    # `spec_identity_id` NULL forever, so a suite whose every current test resolves cleanly would go
    # on reporting a growing count of exclusions from runs long past.
    #
    # One aggregate rather than two round trips, for the reason `.coverage_in` gives: a caption
    # fetched separately from the list it describes is a claim with no structural reason to keep
    # agreeing with it.
    #
    # == `layer:` (SPGD-1726)
    #
    # With a layer the SAME statement also counts the run's rows that declared it, as two extra FILTER
    # aggregates (`layer_recorded_count`, `layer_unresolved_count`), so a layer-narrowed {SlowestTests}
    # can state its coverage fraction over ONE population — the layer's candidate read is the numerator,
    # so the denominator has to be the layer's resolved rows, not the whole run's — WITHOUT a fourth
    # statement: the gate still costs exactly one read. The predicate is {.declared_layer_predicate},
    # the one every layer-narrowed read here is built from. `recorded_count` / `unresolved_count`
    # stay the WHOLE run's (they decide the gate's state). `nil` — the default — selects exactly the two
    # original aggregates and returns exactly the two original keys.
    #
    # @return [Hash{Symbol=>Integer}] `recorded_count` and `unresolved_count`, both counted in rows —
    #   plus `layer_recorded_count` and `layer_unresolved_count` when a layer is asked.
    def identity_presence_in(test_run, layer: nil)
      columns = [Arel.sql("COUNT(*)"), Arel.sql("COUNT(*) FILTER (WHERE spec_identity_id IS NULL)")]
      if layer
        predicate = declared_layer_predicate(layer)
        columns << Arel.sql("COUNT(*) FILTER (WHERE #{predicate})")
        columns << Arel.sql("COUNT(*) FILTER (WHERE #{predicate} AND spec_identity_id IS NULL)")
      end
      counts = where(test_run_id: test_run.id).pick(*columns)

      result = { recorded_count: counts[0].to_i, unresolved_count: counts[1].to_i }
      result.merge!(layer_recorded_count: counts[2].to_i, layer_unresolved_count: counts[3].to_i) if layer
      result
    end

    # The DECLARED INTENT LAYERS of the examples that resolved to each of the named identities — the
    # read {NearDuplicateClusters}'s declared-layer cut is built on, and the reason that cut is a
    # report over stored declarations rather than a detector.
    #
    # `intent_layer` is the protocol's `layer`, validated at the door (`Ingest::Payload#validate_intent`
    # against the four-token enum) and stored per example exactly as declared —
    # {Ingest::ObservationRecorder#intent_attributes} is explicit that nothing infers it, and the
    # motivating case is on record there: a `layer: "request"` example living under `spec/models/`
    # stores `"request"`. This read adds nothing to that value and nothing to the codebase's shape:
    # no path-based inference, no default, no fallback — a member whose examples carry no layer is
    # ABSENT from the returned map, and absent is the undeclared state the census reports.
    #
    # == The grain is the identity's whole history, deliberately not one run's
    #
    # The census's weight figures are ONE run's and its membership spans every run; the layer is a
    # declaration, not a measurement, so it follows membership rather than weight. An identity the
    # weighed run did not observe — deleted, renamed, deselected — keeps the layer its examples
    # declared, which is what keeps such a member out of the undeclared group it would be misfiled
    # into if the read were scoped to the run. An identity whose declarations DISAGREE across its
    # examples (the same text annotated at two layers, or a layer corrected between runs) comes back
    # with every distinct value it declared, sorted: the census's rule for that member is to report it
    # under each layer it declared, because collapsing a disagreement to one value would be the guess
    # this read exists to make unnecessary.
    #
    # One indexed round trip over `index_spec_observations_on_spec_identity_id`, DISTINCT down to
    # `(spec_identity_id, intent_layer)` — a cluster's handful of identities never carry more rows
    # than their examples did, and the collapse happens in the database rather than in Ruby.
    #
    # @param identity_ids [Array<Integer>] the census cluster members to read. Empty in, empty out —
    #   a repository with no clusters asks no question of this table.
    # @return [Hash{Integer=>Array<String>}] identity id => its DISTINCT declared layers, sorted.
    def declared_layers_by_identity(identity_ids)
      return {} if identity_ids.empty?

      where(spec_identity_id: identity_ids)
        .where.not(intent_layer: nil)
        .distinct
        .order(:spec_identity_id, :intent_layer)
        .pluck(:spec_identity_id, :intent_layer)
        .each_with_object({}) do |(identity_id, layer), map|
          (map[identity_id] ||= []) << layer
        end
    end

    # Step one of two: WHICH durable tests a repository-grain ranking is going to be about — the
    # slowest identities of ONE run, with the coverage of the population they were ranked out of
    # riding back beside them.
    #
    # **The first read in this application to group on `spec_identity_id`**, and the reason the column
    # stopped being written-and-never-aggregated. `.slowest_in` above answers "the slowest examples in
    # this run" and stays on the near side of the model's own boundary in as many words; this is the
    # step that crosses it, and {SlowestTests} is what carries the crossing.
    #
    # == Why the candidates come from ONE run and not from the window
    #
    # The naive spelling of "the slowest tests in this repository" groups the whole window by identity,
    # which is 600,000 rows aggregated per page load at the 20,000-example design point — the arithmetic
    # `.unstable_identity_candidates_in` states for its own grain and refuses. So the narrowing happens first and
    # it happens here: ONE RUN's rows, reached through an index that leads with `test_run_id`, grouped
    # and capped. The window is only ever aggregated over the identities this step hands back.
    #
    # WHICH `test_run_id` index is left to Postgres, and the measured answer is not the one this
    # comment first claimed. `index_spec_observations_on_test_run_id_and_duration_seconds` is the
    # obvious candidate and the planner does not take it: the aggregate has to visit the heap for
    # `spec_identity_id` either way, so the wider index buys a whole-run grouping nothing and the
    # narrower `(test_run_id, outcome)` bitmap was measured to price better. `.file_durations_in`'s own
    # plan assertion documents exactly this — *"what matters for this criterion is that one run is read
    # through an index rather than by walking every run's rows"* — and the certification here asserts
    # that and not a cost tiebreak the planner is entitled to revisit.

    #
    # Anchoring on the newest run is a PARTITION AND NOT AN OVERSIGHT, and {SlowestTests} states it
    # rather than leaving it to be discovered: a test absent from the newest run — deleted, renamed
    # past its own identity, or simply not selected — is not in the suite being asked about, and a
    # ranking that resurrected it would be answering a question about a suite that no longer exists.
    #
    # == Untimed identities are KEPT, and the ordering is what makes that safe
    #
    # `.slowest_in` excludes untimed rows in SQL and its comment says why that exclusion is
    # load-bearing: `duration_seconds: :desc` is NULLS FIRST in Postgres, so a naive ordering heads a
    # list captioned "slowest" with the examples that did not run. That argument bounds an exclusion
    # for a read of RAW ROWS. This one aggregates, and `.file_durations_in` states the rule for that
    # shape instead: *"dropping untimed rows changes each surviving group's own POPULATION"* — an
    # identity carried by four examples of which two went untimed would report a total understating by
    # half and say nothing about it. So nothing is dropped, `NULLS LAST` disarms the hazard the
    # exclusion existed for, and every group carries `COUNT(*)` beside `COUNT(duration_seconds)` so the
    # surface states what it summed over. An identity nothing timed sorts last and renders as "not
    # reported" through `.humanized_duration`, never as a zero.
    #
    # == The two ride-alongs, and why they are windows over aggregates
    #
    # `COUNT(*) OVER ()` counts candidate IDENTITIES — evaluated after `GROUP BY` and before `LIMIT`,
    # so it counts all of them however few are returned. That is the truncation disclosure
    # `.unstable_identity_candidates_in` documents and `SlowestTests#truncated?` reports.
    #
    # `SUM(COUNT(duration_seconds)) OVER ()` is a window over an aggregate, which reads oddly and is
    # the point: it re-totals the per-identity timed counts back up to the RUN, so the numerator of the
    # coverage fraction the caption states is measured over the very rows this ranking was drawn from,
    # in the same round trip. Fetched separately it would be a figure with no structural reason to keep
    # agreeing with the list — the rule `SlowestExamples` states for its own caption.
    #
    # ⚠️ Its DENOMINATOR is deliberately NOT fetched here, and that absence is the correction of a
    # defect rather than an omission. This read once carried a `SUM(COUNT(*)) OVER ()` beside it to
    # count the run's resolved rows, and its comment claimed that was "never a second measurement" of
    # what `.identity_presence_in` counts. It was exactly that: this read's `WHERE spec_identity_id IS
    # NOT NULL` and that gate's `recorded_count - unresolved_count` are the SAME PREDICATE over the SAME
    # population, computed twice in two statements with no transaction around them. An ingest landing
    # between the two let a surface render "7 rows recorded, 1 excluded" beside "5 of 6 timed" — three
    # figures from two snapshots that do not add up, on an object whose whole claim is that its list and
    # its captions are one read. So the population is measured ONCE, at the gate, and {SlowestTests}
    # threads that figure through as the denominator. One measurement cannot disagree with itself.
    #
    # == `layer:` — ONE rule (SPGD-1726)
    #
    # With a layer, the candidates are the identities with AT LEAST ONE anchor-run example in that
    # declared layer ({.in_declared_layer}; `undeclared` = `intent_layer IS NULL`). The narrowing is on
    # the candidate STEP only: each candidate's row totals across the window stay the WHOLE durable
    # test's ({.identity_duration_composition_in} is unchanged), so a row's `declared_layers` may list
    # several layers when a test changed layer mid-window. Without it, if the anchor run's ten slowest
    # tests are all `system`, no `unit` or `request` test's cross-run cost could be seen at all.
    #
    # The two window figures ride the same statement and are evaluated after WHERE, so under a layer
    # they describe that layer's candidate population — the single-measurement rule holds (no second
    # count). A layer nothing declared returns `[]`, which is why a caller must not destructure
    # `.first` of a layer-narrowed read. `nil` — the default — leaves the SQL byte-identical.
    #
    # @param test_run [TestRun] the ANCHOR — normally the newest run of the window.
    # @param layer [String, Symbol, nil] a {DECLARED_LAYER_KEYS} member; `KeyError` otherwise.
    # @return [Array<Array>] `[spec_identity_id, candidate_count, timed_count]` per kept identity,
    #   where the last two are the same figures on every row.
    def slowest_identity_candidates_in(test_run, limit: SLOWEST_LIMIT, layer: nil)
      in_declared_layer(where(test_run_id: test_run.id), layer)
        .where.not(spec_identity_id: nil)
        .group(:spec_identity_id)
        .order(Arel.sql("SUM(duration_seconds) DESC NULLS LAST"), Arel.sql("spec_identity_id ASC"))
        .limit(limit)
        .pluck(Arel.sql("spec_identity_id"),
               Arel.sql("COUNT(*) OVER ()"),
               Arel.sql("SUM(COUNT(duration_seconds)) OVER ()"))
    end

    # Step two of two: how each candidate identity behaved across the whole window — over the
    # candidates only, which is what keeps this off the window's rows.
    #
    # == What it costs, MEASURED rather than assumed
    #
    # EXPLAIN (ANALYZE) over ten candidates, a six-run window and twenty runs of history, 300 rows per
    # run — the seed the certification in `spec/models/spec_observation_spec.rb` runs on:
    #
    #     Bitmap Index Scan on index_spec_observations_on_spec_identity_id   rows=200
    #     Bitmap Heap Scan   Filter: (test_run_id = ANY (…))                 rows=60, removed=140
    #
    # So the honest bound is **candidates × the runs those identities appear in AT ALL**, and not
    # candidates × the window — the index is on `spec_identity_id` ALONE, so the window predicate is a
    # FILTER applied after the fetch rather than an index condition that narrows it. 200 rows against
    # the window's 1,800, and against a whole-window group-by's 1,800; the ratio widens with the suite,
    # because the number this read follows is the candidate count and the number the naive spelling
    # follows is the row count.
    #
    # That leaves it bounded by RETENTION rather than by the window, which is a bound and worth naming
    # as one: `BRANCH_RETENTION_RUNS` above caps a branch's history at 60 runs, so a candidate's rows
    # are capped whatever window is asked for. It is also why the certification pins the bound by
    # SHRINKING THE CANDIDATE LIST and measuring again rather than by asserting one number — what has
    # to stay true is that the work follows the candidates, and a single ceiling would pass just as
    # happily on a read that had stopped being narrowed at all.
    #
    # A composite `(spec_identity_id, test_run_id)` index would turn that filter into an index
    # condition, and is deliberately NOT added: this ticket ships no migration, the measured read is
    # already three orders of magnitude off the shape it replaces at the design point, and an index
    # added on an argument rather than on a profile is the kind this table already carries two of.
    #
    # NO `repository_id` PREDICATE, and the omission is deliberate rather than an oversight. Both
    # identity-grained composition reads decline the predicate for the same reason: the index here is
    # on `spec_identity_id` alone, so a repository predicate buys this read no index and risks
    # costing it the one it needs — the planner would be offered
    # `index_spec_observations_on_repository_id` as an alternative to the identity index this bound
    # depends on. Tenancy is carried by the arguments instead, and structurally: a `spec_identity` is
    # `repository_id`-scoped and unique on `(repository_id, text_digest)`, so ids handed back by
    # `.slowest_identity_candidates_in` for a run of this repository are this repository's — which is
    # why {SlowestTests} validates that the run belongs to the repository, on {NearDuplicateClusters}'
    # precedent, rather than re-deriving the tenant here.
    #
    # @return [Array<Array>] `[spec_identity_id, *IDENTITY_DURATION_COMPOSITION.values]`, in that
    #   order. Unordered between groups — the ranking is {SlowestTests}', which sorts on the summed
    #   wall clock the sibling reads sort on and by their `NULLS LAST` rule.
    def identity_duration_composition_in(run_ids:, spec_identity_ids:)
      return [] if run_ids.empty? || spec_identity_ids.empty?

      where(test_run_id: run_ids, spec_identity_id: spec_identity_ids)
        .group(:spec_identity_id)
        .pluck(Arel.sql("spec_identity_id"),
               *IDENTITY_DURATION_COMPOSITION.values.map { |sql| Arel.sql(sql) })
    end

    # Step three of the cross-run ranking: each candidate identity's wall clock PER RUN of the window —
    # `SUM(duration_seconds)` grouped on `(spec_identity_id, test_run_id)` — so a caller can read the
    # two ENDPOINTS of a test's window (the oldest and newest run it appears in) without a series.
    #
    # Same candidates and same window run ids as `.identity_duration_composition_in`, and the same
    # conventions, for the same reasons (see that method's plan and arithmetic, which this read shares
    # because it is the same index scan with a finer GROUP BY):
    #
    # * NO `repository_id` predicate — the by-identity index drives it, and tenancy is carried by the
    #   arguments (`SlowestTests.validate_anchor!`).
    # * `[]` with no query when either list is empty.
    # * Bound: candidates × the runs those identities appear in. The result is at most one row per
    #   `(identity, run)`, i.e. ≤ `SLOWEST_LIMIT × window runs`, and it follows the candidate count,
    #   never the window's row count.
    #
    # ⚠️ PER-RUN SUM, not per-row: a table-driven test that ran three times in a run is one identity
    # and three rows, so the per-run figure is their sum — otherwise the first and latest endpoints of
    # a loop would compare one example against three. A run in which EVERY row of the identity was
    # untimed sums to SQL NULL, and that NULL is KEPT (never coalesced to zero): an untimed endpoint is
    # "not reported", not a free run.
    #
    # NOT ordered, and deliberately: `test_run_id` is not time order, so ordering here would invite the
    # caller to read the first and last tuple as the endpoints. The window's own run order decides
    # which run is oldest and which is newest, and that lives with the caller ({SlowestTests}).
    #
    # SPGD-1840 — the 4th column is that run's `MAX(duration_seconds)`: the single longest row of the
    # identity in that run. It rides the SAME grouped scan (one more aggregate over rows already being
    # read, so the tuple count and the query count are unchanged) and is what lets the caller NAME the
    # run that holds the window's MAX. The max of these per-run maxes is exactly the composition read's
    # `MAX(duration_seconds)`. `nil` — never zero — when nothing in that run was timed, like the sum.
    #
    # @return [Array<Array>] `[spec_identity_id, test_run_id, seconds, slowest_seconds]` per identity per
    #   run it appears in; both figures are `nil` when nothing in that run was timed.
    def identity_run_durations_in(run_ids:, spec_identity_ids:)
      return [] if run_ids.empty? || spec_identity_ids.empty?

      where(test_run_id: run_ids, spec_identity_id: spec_identity_ids)
        .group(:spec_identity_id, :test_run_id)
        .pluck(Arel.sql("spec_identity_id"), Arel.sql("test_run_id"), Arel.sql("SUM(duration_seconds)"),
               Arel.sql("MAX(duration_seconds)"))
    end
  end
end
