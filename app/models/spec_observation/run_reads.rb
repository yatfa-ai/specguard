# frozen_string_literal: true

# THE ONE-RUN READS OF `SpecObservation`, MOVED OUT WHOLE — the fourteen class methods that answer
# a question about ONE run's rows and nothing else: `slowest_in`, `in_declared_layer`, `coverage_in`,
# `file_durations_in`, `in_file`, `with_description`, `unannotated_in`, `unannotated_directories_in`,
# `unannotated_files_in`, `reading_counts_in`, `directory_durations_in`, `files_in_directory`,
# `repeated_descriptions_in` and `description_presence_in`. `SpecObservation` `extend`s this module,
# so every caller keeps
# spelling them `SpecObservation.<method>` and the receiver is still the model class (`where`,
# `sanitize_sql_array`, `connection` and the constants resolve as before).
#
# MOVE ONLY. Every method body and comment below is byte-identical to what it was in
# `app/models/spec_observation.rb`; the sole code edit is `def self.x` -> `def x` (plus the extra
# indent), and the emitted SQL did not change. The comments still say "above", "below" and `{.foo}`,
# and those coordinates are RELATIVE TO THE OLD FILE — they were not rewritten, so read a position
# word as pointing into `SpecObservation`, not into this module. (A bare "this file" in the moved
# prose likewise names `app/models/spec_observation.rb`.)
#
# THE CONSTANTS STAY ON `SpecObservation`. This module is nested lexically inside the class, so the
# unqualified `SLOWEST_LIMIT`, `HEAVIEST_FILES_LIMIT`, `HEAVIEST_DIRECTORIES_LIMIT`,
# `FILE_EXAMPLES_LIMIT`, `SPEC_DIRECTORY_FILES_LIMIT`, `COVERAGE_COUNTS`, `REPEATED_DESCRIPTIONS_LIMIT`,
# `REPEATED_DESCRIPTION_EXAMPLES_LIMIT`, `UNANNOTATED_EXAMPLES_LIMIT`, `UNANNOTATED_DIRECTORIES_LIMIT`,
# `UNANNOTATED_FILES_LIMIT`, `UNANNOTATED_POPULATION_COUNTS`, `FILE_POPULATION_COUNTS`,
# `DESCRIPTION_POPULATION_COUNTS`,
# `READING_COUNTS`, `READINGS`, `READING_EXPRESSION` and `DIRECTORY_EXPRESSION` resolve exactly as
# they did, and a `stub_const("SpecObservation::...")` in a spec still bites because the lookup
# happens at call time. Some moved bodies also call `declared_layer_predicate`,
# `directory_layer_count_expressions` and `run_counts_in`, which stay on the model (the history
# family and the shared builders need them too) and are reached through the same receiver.
class SpecObservation < ApplicationRecord
  module RunReads
    # The slowest examples of ONE run, slowest first — the question this table's composite index
    # (`index_spec_observations_on_test_run_id_and_duration_seconds`) was built for. Scoped to a
    # single `test_run_id` and capped, it is an indexed backward scan: constant in suite size, which
    # is what makes it safe at the 20,000-example design point rather than a sort over every row the
    # run wrote.
    #
    # One run, never a repository's history. `example_id` is positional and explicitly not stable
    # across refactors (see the class comment above), so a ranking that spanned runs would be
    # comparing rows that are not known to be the same test. That boundary is the model's, and this
    # method stays on the near side of it.
    #
    # `id` breaks ties, so a run whose examples tie to the millisecond has a total, stable order
    # rather than one the query planner picks afresh on each request.
    #
    # `layer:` narrows the ranking to ONE declared layer (a {DECLARED_LAYER_KEYS} member, as a String or
    # Symbol), through {.declared_layer_predicate} — the same predicate the run-wide per-layer counts and
    # durations are built from, selected by key and never retyped, so a layer's ranking and its
    # `layer_counts` / `layer_durations` figures cannot disagree about what its rows are. `nil` — the
    # default — is the unnarrowed run-wide ranking, byte-identical to before the keyword existed.
    def slowest_in(test_run, limit: SLOWEST_LIMIT, layer: nil)
      in_declared_layer(where(test_run_id: test_run.id), layer).timed.order(duration_seconds: :desc, id: :asc).limit(limit)
    end

    # `scope` narrowed to one declared layer, or `scope` itself for `nil`. Shared by {.slowest_in} and
    # {.coverage_in} so the ranking and the coverage counts that caption it always describe one row set.
    def in_declared_layer(scope, layer)
      layer.nil? ? scope : scope.where(declared_layer_predicate(layer))
    end

    # One run's slice, counted every way the panel above it has to state — in a single round trip.
    #
    # Deliberately NOT `TestRun#total_specs_count` for any of it. That figure is re-derived by SUM
    # over `test_run_shards` and the class comment above is explicit that nothing here re-derives it;
    # the two can legitimately disagree, since `Ingest::ObservationRecorder#record` writes a row count
    # that is *"not always `specs.size`"*. Coverage of a ranking is a fact about the rows ranked.
    #
    # Every value is `to_i`'d: a run that recorded nothing still returns a row of zeroes from an
    # aggregate, and the caller wants integers rather than a mix of those and nils.
    #
    # @return [Hash{Symbol=>Integer}] keyed by `COVERAGE_COUNTS`' names, in its order.
    #
    # `layer:` narrows the slice to one declared layer on {.slowest_in}'s terms. Its default is NO layer,
    # which is what the second caller (`Api::V1::IngestsController`) relies on to stay unchanged.
    def coverage_in(test_run, layer: nil)
      counts = in_declared_layer(where(test_run_id: test_run.id), layer).pick(*COVERAGE_COUNTS.values.map { |sql| Arel.sql(sql) })

      COVERAGE_COUNTS.keys.zip(Array(counts)).to_h { |name, count| [name, count.to_i] }
    end

    # Where ONE run's wall clock went, rolled up by spec file, heaviest first — the question the
    # class comment above says this table exists to answer and which nothing in `app/` had ever
    # asked. A ranking of individual examples cannot answer it: at the 20,000-example design point
    # `SLOWEST_LIMIT` shows 0.05% of the suite ordered by *individual* cost, and a file holding 400
    # examples at 50ms each is twenty seconds of the run with every one of its rows far below the
    # head. Outliers and concentration are different questions.
    #
    # Grouped on `spec_file_path` — the INCLUDING file — so a shared example group's time lands on
    # the file that ran it rather than on a `spec/support/` helper (see "Two paths, two meanings"
    # above, and the end-to-end pin in spec/requests/api/v1/ingest_spec.rb). The key cannot be null:
    # `Ingest::ObservationRecorder#attributes` falls back to `file_path` for a producer old enough
    # not to send one, precisely so no row drops out of a by-file total.
    #
    # @return [Array<Array>] `[spec_file_path, total_seconds, recorded_count, timed_count, file_count]`
    #   per file, where `file_count` is the same figure on every row: how many files the run touched
    #   in total, before the `LIMIT`.
    #
    # == Why four columns and not one SUM
    #
    # `SUM` skips NULLs SILENTLY, and `duration_seconds` is nullable by design — an example that
    # never ran records a faithful nil. Unlike `#slowest_in`, exclusion is not available here:
    # dropping untimed rows changes each surviving group's own POPULATION, so a file with 400
    # examples of which 200 went untimed would report a total that understates by half and say
    # nothing about it. So every group carries how many of its rows reported a timing, counted in
    # the same pass: `COUNT(*)` against `COUNT(duration_seconds)`, which counts non-nulls. One
    # grouped aggregate for the whole panel — a per-file follow-up query would be a trip per row.
    #
    # == `pluck`, deliberately, and `NULLS LAST`
    #
    # Both are about the file whose examples were ALL untimed, whose SUM is SQL NULL:
    #
    # * `group(...).sum(:duration_seconds)` casts that NULL to `0.0` on the way back into Ruby, and
    #   a surface handed a zero renders "0.00s" — a run that measured nothing wearing the spelling
    #   of a measurement. `#duration_label` refuses exactly that reading one grain down. `pluck`
    #   hands the nil back intact so the caller can tell the two apart.
    # * `SUM(...) DESC` is NULLS FIRST in Postgres, so the naive ordering does not merely include
    #   that file — it names it the heaviest file in the suite. Same hazard `scope :timed` documents
    #   at the example grain, and the ordering has to answer it here because the row is not excluded.
    #
    # `spec_file_path` breaks ties, so a run whose files total equally has one stable order rather
    # than one the planner picks afresh per request.
    #
    # == Why the row count comes back on every row
    #
    # This read is `LIMIT`ed, so its own length is the TRUNCATED count and a caller holding it cannot
    # tell "the ten heaviest of three hundred files" from "all three files this run touched". That is
    # the same lie by omission the four columns above exist to refuse, one grain up: a figure that
    # does not state what it was drawn from. A second `COUNT(DISTINCT spec_file_path)` would be a
    # second round trip for one clause of one sentence — the objection `.coverage_in` answers.
    #
    # `COUNT(*) OVER ()` is evaluated AFTER `GROUP BY` and BEFORE `LIMIT`, so it counts groups, not
    # rows, and counts all of them however few are returned. It rides back on every row carrying the
    # same value; the caller reads it off whichever row it has and gets nothing for an empty run,
    # which is the correct answer there.
    #
    # == The trailing declared-layer operands
    #
    # After those five, five more: the FILE's declared-layer counts ({.directory_layer_count_expressions},
    # in {DECLARED_LAYER_KEYS} order), each a `COUNT(*) FILTER` in the SAME grouped pass — no second
    # statement. They are appended AFTER `COUNT(*) OVER ()` so `SpecFileDurations::FILE_COUNT_INDEX`
    # keeps its meaning; the caller reads the file count by that index, never from the tail.
    #
    # == `layer:` — the layer in the query, before `GROUP BY` and `LIMIT`
    #
    # With a declared layer asked ({DECLARED_LAYER_KEYS} member), the rows are narrowed through
    # {.in_declared_layer} — the one shared predicate {.slowest_in} and {.coverage_in} use, never
    # retyped — BEFORE grouping, so the ranking is by THAT layer's `SUM(duration_seconds)` and the cut
    # is made over that layer's files. It cannot be recovered from the unfiltered top ten: a file whose
    # request-layer time is large and whose all-layer time is not would sit below the cut. `COUNT(*)` /
    # `COUNT(duration_seconds)` are then the layer's own per-file counts, and `COUNT(*) OVER ()` is the
    # number of files with at least one example in the layer. The trailing per-layer operands are
    # unchanged (the layer's population: its own key non-zero, the rest measured zeros). `nil` — the
    # default — is byte-identical to the unnarrowed read.
    def file_durations_in(test_run, limit: HEAVIEST_FILES_LIMIT, layer: nil)
      in_declared_layer(where(test_run_id: test_run.id), layer)
        .group(:spec_file_path)
        .order(Arel.sql("SUM(duration_seconds) DESC NULLS LAST"), Arel.sql("spec_file_path ASC"))
        .limit(limit)
        .pluck(Arel.sql("spec_file_path"), Arel.sql("SUM(duration_seconds)"),
               Arel.sql("COUNT(*)"), Arel.sql("COUNT(duration_seconds)"),
               Arel.sql("COUNT(*) OVER ()"), *directory_layer_count_expressions)
    end

    # ONE spec file's examples in ONE run, slowest first — the rung BELOW the rollup above, and the
    # read `index_spec_observations_on_test_run_id_and_spec_file_path` exists for. The by-file rollup
    # says `spec/models/order_spec.rb` cost six minutes across 340 examples; nothing until now could
    # say WHICH 340, at a design point where every panel on the page is a capped ten.
    #
    # == It leads with the by-file index, and must go on doing so
    #
    # `.slowest_in` is a backward scan on `index_spec_observations_on_test_run_id_and_duration_seconds`
    # and its comment calls that plan *"constant in suite size"*. Adding `spec_file_path` to THAT scan
    # would destroy exactly the property the comment claims: the scan would walk the run from its
    # slowest example downward discarding every row belonging to another file, which on a small file
    # in a 20,000-example run is most of the run to fill a page. This narrows on
    # `(test_run_id, spec_file_path)` first — an equality predicate on both columns of the composite
    # index, so the rows read are the file's and only the file's — and sorts that handful. Cost is
    # bounded by the size of the FILE, not of the suite. EXPLAIN-certified against a real planner at
    # the 20-run seed in spec/models/spec_observation_spec.rb.
    #
    # Deliberately an EQUALITY predicate and deliberately not a subtree. "Every row under
    # `spec/models/`" is a PREFIX predicate, which wants a `text_pattern_ops` index and therefore a
    # migration; this read issues none and needs none. That boundary is recorded in the same spec.
    #
    # == Untimed rows are LISTED, which is why the ordering carries `NULLS LAST`
    #
    # `scope :timed` excludes them from every RANKING because a row with nothing to compare cannot be
    # the slowest of anything. This is not a ranking of the suite; it is the file's population, and an
    # example the client never timed is part of that population — hiding it would make a file's list
    # disagree with the `recorded_count` printed above it. So the rows stay, and `duration_seconds:
    # :desc` alone would then be **NULLS FIRST** in Postgres: the examples that reported no duration
    # at the head of a list captioned "slowest first". They sort to the END instead, which is the
    # hazard `scope :timed` documents answered by the other of the two ways it names.
    #
    # `id` breaks ties, so a file whose examples tie — and a file all of whose examples went untimed,
    # where every row ties — has one stable order rather than one the planner picks afresh per
    # request.
    #
    # The projection carries `FILE_POPULATION_COUNTS`, so a caller gets the file's recorded and timed
    # counts off the same read as the rows; see that constant for why they are windows rather than a
    # second aggregate. Those two are ATTRIBUTES of the returned records rather than a separate
    # value, which makes this relation one to load and read — `SpecFileExamples` is its one caller —
    # rather than one to count or paginate further.
    #
    # `layer:` narrows the file to the examples that declared ONE layer ({DECLARED_LAYER_KEYS}), through
    # {.in_declared_layer} — the predicate the layer-ranked "Heaviest spec files" rollup counts with — so
    # a file opened out of a layer-ranked row holds exactly the rows that row counted: the `FILE_POPULATION_COUNTS`
    # windows are evaluated AFTER the WHERE, so the drill-in's `file_recorded_count` / `file_timed_count`
    # equal the clicked row's `recorded_count` / `timed_count` with no second query. The `(test_run_id,
    # spec_file_path)` equality still leads, so the by-file index stays the access path and the layer is a
    # filter on that file's rows. `nil` (the default) is the unnarrowed read, byte-identical to before.
    def in_file(test_run, spec_file_path, limit: FILE_EXAMPLES_LIMIT, layer: nil)
      in_declared_layer(where(test_run_id: test_run.id, spec_file_path: spec_file_path), layer)
        .select(Arel.sql("spec_observations.*, #{FILE_POPULATION_COUNTS}"))
        .order(Arel.sql("duration_seconds DESC NULLS LAST"), id: :asc)
        .limit(limit)
    end

    # ONE description's examples in ONE run — the rows behind a single line of the repeated-description
    # ranking, where `.repeated_descriptions_in` returns the group and no member of it.
    #
    # The sibling of `.in_file` above and deliberately shaped identically, because it is the same kind
    # of read one axis over: that one narrows a run to the rows of a FILE, this narrows it to the rows
    # carrying one NAME. `.repeated_descriptions_in` is an aggregate — `[name, SUM, COUNT(*), …,
    # ARRAY_AGG(DISTINCT spec_file_path)]` — out of which no member row escapes, so a reader told that
    # eight examples share a description and cost ninety seconds between them had, until this existed,
    # no way whatever to learn WHICH eight.
    #
    # == Not answerable by `.in_file`, which is the obvious substitute
    #
    # The ranking names the group's files, and those paths are a link into the `?spec_file=` panel. But
    # that panel lists EVERY example of a file, capped at `FILE_EXAMPLES_LIMIT` and ranked by duration:
    # a reader following a two-file group through it gets two lists of up to fifty unrelated rows, and
    # the group's own members need not be among the fifty either list shows. The narrowing this panel
    # needs is by description, and it exists nowhere else.
    #
    # == An EQUALITY predicate on a nullable column, and why no nil ever reaches it
    #
    # `name` is nullable and `Ingest::ObservationRecorder#attributes` writes it through `presence_of`.
    # `.repeated_descriptions_in` excludes null names in SQL, so a group only reaches the ranking if it
    # HAS a name and the drill-down is never legitimately handed a nil; `RequestedRepeatedDescriptionParam`
    # is what keeps a blank ask from arriving as one anyway. Nothing here re-checks it — a nil would
    # answer no rows, which is the same honest empty state a description this run did not record gets.
    #
    # == Untimed rows are LISTED, which is why the ordering carries `NULLS LAST`
    #
    # Verbatim the argument `.in_file` makes: `scope :timed` excludes untimed rows from every RANKING
    # because a row with nothing to compare cannot be the slowest of anything, and this is not a
    # ranking of the suite but the GROUP's population. An example the client never timed is part of
    # what shares this description — hiding it would make the list disagree with the `recorded_count`
    # printed above it, and on this panel it would do worse than that: an untimed member is often
    # exactly the row a reader has come to find, because a test that never ran is one way three
    # examples come to say the same thing. So the rows stay, and `duration_seconds: :desc` alone would
    # then be **NULLS FIRST** in Postgres — the examples that reported no duration at the head of a
    # list captioned "slowest first". They sort to the END instead.
    #
    # `id` breaks ties, so a group whose examples tie — and a group none of whose examples were timed,
    # where every row ties — has one stable order rather than one the planner picks afresh per request.
    #
    # == Query cost
    #
    # Rides `index_spec_observations_on_test_run_id`. There is no `(test_run_id, name)` index and this
    # read does not want one: `index_spec_observations_on_repository_id_and_name` exists and is NOT the
    # path here, for the reason `.repeated_descriptions_in` states at this exact grain — it leads on
    # `repository_id`, which serves a WINDOW of runs, and a single-run narrow does not begin with it.
    # One query, bounded by the size of ONE RUN rather than of the suite, and issued only when a
    # description was asked for. EXPLAIN-certified at the 20-run seed in
    # spec/models/spec_observation_spec.rb rather than argued for here.
    #
    # The projection carries `DESCRIPTION_POPULATION_COUNTS`, so a caller gets the group's recorded and
    # timed counts off the same read as the rows. Those two are ATTRIBUTES of the returned records
    # rather than a separate value, which makes this relation one to load and read —
    # `RepeatedDescriptionExamples` is its one caller — rather than one to count or paginate further.
    #
    # `layer:` narrows the group to the examples that declared ONE layer ({DECLARED_LAYER_KEYS}),
    # through {.in_declared_layer}, so a group opened out of a layer-ranked row holds exactly the rows
    # that row counted: the drill-in's `description_recorded_count` / `description_timed_count` windows
    # equal the clicked row's `recorded_count` / `timed_count`. `nil` is the unnarrowed read.
    def with_description(test_run, name, limit: REPEATED_DESCRIPTION_EXAMPLES_LIMIT, layer: nil)
      in_declared_layer(where(test_run_id: test_run.id, name: name), layer)
        .select(Arel.sql("spec_observations.*, #{DESCRIPTION_POPULATION_COUNTS}"))
        .order(Arel.sql("duration_seconds DESC NULLS LAST"), id: :asc)
        .limit(limit)
    end

    # ONE run's UNANNOTATED examples — the rows behind the subtraction the dashboard USED TO print as
    # *"SpecGuard cannot see the other N tests"*, and the one ranking on this endpoint that had no rung
    # under it.
    #
    # ⚠️ THAT SENTENCE IS GONE AND THIS POPULATION IS NOT. SPGD-711 corrected the claim, not the rows:
    # every row here lacks an authored `@intent` — which is exact, and is the same predicate the
    # subtraction evaluates — while most of them carry a description SpecGuard reads perfectly well.
    # {READINGS} is the split, `UNANNOTATED_POPULATION_COUNTS` counts it, and the ordering below leads
    # with the rows nothing could be read from.
    #
    # The third sibling of `.in_file` and `.with_description` and deliberately shaped like them, because
    # it is the same kind of read one axis over: those narrow a run to the rows of a FILE and to the rows
    # carrying one NAME, and this narrows it to the rows carrying one STATUS. What makes it different is
    # what it drills out of — not a ranking of the run's rows but a COUNT PAIR on the run itself,
    # `total_specs_count` and `annotated_specs_count`, which is a subtraction and names nothing.
    #
    # == It agrees with the headline BY CONSTRUCTION, which is the whole reason it reads this column
    #
    # `Ingest::Payload#annotated_specs` is `@specs.reject { |spec| spec["status"] == "unannotated" }` and
    # its size is `annotated_specs_count`; `Ingest::ObservationRecorder#attributes` writes that same
    # `spec["status"]` onto every row it inserts. So `total_specs_count - annotated_specs_count` and a
    # `WHERE status = 'unannotated'` over the run's rows are the SAME PREDICATE evaluated twice — one
    # derivation, not two that agree today. That is the property this file demands of a count and its
    # list everywhere else, and it is why no new column, no counter and no migration came with this read.
    #
    # ⚠️ THE WORD IS `Ingest::Payload`'S, NOT THIS MODEL'S, and it is safe to compare against literally
    # only because that class validates it: `Ingest::Payload::STATUSES` is `%w[annotated unannotated]`,
    # which is what makes "not unannotated" the same set as "annotated" — the payload's own comment says
    # so at `#annotated_specs`. A third status added there would need this read revisited in the same
    # commit; nothing here can detect one, and `spec/requests/api/v1/repository_unannotated_examples_spec.rb`
    # reconciles this count against the run's two counters so the pair cannot drift silently.
    #
    # It is deliberately NOT spelled as `where.not(status: "annotated")`, which selects the same rows
    # today and would stop doing so the moment a third status existed — and would stop by silently
    # ADOPTING it into a list captioned "unannotated" rather than by going red.
    #
    # == The ordering is FILE-NAVIGABLE, not a ranking
    #
    # The two siblings sort by `duration_seconds DESC NULLS LAST`, because a reader arriving at them has
    # come to find what a file or a description COSTS. Nobody arrives here for that: this is a worklist of
    # tests to go and annotate, and duration is not merely a different axis but a misleading one — an
    # unannotated example is disproportionately likely to be untimed (a test that never ran is one way an
    # example goes unannotated), so a by-duration order would put the rows a reader can act on LEAST at
    # the head under a `NULLS LAST` tail nobody reaches.
    #
    # `spec_file_path`, then `line_number`, then `id`: the order somebody would open the files in, so the
    # rows of one file arrive together and in the order they sit in it. Every one of the three is total
    # where the two before it tie, so the same run returns the same page twice — which the cap makes
    # load-bearing rather than tidy, since a reader annotating the first hundred and asking again must
    # not be handed a re-shuffled hundred. `line_number` is `null: false`, so nothing in the middle term
    # can be NULL; `spec_file_path` is nullable BY SCHEMA and cannot be in practice, because
    # `Ingest::ObservationRecorder#attributes` falls back to the `null: false` `file_path` — and where
    # Postgres sorts a NULL under a plain `ASC` (last) is the survivable direction either way.
    #
    # == The population may be NARROWED to one file or one area, on the ladder's own two parameters
    #
    # Whole-run is the ask's default and not its only shape. A worklist with exactly one order and no
    # way to choose a place in it hands a team adopting SpecGuard the alphabetically-first hundred of
    # the WHOLE suite, and the only route to the module they are actually touching is to annotate every
    # alphabetically-earlier example first — a hundred at a time, each batch costing a CI run and a
    # re-ingest. Nothing was lost that way; the reader simply could not start where the work is, which
    # is the one thing a worklist is for.
    #
    # So `spec_file` and `spec_directory` narrow it, and they are THE PREDICATES THIS FILE ALREADY
    # OWNS rather than two new ones. `spec_file` is `.in_file`'s `where(spec_file_path: …)` verbatim;
    # `spec_directory` is `.files_in_directory`'s `DIRECTORY_EXPRESSION = ?` verbatim, which is the
    # IMMEDIATE PARENT of the including file compared for EQUALITY and NEVER a prefix `LIKE` — the rule
    # `.file_growth_between` and `.file_runtime_growth_between` each state in full, and the one a reader
    # widening this to "the whole subtree" would be inventing a fifth directory semantics to break.
    # `spec/models/orders` is its own area, not part of `spec/models`.
    #
    # BOTH TOGETHER ARE AND-ED, AND THERE IS NO PRECEDENCE RULE. The two parameters are read
    # independently everywhere else on the endpoint that sends them and open two independent blocks, so
    # a "narrower rung wins" rule would be a concept invented for this one read and remembered nowhere
    # else. AND-ing needs no rule at all: a contradictory pair returns no rows, which is an honest
    # empty intersection rather than one parameter having been silently dropped.
    #
    # Neither narrowing distinguishes "that path does not exist" from "that path is fully annotated",
    # and neither should — `SpecFileExamples` answers an unknown path with the empty block rather than
    # an error or a prefix match, and a caller that needs the two apart has them for free in the
    # sibling block the same request opens. See `serialized_unannotated_examples`, which says so.
    #
    # == Query cost
    #
    # One statement, bounded by the size of ONE RUN and issued only when the parameter was sent. Rides
    # `index_spec_observations_on_test_run_id`: there is no `(test_run_id, status)` index and this read
    # does not want one — `status` is two values over a whole table, which is the shape an index serves
    # worst, and the run narrow is what makes the read affordable. The certification in
    # `spec/models/spec_observation_spec.rb` asserts what actually matters and nothing wider — ONE RUN
    # REACHED THROUGH AN INDEX rather than every run's rows walked — which is a claim about the WHERE,
    # and the WHERE is untouched by everything below.
    #
    # ⚠️ THE SORT IS EXPLICIT AND UNCONDITIONAL, AND THE ORDERING BELOW IS WHAT MADE IT SO. This
    # paragraph used to add that the ORDER BY leads on `spec_file_path`, which
    # `index_spec_observations_on_test_run_id_and_spec_file_path` DOES lead on after the run, "so the
    # planner may take the sort from that index or read the narrow one and sort the rows". That was
    # true of this read until SPGD-711, and the reading term falsified it in the same commit that left
    # the sentence standing: the leading term is now `(READING_EXPRESSION = 'derived')`, a per-row
    # expression no index expresses, so the sort cannot come from an index and every plan carries a
    # `Sort` node over the run's unannotated rows.
    #
    # Established rather than asserted, with `enable_sort = off` so the planner would take an ordered
    # path if one were reachable at all: the pre-SPGD-711 shape plans as an `Index Scan using
    # index_spec_observations_on_test_run_id_and_spec_file_path` under an `Incremental Sort`
    # (`Presorted Key: spec_file_path`); this one still plans a `Sort` on the expression. There is no
    # ordered path left to offer a reader.
    #
    # 💰 WHAT THAT COSTS, MEASURED, because the alternative is arguing about it. Same method as the
    # table at {READING_EXPRESSION} — `EXPLAIN (ANALYZE, TIMING OFF)`, ActiveRecord query cache off,
    # best of eleven — on one 35,000-row all-unannotated run seeded for the purpose, with `jit` off
    # and the sequential and bitmap paths disabled so all five rows are the SAME access method and
    # only the ordering and the projection move:
    #
    # | ORDER BY / projection                                | plan               | measured |
    # |------------------------------------------------------|--------------------|----------|
    # | pre-711: `spec_file_path` first, `COUNT(*) OVER ()`  | `Sort`             |  40.8 ms |
    # | …the same, with `enable_sort = off`                  | `Incremental Sort` |  28.6 ms |
    # | `(status = 'annotated')` first — free per row        | `Sort`             |  44.8 ms |
    # | the reading first, `COUNT(*) OVER ()`                | `Sort`             | 118.0 ms |
    # | as shipped: the reading first, both reading windows  | `Sort`             | 253.0 ms |
    #
    # Three separate quantities, and they are nowhere near the same size.
    #
    # THE EXTRA SORT KEY costs ~4 ms — 40.8 → 44.8, holding the projection fixed and putting a
    # per-row-FREE expression in the lead, which changes the plan's shape and nothing else. It stays
    # that small because the `Sort` is a `top-N heapsort` bounded by `LIMIT 100` (111 kB at 35,000
    # rows) rather than a full sort of the population.
    #
    # THE FORGONE INDEX ORDER is the 40.8 → 28.6 gap: ~12 ms, and it is a COUNTERFACTUAL rather than a
    # regression, because the planner declined that path unaided even while it was reachable — 40.8 ms
    # is what this read was ACTUALLY getting. What the reading term removed is an option, not the plan.
    #
    # THE REGEX is the rest, and it dominates both by an order of magnitude: ~70 ms an evaluation
    # (44.8 → 118.0 for the sort key, 118.0 → 253.0 for the two windows), which is ~2 µs a row —
    # the figure that table states, arrived at from a different direction.
    #
    # So `.unannotated_in`'s row in that table is a REGEX cost carrying single-digit milliseconds of
    # ordering, and the remedy for the large part is the fence that section names and declines — not
    # an index, which cannot help a per-row expression at all. The absolutes here sit above that
    # table's because this is a different seeded run and a forced access method; the DECOMPOSITION is
    # what this block is for, and its per-evaluation figure reproduces the one measured there.
    #
    # ⭐ AND THE SCAN WAS NEVER EARLY-TERMINABLE, before SPGD-711 or after — worth stating because
    # "the LIMIT can no longer stop the scan early" is the natural inference from the paragraph above
    # and it is not true. `COUNT(*) OVER ()` in {UNANNOTATED_POPULATION_COUNTS} must consume the whole
    # narrowed population before the first row can be emitted, so both shapes read every unannotated
    # row of the run (`actual rows=35000` under the `WindowAgg` on each) and the cap bounds what is
    # RETURNED rather than what is read. The cap was never the thing keeping this read affordable; the
    # run narrow is, which is what the certification pins.
    #
    # NEITHER NARROWING COSTS THE READ ANYTHING, and they do not cost it the same way. `spec_file`
    # narrows on the second column of `index_spec_observations_on_test_run_id_and_spec_file_path`, so
    # it is strictly CHEAPER than the whole-run read above. `spec_directory` is an expression
    # predicate and buys no index — it is the run-bounded scan `.files_in_directory` already ships,
    # bounded by the run rather than by the suite, which is the same bound the un-narrowed read has.
    # So the certification covers all three reads and asserts the one thing that has to stay true of
    # each: one run reached through an index rather than every run's rows walked.
    #
    # The projection carries `UNANNOTATED_POPULATION_COUNTS`, so a caller gets the unannotated
    # population off the same read as the rows — and the window rides the WHERE, so a narrowed read
    # counts the narrowed population for free rather than needing a second aggregate to describe what
    # it returned. That figure is an ATTRIBUTE of the returned records rather than a separate value,
    # which makes this relation one to load and read — `UnannotatedExamples` is its one caller —
    # rather than one to count or paginate further.
    # == The UNREADABLE rows come FIRST, and the cap is why that is not a preference
    #
    # The list is capped at a hundred and ordered file-navigably, which was a complete answer while
    # every row on it was the same kind of row. It is not one now: SPGD-711 splits this population into
    # examples SpecGuard READ from their own description and examples it could not, and the second
    # group is both far smaller and the only one any "cannot see this test" sentence may describe. A
    # purely alphabetical order buries them — a run whose dark corner sits in `spec/workers/` hands the
    # reader a hundred rows of `spec/api/` that SpecGuard understands perfectly well, and the corner is
    # off the page.
    #
    # So the FIRST sort term is the reading, and it is spelled as the boolean `= 'derived'` because
    # Postgres orders `false` before `true`: unreadable rows head the page, derived rows follow, and
    # within each group the file-navigable order below is untouched. The three terms after it are still
    # total where the ones before tie, so two identical asks still return the same page — which the cap
    # makes load-bearing rather than tidy, for the reason stated above.
    def unannotated_in(test_run, limit: UNANNOTATED_EXAMPLES_LIMIT, spec_file: nil,
                            spec_directory: nil)
      scope = where(test_run_id: test_run.id, status: "unannotated")
      scope = scope.where(spec_file_path: spec_file) if spec_file
      scope = scope.where(sanitize_sql_array(["#{DIRECTORY_EXPRESSION} = ?", spec_directory])) if spec_directory

      scope
        .select(Arel.sql("spec_observations.*, #{UNANNOTATED_POPULATION_COUNTS}"))
        .order(Arel.sql("(#{READING_EXPRESSION} = 'derived')"), :spec_file_path, :line_number, :id)
        .limit(limit)
    end

    # WHERE ONE RUN'S ANNOTATION DEBT IS, rolled up by code AREA — the ranking the worklist above never
    # had, and the rung that makes `.unannotated_in`'s narrowing reachable.
    #
    # `.unannotated_in` orders FILE-NAVIGABLY and says so: it is a worklist, not a ranking, and its own
    # comment states that nobody arrives at it to find what something COSTS. `?spec_file=` and
    # `?spec_directory=` then let a caller start where the work is — but only a caller who ALREADY KNOWS
    # which area to name. Nothing in the response said. The three area/file rollups this endpoint serves
    # rank by DURATION and their `coverage_label` is `coverage_fraction(timed_count, recorded_count)`,
    # which is TIMING coverage — so an agent told to raise a repository's annotation coverage had a
    # headline integer, a hundred alphabetical rows, and no way to choose. This read is the missing rung:
    # it names the areas the debt is concentrated in, and each one is a `?spec_directory=` away.
    #
    # == It is `.directory_durations_in` with a different ranked quantity, deliberately
    #
    # Same GROUP BY on `DIRECTORY_EXPRESSION`, same `where(test_run_id:)` narrow, same `COUNT(*) OVER ()`
    # riding back to disclose the population the cap cut. What differs is what it ranks by, which is why
    # it is a sibling rather than a parameter on that read: an area's wall clock and an area's unannotated
    # count are independent quantities, and folding a second ranking into one method would make every
    # caller of the first pay for a column it does not read.
    #
    # == `COUNT(*) FILTER (WHERE status = 'unannotated')`, and the predicate is spelled VERBATIM
    #
    # NEVER `where.not(status: 'annotated')`, for the reason `.unannotated_in` argues in full above: the
    # negated form selects the same rows today and would stop doing so the moment a third status existed
    # — and would stop by silently ADOPTING it into a ranking captioned "unannotated" rather than by
    # going red. The rule is the same one grain up, and it is easier to break here, where the predicate
    # sits inside an aggregate rather than in a WHERE a reader scans first.
    #
    # A FILTERed aggregate rather than a `where(status:)` narrow on the whole read, and that is the
    # load-bearing shape of this method rather than a spelling preference. Narrowing the read would give
    # each group a `recorded_count` of its own UNANNOTATED rows — which is `unannotated_count` again
    # under a second name, a fraction that is 100% on every row. The denominator a reader needs is the
    # area's WHOLE population, so the WHERE stays open at the run and the predicate rides the aggregate.
    # It also keeps a fully-annotated area OUT of the ranking without dropping it from the count of areas
    # the run touched: a zero-debt area sorts last by construction and the cap removes it, while
    # `directory_count` still describes every area — the ranking is of debt, the disclosure is of the run.
    #
    # == The ordering: the DARK areas first, the debt second, the path last
    #
    # `unreadable_count DESC` leads, `unannotated_count DESC` breaks it, `#{DIRECTORY_EXPRESSION} ASC`
    # breaks that. Three terms, and this is the ONLY section in this block that says what they are.
    # SPGD-711 added the lead term and, for a round, left the old two-term section standing beside this
    # one — so a reader following `_unannotated_directories.html.erb`'s pointer here met a paragraph
    # calling the tiebreak the ranking, and met it FIRST. One section per ordering, or the next change
    # writes a third.
    #
    # Before SPGD-711 there was one quantity to rank by and the question did not arise; there are now
    # two, and they are not the same worklist. `unannotated_count` is ANNOTATION DEBT — areas somebody
    # has not written an `@intent` for yet — and it is the number a reader raising the authored ratio
    # works down. `unreadable_count` is where SpecGuard has NOTHING: no annotation and a description it
    # could not read either, which is the only population the product may describe as invisible and, on
    # a suite written in the ordinary shapes, a far smaller one.
    #
    # The dark areas lead because the cap is ten. A ranking led by debt on a suite that has never
    # annotated anything is a ranking by area SIZE — the ten biggest directories, in size order, every
    # time — and the handful of areas SpecGuard genuinely cannot read never appear. Led by unreadable
    # count, the ten rows are the ten places worth looking, and debt still orders every area that ties
    # at zero unreadable, which on a fully-readable suite is all of them: the old ranking survives
    # intact underneath, as the tiebreak it now is.
    #
    # `#{DIRECTORY_EXPRESSION} ASC` comes last and is a TOTAL tiebreak, so two areas tying on BOTH
    # counts come back in the same order on two identical asks. The cap makes that load-bearing rather
    # than tidy — a reader comparing this ranking across two requests must not be handed a re-shuffled
    # tail, which is the same argument `.unannotated_in` makes for its third sort term. No `NULLS LAST`
    # clause and none wanted: `COUNT` returns 0 where `SUM` returns NULL, so unlike
    # `.directory_durations_in` this read has no null-ranked rows to keep off the head.
    #
    # == Query cost
    #
    # One grouped aggregate over ONE RUN, issued only when the parameter was sent. NO NEW INDEX, for the
    # reason `.directory_durations_in` states at length: it groups on an EXPRESSION and narrows on a
    # COLUMN, and only the second decides the access path — `where(test_run_id:)` is served by
    # `index_spec_observations_on_test_run_id` and the aggregation sits on top of that scan either way.
    # There is deliberately no `(test_run_id, status)` index and this read does not want one; `status` is
    # two values over a whole table, which is the shape an index serves worst, and the FILTER is applied
    # to rows the group has already touched. Certified in `spec/models/spec_observation_spec.rb` on the
    # one thing that has to stay true — one run reached through an index rather than every run's rows
    # walked.
    #
    # == Four counts per area, from ONE grouped pass
    #
    # `authored`, `derived` and `unreadable` come back beside the `unannotated` and `recorded` totals
    # that were already here, all as FILTERed aggregates over the same open WHERE — so the panel can
    # show the three states side by side without any of them being able to describe a different
    # population from the others. `unannotated_count` is retained rather than recomputed as
    # `derived + unreadable`: it is the figure that reconciles against `total_specs -
    # annotated_specs`, and a caller must be able to read it without knowing that identity.
    #
    # The new columns are APPENDED to the tuple, leaving `UnannotatedDirectories::DIRECTORY_COUNT_INDEX`
    # pointing where it did — the tuple shape is a stated contract between the two objects and this
    # keeps the statement true rather than renumbering it.
    def unannotated_directories_in(test_run, limit: UNANNOTATED_DIRECTORIES_LIMIT)
      where(test_run_id: test_run.id)
        .group(Arel.sql(DIRECTORY_EXPRESSION))
        .order(Arel.sql("#{READING_COUNTS['unreadable']} DESC"),
               Arel.sql("COUNT(*) FILTER (WHERE status = 'unannotated') DESC"),
               Arel.sql("#{DIRECTORY_EXPRESSION} ASC"))
        .limit(limit)
        .pluck(Arel.sql(DIRECTORY_EXPRESSION),
               Arel.sql("COUNT(*) FILTER (WHERE status = 'unannotated')"),
               Arel.sql("COUNT(*)"),
               Arel.sql("COUNT(*) OVER ()"),
               *READINGS.map { |reading| Arel.sql(READING_COUNTS[reading]) })
    end

    # WHERE ONE AREA'S ANNOTATION DEBT SITS, rolled up by spec file — the rung between
    # {.unannotated_directories_in} above and {.unannotated_in} below, and the one the worklist's
    # own cap kept out of reach.
    #
    # The worklist orders FILE-NAVIGABLY and is capped at {UNANNOTATED_EXAMPLES_LIMIT} rows; the
    # area ranking above it names the areas and `?spec_directory=` narrows the worklist to one of
    # them. What neither does is name the files of that area — SPGD-622 closed this gap one rung up
    # for areas, and a reader who picked one still knew no more about its files than they did about
    # the run's areas before that read existed. The narrowing that WOULD have shown them,
    # `?spec_file=`, is a question about a file you ALREADY KNOW — which is exactly what a reader
    # working down an area's debt does not have. This read is what tells them, so a file whose rows
    # fall past the worklist's cap is still named, still one link away, and its link opens a
    # worklist that starts at its own rows.
    #
    # == It is {.unannotated_directories_in} one grain down, deliberately
    #
    # Same open WHERE at the run, same `COUNT(*) FILTER (WHERE status = 'unannotated')` aggregate,
    # same three-term ordering, same `COUNT(*) OVER ()` disclosure — grouped on `spec_file_path`
    # and narrowed on `DIRECTORY_EXPRESSION = ?` instead. The narrow is the predicate
    # {.files_in_directory} ships — the IMMEDIATE PARENT compared for EQUALITY, never a prefix
    # `LIKE` — and it is taken through `DIRECTORY_EXPRESSION` rather than a hand-copy of it, for
    # the reason that constant's own comment gives: the area a link names must be computed by the
    # same expression the answering read filters on, or a row in the ranking opens an empty panel.
    #
    # == `HAVING unannotated > 0`, and why a file with no debt is OMITTED where an area is a row
    #
    # The area ranking keeps a fully-annotated area as a row carrying a zero, and its comment calls
    # that a decision rather than a leak; this read drops the equivalent file. Both are right, and
    # the difference is the question each answers. The area ranking surveys where a run's debt
    # STANDS — "this area has none" is a fact about the survey and `directory_count` has to cover
    # the run's every area. This read is a worklist of work within one area: a file every one of
    # whose examples carries an `@intent` has nothing on it to annotate, so listing it at zero
    # would pad a to-do list with rows that cannot be worked. What is preserved instead is the
    # disclosure: `COUNT(*) OVER ()` is evaluated after the `HAVING`, so `file_count` counts the
    # files CARRYING DEBT — not the area's every file, which is what `.files_in_directory`'s window
    # of the same shape counts over the same grain. The two windows share a construct and not a
    # population, and neither may be read as the other.
    #
    # == The predicate is spelled VERBATIM, exactly as the area ranking's is
    #
    # `COUNT(*) FILTER (WHERE status = 'unannotated')`, never `where.not(status: 'annotated')` and
    # never `!= 'annotated'`: the negated form selects the same rows today and would stop doing so
    # the moment a third status existed — and would stop by silently ADOPTING it into a file list
    # captioned "unannotated" rather than by going red. {READINGS} rides the same rule one column
    # over: {READING_COUNTS} is reused whole rather than retyped, so a file's readings and the
    # area's readings one rung up can never disagree about what a reading is.
    #
    # == The ordering: the DARK files first, the debt second, the path last
    #
    # The area ranking's three terms exactly — {READING_COUNTS['unreadable']} `DESC`, the
    # unannotated `FILTER` count `DESC`, the path `ASC` — and for the same reason. A ten-row list
    # led by debt on an area that has never annotated anything is a ranking by file SIZE, and the
    # handful of rows SpecGuard genuinely cannot read never surface; led by unreadable count, the
    # ten rows are the ten files worth opening, and debt still orders every file that ties at zero
    # unreadable. The path comes last and is a TOTAL tiebreak, so two identical asks return the same
    # page — which the cap makes load-bearing rather than tidy, the argument
    # {.unannotated_directories_in} states for its own third term. No `NULLS LAST` and none wanted:
    # `COUNT` returns 0, so unlike the duration reads there is no null-ranked row to keep off the head.
    #
    # == Query cost
    #
    # One grouped aggregate over ONE AREA's rows of ONE run, issued only when the parameter was
    # sent — the narrow is {.files_in_directory}'s own, an EXPRESSION predicate that buys no index
    # and decides nothing about the access path: `where(test_run_id:)` is served by
    # `index_spec_observations_on_test_run_id` and the aggregation sits on top of that scan either
    # way. There is deliberately no `(test_run_id, status)` index, for the reason both sibling
    # reads state: `status` is two values over a whole table, which is the shape an index serves
    # worst. No `layer:` parameter, either — the worklist and the area ranking narrow on nothing
    # declared, and a rung between them does not invent the narrowing they both decline.
    #
    # == Four counts per file, from ONE grouped pass
    #
    # `authored`, `derived` and `unreadable` ride back beside the `unannotated` and `recorded`
    # totals, all as FILTERed aggregates over the same open WHERE — so no column can describe a
    # different population from the others, and `unannotated_count` stays its own counted column
    # rather than being recomputed as `derived + unreadable`: it is the figure that reconciles
    # against `total_specs - annotated_specs`, the reason {.unannotated_directories_in} keeps it.
    #
    # The tuple is the area ranking's one grain down —
    # `[spec_file_path, unannotated, recorded, file_count, authored, derived, unreadable]` — with
    # the window count at index 3 where `DIRECTORY_COUNT_INDEX` sits on the sibling, a shape
    # `UnannotatedFiles::FILE_COUNT_INDEX` states rather than a positional habit.
    #
    # @return [Array<Array>] `[spec_file_path, unannotated_count, recorded_count, file_count,
    #   authored_count, derived_count, unreadable_count]` per file carrying debt, dark files first.
    def unannotated_files_in(test_run, spec_directory:, limit: UNANNOTATED_FILES_LIMIT)
      where(test_run_id: test_run.id)
        .where(sanitize_sql_array(["#{DIRECTORY_EXPRESSION} = ?", spec_directory]))
        .group(:spec_file_path)
        .having(Arel.sql("COUNT(*) FILTER (WHERE status = 'unannotated') > 0"))
        .order(Arel.sql("#{READING_COUNTS['unreadable']} DESC"),
               Arel.sql("COUNT(*) FILTER (WHERE status = 'unannotated') DESC"),
               Arel.sql("spec_file_path ASC"))
        .limit(limit)
        .pluck(Arel.sql("spec_file_path"),
               Arel.sql("COUNT(*) FILTER (WHERE status = 'unannotated')"),
               Arel.sql("COUNT(*)"),
               Arel.sql("COUNT(*) OVER ()"),
               *READINGS.map { |reading| Arel.sql(READING_COUNTS[reading]) })
    end

    # HOW THIS RUN READS, in one line per state — the run-grain answer the Overview panel replaced a
    # subtraction with, and the figure every "SpecGuard cannot see N tests" sentence on this product is
    # now taken from.
    #
    # == Why a subtraction could not stay
    #
    # `total_specs_count - annotated_specs_count` is exact, cheap, and answers a question nobody asked:
    # it counts the examples with no AUTHORED intent and was rendered as the examples SpecGuard cannot
    # SEE. Those are the same number only on a suite whose descriptions say nothing. This read is what
    # separates them, and it can only be a read over the rows: the counters know a status and nothing
    # about a description.
    #
    # == The population is the RUN'S ROWS, and that is disclosed rather than smoothed over
    #
    # `UnannotatedExamples` states the separation in full and both dashboard panels already print it:
    # the run's counters are re-derived by SUM over `test_run_shards` from what each shard REPORTED,
    # while these are the observations actually STORED, and on a sharded or partially-redelivered run
    # the two legitimately differ. So {IntentReadings#recorded} rides back with the three states rather
    # than being assumed equal to `total_specs_count` — a surface that wants a denominator for these
    # three has one that was counted with them, and a surface that wants the suite size keeps reading
    # the counter.
    #
    # A run with no per-example rows at all — one ingested before they existed, or from a client
    # sending only totals — comes back all zeros with `recorded` zero, which {IntentReadings#recorded?}
    # turns into "this run has nothing to say" rather than "this run is entirely readable".
    #
    # == Cost
    #
    # ONE aggregate row over ONE run, served by `index_spec_observations_on_test_run_id`, issued once
    # per page. No GROUP BY, so `pick` returns the single row the four aggregates produce — the same
    # shape and the same reasoning as `TestRun#shard_totals`.
    def reading_counts_in(test_run)
      run_counts_in(test_run).first
    end

    # Where ONE run's wall clock went, rolled up by DIRECTORY — the rung directly above the rollup
    # above, and the grain the question is usually asked in. "Which area of this suite carries the
    # time" is not answerable from a ranked list of files any more than it was from a ranked list of
    # examples: a directory holding forty files at two seconds each is eighty seconds of the run with
    # not one of its files near the head of a by-file top ten. Concentration re-concentrates one rung
    # up, and each rung has to be summed to be seen.
    #
    # Grouped on `DIRECTORY_EXPRESSION` — the immediate parent of the INCLUDING file — so a shared
    # example group's time lands on the area that ran it rather than on `spec/support`, and so the
    # areas listed partition the run rather than nesting inside one another. Depth selection and
    # drill-down trees are a different question and deliberately not this one: every row here is at
    # the same depth as its own file, so the totals are disjoint and sum to the run.
    #
    # NOT a shard. `TestRun#shard_durations` rolls a run up by CI partition and its comment is
    # explicit that "a shard is not a code area" — RSpec/Knapsack partitions are arbitrary with
    # respect to directory structure. That grain answers "which partition ran long"; this one answers
    # "which area of the codebase costs", and neither is derivable from the other.
    #
    # @return [Array<Array>] `[directory, total_seconds, recorded_count, timed_count,
    #   distinct_name_count, named_count, directory_count]` per directory, where `directory_count` is
    #   the same figure on every row: how many directories the run touched in total, before the
    #   `LIMIT`. The window function stays LAST in the tuple, and the two description figures were
    #   inserted BEFORE it rather than appended after — see the note below.
    #
    # == Every hazard the by-file read documents, at this grain
    #
    # The duration columns, `pluck` over `.sum`, and `NULLS LAST` are all here for the reasons
    # spelled out on `.file_durations_in` above — read that comment, it is not repeated. What changes
    # with the grain is only how much each one costs when it is got wrong: an area is a bigger
    # population than a file, so an all-untimed area rendered as `0.00s` is a bigger invented
    # measurement, and `SUM(...) DESC`'s NULLS FIRST would name that area the heaviest in the suite.
    #
    # == How many DISTINCT DESCRIPTIONS an area's examples carry, and the count that rides beside it
    #
    # The third figure of the area-grain reading — "this area carries 340 examples and 6 minutes of
    # wall clock for what looks like ~40 distinct behaviors". It is measured HERE, in the aggregate
    # that already produces the other two, because a caption is a claim about a list: a density
    # counted by a second read is a claim about a population this one did not group. No migration and
    # no new index. It is NOT free, and what it costs is written down below rather than waved at.
    #
    # `COUNT(DISTINCT name)` SKIPS NULLS SILENTLY and `name` is nullable, so on its own it reports an
    # area whose producer sent no descriptions as ZERO distinct behaviors against 340 examples — the
    # most extreme over-coverage reading obtainable, invented out of silence. So `COUNT(name)` rides
    # back beside it and the density is only ever stated over the NAMED rows, with the excluded ones
    # visible: the same `recorded_count` / `timed_count` fraction this method already carries for
    # timings, applied to the second nullable column. `RepeatedDescriptions` draws the same
    # distinction one grain down and `.unnamed_row_count_in` above refuses the same silence for a
    # window. What the ratio MEANS is not decided here or anywhere downstream — repetition is equally
    # the ordinary shape of a table-driven loop or a shared example group.
    #
    # POSITION IS A DECISION, not an accident: `SpecDirectoryDurations.for` reads the window count off
    # the end of the tuple, so appending after `COUNT(*) OVER ()` would have kept every caller running
    # while silently handing it a description count as a directory count. The window stays last, and
    # the caller now reads it by an explicit index rather than by `.last`.
    #
    # == What the DISTINCT aggregate COSTS: the hash strategy, and this read alone pays it
    #
    # A `DISTINCT` aggregate disqualifies hashed aggregation in Postgres, so adding `COUNT(DISTINCT
    # name)` moved this read off `HashAggregate` and onto `Sort` + `GroupAggregate`, sorting the run's
    # rows on the directory expression AND on `name` before grouping them. That is a REAL price and
    # this comment used to deny it: the access path did not change, which is a narrower claim than the
    # plan not changing, and the two were being read as the same sentence.
    #
    # Measured, not asserted — EXPLAIN (ANALYZE, BUFFERS) over one 20,000-example run, the stated
    # design point, at the default `work_mem` of 4MB:
    #
    #     before   HashAggregate           Memory:  145kB   Buffers: shared hit=753
    #     after    Sort + GroupAggregate   Memory: 2911kB   Buffers: shared hit=753
    #
    # What that buys and what it costs. The buffer counts are IDENTICAL — the sort reads no page the
    # hash did not already read, because both sit on the same index scan of the same one run, which is
    # the part "the access path is unchanged" was always about. The sort is bounded by ONE RUN's rows,
    # never by the table, and it is the run's rows this read already had to fetch. What it adds is
    # ~2.8MB of `work_mem` and a sort of 20,000 rows on two text columns, per render of this panel.
    #
    # The wall-clock difference is deliberately NOT quoted as a figure. Repeated on one box it ran
    # 53-58ms before and 57-69ms after — a real cost whose ranges OVERLAP, so any single pair of
    # numbers picked out of that would be a precision this measurement does not have, which is the
    # error this whole section exists to correct. What is stable across every repetition is the
    # strategy, the sort memory and the buffer count above; those are what the claim rests on.
    #
    # Priced as acceptable: the panel is one read on one page load, not a hot path, and tens of
    # milliseconds is well inside the budget for rendering a dashboard. The figure is worth a sort.
    #
    # Where it stops being acceptable: 2911kB sits under the default 4MB with less room than it looks
    # — at `work_mem = 1MB` the same read spills to `external merge Disk: 2040kB`. So a deployment
    # that tightens `work_mem`, or a suite materially past the design point, buys disk I/O rather than
    # CPU here. The strategy is pinned by an EXPLAIN example in spec/models/spec_observation_spec.rb
    # so that an edit which loses the in-memory sort is visible rather than silent.
    #
    # == Why this still needs no index of its own
    #
    # It groups on an EXPRESSION and narrows on a COLUMN, and only the second decides the access
    # path. `where(test_run_id:)` is served by `index_spec_observations_on_test_run_id`, and the
    # aggregation — hash before this change, sort-and-group after it — sits on top of that scan
    # either way. No index available here changes that: the aggregate has to touch the heap for
    # `duration_seconds` whatever it does, so no wider index buys a whole-run grouping anything, and
    # an index leading with `name` would not be read by a grouping keyed on the directory expression.
    # A `text_pattern_ops` index governs a prefix PREDICATE — "every row under `spec/models/`" — and
    # this read has no prefix predicate to serve. All of it is EXPLAIN-certified at the 20-run seed in
    # that spec rather than argued for here.
    #
    # == `layer:` — the layer in the query, before `GROUP BY` and `LIMIT`
    #
    # With a declared layer asked ({DECLARED_LAYER_KEYS} member), the rows are narrowed through
    # {.in_declared_layer} — the one shared predicate {.slowest_in}, {.coverage_in} and
    # {.file_durations_in} use, never retyped — BEFORE grouping, so the ranking is by THAT layer's
    # `SUM(duration_seconds)` and the cut is made over that layer's areas. It cannot be recovered from
    # the unfiltered top ten: an area whose request-layer time is large and whose all-layer time is not
    # would sit below the cut. `COUNT(*)` / `COUNT(duration_seconds)` are then the layer's own per-area
    # counts, and `COUNT(*) OVER ()` (still the tuple's index 6) is the number of areas with at least one
    # example in the layer. `nil` — the default — is byte-identical to the unnarrowed read, and the
    # layer-asked read is still ONE grouped statement.
    def directory_durations_in(test_run, limit: HEAVIEST_DIRECTORIES_LIMIT, layer: nil)
      in_declared_layer(where(test_run_id: test_run.id), layer)
        .group(Arel.sql(DIRECTORY_EXPRESSION))
        .order(Arel.sql("SUM(duration_seconds) DESC NULLS LAST"), Arel.sql("#{DIRECTORY_EXPRESSION} ASC"))
        .limit(limit)
        .pluck(Arel.sql(DIRECTORY_EXPRESSION), Arel.sql("SUM(duration_seconds)"),
               Arel.sql("COUNT(*)"), Arel.sql("COUNT(duration_seconds)"),
               Arel.sql("COUNT(DISTINCT name)"), Arel.sql("COUNT(name)"),
               Arel.sql("COUNT(*) OVER ()"), *directory_layer_count_expressions)
    end

    # The spec FILES of ONE code area in ONE run, heaviest first — the rung between the by-directory
    # rollup above and `.in_file` below it, and the one that was missing.
    #
    # `.directory_durations_in` names the ten areas the run spent most of its wall clock in and
    # `.in_file` lists one file's examples, but nothing joined the two: the by-file rollup is also a
    # capped ten, and the class comment on `SpecDirectoryDurations` states why that is not a way in —
    # "a directory holding forty files at two seconds each is eighty seconds of the run with not one
    # of its rows in that list". The heaviest AREA is precisely the one whose files are structurally
    # absent from a by-file top ten, so its files could be reached from nowhere. This is that read.
    #
    # == An EQUALITY narrow at one depth, and deliberately not a subtree
    #
    # The predicate is `DIRECTORY_EXPRESSION = ?` — the area a row is IN, compared for equality with
    # the area that was asked for. It is not `spec_file_path LIKE 'spec/models/%'`, and the
    # difference is the whole reason this ships without a migration. A prefix predicate is what a
    # `text_pattern_ops` index serves, and it would also gather `spec/models/orders/` into
    # `spec/models/` — re-opening the drill-down TREE that `.directory_durations_in` above says is
    # "a different question and deliberately not this one". Every row here sits at the same depth as
    # its own file, exactly as every row of the rollup does, so this listing partitions its area the
    # way that rollup partitions the run. An edit that grows a prefix `LIKE` has left what this
    # method is allowed to say.
    #
    # Through `DIRECTORY_EXPRESSION` rather than a hand-copy of it, for the reason that constant's own
    # comment gives: three hand-copies of one expression are three definitions of what an area IS, and
    # this one has to agree with the GROUP BY that produced the path being asked about — a link whose
    # target is computed one way and answered another opens an empty panel on a row that has rows.
    #
    # == Grouped by FILE, and the counts are the file's
    #
    # `SUM(duration_seconds)` per file with `NULLS LAST`, for the reason every read on this table
    # gives: `SUM` skips a missing timing silently, `DESC` alone is NULLS FIRST in Postgres, and a
    # file none of whose examples were timed would otherwise be named the heaviest in the area with a
    # total it did not measure. `COUNT(*)` and `COUNT(duration_seconds)` ride along per group, so each
    # row can state what its own total was summed over.
    #
    # == Three windows, so the caption is counted before the cap
    #
    # `COUNT(*) OVER ()` counts the area's FILES — windows run after `GROUP BY` and before `LIMIT`, so
    # it counts groups rather than rows on the page and counts all of them however few come back. The
    # same trick `FILE_POPULATION_COUNTS` uses one grain down and `.directory_durations_in` uses one
    # grain up, and for the same reason: a capped list whose own length is the only figure available
    # cannot tell three files from three hundred.
    #
    # The other two are `SUM(COUNT(...)) OVER ()` — an aggregate under a window, which is the only
    # spelling that reaches the AREA's example counts from a read grouped by file. They are what lets
    # the panel state its timing coverage over the whole area rather than over the files that fit,
    # which on a truncated area are different populations. `.directory_growth_between` uses the same
    # construct for the same reason: a total that describes the page is a claim about the page.
    #
    # == Why this needs no index of its own
    #
    # It narrows on `test_run_id` — served by `index_spec_observations_on_test_run_id` — and adds an
    # EXPRESSION predicate that no index can serve and that therefore decides nothing about the access
    # path. That is the ACCESS PATH `.file_durations_in` gets, for the reason its comment states: the
    # aggregate has to touch the heap for `duration_seconds` either way, so no wider index buys a
    # whole-run grouping anything. EXPLAIN-certified at the 20-run seed in
    # spec/models/spec_observation_spec.rb rather than argued for here.
    #
    # This comment used to go on to claim "the grouping hash-aggregates on top", and to cite
    # `.directory_durations_in` as the exemplar for that. BOTH halves were wrong and are worth
    # recording as wrong, because the second is a trap. Measured at the 20-run seed: this read gets
    # `Sort` + `GroupAggregate` (the planner estimates three groups, at which size sorting is simply
    # cheaper), while `.file_durations_in` — same table, same absence of a `DISTINCT` aggregate, 25
    # groups — gets `HashAggregate`. So for THIS read the strategy is a cost tiebreak that moves with
    # the data, and no comment here should promise either one.
    #
    # `.directory_durations_in` is not that, and that is why it is no longer cited here: its
    # `COUNT(DISTINCT name)` disqualifies hashed aggregation outright, so its sort is structural
    # rather than a tiebreak, and its own comment prices it in measured milliseconds. A read whose
    # strategy is chosen and a read whose strategy is forced are not exemplars of each other.
    #
    # == Declared-layer operands, appended
    #
    # After those seven, ten more: the FILE's five declared-layer counts (`directory_layer_count_expressions`,
    # in `DECLARED_LAYER_KEYS` order) and then the AREA's five, each the same FILTER aggregate under
    # `SUM(...) OVER ()` — so the area's mix is counted before the `LIMIT`, by the rule `recorded_count`
    # follows. Same grouped read, no extra query, no index; positions 0-6 keep their meaning.
    #
    # == `layer:`
    #
    # Narrows the area to the examples that declared ONE layer ({DECLARED_LAYER_KEYS}) through
    # {.in_declared_layer} — the predicate the layer-ranked "Heaviest spec directories" rollup counts
    # with — before the grouping. The windows and the per-layer counts evaluate after the WHERE, so the
    # area's file, recorded, timed and layer counts equal that rollup row's. `nil` (the default) is the
    # unnarrowed read, byte-identical to before.
    #
    # @return [Array<Array>] `[spec_file_path, total_seconds, recorded_count, timed_count, file_count,
    #   directory_recorded_count, directory_timed_count, *file_layer_counts, *directory_layer_counts]`
    #   per file, heaviest first. Positions 4-6 are the same figures on every row: how many files the
    #   area holds, and how many examples it holds and timed — all counted before the `LIMIT`; the last
    #   five are likewise area-wide.
    def files_in_directory(test_run, directory, limit: SPEC_DIRECTORY_FILES_LIMIT, layer: nil)
      in_declared_layer(where(test_run_id: test_run.id)
                          .where(sanitize_sql_array(["#{DIRECTORY_EXPRESSION} = ?", directory])), layer)
        .group(:spec_file_path)
        .order(Arel.sql("SUM(duration_seconds) DESC NULLS LAST"), spec_file_path: :asc)
        .limit(limit)
        .pluck(Arel.sql("spec_file_path"), Arel.sql("SUM(duration_seconds)"),
               Arel.sql("COUNT(*)"), Arel.sql("COUNT(duration_seconds)"),
               Arel.sql("COUNT(*) OVER ()"),
               Arel.sql("SUM(COUNT(*)) OVER ()"),
               Arel.sql("SUM(COUNT(duration_seconds)) OVER ()"),
               *directory_layer_count_expressions,
               *directory_layer_count_expressions.map { |expression| Arel.sql("SUM(#{expression}) OVER ()") })
    end

    # The descriptions that MORE THAN ONE example of ONE run recorded, ranked by the wall clock those
    # examples cost between them — the first read in this application that groups examples by
    # description on a run that is not red.
    #
    # == Why this did not already exist
    #
    # `GROUP BY name` in this file's cross-run reads is gone — the flakiness panel now groups on
    # `spec_identity_id` (`.unstable_identity_candidates_in` and
    # `.unstable_outcome_composition_in`), which never pools several examples of one run under one
    # key unless they resolved to ONE identity. So this read is the ONLY grouping by description
    # left, and on a GREEN suite — the normal case — nothing else groups examples by description at
    # all. The fact that several examples of one run share a description has otherwise only ever
    # been reachable as a by-product of the flakiness path, where
    # `UnstableTests::Row#shared_description?` computes it in order to THROW THOSE GROUPS AWAY:
    # there, an identity carried by two examples in one run is a matching-rule false positive to be
    # rejected. Here it is the finding.
    #
    # The population is documented on `UNSTABLE_COMPOSITION` above and is not hypothetical: *"a
    # table-driven loop, a shared example group or two genuinely identical `it` strings put several
    # examples under one description in the same run"*. Schema uniqueness is `(test_run_id,
    # example_id)` and nothing wider, so nothing prevents it.
    #
    # == Ranked by summed wall clock, and deliberately not by group size
    #
    # An eight-example group costing two seconds matters less than a three-example group costing
    # ninety, and the question this read exists to serve is redundancy WEIGHED AGAINST duration. So
    # the ordering is the one every duration rollup on this table uses, `NULLS LAST` included, for the
    # reason `.directory_durations_in` gives at length: `SUM(...) DESC` is NULLS FIRST in Postgres, so
    # a group none of whose examples were timed would otherwise be named the most expensive repetition
    # in the suite on the strength of a total nobody measured. `name` breaks ties, so a run whose
    # groups total equally has one stable order rather than one the planner picks afresh per request.
    #
    # == What it does NOT say
    #
    # Nothing here is a verdict that the group is duplicated work. A shared description is evidence of
    # repetition and is also the ordinary shape of a `where` loop over a table of cases; which of the
    # two a group is cannot be decided from these rows, so the surface presents it for review and says
    # so — the echo-don't-judge rule `#outcome_label` states for the outcome word, at this grain.
    #
    # A null `name` is excluded, because a null is not a description and pooling every unnamed example
    # of the run into one group would invent the largest repetition on the page out of rows that share
    # nothing. How many rows that excludes is a separate question, asked by `.description_presence_in`
    # below and stated on the panel; dropping them silently is the reading this must not produce.
    #
    # == Why it needs no index of its own
    #
    # Verbatim the ACCESS PATH argument at `.directory_durations_in`: it narrows on `test_run_id` —
    # served by `index_spec_observations_on_test_run_id` — and GROUPS on a column no index leads on
    # for this predicate, which decides nothing about the access path.
    # `index_spec_observations_on_repository_id_and_name` exists and is NOT the path here: it leads on
    # `repository_id`, and a single-run narrow does not begin with it. EXPLAIN-certified at the 20-run
    # seed in spec/models/spec_observation_spec.rb rather than argued for here.
    #
    # Not "and the grouping hash-aggregates on top", which this comment used to say and which is
    # measurably false: the `ARRAY_AGG(DISTINCT spec_file_path)` in the `pluck` below disqualifies
    # hashed aggregation, so this read sorts on `name, spec_file_path` and group-aggregates — the
    # same price, from the same cause, that `.directory_durations_in` now writes down in full.
    #
    # @return [Array<Array>] `[name, total_seconds, recorded_count, timed_count, file_paths,
    #   group_count, repeated_recorded_count, repeated_timed_count]` per description, costliest first.
    #   `total_seconds` is nil for a group none of whose examples were timed. The last three are the
    #   same figures on every row — how many repeated descriptions the run holds, and how many
    #   examples they cover and timed between them — all counted before the `LIMIT`.
    #
    # `COUNT(*) OVER ()` is evaluated after `GROUP BY` and its `HAVING` and before the `LIMIT`, so it
    # counts repeated DESCRIPTIONS and counts all of them however few come back — the truncation
    # disclosure `.file_durations_in` documents. The two `SUM(COUNT(...)) OVER ()` totals are the
    # `.files_in_directory` construct and are here for the same reason: the panel's timing coverage
    # has to describe the whole repeated population rather than the head of it that fit on the page.
    #
    # == The trailing declared-layer operands
    #
    # After those eight, five more: the DESCRIPTION's declared-layer counts
    # ({.directory_layer_count_expressions}, in {DECLARED_LAYER_KEYS} order), each a `COUNT(*) FILTER`
    # in the SAME grouped pass — no second statement. They are appended AFTER the window totals so
    # `RepeatedDescriptions::WINDOW_INDEXES` keeps its meaning; the caller reads the totals by those
    # indexes, never from the tail.
    #
    # == `layer:` — repeated WITHIN a declared layer, narrowed before `GROUP BY`, `HAVING` and `LIMIT`
    #
    # With a declared layer asked ({DECLARED_LAYER_KEYS} member), the rows are narrowed through
    # {.in_declared_layer} — the one shared predicate {.slowest_in}, {.coverage_in} and
    # {.file_durations_in} use, never retyped — BEFORE the grouping, so a group is a description carried
    # by more than one example OF THAT LAYER (`HAVING COUNT(*) > 1` runs over the layer's rows), and the
    # ranking and the cut are by that layer's own `SUM(duration_seconds)`. It cannot be recovered from
    # the unasked top ten: a description repeated four times inside the request layer can sit below
    # the cut of a run-wide ranking led by cheaper-per-example unit loops. Every figure is then the
    # layer's — each group's `COUNT(*)` / `COUNT(duration_seconds)` / layer operands and the three
    # window totals (`group_count`, `repeated_*`) — and a description with exactly one example in each
    # of two layers is NOT repeated within either, so it is absent under both (the cross-layer
    # question — the same behaviour covered on several levels — is the near-duplicate census's
    # `layer_redundancy`, not this read's). `nil` — the default — is byte-identical to the unnarrowed
    # read, and the layer-asked read is still ONE grouped statement.
    def repeated_descriptions_in(test_run, limit: REPEATED_DESCRIPTIONS_LIMIT, layer: nil)
      in_declared_layer(where(test_run_id: test_run.id), layer)
        .where.not(name: nil)
        .group(:name)
        .having(Arel.sql("COUNT(*) > 1"))
        .order(Arel.sql("SUM(duration_seconds) DESC NULLS LAST"), Arel.sql("name ASC"))
        .limit(limit)
        .pluck(Arel.sql("name"), Arel.sql("SUM(duration_seconds)"),
               Arel.sql("COUNT(*)"), Arel.sql("COUNT(duration_seconds)"),
               Arel.sql("ARRAY_AGG(DISTINCT spec_file_path) FILTER (WHERE spec_file_path IS NOT NULL)"),
               Arel.sql("COUNT(*) OVER ()"),
               Arel.sql("SUM(COUNT(*)) OVER ()"),
               Arel.sql("SUM(COUNT(duration_seconds)) OVER ()"),
               *directory_layer_count_expressions)
    end

    # Whether ONE run's rows carry descriptions at all, and how many of them do not — the two facts a
    # description-grouped read has to establish BEFORE anything it returns can be read.
    #
    # The run-scoped counterpart of `.unnamed_row_count_in` above, which asks the same question of a
    # WINDOW and is not reusable here: that one narrows on `repository_id` and a list of runs because
    # the cross-run panel's population is a window, and handing it a one-element list would ride the
    # wrong index to answer a question about a single run.
    #
    # Two figures rather than one, and the second is the load-bearing addition. `recorded_count` of
    # zero and `unnamed_count` of zero is a run that wrote no rows at all; the repeated-description
    # read returns exactly the same empty list for it as it does for a suite whose every description
    # is unique. Rendered as "nothing is repeated here" that empty list is *Vacuous Green* — "nobody
    # told us" wearing the spelling of "there is no redundancy" — and `recorded_count` is what lets
    # the surface tell the two apart, exactly as `reported_outcome_count` does for the outcome
    # counters on `COVERAGE_COUNTS`.
    #
    # One aggregate over rows the run wrote, never `TestRun#total_specs_count`: that figure is
    # re-derived by SUM over `test_run_shards` and the class comment above is explicit that nothing
    # here re-derives it. `COUNT(*) FILTER (...)` rather than a second query, for the one-read reason
    # `.coverage_in` gives — a caption fetched separately from the list it describes is a claim with
    # no structural reason to keep agreeing with it.
    #
    # This IS a second round trip beside `.repeated_descriptions_in`, and it has to be: that read
    # excludes null names in its WHERE clause, so no window over it could ever have counted the rows
    # it dropped. `SlowestExamples` pays the same price for the same reason and `FILE_POPULATION_COUNTS`
    # records why the drill-down beside it does not have to.
    #
    # @return [Hash{Symbol=>Integer}] `recorded_count` and `unnamed_count`, both counted in rows.
    #
    # `layer:` narrows both counts to ONE declared layer through {.in_declared_layer}, the predicate
    # {.repeated_descriptions_in} narrows by, so the presence figures describe the SAME row set the
    # ranking grouped and `recorded_count - unnamed_count` still reconciles with the ranking's named
    # population. Still ONE statement; `nil` is the unnarrowed read.
    def description_presence_in(test_run, layer: nil)
      counts = in_declared_layer(where(test_run_id: test_run.id), layer)
               .pick(Arel.sql("COUNT(*)"), Arel.sql("COUNT(*) FILTER (WHERE name IS NULL)"))

      { recorded_count: counts[0].to_i, unnamed_count: counts[1].to_i }
    end

  end
end
