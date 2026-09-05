# frozen_string_literal: true

# The TWO GROUPED READS a surface listing N repositories needs before it can say, per repository,
# whether that repository's deliveries are being REFUSED — the newest refusal on one side, the
# newest accepted run on the other. One query each for the whole list, whatever N is.
#
# Neither method decides anything. The verdict itself is `RejectedIngests.verdict`'s and stays
# there: `rejected_ingests.rb:80-84` forbids a second inline expression of the ordering rule, and
# the rule has two `nil` limbs that do not both fall out of a bare `>` — a `nil` rejection is not
# refusing, and a `nil` accepted side WITH a rejection present is the most refusing state there is,
# which inverts. So this module hands a caller two timestamps per repository and nothing else; the
# caller asks `RejectedIngests`.
#
# ONE MODULE, TWO BASES, on `ShardCountPreloading`'s stated precedent: this is included into an
# `ActionController::Base` (the repositories card grid) and an `ActionController::API`
# (`GET /api/v1/repositories`). Nothing below touches view helpers or anything an API controller
# lacks, so the differing bases were never an obstacle to sharing — which is why the machine-facing
# list reaches these reads by including this rather than by growing a second copy of them that is
# free to drift from the grid's.
#
# ## Parameterized on an id set, and not on an ivar
#
# The two methods this replaces both opened with `repository_ids = @repositories.map(&:id)`, which
# is a coupling to one controller's ivar rather than to its data.
# `Api::V1::UserRepositoriesController#index` holds its list in a LOCAL, so an argument is the only
# spelling both callers can reach. The memoization stays at each call site too, since what is worth
# caching — and what key it is cached under — is the caller's question, not this module's.
#
# ## The empty early return is load-bearing
#
# `where(repository_id: [])` is a round trip that issues `WHERE 1=0` and can only come back empty.
# An account that can open no repositories, or a grid page with no cards, pays nothing for either
# aggregate — which is a promise both surfaces' specs assert rather than an incidental saving.
module DeliveryHealthLookups
  extend ActiveSupport::Concern

  private

  # `repository_id => newest refusal time`, in one query no matter how long the list is.
  #
  # A grouped `MAX(occurred_at)` and NOT a `DISTINCT ON` like the runs read below, because the two
  # callers of the refused side want different things: nothing that lists repositories renders a
  # refusal's reasons, and selecting rows here would load `details` — the client's verbatim error
  # list, bounded at ~6 KB a row — for every repository in the list to read one column of it.
  # `RejectedIngests.for` is the same mistake one step worse: it reads `PANEL_LIMIT + 1` ROWS per
  # repository, which is the panel's shape on a surface that renders no panel.
  #
  # Served with no migration by `index_ingest_rejections_on_repository_and_recency` on
  # `(repository_id, occurred_at DESC, id DESC)` — the grouped max walks the head of each
  # repository's run of that index. Scoped to the ids handed in, so it never scans
  # `ingest_rejections` globally.
  #
  # The retention rule needs no mention and gets none: `IngestRejection::REPOSITORY_RETENTION_ROWS`
  # bounds the table, so a repository whose refusals have all aged out has no row here and reads as
  # non-refusing — the model's documented "it is reporting what it can still see", arrived at by
  # this method knowing nothing about it.
  def last_rejection_times_for(repository_ids)
    return {} if repository_ids.empty?

    IngestRejection.where(repository_id: repository_ids).group(:repository_id).maximum(:occurred_at)
  end

  # `repository_id => newest TestRun`, in one query no matter how long the list is.
  #
  # `DISTINCT ON` keeps the first row per repository under the ORDER BY, and that ORDER BY repeats
  # `Repository#latest_test_run`'s tie-break exactly (created_at desc, then id desc) — so a listing
  # and the page it links to can never name different runs. Scoped to the ids handed in, so it never
  # scans `test_runs` globally.
  #
  # ⚠️ NO SHARD PRIMING HERE, deliberately. `RepositoriesController#latest_test_runs` and
  # `Api::V1::UserRepositoriesController#index` both follow this read with `preload_shard_counts`,
  # because BOTH now name how each suite was assembled and what it cost — and those are memoized
  # per-instance `pick`s. But that priming is a second aggregate over `test_run_shards`, and a
  # caller that reads only `created_at` — which is all the refusal comparison above needs, and is
  # all `Api::V1::UserRepositoriesController#update`'s verdict asks for — would be paying for a
  # column it never looks at on every request. So the priming stays at the call site that reads
  # primed values, and this module serves the resolution both callers share.
  def latest_test_runs_for(repository_ids)
    return {} if repository_ids.empty?

    TestRun.where(repository_id: repository_ids)
           .select("DISTINCT ON (test_runs.repository_id) test_runs.*")
           .order(:repository_id, created_at: :desc, id: :desc)
           .index_by(&:repository_id)
  end
end
