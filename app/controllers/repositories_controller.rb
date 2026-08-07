# frozen_string_literal: true

class RepositoriesController < ApplicationController
  before_action :require_authentication

  # The first four are per-card questions asked by repositories/index, once per repository in the
  # list. The fifth is a per-row question asked by repositories/show, once per API key.
  helper_method :owns_repository?, :key_count_visible?, :api_key_count, :latest_run, :former_member?

  # Everything the viewer can open: what they own, plus what has been shared with them. Kept as one
  # relation rather than `owned + shared`, because concatenating two Arrays orders them
  # owned-then-shared and silently loses the alphabetical order the page is sorted by.
  #
  # No `.distinct`: RepositoryMembership rejects a row for the owner outright
  # (`user_is_not_the_owner`), so the two sides cannot overlap. A defensive uniq here would mask
  # that invariant breaking rather than let it fail loudly.
  #
  # `includes(:user)` because every shared card names its owner. Without it that is one user query
  # per shared card — the same footing `shared_permissions` puts its own per-card question on, so
  # the page costs the same whether the list has one shared card or fifty.
  def index
    @repositories = Repository.where(user_id: current_user.id)
                              .or(Repository.where(id: current_user.repository_memberships.select(:repository_id)))
                              .includes(:user)
                              .order(:github_full_name)
  end

  def show
    @repository = current_repository(:view)
    # `includes` because the table names the creator of every row — without it, listing keys is
    # one user query per key.
    @api_keys = @repository.api_keys.includes(:created_by_user).order(created_at: :desc)
    # The only signal that the repo ever reached the API: the newest use across every key.
    # `nil` means no key has ever authenticated — see the "Connect this repository" panel.
    @last_api_request_at = @repository.api_keys.maximum(:last_used_at)
    # Every suite figure on the Overview panel is read off this one row — suite size, annotated
    # count, and the difference between them. `nil` is load-bearing and means *never ingested*,
    # which the panel renders as an empty state rather than as `0%`; a repository whose CI has
    # never reported must not look identical to one that reported and genuinely found no
    # annotations. Deliberately not `Repository#annotated_ratio`, which cannot express that
    # difference (it floors at 0.0 by contract — see spec/models/repository_spec.rb).
    @latest_test_run = @repository.latest_test_run
    # The one figure on that panel read off *two* rows: the run the suite size is compared against,
    # so a size can be reported as a change and not only as a level. Passed the already-loaded
    # latest run rather than looking it up again, so this costs exactly one query — and none at all
    # when there is nothing to compare (no run, or a run that named no branch: the model returns
    # early, see Repository#previous_test_run_on_branch).
    #
    # `nil` is load-bearing here too, and in three different ways the panel has to keep apart: no
    # run at all, a run that reported no branch, and a run that is the first on its branch. Every
    # one of them is "no delta" and only the first is the never-ingested empty state — so the view
    # decides between them on `@latest_test_run` and `@latest_test_run.branch`, never by treating a
    # nil here as one undifferentiated absence.
    #
    # A row here is a *candidate*, not a comparison. Finding one is necessary and not sufficient:
    # the view still asks whether each side measured a suite at all and whether the two were
    # assembled from the same number of shards, because a run's count is the SUM over the shards
    # recorded so far and differencing an in-flight sharded run against a complete one reports a
    # deletion no commit made. See `TestRun#suite_size_measured?` / `#assembled_like?`.
    @previous_test_run = @repository.previous_test_run_on_branch(@latest_test_run)
    # The tail of that same append-only history for the "Recent runs" panel. Bounded at ten rows by
    # the model, so this stays O(1) no matter how long CI has been reporting. It shares
    # `latest_test_run`'s ordering by construction, so the run named on the Overview panel above is
    # always the top row here — the two panels cannot name different commits on the same page.
    #
    # Materialised with `.to_a` rather than left as a relation, because each row is then primed
    # with its own shard count — see `preload_shard_counts`. Every reader in the view is `any?` /
    # `each`, so an Array answers them identically.
    @recent_test_runs = preload_shard_counts(@repository.recent_test_runs.to_a)
    # Set by ApiKeysController#create and readable exactly once — see ApiKeysController.
    @revealed_token = flash[:revealed_api_key]
    @revealed_token_name = flash[:revealed_api_key_name]
  end

  def new
    @repository = current_user.repositories.new
  end

  def create
    @repository = current_user.repositories.new(repository_params)

    if @repository.save
      redirect_to repository_path(@repository), notice: "Registered #{@repository.github_full_name}."
    else
      render :new, status: :unprocessable_content
    end
  end

  # Rename is owner-only. `github_full_name` is both the repository's identity and the globally
  # unique key, so no membership permission grants it — a member with `view` gets 403 here.
  def edit
    @repository = current_repository(:owner)
  end

  # Renaming is a pure metadata change: api_keys, test_runs and spec_intents are keyed by
  # repository_id, so none of them are touched. That is the whole point — the alternative
  # (Remove + re-register) destroys every key and all telemetry.
  def update
    @repository = current_repository(:owner)

    if @repository.update(repository_params)
      redirect_to repository_path(@repository), notice: rename_notice
    else
      render :edit, status: :unprocessable_content
    end
  end

  # Gated at `:repo_delete`, not `:owner` — a member granted `repo.delete` may destroy the owner's
  # repository, and the flash says so. Both halves of that disclosure live in RepositoriesHelper,
  # beside the confirm dialog they have to agree with.
  def destroy
    repository = current_repository(:repo_delete)
    # Composed BEFORE the row goes away, the same discipline MembershipsController#destroy uses for
    # `revoke_notice`: the non-owner sentence names `repository.user`, and a destroyed record is not
    # something to be asking for its associations. `repository_policy` defaults to the record
    # `current_repository` just resolved and is memoized, so this costs no query.
    notice = helpers.remove_notice(repository, owner: repository_policy.owner?)

    repository.destroy!

    redirect_to repositories_path, notice: notice
  end

  private

  # How each of the Recent-runs rows was assembled, in ONE aggregate for the whole panel.
  #
  # The panel names every row's composition, and every route to that fact on the model —
  # `TestRun#shard_count`, `#multi_shard?`, `#delivery_description` — goes through a memoized
  # per-instance `pick`. Asked inside the row loop, that is ten queries for one column, and it is
  # the kind of N+1 that ships green: the page's existing query-budget example
  # (spec/requests/repositories_spec.rb) is the API-keys one and its fixture holds no runs at all.
  # So the aggregate is taken here, once, and each row is primed from it —
  # `spec/requests/repository_runs_spec.rb` pins that the count does not move when rows become
  # sharded.
  #
  # `group(:test_run_id).count` over `index_test_run_shards_on_test_run_id` (db/schema.rb), keyed by
  # the ten ids already loaded. A run with no shard rows — the whole unsharded corpus, every run
  # that named no `ci_run_id` — is simply absent from the hash and is primed with the zero
  # `TestRun#delivery_description` already words as "reported in one piece".
  #
  # Returns early on an empty list rather than letting `where(test_run_id: [])` issue a `WHERE 1=0`:
  # a repository that has never ingested renders the empty state and should pay nothing for a panel
  # of no rows.
  def preload_shard_counts(runs)
    return runs if runs.empty?

    counts = TestRunShard.where(test_run_id: runs.map(&:id)).group(:test_run_id).count
    runs.each { |run| run.preload_shard_count(counts[run.id]) }
  end

  # `user_id` is already loaded on the record, so this asks nothing of the database.
  def owns_repository?(repository)
    repository.user_id == current_user&.id
  end

  # The index card must not hand a member more key information than repositories#show is willing to
  # give them: that page gates the whole API keys panel — names, hints, last-used — behind
  # `keys.manage`, so a bare count on the card would leak past the same line.
  #
  # Deliberately *not* `repository_policy(repository).can?(:keys_manage)`. That helper memoizes per
  # repository but loads its membership with a `find_by`, so asking it once per card costs one query
  # per shared card. `shared_permissions` below is the same answer in a single query.
  def key_count_visible?(repository)
    return true if owns_repository?(repository)

    Array(shared_permissions[repository.id]).include?(RepositoryMembership::KEYS_MANAGE)
  end

  # `repository_id => permissions` for every membership the viewer holds, loaded in one query and
  # memoized for the request — so the answer above costs the same whether the list has one shared
  # card or fifty.
  def shared_permissions
    @shared_permissions ||= current_user.repository_memberships.pluck(:repository_id, :permissions).to_h
  end

  # The user ids that currently hold access to `@repository`: every membership row, plus the owner
  # (who never has one — see RepositoryMembership#user_is_not_the_owner). One query for the whole
  # table, the same single-query discipline as `shared_permissions` above and as
  # `MembershipsController#keys_minted_by`; `includes(:created_by_user)` has already loaded the
  # creators themselves, so the keys panel asks nothing further per row.
  #
  # `pluck(:user_id)` rather than `@repository.members`, because ids are all the caller compares
  # and loading the User rows would be strictly more work for a strictly worse answer.
  #
  # `nil` — NOT an empty Set — when the viewer may not be told, and that distinction is the whole
  # safety of this method: an empty set reads as "nobody holds access", which would mark *every*
  # creator a former member. `former_member?` fails closed on the nil.
  #
  # The gate is `members.manage`, not the `keys.manage` that gates the panel this feeds, because
  # "does this person still have access" is a membership question. `MembershipsController#keys_minted_by`
  # already ruled on this exact collision in the opposite direction — the members page withholds a
  # key count from a `members.manage`-only viewer — and this is that rule applied symmetrically. A
  # member holding only `keys.manage` therefore sees the creator cell exactly as it read before this
  # existed: told nothing, rather than told less. The owner holds every capability, so their page
  # always shows it.
  #
  # `repository_policy` is memoized and already populated by `current_repository` in `show`, so the
  # gate itself costs no query.
  #
  # Memoized on first call rather than assigned by the action, so the query fires only once a row
  # actually asks: the keys panel is itself gated on `keys.manage`, and a viewer holding
  # `%w[view members.manage]` never renders it. That also keeps `former_member?` self-contained —
  # it answers truthfully on any render path, not only one that remembered to prime an ivar.
  # `defined?` rather than `||=` because `nil` is a meaningful memo here, the same idiom
  # `RepositoryPolicy#membership` uses for the same reason.
  def access_holder_ids
    return @access_holder_ids if defined?(@access_holder_ids)

    @access_holder_ids =
      if repository_policy.can?(:members_manage)
        @repository.repository_memberships.pluck(:user_id).to_set << @repository.user_id
      end
  end

  # A key's creator who no longer holds access — the durable half of the warning SPGD-113 gives at
  # the moment of revocation. Revoking a membership deliberately does not revoke the keys that
  # member minted (see `User has_many :created_api_keys, dependent: :nullify`), so this row is still
  # a live credential and this page is where the owner holds the lever.
  #
  # A `nil` creator is NOT this: it is a legacy key or a deleted account, and it reads "Unknown".
  # Conflating the two would have the page assert that a deleted user was revoked, which is false.
  def former_member?(user)
    return false if user.nil?

    ids = access_holder_ids
    ids.nil? ? false : ids.exclude?(user.id)
  end

  # The run one card reports from, or `nil` when this repository's CI has never reported.
  #
  # `nil` is load-bearing and means *never ingested*, which the card renders as its own state
  # rather than as `0 tests` — a repository CI has never posted a run for must not read identically
  # to one whose suite is genuinely empty. Same distinction the Overview panel on `show` draws on
  # `@latest_test_run` presence, and the reason this is not `Repository#annotated_ratio`, which
  # floors at 0.0 by contract and cannot express it.
  #
  # The whole ROW, deliberately, where this used to hand the view `total_specs_count.to_i` and
  # nothing else. A suite size is not self-describing: `Repository#latest_test_run` returns the
  # newest row whatever its age, and on a sharded run `total_specs_count` is the SUM over the
  # shards recorded SO FAR (`TestRun#suite_size_measured?` carries that argument in full). So a
  # five-month-dead repository and one that reported an hour ago, and a half-delivered run and a
  # complete one, all reduced to the same bare integer — on the one surface that renders N of them
  # side by side, which makes it a comparison surface by construction. The `created_at`, `branch`
  # and primed shard count the card needs to say which is which are all already loaded by
  # `latest_test_runs` below and cost nothing extra; collapsing them here was throwing them away.
  #
  # The figure itself is the run's *whole-suite* count — every spec, annotated or not (see
  # `Ingest::Payload#test_run_attributes`) — so it is already correct on a suite carrying no
  # annotations at all.
  def latest_run(repository)
    latest_test_runs[repository.id]
  end

  # `repository_id => newest TestRun` for every repository on this page, in one query no matter how
  # long the list is — the same shape, and the same reason, as `shared_permissions` above. Asking
  # `Repository#latest_test_run` per card would be an N+1, and the card only just stopped paying a
  # per-repository COUNT for the badge this replaces.
  #
  # `DISTINCT ON` keeps the first row per repository under the ORDER BY, and that ORDER BY repeats
  # `Repository#latest_test_run`'s tie-break exactly (created_at desc, then id desc) so a card and
  # the page it links to can never name different runs. Scoped to the ids already on this page, so
  # it never scans `test_runs` globally.
  #
  # Primed through `preload_shard_counts` at the point the rows are loaded, because the card asks
  # each run whether it is `multi_shard?` and `TestRun#shard_count` is a memoized per-instance
  # `pick` (`test_run.rb`) — asked in the card loop that is one `test_run_shards` query per card,
  # the same N+1 shape this page has already been cleaned of twice. One grouped `COUNT(*)` over
  # `index_test_run_shards_on_test_run_id` answers it for the whole grid, exactly as the Recent-runs
  # table on `show` already does. Primed HERE and not in `#index`, so the aggregate is taken only
  # when something actually reads the runs and a page of no repositories still pays nothing.
  def latest_test_runs
    @latest_test_runs ||= begin
      repository_ids = @repositories.map(&:id)

      if repository_ids.empty?
        {}
      else
        runs = TestRun.where(repository_id: repository_ids)
                      .select("DISTINCT ON (test_runs.repository_id) test_runs.*")
                      .order(:repository_id, created_at: :desc, id: :desc)
                      .index_by(&:repository_id)
        preload_shard_counts(runs.values)
        runs
      end
    end
  end

  # How many API keys one card should report. Reads the grouped count below rather than
  # `repository.api_keys.size`, which — on an association the index does not preload — was one
  # `SELECT COUNT(*) FROM api_keys` per rendered card, two lines above the card's own "never a
  # COUNT per card" rule.
  #
  # `to_i` is load-bearing: a grouped count has no key at all for a repository with no keys, and
  # that card must keep reading `0 keys` exactly as the association call did. The defaulting lives
  # here so the view never has to know the difference.
  def api_key_count(repository)
    api_key_counts[repository.id].to_i
  end

  # `repository_id => key count` for every repository on this page, in one query no matter how long
  # the list is — the same shape, and the same reason, as `shared_permissions` and
  # `latest_test_runs`. Scoped to the ids already on this page, so it never counts `api_keys`
  # globally.
  #
  # Counted for the whole page even though `key_count_visible?` withholds the badge from a
  # `view`-only member: the gate is on what is *rendered*, not on what is loaded, and narrowing the
  # query to visible ids would put a per-card decision back in front of it for no benefit. Nothing
  # here reaches a viewer the gate has not already admitted.
  def api_key_counts
    @api_key_counts ||= begin
      repository_ids = @repositories.map(&:id)

      if repository_ids.empty?
        {}
      else
        ApiKey.where(repository_id: repository_ids).group(:repository_id).count
      end
    end
  end

  def repository_params
    params.expect(repository: [:github_full_name])
  end

  # Submitting the form unchanged is a valid save, so don't claim a rename that didn't happen.
  def rename_notice
    if @repository.saved_change_to_github_full_name?
      "Renamed to #{@repository.github_full_name}."
    else
      "#{@repository.github_full_name} is already up to date."
    end
  end
end
