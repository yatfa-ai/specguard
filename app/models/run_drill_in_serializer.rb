# frozen_string_literal: true

# THE RUN-LEVEL DRILL-IN FAMILY OF `RepositoryOverview`, MOVED OUT WHOLE — the twelve `serialized_*`
# methods that turn one run's ask-dependent drill-in blocks into the JSON `latest_run` serves, plus
# the two intent helpers (`serialized_declared_intent`, `serialized_derived_intent`) they share. It
# follows the `RepositoryGrowthSerializer` / `RepositoryWindowRankingSerializer` precedent: a
# collaborator the overview owns one memoized instance of (`RepositoryOverview#drill_ins`), reaching
# back into it only for the asks. `LatestRunSerializer` is its one caller.
#
# MOVE ONLY. Every method body and comment below is byte-identical to what it was in
# `app/models/repository_overview.rb`; nothing about the emitted JSON, its key order or its query
# count changed. The comments still say "above", "below" and "this file", and those coordinates are
# RELATIVE TO THE OLD FILE — they were not rewritten, so read a position word as pointing into the
# overview, not into this class.
#
# ONE INSTANCE PER OVERVIEW: the overview memoizes it; do not build one per call.
#
# It reads no instance variable of the overview. What it reads back is exactly six asks, delegated
# privately below: `requested_limit`, `requested_layer`, `requested_spec_directory`,
# `requested_spec_file`, `requested_repeated_description` and `requested_unannotated_examples?`. It
# holds no `repository` and no `params` of its own and issues no SQL beyond what the moved bodies did.
class RunDrillInSerializer
  def initialize(overview:)
    @overview = overview
  end

  # WHICH FILE the run spent its wall clock in — the same decomposition `repositories#show` has
  # rendered since SPGD-275, served to the client that has no page to read.
  #
  # This is `LatestRunSerializer#serialized_shards`' argument one axis over, and the substitution
  # is exact. The scalars above say a run cost 253.75s; not one of them is a file, so an agent
  # reading only those cannot learn WHERE the suite is slow — it can learn that it is. And a shard
  # is not the answer: a shard is a CI partition, `TestRun#shard_durations`' own comment is explicit
  # that it is not a code area, and "shard 3 was slow" names a machine while
  # "spec/models/invoice_spec.rb was slow" names something a reader can go and edit.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query. `SpecFileDurations` is already
  # view-free — `repositories_controller.rb` is its only other caller — so the API and the panel
  # rank the same files in the same order off the same rows of the same run, which is this file's
  # governing rule at the top and the one thing a second copy of the query could not promise.
  #
  # `rows` MIRRORS `SpecFileDurations#rows` VERBATIM and re-sorts nothing, on the rule
  # `LatestRunSerializer#serialized_shard_rows` follows: the aggregate orders
  # `SUM(duration_seconds) DESC NULLS LAST, spec_file_path ASC`, and that NULLS LAST is load-bearing
  # rather than incidental — a re-sort here on a plain `desc` would put the file that reported
  # NOTHING at the head of a list whose whole contract is "heaviest first". Inheriting the order is
  # what makes `rows.first` and the panel's heaviest file the same file by construction instead of
  # by coincidence.
  #
  # STRUCTURED COUNTS, NOT PROSE, the rule `LatestRunSerializer#serialized_shards` states and
  # this block obeys one grain down. `Row#coverage_label` words this same coverage as `"4 of 12"`
  # and `#duration_label` words the total as `"1.23s"` / `"not reported"`; a machine-readable client
  # cannot act on either without parsing it. So `recorded_count` and `timed_count` go out as the
  # integers those sentences are built from and `total_seconds` as a raw float. This is also how the
  # honesty constraint is met PER ROW rather than only for the block: `SUM` skips NULLs silently, so
  # a file whose examples were half untimed reports a total covering half of it, and every row
  # states what its own total was summed over instead of leaving one caption to cover a list of
  # mixed coverage.
  #
  # `total_seconds` is `null`, NEVER `0.0`, for a file none of whose examples reported a timing —
  # `duration_seconds` above and `shards.machine_seconds` already follow this rule, and
  # `SpecObservation.file_durations_in` deliberately uses `pluck` over `group(...).sum` so the SQL
  # NULL survives the trip rather than being helpfully zeroed on the way. A measured `0.0` is a
  # measurement; "nobody reported" is not, and the row still carries its counts so a client can see
  # which it got.
  #
  # `file_count` IS NOT `rows.size`, and serving only the array would reintroduce the exact lie the
  # aggregate was widened to close. The list stops at `HEAVIEST_FILES_LIMIT`, so its own length
  # cannot tell "the 10 heaviest of 300" from "all 3 this run touched" — a truncated list silently
  # wearing the shape of a complete one. `COUNT(*) OVER ()` is evaluated after `GROUP BY` and
  # before `LIMIT` precisely so this figure comes back on every row of the same pass, which is also
  # why it cannot describe a different row set from the one listed.
  #
  # `limit` beside it is the bound that PRODUCED the list, so a client learns that it stopped
  # without knowing this constant. Read off `SpecObservation`'s own constant rather than restated
  # here, on the precedent `branches_window.run_count_limit` sets: the model's default is taken as
  # given, and a locally-bound fourth number would let the response claim a bound the query did not
  # apply. `file_count > limit` is how a client detects truncation, which is `#truncated?` without
  # this endpoint shipping the comparison instead of the operands.
  #
  # `null` — THE KEY STILL PRESENT — for a run that recorded no observation rows at all: one
  # ingested before SPGD-255, or one whose client sends no per-example detail. Never a zeroed
  # block, on `shards`' rule verbatim: a client tests one thing (`spec_files == null` → "this run
  # disclosed no per-example grain") rather than distinguishing an absent key from a null one, and
  # a `file_count: 0` beside an empty array would assert a run that touched no spec files.
  #
  # GATED ON `#recorded?` ITSELF — called, not re-spelled as `rows.any?` here. The object's own
  # answer to its own question: a group exists in that aggregate if and only if a row exists, so
  # the predicate and the emptiness of `rows` cannot come apart, and a controller re-spelling it
  # would be a second copy free to drift the day the presenter learns to hold rows it did not read.
  #
  # EXACTLY ONE EXTRA QUERY, on every run, recorded or not — and constant in the size of the suite.
  # `SpecFileDurations.for` issues `file_durations_in` unconditionally, so `#recorded?` is an answer
  # DERIVED from the read rather than a gate in front of it; there is no cheaper way to ask, since
  # no counter cache exists on `test_runs`. That is the honest cost and it is stated as constant
  # rather than minimal: one grouped aggregate behind
  # `index_spec_observations_on_test_run_id_and_spec_file_path`, EXPLAIN-certified in
  # `spec/models/spec_observation_spec.rb`, so a 20,000-example suite costs exactly what a
  # 40-example one does. It sits inside the budget `LatestRunSerializer#serialized_shards` states.
  def serialized_spec_files(test_run)
    limit = requested_limit || SpecObservation::HEAVIEST_FILES_LIMIT
    durations = SpecFileDurations.for(test_run, limit: limit, layer: requested_layer)

    return nil unless durations.recorded?

    body = {
      rows: durations.rows.map do |row|
        {
          path: row.path,
          total_seconds: row.total_seconds,
          recorded_count: row.recorded_count,
          timed_count: row.timed_count,
          # The file's own examples' DECLARED layers (`@intent`), never path-inferred; five keys,
          # measured zeros, summing to `recorded_count`.
          layer_counts: row.layer_counts
        }
      end,
      file_count: durations.file_count,
      # The APPLIED limit, never the ask verbatim: an over-large ask is clamped by the guard, and
      # `file_count > limit` is how a client detects truncation — a `limit` the response did not
      # honour would make that comparison lie in exactly the direction the field exists to prevent.
      # Beside `file_count`, counted before the LIMIT and exact, the two operands of the disclosure
      # travel together.
      limit: limit
    }
    # `?layer=` ranks the rollup by that declared layer's time, so every figure above is the layer's.
    # Echoed ONLY when asked — the key is ABSENT, never null, unasked, so an unasked or malformed-ask
    # body is byte-identical to before the parameter reached this block. A layer matching no files is
    # `rows: []` / `file_count: 0` with the block present; `nil` above still means the run recorded
    # no per-example rows.
    body[:layer] = durations.layer if durations.layer?
    body
  end

  # WHERE the wall clock went, by code AREA — the block above one rung up, and the same
  # decomposition `repositories#show` has rendered on its by-directory panel. Added BESIDE
  # `spec_files` rather than in place of it, on this endpoint's standing rule: a client reading
  # `spec_files` today reads the same key, type and values tomorrow.
  #
  # NOT DERIVABLE FROM THE BLOCK ABOVE, which is the whole reason it is served at all. That list
  # stops at `HEAVIEST_FILES_LIMIT`, so an agent holding it has ten files out of a run that may
  # have touched three hundred — and `SpecDirectoryDurations`' own comment states the arithmetic:
  # *"a directory holding forty files at two seconds each is eighty seconds of the run with not one
  # of its rows in that list. Concentration re-concentrates at every rung."* Summing the ten files
  # a client can see by their parent directory answers a different question from summing the run.
  # And a shard is not the substitute either — `TestRun#shard_durations`' comment is explicit that
  # a CI partition is not a code area.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query — this file's governing rule,
  # stated in full on `serialized_spec_files` above. `SpecDirectoryDurations` is view-free, so the
  # API and the panel rank the same areas in the same order off the same rows of the same run.
  #
  # Every rule `serialized_spec_files` states applies here unchanged and is NOT restated: the
  # `null`-with-the-key-present shape, the `#recorded?` gate, structured counts over labels,
  # `total_seconds` never coalesced to `0.0`, `directory_count` off the window function rather than
  # `rows.size`, and the inherited order. Read them there. They are one behaviour described once,
  # and a second copy here is a second thing to keep true.
  #
  # What the grain changes is only what each of those costs when it is got wrong, and every one
  # costs MORE here: an area is a bigger population than a file, so an all-untimed area rendered as
  # `0.0` is a bigger invented measurement, and NULLS FIRST would name it the heaviest area in the
  # suite rather than merely the heaviest file.
  #
  # EXACTLY ONE EXTRA QUERY, on every run, recorded or not — and constant in the size of the suite.
  # `SpecDirectoryDurations.for` issues `directory_durations_in` unconditionally, so `#recorded?` is
  # an answer DERIVED from the read rather than a gate in front of it; there is no cheaper way to
  # ask, since no counter cache exists on `test_runs`. It needs no index of its own: the read groups
  # on an EXPRESSION and narrows on a COLUMN, and only the second decides the access path, so
  # `index_spec_observations_on_test_run_id` serves it — EXPLAIN-certified at the 20-run seed in
  # `spec/models/spec_observation_spec.rb` rather than asserted here.
  def serialized_spec_directories(test_run)
    limit = requested_limit || SpecObservation::HEAVIEST_DIRECTORIES_LIMIT
    durations = SpecDirectoryDurations.for(test_run, limit: limit)

    return nil unless durations.recorded?

    {
      rows: durations.rows.map do |row|
        {
          path: row.path,
          total_seconds: row.total_seconds,
          recorded_count: row.recorded_count,
          timed_count: row.timed_count,
          # The third figure of the area-grain reading, served as the OPERANDS the panel states it
          # from and never as the density itself. `COUNT(DISTINCT name)` skips NULLs, so
          # `distinct_name_count` alone is a ratio a client would compute against the wrong
          # denominator — over `recorded_count`, which includes rows the count could not see, an
          # area whose producer sent no descriptions reads as total redundancy. `named_count` is
          # what it WAS counted over, so a client divides by the same figure the panel does and can
          # subtract to see what was excluded. No verdict here for the same reason there is none on
          # the Row: the reading is the client's.
          distinct_name_count: row.distinct_name_count,
          named_count: row.named_count,
          # What each area's examples DECLARED, as operands: one count per `SpecIntent::LAYERS`
          # member plus `undeclared` (`intent_layer IS NULL`), summing to `recorded_count`. Measured
          # zeros, never null, and no label or verdict — a layer is counted only where an annotation
          # declared it, never inferred from the directory.
          layer_counts: row.layer_counts
        }
      end,
      directory_count: durations.directory_count,
      # The APPLIED limit, never the ask verbatim — the same rule `serialized_spec_files` states
      # for its own `limit`, not restated here beyond noting the two must agree in kind: both are
      # clamped by the same guard, and both sit beside a count taken before the LIMIT.
      limit: limit
    }
  end

  # WHICH TESTS ARE SLOW — the per-EXAMPLE grain, and the one question the two blocks above are
  # structurally unable to answer. They rank populations; this ranks individuals, and an agent that
  # has learned `spec/models/` cost ninety seconds has no way to get from there to a test to open.
  # `repositories#show` has rendered this list since SPGD-266; it has never reached a client that
  # cannot read a panel.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query — this file's governing rule,
  # stated in full on `serialized_spec_files` above. `SlowestExamples` is view-free, so the API and
  # the panel rank the same examples of the same run in the same order, off the same two reads.
  #
  # OPERANDS, NEVER THE PANEL'S LABELS, and this grain is where that rule costs the most. Every row
  # this serializes has four label methods one call away — `SpecObservation#label`,
  # `#location_label`, `#duration_label`, `#outcome_label` — and each of them FOLDS A FALLBACK
  # STRING INTO THE VALUE ("not reported", `"path:line"`, `"1.5s"`). That is precisely the prose
  # this endpoint refuses: a client cannot subtract `"1.5s"` and cannot tell `#label`'s location
  # fallback from a test genuinely named after its own file. So:
  #
  #   - `name` is NULLABLE and serialized as `null` when absent, rather than substituted with
  #     `#label`'s location fallback. `Ingest::ObservationRecorder#attributes` writes it through
  #     `presence_of`, so a null is the honest record that the producer sent no description — and a
  #     client that wants the fallback can build it from the two path operands below.
  #   - `file_path` + `line_number` are the DEFINITION SITE and are served as two operands rather
  #     than as the joined string `#location_label` builds from them.
  #   - `spec_file_path` is the INCLUDING file, nullable, and it is what makes this block JOINABLE:
  #     it is the column the two rollups above aggregate on, so a client can carry a ranked test
  #     back to the rollup row it belongs to. `SpecObservation`'s "Two paths, two meanings" note is
  #     explicit that it and `line_number` are NOT one coordinate — keep all three distinct and let
  #     the client choose, rather than pairing two of them here.
  #   - `outcome` is a NULLABLE RAW STRING, echoed verbatim. `null` keeps its documented meaning
  #     "the client did not say" and must never be folded into `"passed"`; nothing platform-side
  #     validates the column (`Ingest::Payload` does not), so an unrecognised string is echoed too.
  #
  # `recorded_count` / `timed_count` / `limit` follow `serialized_spec_files` exactly — what the
  # ranking was taken over, and the bound that cut the list, read off `SpecObservation::SLOWEST_LIMIT`
  # rather than restated here.
  #
  # `reported_outcome_count` IS NOT SCOPE CREEP, and it is the one figure the by-file blocks have no
  # counterpart for. Outcome coverage OVER THE RUN is not derivable from the ten rows served: a
  # client seeing ten `null` outcomes cannot tell "this run reported no outcomes at all" from "these
  # ten happened to be silent", and only the first of those makes a zero `failed` count mean
  # silence rather than health. That is the Vacuous Green separation `SlowestExamples#outcomes_reported?`
  # exists for, and the count is already in hand at zero extra query cost — `SlowestExamples.for`
  # splats the whole of `SpecObservation::COVERAGE_COUNTS`. Its `failed_count` / `pending_count` /
  # `other_outcome_count` siblings are deliberately NOT served: they describe the run's outcome
  # composition, not this ranking's coverage, and belong with a run-level health block.
  #
  # `null` — with the key still present — for a run that recorded no observation rows, on `shards`'
  # rule verbatim, and never a zeroed block: a `recorded_count: 0` beside an empty array would
  # assert a run that ran no examples. GATED ON `#recorded?` ITSELF, called rather than re-spelled
  # as `rows.any?`: the predicate is `recorded_count.positive?` and separates "no rows" from "no
  # timings", and a run that recorded fifty examples and timed none of them has a real per-example
  # grain to disclose — with an empty ranking over it — which `rows.any?` would blank.
  #
  # EXACTLY TWO EXTRA QUERIES, on every run, recorded or not — and constant in the size of the
  # suite. `SlowestExamples.for` issues both unconditionally, so `#recorded?` is an answer DERIVED
  # from the reads rather than a gate in front of them: an indexed backward scan capped at
  # `SLOWEST_LIMIT`, and one aggregate over the same index's leading column, both behind
  # `index_spec_observations_on_test_run_id_and_duration_seconds` and both EXPLAIN-certified in
  # `spec/models/spec_observation_spec.rb`. This block issues the read the panel issues, unchanged,
  # so that certification transfers rather than needing to be repeated in a request spec.
  def serialized_slowest_examples(test_run)
    slowest = SlowestExamples.for(test_run, layer: requested_layer)

    return nil unless slowest.recorded?

    {
      # `?layer=` ASKED: the declared layer this whole block was narrowed to, echoed so the figures
      # below read as the LAYER's, not the run's — `recorded_count` / `timed_count` /
      # `reported_outcome_count` are then that layer's own counts (they equal `layer_counts[layer]` and
      # `layer_durations[layer].timed_count`, built from the same predicate) and `limit` is unchanged.
      # ABSENT — not `null` — when no layer was asked, so an unasked body (and a malformed ask, which
      # reads as no ask) is byte-identical to what this endpoint served before the parameter existed.
      # `recorded?` stays a RUN-level gate: a layer with no examples serves `rows: []` and
      # `recorded_count: 0`, never `null` — `null` still means "this run recorded nothing".
      **(slowest.layer? ? { layer: slowest.layer } : {}),
      rows: slowest.rows.map do |observation|
        {
          name: observation.name,
          file_path: observation.file_path,
          line_number: observation.line_number,
          spec_file_path: observation.spec_file_path,
          duration_seconds: observation.duration_seconds,
          outcome: observation.outcome,
          # THE LAYER THE TEST'S OWN ANNOTATION DECLARED — one of the four `open-test-intent` enum
          # tokens (`unit` / `integration` / `request` / `system`), or `null`.
          #
          # THIS IS THE COLUMN'S FIRST AND ONLY READER, AND IT SHIPPED WITH THE COLUMN ON PURPOSE.
          # `db/migrate/20260811120000_create_spec_identities.rb` refused the field with a condition
          # rather than a flat no — *"a column nothing reads is a column that will be read wrongly
          # later"* — so `intent_layer` was not allowed to exist without a caller. Serving it here
          # is that condition being met, not a convenience bolted onto a storage change.
          #
          # SERVED RAW, NEVER WORDED. The stored string is already a bounded token that
          # `Ingest::Payload#validate_intent` checked against the schema's enum before the run was
          # accepted, so a client can branch on it, group by it, and compare it across runs. Passing
          # it through a humanising helper the way `outcome` has `SpecObservation#outcome_label`
          # would turn a machine-readable axis into prose an agent has to parse back — and this
          # endpoint exists for the reader that cannot look at a panel.
          #
          # WHY THIS BLOCK AND NOT `unannotated_examples`. That block's population is BY DEFINITION
          # the rows carrying no layer, so serving the key there would be a column of guaranteed
          # nulls. This ranking spans annotated and unannotated rows alike — it ranks on duration and
          # filters on nothing else — so the key is informative on some rows and honestly null on
          # others, which is the only shape in which "which layers is this suite's slowest work in?"
          # is answerable at all.
          #
          # `null` IS A REAL ANSWER AND IS KEPT DISTINGUISHABLE FROM A VALUE — the key is always
          # present, never omitted for a row that has no layer. It carries TWO readings this block
          # cannot separate and must not pretend to: the example is unannotated (it declared no
          # layer, and the envelope requires `intent` to be ABSENT when `status` is `"unannotated"`),
          # or it was ingested before this column existed and cannot be given one retroactively. In
          # neither case is a default admissible: substituting a directory guess would serve an
          # inference in the field reserved for a declaration, and substituting `""` would make "not
          # declared" indistinguishable from a layer named by the empty string.
          intent_layer: observation.intent_layer,
          declared_intent: serialized_declared_intent(observation)
        }
      end,
      recorded_count: slowest.recorded_count,
      timed_count: slowest.timed_count,
      reported_outcome_count: slowest.reported_outcome_count,
      limit: SpecObservation::SLOWEST_LIMIT
    }
  end

  # WHICH DESCRIPTIONS ONE RUN RECORDED MORE THAN ONCE, ranked by the wall clock those examples cost
  # between them — the ⭐overcoverage reading `repositories#show` has rendered since SPGD-344,
  # carried here so it reaches a client that cannot read a panel.
  #
  # INSIDE `latest_run` rather than beside it, on the membership test the comment on
  # `unstable_tests` states in full: every key that block serves is a statement about ONE run's
  # rows, and "this test is unstable" is a statement about one test across several.
  # `RepeatedDescriptions.for` narrows both of its reads to a single `test_run_id`, so this is a
  # statement about one run's rows and belongs inside `latest_run` with every other block that
  # meets it.
  #
  # STATED AS A RULE, NOT AS A TALLY, on purpose. The claims above used to carry a count of the
  # run-grain blocks — accurate when written, falsified as each later block was added below them.
  # The paragraph directly below carries a count as well, and it stays accurate: it counts the
  # blocks positioned ABOVE this point, which nothing added below can change. That is the
  # discriminator, and the reason the rewrite stopped where it did — a count of set membership rots
  # when a member joins it, and a count of position above a fixed point does not. Every run-grain
  # block added after this one has landed below it.
  #
  # THE GRAIN IS THE DESCRIPTION, which is a grain none of the four blocks above can reach. They
  # roll a run's rows up by where the code LIVES — the example, its file, its area — and no
  # rollup of "where" can see that two of those rows claim to test the same thing. The measurement
  # existed nowhere before that panel: no read in this application groups examples by description
  # outside failures — the flakiness panel groups on `spec_identity_id`, and identity is not a
  # description — so on a green suite, the normal case, nothing grouped examples by description at
  # all.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query — this file's governing rule,
  # stated in full on `serialized_spec_files` above. `RepeatedDescriptions` is view-free, so the
  # API and the panel rank the same descriptions of the same run in the same order, off the same
  # two reads.
  #
  # OPERANDS, NEVER THE PANEL'S PROSE, and every row here has two label methods one call away.
  # `Row#duration_label` renders `"1.23s"` or `"not reported"` and `Row#coverage_label` renders
  # `"6 of 8"`; a client can subtract neither. So `total_seconds` is the raw float — `null`, never
  # `0.0`, for a group nothing timed, which `Row#timed?` exists to keep distinguishable — and
  # `recorded_count` / `timed_count` are the two integers that fraction is built from. `files_seen`
  # is served through the row's own accessor, which is `Array()`-normalized and sorted, so the
  # `ARRAY_AGG … FILTER` SQL NULL cannot leak into the JSON as a bare `null` element.
  #
  # `group_count` beside `limit`, on the rule `spec_files` states: `rows.size` cannot tell "the 10
  # costliest of 80" from "all 3", and `group_count` is the `COUNT(*) OVER ()` counted after the
  # `HAVING` and before the `LIMIT`, so it counts every repeated description however few come back.
  # `limit` is READ OFF `SpecObservation::REPEATED_DESCRIPTIONS_LIMIT` rather than restated here, on
  # the precedent `history_window.run_count_limit` and `slowest_examples.limit` set. The operands,
  # never `#truncated?` — this endpoint ships figures a client compares, not comparisons.
  #
  # THE THREE HONESTY FIGURES ARE THE POINT OF THE BLOCK, and they are why an empty `rows` here
  # carries more keys than an empty ranking one grain up. `#recorded?`, `#named?` and `#any?` are
  # three different facts — the object's class comment says so in those words — and an empty
  # ranking over a run that wrote NO rows, an empty ranking over a run whose producer sent no
  # descriptions, and an empty ranking over a suite whose every description is unique are the same
  # empty list. Only the first two are silence, and reporting any of them as "no redundancy here"
  # is *Vacuous Green*. So `recorded_count` says how many rows the run wrote, `unnamed_row_count`
  # says how many of them the grouping could not see (they are excluded in SQL, so no window over
  # that read could ever have counted them — hence the second query), and the client holds
  # `named_row_count`'s two operands without this endpoint shipping the subtraction.
  #
  # `repeated_recorded_count` / `repeated_timed_count` are the window pair, over the WHOLE repeated
  # population rather than over the head that fit, which is what keeps a truncated run from reading
  # as fully timed on the strength of ten rows.
  #
  # NO VERDICT KEY. A description carried by several examples is evidence of repetition AND the
  # ordinary shape of a table-driven loop or a shared example group; the object deliberately has no
  # `#redundant?` and this response has no counterpart. It presents, and does not judge.
  #
  # `null` — with the key still present — for a run that recorded no observation rows, on
  # `slowest_examples`' rule verbatim, and never a zeroed block: a `recorded_count: 0` beside an
  # empty array would assert a run that ran no examples. GATED ON `#recorded?` ITSELF, called
  # rather than re-spelled as `rows.any?`: a run that recorded five hundred examples whose every
  # description is unique has a real description grain to disclose, with an honest empty ranking and
  # a zero `group_count` over it, and `rows.any?` would blank exactly that run.
  #
  # RE-SORTED NOWHERE. The order is the aggregate's `SUM(duration_seconds) DESC NULLS LAST, name
  # ASC` — a group nobody timed sorts LAST rather than heading a list about what repetition cost.
  #
  # EXACTLY TWO EXTRA QUERIES, on every run, recorded or not — and constant in the size of the
  # suite. `RepeatedDescriptions.for` issues both unconditionally, so `#recorded?` is an answer
  # DERIVED from the reads rather than a gate in front of them: one grouped aggregate behind
  # `index_spec_observations_on_test_run_id`, and one two-column count over the same narrow. Both
  # are EXPLAIN-certified in `spec/models/spec_observation_spec.rb`, and this block issues the
  # panel's reads unchanged, so that certification transfers rather than needing to be repeated in
  # a request spec.
  def serialized_repeated_descriptions(test_run)
    repeated = RepeatedDescriptions.for(test_run)

    return nil unless repeated.recorded?

    {
      rows: repeated.rows.map do |row|
        {
          name: row.name,
          total_seconds: row.total_seconds,
          recorded_count: row.recorded_count,
          timed_count: row.timed_count,
          files_seen: row.files_seen,
          # The group's own examples' DECLARED layers (`@intent`), never path-inferred; five keys,
          # measured zeros, summing to `recorded_count`.
          layer_counts: row.layer_counts
        }
      end,
      group_count: repeated.group_count,
      recorded_count: repeated.recorded_count,
      unnamed_row_count: repeated.unnamed_row_count,
      repeated_recorded_count: repeated.repeated_recorded_count,
      repeated_timed_count: repeated.repeated_timed_count,
      limit: SpecObservation::REPEATED_DESCRIPTIONS_LIMIT
    }
  end

  # WHICH FILES ONE AREA HOLDS — the middle rung of area → file → example, and the one move an
  # agent holding every other key on this endpoint could not make. `spec_directories` above names
  # the ten areas the run spent its wall clock in and stops there; `spec_files` is a capped ten of
  # the run's own heaviest files, and `SpecDirectoryDurations`' comment states why that is not the
  # same list under another name — *"a directory holding forty files at two seconds each is eighty
  # seconds of the run with not one of its rows in that list"*. The heaviest AREA is exactly the one
  # whose files a by-file top ten cannot show. `slowest_examples` reaches the per-example grain only
  # for the ten examples that are slowest RUN-WIDE, so for every other area the sentence its own
  # comment opens with — *"an agent that has learned `spec/models/` cost ninety seconds has no way
  # to get from there to a test to open"* — was still true after that block shipped.
  #
  # INSIDE `latest_run` rather than beside it, on the membership test the comment on
  # `unstable_tests` states in full: every key this block serves is a statement about ONE run's
  # rows. `SpecDirectoryFiles.for` narrows to a single `test_run_id`, so it belongs with the other
  # five. And `latest_run` is not re-anchored by `?branch=`, so an area ask composes with a branch
  # ask without either touching the other. It IS re-anchored by `?commit_sha=`, and this drill-in
  # follows it there WITHOUT READING THE PARAMETER: both hang off the one `latest_test_run` memo, so
  # the rows here and the `latest_run` they are an area OF can never come from two different runs.
  # Which run that is, `run_anchor` says. It is the repository's newest one only on a default call,
  # and on an explicit ask this list is STILL the panel's: `RepositoriesController` reads
  # `?commit_sha=` through this same `RequestedCommitShaParam` — the comment beside its own include
  # is the corroboration — so both surfaces re-anchor on the run the client named.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query — this file's governing rule, stated
  # in full on `serialized_spec_files` above. `SpecDirectoryFiles` is view-free, so the API and the
  # panel list the same files of the same area of the same run, in the same order, off the one read.
  #
  # OPERANDS, NEVER THE PANEL'S LABELS, on the rule `serialized_repeated_descriptions` states.
  # `Row#duration_label` and `Row#coverage_label` are both one call away and both fold prose into a
  # value: an untimed file renders "not reported", which a client must receive as `null` rather than
  # as a string it would have to recognise, and `"1 of 3"` is two integers a client cannot subtract.
  #
  # `null` — with the key present — MEANS "YOU DID NOT ASK", and it is the one thing this key must
  # not spell the way its siblings do. Those are served unconditionally and gate on `#recorded?`;
  # copying that gate here would collapse two different facts into one spelling — *"you did not
  # ask"* and *"the area you asked about has no rows"* — which is precisely the collapse
  # `serialized_history` refuses for an unknown `?branch=`, where the ask is RESTATED beside a zero
  # rather than answered with somebody else's rows. So an ask that matched nothing gets the block
  # with `rows: []` and its `path` restated, and a client can tell the two apart because the second
  # never wears the first's spelling. An area a run recorded nothing for is an ordinary answer — a
  # stale bookmark, a directory deleted since, a typo — and never an error, as
  # `RequestedSpecDirectoryParam` argues for the malformed shapes it treats as no ask at all.
  #
  # `file_count` is the AREA's, off the read's `COUNT(*) OVER ()` and never `rows.size`, which is
  # the truncated figure — the rule `spec_files.file_count` states one grain up. `recorded_count`
  # and `timed_count` are the area's too, off the two `SUM(COUNT(...)) OVER ()` windows, so they
  # describe the population the list was cut from rather than the files that fit on the page. A
  # client that folded the serialized rows to re-derive either would be computing the page's figure
  # under the area's name, which is the figure `SpecDirectoryFiles#any_timed?` exists to refuse.
  # `limit` is READ OFF `SpecObservation::SPEC_DIRECTORY_FILES_LIMIT` rather than restated, on the
  # precedent every capped block here sets — it is its own constant and neither of the tens above.
  #
  # EXACTLY ONE ADDITIONAL QUERY WHEN ASKED, AND NONE WHEN NOT — which is where this key departs
  # from `spec_directories`, whose read is issued on every request so that `#recorded?` is an answer
  # derived from it. Here the gate is the ASK and it is decided before any query is issued, so a
  # client that never sends the parameter pays nothing for the key's existence. The read is bounded
  # by the size of the AREA rather than of the suite and needs no index of its own: it narrows on
  # `test_run_id` and adds an EXPRESSION predicate no index can serve, so
  # `index_spec_observations_on_test_run_id` serves it — EXPLAIN-certified at the 20-run seed in
  # `spec/models/spec_observation_spec.rb`, which is where a plan belongs.
  def serialized_spec_directory_files(test_run)
    return nil if requested_spec_directory.nil?

    files = SpecDirectoryFiles.for(test_run, requested_spec_directory)

    {
      # The ask, restated as the server read it — never echoed from the raw parameter, on
      # `history_window.branch`'s rule: a malformed shape is no ask at all and reaches no block, so
      # what is served here is always the path the rows were actually gathered under.
      path: files.path,
      rows: files.rows.map do |row|
        {
          path: row.path,
          # Nullable, never coalesced to `0.0`: a file whose every example went untimed is SQL NULL
          # out of the aggregate, and a zero there would assert a file that cost nothing.
          total_seconds: row.total_seconds,
          recorded_count: row.recorded_count,
          timed_count: row.timed_count,
          # The file's declared-layer operands: one count per `SpecIntent::LAYERS` member plus
          # `undeclared`, summing to the row's `recorded_count`. Measured zeros, never null.
          layer_counts: row.layer_counts
        }
      end,
      file_count: files.file_count,
      recorded_count: files.recorded_count,
      timed_count: files.timed_count,
      # The AREA's declared-layer operands, counted over the whole area before the file cap (so they
      # sum to `recorded_count` even where the rows do not). No path inference; measured zeros.
      layer_counts: files.layer_counts,
      limit: SpecObservation::SPEC_DIRECTORY_FILES_LIMIT
    }
  end

  # WHICH EXAMPLES ONE FILE HOLDS — the bottom rung of area → file → example, and the move an agent
  # holding every other key on this endpoint still could not make. The key above names the files of
  # one area and stops there; an agent that has walked `spec/models/` down to
  # `spec/models/order_spec.rb — 340 examples, six minutes` has learned WHICH file to open and has
  # nothing to open it with. Neither per-example block already here answers it: `slowest_examples`
  # reaches this grain only for the ten examples that are slowest RUN-WIDE — usually holding not one
  # row of the file that was opened — and `spec_files` is a capped ten RANKING of the run's heaviest
  # files rather than a listing of anything.
  #
  # INSIDE `latest_run` rather than beside it, on the membership test the comment on `unstable_tests`
  # states in full: every key this block serves is a statement about ONE run's rows.
  # `SpecObservation.in_file` narrows to a single `test_run_id`, so it belongs with the others. And
  # `latest_run` is not re-anchored by `?branch=`, so a file ask composes with a branch ask and with
  # an area ask without any of the three touching another. `?commit_sha=` is the one ask that DOES
  # move the anchor, and this drill-in moves with it unread — the file is always a file OF the run
  # `latest_run` named, because both read the single `latest_test_run` memo, and `run_anchor` names
  # that run. It is the repository's newest one only on a default call, and on an explicit ask this
  # list is STILL the panel's: `RepositoriesController` reads `?commit_sha=` through this same
  # `RequestedCommitShaParam`, so under an explicit ask the two surfaces agree — both re-anchor on
  # the run the client named rather than diverging.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query — this file's governing rule, stated
  # in full on `serialized_spec_files` above. `SpecFileExamples` is view-free apart from
  # `#coverage_label`, which is skipped here exactly as the rung above skips `Row#duration_label` and
  # `Row#coverage_label`, so the API and the panel list the same examples of the same file of the
  # same run, in the same order, off the one read.
  #
  # THE ROW SHAPE IS `serialized_slowest_examples`' EIGHT FIELDS, field for field, because this
  # endpoint's two per-example blocks describe the same rows of the same table and a client that
  # learned to read one must not have to learn a second shape to read the other. The seventh is
  # `intent_layer` (SPGD-851) and the eighth `declared_intent` (SPGD-1665); both arrived on the
  # run-wide ranking and reached this block through exactly that rule rather than because this block
  # asked for it — the field list below says so at the rows themselves. `duration_seconds`
  # is nullable and NEVER coalesced to `0.0`: an example this run recorded and did not time has no
  # duration to report — `Ingest::ObservationRecorder#attributes` writes the nil faithfully — and a
  # zero there would assert an example that cost nothing. Those rows are LISTED rather than
  # excluded, at the end of the list, which is the whole reason this block's population counts can
  # ride back on the rows at all where `slowest_examples`' had to be a second read.
  #
  # NO `reported_outcome_count`. `SlowestExamples` exposes one and this object does not, and the
  # difference is not an oversight to paper over with a re-derivation off the serialized rows: that
  # figure would be the PAGE's, computed under the file's name, which is the one thing every count
  # on this block is arranged to avoid.
  #
  # `null` — with the key present — MEANS "YOU DID NOT ASK", on the spelling the key above fixed and
  # for the same reason: the siblings are served unconditionally and gate on `#recorded?`, and
  # copying that gate here would collapse *"you did not ask"* and *"the file you asked about has no
  # rows"* into one answer. So an ask that matched nothing gets the block with `rows: []` and its
  # `path` restated — HTTP 200, never a 404, since a deleted spec file, a renamed one and a stale
  # bookmark are all ordinary ways to arrive here, as `RequestedSpecFileParam` argues in full.
  #
  # `recorded_count` and `timed_count` are the FILE's, off the two `COUNT(…) OVER ()` windows of
  # `SpecObservation::FILE_POPULATION_COUNTS` — evaluated after the WHERE and before the LIMIT, so
  # they describe the population the list was cut from rather than the examples that fit on the
  # page. A client that folded the serialized rows to re-derive either would be computing the page's
  # figure under the file's name. `limit` is READ OFF `SpecObservation::FILE_EXAMPLES_LIMIT` rather
  # than restated, on the precedent every capped block here sets — it is its own constant and
  # neither `SLOWEST_LIMIT` nor `SPEC_DIRECTORY_FILES_LIMIT`.
  #
  # EXACTLY ONE ADDITIONAL QUERY WHEN ASKED, AND NONE WHEN NOT, on the key above's rule: the gate is
  # the ASK and it is decided before any read is issued, so a client that never sends the parameter
  # pays nothing for the key's existence. The read is bounded by the FILE rather than by the suite
  # and rides `index_spec_observations_on_test_run_id_and_spec_file_path`, the composite index
  # EXPLAIN-certified for exactly this narrow in `spec/models/spec_observation_spec.rb`. Because
  # this block issues the read the panel issues, unchanged, that certification transfers rather than
  # needing to be repeated in a request spec.
  def serialized_spec_file_examples(test_run)
    return nil if requested_spec_file.nil?

    examples = SpecFileExamples.for(test_run, requested_spec_file)

    {
      # The ask, restated as the server read it — never echoed from the raw parameter, on
      # `history_window.branch`'s rule: a malformed shape is no ask at all and reaches no block, so
      # what is served here is always the path the rows were actually gathered under.
      path: examples.path,
      # THE SAME EIGHT FIELDS `serialized_slowest_examples` SERVES, AND THE REPETITION IS CHOSEN. The
      # two per-example blocks on this endpoint must agree field for field, and a shared
      # `serialized_example_row` would make that structural rather than asserted — the stronger
      # guarantee, and it is declined here for this file's standing reason: each block states its
      # own contract beside its own rows, and a field list extracted to a helper sits where neither
      # block's comment can explain why it holds what it holds. What enforces the agreement instead
      # is a `contain_exactly` over these names in each block's request spec, so a field added to
      # one and not the other goes red rather than shipping a client two per-example shapes.
      #
      # `intent_layer` is here BECAUSE OF THAT RULE, not because this block asked for it. It was
      # added to `serialized_slowest_examples` (SPGD-851) and the cross-block guard in
      # `repository_repeated_description_examples_spec.rb` went red — which is the guard working:
      # one shape, served by every block that describes these rows. It is the DECLARED layer, null
      # for an unannotated row and for one ingested before the column existed; see
      # `serialized_slowest_examples` for why it is served raw and never worded.
      rows: examples.rows.map do |observation|
        {
          name: observation.name,
          file_path: observation.file_path,
          line_number: observation.line_number,
          spec_file_path: observation.spec_file_path,
          duration_seconds: observation.duration_seconds,
          outcome: observation.outcome,
          intent_layer: observation.intent_layer,
          declared_intent: serialized_declared_intent(observation)
        }
      end,
      recorded_count: examples.recorded_count,
      timed_count: examples.timed_count,
      limit: SpecObservation::FILE_EXAMPLES_LIMIT
    }
  end

  # WHICH EXAMPLES SAY ONE THING — the drill-in out of `repeated_descriptions` above, and the last
  # ranking on this endpoint whose rows dead-ended. That block reports that a description is carried
  # by eight examples costing ninety seconds between them and names the files they ran in, and
  # `files_seen` is where it stops: a string array a client can read and cannot act on. Until this
  # key, writing SQL was the only way to learn WHICH eight, what each cost, where each sits and how
  # each ended.
  #
  # NOT REACHABLE FROM ANY OTHER KEY HERE, which is the whole reason it is served. `slowest_examples`
  # is the run-wide top ten and a group's members are usually absent from it entirely;
  # `spec_file_examples` over each path in `files_seen` is N unrelated lists, each capped at fifty by
  # DURATION, with no guarantee any of the group's members are in any of them — a two-file group
  # followed that way returns two lists of rows that need not include one row of it. The reason is
  # the one `serialized_repeated_descriptions` states above and this key inherits: the three rollups
  # name where the code LIVES, and no rollup of "where" can see that two of those rows say the same
  # thing.
  #
  # THE THIRD DRILL-IN AND NOT A FOURTH RUNG. `spec_directory_files` and `spec_file_examples` are
  # the middle and bottom of area → file → example, and this is not under either of them: it opens
  # a SENTENCE rather than a place, and its rows routinely span several files — which is precisely
  # the shape a reader came to see. A group whose three rows sit at consecutive line numbers in one
  # file reads as a table-driven loop; the same description at three unrelated sites reads as
  # something else, and nothing here decides which.
  #
  # INSIDE `latest_run` rather than beside it, on the membership test the comment on `unstable_tests`
  # states in full: `SpecObservation.with_description` narrows to a single `test_run_id`, so this is
  # a statement about ONE run's rows. And `latest_run` is not re-anchored by `?branch=`, so a
  # description ask composes with all three of the other asks without any of the four touching
  # another. The fifth ask is the exception and is meant to be: `?commit_sha=` re-anchors
  # `latest_run`, and this drill-in re-anchors with it without reading the parameter, because the
  # group is always a group WITHIN the run that one `latest_test_run` memo picked. `run_anchor` is
  # what names it. Only on a default call is that the repository's newest run, and these rows are
  # the panel's on an explicit ask too — `RepositoriesController` reads `?commit_sha=` through this
  # same `RequestedCommitShaParam`, so both surfaces re-anchor on the run the client named.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query — this file's governing rule, stated
  # in full on `serialized_spec_files` above. `RepeatedDescriptionExamples` is view-free apart from
  # `#coverage_label`, which is skipped here exactly as the two rungs above skip `Row#duration_label`
  # and `SpecFileExamples#coverage_label`: `"25 of 40"` is two integers a client cannot subtract.
  #
  # THE ROW SHAPE IS `serialized_slowest_examples`' EIGHT FIELDS, field for field, on the rule
  # `serialized_spec_file_examples` states: this endpoint's now THREE per-example blocks describe the
  # same rows of the same table, and a client that learned to read one must not have to learn a
  # second shape to read the others. `duration_seconds` is nullable and NEVER coalesced to `0.0` —
  # and at this grain an untimed row is often exactly the row a reader came for, because a test that
  # never ran is one way three examples come to say the same thing. Those rows are LISTED rather than
  # excluded, at the END of the list, which is what `with_description`'s `NULLS LAST` is for.
  #
  # NO CAPTION PREDICATES. The object exposes `#lists_untimed?`, `#truncated?`, `#complete?` and
  # `#any_timed?`, and every one of them is a COMPARISON between figures served below. This endpoint
  # ships the operands and lets a client word it — `recorded_count > rows.length` is `#truncated?`
  # without this block shipping the comparison instead of the two numbers it is drawn from.
  #
  # `recorded_count` and `timed_count` are the GROUP's, off the two `COUNT(…) OVER ()` windows of
  # `SpecObservation::DESCRIPTION_POPULATION_COUNTS` — evaluated after the WHERE and before the
  # LIMIT, so they describe the population the list was cut from rather than the examples that fit on
  # the page. On a truncated group neither is re-derivable from the serialized rows, which is the
  # point of serving them: a client that folded `rows` to count them would be computing the page's
  # figure under the description's name. `limit` is READ OFF
  # `SpecObservation::REPEATED_DESCRIPTION_EXAMPLES_LIMIT` rather than restated, on the precedent
  # every capped block here sets — it is its own constant and is neither `FILE_EXAMPLES_LIMIT` nor
  # `SPEC_DIRECTORY_FILES_LIMIT`.
  #
  # `null` — with the key present — MEANS "YOU DID NOT ASK", on the spelling the two keys above fixed
  # and for the same reason: the siblings are served unconditionally and gate on `#recorded?`, and
  # copying that gate here would collapse *"you did not ask"* and *"the description you asked about
  # has no rows"* into one answer. So an ask that matched nothing gets the block with `rows: []` and
  # its `name` restated — HTTP 200, never a 404, since a test renamed since, a description edited and
  # a stale bookmark are all ordinary ways to arrive here, as `RequestedRepeatedDescriptionParam`
  # argues in full.
  #
  # EXACTLY ONE ADDITIONAL QUERY WHEN ASKED, AND NONE WHEN NOT, on the two keys above's rule: the
  # gate is the ASK and it is decided before any read is issued, so a client that never sends the
  # parameter pays nothing for the key's existence. The read is bounded by the GROUP's run rather
  # than by the suite and rides `index_spec_observations_on_test_run_id`, EXPLAIN-certified for
  # exactly this narrow in `spec/models/spec_observation_spec.rb`. Because this block issues the read
  # the panel issues, unchanged, that certification transfers rather than needing to be repeated in a
  # request spec.
  def serialized_repeated_description_examples(test_run)
    return nil if requested_repeated_description.nil?

    examples = RepeatedDescriptionExamples.for(test_run, requested_repeated_description)

    {
      # The ask, restated as the server read it — never echoed from the raw parameter, on the rule
      # `path` follows on both sibling blocks: a malformed shape is no ask at all and reaches no
      # block, so what is served here is always the description the rows were actually gathered
      # under.
      name: examples.name,
      # THE SAME EIGHT FIELDS the two per-example blocks above serve, and the repetition is chosen for
      # the reason `serialized_spec_file_examples` states in full: each block states its own contract
      # beside its own rows, and what enforces the agreement is a `contain_exactly` over these names
      # in each block's request spec, so a field added to one and not the others goes red rather than
      # shipping a client three per-example shapes.
      #
      # `intent_layer` is here BECAUSE OF THAT RULE (SPGD-851): it was added to the run-wide ranking
      # and the cross-block guard in this block's own request spec — the one assertion that reads all
      # three shapes off a single response — went red until the field reached all three. The DECLARED
      # layer, null for an unannotated row and for one ingested before the column existed.
      rows: examples.rows.map do |observation|
        {
          name: observation.name,
          file_path: observation.file_path,
          line_number: observation.line_number,
          spec_file_path: observation.spec_file_path,
          duration_seconds: observation.duration_seconds,
          outcome: observation.outcome,
          intent_layer: observation.intent_layer,
          declared_intent: serialized_declared_intent(observation)
        }
      end,
      recorded_count: examples.recorded_count,
      timed_count: examples.timed_count,
      limit: SpecObservation::REPEATED_DESCRIPTION_EXAMPLES_LIMIT
    }
  end

  # WHICH TESTS CARRY NO `@intent` — the rows behind the product's stated primary adoption metric,
  # and until this key the one figure on either surface that could be reported and not opened.
  #
  # ⚠️ NOT "which tests SpecGuard cannot see", which is what this comment and this block's own
  # description said until SPGD-711. That population is `intent_readings.unreadable`, and it is far
  # smaller: most of the rows here carry a `Class#method behavior` description SpecGuard reads. Each
  # row's `reading` says which, and `unreadable_count` beside `recorded_count` is the only figure in
  # this block any "cannot see" sentence may be built on.
  #
  # `latest_run.total_specs` and `latest_run.annotated_specs` sit twenty lines above this key, and
  # `annotated_ratio` beside them. Their difference is what `repositories#show` used to render under
  # "Not visible to SpecGuard" as *"SpecGuard cannot see the other N tests"*, and a subtraction is the whole
  # answer a reader has ever been given: an agent told to raise annotation coverage receives
  # `annotated_ratio: 0.43` and cannot name ONE of the tests that number is about. Every other ranking
  # on this endpoint has a drill-down rung — `spec_directory` → files, `spec_file` → examples,
  # `repeated_description` → examples, `unstable_test` → runs — and this was the sole exception.
  #
  # THE COUNT AND THE LIST ARE ONE PREDICATE, WHICH IS WHY THE ROWS COME OFF `spec_observations.status`
  # AND NOT FROM ANYWHERE ELSE. `Ingest::Payload#annotated_specs` rejects `status == "unannotated"` and
  # its size becomes `annotated_specs_count`; `Ingest::ObservationRecorder#attributes` writes that same
  # string onto every row of the same delivery. So `recorded_count` here and `total_specs -
  # annotated_specs` above are one derivation evaluated twice rather than two figures that agree today
  # — the property this file demands of a count and its list everywhere else, and the reason this rung
  # needed no migration and no new data. `SpecObservation.unannotated_in` argues it in full, and the
  # reconciliation is pinned in `spec/requests/api/v1/repository_unannotated_examples_spec.rb` for an
  # UNSHARDED run: on a sharded one those counters are re-derived by SUM over `test_run_shards` while
  # these rows are what was actually stored, which is the same separation `serialized_spec_files`
  # states for its own denominator.
  #
  # THE WORKLIST CAN BE POINTED AT WHERE THE WORK IS, WITH THE TWO PARAMETERS THAT ALREADY NARROW
  # EVERY OTHER PER-EXAMPLE QUESTION HERE. Sent alone the flag answers the WHOLE RUN in one order,
  # capped, and a team adopting SpecGuard on the module they are actually touching could not ask for
  # its unannotated tests: they got a hundred rows from wherever `spec/` sorts first, and the only
  # route to `spec/services/` was to annotate every alphabetically-earlier example first — a hundred
  # at a time, each batch costing a CI run and a re-ingest. Sent WITH `?spec_file=` or
  # `?spec_directory=`, the population narrows to it — rows and `recorded_count` both — on the
  # `area → file → example` ladder those two parameters already are, and on the predicates this
  # application already owns: `where(spec_file_path: …)` and `DIRECTORY_EXPRESSION` compared for
  # EQUALITY, which is the IMMEDIATE PARENT and never a prefix, so `spec/models/orders` is its own
  # area rather than part of `spec/models`. See `SpecObservation.unannotated_in`, which argues the
  # predicates, the AND-ing of the pair and the absence of a precedence rule between them.
  #
  # THE TWO PARAMETERS DO NOT STOP OPENING THEIR OWN BLOCKS. They are read once, by the guards this
  # controller already includes, and each reaches its own drill-in beside this one — `?spec_file=` →
  # `spec_file_examples`, `?spec_directory=` → `spec_directory_files`. They do not reach equally far,
  # and the asymmetry is the point rather than a rounding: `?spec_directory=` alone carries on to the
  # two directory file-growth pairs as well, six served keys against `?spec_file=`'s two. It is that
  # ONE DRILL-IN EACH, not the growth pairs and not this block, that makes the empty answer here
  # reconcilable rather than ambiguous, and it is stated in full at the keys below.
  #
  # INSIDE `latest_run` rather than beside it, on the membership test the comment on `unstable_tests`
  # states in full: `SpecObservation.unannotated_in` narrows to a single `test_run_id`, so this is a
  # statement about ONE run's rows. And `latest_run` is not re-anchored by `?branch=`, so this ask
  # composes with the other four — narrowing on two of them and leaving the other two untouched, none
  # of the five re-anchoring another. `?commit_sha=` is the exception and is meant to be: it
  # re-anchors `latest_run`, and this drill-in re-anchors with it WITHOUT READING THE PARAMETER,
  # because both hang off the one `latest_test_run` memo and `run_anchor` names the run they landed
  # on. That matters more here than on its siblings — "what is still unannotated" is the question an
  # adopting repository asks after every push, so asking it of an older commit is the ordinary use
  # rather than the exotic one.
  #
  # THE ROW SHAPE IS SIX FIELDS AND DELIBERATELY NOT THE OTHER BLOCKS' EIGHT. The three per-example
  # blocks above agree field for field on purpose — `serialized_spec_file_examples` states why, and a
  # `contain_exactly` in each of their request specs enforces it — and this block is not a fourth
  # member of that set. Those three list examples a reader has come to MEASURE, so they carry
  # `duration_seconds` and `outcome`; this one lists examples a reader has come to OPEN AND EDIT, so it
  # carries what opens a file plus what SpecGuard already read of the row, and nothing else. `outcome`
  # would be worse than surplus here: an
  # unannotated example's outcome is a fact about the last run, and a worklist sorted for editing that
  # also whispers "this one failed" invites the reader to do the other job. The third and fourth withheld fields are
  # `intent_layer` (SPGD-851), and it is withheld for a STRUCTURAL reason rather than an editorial one:
  # this block's population is BY DEFINITION the rows carrying no layer — an unannotated example
  # declared none, and the envelope requires `intent` to be ABSENT when `status` is `"unannotated"` —
  # so the key would be a column of guaranteed nulls, saying nothing on every row it appeared on. The
  # same argument withholds `declared_intent` (SPGD-1665): this block already serves the OTHER half,
  # `derived_intent`, and an unannotated row has no declaration to serve. The
  # six are `name`, `spec_file_path`, `file_path` and `line_number`, plus `reading` and
  # `derived_intent` (SPGD-711) — and of the locating four the last three are the pair
  # `serialized_spec_file_examples` keeps apart plus the line: `file_path` is where the example is
  # DEFINED and `spec_file_path` is the file that RAN it, which differ for a shared example group, and
  # a reader opening the wrong one of the two finds nothing to annotate.
  #
  # `null` — WITH THE KEY PRESENT — MEANS "YOU DID NOT ASK", on the spelling the three drill-ins above
  # fixed, and the distinction it protects is the sharpest on this block. A fully-annotated run is not
  # an empty file or a stale bookmark: it is the STATE THE METRIC EXISTS TO REACH, so it arrives as the
  # block with `rows: []` and `recorded_count: 0` — HTTP 200, never a 404 and never a `null`. Collapsing
  # it into the no-ask spelling would answer the best possible outcome with the one word reserved for
  # "you did not ask", and a client walking a repository to completion would watch the block vanish at
  # the moment it succeeded and be unable to tell that from its own parameter having been dropped.
  #
  # `recorded_count` IS THE UNANNOTATED POPULATION OF WHATEVER WAS ASKED FOR — the whole run by
  # default, and the narrowed slice when `?spec_file=` or `?spec_directory=` came with the flag. It is
  # the `COUNT(*) OVER ()` window of `SpecObservation::UNANNOTATED_POPULATION_COUNTS`, evaluated after
  # the WHERE and before the LIMIT, so it describes what the ask holds rather than what fit on the
  # page — and it narrows with the rows for free rather than through a second aggregate. Re-deriving
  # it by folding `rows` is wrong here far more often than on the siblings: this population is
  # routinely the WHOLE RUN — a repository that has just installed the gem has `recorded_count ==
  # total_specs` on day one — so the cap fires as the normal case rather than the exotic one, and
  # `recorded_count > rows.length` is a comparison this block ships the two OPERANDS of rather than the
  # answer to — the same ships-the-numbers rule the siblings follow, and the reason
  # `UnannotatedExamples` defines no `truncated?` for a caller that does not exist yet.
  #
  # ⚠️ WHICH IS WHY THE NARROWING IS ECHOED. `recorded_count` is the one figure on this endpoint a
  # client is invited to reconcile against a headline — `total_specs - annotated_specs`, one predicate
  # evaluated twice — and a narrowed count silently breaks that reconciliation. So the two keys below
  # say which population the count is of, and a client that sent neither sees `null` twice and can
  # reconcile exactly as before.
  #
  # NO SECOND COUNT, where all three siblings serve one. Each of theirs discloses COVERAGE of the
  # column its rows are ranked by, and this block ranks by nothing and serves neither nullable column
  # — see `SpecObservation::UNANNOTATED_POPULATION_COUNTS`, where the omission is argued as a choice
  # rather than left as an absence. `limit` is READ OFF `SpecObservation::UNANNOTATED_EXAMPLES_LIMIT`
  # rather than restated, on the precedent every capped block here sets — it is its own constant and is
  # neither `FILE_EXAMPLES_LIMIT` nor `REPEATED_DESCRIPTION_EXAMPLES_LIMIT`.
  #
  # EXACTLY ONE ADDITIONAL QUERY WHEN ASKED, AND NONE WHEN NOT, on the three drill-ins' rule: the gate
  # is the ASK and it is decided before any read is issued, so a client that never sends the parameter
  # pays nothing for the key's existence. The narrowing does not change that — it is a predicate on the
  # one read, not a second one, and it is read off guards this controller already includes for their
  # own blocks. The read is bounded by the RUN rather than by the suite and rides
  # `index_spec_observations_on_test_run_id`, EXPLAIN-certified for exactly this narrow — and for both
  # narrowed shapes — in `spec/models/spec_observation_spec.rb`.
  # `latest_run.intent_readings` — see the key on `serialized_latest_run` for what the four figures
  # are and which of them may not be read as annotation coverage.
  #
  # Unconditional, unlike the two `?unannotated_examples=` blocks below, and that is deliberate
  # rather than an oversight about cost. Those two are a HUNDRED-ROW WORKLIST and a TEN-ROW RANKING
  # — payload a client that did not ask for it should not be handed. This is four integers off one
  # aggregate over one run, and it is what makes `unreadable` reachable without a second request. A
  # client that has to opt in to the correction goes on reading the subtraction, which is the state
  # SPGD-711 exists to end.
  def serialized_intent_readings(test_run)
    readings = test_run.intent_readings

    { authored: readings.authored, derived: readings.derived, unreadable: readings.unreadable,
      recorded: readings.recorded }
  end

  # `latest_run.layer_counts` — the run-wide declared-layer mix, read off the SAME memoized aggregate
  # row as `intent_readings` (no query of its own). `nil` when the run recorded no per-example rows.
  # See the key on `LatestRunSerializer#full_body`.
  def serialized_layer_counts(test_run)
    test_run.layer_counts
  end

  # `latest_run.layer_durations` — the run-wide time by declared layer, read off the SAME memoized
  # aggregate row as `layer_counts` (no query of its own). `nil` when the run recorded no per-example
  # rows; `total_seconds` is `nil` (never 0) for a layer with no timed example.
  def serialized_layer_durations(test_run)
    test_run.layer_durations
  end

  def serialized_unannotated_examples(test_run)
    return nil unless requested_unannotated_examples?

    examples = UnannotatedExamples.for(test_run, spec_file: requested_spec_file,
                                                 spec_directory: requested_spec_directory)

    {
      # THE ASK RESTATED IS THE NARROWING, AND `null` WHEN THERE WAS NONE. The flag itself carries no
      # value to echo — the sibling drill-ins echo the key the client picked out of a ranking, and
      # this parameter is a presence rather than a pick; see `RequestedUnannotatedExamplesParam` for
      # why it is the flag-style one. What CAN be restated is where in the run the client asked to
      # start, and it has to be: `recorded_count` moves with it.
      #
      # As the server READ them, never echoed from the raw parameter, on `history_window.branch`'s
      # rule and `spec_file_examples.path`'s: a malformed shape is no ask at all and reaches no
      # narrowing, so what is served here is always the value the rows were actually gathered under.
      #
      # BOTH ARE AND-ED WHEN BOTH ARRIVE, and a contradictory pair — an area and a file outside it —
      # is answered with `rows: []` and both narrowings echoed, which reads as an empty intersection
      # rather than as one parameter having been dropped. `SpecObservation.unannotated_in` argues why
      # there is no precedence rule.
      #
      # AN UNKNOWN PATH IS THE SAME EMPTY BLOCK, never a 404 and never a prefix match onto a
      # neighbouring file or a sibling subdirectory — `serialized_spec_file_examples` fixed that
      # answer and this inherits it. Unknown-vs-fully-annotated is not distinguished here, and a
      # client that needs the two apart already has them in the SAME RESPONSE BODY for free: with
      # `?spec_file=`, `spec_file_examples.recorded_count > 0` beside a zero here means the file
      # exists and is fully annotated, and both zero means the run recorded nothing at that path.
      # `?spec_directory=` reconciles against `spec_directory_files` the same way. No new field, no
      # new query.
      spec_file: examples.spec_file,
      spec_directory: examples.spec_directory,
      # SIX ROW FIELDS, NOT THE OTHER PER-EXAMPLE BLOCKS' EIGHT, and the difference is asserted rather
      # than structural on purpose — the same way their agreement is. The two sets are not nested:
      # this block withholds four of theirs and carries two — `reading` and `derived_intent` — that
      # none of them serves. A `contain_exactly` over these
      # names in this block's request spec goes red if `duration_seconds`, `outcome`, `intent_layer` or
      # `declared_intent` is added here, and the siblings' own `contain_exactly`s go red if one of
      # theirs is dropped to match, so neither set can drift into the other unnoticed.
      rows: examples.rows.map do |observation|
        {
          name: observation.name,
          file_path: observation.file_path,
          line_number: observation.line_number,
          spec_file_path: observation.spec_file_path,
          # WHAT SPECGUARD READS OF THIS ROW, per row, so the caller never has to re-derive it — and
          # so it cannot re-derive it DIFFERENTLY, which is what a client seeing `name` and no
          # reading would end up doing. `reading` is `"derived"` or `"unreadable"` and never
          # `"authored"`: this list is narrowed to `status = 'unannotated'`, so the third state
          # cannot appear here (see `SpecObservation::UNANNOTATED_POPULATION_COUNTS` for the same
          # argument about the missing count).
          #
          # `derived_intent` is the three fields themselves, or `null`, and the two keys are
          # redundant on purpose: the reading is what a client BRANCHES on, the fields are what it
          # SHOWS, and an agent asked to check whether SpecGuard has the test right needs the second.
          # `layer` is absent from it because it is inferred from the directory rather than read from
          # the description — see `DerivedIntent`, which states in full what an authored `@intent`
          # still buys over this.
          reading: observation.reading,
          derived_intent: serialized_derived_intent(observation)
        }
      end,
      recorded_count: examples.recorded_count,
      # The same population split by reading. Windows over the same rows and the same WHERE as
      # `recorded_count`, so all three narrow together under `spec_file` / `spec_directory` — a
      # client cannot end up holding a derived count for one slice beside a total for another.
      #
      # This is where the endpoint stops being able to be read as "the tests SpecGuard cannot see".
      # `recorded_count` reconciles against `total_specs - annotated_specs` exactly as it always did
      # and means what it always meant — no authored `@intent`. `unreadable_count` is the only figure
      # here any "cannot see" sentence may be built on.
      #
      # ⚠️ ALL THREE ARE POPULATION-GRAIN AGAINST A CAPPED `rows`, and for this pair that is sharper
      # than it is for `recorded_count`. The read leads with the rows nothing could be read from — so
      # `rows` fills with unreadable examples FIRST, and the derived ones are exactly what a cap
      # drops. A client that counts non-null `derived_intent` over `rows` and expects `derived_count`
      # is comparing a page against a population, and on a capped response the honest answer to that
      # comparison is routinely zero-of-many rather than merely short. `limit` below is shipped so
      # the client can tell a capped response from a whole one; `recorded_count > rows.size` is the
      # comparison, and it is a client's sentence to write for the reason `UnannotatedExamples`
      # states. The dashboard's own caption got this wrong in exactly this cell (SPGD-711), which is
      # why it is written down here rather than left as a property of the ordering.
      derived_count: examples.derived_count,
      unreadable_count: examples.unreadable_count,
      limit: SpecObservation::UNANNOTATED_EXAMPLES_LIMIT
    }
  end

  # One row's DECLARED `@intent` as three fields, or `null` when the author declared none of them
  # (SPGD-1665) — the declared twin of `serialized_derived_intent`, served on the three per-example
  # blocks that span annotated and unannotated rows (`slowest_examples`, `spec_file_examples`,
  # `repeated_description_examples`) so the three call sites cannot drift.
  #
  # DECLARED ONLY. This reads the three `intent_*` columns the ingest recorder stored from the
  # author's own annotation and NEVER falls back to `SpecObservation#derived_intent`: a regex guess
  # from the description must not appear in the field reserved for the author's word (an unannotated
  # row's guess is `unannotated_examples#derived_intent`, a different key on a different block).
  #
  # Each part is read with `.presence`, as `_authored_intent.html.erb` does, so an empty string is
  # never served as a value. The parts are independent: a row declaring only `behavior` serves a
  # non-nil object with nil `entity`/`action`. The object is `nil` — never a hash of nils — when none
  # of the three is present. The columns are already loaded on every row source, so this adds no query.
  def serialized_declared_intent(observation)
    entity = observation.intent_entity.presence
    action = observation.intent_action.presence
    behavior = observation.intent_behavior.presence
    return nil unless entity || action || behavior

    { entity: entity, action: action, behavior: behavior }
  end

  # One row's derived reading as three fields, or `null` when the description yielded none.
  #
  # Nil rather than a hash of nils: "SpecGuard read nothing from this description" is one state, and
  # three null fields is a shape a client would have to test three times to recognise.
  def serialized_derived_intent(observation)
    derived = observation.derived_intent
    return nil unless derived

    { entity: derived.entity, action: derived.action, behavior: derived.behavior }
  end

  # WHERE THE ANNOTATION DEBT IS, by code area — the ranking the block above is a worklist under, and
  # the answer to the question that block could not be asked. `unannotated_examples` is ordered
  # file-navigably and says so; `?spec_file=` / `?spec_directory=` narrow it, and both only help a
  # client that already knows which area to name. Nothing in this response body said. This key does.
  #
  # NO NEW REQUEST PARAMETER. It rides `requested_unannotated_examples?` — the same gate, decided
  # before any read is issued — on this file's rule that THE GATE IS THE ASK: a client that never
  # sends the flag pays nothing for the key's existence, and one that does gets the ranking and the
  # worklist off one request rather than having to learn a second parameter to make the first usable.
  # EXACTLY ONE ADDITIONAL QUERY FOR THIS KEY WHEN ASKED, AND NONE WHEN NOT — so the ask now costs
  # TWO reads in total, one per block, which is what the cost examples in
  # `repository_unannotated_examples_spec.rb` pin.
  #
  # ⭐ THIS MAP IS WHOLE-RUN EVEN UNDER `?spec_file=` / `?spec_directory=`, AND ITS SIBLING IS NOT.
  # This is the one place on this endpoint where two keys of ONE block are deliberately scoped
  # differently, so it is disclosed here rather than left for a client to discover by arithmetic.
  #
  # `unannotated_examples.recorded_count` NARROWS with the narrowing — SPGD-608 made it so on purpose,
  # because the window rides the WHERE and a count beside a narrowed list has to describe the
  # population that list was cut from. This map does the opposite BY DESIGN: it is the thing a client
  # picks a narrowing FROM, and a map that narrowed to the area you had already picked would answer
  # nothing — one row, echoing the parameter back. So it stays whole-run and remains a way to choose
  # the NEXT area to go and work on, which is the whole reason the rung exists.
  #
  # The consequence a client must be able to explain: under a narrowing, `unannotated_examples.recorded_count`
  # is NOT the sum of `unannotated_directories[].unannotated_count`, and neither figure is wrong. The
  # first counts one area (or one file); the second ranks the whole run and is capped besides — so the
  # sum is short of the run's total whenever `directory_count > rows.size`, narrowing or no narrowing.
  # `spec_file` / `spec_directory` are echoed on the sibling block for exactly this reconciliation, and
  # `directory_count` beside these rows is the other half of it.
  #
  # `limit` is READ OFF `SpecObservation::UNANNOTATED_DIRECTORIES_LIMIT` rather than restated, on the
  # precedent every capped block here sets — it is its own constant and is neither
  # `HEAVIEST_DIRECTORIES_LIMIT` nor `UNANNOTATED_EXAMPLES_LIMIT`.
  #
  # OPERANDS, NEVER A FRACTION — this file's governing rule for every rollup it serves. The rows carry
  # `unannotated_count` and the `recorded_count` it was counted against, so a client divides by the
  # same figure the ranking was built on. A single percentage here would be a number a client cannot
  # take apart, and the sibling rollups' `coverage_label` is TIMING coverage and would be mistaken for
  # this one the moment either shipped a bare ratio.
  #
  # `null` WHEN THE FLAG WAS NOT SENT, and `null` — not an empty block — for a run that recorded no
  # per-example rows at all, which is `UnannotatedDirectories#recorded?` and the same absence
  # `serialized_spec_directories` answers that run with.
  #
  # ⭐ THAT SECOND NULL IS THE OTHER PLACE THESE TWO KEYS OF ONE BLOCK DISAGREE, and it is disclosed
  # here for the same reason the scope disagreement above is. On a run that recorded no per-example
  # rows, with the flag sent:
  #
  #     unannotated_examples    -> a present block, `rows: []`, `recorded_count: 0`
  #     unannotated_directories -> `null`
  #
  # A client reconciling those is doing exactly the arithmetic the paragraph above was written to
  # protect, so the difference has to be readable rather than inferred from two absent things looking
  # alike. It is NOT an inconsistency to iron out. The sibling's zero is ambiguous by construction —
  # "fully annotated" and "recorded nothing at all" are the same `recorded_count: 0` there, and that
  # block's own comment sends a client to neighbouring keys to tell such pairs apart. This key IS one
  # of those neighbours: a PRESENT map beside that zero means the run has a per-area grain and the
  # zero is the success state; a `null` map means the run recorded nothing and the zero is an absence
  # of data. Serving `rows: []` here instead would spend a distinction a client has no other way to
  # make in order to make two keys look the same. Both halves are pinned together in
  # `repository_unannotated_examples_spec.rb`, beside the fully-annotated run that reaches the same
  # zero with the map present.
  def serialized_unannotated_directories(test_run)
    return nil unless requested_unannotated_examples?

    directories = UnannotatedDirectories.for(test_run)

    return nil unless directories.recorded?

    {
      rows: directories.rows.map do |row|
        # The three readings beside the two totals that were already here. `unannotated_count` is
        # unchanged in meaning and in value — no authored `@intent` — and is what reconciles against
        # the run's counters; `derived_count` and `unreadable_count` split it, and are what stop a
        # client rendering the whole of it as debt SpecGuard is blind to.
        { path: row.path, unannotated_count: row.unannotated_count, recorded_count: row.recorded_count,
          authored_count: row.authored_count, derived_count: row.derived_count,
          unreadable_count: row.unreadable_count }
      end,
      directory_count: directories.directory_count,
      limit: SpecObservation::UNANNOTATED_DIRECTORIES_LIMIT
    }
  end

  private :serialized_declared_intent, :serialized_derived_intent

  private

  attr_reader :overview

  delegate :requested_limit, :requested_layer, :requested_spec_directory, :requested_spec_file,
           :requested_repeated_description, :requested_unannotated_examples?, to: :overview, private: true
end
