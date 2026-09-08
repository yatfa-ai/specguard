# frozen_string_literal: true

# THE REPOSITORIES DASHBOARD'S PANEL ASSEMBLY — every instance variable the
# `repositories/show` view reads, assigned in the order the panels depend on one another, by one
# object instead of one order-sensitive controller action.
#
# == Why this is not (still) the controller
#
# It was, and the action paid for it in collisions: the panels are assembled in one
# order-sensitive region — `show` spanned L179-L892 of `repositories_controller.rb` at the
# extraction point — so every panel feature edited the same contiguous lines of the same file,
# and the file took ~20% of the main-line commits in 45 days with a 63% co-change couple rate
# against `show.html.erb`. The house has answered this shape twice already: `RepositoryOverview`
# (the API's assembly, whose header argues that the controllers differ in resolution and
# authorization alone) and `ApiKeyPartition` (split out of THIS action's keys block by #956).
# This class completes the move for the one layer still monolithic: the assembly itself. No
# `Dashboard`-named object existed in `app/models/` before it.
#
# == What stays in the action
#
# Exactly the three things `RepositoryOverview`'s rule leaves a controller: RESOLUTION
# (`current_repository(:view)`), AUTHORIZATION (the policy's `keys_manage` decision, handed in as
# the plain `can_manage_keys:` boolean — never the policy object), and the flash reads the token
# reveal needs (handed in as plain values). Everything else — every query, every guard, every
# ivar — is assembled here.
#
# == The ivar contract
#
# Every instance variable the view reads keeps its name and its conditional. {#assemble} hands
# the assembled ivars back under the same names and the action sets them on itself, so the 22+
# partials, the helpers and the request-spec suite all read exactly what the action used to set
# directly — the view takes ZERO changes. A guard that skips an assignment still skips the name
# (see {#publish}): unset stays unset, never silently nil.
#
# == The query contract
#
# Identical shapes, frozen at the extraction: no new preloads, none removed, no N+1 introduced,
# and every budget-pinned load stays a single statement visible at the site that pays it — the
# keys SELECT and the `ApiKeyPartition.for(keys.to_a)` split it feeds are the pinned example.
# The comments' load-bearing orderings travel with the code: the anchor chain evaluates in the
# order it always did (`newest_test_run` is evaluated at the position its local held), and the
# trajectory window is fetched once and handed to every panel that reads it, never re-fetched.
#
# The rule-carrying comments travel with the code they govern — the anchors, the load-bearing
# nils, the pinned page budgets, the collapse warning ("a bug this page would ship green"), the
# retirement split. They are the product's memory; read them before simplifying any line below.
class RepositoryDashboard
  # The modules the assembled panels read through — the same includes the action made, moved
  # with the code that used them, their comments travelling intact.
  #
  # How each Recent-runs row was assembled, in one aggregate for the whole panel. Shared with
  # `Api::V1::RepositoriesController`, which asks the same question of the same ten rows for the
  # `history` block on `GET /api/v1/repository`.
  include ShardCountPreloading

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
  # assignment in the assembly below) and every panel hanging off that ivar re-anchors without
  # reading the parameter at all.
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

  # Never published back to the action by {#publish}: the constructor's inputs — `@repository`,
  # which the action set itself, `@params`, and the `keys_manage` decision — the memoized
  # `requested_*` reads the included `Requested*Param` concerns keep on this object, and the two
  # anchor/window memos (`newest_test_run`, `trajectory_runs`), which the view knew as LOCALS and
  # must not gain ivar visibility it never had. Everything ELSE this object assigns is published:
  # that is the ivar contract. A new assignment in {#assemble} is visible to the view with no
  # second step, exactly as an assignment in the old action was.
  INTERNAL_IVARS = %i[
    @repository @params @can_manage_keys @newest_test_run @trajectory_runs
    @requested_branch @requested_spec_file @requested_spec_directory @requested_commit_sha
    @requested_unstable_test @requested_unstable_test_origin @requested_limit
    @requested_repeated_description
  ].freeze

  attr_reader :repository, :params, :can_manage_keys

  # The three things the action keeps (see the class comment) arrive as plain values — the
  # repository resolved, the authorization decision made, and `params` for the `Requested*Param`
  # concerns above. Nothing here touches the policy, the flash or the session.
  def initialize(repository:, params:, can_manage_keys:)
    @repository = repository
    @params = params
    @can_manage_keys = can_manage_keys
  end

  # The assembly, in the order the panels depend on one another. The keyword arguments are the
  # flash-derived values the action reads; the return value is the ivar hand-off — a hash keyed
  # by FULL instance-variable name, ready for `instance_variable_set` at the call site.
  def assemble(revealed_token:, revealed_token_name:, revealed_token_regenerated:)
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
    # it, listing keys is one user query per key. Asking costs nothing — the decision is resolved
    # once in the action, off the same memoized `repository_policy` `current_repository` populated,
    # and handed in here as the plain `can_manage_keys` this gate reads — and the view asks that
    # same memoized question for `manage_keys`, so the query shape here and the render that
    # consumes it cannot disagree about which viewer this is.
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
    if can_manage_keys
      keys = keys.includes(:created_by_user)
      # THE AGENT CREDENTIAL'S REPOSITORY-SIDE LISTING (SPGD-989) — behind the SAME gate the
      # `sgk_` table renders behind, because it is the same class of information: names, hints,
      # who holds the credential and what it may do are credential metadata, and the member
      # without `keys.manage` gets none of it. `live` first (SPGD-804's rule, applied here on its
      # own table: a revoked row is retained but must not present as a live credential),
      # `covering` for the boundary, `eager_load(:user)` for the owner cell — the same join
      # `authenticate` pays, so the whole listing is ONE statement against `agent_api_keys` and
      # the page's pinned one-SELECT budget for this table holds even when rows exist.
      #
      # ARCHIVED-OWNER rows stay in this listing, marked: `authenticate`'s `merge(User.active)`
      # refuses their tokens, so they are records rather than live hazards — but they are still
      # `revoked_at: nil` rows nobody but this page's viewer can retire (an archived owner cannot
      # sign in to /account to do it), and filtering them here would hide an unrevokable grant
      # from the only people who can revoke it. The badge beside the owner's name says what the
      # listing itself must never say silently: this one does NOT authenticate.
      @agent_api_keys = AgentApiKey.live.covering(@repository)
                                        .eager_load(:user)
                                        .order(created_at: :desc).to_a
      # The name map the revoke confirmation reads — the dialog must name the key's FULL stored
      # set (count + names), and building that copy from one preloaded map keeps it a single
      # SELECT against `repositories` for the whole table, bought only when there is a row to
      # confirm. Names missing from the map are repositories deleted since mint (nothing
      # cascades into the stored array); the confirmation sentence discloses them as such rather
      # than letting the count quietly disagree with the list.
      @agent_key_repositories =
        if @agent_api_keys.any?
          Repository.where(id: @agent_api_keys.flat_map(&:repository_ids).uniq).index_by(&:id)
        end
    end
    # THE RETIREMENT SPLIT, one object off the ONE SELECT above. `ApiKeyPartition` owns the
    # live / revoked / stranded / presented-revoked split and every figure derived from it — the
    # same object the agent-facing credential-health block and the repositories grid read, so all
    # three surfaces answer one key the same way by construction instead of by three hand-typed
    # copies agreeing (two of those copies drifted in lockstep twice in this seam's first six
    # days; see the class comment). The load stays here, in Ruby off the single SELECT the pinned
    # absolute page budget prices — a second SELECT for the revoked rows would fail it even where
    # it cost no fresh round trip (query-cache hits are counted) — and the object is handed the
    # loaded rows rather than the relation, so the budget stays visible at the site that pays it.
    #
    # `@api_keys` stays the name every existing reader (the keys table, `has_api_keys`,
    # `former_member?`'s rows) already asks, and every one of those readers is a LIVE-keys
    # question: a revoked row's `last_used_at` describes a credential that no longer exists, its
    # creator no longer holds a live credential, and the wire-up panel must not point CI at a
    # repository with nothing that authenticates. SPGD-804 states each of these sites; none of
    # them may silently change meaning because a row stopped being deleted. The revocation-outranks-
    # rotation rule behind `@rotated_unused_api_keys` — a key rotated and THEN revoked is revoked,
    # never stranded — lives in the partition's `stranded_rows`, which reads off its live side.
    partition = ApiKeyPartition.for(keys.to_a)
    @api_keys = partition.live_rows
    @revoked_api_keys = partition.revoked_rows
    # The keys whose `last_used_at` was stamped by a token that no longer exists — read by the key
    # list, which must not print an inherited "last used" age, and by the connection indicator's
    # rotated branch in the page header.
    @rotated_unused_api_keys = partition.stranded_rows
    # The two figures the connection indicator branches on, derived from the partition because they
    # are computed FROM it — `@last_api_request_at` is the newest use across the LIVE rows
    # (restricted to live since the retirement split: letting a revoked row answer would render the
    # rotated branch over a repository whose every key was revoked and nothing was ever rotated
    # into disuse), and `@last_live_api_request_at` the same figure restricted to keys whose
    # `last_used_at` still describes the token they carry now. Their nils are load-bearing —
    # "nothing has ever connected" versus "something did, with a token that is gone" — and the
    # partition's own methods carry those readings in full.
    @last_api_request_at = partition.last_api_request_at
    @last_live_api_request_at = partition.last_live_api_request_at
    # THE RETIRED KEYS THE PLATFORM HAS SEEN BEING PRESENTED — a revoked token arriving and being
    # refused stamps `last_refused_at` on the row it names (`Api::BaseController`'s failure path),
    # and this is the set the connection indicator's revoked state is derived from. Restricted to
    # rows that carry the stamp: a key revoked and never presented again is not a finding, and
    # synthesizing one for it is exactly what the honest-bound rule forbids. The recency of the
    # stamp travels with the row (`last_refused_at`), so the rendered state can date the last
    # observed presentation rather than claim a present tense the data does not carry.
    @presented_revoked_api_keys = partition.presented_revoked_rows
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
    # THREE named carriers rather than one, because three different questions are asked of them
    # below and
    # collapsing any two of them is a bug this page would ship green.
    #
    # `newest_test_run` — the repository's newest accepted run, unconditionally, whatever was asked.
    # It is what "when did CI last succeed" and "which series is the trajectory drawn on" mean, and
    # neither is a question about the reader's anchor. Read once here rather than re-read at each of
    # those two sites, so the page costs exactly the one indexed `LIMIT 1` it always cost on a
    # default call; it is a zero-argument memoized method (SPGD-1010's conversion of the local)
    # and is never reassigned, so it cannot acquire a re-anchoring parameter without this rule
    # being edited in plain sight (see `@rejected_ingests`, which is where the API hit this and
    # wrote the rule out).
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
    # Evaluated HERE, at the position the local it replaced held, so the anchor's two reads keep
    # issuing in the order they have always issued in. The method's memo lives below.
    newest_test_run
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
      # THE SAME `trajectory_runs` window (the memoized method below), handed in rather than
      # re-queried, and the model's own "window is HANDED IN" invariant (`UnstableTestRuns`) is
      # sharper here than anywhere else on the page: these rows are read for their POSITION against
      # commits the panels above serialized from the first fetch, so a second fetch would put an
      # off-by-one between the sequence and the commits it is read against — and naming the wrong
      # culprit commit is worse than naming none.
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
      # Another reader of this same window, for the reason stated where it is taken: every panel that
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
      # Another reader of this same window, for the reason stated where it is taken: every panel that
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
    # HANDED IN by the action, which owns the flash reads — see the class comment: flash handling
    # is one of the three things that stay with the controller. The names are the ones the token
    # panel has always read.
    #
    # Set by ApiKeysController#create and #regenerate, and readable exactly once — see
    # ApiKeysController.
    @revealed_token = revealed_token
    @revealed_token_name = revealed_token_name
    # Whether the reveal is a rotation rather than a first minting: same token panel either way,
    # plus the one fact only a rotation carries — an old token just stopped working. The action
    # applies the `.present?` this reads, and hands the boolean in.
    @revealed_token_regenerated = revealed_token_regenerated

    # THE HAND-OFF. Every instance variable assigned above travels back to the action under the
    # name the view has always read — see {#publish} and the ivar contract in the class comment.
    publish
  end

  private

  # The first of the three anchor carriers: the repository's newest accepted run,
  # unconditionally, whatever was asked. A named memoized method rather than a positional local
  # (SPGD-1010) so the DAG is written down instead of implied by line order — its full rule (what
  # it means, why it is never re-anchored) is stated where it is evaluated, at the anchor block
  # in {#assemble}.
  #
  # Memoized with `defined?` rather than `||=` because `nil` is a real answer — a repository
  # whose CI has never reported — and `||=` would re-issue the query on every read of it.
  def newest_test_run
    return @newest_test_run if defined?(@newest_test_run)

    @newest_test_run = @repository.latest_test_run
  end

  # The trajectory window: the SAME rows every panel below reads, held in one named memoized
  # method rather than a positional local (SPGD-1010). Each panel that fetched "the last thirty
  # runs on this branch" for itself would be its own window, with no structural reason to keep
  # agreeing, on a page where they caption each other's branch — and each would be another copy
  # of a query that is already the page's most carefully bounded read. Wrapped as a {RunWindow}
  # built `oldest_first` rather than left a bare array, so the ORDER the `.to_a.reverse` inside
  # `Repository#suite_size_trajectory` produced is carried IN the object: every panel below asks
  # the window for the end it needs (the two anchor sites ask `oldest_first`; the
  # order-indifferent and order-propagating ones read it as handed) instead of each remembering
  # what order this window happens to be in.
  #
  # Memoized with `defined?` rather than `||=` — an empty window is a real answer, not an
  # uninitialized memo (the "Empty — never a query" states at the `@suite_trajectory` assignment
  # in {#assemble}).
  def trajectory_runs
    return @trajectory_runs if defined?(@trajectory_runs)

    @trajectory_runs = RunWindow.oldest_first(@repository.suite_size_trajectory(@trajectory_run))
  end

  # The limit the two run-grain duration rollups were asked for, resolved against each panel's own
  # default. The `?limit=` ask names a magnitude and no panel, so the DEFAULT is per-call-site —
  # the shipped constants stay the defaults and are not re-tuned, and a nil ask (the common one)
  # must not become `limit: nil`, which ActiveRecord reads as NO limit at all: the opposite of the
  # widening the reader declined. Read through `RequestedLimitParam` like both surfaces of the API,
  # never re-derived here. (Moved verbatim from the controller with {#assemble}, whose two
  # `rollup_limit` calls were its only readers.)
  def rollup_limit(default) = @limit_request || default

  # The ivar hand-off: everything this object assigned, keyed by full instance-variable name for
  # `instance_variable_set` at the call site. `instance_variables` lists only what was actually
  # set, so a guard that skipped an assignment skips the name — `@slowest_examples` on a run-less
  # repository is unset on the controller exactly as the action left it, not silently nil. The
  # constructor's inputs, the concerns' `requested_*` memos and the two anchor/window memos stay
  # home (INTERNAL_IVARS above).
  def publish
    (instance_variables - INTERNAL_IVARS).to_h do |ivar|
      [ivar, instance_variable_get(ivar)]
    end
  end
end
