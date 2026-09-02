# frozen_string_literal: true

class RepositoriesController < ApplicationController
  # How each run's assembly was primed, in one aggregate for the whole set. The Recent-runs panel
  # on `show` primes its rows through `RepositoryDashboard` now (SPGD-1010); the grid's reader is
  # `latest_test_runs` below, and `Api::V1::UserRepositoriesController` primes the same way at its
  # own call site. Shared with `Api::V1::RepositoriesController`, which asks the same question of
  # the same ten rows for the `history` block on `GET /api/v1/repository`.
  include ShardCountPreloading

  # The two grouped reads behind the card's "Deliveries refused" marker — the newest refusal and
  # the newest accepted run, one query each for the whole grid. Shared with
  # `Api::V1::UserRepositoriesController`, which needs the same two timestamps per repository to
  # serve `delivery_health` on `GET /api/v1/repositories`. The verdict itself stays where it has
  # always been, in `RejectedIngests`; this module only fetches.
  include DeliveryHealthLookups

  # THE THREE NARROWING ASKS THE INDEX READS — `?q=`, `?role=` and `?sort=`, on the one surface
  # that renders every repository an account holds side by side and, until them, offered no way
  # to act on that comparison. Each parameter is its own guard for the reason every sibling has one
  # (the argument `RequestedSpecFileParam` makes in full); `RepositoryNarrowing` gathers those three
  # guards WITH the one application of them, and is shared with
  # `Api::V1::UserRepositoriesController`, which reads the same three asks over the same
  # `accessible_by` population for a machine. Sharing the application and not merely the reads is
  # what stops this grid and that list ordering one account two different ways — see the module.
  #
  # All three are read ONCE, in `#index`, and the URL is their only carrier: no session state, no
  # form state, nothing a colleague receiving a pasted link does not also receive. `?q=` is a
  # case-insensitive substring on `github_full_name` applied IN SQL inside
  # `Repository.accessible_by` — never a post-load filter, so a repository the viewer cannot see
  # never enters the relation and cannot become probeable for existence by name. `?role=` draws
  # the same line the card badge already draws (`owns_repository?`); `?sort=stale` reorders by
  # last-ingested recency over runs the grid already loads. None of the three may add a query:
  # `?q=` and `?role=` only add predicates to the ONE relation the page was already going to
  # load, and the stale ordering sorts the loaded set in memory (see `index`).
  include RepositoryNarrowing

  # The repositories this user may pick from, straight off GitHub, and the four different things to
  # say when that list cannot be loaded. Shared with `BulkRegistrationsController`, which renders a
  # picker built from the same listing and has to answer the same questions the same way.
  include GithubRepositoryListing
  # The minted-key count behind the Leave dialog's disclosure — see `show`.
  include MintedKeyCounts

  before_action :require_authentication

  # The first five are per-card questions asked by repositories/index, once per repository in the
  # list. The sixth is a per-row question asked by repositories/show, once per API key.
  # `stranded_rotation_time` joins the first five's shape: another per-card question asked by
  # repositories/index, once per repository in the list.
  helper_method :owns_repository?, :key_count_visible?, :api_key_count, :latest_run,
                :rejection_verdict, :former_member?, :stranded_rotation_time

  # The seventh through tenth are the index's NARROWING state, handed to the view so it can echo
  # the reader's own ask back at them — the search field's value, the selects' selected options,
  # the "Clear" affordance — and so the empty state can name what was searched for. The readers
  # are the guards themselves (memoised, malformed-shape-safe), not copies of the raw params: the
  # view never sees a shape it has to defend against, only the ask the guards settled on.
  helper_method :requested_search, :requested_role, :requested_sort, :narrowing_matched_nothing?

  # Everything the viewer can open, through the one seam that defines that set — see
  # `Repository.accessible_by`, which carries the union rule and the reason it stays a relation
  # rather than becoming `owned + shared`.
  #
  # `includes(:user)` because every shared card names its owner. Without it that is one user query
  # per shared card — the same footing `shared_permissions` puts its own per-card question on, so
  # the page costs the same whether the list has one shared card or fifty. It stays HERE and not on
  # the seam: it is this page's per-card concern, and the other reader of that set has no use for it.
  #
  # THE NARROWING ASKS compose onto that relation and onto nothing else, in this order:
  #
  #   accessible_by → ?q= → ?role= → includes/order → ?sort=stale
  #
  # `?q=` and `?role=` narrow INSIDE the relation, chained on `accessible_by` itself, which is the
  # whole security claim of the search: the WHERE is applied by the database to rows the scope
  # already admits, so a repository this viewer cannot see never enters the relation at all — not
  # "enters and is filtered out after loading", and not "answers a probe by name". `accessible_by`
  # hands back a relation precisely so callers can chain their own concerns onto it (its own
  # comment says so); these are this page's.
  #
  # `?q=` is `ILIKE '%…%'` — case-insensitive substring, per the parameter's contract — with the
  # WILDCARD CHARACTERS ESCAPED, and `?role=owned`/`?role=shared` are a predicate and its
  # COMPLEMENT WITHIN the accessible set, so the two asks partition exactly the set the
  # unparameterised page renders. Both are applied by `RepositoryNarrowing#narrow_repositories`,
  # shared with `Api::V1::UserRepositoriesController`; the reasoning for the escape, for the
  # complement, and for why chaining on the relation is a SECURITY claim rather than a
  # convenience all lives there, in one copy.
  #
  # Neither adds a query: they are predicates on the ONE relation the page was already going to
  # load, and everything downstream keys off `@repositories` (the grouped `latest_test_runs`,
  # `last_rejection_times` and `api_key_counts` lookups scope to its ids, so a narrowed set
  # narrows them for free; `shared_permissions` reads the viewer's whole membership set and is
  # unaffected either way — one query before, one query after).
  #
  # `?sort=stale` is applied OVER THE LOADED SET rather than in SQL, deliberately: the cards
  # already materialise every run the ordering needs (`latest_test_runs`, one query for the whole
  # grid whatever it is sorted by), so a SQL spelling would have to re-derive per-repository
  # recency in a join the page then throws away — work the page has already paid for, paid a
  # second time to keep the ORDER BY company. Sorting the loaded Array costs no query and lets the
  # view's iteration keep working unchanged. The map is passed in rather than read per row, which
  # is what lets the API list sort by the same rule against the map IT already holds; the
  # `latest_test_runs` memo is keyed off the relation and is taken here exactly as before.
  def index
    scope = narrow_repositories(Repository.accessible_by(current_user), current_user)
    @repositories = scope.includes(:user).order(:github_full_name)
    @repositories = stale_first(@repositories, latest_test_runs) if requested_sort == "stale"
    @registration_grant_story = registration_grant_story
  end

  def show
    @repository = current_repository(:view)
    # THE PANEL ASSEMBLY IS REPOSITORYDASHBOARD'S (SPGD-1010) — one object in `app/models/`, built
    # the way `RepositoryOverview` and `ApiKeyPartition` were. This action keeps the three things
    # a controller alone can do — resolution (`current_repository`), authorization (the
    # `keys_manage` decision, handed in as a plain boolean, never the policy object) and the flash
    # reads the token reveal needs — and the dashboard assembles everything else, handing each
    # ivar back under the name this action always set it under (the `instance_variable_set` below
    # applies the hand-off), so the view takes zero changes. The dashboard's header states the
    # ivar and query contracts in full; the rule-carrying comments moved with their code.
    RepositoryDashboard.new(
      repository: @repository,
      params: params,
      can_manage_keys: repository_policy.can?(:keys_manage)
    ).assemble(
      revealed_token: flash[:revealed_api_key],
      revealed_token_name: flash[:revealed_api_key_name],
      revealed_token_regenerated: flash[:revealed_api_key_regenerated].present?
    ).each { |name, value| instance_variable_set(name, value) }
    # The minted-key count behind the Leave dialog beside the "Your access" row (SPGD-838), kept
    # in the action under SPGD-1010's own split — it is AUTHORIZATION-shaped viewer state, and
    # authorization is exactly the quarter of the action the dashboard's header leaves here. It
    # goes through `MintedKeyCounts#keys_minted_by`, so the `keys.manage` gate is the reader's,
    # not this call site's: a `view`-only member (and a `members.manage`-only one) is handed `{}`
    # before any `api_keys` query runs and the dialog degrades to the zero-key wording, which is
    # the rule this page already keeps for credential metadata.
    #
    # Skipped for the OWNER, who is never shown the control — `viewer_access` is nil for them in
    # the template — and must not pay the grouped query: this page's query budgets are absolute
    # and pinned, and the owner's must not move for a dialog they cannot see.
    @viewer_keys_minted =
      if repository_policy.can?(:owner)
        0
      else
        keys_minted_by(@repository, [current_user.id]).fetch(current_user.id, 0)
      end
  end

  def new
    @repository = current_user.repositories.new
  end

  def create
    @repository = current_user.repositories.new(repository_params)

    if save_with_verified_ownership(@repository)
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
  #
  # Verified through the same gate as `#create`, and that is the point of the gate existing at all
  # — see `save_with_verified_ownership`. Owner-only was never an ownership check: it says the
  # presser owns the *SpecGuard record*, which is exactly what a squatter has.
  def update
    @repository = current_repository(:owner)
    @repository.assign_attributes(repository_params)

    if save_with_verified_ownership(@repository)
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

  # The `?sort=stale` ordering is `RepositoryNarrowing#stale_first`, shared with
  # `Api::V1::UserRepositoriesController` — one definition of what "stale" means, so the grid and
  # the machine-facing list cannot order the same account two different ways. It is handed
  # `latest_test_runs`, the map this page already resolved in one `DISTINCT ON` for the cards' own
  # size badges and basis sentences, so the ordering re-derives nothing and costs no query.

  # Whether the reader asked to NARROW this page at all: `?q=` or `?role=`, either one. `?sort=`
  # is deliberately excluded — it reorders and cannot empty the set, so an empty set under a
  # bare `?sort=stale` is an empty ACCOUNT and must render the registration empty state, not the
  # no-match one. Used by `narrowing_matched_nothing?` and nothing else.
  def index_narrowing_asked?
    requested_search.present? || requested_role.present?
  end

  # True when the reader narrowed, the narrowed set is EMPTY, and the account nonetheless holds
  # repositories — the one state whose wording the page owes care to. It is what tells the two
  # empty pages apart: this one must name the ask and offer the way back ("No repositories match
  # “api”"), while the account that holds nothing at all keeps the registration invitation it has
  # always had, a sentence that would be false for the reader of the first page.
  #
  # THE ONE QUERY IT MAY COST IS PAID ONLY ON THE PAGE THAT NEEDS IT. The order of the conjuncts
  # is the whole budget: `index_narrowing_asked?` first costs nothing at all and settles the
  # UNPARAMETERISED page — no narrowing, no second query, whatever the grid holds, so the empty
  # account page pays exactly the one EXISTS it always paid. Only a page that narrowed AND came
  # back empty reaches further: `@repositories.empty?` (a free check under `?sort=stale`, an
  # EXISTS otherwise), and then the account-level EXISTS that asks whether anything was filtered
  # OUT at all. A page of N cards never reaches any of it.
  #
  # Memoised with `defined?` because the view asks it from TWO branches (the controls gate and
  # the empty-state gate) and it must cost its query once.
  def narrowing_matched_nothing?
    return @narrowing_matched_nothing if defined?(@narrowing_matched_nothing)

    @narrowing_matched_nothing =
      index_narrowing_asked? && @repositories.empty? && Repository.accessible_by(current_user).exists?
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
  # `MintedKeyCounts#keys_minted_by`; `includes(:created_by_user)` has already loaded the
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
  # "does this person still have access" is a membership question. `MintedKeyCounts#keys_minted_by`
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
  # The premise is "still a live credential", and it is the caller's to satisfy: the keys table
  # feeds this badge from `@api_keys`, which `show` partitions to LIVE keys — a revoked key's
  # creator is never flagged, because the premise is false for it (the row no longer
  # authenticates; see `ApiKey#revoke!`). If a caller ever feeds this method revoked rows, the
  # badge lies.
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
  # `@latest_test_run` presence, and the reason this hands back the run rather than a
  # repository-wide ratio floored at 0.0, which cannot express it.
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
  # The resolution itself — the `DISTINCT ON` and the tie-break that repeats
  # `Repository#latest_test_run`'s exactly, so a card and the page it links to can never name
  # different runs — is `DeliveryHealthLookups#latest_test_runs_for`, shared with
  # `Api::V1::UserRepositoriesController`, which needs the same newest-run timestamp per repository
  # for its own refusal verdict. Scoped there to the ids handed in, so it never scans `test_runs`
  # globally, and it early-returns on an empty page.
  #
  # ⚠️ THE PRIMING IS THIS CALLER'S AND STAYS HERE, which is the whole reason the shared method
  # resolves runs and does not prime them. The card asks each run whether it is `multi_shard?` and
  # what it COST, and both `TestRun#shard_count` and `#machine_seconds` are memoized per-instance
  # reads of one `pick` (`test_run.rb`) — asked in the card loop that is one `test_run_shards` query
  # per card, the same N+1 shape this page has already been cleaned of twice. One grouped aggregate
  # answers all of it for the whole grid in a single round trip, exactly as the Recent-runs table on
  # `show` already does. The machine-facing list (`Api::V1::UserRepositoriesController#index`) now
  # reads the same primed values for its own `latest_run` block and primes them the same way, at its
  # own call site — a reader that never serves the block, like `#update` over there, still pays
  # nothing. The wall clock needs no priming at all: `duration_seconds` is a column on the rows
  # selected. Primed HERE and not in `#index`, so the aggregate is taken only when something
  # actually reads the runs and a page of no repositories still pays nothing.
  def latest_test_runs
    @latest_test_runs ||= latest_test_runs_for(@repositories.map(&:id))
                          .tap { |runs| preload_shard_counts(runs.values) }
  end

  # What one card says about its deliveries being REFUSED — the same object, answering the same two
  # questions, that the connection indicator on `show` reads (`refusing?` and `last_rejection_at`).
  # That symmetry is the point: the grid and the page it links to reach one repository's refusal
  # through one class's API, not through two readings that happen to agree.
  #
  # The verdict is `RejectedIngests`' own and is NOT re-derived here. That class's comment forbids a
  # second inline expression of the rule ("holding the verdict beside the rows it is a verdict about
  # is what stops the headline and the list under it describing different states of the same
  # repository"), and the rule has two `nil` limbs that do not both fall out of a `>` — a repository
  # with no rejection is not refusing, and one with a rejection and NO accepted run ever is the most
  # refusing state there is. So this hands over two timestamps and asks; `RejectedIngests.verdict`
  # is the row-free way in, built for exactly this caller.
  #
  # Both timestamps are already grouped for the whole page: the accepted side is `latest_test_runs`
  # above, which the card is already reading for its size badge, and the refused side is the one
  # aggregate below. So this costs no query per card, and the object it builds holds no rows.
  def rejection_verdict(repository)
    RejectedIngests.verdict(last_rejection_at: last_rejection_times[repository.id],
                            last_accepted_run_at: latest_run(repository)&.created_at)
  end

  # `repository_id => newest refusal time` for every repository on this page, in one query no matter
  # how long the list is — the same shape, and the same reason, as `shared_permissions`,
  # `latest_test_runs` and `api_key_counts`. Asking `RejectedIngests.for` per card would be worse
  # than the usual N+1: that constructor reads `IngestRejection::PANEL_LIMIT + 1` ROWS per
  # repository, and the grid needs no rows at all — only the newest time.
  #
  # The grouped `MAX(occurred_at)` itself is `DeliveryHealthLookups#last_rejection_times_for`, shared
  # with `Api::V1::UserRepositoriesController` — which asks the same question of the same table for
  # the `delivery_health` block on `GET /api/v1/repositories`, and would otherwise carry a second
  # copy of this read free to drift from the grid's. That method carries the argument for the
  # aggregate's shape, the index it is served by, and why the retention rule needs no mention here.
  #
  # Memoized on first call rather than assigned by `#index`, so the aggregate is taken only once a
  # card actually asks and a page of no repositories still pays nothing — the same laziness
  # `latest_test_runs` carries for the same reason, and the empty early return that makes it true
  # lives in the shared method.
  def last_rejection_times
    @last_rejection_times ||= last_rejection_times_for(@repositories.map(&:id))
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

  # `repository_id => key count` for every repository on this page — the same shape, and the same
  # reason, as `shared_permissions` and `latest_test_runs`. Derived from `api_key_rows` below
  # through `ApiKeyPartition` rather than issuing its own grouped COUNT: the rotation state beside
  # it needs the same rows under the same scope, and two reads would hit `api_keys` twice per page
  # render for one answer each. The GROUP BY this used to run is a group-by in Ruby over that one
  # row set — same `{repository_id => count}` answer, still one `api_keys` SELECT for the whole
  # page, still scoped to the ids already on this page so it never counts `api_keys` globally.
  #
  # LIVE keys only (SPGD-804): the badge deep-links to `#api-keys`, and the panel it lands on
  # renders the live partition — a count that included retained revoked rows would advertise "4
  # keys" over a table showing one, the same misreading `MembershipsController#keys_minted_by`
  # was corrected for. The count reads `live_rows.size` off each partition rather than the size of
  # the handed-in rows, so the badge's premise is stated where it is read rather than depending on
  # the load's scope staying narrow.
  #
  # Counted for the whole page even though `key_count_visible?` withholds the badge from a
  # `view`-only member: the gate is on what is *rendered*, not on what is loaded, and narrowing the
  # query to visible ids would put a per-card decision back in front of it for no benefit. Nothing
  # here reaches a viewer the gate has not already admitted.
  def api_key_counts
    @api_key_counts ||= api_key_partitions.transform_values { |partition| partition.live_rows.size }
  end

  # `repository_id => the oldest stranded `rotated_at`` for every repository on this page that
  # reads the way show's rotated branch reads — `nil` for every repository that does not, and
  # therefore renders no marker. The value the card's rotation sentence dates itself from.
  #
  # THE VERDICT IS `ApiKeyPartition#stranded_rotation_time`'s AND IS NOT RE-DERIVED HERE, on the
  # rule the grid already holds for its refusal marker (`rejection_verdict` above): the card and
  # the page it links to must not reach one repository's connection state through two readings that
  # happen to agree. That method carries the whole story — why the trigger is show's branch chain
  # and not the per-key predicate, and why the date is the oldest stranded `rotated_at` and never
  # the newest.
  #
  # `ApiKeyPartition.grouped_by_repository` takes the page's one loaded row set and hands back a
  # partition per repository — the same two-constructor split `RejectedIngests` draws for this
  # grid, and for the same reason: the grid has rows for N repositories and must not build N loads.
  # A repository with no handed-in rows has no entry, which is exactly what both readers below want
  # (`api_key_count` defaults the missing count to 0; a missing rotation time renders no marker).
  def stranded_rotation_time(repository)
    stranded_rotation_times[repository.id]
  end

  def stranded_rotation_times
    @stranded_rotation_times ||= api_key_partitions.transform_values(&:stranded_rotation_time)
  end

  # One partition per repository, built once per render off the single SELECT `api_key_rows`
  # issued. Both per-card `ApiKey` questions — the count above and the rotation age above that —
  # read off these objects, so they cannot disagree about which keys a repository has.
  def api_key_partitions
    @api_key_partitions ||= ApiKeyPartition.grouped_by_repository(api_key_rows)
  end

  # The rows BOTH per-card `ApiKey` questions read — the key count above and the rotation age
  # beside it — loaded once for the whole page and partitioned in Ruby. Consolidation is the point:
  # one `ApiKey.live` SELECT scoped to this page's ids answers the count (a group's size) and the
  # rotation state (the predicate applied per row) together, and the page's `api_keys` budget stays
  # at the single SELECT a grouped COUNT used to cost.
  #
  # Full ROWS rather than an aggregate is precedent on this product, not a new exposure: `show`
  # loads `keys.to_a` before any gate, and only its `:created_by_user` preload is gated on
  # `keys_manage` — `token_digest` is never rendered anywhere, and it is not the token. The gate
  # here is likewise on what is RENDERED: the count is read behind `key_count_visible?` by the
  # view, and the rotation state renders only as a `:warning` badge plus a count-free age sentence
  # — the ungated class the connection stat established, no key name, no count, no hint.
  def api_key_rows
    @api_key_rows ||= begin
      repository_ids = @repositories.map(&:id)

      repository_ids.empty? ? [] : ApiKey.live.where(repository_id: repository_ids).to_a
    end
  end

  def repository_params
    params.expect(repository: [:github_full_name])
  end

  # The single gate every write of `github_full_name` passes through. The gate itself — the
  # `valid?` -> ownership -> `save` order, and why it is a save rather than a `before_action` —
  # now lives in `RepositoryRegistration`, because a second caller with no browser session needs
  # exactly the same gate and must not reimplement it. Read that class for the order and its
  # reasons; what stays here is the WEB tree's answer to "who is asking, and with what evidence".
  #
  # `LiveVerifier` is that answer: this person, this session's GitHub credential, and this
  # request's own read of their installations. The machine surface passes a different verifier and
  # gets the same gate.
  #
  # `sources:` is passed as a LAMBDA rather than as a value, and that is not style. `github_sources`
  # is memoized and lazy precisely so a registration that verifies costs one GitHub round trip
  # rather than two, and so a rename form submitted unchanged costs none at all — see
  # `rename_notice`. Evaluating it here, at construction, would force the read before the gate has
  # decided whether the name is even changing.
  def save_with_verified_ownership(repository)
    registration = RepositoryRegistration.new(repository: repository, verifier: live_verifier)
    saved = registration.save
    # Kept for the view, which offers an install button instead of an error when the fix is
    # installing the App rather than picking something else. `nil` when nothing was asked.
    @github_verdict = registration.verdict
    saved
  end

  def live_verifier
    RepositoryRegistration::LiveVerifier.new(user: current_user,
                                             user_token: github_user_token,
                                             sources: -> { github_sources })
  end

  # The repositories this user may pick from, straight off GitHub. Memoized and lazy — read by the
  # registration and rename forms, and by nothing on the success path, so a registration that
  # verifies costs exactly one GitHub call rather than two.
  #
  # A listing failure is not an error page. The form still renders; it says what went wrong and
  # offers the fix. Nothing on this path is authorization — `save_with_verified_ownership` is the
  # gate, and it asks GitHub again — so a stale or empty list cannot admit anything. See
  # `GithubRepositoryListing`, which holds all of that and is shared with the bulk path.
  #
  # What this controller adds is the verdict from a write it has just ATTEMPTED: a registration
  # refused because the App is not installed must offer the install button, and the listing alone
  # cannot know that happened.
  def github_verdict = @github_verdict

  # WHICH STORY this person's registration grant tells. FIVE outcomes — the four non-nil ones listed
  # in the order the ladder below asks them, and they are readings of ONE verdict rather than four
  # separate bounds. `nil` is last here for readability only: it is not a final rung but the answer
  # at two earlier ones, an unconfigured App above the ladder and a redeeming grant mid-way down:
  #
  #   * `:not_installed` — the App is installed nowhere.
  #   * `:session_expired` — installed, but this session holds no credential to read it with.
  #   * `:never_taken` — credential in hand, and no snapshot has EVER been taken.
  #   * `:lapsed` — a snapshot was taken and has aged past `MAX_AGE`.
  #   * `nil` — there is nothing to say: the grant redeems, or the App is unconfigured.
  #
  # The state `RepositoryRegistration::GrantVerifier` refuses an `sgu_` registration with, asked here
  # so that the page that refusal sends them to can say so and offer the fix.
  #
  # THE SAME EXPRESSION THE GATE USES. `GrantVerifier#verdict_for` opens with `return
  # verdict(:not_granted, name) if @grant.nil? || @grant.stale?`, and this is that line and not a
  # second opinion about it: a page drawing a different bound from the gate would tell somebody
  # their registration access was fine while the API went on refusing them, or the reverse. Absent
  # and stale are ONE verdict there and are one here for the same reason — neither redeems anything.
  #
  # ## One VERDICT, two FACTS — and a landing page owes the reader the FACT
  #
  # The merge is right where `GrantVerifier` does it: that method is answering "may this `sgu_`
  # request register?" at the instant of a refusal, and the answer is no either way. This page is
  # not a refusal, and to a READER the two halves are different facts with different fixes — so the
  # verdict is kept whole and its readings are told apart for what is SAID and OFFERED, not
  # re-bounded. Each of the four names a different missing thing, so each ends in a different fix:
  #
  #   * `:not_installed` — the App is installed nowhere, so there is no installation for a
  #     credential to read and nothing for a picker to take a snapshot OF. Neither fix below
  #     applies: the missing thing is the App itself, and the control offered is
  #     `github_install_button`. Asked ABOVE the grant read rather than beside these branches,
  #     because a picker mints an EMPTY BUT FRESH row for this reader — see the guard's own comment
  #     for why reading it after the grant produces a false all-clear.
  #   * `:lapsed` — a snapshot existed and aged past `MAX_AGE`. A week-old grant frequently sits
  #     beside a week-old session, and nothing on this path has asked (asking is what would cost a
  #     round trip), so the fix is the reconnect the API's own refusal names.
  #   * `:never_taken` — no snapshot has EVER been taken. That is the ordinary state of somebody who
  #     connected the App one redirect ago: `GithubInstallationsController#destination` lands them
  #     here, and a grant is minted nowhere but a picker render, so their FIRST visit is always this
  #     one. Nothing lapsed and nothing is missing from their session. Telling them SpecGuard needs
  #     to check their permissions "again" is false, and sending them to github.com would be a
  #     WORSE fix than the "Register a repository" button already in this page's header — they hold
  #     a live token, and the only thing anybody needs to do is open a picker once.
  #   * `:session_expired` — the App is installed, but this SESSION holds no credential to read it
  #     with. Split out because both branches above tell this reader something FALSE, for one
  #     shared reason: each promises the picker will take a snapshot, and for this reader it cannot.
  #     `InstallationRepositories.sources` answers a blank token with `error: :not_authorized`,
  #     `Sources#complete?` is therefore false, and the grant's own capture method opens with
  #     `return nil unless sources.complete?` — so the picker mints NOTHING and the panel redraws
  #     unchanged, however many times the instruction is followed. It also falsifies the other
  #     branch's reassurance that registering in the browser is unaffected: the picker offers this
  #     reader a reconnect rather than a repository. The credential is the missing thing, so the
  #     reconnect is the whole fix — and after it the picker mints on arrival as it does for anyone.
  #
  # ## Nothing to offer means nothing to say
  #
  # Both stories end in a control, and with the App unconfigured neither control can work —
  # `github_authorize_button` renders `github_app_unconfigured_notice` in place of itself, and the
  # picker cannot reach GitHub either. So the panel is suppressed rather than wrapped around an
  # operator-facing notice a reader can do nothing with; that notice already meets the operator on
  # the connect paths, and it is an alert, which inside this page's alert would nest one in another.
  #
  # ## Read off the grant, never off the listing — this controller makes that easy to get wrong
  #
  # `include GithubRepositoryListing` (above) puts `github_sources`, `github_listing`,
  # `github_listing_error`, `github_authorization_needed?` and `github_installation_needed?` all in
  # scope on this action, and every one of them forces `github_sources`. That would do two things,
  # both unacceptable on this page:
  #
  #   * It CALLS GITHUB — a round trip added to the most-visited page in the product, on every
  #     render, to answer a question one indexed row already answers.
  #   * `github_sources` is the sole site that CAPTURES a grant (see `GithubRegistrationGrant` and
  #     the concern's own comment). Asking it would REPAIR the grant as a side effect of asking, so
  #     the state this page exists to render could never be observed on the page that renders it.
  #
  # ## The CREDENTIAL is asked about before the SNAPSHOT, because it decides whether the fix works
  #
  # Both stories above end by promising a picker render will take a snapshot, and that promise is
  # only keepable while the session holds a token to read GitHub with. Without one,
  # `InstallationRepositories.sources` returns `error: :not_authorized`, `Sources#complete?` is
  # false, and `capture` opens with `return nil unless sources.complete?` — so the picker mints
  # NOTHING and this page redraws unchanged however many times its instruction is followed. So the
  # credential is asked about first: it is the more proximate missing thing, and it is the one whose
  # absence makes the other two branches' advice untrue.
  #
  # ⚠ ASKED AS `github_user_token.nil?` AND DELIBERATELY NOT AS `github_authorization_needed?`. The
  # two name the same idea, and on this controller the cheap one is not the one that would resolve:
  # `GithubRepositoryListing` OVERRIDES that predicate, and the override forces `github_sources` —
  # the round trip and the self-repair this whole method exists to avoid. `github_user_token` is a
  # signed-session read costing no query and no round trip; `github_installed?` is one `EXISTS`
  # against our own table.
  #
  # ⚠ AND ASKED AS ONE TERM, NOT TWO. `GithubUserSession#github_authorization_needed?` pairs the
  # token question with `github_installed?`, and this branch deliberately does NOT: the installation
  # question is settled one rung ABOVE, by the `:not_installed` guard, so by the time this line
  # evaluates an installation is a PRECONDITION rather than an open question and re-asking could not
  # change the outcome. That is the point of the ladder — each rung may assume the rungs above it —
  # and a defensive re-ask would not be belt-and-braces here but a second `EXISTS` on the hot path,
  # quietly contradicting the claim that this page adds no cost it does not need. An earlier
  # revision did carry that second term, back when `:not_installed` did not exist and the reader
  # with no installation fell through to `:never_taken`; the rung above subsumed exactly that
  # population, and the term went inert with it.
  #
  # `has_one :github_registration_grant` is one row on a unique index, and costs one query.
  def registration_grant_story
    return nil unless SpecGuard::GithubApp.configured?

    # ⚠ THE INSTALLATION IS ASKED ABOUT FIRST, AND BEFORE THE GRANT IS EVEN READ. This is the
    # outermost rung of a three-rung ladder — installation, then credential, then snapshot — where
    # each rung is a precondition for the next: there is no credential worth holding for an App that
    # is installed nowhere, and no snapshot worth taking of an installation that does not exist.
    #
    # It sits ABOVE the redemption check below, not beside the branches under it, and that placement
    # is the whole fix rather than an ordering preference. A picker render mints a grant from
    # WHATEVER GitHub answers, and for somebody with no installation GitHub answers *nothing*:
    # `InstallationRepositories.sources` returns `blank_sources(installed: false)` — no error and not
    # truncated — so `Sources#complete?` is TRUE and `capture` writes an EMPTY BUT FRESH row. Read
    # after the grant, this reader would mint that row on their first picker visit, `grant.stale?`
    # would go false, and the panel would VANISH while `POST /api/v1/repositories` went on refusing
    # them — with `:not_in_installation`, a different refusal than any branch here describes. That is
    # a false all-clear rather than a loop: the reader followed the instruction, the warning
    # disappeared, and nothing on the page would ever tell them again. Asking first means the empty
    # row can never be reached as a reason for silence.
    #
    # Their fix is neither of the two below. A credential reads an installation and there is none to
    # read; a picker mints a snapshot of an empty set. The missing thing is the App itself, so the
    # control offered is `github_install_button` — the existing helper for exactly this — and not the
    # reconnect. `github_installed?` is one `EXISTS` against our own table, the same read the branch
    # below already makes, and it costs no GitHub round trip.
    return :not_installed unless current_user.github_installed?

    grant = current_user.github_registration_grant

    # A grant inside the bound redeems, so there is nothing to say — whatever the session holds.
    # This page is about registration access, and theirs has not lapsed.
    return nil unless grant.nil? || grant.stale?

    return :session_expired if github_user_token.nil?
    return :never_taken if grant.nil?

    :lapsed
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
