# frozen_string_literal: true

# A registered GitHub repository — the tenant boundary for everything SpecGuard stores.
# API keys, test runs and spec intents all hang off it.
class Repository < ApplicationRecord
  FULL_NAME_FORMAT = %r{\A[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?/[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?\z}

  # The owner: the account that registered this repository, and the only one that holds every
  # permission implicitly (see RepositoryPolicy#owner?). Anything naming the owner reads through
  # here — never off `github_full_name`. The slug's org segment is a *GitHub* org, not a SpecGuard
  # account, and nothing constrains the two to match: `github_full_name` is permitted free-form and
  # validated only for presence, uniqueness and shape, so any user may register any slug.
  belongs_to :user
  has_many :api_keys, dependent: :destroy
  has_many :test_runs, dependent: :destroy
  has_many :spec_intents, dependent: :destroy
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

  # Share of the suite that carries an @intent annotation — the headline dashboard metric.
  #
  # Sourced from the most recent `TestRun`, not from `spec_intents`. Counting rows here could only
  # ever return 100%: `spec_intents.entity/action/behavior/layer` are all NOT NULL, so an
  # unannotated spec — which by definition has none of them — is not a row ingestion can write.
  # Ingestion therefore *counts* unannotated specs into the run's totals and persists only the
  # annotated ones, which makes the run's own counters the honest denominator.
  def annotated_ratio
    latest_test_run&.annotated_ratio || 0.0
  end

  # Ties broken by id so two runs ingested in the same instant still order deterministically.
  def latest_test_run
    test_runs.order(created_at: :desc, id: :desc).first
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
  # == Why the shard count rides along
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
  # A correlated scalar subquery rather than the `LEFT JOIN … GROUP BY` that first suggests itself,
  # and the difference is not stylistic — it is the difference between O(window) and O(history).
  # Grouping forces Postgres to aggregate EVERY row on the branch before the LIMIT can pick thirty,
  # so it cannot walk the ordering index and stop; measured on a 40,000-run branch it plans a full
  # scan and top-N sort at ~12ms and does not improve when the index below is added. The subquery
  # leaves the ORDER BY/LIMIT alone, so the index walk stops after thirty rows and the count is
  # evaluated for those thirty only (`loops=30` in the plan) — ~0.05ms, and flat as the history
  # grows. `COUNT(*)` on `index_test_run_shards_on_test_run_id` is an index-only scan per point.
  #
  # Returns an Array rather than a relation, and that is the point: the rows have been primed, and
  # a relation would invite a caller to chain onto it and quietly re-issue the query without the
  # count — handing back runs whose `shard_count` costs one query each.
  def suite_size_trajectory(run, limit: TRAJECTORY_LIMIT)
    return [] if run.nil? || run.branch.blank?

    test_runs.where(branch: run.branch)
             .where("(test_runs.created_at, test_runs.id) <= (?, ?)", run.created_at, run.id)
             .order(created_at: :desc, id: :desc)
             .limit(limit)
             .select("test_runs.*, (SELECT COUNT(*) FROM test_run_shards " \
                     "WHERE test_run_shards.test_run_id = test_runs.id) AS shards_recorded")
             .to_a
             .reverse
             .each { |point| point.preload_shard_count(point["shards_recorded"]) }
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
  def recent_test_runs(limit: 10)
    test_runs.order(created_at: :desc, id: :desc).limit(limit)
  end

  private

  def normalize_full_name
    self.github_full_name = github_full_name.to_s.strip.delete_prefix("https://github.com/")
                                            .delete_suffix(".git").delete_suffix("/").presence
  end

  def derive_name
    self.name = github_full_name.to_s.split("/").last.presence || name
  end
end
