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

  # `?spec_directory=` read as a spec directory path, to open ONE area of the by-area rollup below.
  # Shared with `RepositoriesController`, which reads the same parameter under the same guard for
  # the drill-in panel on repositories#show — the third sibling of the include above, and included
  # here for the same reason that one is: the guard is the parameter's, not the surface's, and a
  # second copy of it would be a second answer to "which shapes does `?spec_directory=` tolerate".
  #
  # It reaches a SQL equality comparison directly, where a non-String does not raise but answers a
  # different question — see `RequestedSpecDirectoryParam`, which holds that reasoning in full.
  include RequestedSpecDirectoryParam

  # `?spec_file=` read as a spec file path, to open ONE FILE of the area opened above — the rung
  # below `?spec_directory=` and the last one the ladder has. Shared with `RepositoriesController`
  # on the reasoning the include above gives verbatim: the guard is the parameter's, not the
  # surface's, and a second copy of it would be a second answer to "which shapes does `?spec_file=`
  # tolerate".
  #
  # It reaches `where(spec_file_path: …)` directly, which is the harder half of that argument
  # rather than a restatement of it: a non-String does not raise here at all. An Array becomes an
  # `IN` list and answers a question nobody asked, under a `path` naming one file — see
  # `RequestedSpecFileParam`, which holds that reasoning in full.
  include RequestedSpecFileParam

  # `?repeated_description=` read as a test description, to open ONE GROUP of the by-description
  # ranking below — the fourth `Requested*Param` this controller reads and the one the three above
  # cannot stand in for, because it opens a ranking of WHAT tests say rather than of where they
  # live. Shared with `RepositoriesController` on the reasoning the two includes above give
  # verbatim: the guard is the parameter's, not the surface's, and a second copy of it would be a
  # second answer to "which shapes does `?repeated_description=` tolerate".
  #
  # It reaches `where(name: …)` on a plain text column, which is the same silent half of that
  # argument `?spec_file=` makes rather than a restatement of it — an Array does not raise, it
  # becomes an `IN` list and answers about SEVERAL descriptions under a `name` restating one. And
  # the `.presence` half is load-bearing here in a way it is not one rung up:
  # `spec_observations.name` is NULLABLE, so a blank ask would become `WHERE name = ''`, a query for
  # a description no row can carry. See `RequestedRepeatedDescriptionParam`, which holds that
  # reasoning in full.
  include RequestedRepeatedDescriptionParam

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
      # BESIDE `history`/`history_window` and deliberately NOT inside `latest_run`, which is
      # single-run facts by construction. Every key that block serves — `shards`, `spec_files`,
      # `spec_directories`, `slowest_examples` — is a statement about ONE run's rows; "this test is
      # unstable" is a statement about one test across several, and it is read off the same window
      # `history` is served over. See `serialized_unstable_tests_window`.
      unstable_tests_window: serialized_unstable_tests_window,
      unstable_tests: serialized_unstable_tests,
      # BESIDE `unstable_tests` and for the same structural reason it sits out here: a statement
      # about the WINDOW rather than about one run. `history` serves how the suite grew — one total
      # per run, no area grain on any row — and `latest_run.spec_directories` serves the area grain
      # of exactly one run. An agent holding every other key on this endpoint can compute THAT the
      # suite grew and never WHERE, which is the half of the roadmap's second axis ("how the suite
      # has grown over time and in which areas") nothing here answered. See
      # `serialized_directory_growth_window`.
      directory_growth_window: serialized_directory_growth_window,
      directory_growth: serialized_directory_growth,
      # BESIDE `directory_growth` and NEVER IN PLACE OF IT — a different comparison over the same
      # grain, not a refinement of that one. The pair above compares the two ENDPOINTS of a
      # thirty-run branch window and is served only when `?branch=` named the branch to walk; this
      # pair compares the latest run against THE PREVIOUS RUN ON ITS OWN BRANCH, which is the
      # comparison `repositories#show` renders as "Areas that grew or shrank" and the one an agent
      # asks for by pushing: *which areas moved in the push I just made*.
      #
      # It needs no `?branch=` and takes none. `Repository#previous_test_run_on_branch` scopes to
      # the latest run's own branch, so the hazard the window pair's gate exists to prevent —
      # anchoring on a `main` run and baselining against a same-sharded `feature/x` one — cannot
      # arise here by construction. That is what makes a plain unparameterised `GET` carry growth
      # at all, which until now it did not: unfiltered, `directory_growth` is `null`.
      #
      # Out here rather than inside `latest_run` for the reason stated at the top of that block and
      # again on `unstable_tests`: that block is single-run facts by construction, and "this area
      # gained forty examples" is a statement about one run measured against another.
      #
      # See `serialized_directory_run_growth_window`.
      directory_run_growth_window: serialized_directory_run_growth_window,
      directory_run_growth: serialized_directory_run_growth,
      # BESIDE `directory_run_growth` AND NOT DERIVABLE FROM IT — the same two runs and the same area
      # grain, measuring a different quantity. That pair answers "which areas changed SIZE" and this
      # one answers "which areas changed TIME", and `SpecDirectoryRuntimeGrowth`'s class comment
      # carries the argument in full: an area where somebody made an existing spec slow adds ZERO
      # examples, so its `ABS(latest_count - previous_count)` is `0`, it sorts last on that pair and
      # falls off the cap. It is not a row there missing a column — it is not on that list at all.
      # The independence runs both ways: splitting one slow spec into four fast ones is `+3` examples
      # and LESS time, and a `sleep` in a shared `before` is `0` examples and minutes.
      #
      # It is the grain `history` stops one short of, which is what makes it unreachable rather than
      # merely absent. `latest_run.spec_directories` serves per-area `total_seconds` for the LATEST
      # RUN ONLY, and the previous run is dereferenced on this endpoint for `baseline_commit_sha` and
      # the two COUNT-grain blocks alone — so there is no previous-run per-area duration anywhere in
      # this body and the subtraction is impossible client-side. The only runtime delta an agent can
      # compute is `test_runs.duration_seconds`, one figure for the whole run: it can be told the run
      # got ninety seconds slower and can never ask WHERE.
      #
      # NO NEW PARAMETER, for the reason the pair above gives: `Repository#previous_test_run_on_branch`
      # scopes to the latest run's own branch by construction, so a plain unparameterised `GET`
      # carries this.
      #
      # Out here rather than inside `latest_run` on that block's own membership rule: it is
      # single-run facts by construction, and "this area got forty seconds slower" is a statement
      # about one run measured against another.
      #
      # See `serialized_directory_runtime_growth_window`.
      directory_runtime_growth_window: serialized_directory_runtime_growth_window,
      directory_runtime_growth: serialized_directory_runtime_growth,
      # ONE GRAIN BELOW THE PAIR ABOVE, for the ONE area a caller asked about — not which areas
      # moved but which FILES of the picked area moved. The pair above answers
      # `spec/models 412 → 459 (+47)` and dead-ends on the only question that provokes: WHICH FILES
      # DID THAT. `repositories#show` has answered it since SPGD-456 and this endpoint could not be
      # asked at all, so an agent holding `directory_run_growth` reached exactly the dead end the
      # panel had already removed for a human reader.
      #
      # It matters most for the doubt the pair above DISCLOSES and then leaves the caller holding: a
      # moved directory appears there as one area growing and another shrinking by the same amount,
      # with nothing added and nothing deleted. The file grain is what resolves it —
      # `user_spec.rb` new beside `legacy_user_spec.rb` removed reads as a rename, and
      # `billing_spec.rb 3 → 50` does not. Neither surface ASSERTS either reading; both put the
      # operands where the reader can pair them, which is the pairing
      # `SpecObservation`'s positional-instability rule forbids the application from doing.
      #
      # NO NEW PARAMETER. The ask is `?spec_directory=` — the SAME one `latest_run.spec_directory_files`
      # reads, deliberately not a second one, exactly as the two panels on `show` are opened by one
      # click. One ask now opens TWO blocks on this endpoint, each answering in its own grain: which
      # files carry the area's wall clock, and which of them moved since the previous run. A later
      # reader should not "fix" it by splitting the parameter in two.
      #
      # Out here beside its parent rather than inside `latest_run` for that block's own membership
      # rule: `latest_run` is single-run facts by construction, and "this file gained forty
      # examples" is a statement about one run measured against another.
      #
      # See `serialized_directory_run_file_growth_window`.
      directory_run_file_growth_window: serialized_directory_run_file_growth_window,
      directory_run_file_growth: serialized_directory_run_file_growth,
      branches_window: serialized_branches_window,
      branches: serialized_branches
    }
  end

  private

  # `nil` — not a zeroed block — when CI has never reported. A repository whose CI has never run
  # must not serialize byte-identically to one that ran and genuinely found an empty suite; that is
  # the conflation the Overview panel refuses too (see RepositoriesController#show).
  # A repository-wide ratio floored at 0.0 cannot express the difference, which is why this reads
  # the run.
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
    test_run = latest_test_run

    return nil if test_run.nil?

    {
      commit_sha: test_run.commit_sha,
      # Nullable, and Ingest::Payload accepts a body without it. `null` here means "the client did
      # not say", which is a different fact from any branch name we could substitute for it.
      branch: test_run.branch,
      total_specs: test_run.total_specs_count,
      annotated_specs: test_run.annotated_specs_count,
      # The 0–1 FRACTION, the same `TestRun#annotated_fraction` call `/ingest` answers this run
      # with — never the 0–100 percentage `TestRun#annotated_ratio` renders for the dashboard. The
      # 100× gap between the two is invisible in a JSON body, so two endpoints disagreeing about it
      # would be a silent two-orders-of-magnitude error for any client that read both. `null` for a
      # run that reported no tests; the model carries why.
      annotated_ratio: test_run.annotated_fraction,
      # Nullable by schema. Serializing `0.0` for an unreported duration would assert the run took
      # no time — the same "not reported" vs `0.0s` distinction the Recent runs table draws.
      #
      # On a sharded run this is the MAX over the shards — the run's WALL CLOCK, not what the suite
      # cost. It keeps that key, that type and that value: `shards` below is added beside it rather
      # than in place of it, so nothing a client reads today changes meaning.
      duration_seconds: test_run.duration_seconds,
      shards: serialized_shards(test_run),
      spec_files: serialized_spec_files(test_run),
      # BESIDE `spec_files`, never in place of it: the two rank different populations and the
      # second is not derivable from the first. See `serialized_spec_directories` below.
      spec_directories: serialized_spec_directories(test_run),
      # BESIDE both rollups above, and it is the grain NEITHER of them can reach: those two name
      # areas and files, and an agent holding both still cannot ask which TEST inside a 90-second
      # directory to open. See `serialized_slowest_examples` below.
      slowest_examples: serialized_slowest_examples(test_run),
      # BESIDE `slowest_examples`, and the grain none of the three blocks above can reach. Those
      # roll this run's rows up by where the code LIVES — the example, its file, its area — and no
      # rollup of "where" can see that two of those rows say the same thing. See
      # `serialized_repeated_descriptions` below.
      repeated_descriptions: serialized_repeated_descriptions(test_run),
      # ONE AREA of `spec_directories` above, opened — the first of the three keys in this block
      # that answer a question the client asked rather than one the endpoint always answers, and so
      # the first whose `null` is a fact about the REQUEST. `shards` is null for a fact about the
      # run (it had one part, which is the ordinary case) and the four rollups for a fact about its
      # rows (there were none); this one is null because no area was asked for, which is a statement
      # about neither the run nor its rows. See `serialized_spec_directory_files` below.
      spec_directory_files: serialized_spec_directory_files(test_run),
      # ONE FILE of that area, opened — the rung below the key above it and the last one this ladder
      # has: area → file → example, with nothing under an example to open. Its `null` is a fact
      # about the REQUEST for the same reason `spec_directory_files`' is, and it is the second key
      # on this block to which that applies rather than an exception to the rule the four rollups
      # follow. `shards` is null about the run, the four rollups about its rows, and the three
      # drill-ins about what the client asked. See `serialized_spec_file_examples` below.
      spec_file_examples: serialized_spec_file_examples(test_run),
      # ONE GROUP of `repeated_descriptions` above, opened — the third key on this block whose
      # `null` is a fact about the REQUEST, and the one drill-in that leaves the area → file →
      # example ladder entirely. Those two open a place; this one opens a SENTENCE, and the ranking
      # it drills out of is the only one here that is not a rollup of where the code lives. See
      # `serialized_repeated_description_examples` below.
      repeated_description_examples: serialized_repeated_description_examples(test_run),
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
    durations = SpecDirectoryDurations.for(test_run)

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
          named_count: row.named_count
        }
      end,
      directory_count: durations.directory_count,
      limit: SpecObservation::HEAVIEST_DIRECTORIES_LIMIT
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
    slowest = SlowestExamples.for(test_run)

    return nil unless slowest.recorded?

    {
      rows: slowest.rows.map do |observation|
        {
          name: observation.name,
          file_path: observation.file_path,
          line_number: observation.line_number,
          spec_file_path: observation.spec_file_path,
          duration_seconds: observation.duration_seconds,
          outcome: observation.outcome
        }
      end,
      recorded_count: slowest.recorded_count,
      timed_count: slowest.timed_count,
      reported_outcome_count: slowest.reported_outcome_count,
      limit: SpecObservation::SLOWEST_LIMIT
    }
  end

  # WHICH DESCRIPTIONS ONE RUN RECORDED MORE THAN ONCE, ranked by the wall clock those examples cost
  # between them — the ⭐overcoverage reading `repositories#show` has rendered since SPGD-344, and
  # the last of the five run-grain panels to reach a client that cannot read a panel.
  #
  # INSIDE `latest_run` rather than beside it, on the membership test the comment on
  # `unstable_tests` states in full: every key that block serves is a statement about ONE run's
  # rows, and "this test is unstable" is a statement about one test across several.
  # `RepeatedDescriptions.for` narrows both of its reads to a single `test_run_id`, so this is a
  # statement about one run's rows and belongs where the other four are.
  #
  # THE GRAIN IS THE DESCRIPTION, which is a grain none of the four blocks above can reach. They
  # roll a run's rows up by where the code LIVES — the example, its file, its area — and no
  # rollup of "where" can see that two of those rows claim to test the same thing. The measurement
  # existed nowhere before that panel: `GROUP BY name` appears twice in this application and both
  # are narrowed to failures, so on a green suite — the normal case — nothing grouped examples by
  # description at all.
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
          files_seen: row.files_seen
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
  # ask without either touching the other: the drill-in always describes the newest run, exactly as
  # the panel does.
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
          timed_count: row.timed_count
        }
      end,
      file_count: files.file_count,
      recorded_count: files.recorded_count,
      timed_count: files.timed_count,
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
  # an area ask without any of the three touching another: the drill-in always describes the newest
  # run, exactly as the panel does.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query — this file's governing rule, stated
  # in full on `serialized_spec_files` above. `SpecFileExamples` is view-free apart from
  # `#coverage_label`, which is skipped here exactly as the rung above skips `Row#duration_label` and
  # `Row#coverage_label`, so the API and the panel list the same examples of the same file of the
  # same run, in the same order, off the one read.
  #
  # THE ROW SHAPE IS `serialized_slowest_examples`' SIX FIELDS, field for field, because this
  # endpoint's two per-example blocks describe the same rows of the same table and a client that
  # learned to read one must not have to learn a second shape to read the other. `duration_seconds`
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
      # THE SAME SIX FIELDS `serialized_slowest_examples` SERVES, AND THE REPETITION IS CHOSEN. The
      # two per-example blocks on this endpoint must agree field for field, and a shared
      # `serialized_example_row` would make that structural rather than asserted — the stronger
      # guarantee, and it is declined here for this file's standing reason: each block states its
      # own contract beside its own rows, and a field list extracted to a helper sits where neither
      # block's comment can explain why it holds what it holds. What enforces the agreement instead
      # is a `contain_exactly` over these names in each block's request spec, so a field added to
      # one and not the other goes red rather than shipping a client two per-example shapes.
      rows: examples.rows.map do |observation|
        {
          name: observation.name,
          file_path: observation.file_path,
          line_number: observation.line_number,
          spec_file_path: observation.spec_file_path,
          duration_seconds: observation.duration_seconds,
          outcome: observation.outcome
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
  # another: the drill-in always describes the newest run, exactly as the panel does.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query — this file's governing rule, stated
  # in full on `serialized_spec_files` above. `RepeatedDescriptionExamples` is view-free apart from
  # `#coverage_label`, which is skipped here exactly as the two rungs above skip `Row#duration_label`
  # and `SpecFileExamples#coverage_label`: `"25 of 40"` is two integers a client cannot subtract.
  #
  # THE ROW SHAPE IS `serialized_slowest_examples`' SIX FIELDS, field for field, on the rule
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
      # THE SAME SIX FIELDS the two per-example blocks above serve, and the repetition is chosen for
      # the reason `serialized_spec_file_examples` states in full: each block states its own contract
      # beside its own rows, and what enforces the agreement is a `contain_exactly` over these names
      # in each block's request spec, so a field added to one and not the others goes red rather than
      # shipping a client three per-example shapes.
      rows: examples.rows.map do |observation|
        {
          name: observation.name,
          file_path: observation.file_path,
          line_number: observation.line_number,
          spec_file_path: observation.spec_file_path,
          duration_seconds: observation.duration_seconds,
          outcome: observation.outcome
        }
      end,
      recorded_count: examples.recorded_count,
      timed_count: examples.timed_count,
      limit: SpecObservation::REPEATED_DESCRIPTION_EXAMPLES_LIMIT
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
  # as the 0–1/0–100 ratio confusion `TestRun#annotated_fraction` guards against. So the ask is
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
      # The 0–1 fraction, same call and same units as `latest_run` above and as `/ingest`.
      annotated_ratio: run.annotated_fraction,
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

  # The contract the flakiness rows below are served under — and, when they are `null`, the reason
  # they are. Served UNCONDITIONALLY, on the key-always-present rule `latest_run.shards` argues for
  # itself above: a client tests one thing rather than distinguishing an absent key from a null one,
  # and the block that explains a `null` is worthless if it is itself absent whenever the `null`
  # happens.
  #
  # `grouped` IS THE LOAD-BEARING KEY, and it exists because of the branch decision below. Outcomes
  # compared across branches are outcomes of different code — `UnstableTests` states that rule for
  # itself — and unfiltered, `history_runs` is the INTERLEAVED all-branch window
  # `serialized_history_window` spends a paragraph warning about, on which consecutive rows are
  # routinely two different branches. Grouping outcomes over it would manufacture a flip out of two
  # branches: the same description failing on `feature/x` and passing on `main` is two pieces of
  # code, and calling it flaky is a false positive the object exists to avoid. So unfiltered,
  # `UnstableTests.for` IS NOT CALLED AT ALL — no rows, and no reads to produce them — and this
  # boolean is what says so.
  #
  # It is read off whether the object was CONSTRUCTED, never re-spelled as `requested_branch ?
  # true : false`. A second copy of the gate is a second thing to keep true, and the one that
  # decides what was read is the one worth serving. So `grouped` is exactly `unstable_tests !=
  # null`, in every response, and a client can test either.
  #
  # `grouped: true` IS NOT "SOMETHING WAS COMPARED". It says the window was eligible to be grouped
  # and was handed to the presenter — which is the branch decision and nothing more. What came of
  # it is the block's own business and is stated there: an unknown `?branch=` selects zero runs and
  # groups over an empty set, and a branch whose client never reported outcomes groups over a
  # populated one and still cannot compare. `run_count`, `recorded` and `comparable` are what
  # separate those, and they are in the block precisely because they are answers rather than
  # eligibility.
  #
  # `branch_scope` and `branch` are TWO keys rather than one interpolated token, and `branch` is
  # always served (`null` when the window was not narrowed) — `serialized_history_window` makes
  # both arguments in full and they are not repeated here. They carry the same values that block
  # carries in the same response, because both describe the SAME window: the rows below are grouped
  # over `history_runs`, which is what `history` is serialized from.
  #
  # `null` ROWS AND NEVER AN EMPTY LIST. `unstable_tests: []` would read as "nothing is flaky" when
  # it means "we refused to compare" — Vacuous Green exactly, in the shape this project keeps
  # finding it: a surface reporting a clean result for work it did not do. The `null` cannot be
  # misread, and this block says which of the two states produced it.
  #
  # `order` NAMES ALL THREE KEYS, and `tie_break_served` is `true` here — one of the two places on
  # this endpoint where it is, the other being `serialized_directory_growth_window`.
  # `UnstableTests#initialize` sorts by `(-failed_run_count, -run_count,
  # name)` and every one of those three is served on the row below, so unlike `history` and
  # `branches` — whose tie-breaks are an ingest sequence and a last-run timestamp that no row
  # carries — a client CAN reproduce this order from what it holds. Stated rather than assumed,
  # because the honest answer differs per block and a client that had to guess would re-sort one of
  # the two lists that must not be re-sorted.
  def serialized_unstable_tests_window
    {
      order: "failed_run_count_desc,run_count_desc,name_asc",
      tie_break_served: true,
      branch_scope: requested_branch ? "single_branch" : "all_branches",
      branch: requested_branch,
      grouped: !unstable_tests.nil?
    }
  end

  # WHICH TESTS ARE UNSTABLE ACROSS RUNS — the agent-readable half of the "Tests whose outcome
  # changed" panel `repositories#show` has rendered since SPGD-282, and the roadmap's fourth axis
  # ("where it is flaky"), which was the last of the four this endpoint had never been given.
  #
  # A DIFFERENT GRAIN FROM EVERYTHING IN `latest_run`, which is why it is served beside `history`
  # rather than inside that block. `slowest_examples` reaches the per-example grain of ONE run;
  # this is the first key on this endpoint that matches a test to ITSELF across runs, and no
  # arrangement of single-run facts answers it. An agent holding thirty responses could subtract
  # them — which is the polling-and-differencing this file's opening comment exists to refuse.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query — this file's governing rule,
  # stated in full on `serialized_spec_files`. `UnstableTests` is view-free, so the API and the
  # panel name the same tests, in the same order, off the same rows of the same window.
  #
  # OFF THE ALREADY-MEMOIZED WINDOW, so this adds NO run-window query. `history_runs` is
  # materialized once and `show` already reads it twice, and `UnstableTests.for`'s own signature
  # documents the window as *"ALREADY LOADED … handed in rather than re-queried"*, precisely so two
  # surfaces cannot come to be drawn on two windows that agree today. The object is order- and
  # anchor-indifferent: it reads `runs.map(&:id)` and `runs.size` and nothing else.
  #
  # `null` — THE KEY STILL PRESENT — under an unfiltered window, and the argument for that is on
  # `serialized_unstable_tests_window` above where the boolean that explains it lives.
  #
  # AN EMPTY `rows` IS A REAL ANSWER HERE and is not the same state. Under a branch-scoped window
  # the object IS constructed, and `rows: []` beside `comparable: true` means "we compared and
  # nothing flipped". Beside `comparable: false` it means "nobody told us how anything ended". The
  # two must never serialize identically, which is what the coverage keys below are for.
  #
  # STRUCTURED COUNTS AND BOOLEANS, NOT PROSE — this endpoint's standing rule, and this is the
  # block where it costs the most. `RepositoriesHelper` words this same coverage in TWELVE
  # `unstable_tests_*` helpers ("3 of the last 30 runs on main reported outcomes", "2 of 5"), and a
  # machine-readable client cannot act on a sentence without parsing it. So every figure those
  # sentences are built from goes out as an integer or a boolean and the client words it — or does
  # not word it at all and just divides.
  #
  # `comparable` IS THE VACUOUS GREEN GATE AND IS SERVED AS A FLAG, never as an empty list.
  # `UnstableTests#comparable?` is explicit about why: `outcome` is nullable and nothing validates
  # it, so a window whose client sends no outcomes stores a nil on every row of every run, which
  # yields no failures, therefore no candidates, therefore an empty list — *"the zero is real; what
  # it counts is silence"*. An empty list without this flag is "nobody told us" wearing the
  # spelling of "everything is stable".
  #
  # `recorded` is the coarser question one rung under it — whether the window has ANY per-example
  # grain at all — and separates a repository whose CI has never sent per-example detail from one
  # that sends it without outcomes. Both are read off the object's OWN predicates, called rather
  # than re-spelled here, on the rule `serialized_spec_files`' `#recorded?` gate states: a
  # controller-side copy of a predicate is free to drift the day the presenter's changes.
  #
  # `truncated` / `unexamined_count` DISCLOSE THE CANDIDATE CAP. The candidate step stops at
  # `SpecObservation::UNSTABLE_CANDIDATE_LIMIT` — a catastrophe valve for a window in which the
  # whole suite went red — and a capped list that does not say it stopped is read as the whole
  # story. The two OPERANDS (`candidate_count`, `examined_count`) go out beside the boolean, so a
  # client can check the comparison rather than take it; `limit` is read off `SpecObservation`'s own
  # constant rather than restated here, on the precedent `serialized_spec_files` sets, so the
  # response cannot claim a bound the query did not apply.
  #
  # `unnamed_count` IS AN EXCLUSION, not a population. A null `name` cannot be matched to itself
  # across runs — two nulls are not known to be one test — so those rows are dropped from the
  # matching before anything is grouped. Counted in ROWS and never in tests, because an unnamed row
  # is precisely a row this block cannot say is a test.
  #
  # It is `null` wherever the outcome gate below short-circuited — the ONE key on that line that
  # goes null while `candidate_count`, `examined_count`, `truncated` and `unexamined_count` stay at
  # their zeros. The split is not a stylistic one. Those four are OUTCOME facts, and in a window
  # nothing was examined in their zeros are true: no candidate was found because none was sought.
  # This one is a ROW fact — its query carries no outcome predicate — so the number of unnamed rows
  # is fully determined in that window and merely never asked. A `0` would be a fabricated
  # exclusion, wire-identical to a window measured to hold none, and a client reading this key to
  # learn how much of the window the matching dropped could not tell "not counted" from "counted
  # zero". Null rather than the true count because asking costs the second read the ONE-read
  # property below rules out; the HTML panel refuses to print any count over this same state.
  #
  # `shared_description_rows` IS ITS OWN LIST and never folded into `rows` — exactly as the panel
  # lists them separately. These are descriptions that varied across the window AND were carried by
  # more than one example in at least one run of it, so the description is not a key for that run:
  # its `failed` and its `passed` are two tests rather than one test that flipped. Reported rather
  # than dropped, because a dropped group is a silence a reader has no way to notice, and named as
  # what they are rather than as flakiness, because nothing here establishes which of it.
  #
  # AT MOST FOUR READS OF `spec_observations`, and CONSTANT in the length of the window and the size
  # of the suite — none of them new. They are the panel's own reads, already EXPLAIN-certified in
  # `spec/models/spec_observation_spec.rb`, so that certification transfers rather than needing to
  # be repeated in a request spec. The count is not constant in STATE, deliberately:
  # `UnstableTests.for` asks the gating question FIRST and on its own, so an incomparable window
  # costs ONE read and stops, and an unfiltered request costs NONE because the object is never
  # constructed.
  def serialized_unstable_tests
    unstable = unstable_tests

    return nil if unstable.nil?

    {
      rows: unstable.rows.map { |row| serialized_unstable_test_row(row) },
      shared_description_rows: unstable.shared_description_rows.map { |row| serialized_unstable_test_row(row) },
      run_count: unstable.run_count,
      runs_with_rows: unstable.runs_with_rows,
      runs_reporting_outcomes: unstable.runs_reporting_outcomes,
      recorded: unstable.recorded?,
      comparable: unstable.comparable?,
      candidate_count: unstable.candidate_count,
      examined_count: unstable.examined_count,
      truncated: unstable.truncated?,
      unexamined_count: unstable.unexamined_count,
      unnamed_count: unstable.unnamed_count,
      limit: SpecObservation::UNSTABLE_CANDIDATE_LIMIT
    }
  end

  # One description across the window. Every counter the presenter carries, flat, on
  # `serialized_slowest_examples`' shape — and every one of them an OPERAND rather than one of the
  # labels `UnstableTests::Row` builds for the panel. `#appearance_label` and `#failure_label` word
  # these same figures as `"2 of 5"`, which a client would have to split on a space before it could
  # compare two rows.
  #
  # BOTH DENOMINATORS ARE SERVED, and they are different denominators. `run_count` is the runs this
  # description APPEARED in — not the window's length, which is on the block above — because a test
  # added halfway through the window failed in two of the fifteen runs that ran it, and dividing by
  # thirty would report a stability it was never measured for. `recorded_count` is its ROWS, which
  # exceeds `run_count` exactly when the description was carried by more than one example in a run.
  #
  # `outcome_words` IS ECHOED VERBATIM and never reworded into a verdict — the model's own
  # echo-don't-judge rule, which `SpecObservation#outcome_label` carries the reason for: nothing
  # platform-side validates that string, so quoting what arrived is the only reading that cannot be
  # wrong. An unrecognised word goes out unrecognised.
  #
  # `outcome_words` and `files_seen` are read through the ROW'S ACCESSORS, never off the struct
  # members: both aggregates are `ARRAY_AGG(…) FILTER (…)`, which is SQL NULL rather than an empty
  # array for a group with nothing to collect, and both accessors `Array()`-normalise that and sort
  # — so two rows carrying the same set serialize the same way instead of in whatever order the
  # planner returned.
  #
  # `unreported_outcome_count` is runs that recorded this description and said NOTHING about how it
  # ended. Not a pass, and counted as one nowhere: `#changed?` compares against
  # `reported_outcome_count` and not against `recorded_count`, precisely so a client that stopped
  # sending outcomes cannot manufacture a flip. Served so a client can see the same separation
  # rather than infer it.
  #
  # `shared_description` rides on EVERY row, in both lists, on the rule `serialized_history_row`'s
  # per-row `branch` follows: a client should be able to read a row's classification off the row
  # rather than off the list it arrived in. `multi_file` is beside it and is a DISCLOSURE rather
  # than a defect — the project's identity rule is semantic, so a test that moved is the same test
  # and keeps its history, but a reader looking for a flaky test in one file needs to know the
  # history spans two.
  def serialized_unstable_test_row(row)
    {
      name: row.name,
      recorded_count: row.recorded_count,
      run_count: row.run_count,
      reported_outcome_count: row.reported_outcome_count,
      unreported_outcome_count: row.unreported_outcome_count,
      failed_count: row.failed_count,
      failed_run_count: row.failed_run_count,
      outcome_words: row.outcome_words,
      files_seen: row.files_seen,
      multi_file: row.multi_file?,
      shared_description: row.shared_description?
    }
  end

  # The presenter, or `nil` when no comparison was allowed — memoized, because `show` reads it
  # twice: once for the window block's `grouped` and once for the rows. Without the memo the whole
  # thing is built twice and the block's four reads become eight, which is what the cost examples
  # next door count.
  #
  # MEMOIZED ACROSS THE NIL — `defined?` rather than `||=` — so the memo means "already decided"
  # rather than "already truthy". That distinction is free TODAY: `requested_branch &&`
  # short-circuits before any read, so re-evaluating the nil case costs nothing and a `||=` would
  # behave identically. It stops being free the moment this gate consults anything that costs, and
  # the shape that cannot regress is the one that does not depend on the answer being truthy.
  #
  # The branch gate lives HERE, in one place, so the boolean the window serves and the decision that
  # produced it cannot come apart. See `serialized_unstable_tests_window` for why an unfiltered
  # window is refused rather than answered.
  def unstable_tests
    return @unstable_tests if defined?(@unstable_tests)

    @unstable_tests =
      requested_branch && UnstableTests.for(current_repository, history_runs, branch: requested_branch)
  end

  # The contract the growth-by-area rows below are served under — and, when they are `null`, the
  # reason they are. Served UNCONDITIONALLY, on the key-always-present rule `latest_run.shards` and
  # `serialized_unstable_tests_window` both argue for: a client tests one thing rather than
  # distinguishing an absent key from a null one, and a block that explains a `null` is worthless if
  # it is itself absent whenever the `null` happens.
  #
  # `grouped` IS THE LOAD-BEARING KEY, and it exists for the branch reason its flakiness sibling
  # gives, which binds at least as hard here. `SpecDirectoryWindowGrowth` picks its baseline with
  # two in-memory predicates — `TestRun#suite_size_measured?` and `TestRun#assembled_like?`, which
  # is `shard_count` equality — and NEITHER looks at `branch`. Handed the INTERLEAVED all-branch
  # window `serialized_history_window` warns about, the walk would anchor on a `main` run and
  # baseline against a `feature/x` run that happened to be sharded the same way, and report "this
  # area grew by 300 examples" where the truth is two different pieces of code. So unfiltered, the
  # object IS NOT CONSTRUCTED — no rows, and no read to produce them — and this boolean says so.
  #
  # Read off whether the object was CONSTRUCTED, never re-spelled as `requested_branch ? true :
  # false`. A second copy of the gate is a second thing to keep true, and the one that decides what
  # was read is the one worth serving. So `grouped` is exactly `directory_growth != null`.
  #
  # `grouped: true` IS NOT "SOMETHING WAS COMPARED", the same disclaimer the flakiness window
  # carries: the object is constructed for every branch-scoped ask, and what came of it is the
  # block's own business. Its `state` is what separates the eight answers.
  #
  # `order` names both keys and `tie_break_served` is TRUE, which is the honest reading here and
  # only the second place on this endpoint it is. `SpecObservation.directory_growth_between` orders
  # by `ABS(anchor_count - baseline_count) DESC` then `path ASC`, and both operands and the path go
  # out on every row — so a client CAN reproduce this order from what it holds, unlike `history`
  # (whose tie-break is an ingest sequence no row carries) and `branches`.
  #
  # `basis` IS THE OBJECT'S OWN LOAD-BEARING LIMITATION, served as a token because a client cannot
  # act on the paragraph `spec_directory_window_growth.rb` spends on it. The figures compare TWO
  # ENDPOINTS of a thirty-run window; they are not a series over it. An area that added 300
  # examples in run 12 and deleted them again in run 25 reads `change: 0` here, indistinguishable
  # from an area nothing happened in — and a thirty-run heading over a two-run measurement is
  # exactly the claim a caption would otherwise imply and nothing looked at. `covered_run_count`
  # says how far apart the two endpoints are; this says that two is all there are.
  def serialized_directory_growth_window
    {
      order: "abs_change_desc,path_asc",
      tie_break_served: true,
      basis: "two_endpoints",
      branch_scope: requested_branch ? "single_branch" : "all_branches",
      branch: requested_branch,
      grouped: !spec_directory_window_growth.nil?
    }
  end

  # WHICH AREAS OF THE SUITE GREW OR SHRANK ACROSS THE BRANCH WINDOW — the agent-readable half of
  # the panel `repositories#show` renders from the same object, and the "in which areas" half of the
  # roadmap's growth axis, which is the one this endpoint has never been given.
  #
  # A DIFFERENT GRAIN FROM EVERYTHING IN `latest_run`, which is why it is served beside `history`.
  # `latest_run.spec_directories` carries a per-directory `recorded_count` for exactly ONE run, and
  # `serialized_history_row` carries run TOTALS with no area grain on any row. Neither is the other's
  # missing half: an agent holding both, for every row of the window, knows how much the suite grew
  # and nothing about where. Two responses could not be subtracted into this either — that is the
  # polling-and-differencing this file's opening comment exists to refuse.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query — this file's governing rule, stated
  # in full on `serialized_spec_files`. `SpecDirectoryWindowGrowth` is view-free, so the API and the
  # panel name the same areas, in the same order, off the same rows of the same window.
  #
  # OFF THE ALREADY-MEMOIZED WINDOW, so this adds NO run-window query — see
  # `spec_directory_window_growth` for the ORDER that window has to be handed over in, which is the
  # one thing about this block that is not shared with its flakiness sibling.
  #
  # `state` IS SERVED AS THE SYMBOL AND NEVER COLLAPSED TO A BOOLEAN OR TO `null`. The object
  # distinguishes eight states, seven of them absences, and its own comment is why they are not one:
  # "every earlier run on this branch reported no tests", "they were all assembled differently from
  # this one" and "the run at the far end recorded no per-example rows" are one blank panel and
  # three different things to go and fix. `comparable` rides beside it as the single boolean a
  # client that only wants the rows can branch on, read off the object's own predicate rather than
  # re-derived here from the symbol.
  #
  # THE HONESTY FIGURES ARE SERVED, NOT DROPPED, and they are the block's actual payload in seven of
  # the eight states. The baseline is WALKED from the far end of the window, so the comparison a
  # client is handed can be SHORTER than the window it asked over — `window_run_count` is what the
  # window holds and `covered_run_count`/`runs_back` are what the figures span, and a 26-run
  # comparison under a 30-run heading is a fact about the measurement rather than an implementation
  # detail. The two skip counts stay SPLIT rather than summed, on the object's own rule: a client
  # that stopped reporting totals and a branch whose sharding changed are two different repairs, and
  # a bare "4 runs were skipped" is a fact nobody can act on.
  #
  # BOTH COMMIT SHAS, so a client can say WHICH TWO RUNS the figure spans and go read them. They are
  # nullable for the reason the states are: the walk finds no baseline in four of them, and there is
  # no run to name. Anchor and baseline rather than "first" and "last" — the anchor is the newest
  # run of the window and the baseline is the OLDER end, which is the direction every `change` on
  # every row below is signed in.
  #
  # ⭐ THE SPAN IS NULL WHEREVER THE SHA IS — one predicate, `baseline_run`, read ONCE into a local
  # and used for all FOUR span keys, so the figures and the run they are counted to cannot come
  # apart. `#covered_run_count` is `runs_back + 1` and `runs_back` keeps its `0` default in exactly
  # the four states the walk landed on no baseline in, so serving it raw asserts a ONE-RUN
  # COMPARISON that was never taken: `anchor_unmeasured` would carry `covered_run_count: 1` beside
  # `window_run_count: 2` and `shortened: false` — the block's own claim that the span equals the
  # window, and its own figures denying it, two keys apart. The degenerate end is worse: an unknown
  # `?branch=` selects ZERO runs and would serve a comparison spanning one run over a window holding
  # none, next to an `anchor_commit_sha` of `null`.
  #
  # `shortened` IS THE FOURTH, and it fails in the opposite direction from the other three, which is
  # why enumerating from `anchor_unmeasured` alone once left it ungated. The four no-baseline states
  # split in half on this key. `anchor_unmeasured` and `no_earlier_run` never enter the walk, so the
  # skip counters keep their `0` default and `shortened?` is benignly `false`. `no_measured_baseline`
  # and `no_comparable_composition` are reached ONLY from inside the walk, and only by every earlier
  # run being skipped — `skipped_count.positive?` is the very mechanism that reaches them — so
  # `shortened?` is necessarily `true` in both, ALWAYS, not merely sometimes. Ungated it printed
  # `shortened: true` beside `covered_run_count: null` and `baseline_commit_sha: null`: a shortened
  # span asserted for a comparison that was never taken. `false` would be no better than `true`
  # here — it is equally a claim about a span, namely that it equals the window — so the answer is
  # `null`, the same answer the other three give, for the same reason.
  #
  # The two SKIP COUNTS are NOT gated and must not be: they are facts about the walk rather than
  # about the span, they are the actionable half of both those states ("two earlier runs reported no
  # tests"), and they are true whether or not the walk found somewhere to land.
  #
  # The panel never prints the span in these states — `spec_directory_window_growth_span_sentence`
  # is reached only under `comparable? && any_movement?` — so this endpoint is the FIRST surface that
  # can be wrong with it, and a fabricated span sitting among the honesty fields is the exact failure
  # they exist to prevent. `null` is the same answer `baseline_commit_sha` already gives, and it is a
  # PINNED CONTRACT rather than a default: the spec asserts the keys in every one of the four.
  # The four states that DID land on a baseline — `comparable` and the three recorded-rows absences
  # — carry a true span, and it is their actionable payload ("the run that recorded nothing is two
  # back"), so the gate is `baseline_run` and never `comparable?`.
  #
  # `truncated` DISCLOSES THE CAP with both operands beside it. `directory_count` is counted BEFORE
  # `SpecObservation::MOVED_DIRECTORIES_LIMIT` applies (a window function, so it runs before the
  # `LIMIT`), which is what makes the comparison answerable at all; `limit` is read off that
  # constant rather than restated — this call site passes no `limit:`, so the constant IS the bound
  # the query applied. It is the object's default that makes that true, not the serving of it: the
  # object does not expose the limit it was built with, so a caller that ever passed `limit: 5` here
  # would need this key taught to follow it rather than re-read the constant.
  #
  # `baseline_recorded_count`/`anchor_recorded_count` are the DENOMINATORS the recorded-rows states
  # turn on — how many per-example rows each end wrote in total — and deliberately not
  # `TestRun#total_specs_count`, which is re-derived by SUM over shard reports and can legitimately
  # differ from the rows a run actually wrote. Every figure on this block is counted off those rows.
  #
  # ⭐ THOSE COUNTS ARE GATED ON `baseline_run` TOO, on the same rule as the span keys above them.
  # `SpecDirectoryWindowGrowth.from_tuples` is the ONLY path that reads the aggregate, and the only
  # one that passes `baseline_run:` — so the four states the walk short-circuits into before it
  # (`anchor_unmeasured`, `no_earlier_run`, `no_measured_baseline`, `no_comparable_composition`)
  # carry no totals at all and fall back to the object's `0` defaults. `baseline_run.nil?` is
  # therefore EXACTLY "the totals were never counted", with no third case. Served raw, those
  # defaults would print `anchor_recorded_count: 0` for an anchor that wrote four hundred rows, and
  # `directory_count: 0` for a comparison whose query was never issued — fabricated denominators
  # sitting among the fields that exist to be trustworthy. `truncated` rides along because it is
  # DERIVED from `directory_count` (`directory_count > rows.size`): once its operand is `null`, a
  # `false` beside it would be a completeness claim about a list this same body declares unknown.
  #
  # NOT `comparable?`, which is the weaker predicate and would null too much: `neither_recorded`,
  # `baseline_unrecorded` and `anchor_unrecorded` are non-comparable but DID read the aggregate, so
  # their totals are true — including their genuine `0`s — and are the actionable half of those
  # states. Four of the eight states carry these figures; the other four have none to carry.
  #
  # ONE READ OF `spec_observations` AT MOST, and none at all where there is nothing to compare. The
  # walk is pure in-memory predicates over rows already loaded, and the comparison itself is two run
  # ids in an `IN` list whatever the window's length — already plan-certified at the seeded table
  # size in `spec/models/spec_observation_spec.rb`, so that certification transfers rather than
  # needing to be repeated here. Same argument `serialized_unstable_tests` makes for itself.
  def serialized_directory_growth
    growth = spec_directory_window_growth

    return nil if growth.nil?

    baseline = growth.baseline_run

    {
      state: growth.state,
      comparable: growth.comparable?,
      rows: growth.rows.map { |row| serialized_directory_growth_row(row) },
      window_run_count: growth.window_run_count,
      covered_run_count: baseline && growth.covered_run_count,
      runs_back: baseline && growth.runs_back,
      shortened: baseline && growth.shortened?,
      skipped_unmeasured_count: growth.skipped_unmeasured_count,
      skipped_assembled_differently_count: growth.skipped_assembled_differently_count,
      anchor_commit_sha: growth.anchor_run&.commit_sha,
      baseline_commit_sha: baseline&.commit_sha,
      directory_count: baseline && growth.directory_count,
      truncated: baseline && growth.truncated?,
      baseline_recorded_count: baseline && growth.baseline_recorded_count,
      anchor_recorded_count: baseline && growth.anchor_recorded_count,
      limit: SpecObservation::MOVED_DIRECTORIES_LIMIT
    }
  end

  # One area's movement across the window, and BOTH OPERANDS it was taken across — never one of the
  # labels the row builds for the panel. `SpecDirectoryWindowGrowth::Row` carries `change_label`,
  # `change_reading`, `baseline_count_label` and `anchor_count_label`, which are typographic and
  # screen-reader spellings of these same numbers: a U+2212 for a negative, `"±0"` for an area that
  # did not move, `"New area"` where a delta would be arithmetic on a side that was never measured,
  # and delimited numerals throughout. A client served those would be splitting strings and
  # stripping glyphs to compare two rows. `serialized_unstable_test_row` set this rule; this block
  # is where it costs the most, because the labels here are the panel's whole vocabulary.
  #
  # `previous_count`/`latest_count` are the aggregate's own two sides and are the parent Struct's
  # names; they go out as `baseline_count`/`anchor_count`, the names the window object itself uses
  # for the two ends of the comparison and the two shas above are served under. The translation
  # happens once, here, rather than in every client's head.
  #
  # `moved`, `new_area` and `removed_area` are the three states the label collapses, served as the
  # booleans they are. `new_area` and `removed_area` are NOT derivable from `change` alone — an area
  # at zero on one side is a real absence, and `+40` against an absent side reads identically to an
  # existing area that gained forty examples, which is the one distinction a client scanning this
  # list most needs. The block that holds this row has already established that BOTH runs recorded
  # rows, which is what makes a zero on one side that area's own absence rather than a run that
  # recorded nothing anywhere.
  def serialized_directory_growth_row(row)
    {
      path: row.path,
      baseline_count: row.previous_count,
      anchor_count: row.latest_count,
      change: row.change,
      moved: row.moved?,
      new_area: row.new_area?,
      removed_area: row.removed_area?
    }
  end

  # The contract the RUN-OVER-RUN growth rows below are served under — and, when they are `null`,
  # the reason they are. Served UNCONDITIONALLY, on the key-always-present rule
  # `serialized_directory_growth_window` and `latest_run.shards` both argue for: a block that
  # explains a `null` is worthless if it is itself absent whenever the `null` happens.
  #
  # `_window` NAMES THE CONTRACT BLOCK HERE, NOT A RUN WINDOW — the suffix this endpoint has used
  # three times for "the facts that decide how the array beside it may be read". This comparison
  # spans exactly TWO runs and `basis` says so in a token rather than leaving the suffix to be read
  # as a claim about depth. The pairing is kept because a client that learned the shape once
  # (`history_window`/`history`, `unstable_tests_window`/`unstable_tests`,
  # `directory_growth_window`/`directory_growth`) should not have to learn a fourth.
  #
  # ⭐ `state` LIVES HERE AND NOT ON THE ROWS BLOCK, WHICH IS WHERE THIS BLOCK DIVERGES FROM ITS
  # WINDOW SIBLING AND WHY. There, `state` rides on the rows block because that block is `null`
  # only when the object was never constructed, and `grouped` out here covers that one case. Here
  # there are TWO ways to have no rows — the object was not constructed (no runs to compare) and
  # the object was constructed and could not compare — and a `state` on the rows block would be
  # absent in exactly the first of them. So the nine-way answer is served on the block that is
  # always present, and the rows block carries figures only.
  #
  # THE STATE ENUMERATION, in full, because a client must be able to enumerate it:
  #
  # * `no_latest_run` — CI has never reported. Serializer-level; see `spec_directory_growth`.
  # * `no_previous_run` — there is a latest run and no earlier run on its branch to compare it
  #   against. Serializer-level, and it covers TWO shapes that `branch` separates: a `branch` of
  #   `null` is a latest run whose client sent no branch (there is no branch to compare on, and
  #   `Repository#previous_test_run_on_branch` refuses to pool anonymous runs into a fictional
  #   history), and a named `branch` is a genuine first run on that branch.
  # * `latest_unmeasured`, `previous_unmeasured`, `assembled_differently` — `SpecDirectoryGrowth`'s
  #   three pre-query states, decided from the two runs alone.
  # * `neither_recorded`, `previous_unrecorded`, `latest_unrecorded` — its three row-decided states.
  # * `comparable` — the rows block below is non-null.
  #
  # The first two are ADDED AT THIS CALL SITE and are not model states, deliberately.
  # `SpecDirectoryGrowth.for` dereferences its second argument on its second line, so it must not be
  # handed a nil; widening it to accept one would change a contract the dashboard already guards for
  # itself (`repositories_controller.rb`, `if @latest_test_run && @previous_test_run`). The guard is
  # duplicated here rather than the model relaxed, and `no_previous_run` is a DISTINCT token from
  # `previous_unmeasured` because they are different repairs: "there is nothing to compare against"
  # against "the run we compared against reported no tests".
  #
  # `comparable` RIDES BESIDE `state` as the single boolean a client that only wants the rows can
  # branch on, read off the object's own predicate rather than re-derived from the symbol — and it
  # is exactly `directory_run_growth != null`, so there is one boolean here and not two.
  #
  # NO `?branch=` GATE, AND THAT IS THE FEATURE. `branch_scope` is the constant `single_branch`
  # because this comparison is branch-correct BY CONSTRUCTION rather than by a parameter:
  # `Repository#previous_test_run_on_branch` scopes to the latest run's own branch and refuses a
  # blank one. So `branch` names the branch the comparison WAS MADE ON — read off the latest run,
  # never off `requested_branch`, which narrows `history` and must not be read as having narrowed
  # this. Like `latest_run`, this block is NOT re-anchored by `?branch=`: under `?branch=main` on a
  # repository whose newest run is on `feature/x`, this still compares the two newest `feature/x`
  # runs, and `branch` says `feature/x` so the two cannot be confused.
  #
  # `basis` IS WHAT SEPARATES THIS PAIR FROM THE ONE ABOVE IT, and it is the key a client reads to
  # know which of the two growth measurements it is holding. `two_endpoints` there says the figures
  # are the two ends of a thirty-run window and not a series over it; `previous_run_on_branch` here
  # says the baseline is one specific run, named by `baseline_commit_sha`, and that the comparison
  # therefore has NO such gap in it — an area that gained 300 examples and gave them back cannot
  # hide inside a two-run comparison. Spelled as the baseline's RULE rather than as "adjacent_runs",
  # which would be read as adjacent in the history `history` serves and is not what this is: the two
  # runs are consecutive ON THEIR BRANCH, and the all-branch history routinely has other branches'
  # runs between them.
  #
  # `order` and `tie_break_served` are the WINDOW SIBLING'S OWN VALUES because they are the same
  # query's: `SpecObservation.directory_growth_between` orders by `ABS(...) DESC` then `path ASC`,
  # and both operands and the path go out on every row, so a client can reproduce this order from
  # what it holds.
  #
  # `anchor_commit_sha`/`baseline_commit_sha` NAME THE TWO RUNS, under the sibling's names rather
  # than "latest"/"previous", because the ROWS below are served as `anchor_count`/`baseline_count`
  # and a client must be able to tell which sha each operand was counted on. ANCHOR IS THE LATEST
  # RUN and BASELINE IS THE PREVIOUS ONE, which is the direction every `change` is signed in. Both
  # are nullable and independently so: `baseline_commit_sha` is `null` in both serializer states,
  # and `anchor_commit_sha` in `no_latest_run` alone.
  def serialized_directory_run_growth_window
    growth = spec_directory_growth

    {
      order: "abs_change_desc,path_asc",
      tie_break_served: true,
      basis: "previous_run_on_branch",
      branch_scope: "single_branch",
      branch: latest_test_run&.branch,
      state: growth&.state || (latest_test_run.nil? ? :no_latest_run : :no_previous_run),
      comparable: growth&.comparable? || false,
      anchor_commit_sha: latest_test_run&.commit_sha,
      baseline_commit_sha: previous_test_run&.commit_sha
    }
  end

  # WHICH AREAS OF THE SUITE GREW OR SHRANK IN THE LATEST PUSH — the agent-readable half of the
  # "Areas that grew or shrank" panel `repositories#show` renders from the same object, off the same
  # two runs, in the same order. It is the question the dashboard answers with no parameter at all
  # and this endpoint could not be asked: `directory_growth` beside it needs a `?branch=` and then
  # answers about the two ends of a thirty-run window, which is a different measurement.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query — this file's governing rule, stated
  # in full on `serialized_spec_files`. `SpecDirectoryGrowth` is view-free, so the API and the panel
  # cannot name different areas or different operands for the same repository.
  #
  # ⭐ `null` IN EVERY NON-COMPARABLE STATE, AND NOT A BLOCK OF ZEROS. The window sibling can gate
  # its honesty figures KEY BY KEY, on `baseline_run`, because its object keeps them in four of its
  # eight states — the four its aggregate read reaches — and drops them in the other four; this
  # object keeps them in ONE state only, so there is no per-key line to draw and the whole block
  # goes. (Seven-of-eight is the count of the window sibling's ABSENCE states, not of the states
  # that retain totals; it is a different figure and does not belong to this argument.)
  # `SpecDirectoryGrowth.from_tuples` returns `new(state: :previous_unrecorded)` and friends WITHOUT
  # the counts it just read, so every aggregate falls back to its `0` default. Serving them raw
  # would print `anchor_recorded_count: 0` for a latest run that recorded four hundred rows — a
  # fabricated denominator sitting among the fields that exist to be trustworthy, which is the
  # failure the sibling's ⭐ gates exist to prevent, refused here by a different route. The
  # actionable half of those states is the `state` token, and it is served unconditionally one key
  # up.
  #
  # So this block is non-null exactly when `directory_run_growth_window.comparable` is true, and
  # every figure in it was counted off the rows the `rows` array lists.
  #
  # ROWS THROUGH `serialized_directory_growth_row`, SHARED VERBATIM WITH THE WINDOW BLOCK and not a
  # second copy of it. That method is written entirely against `SpecDirectoryGrowth::Row` — `change`,
  # `moved?`, `new_area?` and `removed_area?` are all defined on the parent Struct, and
  # `SpecDirectoryWindowGrowth::Row` inherits them — so the two growth blocks read alike row for row,
  # including the `previous_count`/`latest_count` → `baseline_count`/`anchor_count` translation and
  # the rule against serving the panel's `*_label`/`change_reading` strings.
  #
  # `truncated` DISCLOSES THE CAP with both operands beside it, exactly as the sibling does:
  # `directory_count` is counted BEFORE the `LIMIT` applies (a window function, so it runs first),
  # and `limit` is read off `SpecObservation::MOVED_DIRECTORIES_LIMIT` rather than restated —
  # this call site passes no `limit:`, so the constant IS the bound the query applied.
  #
  # `baseline_recorded_count`/`anchor_recorded_count` are the DENOMINATORS the recorded-rows states
  # turn on, and deliberately not `TestRun#total_specs_count`, which is re-derived by SUM over shard
  # reports and can legitimately differ from the rows a run actually wrote.
  #
  # ONE READ OF `spec_observations` AT MOST, and none at all in five of the nine states: the two
  # serializer states never construct the object, and its own gate short-circuits three more before
  # any query. The comparison itself is two run ids in an `IN` list — the same aggregate already
  # plan-certified in `spec/models/spec_observation_spec.rb`, so that certification transfers.
  def serialized_directory_run_growth
    growth = spec_directory_growth

    return nil unless growth&.comparable?

    {
      rows: growth.rows.map { |row| serialized_directory_growth_row(row) },
      directory_count: growth.directory_count,
      truncated: growth.truncated?,
      baseline_recorded_count: growth.previous_recorded_count,
      anchor_recorded_count: growth.latest_recorded_count,
      limit: SpecObservation::MOVED_DIRECTORIES_LIMIT
    }
  end

  # One area's RUNTIME movement between two runs, its two operands, and the three different absences
  # that all render as an empty Change cell.
  #
  # A NEW METHOD AND NOT `serialized_directory_growth_row`, WHICH CANNOT BE REUSED HERE. That method
  # is written entirely against `SpecDirectoryGrowth::Row` — `previous_count`/`latest_count`,
  # `moved?`, `new_area?`, `removed_area?` — and `SpecDirectoryWindowGrowth::Row` INHERITS that
  # Struct, which is the whole reason those two blocks share it. `SpecDirectoryRuntimeGrowth::Row` is
  # an INDEPENDENT Struct with seconds operands and a predicate the count Struct does not have, so a
  # shared serializer would be a method branching on which Struct it was handed.
  #
  # `previous_seconds`/`latest_seconds` are the aggregate's own two sides and are the model's names;
  # they go out as `baseline_seconds`/`anchor_seconds`, this endpoint's wire convention for the two
  # ends of a comparison and the names `anchor_commit_sha`/`baseline_commit_sha` one key up give
  # them. The same translation `serialized_directory_growth_row` makes for the counts, made once here
  # rather than in every client's head.
  #
  # ⭐ THREE PREDICATES, BECAUSE THERE ARE THREE DIFFERENT ABSENCES AND THE MODEL KEEPS THEM APART.
  # `change` is `null` when an area is NEW, when it was REMOVED, and when both runs ran it and one of
  # them reported no timing for it — and those are three different things to go and fix. `comparable`
  # says only that there is nothing to subtract; `new_area`/`removed_area` say the area is on one side
  # only; `timing_gap` says both runs HAVE this area and the telemetry, not the code, is what is
  # missing. Collapsing them re-creates exactly the confusion `SpecDirectoryRuntimeGrowth::Row` spends
  # paragraphs refusing.
  #
  # `change`, `baseline_seconds` and `anchor_seconds` ARE LEGITIMATELY `null` and are served as the
  # nils they are — never coerced to `0`. `SUM` skips NULLs silently and `duration_seconds` is
  # nullable by design, so a zero here would be "this side was never timed" made byte-identical to
  # "this area took no time", which is the one reading the whole panel exists to refuse.
  #
  # NO VIEW STRINGS. `previous_label`, `latest_label`, `coverage_label`, `change_label` and
  # `change_reading` are typographic and screen-reader spellings of these same numbers — a U+2212 for
  # a negative, `"±0"`, `"not reported"`, `"New area"` — and a client served those would be splitting
  # strings and stripping glyphs to compare two rows. The rule `serialized_directory_growth_row`
  # states, held at the grain where the labels are richest.
  def serialized_directory_runtime_growth_row(row)
    {
      path: row.path,
      baseline_seconds: row.previous_seconds,
      anchor_seconds: row.latest_seconds,
      change: row.change,
      comparable: row.comparable?,
      moved: row.moved?,
      new_area: row.new_area?,
      removed_area: row.removed_area?,
      timing_gap: row.timing_gap?
    }
  end

  # The contract the RUN-OVER-RUN RUNTIME growth rows below are served under — and, when they are
  # `null`, the reason they are. Served UNCONDITIONALLY, on the key-always-present rule every window
  # block on this endpoint holds: a block that explains a `null` is worthless if it is itself absent
  # whenever the `null` happens.
  #
  # `_window` NAMES THE CONTRACT BLOCK, NOT A RUN WINDOW — the suffix this endpoint has now used four
  # times for "the facts that decide how the array beside it may be read". This comparison spans
  # exactly TWO runs and `basis` says so in a token.
  #
  # ⭐ TWELVE STATES, AND THE ENUMERATION IS THE POINT. `SpecDirectoryRuntimeGrowth` has TEN of its
  # own — three MORE than its count sibling, because this grain has a second kind of absence:
  #
  # * `no_latest_run` — CI has never reported. ADDED AT THIS CALL SITE; see the accessor.
  # * `no_previous_run` — there is a latest run and no earlier run on its branch. ADDED HERE too, and
  #   it covers the same two shapes `branch` separates for the count sibling: a `null` branch is a
  #   latest run whose client sent none, a named branch is a genuine first run on it.
  # * `latest_unmeasured`, `previous_unmeasured`, `assembled_differently` — the three pre-query
  #   states, decided from the two runs alone and short-circuiting the read.
  # * `neither_recorded`, `previous_unrecorded`, `latest_unrecorded` — a side wrote no per-example
  #   ROWS at all (a client that posts only totals).
  # * `neither_timed`, `previous_untimed`, `latest_untimed` — THE GRAIN THE COUNT SIBLING HAS NO
  #   EQUIVALENT OF. A side recorded rows and none of them carried a duration. "The previous run
  #   recorded no per-example detail" and "the previous run reported no timings" are the same blank
  #   panel and two entirely different things to go and fix, which is why the model asks the RECORDED
  #   questions first and the TIMED ones only of a side that has rows.
  # * `comparable` — the rows block below is non-null.
  #
  # `comparable` RIDES BESIDE `state` as the single boolean a client that only wants the rows can
  # branch on, read off the object's own predicate rather than re-derived from the symbol — and it is
  # exactly `directory_runtime_growth != null`, so there is one boolean here and not two.
  #
  # ⭐ `order` IS THE COUNT SIBLING'S STRING PLUS `_nulls_last`, AND THE DIFFERENCE IS NOT COSMETIC.
  # `SpecObservation.directory_runtime_growth_between` orders by `ABS(...) DESC NULLS LAST`, and the
  # count read has no such clause because a `COUNT` is never NULL. Here the ordering key IS nil for
  # every area a side did not time, and those rows therefore sort LAST rather than first — which is
  # the whole reason a listed row can be untimed at all (the movement ran out before the cap did).
  # Copying `abs_change_desc,path_asc` across would be a token a client could not reproduce this
  # order from, so the token states what the query actually asked.
  #
  # NO `?branch=` GATE, AND THAT IS THE FEATURE — `branch_scope` is the constant `single_branch`
  # because `Repository#previous_test_run_on_branch` scopes to the latest run's OWN branch and
  # refuses a blank one, so this is branch-correct by construction rather than by a parameter. Like
  # `latest_run` and the count pair, this block is NOT re-anchored by `?branch=`: `branch` names the
  # branch the comparison WAS MADE ON, read off the latest run and never off `requested_branch`.
  #
  # `basis` is `previous_run_on_branch`, the count pair's token and for its reason: the baseline is
  # one specific run, named by `baseline_commit_sha`, so the comparison has no gap in it — an area
  # that gained a minute and gave it back cannot hide inside a two-run comparison.
  #
  # `anchor_commit_sha`/`baseline_commit_sha` NAME THE TWO RUNS under the sibling's names, because
  # the ROWS below are served as `anchor_seconds`/`baseline_seconds` and a client must be able to
  # tell which sha each operand was summed on. ANCHOR IS THE LATEST RUN and BASELINE IS THE PREVIOUS
  # ONE, which is the direction every `change` is signed in. Both are nullable and independently so.
  def serialized_directory_runtime_growth_window
    growth = spec_directory_runtime_growth

    {
      order: "abs_change_desc_nulls_last,path_asc",
      tie_break_served: true,
      basis: "previous_run_on_branch",
      branch_scope: "single_branch",
      branch: latest_test_run&.branch,
      state: growth&.state || (latest_test_run.nil? ? :no_latest_run : :no_previous_run),
      comparable: growth&.comparable? || false,
      anchor_commit_sha: latest_test_run&.commit_sha,
      baseline_commit_sha: previous_test_run&.commit_sha
    }
  end

  # WHICH AREAS OF THE SUITE GOT SLOWER OR FASTER IN THE LATEST PUSH — the agent-readable half of the
  # panel `repositories#show` renders from the same object, off the same two runs, in the same order.
  #
  # ⭐ NOT A RESTATEMENT OF `directory_run_growth`, AND NEITHER IS DERIVABLE FROM THE OTHER. That
  # block ranks areas by how their example COUNT moved; this one ranks them by how their summed
  # example TIME moved. `SpecDirectoryRuntimeGrowth`'s class comment carries the argument in full:
  # an area where somebody made an existing spec slow adds ZERO examples, so its
  # `ABS(latest_count - previous_count)` is `0`, it sorts last on that block and falls off the cap —
  # it is not a row there missing a column, it is not on that list at all. The independence runs both
  # ways: splitting one slow spec into four fast ones is `+3` examples and LESS time.
  #
  # It is also the grain `history` stops one short of. `test_runs.duration_seconds` is one figure per
  # run, so an agent holding every other key here can be told the run got ninety seconds slower and
  # can never ask WHERE. The per-area grain exists only in `spec_observations`.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query — this file's governing rule, stated
  # in full on `serialized_spec_files`. `SpecDirectoryRuntimeGrowth` is view-free, so the API and the
  # panel cannot name different areas or different operands for the same repository.
  #
  # ⭐ `null` IN EVERY NON-COMPARABLE STATE, AND THE COUNT SIBLING'S ARGUMENT FOR THAT DOES NOT
  # TRANSFER VERBATIM — so here is the one that does. There, `SpecDirectoryGrowth.from_tuples`
  # returns its row-decided states WITHOUT the counts it just read, so serving them raw would print
  # `anchor_recorded_count: 0` for a run that recorded four hundred rows. `SpecDirectoryRuntimeGrowth`
  # does the opposite deliberately: `from_tuples` passes `**totals` into EVERY state it constructs,
  # so in its six row-derived absence states the four denominators are real. Only the three gate
  # states, which never ran a query, carry the `0` defaults.
  #
  # It goes `null` anyway, for three reasons in order. (1) A key whose presence rule is "populated in
  # six of nine model states and zeroed in three" is a contract a client cannot hold in its head;
  # "non-null exactly when `directory_runtime_growth_window.comparable` is true" is one sentence and
  # is the rule the two shipped growth blocks already teach. (2) A per-key gate would not actually
  # eliminate the fabricated-denominator failure — the three gate states would still carry zeros —
  # it would only narrow it, at the cost of that rule. (3) The actionable half of every
  # non-comparable state is the `state` token, served unconditionally one key up.
  #
  # Serving the honest totals in the six row-derived states is a well-formed enhancement to the
  # window block and deliberately NOT smuggled in here.
  #
  # ⭐ ALL FOUR DENOMINATORS, NOT THE TWO THE COUNT SIBLING SERVES. This block has two grains of
  # absence and therefore two grains of denominator: how many rows each run RECORDED, and how many of
  # those carried a TIMING. The model's own rule — "1,204 examples reported a timing" is 1,204 of
  # something unstated — and the whole reading this block turns on is whether an area got faster or
  # merely went quiet. The count sibling has only the recorded pair because it has no timing grain.
  #
  # `truncated` DISCLOSES THE CAP with both operands beside it: `directory_count` is counted BEFORE
  # the `LIMIT` applies (a window function, so it runs first), and `limit` is read off
  # `SpecObservation::RETIMED_DIRECTORIES_LIMIT` rather than restated — this call site passes no
  # `limit:`, so the constant IS the bound the query applied. A DIFFERENT constant from the count
  # sibling's `MOVED_DIRECTORIES_LIMIT`, which happens to hold the same number today and is not the
  # same bound.
  #
  # ONE READ OF `spec_observations` AT MOST, and none at all in five of the twelve states: the two
  # serializer states never construct the object, and its own gate short-circuits three more before
  # any query. `SpecObservation.directory_runtime_growth_between` is already plan-certified in
  # `spec/models/spec_observation_spec.rb`, so that certification transfers.
  def serialized_directory_runtime_growth
    growth = spec_directory_runtime_growth

    return nil unless growth&.comparable?

    {
      rows: growth.rows.map { |row| serialized_directory_runtime_growth_row(row) },
      directory_count: growth.directory_count,
      truncated: growth.truncated?,
      baseline_recorded_count: growth.previous_recorded_count,
      anchor_recorded_count: growth.latest_recorded_count,
      baseline_timed_count: growth.previous_timed_count,
      anchor_timed_count: growth.latest_timed_count,
      limit: SpecObservation::RETIMED_DIRECTORIES_LIMIT
    }
  end

  # The contract the PER-FILE growth rows below are served under — and, when they are `null`, which
  # of the two reasons applies. Served UNCONDITIONALLY, on the key-always-present rule the two
  # blocks above it argue for: a block that explains a `null` is worthless if it is itself absent
  # whenever the `null` happens, and here it is absent on the commonest request of all — the one
  # that named no area.
  #
  # ⭐ `path` IS THE ASK RESTATED, AND IT IS THE DISCRIMINATOR. The rows block is `null` in two
  # different situations and a client must be able to tell them apart:
  #
  # * `path` is `null` — YOU DID NOT ASK. No `?spec_directory=` reached the server, or the shape it
  #   carried was not a string (`RequestedSpecDirectoryParam` treats a malformed shape as no ask at
  #   all, which is why this is never echoed from the raw parameter).
  # * `path` is set and `comparable` is `false` — you asked, and the comparison this drills out of
  #   refuses. `state` says which of the eight refusals.
  # * `path` is set and `comparable` is `true` — the rows block is populated.
  #
  # So the rows block is non-null exactly when `path` is non-null AND `comparable` is true. This is
  # the same separation `serialized_spec_directory_files` keeps between *"you did not ask"* and
  # *"the area you asked about has no rows"*, reached the other way round: that key is `null`
  # wholesale when unasked, and this one cannot be, because its `null` has a second cause to
  # explain.
  #
  # ⭐ `state` AND `comparable` ARE THE PARENT'S VERDICT, READ OFF THE PARENT — never re-derived and
  # never read off this drill-in's own object, which is not even constructed when nobody asked.
  # `SpecDirectoryFileGrowth` carries the parent's state verbatim and refuses to build anything the
  # moment the parent is not comparable, and its class comment gives the load-bearing reason: two of
  # the six model states (`previous_unrecorded`/`latest_unrecorded`) are facts about a RUN, and
  # everything this object reads is narrowed to one area. An area only the latest run recorded has
  # zero previous-side rows — `previous_unrecorded` spelled identically and meaning something else
  # entirely. So this block's `state` is `directory_run_growth_window.state`, always, by
  # construction: the drill-in is ABSENT whenever the block it drills out of cannot compare, and it
  # never offers a second opinion about two runs.
  #
  # The safe navigation is LOAD BEARING and not stylistic — `spec_directory_growth` is `nil` in the
  # two serializer-level states, and the same `latest_test_run.nil?` fallback the sibling window
  # block uses tells those two apart off the one memoized accessor.
  #
  # NO SECOND SPELLING OF THE OPERANDS. `branch`, `anchor_commit_sha` and `baseline_commit_sha` are
  # served once, on `directory_run_growth_window`, and are identical here by construction — this is
  # the SAME comparison between the SAME two runs, narrowed to one area. Repeating them would be two
  # blocks under one request naming one run two ways, which is the hazard the shared
  # anchor/baseline vocabulary exists to prevent.
  #
  # `limit` LIVES HERE rather than on the rows block, unlike its sibling's: it is a fact about how
  # the array beside it may be read, and a client that asked for an area and got `null` should still
  # be able to learn what a populated answer would have been capped at. Read off
  # `SpecObservation::SPEC_DIRECTORY_FILE_GROWTH_LIMIT` rather than restated — it is its own
  # constant, neither the areas' ten nor the durations drill-down's.
  def serialized_directory_run_file_growth_window
    growth = spec_directory_growth

    {
      path: requested_spec_directory,
      order: "abs_change_desc,path_asc",
      tie_break_served: true,
      basis: "previous_run_on_branch",
      state: growth&.state || (latest_test_run.nil? ? :no_latest_run : :no_previous_run),
      comparable: growth&.comparable? || false,
      limit: SpecObservation::SPEC_DIRECTORY_FILE_GROWTH_LIMIT
    }
  end

  # WHICH FILES OF THE ASKED-FOR AREA GREW OR SHRANK IN THE LATEST PUSH — the agent-readable half of
  # the "Files that grew or shrank in this directory" panel `repositories#show` renders from the
  # same object, off the same two runs, in the same order.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query — this file's governing rule, stated
  # in full on `serialized_spec_files`. `SpecDirectoryFileGrowth` is view-free, so the API and the
  # panel cannot name different files or different operands for the same area of the same
  # repository.
  #
  # ⭐ `null` IN EVERY NON-COMPARABLE STATE, AND NOT A BLOCK OF ZEROS — the rule its parent block
  # pins by its own example. `SpecDirectoryFileGrowth.for` returns `new(path:, state:)` for a parent
  # that cannot compare, WITHOUT any of the counts, so every aggregate falls back to its `0`
  # default: serving them raw would print `anchor_recorded_count: 0` for a latest run that recorded
  # four hundred rows in that very area — a fabricated denominator sitting among the fields that
  # exist to be trustworthy. The actionable half of those states is the `state` token, and it is
  # served unconditionally one key up.
  #
  # `file_count` is the AREA's — every file EITHER run recorded a row for, counted BEFORE the
  # `LIMIT` by a window function and therefore never `rows.size`, which is the truncated figure. So
  # `truncated` is disclosed against a population rather than against the list's own length, and the
  # caption a client builds from these figures cannot describe a different row set from the rows it
  # was handed.
  #
  # `baseline_recorded_count`/`anchor_recorded_count` are THIS AREA'S rows, deliberately not the
  # identically-named whole-run figures on the parent block: every figure here comes back from the
  # one grouped aggregate that returned the rows, narrowed by the same area predicate. A client
  # mixing the two would divide an area's population by the suite's.
  #
  # ONE READ OF `spec_observations` AT MOST, and none at all unless a caller asked for an area AND
  # the parent comparison is comparable — the gate is a read of an object already in memory, so it
  # short-circuits before any query in all eight refusing states even with `?spec_directory=` set.
  # The read is bounded by the size of the AREA rather than of the suite and needs no index of its
  # own: see `SpecObservation.file_growth_between`.
  def serialized_directory_run_file_growth
    growth = spec_directory_file_growth

    return nil unless growth&.comparable?

    {
      rows: growth.rows.map { |row| serialized_directory_file_growth_row(row) },
      file_count: growth.file_count,
      truncated: growth.truncated?,
      baseline_recorded_count: growth.previous_recorded_count,
      anchor_recorded_count: growth.latest_recorded_count
    }
  end

  # One spec file's movement between two runs, and BOTH OPERANDS it was taken across — never one of
  # the labels the row builds for the panel. `SpecDirectoryFileGrowth::Row` carries `change_label`,
  # `change_reading`, `previous_count_label` and `latest_count_label`, which are typographic and
  # screen-reader spellings of these same numbers; `serialized_directory_growth_row` states in full
  # why a client served those would be splitting strings and stripping glyphs.
  #
  # `previous_count`/`latest_count` go out as `baseline_count`/`anchor_count`, the vocabulary both
  # growth pairs on this endpoint already use, so the two blocks under one request cannot name the
  # same run two ways. ANCHOR IS THE LATEST RUN and BASELINE IS THE PREVIOUS ONE, which is the
  # direction every `change` is signed in.
  #
  # NOT `serialized_directory_growth_row` REUSED, though the arithmetic and the two translated names
  # are identical. `new_file`/`removed_file` are not `new_area`/`removed_area` — they are claims
  # about a different grain, and a shared mapper would have to take its own nouns as arguments,
  # which is a parameterised key name standing where two plain ones were. That is the disposition
  # `SpecDirectoryFileGrowth::Row` itself takes on the same question one layer down.
  #
  # `new_file` and `removed_file` are NOT derivable from `change` alone: a file at zero on one side
  # is that file's real absence, and `+47` against an absent side reads identically to an existing
  # file that gained forty-seven examples. At THIS grain that distinction is the whole subject — a
  # file at "new" beside one at "removed" is the shape of a rename, and two files at `+47` and `−47`
  # is not. The block holding these rows has already established, through the parent's gate, that
  # BOTH runs recorded rows, which is what makes a zero on one side that file's own absence rather
  # than a run that recorded nothing anywhere.
  def serialized_directory_file_growth_row(row)
    {
      path: row.path,
      baseline_count: row.previous_count,
      anchor_count: row.latest_count,
      change: row.change,
      moved: row.moved?,
      new_file: row.new_file?,
      removed_file: row.removed_file?
    }
  end

  # The repository's newest run, memoized across the nil — read by `latest_run` and by BOTH
  # run-over-run growth blocks above, which is why it is an accessor here and not three calls to
  # `Repository#latest_test_run` (which memoizes nothing and would issue the query once per reader).
  #
  # Memoizing also makes the ONE INSTANCE shared, which is what keeps `assembled_like?` free: that
  # predicate reads `TestRun#shard_count`, which memoizes `shard_totals` PER INSTANCE, and
  # `latest_run.shards` has already paid for it on this row by the time the growth gate asks.
  #
  # NOT RE-ANCHORED BY `?branch=` — see `serialized_latest_run`, which states that at length.
  def latest_test_run
    return @latest_test_run if defined?(@latest_test_run)

    @latest_test_run = current_repository.latest_test_run
  end

  # The run the latest one is compared against: the newest run STRICTLY OLDER than it ON ITS OWN
  # BRANCH. `nil` — never a fallback row — when there is no honest comparison to make, which
  # `Repository#previous_test_run_on_branch` argues for itself at length: the row immediately before
  # the latest one in the interleaved all-branch history is routinely a different branch, and a
  # difference taken against it reports a suite-size change no commit ever made.
  #
  # FREE WHEN THERE IS NOTHING TO ASK. That method returns `nil` before any read when the run is nil
  # or its branch is blank, so a repository CI has never reported on, and a run whose client sent no
  # branch, cost this endpoint nothing at all. Otherwise it is one indexed row lookup.
  #
  # THIS ROW IS NOT PRIMED, and that is a known second query rather than an oversight.
  # `SpecDirectoryGrowth`'s gate asks `TestRun#assembled_like?`, which reads `shard_count` on BOTH
  # sides; `latest_test_run` has already paid for its own `shard_totals` under `latest_run.shards`,
  # and this row is not in `history_runs` under every request — it is a different branch's row
  # whenever `?branch=` narrowed elsewhere, and outside the bound on a busy branch — so there is no
  # primed instance to read it off. `preload_shard_counts([previous_test_run])` would trade this
  # un-grouped `pick` for an equally-sized grouped read and buy nothing. One aggregate over one run's
  # shards, and `spec/requests/api/v1/repository_latest_run_spec.rb` pins the count so a third does
  # not appear unnoticed.
  #
  # Memoized across the nil with `defined?` rather than `||=` — `show` reads it twice through the
  # window block's `baseline_commit_sha` and the growth object below, and a `||=` would re-issue the
  # lookup on every repository that has no previous run, which is the case this most needs to be
  # cheap in.
  def previous_test_run
    return @previous_test_run if defined?(@previous_test_run)

    @previous_test_run = current_repository.previous_test_run_on_branch(latest_test_run)
  end

  # The run-over-run presenter, or `nil` when there are not two runs to hand it — memoized across
  # the nil with `defined?` for the reason `unstable_tests` states, and under the same double read
  # (`show` asks the window block for `state` and then this block for the rows).
  #
  # ⭐ THE GUARD IS THIS METHOD'S WHOLE SUBTLETY AND IT IS NOT OPTIONAL. `SpecDirectoryGrowth.for`
  # dereferences `previous_test_run` on its SECOND LINE (`unless previous_test_run.suite_size_measured?`)
  # and has no nil state of its own — there are six non-comparable states and "there is no previous
  # run" is none of them. `previous_test_run` above is nil for three ordinary live shapes: a
  # repository CI has never reported on, a latest run whose client sent no branch, and the first run
  # on a branch. Handed straight in, every one of those is a `NoMethodError` on a plain
  # `GET /api/v1/repository`.
  #
  # GUARDED HERE AND NOT BY WIDENING THE MODEL, which is the same shape `RepositoriesController#show`
  # already uses (`if @latest_test_run && @previous_test_run`). Teaching `SpecDirectoryGrowth.for` to
  # accept a nil would give the object a seventh absence state that the dashboard — its other caller,
  # which guards for itself — can never reach, and would move a decision the two call sites make
  # identically into a contract only one of them relies on.
  #
  # The two guarded cases are told apart one key up, by `latest_test_run.nil?`, off this same
  # memoized accessor — so the state token and the object it stands in for cannot come apart.
  def spec_directory_growth
    return @spec_directory_growth if defined?(@spec_directory_growth)

    @spec_directory_growth =
      latest_test_run && previous_test_run && SpecDirectoryGrowth.for(latest_test_run, previous_test_run)
  end

  # The run-over-run RUNTIME presenter, or `nil` when there are not two runs to hand it — memoized
  # across the nil with `defined?` rather than `||=`, on this file's idiom for every nullable
  # accessor and under the same double read its count sibling has: `show` asks the window block for
  # `state` and then this block for the rows, so a `||=` would re-issue the previous-run lookup on
  # every repository that has none, which is the case this most needs to be cheap in.
  #
  # ⭐ THE GUARD IS THIS METHOD'S WHOLE SUBTLETY AND IT IS NOT OPTIONAL, exactly as one method up.
  # `SpecDirectoryRuntimeGrowth.for` dereferences `previous_test_run` on its SECOND LINE
  # (`unless previous_test_run.suite_size_measured?`) and has no nil state of its own — there are
  # nine non-comparable states and "there is no previous run" is none of them. `previous_test_run` is
  # nil for three ordinary live shapes: a repository CI has never reported on, a latest run whose
  # client sent no branch, and the first run on a branch. Handed straight in, every one of those is a
  # `NoMethodError` on a plain unparameterised `GET /api/v1/repository`.
  #
  # GUARDED HERE AND NOT BY WIDENING THE MODEL — the same shape `RepositoriesController#show` already
  # uses (`if @latest_test_run && @previous_test_run`), and the reason `spec_directory_growth` states
  # for its own guard: teaching `.for` to accept a nil would give the object an eleventh absence
  # state that the dashboard — its other caller, which guards for itself — can never reach, and would
  # move a decision the two call sites make identically into a contract only one of them relies on.
  #
  # The two guarded cases are told apart one key up, by `latest_test_run.nil?`, off this same
  # memoized accessor — so the state token and the object it stands in for cannot come apart.
  #
  # A SECOND OBJECT OVER THE SAME TWO RUNS, and that is one more read rather than a doubling: this
  # asks a question `SpecDirectoryGrowth` structurally cannot answer (see
  # `serialized_directory_runtime_growth`), and its own gate short-circuits before any query in the
  # three states decidable from the two runs alone.
  def spec_directory_runtime_growth
    return @spec_directory_runtime_growth if defined?(@spec_directory_runtime_growth)

    @spec_directory_runtime_growth =
      latest_test_run && previous_test_run &&
      SpecDirectoryRuntimeGrowth.for(latest_test_run, previous_test_run)
  end

  # The per-file drill-in for the ONE area a caller asked about, or `nil` when nobody asked or there
  # was no comparison to narrow — memoized across the nil with `defined?` rather than `||=`, on the
  # idiom every nullable accessor in this file uses. Unlike `spec_directory_growth` above,
  # `spec_directory_window_growth` below, and `unstable_tests` further up, this accessor is read
  # ONCE: the contract block reads the PARENT, deliberately, so the verdict is never taken off this
  # object — which is not even constructed when nobody asked. The memoization is this file's idiom
  # held, not a second read paid for; the two guards below are what actually keep the key cheap.
  #
  # ⭐ TWO GUARDS, AND THEY REFUSE DIFFERENT THINGS. `requested_spec_directory` is the ASK — decided
  # from the params before any query, so a client that never sends the parameter pays nothing at all
  # for this key's existence. `spec_directory_growth` is the parent COMPARISON, and it is guarded
  # here for a reason the HTML call site is structurally immune to: `repositories_controller#show`
  # only ever reaches `SpecDirectoryFileGrowth.for` inside `if @latest_test_run && @previous_test_run`,
  # where the growth object has already been built. This endpoint serves the key on every request,
  # and `spec_directory_growth` is `nil` in both serializer-level states — a repository CI has never
  # reported on, and a latest run with no earlier run on its branch. `.for` dereferences its
  # `growth:` argument on its first line (`unless growth.comparable?`), so handing it that `nil` is
  # a `NoMethodError` on a plain `GET /api/v1/repository?spec_directory=spec/models`.
  #
  # GUARDED HERE AND NOT BY WIDENING THE MODEL, for the reason `spec_directory_growth` states about
  # its own guard one method up: teaching `.for` to accept a nil growth would give it an absence
  # state the dashboard — its other caller, which guards for itself — can never reach.
  #
  # ⭐ AND ONLY THOSE TWO. Comparability is NOT re-asked here: `.for` takes the parent object and
  # refuses on its own first line, reading memory rather than the database, so the six model-level
  # refusals cost this endpoint nothing while still producing an object that carries the parent's
  # state verbatim. Adding a `&.comparable?` to the condition above would be a fourth spelling of
  # predicates the parent has already asked on these same two runs — see `SpecDirectoryFileGrowth`,
  # which prices exactly that and explains why two of the six states are not re-derivable at this
  # grain in any case.
  def spec_directory_file_growth
    return @spec_directory_file_growth if defined?(@spec_directory_file_growth)

    @spec_directory_file_growth =
      if requested_spec_directory && spec_directory_growth
        SpecDirectoryFileGrowth.for(latest_test_run, previous_test_run, requested_spec_directory,
                                    growth: spec_directory_growth)
      end
  end

  # The presenter, or `nil` when no comparison was allowed — memoized across the nil with `defined?`
  # rather than `||=`, for the reason `unstable_tests` states above and under the same double read
  # (`show` asks for the window block's `grouped` and then for the rows).
  #
  # ⭐ THE WINDOW IS HANDED IN REVERSED, AND THAT IS THIS METHOD'S WHOLE SUBTLETY.
  # `SpecDirectoryWindowGrowth.for` documents its parameter as *"the window, ALREADY LOADED and
  # OLDEST FIRST"*, takes `runs.last` as its ANCHOR and walks from index 0 for the BASELINE.
  # `history_runs` is `Repository#recent_test_runs`, ordered `(created_at, id) DESC` — NEWEST first.
  # Handing it in unreversed does not raise: `runs.last` becomes the OLDEST run, the walk finds a
  # baseline among the NEWER ones, and every `change` comes back SIGN-FLIPPED — a suite that grew
  # reports its areas shrinking, under a block that looks perfectly well-formed. The human panel
  # avoids this by construction because `Repository#suite_size_trajectory` ends `.to_a.reverse`; this
  # call site has to do it deliberately.
  #
  # The adjacent precedent is what makes it easy to walk into and is NOT a licence: `UnstableTests.for`
  # documents the same parameter with no ordering clause and is order-indifferent — it reads
  # `runs.map(&:id)` and groups — so `unstable_tests` above hands `history_runs` straight in and is
  # right to. This one is not order-indifferent, and the two lines are otherwise identical.
  #
  # `.reverse` AND NEVER `.reverse!`. `serialized_history` maps the same memoized array and
  # `serialized_history_window` declares `order: "ingested_at_desc,ingest_sequence_desc"` over it;
  # reversing in place would make the endpoint's own ordering contract a lie, in the same response
  # body, for every client reading `history`.
  #
  # The branch gate lives HERE, in one place, so the boolean the window serves and the decision that
  # produced it cannot come apart — see `serialized_directory_growth_window` for why an unfiltered
  # window is refused rather than answered.
  def spec_directory_window_growth
    return @spec_directory_window_growth if defined?(@spec_directory_window_growth)

    @spec_directory_window_growth =
      requested_branch && SpecDirectoryWindowGrowth.for(history_runs.reverse, branch: requested_branch)
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
end
