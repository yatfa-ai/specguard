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
  BRANCH_HISTORY_LIMIT = Repository::TRAJECTORY_LIMIT

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
      history: serialized_history
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
  def serialized_shards(test_run)
    return nil unless test_run.multi_shard?

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
      }
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
  # `BRANCH_HISTORY_LIMIT` and an unfiltered one at `HISTORY_LIMIT`, and serving the applied bound is
  # what keeps `returned == limit` meaning the same thing under both — a client that had to know the
  # rule to interpret the number would be reading a caption again.
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

  # The branch the client asked to narrow `history` to, or `nil` for "do not narrow it".
  #
  # THE FIRST REQUEST PARAMETER READ ANYWHERE IN `Api::V1` (`git grep "params\[" app/controllers/api`
  # found none before this), so the two guards below are the pattern rather than local caution.
  #
  # `is_a?(String)` FIRST, and it is not defensive noise: `?branch[]=main` parses to an Array and
  # `?branch[a]=b` to `ActionController::Parameters`, neither of which answers `.presence` the way
  # this reads it — an unguarded `params[:branch].presence` turns a malformed query string into a
  # 500 on an authenticated GET. Anything that is not a String is treated as no filter, which is the
  # same answer an absent param gets.
  #
  # `.presence` SECOND, which is what makes `?branch=` mean "no filter" rather than
  # `WHERE branch = ''` — and, critically, keeps any input at all from reaching a
  # `WHERE branch IS NULL`. `branch` is nullable and an anonymous run is an ordinary live state, so
  # NULL is "the client did not say" (the meaning `serialized_history_row` pins) and not a branch
  # anyone can ask for. `Repository#recent_test_runs` makes the same guard on its own side; this one
  # is here so the model is never handed a blank in the first place.
  #
  # No validation branch and no 400: an unknown branch is not a malformed request, it is a request
  # whose answer is zero rows. See `serialized_history` for why `[]` is the right answer and a
  # substituted branch's rows would be the dangerous one.
  #
  # Memoized with `defined?` rather than `||=`, because `nil` is the common answer and `||=` would
  # re-read the params on every call.
  def requested_branch
    return @requested_branch if defined?(@requested_branch)

    raw = params[:branch]
    @requested_branch = raw.is_a?(String) ? raw.presence : nil
  end

  # Which bound applies, decided in ONE place so the window's `limit` and the query's `LIMIT` cannot
  # come apart. A response stating a bound it did not apply is worse than either bound alone: the
  # client's `returned == limit` test — its only signal that there is more history behind the
  # window — would answer about a number nothing enforced.
  def history_limit
    requested_branch ? BRANCH_HISTORY_LIMIT : HISTORY_LIMIT
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

  # What the human panel's row carries, plus the two composition facts that say whether the row may
  # be differenced against its neighbour.
  #
  # SHARD COUNT ONLY — deliberately not a `shards` sub-block like `serialized_shards` above builds
  # for the latest run. `TestRun#preload_shard_count`'s comment is explicit that the preload seam
  # "primes the COUNT alone and never the whole `shard_totals` tuple", so `timed_shard_count` and
  # `machine_seconds` remain one `pick` per instance: a slice-8-style block on ten history rows is
  # ten extra queries. Of the two remedies open here, this takes the first — restrict the rows to
  # the cheaply-preloadable count — because the second (a grouped preload covering the whole tuple)
  # needs a new model method this slice does not have the mandate to add, and because a client
  # differencing two rows needs to know they were assembled from the same number of parts, not what
  # each part cost. `TestRun#assembled_like?` decides that same question on shard-count
  # equality alone, so this serves exactly what that rule reads. The per-run cost figures stay
  # available in full on `latest_run`, which is one row and pays one `pick` for them.
  #
  # `suite_size_measured` is `TestRun#suite_size_measured?` — a run that reported zero tests has a
  # count but not a measurement, and a difference taken against it describes the report rather than
  # the suite. Serialized as the boolean rather than left for the client to re-derive from
  # `total_specs`, so the endpoint and the panel cannot drift on what "measured" means.
  #
  # Counts and booleans, never prose: `TestRun#delivery_description` words this same shard fact in
  # English for the panel, and `serialized_shards` above already settled that a machine-readable
  # client cannot act on a sentence without parsing it.
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
  # One grouped `COUNT(*)` for the whole window primes `shard_count` on every row — see
  # `ShardCountPreloading`, shared with the human panel that asks the same question of the same
  # rows. So `history` costs two queries at ten rows and the same two at one, instead of one `pick`
  # per row. A narrowed window primes identically: `preload_shard_counts` keys off the ids it is
  # handed and does not care how they were selected, so `?branch=` costs the same two queries at
  # thirty rows.
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
