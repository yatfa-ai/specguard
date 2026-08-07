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
