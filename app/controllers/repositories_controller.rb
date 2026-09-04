# frozen_string_literal: true

class RepositoriesController < ApplicationController
  # How each Recent-runs row was assembled, in one aggregate for the whole panel. Shared with
  # `Api::V1::RepositoriesController`, which asks the same question of the same ten rows for the
  # `history` block on `GET /api/v1/repository`.
  include ShardCountPreloading

  # The two grouped reads behind the card's "Deliveries refused" marker — the newest refusal and
  # the newest accepted run, one query each for the whole grid. Shared with
  # `Api::V1::UserRepositoriesController`, which needs the same two timestamps per repository to
  # serve `delivery_health` on `GET /api/v1/repositories`. The verdict itself stays where it has
  # always been, in `RejectedIngests`; this module only fetches.
  include DeliveryHealthLookups

  # `?branch=` read as a branch name for the suite-trajectory panel. Shared with
  # `Api::V1::RepositoriesController`, which reads the same parameter under the same guard to narrow
  # the `history` block on `GET /api/v1/repository`.
  include RequestedBranchParam

  # `?spec_file=` read as a spec file path, for the drill-down under the "Heaviest spec files"
  # panel. Read through a concern rather than inline for the reason `RequestedBranchParam` carries
  # in full: the shapes a query string can legally parse into are not all Strings, and an unguarded
  # `.presence` on one of them is a 500 on a URL anyone can type.
  include RequestedSpecFileParam

  # `?spec_directory=` read as a spec directory path, for the drill-down under the "Heaviest spec
  # directories" panel. Its own concern rather than a widening of the one above, for the reason both
  # of theirs carry in full: one guard answering two parameters makes "which shapes does each
  # tolerate" a single question nobody asked, and this value reaches a SQL equality comparison
  # directly, where a non-String does not raise but answers a different question.
  include RequestedSpecDirectoryParam

  # `?repeated_description=` read as a test description, for the drill-down under the "Descriptions
  # this run recorded more than once" panel. Its own concern rather than a widening of either above,
  # for the reason all three carry in full — and at this grain the `.presence` half of the guard
  # earns its place twice over: `spec_observations.name` is nullable, so an empty ask would become
  # `WHERE name = ''`, a query for a description no row can carry.
  include RequestedRepeatedDescriptionParam

  # `?commit_sha=` read as a commit sha, naming WHICH RUN this page is anchored on. The fifth ask
  # this page reads and the only one that RE-ANCHORS rather than narrows: the four above take the
  # anchor as given — `?branch=` picks a series for one panel, and the three drill-in parameters
  # open one area, one file or one description OF the run `show` had already chosen. This one
  # chooses that run, which is why it is read in exactly one place (the `@latest_test_run`
  # assignment in `show`) and every panel hanging off that ivar re-anchors without reading the
  # parameter at all.
  #
  # The module is INCLUDED and not re-derived, which is what the comment beside
  # `Api::V1::RepositoriesController`'s own include promised would happen: it said this page "offers
  # no run selector, so there is no second reader to share a guard with yet. When one arrives it
  # includes this module rather than re-deriving the guard." This is that reader. The hazard is the
  # same at both surfaces and is argued in full in `RequestedCommitShaParam` — the value reaches a
  # `where(commit_sha: …)` on a plain string column, where an Array does not raise but silently
  # becomes an `IN` list at the position that CHOOSES THE RUN, so every panel on this page would
  # describe whichever of several unrelated commits sorted newest.
  include RequestedCommitShaParam

  # `?unstable_test=` read as a test description, for the drill-in under the "Tests whose outcome
  # changed" panel. Shared with `Api::V1::RepositoriesController`, which reads the same parameter
  # under the same guard to open the same window's sequence on `GET /api/v1/repository`.
  #
  # A NARROWING ask like the drill-in parameters above and not a second re-anchoring one, so it is
  # read under whichever run `?commit_sha=` chose rather than choosing one itself: it opens one row
  # of one panel, and which run the page is anchored on is settled before it is read.
  #
  # Its own concern rather than a widening of `RequestedRepeatedDescriptionParam` even though both
  # are read as a `spec_observations.name`, for the reason the concern itself carries in full: they
  # select different POPULATIONS — that one opens ONE RUN's rows carrying a description, this one
  # opens a WINDOW's — and one module answering both would make a divergence either is free to make
  # a breaking change to the parameter nobody was editing.
  include RequestedUnstableTestParam

  # WHICH PANEL the test above was opened from, read for the "Close test" control and for nothing
  # else. A QUALIFIER of the ask above rather than an ask of its own: it opens no panel and narrows
  # no population, so it is deliberately absent from `RepositoriesHelper#drill_down_path`'s carry
  # set — see the note there. Its own concern for the same reason every sibling has one, and the
  # allow-list that keeps a URL fragment from naming a panel nobody renders is argued in full there.
  include RequestedUnstableTestOriginParam

  # `?limit=` read as an Integer ask for how many rows the two run-grain duration rollups below
  # should list — the first MAGNITUDE ask this page reads, and the only one whose value is bounded
  # by nothing in the data, which is why its guard carries a ceiling no sibling needs. Shared with
  # `RepositoryOverview`, which reads the same parameter under the same guard to widen the same
  # two rollups' blocks on `GET /api/v1/repository`. See `RequestedLimitParam` for the guard's
  # reasoning in full.
  include RequestedLimitParam

  # THE THREE NARROWING ASKS THE INDEX READS — `?q=`, `?role=` and `?sort=`, on the one surface
  # that renders every repository an account holds side by side and, until them, offered no way
  # to act on that comparison. Each is its own concern for the reason every sibling has one (the
  # argument `RequestedSpecFileParam` makes in full): the parameters mean different things, are
  # read only here, and one guard answering several would make "which shapes does each tolerate"
  # a single question nobody asked. What they share is the hazard, and the guard against it is
  # the same two lines in the same order everywhere.
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
  include RequestedSearchParam
  include RequestedRoleParam
  include RequestedSortParam

  # The repositories this user may pick from, straight off GitHub, and the four different things to
  # say when that list cannot be loaded. Shared with `BulkRegistrationsController`, which renders a
  # picker built from the same listing and has to answer the same questions the same way.
  include GithubRepositoryListing

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
  # WILDCARD CHARACTERS ESCAPED, and the escape is not pedantry: `_` is a legal and ordinary part
  # of a repository name (`org/my_repo`), so an unescaped `_` would quietly widen "my_repo" to
  # match `my-repo` and `myxrepo`, answering a substring ask with a pattern match.
  # `sanitize_sql_like` backslash-escapes `%`, `_` and `\`, which is the escape character Postgres
  # `LIKE` already reads by default — no `ESCAPE` clause to keep in step with the helper.
  #
  # `?role=owned` is `user_id = current_user.id`; `?role=shared` is its COMPLEMENT WITHIN the
  # accessible set — `where.not(user_id: …)` chained on the relation, not a second reading of the
  # membership table, so owned-but-also-shared is impossible by construction (the same
  # no-overlap invariant `accessible_by` leans on) and the two asks partition exactly the set the
  # unparameterised page renders.
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
  # view's iteration keep working unchanged. See `stale_first`.
  def index
    scope = Repository.accessible_by(current_user)
    scope = scope.where("github_full_name ILIKE :pattern",
                        pattern: "%#{ActiveRecord::Base.sanitize_sql_like(requested_search)}%") if requested_search
    scope = if requested_role == "owned"
              scope.where(user_id: current_user.id)
            elsif requested_role == "shared"
              scope.where.not(user_id: current_user.id)
            else
              scope
            end
    @repositories = scope.includes(:user).order(:github_full_name)
    @repositories = stale_first(@repositories) if requested_sort == "stale"
    @registration_grant_story = registration_grant_story
  end

  def show
    @repository = current_repository(:view)
    # Loaded with `to_a` because the three figures below are read off it: they are claims about the
    # same set of rows, and deriving them from one loaded collection is what stops them being
    # separate answers to "when did this repository last reach the API" that can disagree.
    #
    # The `created_by_user` preload is bought only by a viewer who will actually render the keys
    # table. That table is the only thing that names the creator of a row
    # (`_api_keys.html.erb:23`), and it is a `keys.manage` surface end to end — for a view-only
    # member it does not render at all, so preloading unconditionally would issue a join and
    # discard it, on the very page whose stated rule (the API keys panel comment in `show.html.erb`)
    # is that credential metadata is gated. Inside the gate the preload is still required: without
    # it, listing keys is one user query per key. Asking costs nothing — `repository_policy` is
    # memoized and already populated by `current_repository` above — and the view asks that same
    # memoized question for `manage_keys`, so the query shape here and the render that consumes it
    # cannot disagree about which viewer this is.
    #
    # PRICED, on one fixture (two keys, two distinct creators), because this load replaces two
    # round trips rather than adding one, and the two viewer classes are owed separate figures:
    #
    #   keys.manage viewer  14 -> 12   drops `maximum(:last_used_at)` AND the `SELECT 1` that
    #                                  `has_api_keys` used to cost on an unloaded relation; the
    #                                  table's own SELECT and its preload are what remain.
    #   view-only member    12 -> 11   drops the same two and adds only the keys SELECT, which it
    #                                  now needs for the connection indicator. The preload is the one
    #                                  it does NOT buy, and skipping it is the whole difference
    #                                  between this and 12 -> 12, i.e. a join fetched and thrown
    #                                  away.
    #
    # Both are pinned: the owner by the absolute page budget in `repositories_spec.rb`, the member
    # by the paired preload guard beside it. Separate guards because from here the paths differ.
    keys = @repository.api_keys.order(created_at: :desc)
    keys = keys.includes(:created_by_user) if repository_policy.can?(:keys_manage)
    all_keys = keys.to_a
    # THE RETIREMENT SPLIT, taken in Ruby off the ONE SELECT above: live keys to everything that
    # behaved as before, retired rows to their own collection. Partitioning here rather than adding
    # a `WHERE revoked_at IS NULL` is what keeps this page on its pinned absolute query budget — a
    # second SELECT for the revoked rows would fail it even where it cost no fresh round trip
    # (query-cache hits are counted) — and it makes the split a decision the page can see rather
    # than a default the reader has to remember. `@api_keys` stays the name every existing reader
    # (the keys table, `has_api_keys`, `former_member?`'s rows) already asks, and every one of those
    # readers is a LIVE-keys question: a revoked row's `last_used_at` describes a credential that
    # no longer exists, its creator no longer holds a live credential, and the wire-up panel must
    # not point CI at a repository with nothing that authenticates. SPGD-804 states each of these
    # sites; none of them may silently change meaning because a row stopped being deleted.
    @api_keys = all_keys.reject(&:revoked?)
    @revoked_api_keys = all_keys.select(&:revoked?)
    # The keys whose `last_used_at` was stamped by a token that no longer exists: rotated, with
    # nothing having authenticated since. `ApiKey#rotated_and_unused?` carries the rule and both of
    # its nil cases. Read by the key list, which must not print an inherited "last used" age, and
    # by the connection indicator in the page header. Read off the LIVE partition: a key that was
    # rotated and THEN revoked is both, and the revocation is the newer and stronger fact — it
    # belongs to the revoked state below, and `rotated_and_unused?` must not fire for it here.
    @rotated_unused_api_keys = @api_keys.select(&:rotated_and_unused?)
    # DID ANYTHING EVER AUTHENTICATE — the newest use across every LIVE key, whichever token stamped
    # it. Restricted to live rows since the retirement split: a revoked key's `last_used_at` is the
    # history of a credential that no longer exists, and letting it answer here would render the
    # "Key rotated, not yet in use" branch over a repository whose every key was revoked and nothing
    # was ever rotated into disuse. `nil` means no live key has ever been used at all, which is the
    # only question this can answer and the one the "Not connected yet" branch asks. It must NOT be
    # read as "the repository is reachable now": a rotation retires a token without touching its
    # use, so this figure outlives the credential that produced it.
    @last_api_request_at = @api_keys.filter_map(&:last_used_at).max
    # THE SAME FIGURE, RESTRICTED TO KEYS WHOSE `last_used_at` STILL DESCRIBES THE TOKEN THEY ARE
    # CARRYING NOW — the one the "Connected" stat may report, because it is the only one whose age
    # belongs to a credential that still exists. `nil` while every key that has ever authenticated
    # has since been rotated and not used, which is exactly the window between a rotation and the
    # replacement reaching CI, and precisely when the stat used to read `Connected` in success tone
    # over a pipeline that had been 401ing since the rotation.
    #
    # Separate from `@last_api_request_at` rather than replacing it, because the panel needs both:
    # the difference between the two is what tells "nothing has ever connected" apart from
    # "something did, with a token that is gone".
    @last_live_api_request_at = (@api_keys - @rotated_unused_api_keys).filter_map(&:last_used_at).max
    # THE RETIRED KEYS THE PLATFORM HAS SEEN BEING PRESENTED — a revoked token arriving and being
    # refused stamps `last_refused_at` on the row it names (`Api::BaseController`'s failure path),
    # and this is the set the connection indicator's revoked state is derived from. Restricted to
    # rows that carry the stamp: a key revoked and never presented again is not a finding, and
    # synthesizing one for it is exactly what the honest-bound rule forbids. The recency of the
    # stamp travels with the row (`last_refused_at`), so the rendered state can date the last
    # observed presentation rather than claim a present tense the data does not carry.
    @presented_revoked_api_keys = @revoked_api_keys.select(&:revoked_and_still_presented?)
    # Every suite figure on the Overview panel is read off this one row — suite size, annotated
    # count, and the difference between them. `nil` is load-bearing and means *never ingested*,
    # which the panel renders as an empty state rather than as `0%`; a repository whose CI has
    # never reported must not look identical to one that reported and genuinely found no
    # annotations. Deliberately the run row itself and not a repository-wide ratio floored at 0.0,
    # which cannot express that difference — a floored figure reads the same either way.
    #
    # WHICH run that is has been a question this page could not be asked until now. It is
    # `?commit_sha=`, the same ask the JSON endpoint (SPGD-544) and the MCP bridge (SPGD-552) have
    # taken since they shipped, and the reason it is worth having here is the one the bridge states
    # about itself: without a run ask, the anchor names the repository's NEWEST run, which may be
    # another branch's, with no error and no signal that you were answered about someone else's
    # commit. On the web there was no ask AND no signal.
    #
    # THREE locals rather than one, because three different questions are asked of them below and
    # collapsing any two of them is a bug this page would ship green.
    #
    # `newest_test_run` — the repository's newest accepted run, unconditionally, whatever was asked.
    # It is what "when did CI last succeed" and "which series is the trajectory drawn on" mean, and
    # neither is a question about the reader's anchor. Read once here rather than re-read at each of
    # those two sites, so the page costs exactly the one indexed `LIMIT 1` it always cost on a
    # default call; it is a plain local and is never reassigned, so unlike the memo below it cannot
    # acquire a re-anchoring parameter later (see `@rejected_ingests`, which is where the API hit
    # this and wrote the rule out).
    #
    # `@run_anchor_request` — the RAW ask, kept whatever it names, on the idiom
    # `@trajectory_branch_request` below already sets for the same shape of ask on this page: a
    # panel can only SAY the fallback happened if the ask survives it, and a stale bookmark, a
    # pruned run and a commit whose CI never reported are all ordinary ways to arrive here.
    #
    # `@run_anchor_run` — the run the ask RESOLVED to, or nil. The disclosure is computed off this
    # rather than by comparing two shas, for the reason `serialized_run_anchor` gives: the choice
    # and the statement about the choice must not be able to come apart.
    #
    # NO 404 and no validation branch, at any of the three. An unknown, blank or malformed sha is
    # not a malformed request — it falls back to the newest run and the page says so.
    newest_test_run = @repository.latest_test_run
    @run_anchor_request = requested_commit_sha
    @run_anchor_run = @run_anchor_request && @repository.latest_test_run_for_commit(@run_anchor_request)
    @latest_test_run = @run_anchor_run || newest_test_run
    # The `?limit=` ask in its raw form, read once for both duration rollups below and carried by
    # every `drill_down_path` link on the page — the same rule `@trajectory_branch_request` and
    # friends follow: a link reproduces what the reader asked for, so widening one panel closes no
    # open drill-in and drops no widening already in the URL. `nil` — no ask — is the common
    # answer, and `rollup_limit` is what turns it into each panel's default constant.
    @limit_request = requested_limit
    # The refused half of the same delivery stream the run above is the accepted half of, and the
    # verdict the page header's connection indicator needs in order to stop being wrong.
    #
    # `@last_api_request_at` above is stamped by `Api::BaseController#authenticate_api_key!` on the
    # way IN, so it moves for a delivery that is then refused for its payload — which is how a
    # repository whose every run was being thrown away rendered `Connected` in success tone with a
    # hint saying the last request was two minutes ago. That column answers "did anything
    # authenticate", and it is the only question it can answer; whether what authenticated was then
    # ACCEPTED is this object's, and the panel now asks both.
    #
    # Handed the latest run's `created_at` rather than looking one up: that run is already loaded
    # directly above for the Overview, and a second read here would be a second answer to "when did
    # CI last succeed" sitting one line from the first. `RejectedIngests` carries the comparison
    # rule and both of its bounds.
    #
    # ⭐ ANCHORED ON `newest_test_run` AND NEVER ON `@latest_test_run`. This is the one non-obvious
    # thing about this block and a later reader must not "simplify" it — the API states the same
    # rule over the same comparison at `RepositoryOverview#rejected_ingests`.
    #
    # That ivar is RE-ANCHORED BY `?commit_sha=`, deliberately, so every run-grain panel describes
    # the named run coherently. Handing it here would compare the newest REFUSAL against an
    # arbitrary pinned OLDER run, so any reader bookmarking an old commit on a perfectly healthy
    # repository would be told their deliveries are being refused. That is the same class of
    # falsehood this block exists to remove, reintroduced by the feature above it.
    #
    # Delivery health is a fact about the repository's DELIVERY STREAM, not about whichever run the
    # reader anchored to, so the accepted side is the true newest accepted run on every request.
    #
    # Loaded unconditionally and NOT gated on `@latest_test_run`, unlike the per-example panels
    # below: a repository that has never had a run accepted is not the empty case here, it is the
    # worst case — every delivery it ever made was refused, and that is precisely when the reader
    # needs the list. One bounded query HERE (`IngestRejection::PANEL_LIMIT`); the retained-window
    # summary the panel states above its rows is a SECOND read that loads lazily off this object
    # (`RejectedIngests#retained_window`), so a zero-refusal page — the overwhelmingly common case —
    # never issues it, and a refusing page pays exactly one grouped query however full the window
    # is. The grid's cards (`rejection_verdict` below) still pay neither, and the JSON API never
    # asks for a window, so both callers are unchanged.
    @rejected_ingests = RejectedIngests.for(@repository, last_accepted_run_at: newest_test_run&.created_at)
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
    # the model, so this stays O(1) no matter how long CI has been reporting.
    #
    # NOT RE-ANCHORED BY `?commit_sha=`, and that is the contract rather than an omission: history
    # is a SERIES and the anchor is a ROW. It shares `latest_test_run`'s ordering by construction,
    # so on a default call the run named on the Overview panel above is always the top row here and
    # the two panels cannot name different commits on the same page. ⭐ THAT IDENTITY IS NOT
    # EXPECTED TO HOLD UNDER AN EXPLICIT ASK: naming an older run makes the Overview's run a row
    # from the middle of this list, or from behind its bound entirely. The API says the same of its
    # own `history` at `serialized_run_anchor`, and on this page the anchor disclosure in the
    # Overview panel plus the `aria-current` row here are what make the difference legible instead
    # of reading as a rendering bug.
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
    # Which branch the "Suite growth" panel below is drawn on, and what else the reader may pick.
    #
    # This page has no branch of record: `latest_test_run` is scoped to the repository and names
    # whichever branch pushed most recently. So on a repository whose CI reports on every PR, the
    # panel re-anchors to a feature branch's FIRST run — one point, nothing to draw — and goes dark
    # for every visitor while the trunk holds a month of comparable history in the same table.
    # `?branch=` is how a reader asks for that history back.
    #
    # Deliberately a SEPARATE anchor from `@latest_test_run`, which `?branch=` leaves exactly as it
    # found it: the Overview's suite size, its delta and every drill-in go on naming the run that
    # ivar holds whatever this parameter says. Only the trajectory moves — so a reader who selects a
    # branch cannot end up reading a headline figure about one run under a chart about another. That
    # separation is what lets the two asks compose: `?branch=` picks the series, `?commit_sha=` picks
    # the row, and neither redefines the other.
    #
    # An absent, blank or unrecognised branch falls back to the repository's newest run and renders
    # exactly what this page rendered before the parameter existed. A deleted branch, a typo and a
    # stale bookmark are all ordinary ways to arrive here. `@trajectory_branch_request` keeps the raw
    # ask so the panel can SAY the fallback happened, rather than quietly drawing a different branch
    # from the one the URL names.
    #
    # The fallback is `newest_test_run` and specifically NOT `@latest_test_run`, for the reason
    # "Recent runs" above is not re-anchored either: this panel draws a SERIES, and `?commit_sha=`
    # names a row. On a default call the two are the same object and this is byte-identical to what
    # it always was; under an explicit ask, re-anchoring here would silently move a thirty-run
    # window onto the pinned run's branch on the strength of a parameter that says nothing about
    # which series to draw. A reader who wants that series asks for it with `?branch=`, which is the
    # ask this panel is built around.
    @trajectory_branch_request = requested_branch
    @trajectory_run = @repository.latest_test_run_on_branch(@trajectory_branch_request) || newest_test_run
    # The choices, each with how much history it holds — ONE bounded query, and specifically not a
    # `SELECT DISTINCT branch` over the whole run history, which is the O(history) scan
    # `Repository#branch_histories` documents at length for refusing.
    #
    # Loaded whether or not a branch was asked for, because the reader who needs it most is the one
    # looking at a dark panel: nothing else on the page would tell them that `main` has thirty runs
    # behind it, and a selector that only appears once you have already selected something is no
    # help to the reader who does not know there is anything to select.
    #
    # The branch being DRAWN is pinned into that list rather than left to the walk to find. The walk
    # is bounded, and its bound is alphabetical (see `Repository::BRANCH_HISTORY_LIMIT`), so past it
    # a selector could render without the option it is currently on — a list of branches the reader
    # is not looking at, with nothing marked current, on a page that is drawing one of them. Pinning
    # the drawn branch covers the branch ASKED for as well: a requested branch that has runs is the
    # branch drawn, and one that has none is not a choice this list may offer.
    @trajectory_branches = @repository.branch_histories(pinned: [@trajectory_run&.branch])
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
    #
    # Held in a local because every panel below that draws on this window reads the SAME rows. Each
    # panel that fetched "the last thirty runs on this branch" for itself would be its own window, with
    # no structural reason to keep agreeing, on a page where they caption each other's branch — and
    # each would be another copy of a query that is already the page's most carefully bounded read.
    trajectory_runs = @repository.suite_size_trajectory(@trajectory_run)
    @suite_trajectory = SuiteTrajectory.new(runs: trajectory_runs, branch: @trajectory_run&.branch)
    # The slowest examples of the run every panel above names, with the coverage the panel states
    # them to. The first read this application has ever made of `spec_observations` — until those
    # rows landed, "which tests are slow" was a question the schema could not answer, and this page
    # said so in as many words.
    #
    # Guarded on there being a run at all, and on nothing else: with no run there is nothing to
    # rank, and the Overview's "No CI run has reported yet" is this page's one statement of that.
    # Whether the run recorded any examples, and whether any of them were timed, are questions the
    # object answers — the panel branches on them rather than the controller, so the figures it
    # prints and the rows it lists come from one read of one run.
    #
    # Two bounded queries, neither growing with the size of the suite: see `SlowestExamples`.
    @slowest_examples = SlowestExamples.for(@latest_test_run) if @latest_test_run
    # The other half of the same question, off the same rows of the same run: not which individual
    # examples were slow but which FILES the wall clock went into. Neither panel derives the other
    # — a ten-row ranking by individual cost cannot surface a file that is heavy because it holds
    # four hundred cheap examples — so they are two reads, side by side, each stating its own basis.
    #
    # Guarded identically, and on nothing else: with no run there is nothing to roll up. Whether
    # the run recorded examples, and whether any of them were timed, are questions the object
    # answers so the panel branches on one read rather than the controller taking a second.
    #
    # ONE query, not growing with the size of the suite: see `SpecFileDurations`.
    @spec_file_durations = SpecFileDurations.for(@latest_test_run, limit: rollup_limit(SpecObservation::HEAVIEST_FILES_LIMIT)) if @latest_test_run
    # One file out of that rollup, opened: not which files the wall clock went into but WHICH
    # EXAMPLES are in the one the reader picked. The rollup is a capped ten and every panel on this
    # page is, so a reader who has found the heavy file has so far found the end of the road — this
    # is the first read in the application that narrows to a single file rather than grouping by
    # one, and the panel above is where its links come from.
    #
    # Guarded on a file having been ASKED for as well as on there being a run, so a page nobody
    # asked a file of issues no query at all — the whole drill-down is off the default page's
    # budget. The ask is the raw parameter and is kept whatever it names: a run that recorded
    # nothing for that path is an ordinary answer (a stale bookmark, a deleted file, a typo) and
    # `SpecFileExamples` names it in an empty state rather than the page erroring or silently
    # rendering nothing.
    #
    # Anchored on `@latest_test_run` — the run every panel above names, and specifically not
    # `@trajectory_run`, which follows `?branch=` and belongs to the "Suite growth" panel alone.
    # The file was picked out of a rollup of the latest run, so its examples must come from that
    # same run or the panel would be answering about rows the reader did not click.
    #
    # ONE query, bounded by the size of the FILE and not of the suite, and none at all without an
    # ask: see `SpecFileExamples`.
    @spec_file_request = requested_spec_file
    if @latest_test_run && @spec_file_request
      @spec_file_examples = SpecFileExamples.for(@latest_test_run, @spec_file_request)
    end
    # The rung above that one, off the same rows of the same run: not which FILES the wall clock
    # went into but which AREAS. Not derivable from the panel above either — a by-file top ten
    # shows ten files, and a directory holding forty files at two seconds each is eighty seconds of
    # the run with none of its rows in that list. Concentration re-concentrates at every rung, so
    # each rung is summed rather than read off the one below it.
    #
    # And specifically not `TestRun#shard_durations`, which rolls the same run up by CI partition:
    # its own comment is explicit that a shard is not a code area.
    #
    # Guarded identically, and on nothing else. ONE query, not growing with the size of the suite:
    # see `SpecDirectoryDurations`.
    @spec_directory_durations = SpecDirectoryDurations.for(@latest_test_run, limit: rollup_limit(SpecObservation::HEAVIEST_DIRECTORIES_LIMIT)) if @latest_test_run
    # The SAME grain as the line above and a different AXIS, which is why it is a second read rather
    # than a column on that one. That rollup ranks areas by WALL CLOCK and its coverage figure is
    # TIMING coverage; this one ranks them by how many of their examples carry no `@intent`. An
    # area of four hundred fast unannotated examples heads this list and appears nowhere near the
    # head of that one, so neither is derivable from the other.
    #
    # The Overview panel at the top of this page already prints the run's annotation debt — a
    # subtraction, `total_specs_count - annotated_specs_count` — and a subtraction is the whole
    # answer it can give: a five-figure count of tests the reader is handed no route to any of. That
    # is a count of tests nobody has annotated, which is not the same as a count of tests SpecGuard
    # holds nothing about: where the run recorded per-example rows, every one of them arrived
    # located by both paths, and named as well whenever its producer sent a description — `name` is
    # nullable and `SpecObservation.description_presence_in` is what counts the rows lacking one.
    # The rows are not implied by the figure, either: that subtraction is re-derived over
    # `test_run_shards`, so a client reporting only totals carries it with no per-example rows at
    # all, and the panel below is what discloses that rather than letting it read as an absence of
    # debt (`#recorded?`). The API has served the ranked, scoped worklist behind that figure since
    # SPGD-591/608/623; this is the same rows on the page the owner actually opens.
    #
    # Guarded identically, and on nothing else — with no run there is nothing to rank, and the
    # Overview's "No CI run has reported yet" is this page's one statement of that. Whether the run
    # recorded per-example rows at all is a question the object answers (`#recorded?`), so the panel
    # branches on one read rather than the controller taking a second.
    #
    # ONE query, not growing with the size of the suite: one grouped aggregate carrying its own
    # `COUNT(*) OVER ()`, capped at `SpecObservation::UNANNOTATED_DIRECTORIES_LIMIT`. Shared verbatim
    # with the API's `unannotated_directories` block, so the two consumers cannot disagree about a
    # directory — see `UnannotatedDirectories`.
    @unannotated_directories = UnannotatedDirectories.for(@latest_test_run) if @latest_test_run
    # The same run's rows at a grain none of the panels above reach: not which FILES or AREAS the
    # wall clock went into, but which DESCRIPTIONS more than one example of the run recorded, and
    # what those examples cost between them. Reachable from nowhere until now — no read in this
    # application groups examples by description outside failures — the flakiness panel groups on
    # `spec_identity_id`, and identity is not a description — so on a green suite
    # nothing grouped examples by description at all (see `SpecObservation.repeated_descriptions_in`).
    #
    # Presented for review and never as a verdict: a shared description is equally a table-driven
    # loop, a shared example group, or the same test written twice, and nothing in these rows
    # decides which. `RepeatedDescriptions` holds that boundary and the honesty figures — the rows
    # excluded for carrying no description, and what share of the summed time was measured — beside
    # the list they describe.
    #
    # Anchored on `@latest_test_run` — the run every panel above names, and specifically not
    # `@trajectory_run`, which follows `?branch=` and belongs to the "Suite growth" panel alone.
    #
    # Guarded identically, and on nothing else. TWO queries, neither growing with the size of the
    # suite: the grouped ranking, and the description-presence counts it must exclude before it can
    # group (see `SpecObservation.description_presence_in` for why those cannot ride the same read).
    @repeated_descriptions = RepeatedDescriptions.for(@latest_test_run) if @latest_test_run
    # ONE of those descriptions, opened: not that eight examples of this run say the same sentence
    # and cost ninety seconds between them, but WHICH eight — what each cost, where each sits, how
    # each ended. The rung the panel above had none of: that ranking's rows dead-ended.
    #
    # And specifically not reachable through `?spec_file=`. The ranking names the group's files and
    # those paths link into the file panel, but that panel lists EVERY example of a file capped at
    # fifty and ranked by duration — a reader following a two-file group through it gets two lists of
    # unrelated rows that need not contain the group's members at all. The narrowing is by
    # DESCRIPTION and exists nowhere else; see `SpecObservation.with_description`.
    #
    # Presented for review and never as a verdict, the boundary the panel above holds and this one
    # inherits: a shared description is equally a table-driven loop, a shared example group, or the
    # same test written twice. These rows are what a reader decides that FROM — three consecutive
    # line numbers in one file read differently from the same sentence at three unrelated sites — and
    # nothing here decides it for them.
    #
    # Guarded on a description having been ASKED for as well as on there being a run, so a page
    # nobody asked a description of issues no query at all. The ask is the guarded parameter and is
    # kept whatever it names: a run that recorded nothing under it is an ordinary answer (a test
    # renamed since, a description edited, a stale bookmark) and `RepeatedDescriptionExamples` names
    # it in an empty state rather than a 404.
    #
    # Anchored on `@latest_test_run` for the reason both drill-downs above are: the description was
    # picked out of a ranking of that run, so its examples must come from that same run or the panel
    # would be answering about rows the reader did not click.
    #
    # ONE query, bounded by the size of one RUN and not of the suite, and none at all without an ask.
    @repeated_description_request = requested_repeated_description
    if @latest_test_run && @repeated_description_request
      @repeated_description_examples =
        RepeatedDescriptionExamples.for(@latest_test_run, @repeated_description_request)
    end
    # One area out of THAT rollup, opened: not which areas the wall clock went into but WHICH SPEC
    # FILES are in the one the reader picked. The middle rung of the drill-in, and the rung that was
    # missing — the by-file rollup above is a capped ten, so the heaviest area on this page is
    # precisely the one whose files are structurally absent from it (see `SpecDirectoryDurations`),
    # and its files could be reached from nowhere. Each file listed here is itself a link into the
    # `?spec_file=` panel above, which closes area → file → example.
    #
    # An EQUALITY narrow at one depth and not a subtree: `spec/models/orders` is its own area here
    # exactly as it is its own row in the rollup. `SpecObservation.files_in_directory` holds the
    # argument, including why a prefix `LIKE` would be a different feature and would want a
    # migration this one does not.
    #
    # Guarded on an area having been ASKED for as well as on there being a run, so a page nobody
    # asked an area of issues no query at all. The ask is the raw parameter and is kept whatever it
    # names: a run that recorded nothing for that path is an ordinary answer (a stale bookmark, a
    # deleted directory, a typo) and `SpecDirectoryFiles` names it in an empty state.
    #
    # Anchored on `@latest_test_run` for the reason the file drill-down above is: the area was
    # picked out of a rollup of that run, so its files must come from that same run or the panel
    # would be answering about rows the reader did not click.
    #
    # ONE query, bounded by the size of the AREA and not of the suite, and none at all without an
    # ask: see `SpecDirectoryFiles`.
    @spec_directory_request = requested_spec_directory
    if @latest_test_run && @spec_directory_request
      @spec_directory_files = SpecDirectoryFiles.for(@latest_test_run, @spec_directory_request)
    end
    # THE LAST RUNG OF THE ANNOTATION LADDER, and the one this page never had: not WHICH AREAS carry
    # the run's annotation debt but WHICH TESTS. The Overview panel prints that debt at run grain as
    # `total_specs_count - annotated_specs_count`; `@unannotated_directories` above ranks the areas
    # it is concentrated in. Neither names a test — which is the gap this closes. Neither is a count
    # of tests SpecGuard holds nothing about, either: an unannotated example this run RECORDED is
    # stored exactly as an annotated one is — located by both paths, carrying whatever its producer
    # reported of description, duration and outcome — and what it lacks is an authored `@intent`.
    # What the subtraction does not promise is that those rows exist at all — a client reporting only
    # totals carries the figure with none of them — which the `@unannotated_directories` block above
    # states in full. Until this, acting on the panel this page had just handed the owner meant
    # leaving the product for `GET /api/v1/repository?unannotated_examples=1&spec_directory=…` with
    # an API key.
    #
    # NO NEW PARAMETER. It rides `?spec_directory=` and `?spec_file=`, the same asks the duration
    # drill-downs above read. One ask opens EVERY panel that reads it, each answering in its own
    # grain over the same area — that is how `drill_down_path` composes asks, and `show.html.erb`
    # states the rule at "Areas that grew or shrank": it is not a collision to be fixed by minting
    # another parameter. Assigned HERE rather than beside `@unannotated_directories`, which is the
    # panel it belongs to topically, because it reads BOTH asks and `@spec_directory_request` is
    # resolved directly above.
    #
    # Guarded on a narrowing having been ASKED for as well as on there being a run, so a page nobody
    # asked an area or a file of issues no query at all — the same guard `SpecFileExamples` carries
    # one axis over. `UnannotatedExamples.for`'s narrowings are OPTIONAL and whole-run is a complete
    # ask on the JSON endpoint; this surface deliberately does not take it. A hundred rows of a
    # twelve-thousand-example run's debt, unasked, on every dashboard load is the Overview's
    # subtraction again at length rather than a worklist, and it would put a per-example read on the
    # budget of every reader who never opened anything.
    #
    # Both narrowings are handed over together and are AND-ed by the read, never ranked: see
    # `SpecObservation.unannotated_in`, where the absence of a precedence rule is argued. Note the
    # signature — `test_run` is positional and the narrowings are keywords.
    #
    # Anchored on `@latest_test_run` for the reason every drill-down above is: the area was picked
    # out of a ranking of that run, so its examples must come from that same run or the panel would
    # be answering about rows the reader did not click.
    #
    # ONE query, bounded by the size of the narrowed slice and capped at
    # `SpecObservation::UNANNOTATED_EXAMPLES_LIMIT`, with the population count riding the same rows
    # as a window — and none at all without an ask: see `UnannotatedExamples`.
    if @latest_test_run && (@spec_file_request || @spec_directory_request)
      @unannotated_examples = UnannotatedExamples.for(@latest_test_run, spec_file: @spec_file_request,
                                                                       spec_directory: @spec_directory_request)
    end
    # The same areas, asked of TWO runs instead of one: not which area carries the time but which
    # area got bigger or smaller since the previous run ON THIS BRANCH. `@previous_test_run` above
    # is that run and is already in memory, so riding it costs nothing and keeps this panel on the
    # one comparison the page is allowed to make — `@recent_test_runs` is one interleaved history
    # across every branch, where two consecutive rows are routinely two different branches.
    #
    # Guarded on both sides existing and on nothing else. Every further condition — did each side
    # measure a suite, were they assembled the same way, did each actually write per-example rows —
    # belongs to `SpecDirectoryGrowth`, which names WHICH of them failed so the panel can say so.
    # Those first three are decided before any query is issued, so a page with nothing to compare
    # asks `spec_observations` nothing at all.
    #
    # ONE query when there is a comparison to make, none when there is not, and neither grows with
    # the size of the suite: see `SpecDirectoryGrowth`.
    if @latest_test_run && @previous_test_run
      @spec_directory_growth = SpecDirectoryGrowth.for(@latest_test_run, @previous_test_run)

      # ONE grain down, for the ONE area the reader asked about: not which areas moved but which
      # FILES of the picked area moved. The panel above discloses that it cannot tell a relocation
      # from a real gain and a real loss — this puts the per-file operands in front of the reader so
      # they can tell, without the application ever pairing an example with another example.
      #
      # Guarded on the same two runs AND on an area having been asked for, so a page nobody asked an
      # area of issues no query at all. The ask is `?spec_directory=` — the SAME parameter the
      # durations drill-down above reads, deliberately not a second one. One ask opens EVERY panel
      # that reads it, each answering in its own grain over the same area. That is how
      # `drill_down_path` composes asks and it is intended — a later reader should not "fix" it by
      # splitting the parameter in two.
      #
      # `@spec_directory_growth` is passed rather than the runs alone: this drill-in inherits that
      # panel's comparability verdict instead of re-deriving it, so it cannot assert a comparison
      # the panel above refuses, and two of that verdict's six states are not derivable at this
      # grain at all. See `SpecDirectoryFileGrowth`.
      #
      # ONE query when there is a comparison to make and an area to make it in, none otherwise, and
      # it is bounded by the size of the AREA rather than of the suite.
      if @spec_directory_request
        @spec_directory_file_growth = SpecDirectoryFileGrowth.for(
          @latest_test_run, @previous_test_run, @spec_directory_request,
          growth: @spec_directory_growth
        )
      end
      # The same two runs and the same areas, ranked by an INDEPENDENT quantity: not which area
      # changed size but which area changed TIME. Neither panel derives the other — an area where
      # somebody made an existing spec slow adds zero examples, so it sorts last on the panel above
      # and falls off its cap entirely, and splitting one slow spec into four fast ones is a gain of
      # three examples and a loss of time. A ranking by one quantity cannot also be a ranking by the
      # other, which is why this is a second read beside that one rather than a column added to it.
      #
      # And specifically not the Overview panel's runtime delta, which is one number for the whole
      # run: `test_runs.duration_seconds` has no area grain at all, so "the run got 90 seconds
      # slower" cannot be asked where. The per-area grain only exists in `spec_observations`.
      #
      # Guarded identically, and on nothing else. Every further condition — did each side measure a
      # suite, were they assembled the same way, did each write per-example rows, did each report
      # any timings — belongs to `SpecDirectoryRuntimeGrowth`, which names WHICH of them failed so
      # the panel can say so. The first three are decided before any query is issued.
      #
      # ONE query when there is a comparison to make, none when there is not, and neither grows
      # with the size of the suite: see `SpecDirectoryRuntimeGrowth`.
      @spec_directory_runtime_growth =
        SpecDirectoryRuntimeGrowth.for(@latest_test_run, @previous_test_run)
    end
    # The first question this page asks that MATCHES A TEST TO ITSELF across runs: which tests
    # changed their outcome over the window the "Suite growth" panel above is already drawn on.
    #
    # Not the first cross-run read — `SpecDirectoryGrowth` directly above compares two runs. But
    # that panel's own comment is explicit that it compares POPULATIONS and matches no tests: it
    # counts rows per area in each run and subtracts two integers, and nothing in it asserts that a
    # given test is the same test. This one does exactly that, by `name` and by nothing else, and
    # everything below follows from it — which is why the panel states the rule in its own caption
    # rather than leaving the reader to infer it.
    #
    # Anchored to `trajectory_runs` and not to `@latest_test_run`, and the difference is the whole
    # point. The panels above answer questions ONE run's rows answer, or questions two runs answer
    # without pairing anything; an outcome that CHANGED is a statement about one test across at
    # least two runs. The window is the trajectory's window, branch and all, because outcomes
    # compared across branches are outcomes of different code, and this page already has a branch
    # of record and a `?branch=` selector rather than needing a second one.
    #
    # The loaded runs are handed over rather than re-fetched, so this panel adds no query for its
    # own window and cannot end up captioning a different one from the chart above it.
    #
    # Guarded on the window having runs at all, and on nothing else. Whether those runs recorded
    # examples, whether two of them reported outcomes, and whether anything in them was unstable
    # are questions the object answers — the panel branches on its predicates, so every figure it
    # prints comes off one set of reads of one window.
    #
    # The ask for ONE of that panel's rows is read here rather than inside the guard, because it is
    # also what every OTHER link on this page carries through (`RepositoriesHelper#drill_down_path`),
    # and a page whose window happens to be empty still has to reproduce the reader's URL rather than
    # silently dropping an ask out of every href on it.
    @unstable_test_request = requested_unstable_test
    # WHICH PANEL that test was opened from, read outside the guard for the same reason the ask
    # above is: the "Close test" control has to reproduce the reader's origin whatever the window
    # turned out to hold. Not in the carry set and not an ask — it qualifies the one above.
    @unstable_test_origin_request = requested_unstable_test_origin
    if trajectory_runs.any?
      @unstable_tests = UnstableTests.for(@repository, trajectory_runs, branch: @trajectory_run&.branch)
      # ONE ROW of that ranking, opened: not which tests changed their outcome but WHAT THIS ONE
      # ACTUALLY DID, run by run and in the window's own order. The rung the flakiness ladder never
      # had, and the end of it — `UnstableTests` is `COUNT`s and `ARRAY_AGG(DISTINCT …)`
      # under `GROUP BY spec_identity_id`, which is what keeps it constant in the size of the suite and is
      # exactly what discards the run axis. A row saying `30 runs, 4 failed, [failed, passed]`
      # describes two windows calling for opposite work: four failures at runs 27–30 is a
      # REGRESSION with a culprit commit to find, and four failures at runs 3, 11, 19 and 26 is
      # FLAKINESS with none. Deciding between those is the panel's whole purpose and the one
      # question it could not answer.
      #
      # THE SAME `trajectory_runs` LOCAL, handed in rather than re-queried, and the model's own
      # "window is HANDED IN" invariant (`UnstableTestRuns`) is sharper here than anywhere else on
      # the page: these rows are read for their POSITION against commits the panels above serialized
      # from the first fetch, so a second fetch would put an off-by-one between the sequence and the
      # commits it is read against — and naming the wrong culprit commit is worse than naming none.
      #
      # `name` is POSITIONAL and there is no `branch:` kwarg, unlike the `UnstableTests.for` call
      # directly above it. The window is already branch-scoped by construction, and the shape of the
      # neighbouring call is not a reason to give this one the same one.
      #
      # Guarded on the ASK and on nothing else — not on `@unstable_tests.comparable?`, deliberately.
      # A window the ranking has nothing to say about is precisely the one where the raw per-run
      # grain is worth having: "no candidates" and "here is what this test actually did" answer
      # different questions, and gating the second on the first would withhold the grain exactly
      # when the aggregate above it went silent. `Api::V1::RepositoriesController` makes this same
      # choice for the same reason.
      #
      # The ask is kept whatever it names: a window that recorded nothing under it is an ordinary
      # answer — the project's identity rule is semantic, so a RENAMED test starts a new history and
      # every bookmark to the old description goes stale by design — and `UnstableTestRuns` names it
      # in an empty state rather than a 404.
      #
      # EXACTLY ONE query when asked and none when not, bounded by ONE DESCRIPTION'S rows over at
      # most `Repository::TRAJECTORY_LIMIT` runs — constant in the size of the suite, not merely
      # sublinear in it: see `SpecObservation.outcome_sequence_in`.
      if @unstable_test_request
        @unstable_test_runs = UnstableTestRuns.for(@repository, trajectory_runs, @unstable_test_request)
      end
      # The area grain of the panels above, asked of the WINDOW the two panels around it are already
      # drawn on: not which area moved since the last push but which area moved across the branch's
      # last thirty runs. The page had "growth over time" (the chart, one number per run, no area
      # grain at all) and "growth by area" (the panel above, exactly one push) and never their
      # intersection — an area gaining four examples a run is nobody's biggest mover on that panel
      # and sorts below its cap thirty times running.
      #
      # Another reader of this same local, for the reason stated where it is taken: every panel that
      # fetched "the last thirty runs on this branch" for itself would be its own window, with no
      # structural reason to keep agreeing, on a page where each captions the others' branch. So the
      # window costs nothing here — it is handed over, not re-fetched.
      #
      # Guarded on the window having runs at all, and on nothing else. WHICH run in it can serve as
      # a baseline, whether the two ends measured a suite, whether they were assembled the same way
      # and whether each wrote per-example rows all belong to `SpecDirectoryWindowGrowth`, which
      # names which condition failed so the panel can say so. Everything but the last is decided
      # from rows already in memory, so a window with nothing to compare asks `spec_observations`
      # nothing at all.
      #
      # ONE query when there is a comparison to make, none when there is not, and neither grows with
      # the size of the suite or with the length of the window: see `SpecDirectoryWindowGrowth`.
      @spec_directory_window_growth =
        SpecDirectoryWindowGrowth.for(trajectory_runs, branch: @trajectory_run&.branch)
      # The WALL CLOCK at the grain the two panels above already speak at, and the one grain this
      # page has never had. "Slowest tests" above is ONE run, and its own comment says why it stays
      # there: `example_id` is positional and not stable across refactors, so a ranking that spanned
      # runs on that key would be pairing rows not known to be the same test. That is a statement
      # about the KEY, and `spec_identity_id` is a different key — semantic, resolved by
      # `Ingest::IdentityResolver`, and stable across a move, a reorder and a reword alike. So this
      # panel asks the question the per-run one declines: is this test chronically slow, or was that
      # one bad run.
      #
      # Another reader of this same local, for the reason stated where it is taken: every panel that
      # fetched "the last thirty runs on this branch" for itself would be its own window, with no
      # structural reason to keep agreeing, on a page where each captions the others' branch. So the
      # window costs nothing here — it is handed over, not re-fetched.
      #
      # Guarded on the window having runs at all, and on nothing else — the same guard its two
      # siblings above take, and for the same reason. Whether the newest run wrote per-example rows,
      # whether any of them have been matched to a durable test yet, and how much of what it wrote
      # carried a timing are all questions `SlowestTests` answers, and it answers them as four named
      # states rather than as one empty list: the panel branches on `#state`, so every figure it
      # prints comes off one set of reads of one window.
      #
      # THREE bounded queries at most and ONE where the newest run has nothing to rank — a gate, a
      # capped candidate step over a single run, and a composition over those candidates only. None
      # of them grows with the size of the suite or with the length of the window: see
      # `SlowestTests`.
      @slowest_tests = SlowestTests.for(@repository, trajectory_runs, branch: @trajectory_run&.branch)
    end
    # Set by ApiKeysController#create and #regenerate, and readable exactly once — see
    # ApiKeysController.
    @revealed_token = flash[:revealed_api_key]
    @revealed_token_name = flash[:revealed_api_key_name]
    # Whether the reveal is a rotation rather than a first minting: same token panel either way,
    # plus the one fact only a rotation carries — an old token just stopped working.
    @revealed_token_regenerated = flash[:revealed_api_key_regenerated].present?
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

  # The limit the two run-grain duration rollups were asked for, resolved against each panel's own
  # default. The `?limit=` ask names a magnitude and no panel, so the DEFAULT is per-call-site —
  # the shipped constants stay the defaults and are not re-tuned, and a nil ask (the common one)
  # must not become `limit: nil`, which ActiveRecord reads as NO limit at all: the opposite of the
  # widening the reader declined. Read through `RequestedLimitParam` like both surfaces of the API,
  # never re-derived here.
  def rollup_limit(default) = @limit_request || default

  # The `?sort=stale` ordering: never-ingested first, then least-recently-ingested first, newest
  # last — the order a reader scanning for CI that has gone quiet wants, which is the only reason
  # to reorder this page at all.
  #
  # APPLIED OVER THE LOADED SET, NOT IN SQL, and the ticket for it names that the worker's call
  # provided the query count does not move. It does not: every `created_at` this reads is on a run
  # `latest_test_runs` already resolved for the whole grid in one DISTINCT ON (the cards read the
  # same rows for their size badges and their basis sentences), so a SQL spelling of the same
  # ordering would re-derive per-repository recency in a join only to throw the join away after
  # the sort. Sorting here loads the relation in the controller rather than in the view — the same
  # single load either way — and `latest_test_runs` memoises, so the cards' own reads of the same
  # runs cost nothing further.
  #
  # THE `nil` LIMB IS FIRST RATHER THAN SORTED AS ZERO, because "never ingested" is not "ingested
  # at the epoch": the card renders it as its own state ("No runs yet"), and the stalest thing on
  # the page is the repository CI has never reached at all. `github_full_name` breaks ties within
  # a limb so the sequence is DETERMINISTIC — a `?sort=stale` URL is shareable, and two readers
  # pasting the same link must see the same cards in the same order — which Ruby's `sort_by` does
  # not promise on its own.
  def stale_first(repositories)
    repositories.sort_by do |repository|
      run = latest_run(repository)
      [run.nil? ? 0 : 1, run&.created_at || Time.zone.at(0), repository.github_full_name]
    end
  end

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
  # `show` already does. The machine-facing list reads `created_at` and nothing else, so lifting the
  # priming with the resolution would have dragged a `test_run_shards` aggregate into a caller that
  # never looks at a single primed value. The wall clock needs no priming at all: `duration_seconds`
  # is a column on the rows selected. Primed HERE and not in `#index`, so the aggregate is taken
  # only when something actually reads the runs and a page of no repositories still pays nothing.
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
  # rather than issuing its own grouped COUNT: the rotation state beside it needs the same rows
  # under the same scope, and two reads would hit `api_keys` twice per page render for one answer
  # each. The GROUP BY this used to run is replaced by a group-by in Ruby over that one row set —
  # same `{repository_id => count}` answer, still one `api_keys` SELECT for the whole page, still
  # scoped to the ids already on this page so it never counts `api_keys` globally.
  #
  # LIVE keys only (SPGD-804): the badge deep-links to `#api-keys`, and the panel it lands on
  # renders the live partition — a count that included retained revoked rows would advertise "4
  # keys" over a table showing one, the same misreading `MembershipsController#keys_minted_by`
  # was corrected for.
  #
  # Counted for the whole page even though `key_count_visible?` withholds the badge from a
  # `view`-only member: the gate is on what is *rendered*, not on what is loaded, and narrowing the
  # query to visible ids would put a per-card decision back in front of it for no benefit. Nothing
  # here reaches a viewer the gate has not already admitted.
  def api_key_counts
    @api_key_counts ||= api_key_rows.group_by(&:repository_id).transform_values(&:size)
  end

  # `repository_id => the oldest stranded `rotated_at`` for every repository on this page that
  # reads the way show's rotated branch reads — `nil` for every repository that does not, and
  # therefore renders no marker. The value the card's rotation sentence dates itself from.
  #
  # THE TRIGGER IS SHOW'S CHAIN, NOT THE ROW PREDICATE. The decision card this ticket was resumed
  # under settled that fork, and this follows it: on `show` the rotated-but-unused state is branch
  # 3 of an exclusive `elsif` chain, reached only when nothing is refusing AND `@last_api_request_at`
  # is present AND `@last_live_api_request_at` is blank — some live key has authenticated, and every
  # token that ever did has since been rotated away, so CI is presenting a credential that no longer
  # exists. `ApiKey#rotated_and_unused?` is the predicate that state is DERIVED from (the model's
  # own word), not the state itself. Keyed on it per row, the card would contradict `show` on a
  # repository whose live key keeps CI connected (the stranded key beside it holds nothing back —
  # `show` says Connected) and on a key rotated before it ever authenticated (`show` says Not
  # connected yet — no token was ever routed through it, so no replacement is hanging). The chain's
  # refusing conjunct is carried by the CARD'S ORDER rather than by suppression: the refusal marker
  # renders first, and a card holding both facts shows both.
  #
  # "Stranded" is still `ApiKey#rotated_and_unused?`'s own verdict, applied per loaded ROW rather
  # than re-derived as SQL. The predicate has two `nil` limbs that go OPPOSITE ways (`rotated_at`
  # nil is never-rotated → false; `last_used_at` nil is rotated before it ever authenticated →
  # TRUE), so a `WHERE rotated_at > last_used_at` spelling here would be a second expression of
  # the rule, free to drift from the one both web surfaces read. Here the limbs enter as GUARDS
  # rather than as badge triggers: the predicate sorts the rows into the stranded set, and the two
  # aggregate questions read `last_used_at` off the sets — the first off all of them, the second
  # off everything but the stranded.
  #
  # LIVE rows only, on the rule `show` states at its own rotation split: a key that was rotated and
  # THEN revoked is both, the revocation is the newer and stronger fact, and the rotated state must
  # not fire for it. `api_key_rows` below is already the live partition, so this answer and the
  # key count describe the same population — a card's count and its rotation marker cannot
  # disagree about which keys a repository has.
  #
  # The OLDEST stranded `rotated_at`, and never the newest: each stranded key satisfies the rule
  # against its own rotation, so the only date true of all of them at once is the oldest — the
  # NEWEST would date a five-day-dead pipeline at one minute whenever a second key was rotated just
  # now. The same choice the connection indicator's own branch makes over the same column.
  def stranded_rotation_time(repository)
    stranded_rotation_times[repository.id]
  end

  def stranded_rotation_times
    @stranded_rotation_times ||= api_key_rows.group_by(&:repository_id)
                                             .transform_values { |rows| stranded_rotation_time_within(rows) }
  end

  # Show's rotated branch, over one repository's loaded rows. The locals mirror the chain's
  # conditions and are named after the instance variables that carry them on `show` — read the
  # three lines beside `repositories_controller#show`'s own guards and the equivalence is the
  # check.
  def stranded_rotation_time_within(rows)
    stranded = rows.select(&:rotated_and_unused?)
    # `@last_api_request_at` — did any LIVE key ever authenticate, with whichever token it carried
    # at the time (a rotation retires a token without touching its use).
    some_authenticated = rows.filter_map(&:last_used_at).max.present?
    # `@last_live_api_request_at` — does any live key's `last_used_at` still describe the token it
    # is carrying NOW; blank means every token that ever authenticated has been rotated away.
    nothing_live = (rows - stranded).filter_map(&:last_used_at).max.blank?

    return nil unless some_authenticated && nothing_live

    # The trigger cannot fire on an empty stranded set: with nothing stranded, `nothing_live` reads
    # the very rows `some_authenticated` does and the two cannot hold at once — so the min runs
    # over a non-empty set, and every stranded row carries a `rotated_at` (the predicate's first
    # limb is exactly that), never a filtered-out nil.
    stranded.filter_map(&:rotated_at).min
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
