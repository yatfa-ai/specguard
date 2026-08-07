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
  # The bound on `history` below. Ten rows is ten rows whether the suite holds three tests or
  # twenty thousand — `Repository#recent_test_runs` argues that in its own comment — so this is a
  # bound and not the first page of a pagination contract there is no cursor to continue.
  HISTORY_LIMIT = 10

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
  # `branch_scope` is the load-bearing one. `Repository#recent_test_runs` is the interleaved
  # history across EVERY branch CI reports from, so `history[0]` and `history[1]` are routinely two
  # different branches and the difference between their `total_specs` is not a change in the suite.
  # A client that wants a series filters on the per-row `branch` itself; this block is what tells
  # it that it must.
  #
  # `returned` beside `limit` rather than either alone: `returned == limit` is how a client learns
  # the suite has run at least ten times and this is the tail, not the whole history — the
  # inference it would otherwise draw wrongly from a full array.
  def serialized_history_window
    {
      order: "ingested_at_desc",
      branch_scope: "all_branches",
      limit: HISTORY_LIMIT,
      returned: history_runs.length
    }
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
      # Per-row, and non-negotiable: this is the field a client filters on to turn the interleaved
      # history `history_window.branch_scope` warns about into an actual series. `null` keeps its
      # `latest_run` meaning — "the client did not say" — and an anonymous run belongs to no series.
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
  def history_runs
    @history_runs ||= preload_shard_counts(current_repository.recent_test_runs(limit: HISTORY_LIMIT).to_a)
  end

  # One grouped `COUNT(*)` on `index_test_run_shards_on_test_run_id` for the whole window, priming
  # each row the way `TestRun#preload_shard_count` documents — so `history` costs two queries at ten
  # rows and the same two at one, instead of one `pick` per row.
  #
  # Re-stated here rather than shared with `RepositoriesController#preload_shard_counts`, which is
  # the same four lines. The two controllers descend from different bases (`Api::BaseController` is
  # an `ActionController::API`), so sharing means extracting a concern and editing
  # `app/controllers/repositories_controller.rb` — a file SPGD-197 is in flight on. A copy that can
  # be collapsed later beats a merge conflict in a file this ticket has no reason to touch.
  #
  # Returns early on an empty window rather than issuing `WHERE 1=0`: a repository that has never
  # ingested pays nothing for a history of no rows.
  def preload_shard_counts(runs)
    return runs if runs.empty?

    counts = TestRunShard.where(test_run_id: runs.map(&:id)).group(:test_run_id).count
    runs.each { |run| run.preload_shard_count(counts[run.id]) }
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
