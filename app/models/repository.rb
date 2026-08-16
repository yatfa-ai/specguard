# frozen_string_literal: true

# A registered GitHub repository — the tenant boundary for everything SpecGuard stores.
# API keys, test runs and spec intents all hang off it.
class Repository < ApplicationRecord
  FULL_NAME_FORMAT = %r{\A[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?/[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?\z}

  # The owner: the account that registered this repository, and the only one that holds every
  # permission implicitly (see RepositoryPolicy#owner?). Anything naming the owner reads through
  # here — never off `github_full_name`. The slug's org segment is a *GitHub* org, not a SpecGuard
  # account, and nothing constrains the two to match: an org repository is registered by whoever
  # administers it on GitHub, whose handle is not the org's name.
  #
  # What this model validates about `github_full_name` is presence, shape and global uniqueness,
  # and that is deliberately all — ownership is not a property of the string and cannot be checked
  # from it. It is established at the point of writing, by asking GitHub whether the writer
  # administers the repository: `RepositoriesController#save_with_verified_ownership` is the one
  # gate every write of this column passes through, and `GithubOwnership` is the question it asks.
  # A record created around this model rather than through that controller — a builder in the
  # suite, a console session — is unverified by construction, which is why the gate lives with the
  # request that carries a user's GitHub token rather than in a callback here.
  belongs_to :user
  has_many :api_keys, dependent: :destroy
  # Deleted before the runs that own them: `spec_observations.repository_id` is denormalised, so
  # the rows hang off both, and clearing them here is one statement per repository rather than one
  # per run. `delete_all` for the same reason it is `delete_all` on `TestRun` — the volume is a
  # row per example per run.
  has_many :spec_observations, dependent: :delete_all
  # Deleted before `test_runs` for the same reason `spec_observations` is: these hang off the
  # repository directly, so one statement clears them all. `delete_all` rather than `destroy_all`
  # because the volume is a row per test in the repository — 20,000 at the design point — and there
  # is no callback on the model that a destroy would run.
  has_many :spec_identities, dependent: :delete_all
  has_many :test_runs, dependent: :destroy
  has_many :spec_intents, dependent: :destroy
  # The refused half of the same delivery stream `test_runs` holds the accepted half of. Bounded by
  # `IngestRejection::REPOSITORY_RETENTION_ROWS` at the write path, so this is at most fifty rows —
  # `delete_all` is one statement and the model carries no callback a destroy would run.
  has_many :ingest_rejections, dependent: :delete_all
  has_many :repository_memberships, dependent: :destroy
  # Everyone granted access who is *not* the owner. The owner is `user` and holds every permission
  # implicitly, so they never appear here.
  has_many :members, through: :repository_memberships, source: :user

  before_validation :normalize_full_name
  before_validation :derive_name

  validates :github_full_name, presence: true, uniqueness: { case_sensitive: false },
                               format: { with: FULL_NAME_FORMAT, message: "must look like org/repo" }
  validates :name, presence: true

  def github_url = "https://github.com/#{github_full_name}"

  # Ties broken by id so two runs ingested in the same instant still order deterministically.
  def latest_test_run
    test_runs.order(created_at: :desc, id: :desc).first
  end

  # The newest run on ONE named branch — the anchor for a history the reader asked for by name,
  # where `latest_test_run` is the anchor for the one the repository happens to have pushed last.
  #
  # Same ordering as `latest_test_run`, tie-break included, so "the newest run on main" means the
  # same row here as it does everywhere else on the page.
  #
  # `nil` — and no query at all — for a blank branch, for the reason `previous_test_run_on_branch`
  # gives at length: `WHERE branch IS NULL` would pool every anonymous run from every branch and
  # every machine into one fictional history. A caller handed `nil` here falls back; it must never
  # be handed a row assembled from runs that have nothing in common.
  #
  # `nil` too for a branch that simply has no runs — an unrecognised `?branch=` value is an ordinary
  # thing for a reader to arrive with (a deleted branch, a typo, a stale bookmark), and it is the
  # caller's job to fall back to what it would have shown anyway rather than render an empty chart.
  def latest_test_run_on_branch(branch)
    return nil if branch.blank?

    test_runs.where(branch: branch).order(created_at: :desc, id: :desc).first
  end

  # The newest run ON ONE NAMED COMMIT — the anchor for a run the reader asked for by sha, where
  # `latest_test_run` is the anchor for the one the repository happens to have pushed last and
  # `latest_test_run_on_branch` for the one a named branch pushed last.
  #
  # NEWEST rather than THE run, and the distinction is a fact about the table rather than caution.
  # `test_runs` has no uniqueness constraint on `commit_sha` — the only unique index is
  # `(repository_id, ci_run_id) WHERE ci_run_id IS NOT NULL` — so a CI re-run of the same commit is
  # a second row, and a sharded suite reporting under one sha is several. "The run for this sha" is
  # therefore a question with more than one answer, and this picks the same one every other
  # newest-run reader on this model picks.
  #
  # Same ordering as `latest_test_run` and `latest_test_run_on_branch`, tie-break included, so "the
  # newest run" means the same row here as it does everywhere else. Two runs ingested in the same
  # instant on one sha resolve by id, which is the ingest sequence.
  #
  # `nil` — and no query at all — for a blank sha, so a caller holding an empty parameter falls back
  # rather than issuing `WHERE commit_sha = ''`: the column is NOT NULL and `TestRun` validates its
  # presence, so a blank matches nothing and the query is a guaranteed-empty read.
  #
  # `nil` too for a sha that simply has no runs, on the reasoning `latest_test_run_on_branch` gives
  # for an unrecognised branch: a stale bookmark, a pruned run and a commit whose CI never reported
  # are ordinary ways for a reader to arrive, and it is the caller's job to fall back to what it
  # would have shown anyway — and to disclose that it did.
  def latest_test_run_for_commit(sha)
    return nil if sha.blank?

    test_runs.where(commit_sha: sha).order(created_at: :desc, id: :desc).first
  end

  # The run `run`'s suite figures can honestly be compared against: the newest run on the **same
  # branch**, strictly older than `run` itself. `nil` — never a fallback row — when there is no
  # honest comparison to make.
  #
  # Branch-scoped, and that is the point rather than a refinement. `test_runs` is one interleaved
  # history across every branch CI reports from (the "Recent runs" panel lists it exactly that way,
  # deliberately), so the row immediately before the latest one is routinely a different branch
  # entirely — and a difference taken against it would report a suite-size change no commit ever
  # made. A feature branch that deleted a directory would read as the trunk suite shrinking.
  #
  # A nil `branch` returns nil rather than matching `branch IS NULL`. `Ingest::Payload` writes
  # `.presence` and validates a missing branch as acceptable, so anonymous runs are an ordinary
  # live state — and `WHERE branch IS NULL` would pool every one of them, from every branch and
  # every machine, into a single fictional history. "SpecGuard does not know where this run came
  # from" is not a branch.
  #
  # "Older than `run`" is a row-value comparison over exactly the ordering key `latest_test_run`
  # and `recent_test_runs` sort by, tie-break included — a strict position in that ordering, not a
  # set exclusion. Both halves matter and they break differently. A bare `created_at <` skips the
  # same-instant predecessor entirely and compares against a run two rows further back, which the
  # Overview shows today. A bare `id != run.id` is asked nothing it can get wrong *by this page*
  # (the controller only ever passes the latest run), but for any earlier run it answers with the
  # NEWER half of a same-instant pair and reports the suite's growth backwards — so the ordering,
  # not the exclusion, is what this says.
  #
  # Takes the run rather than reading `latest_test_run` itself, so a page that has already loaded
  # the latest run pays one query for this and not two.
  def previous_test_run_on_branch(run)
    return nil if run.nil? || run.branch.blank?

    test_runs.where(branch: run.branch)
             .where("(test_runs.created_at, test_runs.id) < (?, ?)", run.created_at, run.id)
             .order(created_at: :desc, id: :desc)
             .first
  end

  # How many runs back the suite-size trajectory reaches.
  #
  # Bounded by ROWS rather than by a date window, the same choice `recent_test_runs` makes and for
  # the same reason: this is a history of *runs*, so thirty rows is thirty rows whether CI reports
  # hourly or twice a month. A date window would silently render an empty chart for a repository
  # whose CI went quiet, which is the one state a chart of growth must not report as "no growth".
  # Thirty rather than ten because ten runs of a busy repository is an afternoon, and the question
  # this answers is what the suite has done over a month.
  TRAJECTORY_LIMIT = 30

  # The hard bound on the branch walk — a SAFETY bound, not a display one.
  #
  # How many branches a reader is *shown* is `RepositoriesHelper::TRAJECTORY_BRANCH_CHOICES`, and
  # the two must not be confused: the walk is name-ordered by construction (it asks the index for
  # the next branch alphabetically), so any bound on it is an ALPHABETICAL bound. Cutting the walk
  # near the display size therefore hands the sort an arbitrary alphabetical prefix — on a
  # repository with sixty `feature/*` branches, the fifty walked are `feature/000`…`feature/049`
  # and `main` is not among them, which is exactly the "list with the trunk missing" that ordering
  # by history exists to prevent, reintroduced one layer lower.
  #
  # So the walk is bounded where a repository's BRANCH cardinality stops being human-scale rather
  # than where a row of links stops fitting, and inside that bound the walk is COMPLETE — which is
  # what makes "most history first" a property of every branch and not of a prefix. The cost is
  # O(branches) and pays nothing for history: measured on a 46,000-run repository holding 2,001
  # branches, walking a full five hundred of them costs 5.3ms against 8.2ms for the
  # `SELECT DISTINCT branch` over the same rows — and that DISTINCT returns no counts and no
  # ordering, while its cost follows the run history, which grows without bound, where this one
  # follows the branch count, which does not. The same repository walked over 101 branches costs
  # 1.5ms and over 51 costs 1.4ms, and every scan in the plan is an index-only scan of
  # `index_test_runs_on_repository_id_and_branch_and_created_at`; the bound only bites a repository
  # that genuinely has this many branches.
  #
  # `branch_histories` returning at least this many rows is how it says the walk stopped rather than
  # finished — see `RepositoriesHelper#trajectory_hidden_branches_sentence`, which stops claiming
  # the ordering spans every branch once it did.
  BRANCH_HISTORY_LIMIT = 500

  # One branch that has runs, and how much history it holds — a choice the "Suite growth" panel
  # offers.
  #
  # `run_count` is deliberately CAPPED at `TRAJECTORY_LIMIT` (see `branch_histories`), so `capped?`
  # is load-bearing rather than a detail: a capped count must be worded "30+ runs" and never as an
  # exact figure, because the query stopped counting rather than reaching the end of the history.
  BranchHistory = Data.define(:name, :run_count, :capped, :last_run_at) do
    def capped? = capped
  end

  # The suite-size series for `run`'s branch: the last `limit` runs on it, oldest first, each one
  # already primed with the shard count that says how it was assembled.
  #
  # == Why this is not `recent_test_runs`
  #
  # `recent_test_runs` is one interleaved history across every branch CI reports from, and the
  # panel that renders it disclaims being a series in those words ("They are not a series, and the
  # difference between two of these test counts is not a change in the suite"). A trajectory drawn
  # on it would connect a trunk run to a feature branch's run with a line, which is the disclaimer's
  # own counter-example rendered as a fact. So this is branch-scoped, exactly as
  # `previous_test_run_on_branch` is, and a nil branch returns an empty series rather than pooling
  # every anonymous run from every machine into one fictional history.
  #
  # == Why the ordering is spelled this way
  #
  # `(created_at, id) <= (run.created_at, run.id)` is the same row-value comparison
  # `previous_test_run_on_branch` uses, with the same `created_at desc, id desc` tie-break — `<=`
  # rather than `<` only because the anchor run is itself the newest point of its own trajectory.
  # Re-inventing this as a bare `created_at <=` would order a same-instant pair arbitrarily, and a
  # series is where that does the most damage: the Overview shows one subtraction and a reversed
  # pair reads as growth measured backwards, while a chart draws the whole suite jumping up and
  # back down between two runs that were ingested in the same second.
  #
  # DESC + LIMIT then reversed, so the bound keeps the *newest* thirty runs and the caller receives
  # them oldest-first, which is the order a trajectory is read in.
  #
  # == Why the shard counts ride along
  #
  # Every point has to answer `TestRun#assembled_like?` before it may be plotted — a run's
  # `total_specs_count` is the SUM over the shards recorded so far, so an in-flight or cancelled
  # sharded row plotted beside a complete one draws a cliff no commit made. That question routes
  # through `TestRun#shard_count`, which is a memoized per-INSTANCE `pick`: asked of thirty points
  # in a loop it is thirty queries, the same N+1 `RepositoriesController#preload_shard_counts` was
  # written to kill one panel over.
  #
  # So the count is taken in THIS query and each row is primed from it. The whole series costs one
  # query, and it stays one as the history grows and as its runs become sharded.
  #
  # `COUNT(duration_seconds)` rides in the same statement for the same reason, and it is a SECOND
  # question rather than a restatement of the first. `SuiteTrajectory`'s runtime line plots
  # `test_runs.duration_seconds`, which `Ingest::RunRecorder` maintains as the MAX over the shards
  # that REPORTED — so its denominator is `timed_shard_count` and never `shard_count`, and two runs
  # of four shards whose two slowest were cancelled on one side are not a speed-up. That predicate
  # routes through the SAME per-instance `pick`, so a runtime guard added without this column would
  # trade a wrong chart for thirty queries.
  #
  # Primed through `TestRun#preload_timed_shard_count` — a separate call from `preload_shard_count`
  # rather than one taking both, which is the narrowness that seam documents deliberately: a caller
  # must not be able to prime a timing number out of a count that measured no timing.
  #
  # A correlated scalar subquery rather than the `LEFT JOIN … GROUP BY` that first suggests itself,
  # and the difference is not stylistic — it is the difference between O(window) and O(history).
  # Grouping forces Postgres to aggregate EVERY row on the branch before the LIMIT can pick thirty,
  # so it cannot walk the ordering index and stop; measured on a 40,000-run branch it plans a full
  # scan and top-N sort at ~12ms and does not improve when the index below is added. The subquery
  # leaves the ORDER BY/LIMIT alone, so the index walk stops after thirty rows and the count is
  # evaluated for those thirty only (`loops=30` in the plan) — ~0.05ms, and flat as the history
  # grows. `COUNT(*)` on `index_test_run_shards_on_test_run_id` is an index-only scan per point, and
  # the timing count is a second scan of the same index over the same thirty rows in the same
  # statement — a wider SELECT list, never a second round trip.
  #
  # Returns an Array rather than a relation, and that is the point: the rows have been primed, and
  # a relation would invite a caller to chain onto it and quietly re-issue the query without the
  # counts — handing back runs whose `shard_count` costs one query each.
  # `duration_seconds` is qualified and `COUNT(*)` is not, and the asymmetry is deliberate: the
  # column name exists on BOTH `test_runs` and `test_run_shards`, so an unqualified spelling inside
  # this correlated subquery is bound to the inner table by scope precedence rather than by what is
  # written. That binding is correct, and `Repository`'s trajectory spec fails loudly if it ever
  # stops being — but a rule that holds by precedence holds silently, and this one is the
  # denominator of every wall clock the chart draws.
  def suite_size_trajectory(run, limit: TRAJECTORY_LIMIT)
    return [] if run.nil? || run.branch.blank?

    test_runs.where(branch: run.branch)
             .where("(test_runs.created_at, test_runs.id) <= (?, ?)", run.created_at, run.id)
             .order(created_at: :desc, id: :desc)
             .limit(limit)
             .select("test_runs.*, (SELECT COUNT(*) FROM test_run_shards " \
                     "WHERE test_run_shards.test_run_id = test_runs.id) AS shards_recorded, " \
                     "(SELECT COUNT(test_run_shards.duration_seconds) FROM test_run_shards " \
                     "WHERE test_run_shards.test_run_id = test_runs.id) AS shards_timed")
             .to_a
             .reverse
             .each do |point|
               point.preload_shard_count(point["shards_recorded"])
                    .preload_timed_shard_count(point["shards_timed"])
             end
  end

  # A loose index scan ("skip scan") over `index_test_runs_on_repository_id_and_branch_and_created_at`
  # — see `branch_histories` for why the obvious `SELECT DISTINCT branch` is not what this is.
  #
  # The recursive term is the canonical Postgres skip-scan shape: each step asks the index for the
  # single smallest branch strictly greater than the one before it, so the walk costs one index
  # descent PER BRANCH and touches no other row of the history. `branch > walked.branch` also drops
  # `NULL` for free, which is the behaviour this panel wants — an anonymous run names no branch and
  # is not selectable (see `previous_test_run_on_branch`).
  #
  # The LATERAL counts each branch's runs over a window that is bounded the same way the trajectory
  # itself is: `LIMIT :run_probe` rows, walked newest-first off the same index. A bare `COUNT(*)`
  # here would be an index scan of the whole branch — 40,000 entries for a trunk with 40,000 runs,
  # which is precisely the O(history) work the panel's one-query contract exists to refuse. The
  # probe is one row wider than the window so the caller can tell "exactly thirty" from "more than
  # thirty" without ever counting past it, and `MAX(created_at)` over those same rows is the
  # branch's newest run, free, because they are the newest rows.
  #
  # `pinned` is the second arm of the candidate set, and it exists because the walk's bound is
  # alphabetical (see `BRANCH_HISTORY_LIMIT`). A caller may name branches that MUST be offered
  # whatever the walk did — in practice the one the panel is drawing — so that a selector can never
  # be rendered without the branch it is a selector for. `WHERE tail.run_count > 0` is what keeps
  # that from becoming a way to invent a branch: a pinned name with no runs behind it drops out
  # here, the same answer an unrecognised `?branch=` gets everywhere else.
  #
  # `UNION` rather than `UNION ALL` so a pinned branch the walk already found is one row, not two.
  BRANCH_HISTORY_SQL = <<~SQL.squish.freeze
    WITH RECURSIVE walked AS (
      SELECT (SELECT anchor.branch
              FROM test_runs anchor
              WHERE anchor.repository_id = :repository_id AND anchor.branch IS NOT NULL
              ORDER BY anchor.branch
              LIMIT 1) AS branch
      UNION ALL
      SELECT (SELECT next_branch.branch
              FROM test_runs next_branch
              WHERE next_branch.repository_id = :repository_id
                AND next_branch.branch > walked.branch
              ORDER BY next_branch.branch
              LIMIT 1)
      FROM walked
      WHERE walked.branch IS NOT NULL
    ), candidate AS (
      SELECT walk.branch
      FROM (SELECT walked.branch FROM walked WHERE walked.branch IS NOT NULL LIMIT :branch_limit) walk
      UNION
      SELECT pin FROM unnest(ARRAY[:pinned_branches]::text[]) AS pin WHERE pin IS NOT NULL
    )
    SELECT candidate.branch AS branch, tail.run_count, tail.last_run_at
    FROM candidate
    CROSS JOIN LATERAL (
      SELECT COUNT(*) AS run_count, MAX(recent.created_at) AS last_run_at
      FROM (SELECT run.created_at
            FROM test_runs run
            WHERE run.repository_id = :repository_id AND run.branch = candidate.branch
            ORDER BY run.created_at DESC, run.id DESC
            LIMIT :run_probe) recent
    ) tail
    WHERE tail.run_count > 0
  SQL

  private_constant :BRANCH_HISTORY_SQL

  # The branches this repository has runs on, most history first — the choices the "Suite growth"
  # panel offers a reader whose trunk history has been pushed off the page by a feature branch.
  #
  # == Why this is not `SELECT DISTINCT branch`
  #
  # `DISTINCT` over the repository's whole history is O(history): Postgres has no way to answer it
  # without visiting all 40,000 rows of a busy repository, and it gets no help from the branch index
  # because it wants every row's branch, not a position in the ordering. That is the same scan
  # `suite_size_trajectory` documents at length for refusing, reintroduced one line lower down the
  # page. This walks the index instead — one descent per BRANCH, none per run — and both bounds are
  # explicit: at most `branches` branches, and at most `runs + 1` rows counted for each.
  #
  # == Why the counts are capped
  #
  # A count is what the reader needs to see that a dark panel is not the whole story ("main has
  # thirty runs, you are looking at a feature branch's first"), and beyond the trajectory window it
  # answers no question this panel asks — the chart never reaches past `TRAJECTORY_LIMIT` runs. So
  # the count stops there, and `BranchHistory#capped?` carries the fact that it stopped, so a
  # caller can say "30+ runs" rather than inventing an exact figure it did not count to.
  #
  # Ordered by history rather than alphabetically, so the branch a reader is most likely looking
  # for is first and stays first when a caller shows only the head of the list — `main` sorts after
  # a dozen `feature/*` branches, and an alphabetical list truncated for display is a list with the
  # trunk missing. Ties go to the branch pushed to most recently, then to its name so the order is
  # stable between two identically-idle branches.
  #
  # That ordering is a property of the branches the WALK REACHED, and the walk is name-ordered — so
  # its bound has to sit where branch cardinality stops being human-scale rather than where a
  # display list stops fitting, or the sort is handed an alphabetical prefix and the trunk is
  # missing from it after all. `BRANCH_HISTORY_LIMIT` says where that bound is and what it costs;
  # a result at or above it is how a caller learns the walk stopped rather than finished.
  #
  # == Why a caller may pin branches
  #
  # `pinned` names branches that must be offered whatever the walk did — the panel pins the branch
  # it is DRAWING, so the selector can never be rendered without the option it is currently on. A
  # pinned branch with no runs is not invented: it drops out with every other empty one, which is
  # the same answer an unrecognised `?branch=` gets. Pinning the branch drawn covers the branch
  # *asked for* too, and that is not a coincidence — a requested branch that has runs IS the branch
  # drawn (`latest_test_run_on_branch` found it), and one that has none must not appear in a list of
  # branches that have runs.
  def branch_histories(branches: BRANCH_HISTORY_LIMIT, runs: TRAJECTORY_LIMIT, pinned: [])
    rows = self.class.connection.select_all(
      self.class.sanitize_sql_array(
        [BRANCH_HISTORY_SQL,
         { repository_id: id, branch_limit: branches, run_probe: runs + 1,
           pinned_branches: Array(pinned).compact.map(&:to_s).uniq }]
      )
    )

    rows.map { |row|
      counted = row["run_count"].to_i
      last_run_at = row["last_run_at"]
      last_run_at = Time.zone.parse(last_run_at.to_s) unless last_run_at.nil? || last_run_at.is_a?(Time)

      BranchHistory.new(name: row["branch"], run_count: [counted, runs].min,
                        capped: counted > runs, last_run_at: last_run_at)
    }.sort_by { |history| [-history.run_count, -(history.last_run_at&.to_f || 0), history.name] }
  end

  # The tail of the append-only run history, newest first — what the "Recent runs" panel lists.
  #
  # Deliberately the *same* ordering as `latest_test_run` above, tie-break included. The two are
  # read side by side on the repository page (Overview names the latest run, this panel's top row
  # names it again), so an ordering that disagreed by even the id tie-break would print two
  # different commits for the same run on the same screen.
  #
  # Bounded by `limit` rather than paginated: this is a history of *runs*, so ten rows is ten rows
  # whether the suite holds three tests or twenty thousand.
  #
  # == `branch:` — the filter has to be IN this query, not applied to its result
  #
  # Unfiltered, this is the interleaved history across every branch CI reports from, and the panel
  # that renders it disclaims being a series in those words. A caller that wants a series has to
  # narrow it — and narrowing it *afterwards* cannot work, because the bound is already spent. On a
  # repository whose CI reports on every PR, the last ten runs repository-wide are routinely all
  # feature branches, so `recent_test_runs.select { it.branch == "main" }` returns `[]` while `main`
  # holds thirty runs in this same table. The `WHERE` therefore rides along with the `LIMIT`, and
  # `index_test_runs_on_repository_id_and_branch_and_created_at` (db/schema.rb) is the index that
  # makes the narrowed walk stop at `limit` rows rather than scan.
  #
  # `.present?` and not `.nil?`, deliberately, and it is the same guard `suite_size_trajectory` and
  # `previous_test_run_on_branch` make above: a blank branch means "no filter", and must never reach
  # `WHERE branch = ''` or — far worse — `WHERE branch IS NULL`. `branch` is nullable and
  # `Ingest::Payload` writes `.presence`, so anonymous runs are an ordinary live state, and matching
  # NULL would pool every one of them, from every branch and every machine, into a single fictional
  # history. "SpecGuard does not know where this run came from" is not a branch, so it is not
  # selectable here.
  #
  # A branch that never ran returns zero rows rather than falling back to the unfiltered window.
  # That is the honest answer and the only safe one for a caller that asked for a named series:
  # substituting another branch's rows would hand back a growth curve for the wrong branch, with
  # nothing in the result to say so.
  def recent_test_runs(limit: 10, branch: nil)
    scope = test_runs
    scope = scope.where(branch: branch) if branch.present?
    scope.order(created_at: :desc, id: :desc).limit(limit)
  end

  # The canonical form of an `owner/repo` slug, as a value rather than as a callback's side effect.
  #
  # Exposed as a class method because it is a RULE a caller must be able to apply *before* a record
  # exists. `BulkRegistration` de-duplicates a submitted batch, and de-duplicating raw strings would
  # let `acme/api` and `https://github.com/acme/api` through as two candidates for one repository.
  # Returns `nil` for anything that normalises to blank, so a caller can `filter_map` over it.
  def self.normalize_full_name(value)
    value.to_s.strip.delete_prefix("https://github.com/")
         .delete_suffix(".git").delete_suffix("/").presence
  end

  private

  def normalize_full_name
    self.github_full_name = self.class.normalize_full_name(github_full_name)
  end

  def derive_name
    self.name = github_full_name.to_s.split("/").last.presence || name
  end
end
