# frozen_string_literal: true

# The agent-readable half of the repository page: which repository a key resolves to, what the
# suite looked like the last time CI reported, and the bounded tail of what it looked like before
# that. Without the `latest_run` block below an agent can learn the suite's size only by running
# the suite and POSTing it — it cannot ask; and without `history` it can learn how the suite GREW
# only by polling this endpoint and subtracting one poll from the next, which is precisely the
# subtraction `TestRun` spends eighteen lines of its own documentation forbidding.
#
# Every figure is read off the same rows `repositories#show` renders from
# (`Repository#latest_test_run` and `#recent_test_runs`, which share an ordering tie-break
# included), so the API and the dashboard cannot name different commits for the same repository.
class Api::V1::RepositoriesController < Api::BaseController
  # How each `history` row was assembled, in one aggregate for the whole window. The same four
  # lines the human Recent-runs panel primes its rows with — see `ShardCountPreloading`, which is
  # one module rather than two copies because nothing in it needs anything an
  # `ActionController::API` lacks.
  include ShardCountPreloading

  # `?branch=` read as a branch name, to narrow `history` below. Shared with
  # `RepositoriesController`, which reads the same parameter under the same guard for the
  # suite-trajectory panel on repositories#show — see `RequestedBranchParam` for the guard's
  # reasoning, which used to sit here in full.
  include RequestedBranchParam

  # The bound on `history` below. Ten rows is ten rows whether the suite holds three tests or
  # twenty thousand — `Repository#recent_test_runs` argues that in its own comment — so this is a
  # bound and not the first page of a pagination contract there is no cursor to continue.
  HISTORY_LIMIT = 10

  # The bound when `?branch=` narrowed the window, which is DEEPER than the unfiltered one and is
  # the same depth `RepositoriesController` gives the human suite-size chart.
  #
  # Ten interleaved rows and ten rows of one branch are not the same amount of history. Unfiltered,
  # ten rows is a sample of what CI has been doing lately; filtered, it is the series itself, and
  # ten runs of a busy repository is an afternoon — `Repository::TRAJECTORY_LIMIT` documents that
  # reasoning where it was first made. Read off that constant rather than restated as `30`, so the
  # API's series and the dashboard's chart cannot come to disagree about how far back "the history"
  # reaches.
  #
  # `history_window.limit` serves whichever of the two applied, so no client has to know this rule
  # exists to know which bound it got.
  SINGLE_BRANCH_HISTORY_LIMIT = Repository::TRAJECTORY_LIMIT

  def show
    render json: {
      repository: {
        id: current_repository.id,
        full_name: current_repository.github_full_name,
        name: current_repository.name,
        registered_at: current_repository.created_at.iso8601
      },
      api_key: {
        name: current_api_key.name,
        last_used_at: current_api_key.last_used_at&.iso8601
      },
      latest_run: serialized_latest_run,
      history_window: serialized_history_window,
      history: serialized_history,
      branches_window: serialized_branches_window,
      branches: serialized_branches
    }
  end

  private

  # `nil` — not a zeroed block — when CI has never reported. A repository whose CI has never run
  # must not serialize byte-identically to one that ran and genuinely found an empty suite; that is
  # the conflation the Overview panel refuses too (see RepositoriesController#show).
  # `Repository#annotated_ratio` cannot express the difference, which is why this reads the run.
  #
  # NOT RE-ANCHORED BY `?branch=`. This names the repository's newest run and keeps naming it under
  # every request; only `history` narrows. A client filtering the history has asked a question about
  # a series, not for a different latest run, and re-anchoring would silently change the meaning of
  # four blocks (`latest_run`, `shards`, and the `history[0] == latest_run` identity the tie-break
  # examples pin) to answer one. The consequence is worth stating because it is the one surprise
  # here: under `?branch=main` on a repository whose newest run is on `feature/x`, `history[0]` is
  # a `main` row and `latest_run` is the `feature/x` one, and they are *supposed* to differ.
  # `history_window.branch_scope` is what says so.
  def serialized_latest_run
    test_run = current_repository.latest_test_run

    return nil if test_run.nil?

    {
      commit_sha: test_run.commit_sha,
      # Nullable, and Ingest::Payload accepts a body without it. `null` here means "the client did
      # not say", which is a different fact from any branch name we could substitute for it.
      branch: test_run.branch,
      total_specs: test_run.total_specs_count,
      annotated_specs: test_run.annotated_specs_count,
      annotated_ratio: annotated_ratio_for(test_run),
      # Nullable by schema. Serializing `0.0` for an unreported duration would assert the run took
      # no time — the same "not reported" vs `0.0s` distinction the Recent runs table draws.
      #
      # On a sharded run this is the MAX over the shards — the run's WALL CLOCK, not what the suite
      # cost. It keeps that key, that type and that value: `shards` below is added beside it rather
      # than in place of it, so nothing a client reads today changes meaning.
      duration_seconds: test_run.duration_seconds,
      shards: serialized_shards(test_run),
      spec_files: serialized_spec_files(test_run),
      # `TestRun#suite_size_measured?`, the same predicate `serialized_history_row` serves below and
      # for the same reason: a run that reported zero tests has a `total_specs` but not a
      # measurement, and a difference taken against it describes the report rather than the suite.
      # Served from the predicate and never re-derived inline from `total_specs`, so the endpoint,
      # the history row and the panel cannot drift on what "measured" means.
      #
      # It belongs HERE and not only on the history row, because in the unfiltered window
      # `history[0]` is the SAME ROW as this one — the identity `repository_latest_run_spec.rb`
      # pins and the ordering comment on `history_runs` protects. Withholding the key from one of
      # the two blocks let a single response body describe one row twice and disagree with itself:
      # `history[0]` saying the suite was never measured while `latest_run`, thirty lines up,
      # could not say it.
      #
      # Present on EVERY response that has a run — never absent, never null — on the rule
      # `timed_shard_count` follows: a guard a client has to test for before it can trust is not a
      # guard. A repository whose CI never reported has no `latest_run` block at all.
      suite_size_measured: test_run.suite_size_measured?,
      ingested_at: test_run.created_at.iso8601
    }
  end

  # The other half of what a sharded run cost, plus the denominator each cost figure was computed
  # over. `duration_seconds` above is a MAX and `machine_seconds` here is a SUM, and on the
  # project's canonical 4-shard fixture they differ by 3.4× — a client reading only the MAX
  # understates the suite's cost, with no caption to warn it the way the Overview panel has one.
  #
  # STRUCTURED COUNTS, NOT PROSE. `TestRun#machine_seconds_coverage` and `#wall_clock_coverage`
  # answer this same question for the panel, but they answer it in English ("slowest of the 3 that
  # reported"), and a machine-readable client cannot act on a sentence without parsing it. So this
  # serializes the counts those sentences are built from and lets the client word it — or not word
  # it at all and just divide.
  #
  # `coverage` keys each figure by the exact JSON name the client reads it under, so there is no
  # guessing which denominator belongs to which number: `coverage.duration_seconds` is how many
  # shards the MAX was taken over, `coverage.machine_seconds` how many the SUM was taken over, and
  # `count` is how many the run has. Today both are `timed_count` — SQL's MAX and SUM skip the same
  # nulls — but each states its own rather than sharing one field, because a client should not have
  # to know that they coincide, and a figure whose coverage is inferred from a neighbour is exactly
  # the honesty gap this block exists to close.
  #
  # `null` — not an empty or zeroed block — for a run with one shard or none, which is the entire
  # unsharded corpus. There is nothing to disambiguate there (one shard's MAX *is* its SUM, zero
  # shards have neither), and `multi_shard?` is the gate every caller must sit behind: `shard_totals`
  # returns a real `0` for a shardless run, so an ungated block would print `count: 0` and a
  # `machine_seconds: null` for a laptop run that reported a perfectly good duration. The KEY stays
  # present in every response, on the same rule `latest_run` itself follows — a client tests one
  # thing (`shards == null` → "not assembled from parts") rather than distinguishing an absent key
  # from a null one.
  #
  # WHICH SHARD, not just how many. The four scalars above say a run was assembled from four parts
  # and cost 253.75s between them; not one of them is a shard, so an agent reading only those
  # cannot learn which part it waited on. `repositories#show` has rendered the full decomposition —
  # the rows, the balanced floor, the excess over it — since SPGD-192, and the three keys added
  # below are the same model accessors that panel reads, so the API and the panel cannot name
  # different figures for the same run.
  #
  # `rows` mirrors `TestRun#shard_durations`' ordering VERBATIM rather than re-sorting here, which
  # is what makes `rows.first` and the panel's `longest_shard_label` the same shard by
  # construction instead of by coincidence.
  #
  # `shard_id` RAW AND NULLABLE, never a position number. `TestRun#shard_label` argues this at
  # length: a client that shards without naming its slices sends nothing, and numbering the rows
  # would hand the reader a name CI never used — one that points at a different slice next run.
  # The prose formatting (`"shard 3"` / `"an unnamed shard"`) stays view-side; a client that wants
  # a sentence can build one, and a client that wants to correlate against its CI config needs the
  # raw value.
  #
  # RAW FLOATS, not the panel's `humanized_seconds` labels, on the rule `duration_seconds` and
  # `machine_seconds` already follow on this endpoint. Prose in JSON is a figure a client has to
  # regex before it can compute with it.
  #
  # GATED ON `#wall_clock_decomposable?` ITSELF — called, not re-spelled. Two of its three
  # conditions are easy to reach for and the third is the one that matters:
  # `shard_delivery_settled?`. `Repository#latest_test_run` picks a run up the instant its FIRST
  # shard lands, so on a half-delivered run every shard present is timed and a two-condition gate
  # waves it through with a partial SUM over a partial count — both the floor and the excess move,
  # in the direction that manufactures a finding. And the gate is a correctness requirement rather
  # than only an honesty one: `#wall_clock_excess_seconds` documents that it RAISES on a nil
  # `duration_seconds`, which is exactly the state a run whose shards said nothing is in.
  #
  # `null` — the three keys still PRESENT — when the gate fails, on this block's own rule that a
  # client tests one thing rather than distinguishing an absent key from a null one. Never a
  # partial or mis-ordered list: `duration_seconds: :desc` is NULLS FIRST in Postgres, so an
  # ungated `rows` would put the shard that reported *nothing* at the head of a list whose whole
  # contract is "slowest first".
  #
  # TWO EXTRA QUERIES AT MOST, and constant rather than minimal. Both `#shard_durations` and
  # `#shard_reports` are documented as reads beside the memoized `shard_totals` aggregate, kept
  # separate so widening `shard_totals` does not change what its other callers load — so each
  # costs one more statement. They do not fall on the same runs: `#shard_reports` feeds `per_shard`
  # and is paid by every multi-shard run, while `#shard_durations` feeds the three gated keys and
  # is paid only when `#wall_clock_decomposable?` passes. So an ungated multi-shard run costs one
  # extra, a gated one costs two, and a shardless run pays nothing at all. What is bounded is that
  # neither scales: a 40-shard matrix costs exactly what a 4-shard one does. The gate
  # `#wall_clock_decomposable?` itself adds nothing (it reads the already memoized
  # `shard_totals`).
  def serialized_shards(test_run)
    return nil unless test_run.multi_shard?

    decomposable = test_run.wall_clock_decomposable?

    {
      count: test_run.shard_count,
      timed_count: test_run.timed_shard_count,
      # `null`, never `0.0`, when not one shard reported a timing — the rule `branch`,
      # `duration_seconds` and `annotated_ratio` already follow on this endpoint. SQL's SUM returns
      # NULL over an empty set rather than zero, and `TestRun#machine_seconds_reported?` is
      # deliberately a `nil?` check for the same reason: a run whose shards genuinely measured 0.0
      # has a measurement, and serializing "nobody reported" as a measured zero would understate
      # the suite's cost while looking like a fact.
      machine_seconds: test_run.machine_seconds,
      coverage: {
        duration_seconds: test_run.timed_shard_count,
        machine_seconds: test_run.timed_shard_count
      },
      rows: decomposable ? serialized_shard_rows(test_run) : nil,
      balanced_wall_clock_seconds: decomposable ? test_run.balanced_wall_clock_seconds : nil,
      wall_clock_excess_seconds: decomposable ? test_run.wall_clock_excess_seconds : nil,
      # The denominator of every duration above, per shard — the block's own STRUCTURED COUNTS,
      # NOT PROSE rule taken one level down. `machine_seconds` says what the run cost and
      # `coverage` says over how many shards; neither says whether the expensive shard was
      # expensive because it held more tests or because its tests cost more each, and the two take
      # opposite actions. `duration = count x cost per test`, so serving both columns lets a client
      # divide and decide — the Overview panel words that division in English, and this endpoint
      # exists so an agent does not have to parse the sentence.
      #
      # Two raw columns and no derived rate, deliberately: a `seconds_per_spec` key would be this
      # block shipping the arithmetic instead of the operands, and it would have to invent an
      # answer for a shard whose `total_specs` is `0` — a real row, since the column is
      # `null: false, default: 0`. A client dividing for itself sees the zero and decides.
      #
      # ADDED BESIDE the keys above, which keep their names, their types and their values, on the
      # rule `shards` itself followed when it was added beside `duration_seconds`.
      #
      # OVERLAPS `rows` ABOVE, and the overlap is the point rather than an oversight. SPGD-234
      # landed `rows` while this slice was in review; both list shards, and every row `rows` serves
      # appears here too with one more column. They are kept apart because they answer under
      # DIFFERENT GATES, and collapsing them would have to sacrifice one of the two:
      #
      #   - `rows` is RANKED and gated on `#wall_clock_decomposable?`. Its contract is
      #     "slowest first", and `duration_seconds: :desc` is NULLS FIRST in Postgres, so it is
      #     `null` whenever a shard reported no timing — the ordering would otherwise put the
      #     silent shard at the head of a list a client reads as the slowest one.
      #   - `per_shard` is UNRANKED delivery order, gated on `multi_shard?` alone. It makes no
      #     claim to rank, so it needs no such gate, and a test COUNT does not depend on a timing:
      #     `Ingest::RunRecorder#upsert_shard` writes `total_specs_count` on every sharded POST
      #     whether or not that shard timed itself.
      #
      # So moving `total_specs` onto `rows` would withhold a count that is perfectly well known on
      # exactly the runs where a reader most wants it — the half-delivered and partly-untimed ones
      # — and dropping `per_shard` in favour of `rows` would do the same. A client that wants the
      # ranking reads `rows`; one that wants a complete census of what each shard reported reads
      # `per_shard` and sorts for itself.
      per_shard: test_run.shard_reports.map do |shard_id, duration_seconds, total_specs|
        {
          # Nullable, and a nil one is an ordinary state rather than an omission —
          # `Ingest::RunRecorder#upsert_shard` records one row per delivery for a client that
          # shards without exposing an index the gem recognises. `null` says the client did not
          # name this slice; a positional index would hand back a name nothing in CI answers to.
          shard_id: shard_id,
          # `null`, never `0.0`, on the same rule the run's own `duration_seconds` follows.
          duration_seconds: duration_seconds,
          total_specs: total_specs
        }
      end
    }
  end

  # `#shard_durations` yields `[shard_id, duration_seconds, total_specs_count]` and this names the
  # two halves it serves, because a positional array would make a client index into a tuple whose
  # order it can only learn from prose — and `duration_seconds` is the one every reader sorts on.
  # The third column is deliberately dropped here rather than served: the counts go out on
  # `per_shard`, which is not behind this method's gate. See the reconciliation on `per_shard`.
  #
  # Called only from the gated branch above; it does no gating of its own, so do not call it from
  # anywhere that has not already asked `#wall_clock_decomposable?`.
  def serialized_shard_rows(test_run)
    test_run.shard_durations.map do |shard_id, duration_seconds|
      { shard_id: shard_id, duration_seconds: duration_seconds }
    end
  end

  # WHICH FILE the run spent its wall clock in — the same decomposition `repositories#show` has
  # rendered since SPGD-275, served to the client that has no page to read.
  #
  # This is `serialized_shards`' argument one axis over, and the substitution is exact. The scalars
  # above say a run cost 253.75s; not one of them is a file, so an agent reading only those cannot
  # learn WHERE the suite is slow — it can learn that it is. And a shard is not the answer: a shard
  # is a CI partition, `TestRun#shard_durations`' own comment is explicit that it is not a code
  # area, and "shard 3 was slow" names a machine while "spec/models/invoice_spec.rb was slow" names
  # something a reader can go and edit.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query. `SpecFileDurations` is already
  # view-free — `repositories_controller.rb` is its only other caller — so the API and the panel
  # rank the same files in the same order off the same rows of the same run, which is this file's
  # governing rule at the top and the one thing a second copy of the query could not promise.
  #
  # `rows` MIRRORS `SpecFileDurations#rows` VERBATIM and re-sorts nothing, on the rule
  # `serialized_shard_rows` follows: the aggregate orders `SUM(duration_seconds) DESC NULLS LAST,
  # spec_file_path ASC`, and that NULLS LAST is load-bearing rather than incidental — a re-sort
  # here on a plain `desc` would put the file that reported NOTHING at the head of a list whose
  # whole contract is "heaviest first". Inheriting the order is what makes `rows.first` and the
  # panel's heaviest file the same file by construction instead of by coincidence.
  #
  # STRUCTURED COUNTS, NOT PROSE, the rule `serialized_shards` states and this block obeys one
  # grain down. `Row#coverage_label` words this same coverage as `"4 of 12"` and `#duration_label`
  # words the total as `"1.23s"` / `"not reported"`; a machine-readable client cannot act on either
  # without parsing it. So `recorded_count` and `timed_count` go out as the integers those
  # sentences are built from and `total_seconds` as a raw float. This is also how the honesty
  # constraint is met PER ROW rather than only for the block: `SUM` skips NULLs silently, so a file
  # whose examples were half untimed reports a total covering half of it, and every row states what
  # its own total was summed over instead of leaving one caption to cover a list of mixed coverage.
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
  # 40-example one does. It sits inside the budget `serialized_shards` states above.
  def serialized_spec_files(test_run)
    durations = SpecFileDurations.for(test_run)

    return nil unless durations.recorded?

    {
      rows: durations.rows.map do |row|
        {
          path: row.path,
          total_seconds: row.total_seconds,
          recorded_count: row.recorded_count,
          timed_count: row.timed_count
        }
      end,
      file_count: durations.file_count,
      limit: SpecObservation::HEAVIEST_FILES_LIMIT
    }
  end

  # The contract the array below is served under, stated as tokens a client can compare rather
  # than a caption it would have to read. The human "Recent runs" panel carries this same warning
  # as a sentence under its heading (app/views/repositories/show.html.erb) — *"consecutive rows are
  # routinely two different branches. They are not a series"* — and a machine-readable consumer
  # cannot act on a sentence. Shipping the rows without these three facts would re-create that
  # panel's original defect one layer down, for a client that has no caption to fall back on.
  #
  # `branch_scope` is the load-bearing one. Unfiltered, `Repository#recent_test_runs` is the
  # interleaved history across EVERY branch CI reports from, so `history[0]` and `history[1]` are
  # routinely two different branches and the difference between their `total_specs` is not a change
  # in the suite. A client that wants a series asks for one with `?branch=`; a client that does not
  # filters on the per-row `branch` itself, and this block is what tells it that it must.
  #
  # `branch_scope` and `branch` are TWO keys rather than one interpolated token (`"branch:main"`),
  # on this block's own rule: a client compares `branch_scope` against a fixed vocabulary it can
  # hard-code, and reads the name out of `branch` without parsing. A token carrying the name would
  # be neither — every client would have to `start_with?` its way back to the two facts.
  #
  # `branch` IS ALWAYS SERVED, `null` when the window was not narrowed — the same key-always-present
  # rule `latest_run.shards` argues for itself above. A client tests one thing rather than
  # distinguishing an absent key from a null one, and the pair reads the same way in every response.
  # It restates what the SERVER filtered on, which is not always what the client sent: a non-String
  # or blank `?branch=` is no filter at all, and echoing the raw param would tell a client its
  # filter applied when it did not.
  #
  # `returned` beside `limit` rather than either alone: `returned == limit` is how a client learns
  # the suite has run at least `limit` times and this is the tail, not the whole history — the
  # inference it would otherwise draw wrongly from a full array.
  #
  # `limit` reports WHICH BOUND APPLIED, not a constant. A narrowed window is bounded at
  # `SINGLE_BRANCH_HISTORY_LIMIT` and an unfiltered one at `HISTORY_LIMIT`, and serving the applied
  # bound is what keeps `returned == limit` meaning the same thing under both — a client that had to
  # know the rule to interpret the number would be reading a caption again.
  #
  # `order` NAMES BOTH KEYS, because the second one is load-bearing and is not served. The rows are
  # ordered `(created_at, id) DESC` — `Repository#recent_test_runs`' ordering, tie-break included —
  # and `ingested_at_desc` alone would invite exactly the re-sort the serializer refuses to do
  # itself: two runs ingested in the same instant carry the same `ingested_at`, so a client sorting
  # on that field alone scrambles the very pair the tie-break exists to order, and can disagree with
  # `latest_run` about which commit is newest. Narrowing the window does not re-sort it; the branch
  # predicate rides along with the same `ORDER BY`.
  #
  # `tie_break_served: false` is the honest half of that. The tie-break key is the ingest sequence —
  # the runs table's own id — and this endpoint does not serialize it on a row, here or on
  # `latest_run`. So the ordering is NOT reproducible from the fields the client holds, which makes
  # the array's own order the authoritative answer rather than a rendering of one. A client that
  # needs a stable comparison reads the array in the order it arrived; one that must re-sort can
  # only do so within a set of distinct `ingested_at` values.
  def serialized_history_window
    {
      order: "ingested_at_desc,ingest_sequence_desc",
      tie_break_served: false,
      branch_scope: requested_branch ? "single_branch" : "all_branches",
      branch: requested_branch,
      limit: history_limit,
      returned: history_runs.length
    }
  end

  # Which bound applies, decided in ONE place so the window's `limit` and the query's `LIMIT` cannot
  # come apart. A response stating a bound it did not apply is worse than either bound alone: the
  # client's `returned == limit` test — its only signal that there is more history behind the
  # window — would answer about a number nothing enforced.
  def history_limit
    requested_branch ? SINGLE_BRANCH_HISTORY_LIMIT : HISTORY_LIMIT
  end

  # `[]` — not `null` — for a repository whose CI has never reported, which is the one place this
  # slice departs from the `latest_run`/`shards` rule a few methods up.
  #
  # That rule exists because a zeroed *block* asserts measurements that were never taken: a
  # `latest_run` of zeros claims a run happened and found nothing. An empty *list* asserts nothing
  # of the kind — "no runs" is exactly what zero rows means, and it is the same answer a client
  # gets after filtering a populated history down to a branch that never ran. Nulling it would
  # instead force every consumer to distinguish two spellings of the empty case before it could
  # iterate.
  #
  # AND IT IS THE ANSWER AN UNKNOWN `?branch=` GETS — never a fallback to the unfiltered window,
  # never another branch's rows. The human suite-size panel does fall back to its current anchor
  # when it is handed a branch it does not recognise, which is right for a page: the page renders a
  # visible notice beside the chart saying so. A JSON client has no notice. One that asked for
  # `main` and silently received `feature/x` rows would compute a growth series for the wrong
  # branch and have nothing in the body to detect it with — a two-branch error exactly as invisible
  # as the 0–1/0–100 ratio confusion `annotated_ratio_for` guards against below. So the ask is
  # restated in `history_window.branch`, `returned` says `0`, and the client can tell "that branch
  # has no runs" from "here is some other branch" because the second never happens.
  def serialized_history
    history_runs.map { |run| serialized_history_row(run) }
  end

  # What the human panel's row carries, plus the composition facts that say whether the row may be
  # differenced against its neighbour AND what each figure on it was measured over.
  #
  # TWO COUNTS AND NO COST FIGURE — deliberately not the whole `shards` sub-block
  # `serialized_shards` builds for the latest run. `machine_seconds` stays off the row on the
  # argument this comment has always made: a client differencing two rows needs to know they were
  # assembled from the same number of parts, not what each part cost, and the per-run cost figures
  # stay available in full on `latest_run`, which is one row and pays one `pick` for them.
  #
  # `timed_shard_count` is the exception that argument never covered, and it is not "what a part
  # cost" — it is THE DENOMINATOR OF A FIGURE THIS ROW ALREADY SERVES. `duration_seconds` on a
  # sharded run is the MAX over the shards that REPORTED, so its coverage is the timed count and
  # never `shard_count`; a row serving the numerator beside the wrong denominator lets a client
  # difference four timed shards (MAX 600s) against four shards whose two slowest were cancelled
  # (MAX 180s) — identical `shard_count`, identical `suite_size_measured` — and report a 70%
  # speedup produced entirely by telemetry loss. That is the same honesty gap `serialized_shards`'
  # `coverage` block exists to close: a figure whose coverage is inferred from a neighbour.
  #
  # `shard_count` is the right denominator for `total_specs` — a SUM over the shards RECORDED — and
  # is served for that reason; `TestRun#assembled_like?` decides differenceability on shard-count
  # equality alone, so this still serves exactly what that rule reads. The two counts are served
  # FLAT and side by side rather than under a `coverage:` sub-object, because the row is otherwise
  # flat and there are only two of them to keep straight.
  #
  # The three are cheap here only because `ShardCountPreloading` primes all of them from ONE grouped
  # aggregate over the whole window (see `history_runs`). What is left further down `shard_totals` —
  # `MAX(updated_at)` — is still one `pick` per row. The reason this row stops at the two counts is
  # now the semantic one alone: `machine_seconds` became affordable on a window when the repositories
  # grid needed it, and a client differencing two rows still needs to know they were assembled from
  # the same number of parts, not what each part cost.
  #
  # `suite_size_measured` is `TestRun#suite_size_measured?` — a run that reported zero tests has a
  # count but not a measurement, and a difference taken against it describes the report rather than
  # the suite. Serialized as the boolean rather than left for the client to re-derive from
  # `total_specs`, so the endpoint and the panel cannot drift on what "measured" means.
  #
  # Counts and booleans, never prose: `TestRun#delivery_description` and `#wall_clock_coverage`
  # word these same shard facts in English for the panel, and `serialized_shards` above already
  # settled that a machine-readable client cannot act on a sentence without parsing it.
  def serialized_history_row(run)
    {
      commit_sha: run.commit_sha,
      # Per-row, and non-negotiable: this is the field that turns the interleaved history
      # `history_window.branch_scope` warns about into an actual series. It stays served under
      # `?branch=` too, where every row carries the same value — a client should be able to read a
      # row's branch off the row rather than off the window it arrived in, and a narrowed window's
      # rows are otherwise indistinguishable from an unfiltered window that happened to be uniform.
      # `null` keeps its `latest_run` meaning — "the client did not say" — and an anonymous run
      # belongs to no series, which is why no `?branch=` value can select one.
      branch: run.branch,
      total_specs: run.total_specs_count,
      annotated_specs: run.annotated_specs_count,
      annotated_ratio: annotated_ratio_for(run),
      duration_seconds: run.duration_seconds,
      shard_count: run.shard_count,
      # A really-counted `0`, never absent and never null, on a run whose shards all went silent —
      # that run's `duration_seconds` was measured over nothing, and it is exactly the row a client
      # most needs to refuse to difference. A shardless run serves `0` beside a `shard_count` of
      # `0`, unchanged in meaning: there were no parts, so there were none to time.
      timed_shard_count: run.timed_shard_count,
      suite_size_measured: run.suite_size_measured?,
      ingested_at: run.created_at.iso8601
    }
  end

  # `Repository#recent_test_runs`' ordering, REUSED and never re-sorted. It is documented there as
  # deliberately sharing `latest_test_run`'s ordering tie-break included, which is what makes
  # `history[0]` and `latest_run` the same row rather than two rows that usually agree. Re-sorting
  # here — or ordering by `created_at` alone — would put the endpoint one same-instant pair away
  # from naming two different commits for the same run in one response body.
  #
  # Materialized once and memoized: `show` reads it twice (the window's `returned`, then the rows)
  # and must not pay for it twice.
  #
  # ONE grouped aggregate for the whole window primes BOTH of the row's counts on every row —
  # `COUNT(*)` for `shard_count` and `COUNT(duration_seconds)` for `timed_shard_count`, two columns
  # of the same `GROUP BY` rather than two queries — see `ShardCountPreloading`, shared with the
  # human panel, which asks the same question of the same rows and reads only the first of the three
  # facts the aggregate now carries. So `history` costs two queries at ten rows and the same two at
  # one, instead of one `pick` per row. A narrowed window primes identically: `preload_shard_counts`
  # keys off the ids it is handed and does not care how they were selected, so `?branch=` costs the
  # same two queries at thirty rows.
  #
  # The branch predicate is passed INTO the model call, and that placement is the whole feature. The
  # `WHERE` and the `LIMIT` have to be one query: bounding first and filtering the result is what
  # returns zero `main` rows on a repository whose ten newest runs are all feature branches, which
  # is precisely what a client was left to do before this. `Repository#recent_test_runs` carries
  # the rest of that argument, and the index it relies on.
  def history_runs
    @history_runs ||= preload_shard_counts(
      current_repository.recent_test_runs(limit: history_limit, branch: requested_branch).to_a
    )
  end

  # The contract the `branches` catalogue is served under, on the same rule `history_window`
  # follows: the facts that decide how the array below may be read, as tokens rather than as the
  # sentences the human panel prints beneath its selector.
  #
  # THIS BLOCK IS WHY THE CATALOGUE IS TWO KEYS AND NOT ONE. The endpoint already established the
  # shape — an array beside the window it arrived through — and a catalogue that hid its bounds
  # inside its own rows would leave a client no place to learn that the list stops.
  #
  # `walk_limit` and `walk_cut` are the load-bearing pair, and they exist for the same reason
  # `branch_scope` does. `Repository#branch_histories` walks at most `Repository::BRANCH_HISTORY_LIMIT`
  # branches, and that walk is NAME-ORDERED by construction — it asks the index for the next branch
  # alphabetically — so past the bound the result is an alphabetical PREFIX of the repository, and
  # "most history first" is an ordering over the branches it reached rather than over the branches
  # there are. On a repository past the bound the trunk can be missing from a list that otherwise
  # looks complete, and a client with no way to detect that would read "`main` is not here" as
  # "`main` has no runs" — the exact inversion `Repository::BRANCH_HISTORY_LIMIT` documents.
  # `RepositoriesHelper#trajectory_listing_basis` says this to a reader in English; a machine client
  # cannot act on a sentence, so it is served as a bound and a boolean.
  #
  # `walk_cut` IS DERIVED WITH `>=`, NOT `==`, copied from `RepositoriesHelper#trajectory_walk_cut?`
  # rather than re-reasoned: a pinned branch is added to the walk's result, so a cut walk can hand
  # back MORE rows than its own bound. That is also why `returned` is not a substitute for this
  # flag — `returned` can exceed `walk_limit`, and comparing the two is the derivation that breaks.
  #
  # `run_count_limit` is where each row's `run_count` STOPS COUNTING, and it belongs on the window
  # because it is one fact about the whole block, while `run_count_capped` is per-row because
  # whether a given branch reached it is a fact about that branch. Read off `Repository`'s own
  # constant rather than off `SINGLE_BRANCH_HISTORY_LIMIT` above, which happens to hold the same
  # number for an unrelated reason: that one is a bound this controller CHOOSES between for
  # `history`, and this one is the model's own `runs:` default, which the catalogue takes as given.
  #
  # `tie_break_served: false`, the same admission `history_window` makes and for the same effect.
  # The order is `run_count` desc, then the branch's last run desc, then its name — and the middle
  # key is not a field on a row here. So the ordering is NOT reproducible from what a client holds:
  # two branches with equal counts carry nothing that says which the server put first. The array's
  # own order is the answer rather than a rendering of one, which is also why nothing below
  # re-sorts it.
  def serialized_branches_window
    {
      order: "run_count_desc,last_run_at_desc,name_asc",
      tie_break_served: false,
      run_count_limit: Repository::TRAJECTORY_LIMIT,
      walk_limit: Repository::BRANCH_HISTORY_LIMIT,
      walk_cut: branch_histories.length >= Repository::BRANCH_HISTORY_LIMIT,
      returned: branch_histories.length
    }
  end

  # The branch names this repository has runs on — the half of `?branch=` that makes the other half
  # usable, and the only key on this endpoint that answers "what may I ask for?".
  #
  # WITHOUT IT `?branch=` IS UNREACHABLE BY ANY CLIENT THAT DOES NOT ALREADY KNOW THE ANSWER. The
  # only branch names an API client ever sees otherwise are the per-row `branch` values in
  # `history`, and unfiltered that array is the ten-row INTERLEAVED window `history_window` warns
  # about — on a repository whose CI reports on every PR, all ten rows are routinely `feature/*` and
  # the trunk never appears in it. So learning a name required reading the one window that
  # systematically hides the name most clients want. Guessing gives no feedback either: an unknown
  # branch and an idle branch both answer `history: []` with the ask echoed back, byte for byte, so
  # a client cannot converge by probing. The human panel makes exactly this argument for itself —
  # *"a reader cannot ask for a branch they were never told exists"* — and loads its choices whether
  # or not a branch was asked for. This is served under the same rule, for the same reason: the
  # client that needs it most is the one that has not selected anything yet.
  #
  # ONE BOUNDED QUERY, and specifically not a `SELECT DISTINCT branch` over the whole run history,
  # which is the O(history) scan `Repository#branch_histories` documents at length for refusing. The
  # walk costs one index descent per BRANCH and none per run, so this key's cost follows branch
  # cardinality — which does not grow without bound — rather than the history, which does.
  #
  # SERVED IN THE MODEL'S ORDER, NEVER RE-SORTED. `branch_histories` returns most-history-first with
  # an explicit tie-break, and re-sorting here would make the array's order a rendering rather than
  # the answer — the mistake `tie_break_served: false` exists to keep this endpoint from making.
  #
  # NOT CUT TO A DISPLAY SIZE. `RepositoriesHelper::TRAJECTORY_BRANCH_CHOICES` cuts the human
  # selector to eight, and that number is about what a row of links can carry before it stops being
  # a way to find a branch. A JSON array has no such limit, and leaking a display bound into a
  # machine response would drop branches for a reason that does not apply to the reader.
  #
  # `branch IS NULL` runs are ABSENT, which the walk gives for free (see `BRANCH_HISTORY_SQL`). A
  # `null` branch is "the client did not say" — the meaning `latest_run.branch` and
  # `serialized_history_row` both pin — and the anonymous runs of every machine are not one branch.
  # Offering them a name here would offer a name `requested_branch` deliberately refuses to match.
  def serialized_branches
    branch_histories.map do |history|
      {
        name: history.name,
        # CAPPED at `run_count_limit`, and the cap is its own boolean rather than a rendered
        # `"30+"`. The human panel words it that way in a caption; this endpoint's standing rule is
        # tokens a client can compare rather than a caption it would have to read, and a client that
        # had to strip a `+` before comparing two counts would be parsing English again. The pair is
        # also the honest reading: the query STOPPED counting at the window the trajectory reaches,
        # so `run_count: 30, run_count_capped: true` says "at least thirty" without inventing a
        # figure nothing counted to, and `false` says the number is exact.
        run_count: history.run_count,
        run_count_capped: history.capped?
      }
    end
  end

  # The catalogue's rows, memoized: `show` reads them twice — once for the window's `returned` and
  # `walk_cut`, once for the array — and a second walk would double the key's cost for nothing.
  #
  # `Repository#branch_histories`' DEFAULTS ARE TAKEN AS GIVEN, and no bound is restated here. Both
  # numbers this response discloses are read straight off `Repository`, so the catalogue cannot come
  # to claim a bound the walk did not apply. It is also why this controller binds no third constant:
  # `Repository::BRANCH_HISTORY_LIMIT` (branches) and `Repository::TRAJECTORY_LIMIT` (runs) are two
  # different quantities already, `SINGLE_BRANCH_HISTORY_LIMIT` above is a third reading of the
  # second, and a locally-named fourth would say a word this file already uses for something else.
  #
  # `pinned:` CARRIES THE REQUESTED BRANCH, so a client that filtered on a branch can find that
  # branch in the same response that filtered on it. The walk's bound is alphabetical, so past it a
  # response could otherwise serve thirty `main` rows in `history` while omitting `main` from the
  # list of branches that have runs — one body contradicting itself. Pinning cannot invent a branch:
  # `WHERE tail.run_count > 0` drops a pinned name with no runs behind it, which is the same answer
  # an unknown `?branch=` gets in `history` and the correct one here. `Array(pinned).compact` in the
  # model makes the unfiltered case (`[nil]`) the same call as passing nothing.
  def branch_histories
    @branch_histories ||= current_repository.branch_histories(pinned: [requested_branch])
  end

  # The 0–1 FRACTION, matching what `/ingest` answered for this same run — never the 0–100
  # percentage `TestRun#annotated_ratio` renders for the dashboard. The 100× gap between the two is
  # invisible in a JSON body, so two endpoints disagreeing about it would be a silent
  # two-orders-of-magnitude error for any client that read both.
  #
  # `null` when the run reported no tests at all: `annotated_fraction` floors at `0.0` by
  # zero-denominator guard, and a `0.0` sitting beside real fractions reads as a *measured* zero
  # share rather than "there was nothing to take a share of". The counts stay present either way,
  # so a client that wants to compute its own ratio still can.
  def annotated_ratio_for(test_run)
    return nil if test_run.total_specs_count.to_i.zero?

    test_run.annotated_fraction
  end
end
