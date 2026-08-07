# frozen_string_literal: true

class RepositoriesController < ApplicationController
  # How each Recent-runs row was assembled, in one aggregate for the whole panel. Shared with
  # `Api::V1::RepositoriesController`, which asks the same question of the same ten rows for the
  # `history` block on `GET /api/v1/repository`.
  include ShardCountPreloading

  before_action :require_authentication

  # The first four are per-card questions asked by repositories/index, once per repository in the
  # list. The fifth is a per-row question asked by repositories/show, once per API key.
  helper_method :owns_repository?, :key_count_visible?, :api_key_count, :latest_suite_size, :former_member?

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
    # with its own shard count — see `ShardCountPreloading`. Every reader in the view is `any?` /
    # `each`, so an Array answers them identically.
    #
    # The panel names every row's composition, so without that priming this is ten queries for one
    # column, and it is the kind of N+1 that ships green here: this page's own query-budget example
    # (spec/requests/repositories_spec.rb) is the API-keys one and its fixture holds no runs at all.
    # `spec/requests/repository_runs_spec.rb` is what pins that the count does not move when the
    # rows become sharded.
    @recent_test_runs = preload_shard_counts(@repository.recent_test_runs.to_a)
    # The same branch history the delta above reads one row of, read as a series — what the suite
    # has done over the last thirty runs rather than since the last one. ONE query, and it stays
    # one: the shard count each point needs to answer `TestRun#assembled_like?` is folded into that
    # query and primed onto the rows, so the panel costs the same whether the branch has three runs
    # or thirty and whether they are sharded or not (pinned in
    # spec/requests/repository_suite_trajectory_spec.rb, and as an absolute count around the model
    # call itself in spec/models/repository_spec.rb).
    #
    # Empty — never a query — when there is no run at all or the latest named no branch, which are
    # two of the states the Overview's basis line already distinguishes and which the panel
    # distinguishes again rather than collapsing into one blank chart.
    #
    # Which of these rows may be *plotted* is a separate question from which were loaded, and it is
    # asked by `SuiteTrajectory` rather than here: a run's count is the SUM over the shards recorded
    # so far, so an in-flight or cancelled sharded row drawn beside a complete one is a cliff to a
    # quarter of the suite and back. The view renders the object's own counts, so the caption's
    # plotted/withheld figures cannot drift from the line.
    @suite_trajectory = SuiteTrajectory.new(
      runs: @repository.suite_size_trajectory(@latest_test_run),
      branch: @latest_test_run&.branch
    )
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

  # Suite size for one card, or `nil` when this repository's CI has never reported.
  #
  # `nil` is load-bearing and means *never ingested*, which the card renders as its own state
  # rather than as `0 tests` — a repository CI has never posted a run for must not read identically
  # to one whose suite is genuinely empty. Same distinction the Overview panel on `show` draws on
  # `@latest_test_run` presence, and the reason this is not `Repository#annotated_ratio`, which
  # floors at 0.0 by contract and cannot express it.
  #
  # The figure itself is the run's *whole-suite* count — every spec, annotated or not (see
  # `Ingest::Payload#test_run_attributes`) — so it is already correct on a suite carrying no
  # annotations at all.
  def latest_suite_size(repository)
    run = latest_test_runs[repository.id]
    run && run.total_specs_count.to_i
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
  def latest_test_runs
    @latest_test_runs ||= begin
      repository_ids = @repositories.map(&:id)

      if repository_ids.empty?
        {}
      else
        TestRun.where(repository_id: repository_ids)
               .select("DISTINCT ON (test_runs.repository_id) test_runs.*")
               .order(:repository_id, created_at: :desc, id: :desc)
               .index_by(&:repository_id)
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
