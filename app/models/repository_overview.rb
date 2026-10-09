# frozen_string_literal: true

# THE REPOSITORY OVERVIEW, ASSEMBLED FROM A REPOSITORY AND AN ASK — everything
# `GET /api/v1/repository` serves except the block describing the credential that asked.
#
# ## Why this is not (still) a controller
#
# It was, and the whole body was read off `current_repository`. That is exactly one credential's
# worth of reach: an `sgk_` repository key names one repository, so a controller that reads the
# key can only ever describe that one. The same figures asked for BY NAME under an `sgu_` user key
# — `GET /api/v1/repositories/:id` — are the same figures, and since SPGD-952 under an `sga_`
# agent key too (bounded by the key's own set). The only thing that differs between the three is
# how the repository was arrived at. So the repository is a PARAMETER here and not a credential,
# and the controllers differ in resolution and authorization alone.
#
# ## What travels, and the one thing that does not
#
# Every run-grain block travels, because every one of them is repository-scoped. The `api_key`
# block does NOT: it describes the credential that made the request, which under a user key is not
# a repository key at all, and there is nothing honest to put in it. It is ABSENT on that route
# rather than served with nulls — see `#body`, which takes the block from the caller that has one.
#
# `credential_health` is the block that looks like it should have gone with it and did not. It
# reports on the repository's keys AS A SET — necessarily keys the caller does not hold — so it is
# repository-scoped like everything else here, and it is arguably worth MORE under a user key,
# where the caller holds none of them.
#
# ## The ask is `params`, and the guards are the shipped ones
#
# The seven drill-in parameters are read through the same `Requested*Param` concerns both
# controllers already include, rather than re-derived here — each of those modules exists
# precisely so a third reader includes it instead of writing an eighth copy of the guard
# (`requested_branch_param.rb` argues this in full). They read `params` and nothing else, which is
# why they compose into a PORO at all: `params` is handed in, exactly like the repository.
#
# Every figure is read off the same rows `repositories#show` renders from
# (`Repository#latest_test_run` and `#recent_test_runs`, which share an ordering tie-break
# included), so the API and the dashboard cannot name different commits for the same repository.
#
# The `latest_run` block is assembled by `LatestRunSerializer`, handed this object as the
# collaborator that holds the ask — see that class for why one serializer serves it at a declared
# depth, and `#serialized_latest_run` below for what this object still owns about it.
class RepositoryOverview
  # How each `history` row was assembled, in one aggregate for the whole window. The same four
  # lines the human Recent-runs panel primes its rows with — see `ShardCountPreloading`, which is
  # one module rather than two copies because nothing in it needs anything an
  # `ActionController::API` lacks.
  include ShardCountPreloading

  # `?branch=` read as a branch name, to narrow `history` below. Shared with
  # `RepositoriesController`, which reads the same parameter under the same guard for the
  # suite-trajectory panel on repositories#show — see `RequestedBranchParam` for the guard's
  # reasoning, which used to sit here in full.
  include RequestedBranchParam

  # `?spec_directory=` read as a spec directory path, to open ONE area of the by-area rollup below.
  # Shared with `RepositoriesController`, which reads the same parameter under the same guard for
  # the drill-in panel on repositories#show — the third sibling of the include above, and included
  # here for the same reason that one is: the guard is the parameter's, not the surface's, and a
  # second copy of it would be a second answer to "which shapes does `?spec_directory=` tolerate".
  #
  # It reaches a SQL equality comparison directly, where a non-String does not raise but answers a
  # different question — see `RequestedSpecDirectoryParam`, which holds that reasoning in full.
  include RequestedSpecDirectoryParam

  # `?spec_file=` read as a spec file path, to open ONE FILE of the area opened above — the rung
  # below `?spec_directory=` and the last one the ladder has. Shared with `RepositoriesController`
  # on the reasoning the include above gives verbatim: the guard is the parameter's, not the
  # surface's, and a second copy of it would be a second answer to "which shapes does `?spec_file=`
  # tolerate".
  #
  # It reaches `where(spec_file_path: …)` directly, which is the harder half of that argument
  # rather than a restatement of it: a non-String does not raise here at all. An Array becomes an
  # `IN` list and answers a question nobody asked, under a `path` naming one file — see
  # `RequestedSpecFileParam`, which holds that reasoning in full.
  include RequestedSpecFileParam

  # `?layer=` read as one declared-layer key, to narrow ONLY the run-grain `slowest_examples` block
  # below to that layer's examples. Shared with `RepositoryDashboard`, which reads the same parameter
  # under the same guard for the "Slowest tests" panel. Independent of every other ask here — it does
  # not narrow `spec_file_examples`, `spec_directory_files`, `unannotated_examples` or
  # `repeated_description_examples`. See `RequestedLayerParam`, which holds the guard's reasoning.
  include RequestedLayerParam

  # `?repeated_description=` read as a test description, to open ONE GROUP of the by-description
  # ranking below — the fourth `Requested*Param` this controller reads and the one the three above
  # cannot stand in for, because it opens a ranking of WHAT tests say rather than of where they
  # live. Shared with `RepositoriesController` on the reasoning the two includes above give
  # verbatim: the guard is the parameter's, not the surface's, and a second copy of it would be a
  # second answer to "which shapes does `?repeated_description=` tolerate".
  #
  # It reaches `where(name: …)` on a plain text column, which is the same silent half of that
  # argument `?spec_file=` makes rather than a restatement of it — an Array does not raise, it
  # becomes an `IN` list and answers about SEVERAL descriptions under a `name` restating one. And
  # the `.presence` half is load-bearing here in a way it is not one rung up:
  # `spec_observations.name` is NULLABLE, so a blank ask would become `WHERE name = ''`, a query for
  # a description no row can carry. See `RequestedRepeatedDescriptionParam`, which holds that
  # reasoning in full.
  include RequestedRepeatedDescriptionParam

  # `?unstable_test=` read as a test description, to open ONE ROW of the cross-run flakiness ranking
  # below — the fifth `Requested*Param` this controller reads, and the first that opens a WINDOW
  # rather than a run.
  #
  # NOT included by `RepositoriesController`, unlike the four above, and that is a fact about the
  # surfaces rather than an omission here: the HTML panel serves no per-run sequence, so there is no
  # second reader to share a guard with yet. When one arrives it includes this module rather than
  # re-deriving the guard, which is the whole reason the guard lives in a module at all.
  #
  # It reaches `where(name: …)` on a plain text column, which is the same silent hazard
  # `?repeated_description=` documents rather than a restatement of it — an Array does not raise, it
  # becomes an `IN` list — and at THIS grain the wrong answer is the hardest of the five to see: two
  # tests' outcome sequences interleaved under one name look exactly like the alternation the block
  # exists to show, so a stable test merged with a broken one reads as a flaky one. See
  # `RequestedUnstableTestParam`, which holds that reasoning in full.
  include RequestedUnstableTestParam

  # `?unannotated_examples=` read as a request for the run's unannotated examples — the only
  # `Requested*Param` this controller reads that carries NO VALUE.
  #
  # The parameters above it all name a WHICH — which branch, which area, which file, which
  # description, which test — because each opens the rows behind a LINE of a ranking the client had
  # already read. This one opens a POPULATION: the figure it drills out of is a subtraction on the run
  # itself (`total_specs_count - annotated_specs_count`), which has no rows and therefore no keys, so
  # there is exactly one answer the client can be asking for and nothing for the parameter to carry.
  # The predicate spelling — `requested_unannotated_examples?` rather than a `requested_*` reader — is
  # what says that at the call site.
  #
  # NOT included by `RepositoriesController`, like `?unstable_test=` and unlike the other five, and
  # that is a fact about the surfaces rather than an omission: the dashboard opens this subtraction
  # only through the per-example drill-in `445cb7f` added, which rides the existing
  # `?spec_file=`/`?spec_directory=` asks and takes no parameter of its own, so there is still no
  # second reader of THIS parameter to share a guard with. When one arrives it includes this module
  # rather than re-deriving the guard, which is the whole reason the guard lives in a module at all.
  #
  # It reaches no SQL comparison at all, which makes the hazard the MIRROR of the value-carrying
  # parameters rather than a weaker version of it. Theirs is a silent wrong answer: an Array becomes
  # an `IN` list, which answers about several things under a caption naming one for the parameters
  # above, and for `?commit_sha=` below re-anchors the whole response — the widest wrong answer this
  # endpoint can give, as its own block grades it. This one's is a silent EXTRA answer, because all
  # three malformed shapes are truthy in Ruby and an unguarded `.present?` would open a hundred-row
  # block on a query string nobody meant to send. See `RequestedUnannotatedExamplesParam`, which
  # holds that reasoning in full, including why `?unannotated_examples=false` is an ask like any
  # other.
  include RequestedUnannotatedExamplesParam

  # `?near_duplicates=` read as a request for the repository's near-duplicate clusters — the
  # second flag-style `Requested*Param` this object reads. Born in front of a measured, minutes-scale
  # cost (`NearDuplicateClusters` is linear; its class comment carries the table), the flag outlived
  # the cost that created it: since SPGD-1474 the census is computed at ingest and on run deletion
  # and served stored, so the ask now opens one stored row. The opt-in wire contract is unchanged —
  # the ask
  # `RequestedNearDuplicatesParam`, which holds the reasoning in full, including why
  # `?near_duplicates=false` is an ask like any other.
  include RequestedNearDuplicatesParam

  # `?near_duplicates_summary=` and `?near_duplicate_cluster=<rank>` — the bounded projections of
  # the same stored census (SPGD-1712): the ranking without member lists, and one cluster with its
  # members carried once. Guards only; {NearDuplicateCensusView} owns the projections.
  include RequestedNearDuplicatesSummaryParam
  include RequestedNearDuplicateClusterParam

  # `?near=` read as a behavior phrase — the probe text the `near` block ranks this repository's
  # stored identities against. One more free-text `Requested*Param` guard, and its two lines are
  # `RequestedBranchParam`'s — but what an admitted ask buys here is a PAID read (one embed per
  # novel probe on the shipped provider), which is why the malformed shapes are refused at the
  # door exactly as a value-carrying sibling refuses them. See `RequestedNearParam` for the
  # guard's reasoning and `NearProbe` for the read it opens.
  include RequestedNearParam

  # `?commit_sha=` read as a commit sha, to name WHICH RUN this endpoint describes — the only
  # `Requested*Param` here that re-anchors rather than narrows. Every parameter above leaves the
  # anchor alone: `?branch=` narrows a history, the drill-in parameters open one area, one file or
  # one description OF the run `latest_test_run` had already picked, `?unstable_test=` opens a WINDOW
  # across runs rather than a run, and `?unannotated_examples=` opens a POPULATION inside the run
  # already picked. This one picks it, which is why it is read in exactly ONE place — the
  # `latest_test_run` memo below — and every block hanging off that memo re-anchors without reading
  # the parameter at all.
  #
  # INCLUDED by `RepositoriesController` as well, unlike `?unstable_test=` and
  # `?unannotated_examples=`. This comment used to hold the commission open, against a human page
  # that anchored every panel on the repository's newest run; `e569554` redeemed it, and the page
  # now takes `?commit_sha=` and anchors on the run it names. The comment beside that controller's
  # own include quotes the commission this block once carried and answers "This is that reader."
  #
  # It reaches `where(commit_sha: …)` on a plain string column, which is the same silent hazard
  # `?spec_file=` documents — an Array does not raise, it becomes an `IN` list — and at THIS position
  # the wrong answer is the widest one the endpoint can give: an `IN` list would anchor on whichever
  # of several unrelated commits sorted newest, and every rollup, every drill-in and both growth
  # windows would then describe that run under a `run_anchor` naming the sha the client asked for.
  # See `RequestedCommitShaParam`, which holds that reasoning in full.
  include RequestedCommitShaParam

  # `?limit=` read as an Integer ask for how many rows the two run-grain duration rollups should
  # list — the first MAGNITUDE `Requested*Param` this object reads, shared with
  # `RepositoriesController` on the same reasoning every shared include above gives: the guard is
  # the parameter's, not the surface's, and a second copy of it would be a second answer to "which
  # shapes does `?limit=` tolerate". It names no run, no area and no key — it asks the ranking
  # itself to grow — which is also why it alone carries a ceiling: see `RequestedLimitParam`,
  # which holds that reasoning in full.
  include RequestedLimitParam
  # The bound on `history` below. Ten rows is ten rows whether the suite holds three tests or
  # twenty thousand — `Repository#recent_test_runs` argues that in its own comment — so this is a
  # bound and not the first page of a pagination contract there is no cursor to continue.
  HISTORY_LIMIT = 10

  # The bound when `?branch=` narrowed the window, which is DEEPER than the unfiltered one and is
  # the same depth `RepositoriesController` gives the human suite-size chart.
  #
  # Ten interleaved rows and ten rows of one branch are not the same amount of history. Unfiltered,
  # ten rows is a sample of what CI has been doing lately; filtered, it is the series itself, and
  # ten runs of a busy repository is an afternoon — `Repository::TRAJECTORY_LIMIT` documents that
  # reasoning where it was first made. Read off that constant rather than restated as `30`, so the
  # API's series and the dashboard's chart cannot come to disagree about how far back "the history"
  # reaches.
  #
  # `history_window.limit` serves whichever of the two applied, so no client has to know this rule
  # exists to know which bound it got.
  SINGLE_BRANCH_HISTORY_LIMIT = Repository::TRAJECTORY_LIMIT

  # `repository` and `params` are the whole input. Neither is a credential: this object cannot
  # tell an `sgk_` request from an `sgu_` one and has no business doing so — resolving the
  # repository and deciding the caller may open it are the CONTROLLERS' jobs, and they arrive at
  # it two different ways (a key that names one, versus `Repository.accessible_by(...).find_by`).
  def initialize(repository:, params:)
    @repository = repository
    @params = params
  end

  # ⭐ `api_key_block:` IS AN INSERTION AT A POSITION, NOT A FLAG. Passing it serves the block
  # where the singular endpoint has always served it — directly after `repository` and directly
  # before `delivery_health`, which is the claim it corrects — and omitting it leaves the key
  # genuinely ABSENT rather than present-and-null. A client reading a `null` cannot tell "this
  # request had no repository key" from "the key has no name", and only one of those is true.
  #
  # The block is built by the CALLER rather than here, because building it needs
  # `current_api_key`, which is the one thing that does not travel (see the class comment).
  def body(api_key_block: nil)
    {
      repository: serialized_repository,
      **(api_key_block ? { api_key: api_key_block } : {}),
      # WHETHER THIS REPOSITORY'S DELIVERIES ARE BEING ACCEPTED — the verdict `api_key.last_used_at`
      # above cannot give, and the one every run-grain figure below silently depends on.
      #
      # Beside `run_anchor` and deliberately NOT inside `latest_run`, on that block's own membership
      # rule stated at `unstable_tests`: `latest_run` is single-run facts by construction, and this
      # is a statement about a WINDOW OF DELIVERIES — several of them, most of which produced no run
      # at all. It sits directly under `api_key` because that is the claim it corrects.
      #
      # SERVED ON EVERY RESPONSE, including when nothing was refused and including on a repository
      # that has never had a run accepted — the reasoning `RepositoriesController#show` gives at its
      # `@rejected_ingests = RejectedIngests.for(...)` load for loading the panel unconditionally
      # rather than gating it on `@latest_test_run`. A repository with no accepted run is not the
      # empty case, it is the worst case. And "nothing was refused" is a POSITIVE FINDING an agent
      # cannot otherwise distinguish from "SpecGuard does not track that".
      #
      # See `serialized_delivery_health`.
      delivery_health: serialized_delivery_health,
      # WHETHER ANY KEY ON THIS REPOSITORY IS CARRYING A TOKEN NOTHING HAS USED — rotated, with no
      # authentication since. The other half of "is this repository reachable", and the half
      # `delivery_health` structurally cannot cover: a 401 resolves no repository and writes no row
      # (`IngestRejection`), so a pipeline failing on authentication is invisible to every rejection
      # figure above. This is the one 401-shaped failure the platform can report anyway, because it
      # need not observe the 401 — it owns the row and stamped the instant the token was retired.
      #
      # Beside `delivery_health` and NOT inside `api_key`, on that block's own membership rule: it
      # is single-key facts about the REQUESTING key, and this is a statement about the
      # repository's keys as a set — necessarily including keys that are not the one asking, since
      # the asking one has just authenticated and can never be in this state. See
      # `serialized_credential_health`.
      #
      # SERVED ON EVERY RESPONSE, including when nothing is rotated, for the reason `delivery_health`
      # states: "no key is stranded" is a POSITIVE FINDING an agent cannot otherwise tell apart from
      # "SpecGuard does not track that".
      credential_health: serialized_credential_health,
      # WHICH RUN THE RUN-GRAIN HALF OF THIS BODY DESCRIBES, and why that run. Placed before
      # `latest_run` on the `*_window` blocks' own convention — the disclosure precedes what it
      # discloses about — and it is the window-shaped block for the anchor rather than for a series.
      # See `serialized_run_anchor`.
      run_anchor: serialized_run_anchor,
      latest_run: serialized_latest_run,
      history_window: serialized_history_window,
      history: serialized_history,
      # BESIDE `history`/`history_window` and deliberately NOT inside `latest_run`, which is
      # single-run facts by construction. Every key that block serves — `shards`, `spec_files`,
      # `spec_directories`, `slowest_examples` — is a statement about ONE run's rows; "this test is
      # unstable" is a statement about one test across several, and it is read off the same window
      # `history` is served over. See `RepositoryWindowRankingSerializer#serialized_unstable_tests_window`.
      unstable_tests_window: window_rankings.serialized_unstable_tests_window,
      unstable_tests: window_rankings.serialized_unstable_tests,
      # BESIDE `unstable_tests` and NOT inside `latest_run`, on that block's own membership rule:
      # `latest_run` is single-run facts by construction, and this is a statement about ONE TEST
      # ACROSS SEVERAL RUNS. `latest_run.slowest_examples` is the same question at single-run grain
      # and stays exactly where it is — this is its complement, not its replacement.
      #
      # It is the DURATION axis of what `unstable_tests` does for the OUTCOME axis — both are
      # matched to a DURABLE TEST. That block groups on `spec_identity_id`, so an annotated test
      # that was REWORDED keeps its outcome history there, and this one groups on
      # `spec_identity_id` too, so a test that MOVED or was REWORDED keeps its runtime history. See
      # `RepositoryWindowRankingSerializer#serialized_slowest_tests_window`.
      slowest_tests_window: window_rankings.serialized_slowest_tests_window,
      slowest_tests: window_rankings.serialized_slowest_tests,
      # BESIDE `unstable_tests` and for the same structural reason it sits out here: a statement
      # about the WINDOW rather than about one run. `history` serves how the suite grew — one total
      # per run, no area grain on any row — and `latest_run.spec_directories` serves the area grain
      # of exactly one run. An agent holding every other key on this endpoint can compute THAT the
      # suite grew and never WHERE, which is the half of the roadmap's second axis ("how the suite
      # has grown over time and in which areas") nothing here answered. See
      # `RepositoryGrowthSerializer#serialized_directory_growth_window`.
      directory_growth_window: growth.serialized_directory_growth_window,
      directory_growth: growth.serialized_directory_growth,
      # BESIDE `directory_growth` and gated on `?branch=` exactly as it is: the declared-layer MIX
      # over the same thirty-run window's two ENDPOINTS (`basis: "two_endpoints"`). The run-over-run
      # `layer_run_growth` pair below cannot see a drift of one example per push; this can. Null (and
      # `grouped: false`) without `?branch=`. See `serialized_layer_growth_window`.
      layer_growth_window: growth.serialized_layer_growth_window,
      layer_growth: growth.serialized_layer_growth,
      # BESIDE `directory_growth` and NEVER IN PLACE OF IT — a different comparison over the same
      # grain, not a refinement of that one. The pair above compares the two ENDPOINTS of a
      # thirty-run branch window and is served only when `?branch=` named the branch to walk; this
      # pair compares the latest run against THE PREVIOUS RUN ON ITS OWN BRANCH, which is the
      # comparison `repositories#show` renders as "Areas that grew or shrank" and the one an agent
      # asks for by pushing: *which areas moved in the push I just made*.
      #
      # It needs no `?branch=` and takes none. `Repository#previous_test_run_on_branch` scopes to
      # the latest run's own branch, so the hazard the window pair's gate exists to prevent —
      # anchoring on a `main` run and baselining against a same-sharded `feature/x` one — cannot
      # arise here by construction. That is what makes a plain unparameterised `GET` carry growth
      # at all, which until now it did not: unfiltered, `directory_growth` is `null`.
      #
      # Out here rather than inside `latest_run` for the reason stated at the top of that block and
      # again on `unstable_tests`: that block is single-run facts by construction, and "this area
      # gained forty examples" is a statement about one run measured against another.
      #
      # See `serialized_directory_run_growth_window`.
      directory_run_growth_window: growth.serialized_directory_run_growth_window,
      directory_run_growth: growth.serialized_directory_run_growth,
      # BESIDE `directory_run_growth` (same two runs, same `?commit_sha=` re-anchoring, no new
      # parameter) and NOT inside `latest_run`, which is single-run facts only: how the run-wide
      # DECLARED-LAYER MIX moved against the previous run on the branch. See
      # `serialized_layer_run_growth_window`.
      layer_run_growth_window: growth.serialized_layer_run_growth_window,
      layer_run_growth: growth.serialized_layer_run_growth,
      # BESIDE `layer_run_growth` AND NOT DERIVABLE FROM IT: that pair differences example COUNTS, this
      # one differences the summed example DURATION per declared layer. A `sleep` in a shared
      # request-spec `before` is `request ±0` there and seconds here. See
      # `serialized_layer_runtime_growth_window`.
      layer_runtime_growth_window: growth.serialized_layer_runtime_growth_window,
      layer_runtime_growth: growth.serialized_layer_runtime_growth,
      # BESIDE `directory_run_growth` AND NOT DERIVABLE FROM IT — the same two runs and the same area
      # grain, measuring a different quantity. That pair answers "which areas changed SIZE" and this
      # one answers "which areas changed TIME", and `SpecDirectoryRuntimeGrowth`'s class comment
      # carries the argument in full: an area where somebody made an existing spec slow adds ZERO
      # examples, so its `ABS(latest_count - previous_count)` is `0`, it sorts last on that pair and
      # falls off the cap. It is not a row there missing a column — it is not on that list at all.
      # The independence runs both ways: splitting one slow spec into four fast ones is `+3` examples
      # and LESS time, and a `sleep` in a shared `before` is `0` examples and minutes.
      #
      # It is the grain `history` stops one short of, which is what makes it unreachable rather than
      # merely absent. `latest_run.spec_directories` serves per-area `total_seconds` for the LATEST
      # RUN ONLY, and the previous run is dereferenced on this endpoint for `baseline_commit_sha` and
      # the two COUNT-grain blocks alone — so there is no previous-run per-area duration anywhere in
      # this body and the subtraction is impossible client-side. The only runtime delta an agent can
      # compute is `test_runs.duration_seconds`, one figure for the whole run: it can be told the run
      # got ninety seconds slower and can never ask WHERE.
      #
      # NO NEW PARAMETER, for the reason the pair above gives: `Repository#previous_test_run_on_branch`
      # scopes to the latest run's own branch by construction, so a plain unparameterised `GET`
      # carries this.
      #
      # Out here rather than inside `latest_run` on that block's own membership rule: it is
      # single-run facts by construction, and "this area got forty seconds slower" is a statement
      # about one run measured against another.
      #
      # See `serialized_directory_runtime_growth_window`.
      directory_runtime_growth_window: growth.serialized_directory_runtime_growth_window,
      directory_runtime_growth: growth.serialized_directory_runtime_growth,
      # ONE GRAIN BELOW THE PAIR ABOVE, for the ONE area a caller asked about — not which areas
      # moved but which FILES of the picked area moved. The pair above answers
      # `spec/models 412 → 459 (+47)` and dead-ends on the only question that provokes: WHICH FILES
      # DID THAT. `repositories#show` has answered it since SPGD-456 and this endpoint could not be
      # asked at all, so an agent holding `directory_run_growth` reached exactly the dead end the
      # panel had already removed for a human reader.
      #
      # It matters most for the doubt the pair above DISCLOSES and then leaves the caller holding: a
      # moved directory appears there as one area growing and another shrinking by the same amount,
      # with nothing added and nothing deleted. The file grain is what resolves it —
      # `user_spec.rb` new beside `legacy_user_spec.rb` removed reads as a rename, and
      # `billing_spec.rb 3 → 50` does not. Neither surface ASSERTS either reading; both put the
      # operands where the reader can pair them, which is the pairing
      # `SpecObservation`'s positional-instability rule forbids the application from doing.
      #
      # NO NEW PARAMETER. The ask is `?spec_directory=` — the SAME one `latest_run.spec_directory_files`
      # reads, deliberately not a second one, exactly as the two panels on `show` are opened by one
      # click. One ask now opens TWO blocks on this endpoint, each answering in its own grain: which
      # files carry the area's wall clock, and which of them moved since the previous run. A later
      # reader should not "fix" it by splitting the parameter in two.
      #
      # Out here beside its parent rather than inside `latest_run` for that block's own membership
      # rule: `latest_run` is single-run facts by construction, and "this file gained forty
      # examples" is a statement about one run measured against another.
      #
      # See `serialized_directory_run_file_growth_window`.
      directory_run_file_growth_window: growth.serialized_directory_run_file_growth_window,
      directory_run_file_growth: growth.serialized_directory_run_file_growth,
      # THE FOURTH AND LAST CELL of the {area, file} × {count, runtime} square this endpoint serves
      # growth over, and until now the only empty one. `directory_run_growth` is area×count,
      # `directory_runtime_growth` is area×runtime, the pair above is file×count — and an agent told
      # `spec/models` got ninety seconds slower could not ask WHICH FILE DID IT. That exact dead end
      # was identified and removed for the COUNT pair by the block above; the same dead end on the
      # RUNTIME pair had been removed for nobody, human or agent.
      #
      # ⭐ THE KEY NAME IS THE SQUARE'S OWN VOCABULARY, not a new one. The three shipped cells fix
      # two independent morphemes: `run` vs `runtime` selects the QUANTITY, and inserting `file`
      # before `growth` drops the GRAIN by one — which is exactly how `directory_run_growth` became
      # `directory_run_file_growth`. Applying that same insertion to `directory_runtime_growth`
      # yields this and only this, so the four keys read as one paradigm a client can complete
      # rather than four names to memorise. The alternative orderings all break it: anything ending
      # `..._file_runtime_growth` would make this the one cell whose quantity morpheme sits after
      # its grain morpheme, and a client that had learned the square from the other three would
      # guess wrong.
      #
      # NOT DERIVABLE FROM THE THREE CELLS BESIDE IT, and this is the strongest such claim on the
      # endpoint because every candidate operand is dereferenced in this same body:
      # `latest_run.spec_directory_files` carries per-file `total_seconds` and is LATEST RUN ONLY;
      # `latest_run.spec_file_examples` is one file of one run; the pair above is the right two runs
      # at the right grain and measures COUNTS ALONE; `history` rows carry one `duration_seconds`
      # for a whole run with no file grain in it. The client holds this run's per-file seconds and
      # never the previous run's, so the subtraction is impossible client-side — not merely tedious.
      #
      # NO NEW PARAMETER, AND THIS IS THE THIRD BLOCK ON ONE ASK. The ask is `?spec_directory=` —
      # the SAME one `latest_run.spec_directory_files` and `directory_run_file_growth` read. One ask
      # now opens THREE blocks, each answering in its own grain: which files carry the area's wall
      # clock, which of them changed SIZE since the previous run, and which of them changed TIME. A
      # later reader should not "fix" this by splitting the parameter — the warning the block above
      # gives at two, restated at three because the temptation grows with the count.
      #
      # Out here beside its parent rather than inside `latest_run` on that block's own membership
      # rule: `latest_run` is single-run facts by construction, and "this file got forty seconds
      # slower" is a statement about one run measured against another.
      #
      # See `serialized_directory_runtime_file_growth_window`.
      directory_runtime_file_growth_window: growth.serialized_directory_runtime_file_growth_window,
      directory_runtime_file_growth: growth.serialized_directory_runtime_file_growth,
      # SERVED ON THE ASK AND NEVER WITHOUT IT — and, since SPGD-1474, served STORED: the census is
      # computed once per write that moves its inputs — at ingest, and on run deletion
      # ({RunsController#destroy}) — and persisted, so what the ask opens is a read of one stored
      # row rather than the minutes-scale computation it used to be (`NearDuplicateClusters` is
      # linear but measured in seconds; its class comment carries the table, and the agent bridge's
      # thirty-second deadline could never hold it — SPGD-1474 is the ticket that moved the
      # computation off the request path). The opt-in ask itself is unchanged wire contract:
      # `?near_duplicates=`
      # is the ask, a client that does not send it gets the key present and `null` — the no-ask
      # spelling every gate on this endpoint uses — and pays not one query for it. See
      # `serialized_near_duplicates`.
      near_duplicates: serialized_near_duplicates,
      # SERVED ON THE ASK AND NEVER WITHOUT IT — two bounded projections of the SAME stored census
      # row `near_duplicates` opens: the ranking with no member lists, and one cluster by rank with
      # its members once. Both `null` unless asked, and `null` when nothing is stored. See
      # `serialized_near_duplicates_summary`, `serialized_near_duplicate_cluster` and
      # `NearDuplicateCensusView`.
      near_duplicates_summary: serialized_near_duplicates_summary,
      near_duplicate_cluster: serialized_near_duplicate_cluster,
      # SERVED ON THE ASK AND NEVER WITHOUT IT — and, unlike the census beside it, served LIVE:
      # `?near=` embeds the probe (once per novel phrase, through the shipped cache), ranks the
      # repository's identities through the ANN seam, and discloses what every figure means. The
      # no-ask spelling is the same one every gate on this endpoint uses — the key present and
      # `null`, not one query and not one embed paid for it. See `serialized_near` and `NearProbe`.
      near: serialized_near,
      branches_window: serialized_branches_window,
      branches: serialized_branches
    }
  end

  private

  # The two inputs, read-only. `repository` is what every serializer below is about;
  # `params` is what the `Requested*Param` guards above read the ask out of.
  attr_reader :repository, :params

  # The same four fields, under the same names, that `Api::V1::UserRepositoriesController`
  # serves in its own `repository` block — so a client that has read either knows how to read
  # this, and the two cannot drift into naming the same facts differently.
  def serialized_repository
    {
      id: repository.id,
      full_name: repository.github_full_name,
      name: repository.name,
      registered_at: repository.created_at.iso8601
    }
  end

  # THE DELIVERIES THIS REPOSITORY'S CI MADE THAT THE ENDPOINT REFUSED, and the one verdict that
  # tells an agent whether the rest of this body still describes its suite.
  #
  # == What this block is for
  #
  # Every run-grain key here — `latest_run` and its five rollups, both growth pairs, `unstable_tests`
  # — is read off rows that were ACCEPTED. When ingestion is being refused, those rows stop moving
  # while remaining perfectly well-formed, so the response an agent receives is a complete,
  # non-null description of a suite state that no longer exists. It then optimises a test that was
  # deleted, hunts a flake that was fixed, or reports growth that never happened, and nothing in the
  # body contradicts it. This is the project's own *Vacuous Green* class (SPGD-78) at the agent
  # surface, and the trigger is not hypothetical: SPGD-560 documents a gem version floor that 400s
  # every run over 256 KiB — every large suite, which is the population this product exists for.
  #
  # == The honesty bounds, none of them guessable from the keys
  #
  # * ⚠️ **AUTHENTICATED-AND-REFUSED ONLY. A 401 IS NOT IMPLIED HERE, WITH ONE NAMED EXCEPTION.**
  #   `ApiKey.authenticate` returning `nil` resolves no repository, so there is nothing to attribute
  #   a row to and none is written — `Api::V1::IngestsController` states that on the write path. A
  #   client sending a revoked token sees `refusing: false` here, and that remains true: a refused
  #   AUTHENTICATION never reaches the payload, so it is not a refused DELIVERY and this block may
  #   not claim it. What changed (SPGD-804) is that the revoked case is no longer SILENT elsewhere:
  #   `ApiKey#revoke!` retains the row, `Api::BaseController`'s failure path stamps the refused
  #   presentation on it, and `credential_health.revoked_key_presented` reports it by name — the
  #   "name the block that answers what this one cannot" convention `acceptance_reported_by`
  #   follows. A 401 from a token that was never a key for this repository stays unattributable
  #   everywhere, and nothing is synthesized for it. Replacing one false claim with a second one is
  #   the failure mode this block exists to avoid.
  # * **`reasons` is `Ingest::Payload`'s own error list, verbatim** — the same words the client was
  #   handed in its 400, never re-worded into a platform-side verdict. This endpoint's standing rule
  #   for `outcome`, applied one grain down.
  # * **NOT A RETRY QUEUE.** The payload was refused and was not stored; no run of it exists and
  #   none can be reconstructed. What ships is that the agent LEARNS it happened and what the
  #   endpoint objected to.
  # * **Both of `RejectedIngests#refusing?`'s bounds transfer unchanged** and are restated rather
  #   than re-derived (argued in full at `rejected_ingests.rb:29-38`): a sharded run that is half
  #   accepted and half refused reads as refusing, because a shard thrown away IS a suite partly
  #   thrown away; and a refusal ages out of `IngestRejection::REPOSITORY_RETENTION_ROWS`, so a
  #   repository refused and then silent forever eventually reads healthy again.
  #
  # == The two truncation bounds are independent, and both are disclosed
  #
  # `rejections_window.bounded` counts DELIVERIES retained; `reasons_truncated` counts REASONS
  # inside one delivery. A list nowhere near its window bound can still be hiding almost everything
  # — one refusal of a 20,000-example suite is a single row. `IngestRejection` carries that argument.
  #
  # `reasons` / `omitted_reasons_count` are served rather than the raw `details` column: `details` is
  # capped at `RETAINED_REASONS_PER_ROW` with no per-row disclosure beside it, so serving it raw
  # would hand a client a silently-shortened objection to read as the endpoint's whole sentence —
  # exactly the habit this block was built to correct, at a smaller grain.
  #
  # == The window's population and its client composition
  #
  # `rejections_window` also carries the window's two MEASURED facts, both read off
  # {RejectedIngests#retained_window} — the same summary the panel states above its rows, one
  # grouped query, memoized:
  #
  # * `retained_total` is the population of the RETAINED WINDOW — everything the retention rule
  #   still holds, up to `retention_rows` — and is the sum of `retained_clients`' buckets, so the
  #   two come from one `GROUP BY` and cannot disagree. It is NOT the length of the `rejections`
  #   array beside it: that list is bounded by `limit`, and the whole point of the pair is that
  #   they differ — on a fleet mid-upgrade the old-gem refusals sit exactly in the rows the list
  #   does not show, which is the reading `bounded: true` can disclose but never count.
  # * `retained_clients` splits that population by reported client, largest bucket first, ties
  #   alphabetical — `RetainedWindow`'s own order, not re-sorted here. `reported_client: null`
  #   carries the row-level key's meaning (`serialized_ingest_rejection_row`): the client sent no
  #   `User-Agent`. It is not the `served_by` null, which names a missing BUILD identity, and the
  #   nil/blank fold happens inside `RetainedWindow` so the summary and the rows speak one
  #   vocabulary and SQL's `NULL`-vs-`''` split never reaches the wire.
  #
  # An accepting repository serves `retained_total: 0` and `retained_clients: []` — a positive
  # finding, not an absent key — and issues no extra read for them: `RetainedWindow.empty`
  # short-circuits off the peek `.for` has already paid.
  def serialized_delivery_health
    window = rejected_ingests.retained_window

    {
      refusing: rejected_ingests.refusing?,
      last_rejection_at: rejected_ingests.last_rejection_at&.iso8601,
      rejections_window: {
        limit: IngestRejection::PANEL_LIMIT,
        bounded: rejected_ingests.bounded?,
        retention_rows: IngestRejection::REPOSITORY_RETENTION_ROWS,
        any_reasons_truncated: rejected_ingests.truncated_rows?,
        retained_total: window.total,
        retained_clients: window.entries.map { |client, count| { reported_client: client, count: count } }
      },
      rejections: rejected_ingests.rows.map { |rejection| serialized_ingest_rejection_row(rejection) }
    }
  end

  # The keys whose `last_used_at` was stamped by a token that no longer exists, and the verdict the
  # UI's connection indicator is built on. `ApiKey#rotated_and_unused?` carries the rule — an ordering
  # comparison between the rotation and the last use, with both nil cases decided — and it is the
  # same object the two web surfaces read, so the agent and the page cannot disagree about a key.
  #
  # `rotated_and_unused` is the whole-repository answer; `keys` names WHICH, because the remedy is
  # per-key (a secret to update in whichever store that pipeline reads) and a bare boolean would
  # leave an agent unable to act on it. Key NAMES only — no digest, no hint, nothing that
  # identifies a token — and the caller already holds a key on this repository, so the set of key
  # names is not something this discloses to anyone who could not list them anyway.
  #
  # Unbounded on purpose: this is a list of things that are WRONG, and a repository has a handful
  # of keys rather than a stream of them, so there is no window to bound and no truncation to
  # disclose. ONE query, and the predicate is applied in Ruby rather than as SQL deliberately: a
  # WHERE clause here would be a second expression of `rotated_and_unused?`'s rule, free to drift
  # from the one the two web surfaces read, and this block exists to stop the agent and the page
  # disagreeing about a key.
  def serialized_credential_health
    # THE RETIREMENT SPLIT, one object off the ONE SELECT: `ApiKeyPartition` owns the
    # live / revoked / stranded / presented-revoked split — the same object the two web surfaces
    # read, which is what makes "the agent and the page cannot disagree about a key" a property of
    # the construction rather than a hope about three hand-typed copies. Stranded keys are a
    # LIVE-keys question (a key rotated and THEN revoked is both, and the revocation is the newer
    # fact — reporting it as merely rotated would understate the state a client needs to act on),
    # and the presented-revoked half reads the retained rows a `WHERE` would have filtered out, so
    # ALL of this repository's rows are handed in, loaded once. `rotated_and_unused?`'s comment
    # carries the rule against re-expressing that predicate in SQL.
    partition = ApiKeyPartition.for(repository.api_keys.to_a)
    stranded = partition.stranded_rows
    presented_revoked = partition.presented_revoked_rows

    {
      rotated_and_unused: stranded.any?,
      keys: stranded.map do |api_key|
        {
          name: api_key.name,
          rotated_at: api_key.rotated_at.iso8601,
          # The stamp the rotation stranded, served rather than hidden: it is the key's history and
          # it is exactly the figure a client must not read as a live reachability signal. `null`
          # when the key was rotated before it ever authenticated.
          last_used_at: api_key.last_used_at&.iso8601
        }
      end,
      # ⚠️ THE REVOKED-PRESENTATION FINDING, SERVED ON EVERY RESPONSE INCLUDING THE NEGATIVE — the
      # block's standing rule: a positive finding is indistinguishable from "SpecGuard does not
      # track that" unless the negative is served too. `true` means a key this repository's owner
      # revoked has arrived at the API and been refused (`last_refused_at` stamped by
      # `Api::BaseController`'s failure path): the caller's pipeline — or a sibling's — is still
      # presenting a dead token, and the fix is updating the secret store, not this endpoint.
      #
      # THE HONEST BOUND, stated rather than implied: this closes the REVOKED case of the 401s,
      # not 401s in general. A token that was never a key for this repository resolves to no row
      # and nothing may be synthesized for it — the same rule `delivery_health.refusing` follows
      # for a rejection no row was recorded for. `last_refused_at` is the LAST observed
      # presentation, so a client reading `true` learns the most recent attempt's recency and not
      # a promise about the present tense.
      revoked_key_presented: presented_revoked.any?,
      presented_revoked_keys: presented_revoked.map do |api_key|
        {
          name: api_key.name,
          revoked_at: api_key.revoked_at.iso8601,
          last_refused_at: api_key.last_refused_at.iso8601
        }
      end
    }
  end

  # One refused delivery. `reported_client` is `nil` — never a substituted placeholder — when the
  # client sent no `User-Agent`, which is `IngestRejection#reported_client`'s own rule: a version
  # nobody reported must not be invented, least of all on the block whose subject is a diagnosis by
  # client version.
  #
  # ⚠️ THE TWO NULLS ON THIS ROW MEAN DIFFERENT THINGS, and a client must not read one as the
  # other — the panel draws the distinction in words ("Not reported" vs "Not recorded"); this
  # surface has only `null`, so the distinction lives here in prose. A null `reported_client`
  # means THE CLIENT SENT NO `User-Agent` (the row knows, and the client said nothing). A null
  # `served_by` means THE ROW CARRIES NO BUILD IDENTITY RECORDED — the platform genuinely does
  # not know which build answered, and the write path can land on that nil in more than one way
  # (for example a row `IngestRejection::REPOSITORY_RETENTION_ROWS` retains across deploys from
  # before the stamp existed; a build whose VERSION file is missing or unreadable; a column
  # stored blank), so the `null` does not distinguish them.
  # `served_by` is served through the reader `IngestRejection#served_by` (`server_version.presence`),
  # not the raw column, so both API keys and the panel's cells name the same fact — the parity rule
  # this endpoint's controller states outright: the two surfaces do not get to name the same facts
  # differently.
  def serialized_ingest_rejection_row(rejection)
    {
      occurred_at: rejection.occurred_at.iso8601,
      reported_client: rejection.reported_client,
      served_by: rejection.served_by,
      reasons: rejection.reasons,
      omitted_reasons_count: rejection.omitted_reasons_count,
      reasons_truncated: rejection.reasons_truncated?
    }
  end

  # ⭐ ANCHORED ON `repository.latest_test_run` AND NEVER ON THE `latest_test_run` MEMO.
  # This is the one non-obvious thing in this feature and a later reader must not "simplify" it.
  #
  # That memo is RE-ANCHORED BY `?commit_sha=` — deliberately, so every run-grain block describes
  # the named run coherently. Handing it here would compare the newest refusal against an arbitrary
  # PINNED OLDER run, so any client bookmarking an old commit on a perfectly healthy repository
  # would be told `refusing: true`. That is the same class of falsehood this block exists to remove,
  # reintroduced by the fix.
  #
  # Delivery health is a fact about the repository's DELIVERY STREAM, not about whichever run the
  # caller anchored to, so the accepted side is the true newest accepted run on every request.
  #
  # Read unconditionally rather than reusing the memo when no `?commit_sha=` was sent. That
  # conditional would save one indexed `LIMIT 1` lookup on the unpinned path and would couple this
  # block's correctness to the CURRENT list of parameters that re-anchor — the next one to arrive
  # would silently reintroduce the bug above, in a block whose entire purpose is not lying about
  # freshness. One query is the right price for a correctness property that cannot decay.
  #
  # Memoized across the nil with `||=` on the OBJECT rather than the row, so the verdict and the
  # rows under it are read off one bounded query no matter how many serializers ask.
  def rejected_ingests
    @rejected_ingests ||= RejectedIngests.for(
      repository,
      last_accepted_run_at: repository.latest_test_run&.created_at
    )
  end

  # WHICH RUN THE RUN-GRAIN HALF OF THIS BODY DESCRIBES, and why that one — the disclosure block for
  # the anchor, shaped like the `*_window` blocks and serving the same purpose they do: a client must
  # not have to infer from the figures which question was answered.
  #
  # PRESENT ON EVERY RESPONSE, never `null`, including on a repository CI has never reported to. It
  # is a statement about the REQUEST — which run was asked for and which one was picked — and that
  # statement exists whether or not there are runs to pick from. `latest_run` is the key that goes
  # `null` for "CI has never reported"; this one then says `commit_sha: null` beside a `source` that
  # still reports whether anybody asked, which is a different fact and the one that distinguishes
  # "no runs at all" from "no run for the sha you named".
  #
  # `source` is the client's first read: `"requested"` means `?commit_sha=` named a run, `"default"`
  # means this is the repository's newest run because nobody asked. It is a fact about the ASK and
  # NOT about whether the ask worked — an unknown sha is still `"requested"` — which is exactly the
  # split `history_window` draws with `branch_scope` beside its raw `branch`.
  #
  # `requested_commit_sha` is the RAW ASK, echoed back and kept EVEN ON FALLBACK. Without it a client
  # handed a body anchored on a different sha could not tell a fallback from its own bug, because the
  # only other place the ask appears is the URL it no longer holds. `null` when there was none, and
  # `null` too for the malformed shapes `RequestedCommitShaParam` reads as no ask — the guard's
  # answer is the one serialized, so the block never claims a request the endpoint did not honour.
  #
  # `resolved` is FALSE IN EXACTLY ONE CASE: the client named a sha and is not being served it.
  # Deliberately not "did something resolve" — on a default call there was no ask to fail, so this is
  # `true` and a client's `unless resolved` warning fires only on a real fallback rather than on
  # every unparameterised GET. Served off `requested_test_run` — the same memo the anchor itself is
  # picked from — and never re-derived by comparing the two shas, so the disclosure and the choice it
  # discloses cannot come apart.
  #
  # `commit_sha`/`branch` NAME THE RUN ACTUALLY SERVED, which is what makes the fallback legible:
  # under `source: "requested", resolved: false` they are the newest run's, and they will not equal
  # `requested_commit_sha`. Both nullable, and `branch` independently so — it is nullable by schema
  # and `Ingest::Payload` accepts a body without it, so `null` there means "the client did not say"
  # exactly as it does on `latest_run`.
  #
  # ⭐ `history[0] == latest_run` HOLDS ON A DEFAULT CALL AND IS NOT EXPECTED TO HOLD UNDER AN
  # EXPLICIT ASK. `history` is not re-anchored by `?commit_sha=` — it stays the repository's recent
  # runs, newest first, narrowed only by `?branch=` — so naming an older run makes `latest_run` a row
  # from the middle of that array or from behind its bound entirely. That is the contract rather than
  # a bug, and this block is what says so, the way `history_window.branch_scope` says it for the
  # branch-filtered case. A client that needs the identity back omits the parameter.
  # `observations_retained` / `retention_runs` DISCLOSE THE OTHER WAY THIS BLOCK CAN BE EMPTY, and
  # they are shaped on `rejections_window.retention_rows` key-for-key, under the same doctrine that
  # block states in its own words: *the two truncation bounds are independent, and both are
  # disclosed*, because a row ageing out changes the MEANING of the reading. `BRANCH_RETENTION_RUNS`
  # changes the meaning of every per-example reading identically, and until now it was published
  # nowhere.
  #
  # The state they name is one `resolved: true` could not distinguish. `Ingest::ObservationPruner`
  # deletes `spec_observations` and never deletes the owning `test_runs` row, so a pruned run
  # resolves, still reports `suite_size_measured: true` off its own untouched `total_specs_count`,
  # and returns zero rows from every per-example rollup — byte-identical to a run that genuinely
  # recorded nothing, and a lie in the CONFIDENT direction. This block already refuses that exact
  # conflation one grain up (see `serialized_latest_run`: *a repository whose CI has never run must
  # not serialize byte-identically to one that ran and genuinely found an empty suite*); these two
  # keys are that same refusal one grain down. `RequestedCommitShaParam` names *a pruned run* among
  # the ordinary ways to arrive here, and discloses only the not-found half of it.
  #
  # **`observations_retained` is a statement about the RULE, not a row count.** `false` means the
  # retention rule no longer keeps this run's per-example rows — deleted, or eligible for deletion
  # at any ingest. `TestRun#observations_retained?` carries the argument; the short version is that
  # `Ingest::QuietBucketPruner` is opportunistic and names its own unreachable remainder, so a
  # past-boundary run in a quiet bucket may still physically hold rows nothing has got round to
  # deleting. A client must not read this as "the rows are gone", and the endpoint must not derive
  # it from row absence — that would conflate retention with a run whose per-example rows were never
  # delivered at all.
  #
  # `retention_runs` is the constant itself, published so the reading above is interpretable rather
  # than a bare boolean: it is what makes `false` mean *older than the 60 most recent runs of this
  # run's own branch* instead of *older than something*. Per BRANCH and never per repository — the
  # constant's own comment carries why — so it bounds the branch named two keys up.
  #
  # ADDED BESIDE the existing five, which keep their names, types and values exactly: a default
  # unparameterised GET is byte-identical to what it served before apart from these two, pinned in
  # `spec/requests/api/v1/repositories_spec.rb`.
  def serialized_run_anchor
    {
      source: requested_commit_sha ? "requested" : "default",
      requested_commit_sha: requested_commit_sha,
      resolved: requested_commit_sha.nil? || !requested_test_run.nil?,
      commit_sha: latest_test_run&.commit_sha,
      branch: latest_test_run&.branch,
      observations_retained: latest_test_run&.observations_retained?,
      retention_runs: SpecObservation::BRANCH_RETENTION_RUNS
    }
  end

  # THE `latest_run` BLOCK — assembled by `LatestRunSerializer` at FULL depth, which is where the
  # block and its per-key reasoning live now (moved verbatim; only the drill-in calls gained an
  # `overview.` prefix). What stays HERE is the half this object owns: WHICH RUN, and the ask the
  # drill-ins read.
  #
  # NOT RE-ANCHORED BY `?branch=`. This names the run `run_anchor` above resolved to and keeps
  # naming it under every request; only `history` narrows. A client filtering the history has asked
  # a question about a series, not for a different latest run, and re-anchoring would silently change
  # the meaning of four blocks (`latest_run`, `shards`, and the `history[0] == latest_run` identity
  # the tie-break examples pin) to answer one. The consequence is worth stating because it is the one
  # surprise here: under `?branch=main` on a repository whose newest run is on `feature/x`,
  # `history[0]` is a `main` row and `latest_run` is the `feature/x` one, and they are *supposed* to
  # differ. `history_window.branch_scope` is what says so.
  #
  # RE-ANCHORED BY `?commit_sha=`, which is the one parameter that does and is deliberately a
  # different kind of ask: `?branch=` asks about a SERIES, this asks WHICH RUN. It is read once, in
  # the `latest_test_run` memo, so this block and everything hanging off it move together rather than
  # each re-reading the parameter — see that memo, and `serialized_run_anchor` for what the response
  # says about the move. The `history[0] == latest_run` identity above holds on a default call and is
  # NOT expected to hold under an explicit ask; `run_anchor` is what says so, the way
  # `history_window.branch_scope` does for its own block.
  #
  # `nil` — not a zeroed block — when CI has never reported: a repository whose CI has never run
  # must not serialize byte-identically to one that ran and genuinely found an empty suite; that is
  # the conflation the Overview panel refuses too (see RepositoriesController#show). The serializer
  # owns that rule and every key under it. It is the SAME serializer `GET /api/v1/repositories`
  # serves at LIST depth on each entry — one assembly, so the list and this detail page cannot name
  # the same facts differently — and this object is handed to it as the collaborator that holds the
  # ask, because the drill-in blocks below read `params` and are this object's to build.
  def serialized_latest_run
    LatestRunSerializer.new(latest_test_run, depth: LatestRunSerializer::FULL_DEPTH, overview: self).body
  end

  # THE SUITE-WIDE DUPLICATE CENSUS, served STORED — the first block on this endpoint whose GRAIN
  # is the repository rather than a run or a window of runs, and the one whose cost used to be the
  # reason it had to be opted into at all. Since SPGD-1474 the census is computed once per write
  # that moves its inputs — at ingest ({Ingest::NearDuplicateCensusJob}, after identity
  # resolution) and on run deletion ({RunsController#destroy} requests the same recompute) — and
  # persisted on `near_duplicate_censuses`; this method reads what is stored and serves it
  # verbatim. The
  # minutes-scale computation that used to run here is gone from the request path — the agent
  # bridge's thirty-second deadline could never hold it — and the opt-in ask stays as the wire
  # contract: the key is present and `null` on a no-ask, exactly as before, and a client that did
  # not ask pays not one query for the block.
  #
  # == `nil` here has two meanings, and only one of them is this method's
  #
  # On a no-ask, `nil` is the no-ask spelling every gate on this endpoint uses. ON AN ASK, `nil`
  # means the repository has NO STORED CENSUS YET — it has never ingested (its first ingest
  # schedules the first computation), or it is being read in the window between this table
  # shipping and its backfill landing. It is never a live computation and never zeros: zeros would
  # render "not computed yet" as "computed, and nothing reads alike", which is the *Vacuous Green*
  # failure this endpoint exists to prevent. A repository whose every test reads differently is
  # NOT this state — its census is a stored row with an empty `clusters` array and real population
  # counts, stamped `computed_at`, served as the finding it is.
  #
  # == Why serving stored is honest rather than merely fast
  #
  # The census is a pure derivative of ingested data: its inputs — `spec_identities`,
  # `spec_observations`, and the repository's newest run as the weighed run — change only at
  # ingest, which is when the stored artifact is recomputed. Between ingests the stored census
  # equals what a live computation would return, byte-identically, because the writer serialized
  # the very object the live path used to build. A request arriving between a completed ingest and
  # the finished recompute serves the PREVIOUS stored census with its own stamp — `computed_at`
  # says when it was taken and `weighed_run_id` says which run its weights are from — so a stale
  # answer is dated, never silent. That stamp is the one key this method adds to the contract, and
  # it is why the mid-recompute window needs no client-side workaround.
  #
  # == The disclosure rides the count and cannot be split from it
  #
  # `similarity_basis` and `similarity_floor` travel with the stored figures rather than being
  # restated here — they are read off the object at COMPUTE time and frozen into the payload, so
  # this endpoint still cannot drift from what `NearDuplicateClusters` says about itself: when
  # `SIMILARITY` is re-derived for the shipped provider (open work the constant's own comment
  # names), the next ingest stores the new figure and the endpoint reports it without being
  # touched. No spec may pin either as a literal; `near_duplicate_clusters_spec.rb` establishes
  # that discipline for the constants themselves. A cluster count rendered without the statement
  # of what the similarity means is the *Vacuous Green* failure in a new spelling, which is why
  # the disclosure keys sit FIRST on this block, ahead of every figure they qualify.
  #
  # The declared-layer cut rides the same rule and the same artifact (SPGD-1475): `layer_source`
  # joins the two disclosure keys at the head of the block, and each cluster carries its
  # `layer_redundancy` and `layer_groups` exactly as the compute stored them — declared via the
  # intent protocol, never inferred, with `layer_source` `nil` on a suite that declared nothing.
  # `NearDuplicateCensus`'s class comment owns why the cut lives inside the stored payload rather
  # than being re-joined here.
  #
  # The rest of the block's shapes — raw figures, never the object's prose; `member_count` against
  # `example_count` at their two grains — are `NearDuplicateCensus.snapshot_payload`'s to word,
  # where they moved with the serialization. Nothing on the request path re-derives any of it.
  def serialized_near_duplicates
    return nil unless requested_near_duplicates?

    stored_near_duplicate_census
  end

  # `?near_duplicates_summary=` — the stored census as a ranking, member lists dropped.
  def serialized_near_duplicates_summary
    return nil unless requested_near_duplicates_summary?

    NearDuplicateCensusView.new(stored_near_duplicate_census).summary
  end

  # `?near_duplicate_cluster=<rank>` — one stored cluster, members once, the ask echoed.
  def serialized_near_duplicate_cluster
    ask = requested_near_duplicate_cluster
    return nil if ask.nil?

    NearDuplicateCensusView.new(stored_near_duplicate_census).cluster(ask)
  end

  # THE ONE READ of the stored census row, memoized (`nil` — nothing stored — included) so that
  # any combination of the three census asks pays for it once.
  def stored_near_duplicate_census
    return @stored_near_duplicate_census if defined?(@stored_near_duplicate_census)

    @stored_near_duplicate_census = NearDuplicateCensus.stored_block_for(repository)
  end

  # THE `?near=` BLOCK — the probe read, live where the census beside it is stored. `NearProbe`
  # owns every figure and every disclosure; what THIS method owns is the ask's gate and the
  # anchor the weights ride: `latest_test_run`, the same memo every run-grain block on this body
  # is read off, so a `?commit_sha=` ask weights the probe against the run the rest of the
  # response describes rather than against whichever run is newest. The gate reads the memoized
  # ask (nil, "no ask") so the no-ask path costs nothing at all — no fingerprint read, no cache
  # read, no run lookup — and the key is present and `null` on it, the spelling every opt-in
  # block on this endpoint uses.
  #
  # `?limit=` (`requested_limit`, already clamped to `RequestedLimitParam::MAX_LIMIT`, then to
  # `NearProbe::MAX_NEAR_LIMIT` — the deepest measured-good ranking) is the page size; `nil` falls
  # to the probe's default of ten. It is the endpoint's one shared `?limit=`,
  # so it widens the duration rollups too — that is the param's existing contract. The block serves
  # the APPLIED `limit` and `truncated`, so the clamp and any cut are visible (SPGD-1585).
  def serialized_near
    return nil unless requested_near

    NearProbe.for(repository, requested_near, run: latest_test_run, limit: requested_limit)
  end

  # The contract the array below is served under, stated as tokens a client can compare rather
  # than a caption it would have to read. The human "Recent runs" panel carries this same warning
  # as a sentence under its heading (app/views/repositories/show.html.erb) — *"consecutive rows are
  # routinely two different branches. They are not a series"* — and a machine-readable consumer
  # cannot act on a sentence. Shipping the rows without these three facts would re-create that
  # panel's original defect one layer down, for a client that has no caption to fall back on.
  #
  # `branch_scope` is the load-bearing one. Unfiltered, `Repository#recent_test_runs` is the
  # interleaved history across EVERY branch CI reports from, so `history[0]` and `history[1]` are
  # routinely two different branches and the difference between their `total_specs` is not a change
  # in the suite. A client that wants a series asks for one with `?branch=`; a client that does not
  # filters on the per-row `branch` itself, and this block is what tells it that it must.
  #
  # `branch_scope` and `branch` are TWO keys rather than one interpolated token (`"branch:main"`),
  # on this block's own rule: a client compares `branch_scope` against a fixed vocabulary it can
  # hard-code, and reads the name out of `branch` without parsing. A token carrying the name would
  # be neither — every client would have to `start_with?` its way back to the two facts.
  #
  # `branch` IS ALWAYS SERVED, `null` when the window was not narrowed — the same key-always-present
  # rule `latest_run.shards` argues for itself above. A client tests one thing rather than
  # distinguishing an absent key from a null one, and the pair reads the same way in every response.
  # It restates what the SERVER filtered on, which is not always what the client sent: a non-String
  # or blank `?branch=` is no filter at all, and echoing the raw param would tell a client its
  # filter applied when it did not.
  #
  # `returned` beside `limit` rather than either alone: `returned == limit` is how a client learns
  # the suite has run at least `limit` times and this is the tail, not the whole history — the
  # inference it would otherwise draw wrongly from a full array.
  #
  # `limit` reports WHICH BOUND APPLIED, not a constant. A narrowed window is bounded at
  # `SINGLE_BRANCH_HISTORY_LIMIT` and an unfiltered one at `HISTORY_LIMIT`, and serving the applied
  # bound is what keeps `returned == limit` meaning the same thing under both — a client that had to
  # know the rule to interpret the number would be reading a caption again.
  #
  # `order` NAMES BOTH KEYS, because the second one is load-bearing and is not served. The rows are
  # ordered `(created_at, id) DESC` — `Repository#recent_test_runs`' ordering, tie-break included —
  # and `ingested_at_desc` alone would invite exactly the re-sort the serializer refuses to do
  # itself: two runs ingested in the same instant carry the same `ingested_at`, so a client sorting
  # on that field alone scrambles the very pair the tie-break exists to order, and can disagree with
  # `latest_run` about which commit is newest. Narrowing the window does not re-sort it; the branch
  # predicate rides along with the same `ORDER BY`.
  #
  # `tie_break_served: false` is the honest half of that. The tie-break key is the ingest sequence —
  # the runs table's own id — and this endpoint does not serialize it on a row, here or on
  # `latest_run`. So the ordering is NOT reproducible from the fields the client holds, which makes
  # the array's own order the authoritative answer rather than a rendering of one. A client that
  # needs a stable comparison reads the array in the order it arrived; one that must re-sort can
  # only do so within a set of distinct `ingested_at` values.
  def serialized_history_window
    {
      order: "ingested_at_desc,ingest_sequence_desc",
      tie_break_served: false,
      branch_scope: requested_branch ? "single_branch" : "all_branches",
      branch: requested_branch,
      limit: history_limit,
      returned: history_runs.length
    }
  end

  # Which bound applies, decided in ONE place so the window's `limit` and the query's `LIMIT` cannot
  # come apart. A response stating a bound it did not apply is worse than either bound alone: the
  # client's `returned == limit` test — its only signal that there is more history behind the
  # window — would answer about a number nothing enforced.
  def history_limit
    requested_branch ? SINGLE_BRANCH_HISTORY_LIMIT : HISTORY_LIMIT
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
  #
  # AND IT IS THE ANSWER AN UNKNOWN `?branch=` GETS — never a fallback to the unfiltered window,
  # never another branch's rows. The human suite-size panel does fall back to its current anchor
  # when it is handed a branch it does not recognise, which is right for a page: the page renders a
  # visible notice beside the chart saying so. A JSON client has no notice. One that asked for
  # `main` and silently received `feature/x` rows would compute a growth series for the wrong
  # branch and have nothing in the body to detect it with — a two-branch error exactly as invisible
  # as the 0–1/0–100 ratio confusion `TestRun#annotated_fraction` guards against. So the ask is
  # restated in `history_window.branch`, `returned` says `0`, and the client can tell "that branch
  # has no runs" from "here is some other branch" because the second never happens.
  def serialized_history
    # The served order is named here rather than implied: `history_window` declares
    # `ingested_at_desc,ingest_sequence_desc`, and `newest_first` is that same statement at the
    # read. The window was BUILT newest first, so this is the memoized array itself — no copy, no
    # re-sort.
    history_runs.newest_first.map { |run| serialized_history_row(run) }
  end

  # What the human panel's row carries, plus the composition facts that say whether the row may be
  # differenced against its neighbour AND what each figure on it was measured over.
  #
  # TWO COUNTS AND NO COST FIGURE — deliberately not the whole `shards` sub-block
  # `LatestRunSerializer#serialized_shards` builds for the latest run. `machine_seconds` stays off
  # the row on the argument this comment has always made: a client differencing two rows needs to
  # know they were assembled from the same number of parts, not what each part cost, and the
  # per-run cost figures stay available in full on `latest_run`, which is one row and pays one
  # `pick` for them.
  #
  # `timed_shard_count` is the exception that argument never covered, and it is not "what a part
  # cost" — it is THE DENOMINATOR OF A FIGURE THIS ROW ALREADY SERVES. `duration_seconds` on a
  # sharded run is the MAX over the shards that REPORTED, so its coverage is the timed count and
  # never `shard_count`; a row serving the numerator beside the wrong denominator lets a client
  # difference four timed shards (MAX 600s) against four shards whose two slowest were cancelled
  # (MAX 180s) — identical `shard_count`, identical `suite_size_measured` — and report a 70%
  # speedup produced entirely by telemetry loss. That is the same honesty gap
  # `LatestRunSerializer#serialized_shards`' `coverage` block exists to close: a figure whose
  # coverage is inferred from a neighbour.
  #
  # `shard_count` is the right denominator for `total_specs` — a SUM over the shards RECORDED — and
  # is served for that reason; `TestRun#assembled_like?` decides differenceability on shard-count
  # equality alone, so this still serves exactly what that rule reads. The two counts are served
  # FLAT and side by side rather than under a `coverage:` sub-object, because the row is otherwise
  # flat and there are only two of them to keep straight.
  #
  # The three are cheap here only because `ShardCountPreloading` primes all of them from ONE grouped
  # aggregate over the whole window (see `history_runs`). What is left further down `shard_totals` —
  # `MAX(updated_at)` — is still one `pick` per row. The reason this row stops at the two counts is
  # now the semantic one alone: `machine_seconds` became affordable on a window when the repositories
  # grid needed it, and a client differencing two rows still needs to know they were assembled from
  # the same number of parts, not what each part cost.
  #
  # `suite_size_measured` is `TestRun#suite_size_measured?` — a run that reported zero tests has a
  # count but not a measurement, and a difference taken against it describes the report rather than
  # the suite. Serialized as the boolean rather than left for the client to re-derive from
  # `total_specs`, so the endpoint and the panel cannot drift on what "measured" means.
  #
  # Counts and booleans, never prose: `TestRun#delivery_description` and `#wall_clock_coverage` word
  # these same shard facts in English for the panel, and `LatestRunSerializer#serialized_shards`
  # already settled that a machine-readable client cannot act on a sentence without parsing it.
  def serialized_history_row(run)
    {
      commit_sha: run.commit_sha,
      # Per-row, and non-negotiable: this is the field that turns the interleaved history
      # `history_window.branch_scope` warns about into an actual series. It stays served under
      # `?branch=` too, where every row carries the same value — a client should be able to read a
      # row's branch off the row rather than off the window it arrived in, and a narrowed window's
      # rows are otherwise indistinguishable from an unfiltered window that happened to be uniform.
      # `null` keeps its `latest_run` meaning — "the client did not say" — and an anonymous run
      # belongs to no series, which is why no `?branch=` value can select one.
      branch: run.branch,
      total_specs: run.total_specs_count,
      annotated_specs: run.annotated_specs_count,
      # The 0–1 fraction, same call and same units as `latest_run` above and as `/ingest`.
      annotated_ratio: run.annotated_fraction,
      duration_seconds: run.duration_seconds,
      shard_count: run.shard_count,
      # A really-counted `0`, never absent and never null, on a run whose shards all went silent —
      # that run's `duration_seconds` was measured over nothing, and it is exactly the row a client
      # most needs to refuse to difference. A shardless run serves `0` beside a `shard_count` of
      # `0`, unchanged in meaning: there were no parts, so there were none to time.
      timed_shard_count: run.timed_shard_count,
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
  #
  # ONE grouped aggregate for the whole window primes BOTH of the row's counts on every row —
  # `COUNT(*)` for `shard_count` and `COUNT(duration_seconds)` for `timed_shard_count`, two columns
  # of the same `GROUP BY` rather than two queries — see `ShardCountPreloading`, shared with the
  # human panel, which asks the same question of the same rows and reads only the first of the three
  # facts the aggregate now carries. So `history` costs two queries at ten rows and the same two at
  # one, instead of one `pick` per row. A narrowed window primes identically: `preload_shard_counts`
  # keys off the ids it is handed and does not care how they were selected, so `?branch=` costs the
  # same two queries at thirty rows.
  #
  # The branch predicate is passed INTO the model call, and that placement is the whole feature. The
  # `WHERE` and the `LIMIT` have to be one query: bounding first and filtering the result is what
  # returns zero `main` rows on a repository whose ten newest runs are all feature branches, which
  # is precisely what a client was left to do before this. `Repository#recent_test_runs` carries
  # the rest of that argument, and the index it relies on.
  #
  # ONE window read, memoized, and its ORIENTATION IS THE QUERY'S: `recent_test_runs` orders
  # `(created_at, id) DESC` — newest first — so the rows are wrapped `RunWindow.newest_first` and
  # that fact travels with the object. Every reader below asks the window for the end it needs
  # (`history` serializes `newest_first`; the two anchor presenters ask `oldest_first`;
  # `UnstableTests` and `UnstableTestRuns` read it as handed) instead of each remembering which way
  # this array points.
  def history_runs
    @history_runs ||= RunWindow.newest_first(
      preload_shard_counts(
        repository.recent_test_runs(limit: history_limit, branch: requested_branch).to_a
      )
    )
  end

  # THE RUN THE CLIENT NAMED, or `nil` when it named none and `nil` when the one it named has no run
  # — the single source of truth for both halves of the anchor decision, so `latest_test_run` below
  # and `run_anchor.resolved` above cannot come apart.
  #
  # It exists because the fallback is otherwise UNOBSERVABLE once it has happened: `latest_test_run`
  # returns a row either way, and the only remaining way to ask "did the ask hit?" would be to
  # compare the served sha against the requested one — a re-derivation of a decision that was already
  # made, and one that reads as a coincidence check rather than as the fact it is standing in for.
  #
  # Memoized across the nil with `defined?` rather than `||=`, because `nil` — no ask — is the common
  # answer on this endpoint and both readers ask; `||=` would re-issue the finder on every default
  # call, which is the case this most needs to cost nothing.
  #
  # The `requested_commit_sha &&` guard is what makes the no-ask path issue NO QUERY AT ALL.
  # `Repository#latest_test_run_for_commit` returns `nil` for a blank on its own, so this is not
  # correctness — it is the difference between a default `GET` paying for a lookup it cannot use and
  # paying for nothing.
  def requested_test_run
    return @requested_test_run if defined?(@requested_test_run)

    @requested_test_run =
      requested_commit_sha && repository.latest_test_run_for_commit(requested_commit_sha)
  end

  # THE RUN THIS ENDPOINT DESCRIBES, memoized across the nil — the repository's newest run by
  # default, or the newest run on the sha `?commit_sha=` named. Read by `latest_run`, by `run_anchor`
  # and by BOTH run-over-run growth blocks above, which is why it is an accessor here and not several
  # calls to `Repository#latest_test_run` (which memoizes nothing and would issue the query once per
  # reader).
  #
  # Memoizing also makes the ONE INSTANCE shared, which is what keeps `assembled_like?` free: that
  # predicate reads `TestRun#shard_count`, which memoizes `shard_totals` PER INSTANCE, and
  # `latest_run.shards` has already paid for it on this row by the time the growth gate asks.
  #
  # NOT RE-ANCHORED BY `?branch=` — see `serialized_latest_run`, which states that at length.
  #
  # ⭐ RE-ANCHORED BY `?commit_sha=`, AND THIS IS THE ONLY PLACE THE ANCHOR IS CHOSEN. Every run-grain
  # block on the endpoint hangs off this one memo — `latest_run` and its five rollups, the three
  # drill-ins, `shards`, both growth windows' `anchor_commit_sha`/`branch`, and `previous_test_run`
  # below — so re-anchoring here is what makes them describe the named run COHERENTLY. A second place
  # SELECTING a run is how they would come to disagree about which run they are on, which is the one
  # failure this shape exists to make impossible: a client cannot be served a `latest_run` on one sha
  # and a growth window anchored on another.
  #
  # The parameter itself is read by `requested_test_run` above and echoed by `serialized_run_anchor`,
  # and neither is a second anchor: the first is the memo this one falls back FROM, and the second
  # reports the choice rather than making one. No serializer reads `requested_commit_sha` to pick a
  # row.
  #
  # `previous_test_run` follows without a change of its own. It is already "the newest run strictly
  # older than THIS one, on THIS one's branch", which is the right baseline for a named run for the
  # same reason it is for the newest one — and it reads the branch off whatever row this returns.
  #
  # FALLS BACK RATHER THAN 404s when the sha resolves to nothing, and the `||` is where that happens.
  # A stale bookmark, a pruned run and a commit whose CI never reported are ordinary ways to arrive,
  # so the endpoint answers with the run it would have answered with anyway — and `run_anchor`
  # DISCLOSES the fallback rather than leaving the client to infer it from a sha that did not match
  # the one it asked for.
  def latest_test_run
    return @latest_test_run if defined?(@latest_test_run)

    @latest_test_run = requested_test_run || repository.latest_test_run
  end

  # The run the latest one is compared against: the newest run STRICTLY OLDER than it ON ITS OWN
  # BRANCH. `nil` — never a fallback row — when there is no honest comparison to make, which
  # `Repository#previous_test_run_on_branch` argues for itself at length: the row immediately before
  # the latest one in the interleaved all-branch history is routinely a different branch, and a
  # difference taken against it reports a suite-size change no commit ever made.
  #
  # FREE WHEN THERE IS NOTHING TO ASK. That method returns `nil` before any read when the run is nil
  # or its branch is blank, so a repository CI has never reported on, and a run whose client sent no
  # branch, cost this endpoint nothing at all. Otherwise it is one indexed row lookup.
  #
  # THIS ROW IS NOT PRIMED, and that is a known second query rather than an oversight.
  # `SpecDirectoryGrowth`'s gate asks `TestRun#assembled_like?`, which reads `shard_count` on BOTH
  # sides; `latest_test_run` has already paid for its own `shard_totals` under `latest_run.shards`,
  # and this row is not in `history_runs` under every request — it is a different branch's row
  # whenever `?branch=` narrowed elsewhere, and outside the bound on a busy branch — so there is no
  # primed instance to read it off. `preload_shard_counts([previous_test_run])` would trade this
  # un-grouped `pick` for an equally-sized grouped read and buy nothing. One aggregate over one run's
  # shards, and `spec/requests/api/v1/repository_latest_run_spec.rb` pins the count so a third does
  # not appear unnoticed.
  #
  # Memoized across the nil with `defined?` rather than `||=` — `show` reads it twice through the
  # window block's `baseline_commit_sha` and the growth object below, and a `||=` would re-issue the
  # lookup on every repository that has no previous run, which is the case this most needs to be
  # cheap in.
  def previous_test_run
    return @previous_test_run if defined?(@previous_test_run)

    @previous_test_run = repository.previous_test_run_on_branch(latest_test_run)
  end

  # THE GROWTH FAMILY, one memoized collaborator per overview — see `RepositoryGrowthSerializer`.
  # ONE instance is load-bearing: its presenter accessors memoize per instance, so building one per
  # call would re-issue the previous-run `shard_totals` and layer reads and move the
  # `observation_reads` pins.
  def growth
    @growth ||= RepositoryGrowthSerializer.new(overview: self)
  end

  # THE FIVE READS THE GROWTH SERIALIZER MAKES BACK INTO THIS OBJECT, and this one statement is why
  # they are public: the run pair, the history window and the two asks (`requested_branch` and
  # `requested_spec_directory` come from the `Requested*Param` concerns, which read `params` — the
  # half of the collaboration the serializer deliberately does not hold). Same arrangement as the
  # `public :drill_ins, …` statement for `LatestRunSerializer` below; they were private
  # while the growth family lived in here, and the collaborator publishes them to that one
  # serializer and to nothing else. `public` needs the methods defined first, hence this position.
  public :latest_test_run, :previous_test_run, :requested_spec_directory, :requested_branch,
         :history_runs

  # THE RUN-LEVEL DRILL-IN FAMILY, one memoized collaborator per overview — see
  # `RunDrillInSerializer`. One instance is all `LatestRunSerializer` needs; it holds no state of
  # its own, so this memo only keeps it from being rebuilt for each of the twelve calls.
  def drill_ins
    @drill_ins ||= RunDrillInSerializer.new(overview: self)
  end

  # THE SURFACE `LatestRunSerializer` AND `RunDrillInSerializer` REACH BACK INTO THIS OBJECT FOR, and
  # this one statement is why it is public: `drill_ins` itself, and the asks the drill-in family reads
  # (`requested_limit`, `requested_layer`, `requested_spec_file`, `requested_repeated_description`,
  # `requested_unannotated_examples?` — `requested_spec_directory` is already published by the growth
  # statement above). They come from the `Requested*Param` concerns, which read `params` — the half
  # of the collaboration the serializers deliberately do not hold. `public` needs the methods
  # defined first, hence this position.
  public :drill_ins, :requested_limit, :requested_layer, :requested_spec_file,
         :requested_repeated_description, :requested_unannotated_examples?

  # THE BRANCH-WINDOW RANKING FAMILY (`unstable_tests` + `slowest_tests`), one memoized collaborator
  # per overview — see `RepositoryWindowRankingSerializer`. ONE instance is load-bearing: its two
  # branch gates memoize in instance variables and `show` reads each twice, so building one per call
  # would build the presenters again and double the reads the query-cost examples count.
  def window_rankings
    @window_rankings ||= RepositoryWindowRankingSerializer.new(overview: self)
  end

  # THE TWO READS THE WINDOW-RANKING SERIALIZER MAKES BACK INTO THIS OBJECT THAT THE STATEMENT ABOVE
  # DOES NOT ALREADY PUBLISH (`history_runs` and `requested_branch` are in it): `repository`, a
  # private `attr_reader` above, and `requested_unstable_test`, which comes from the
  # `RequestedUnstableTestParam` concern and reads `params`. Same arrangement as the statement above;
  # they were private while the ranking family lived in here, and the collaborator publishes them to
  # that one serializer and to nothing else. `public` needs the methods defined first, hence this
  # position.
  public :repository, :requested_unstable_test

  # The contract the `branches` catalogue is served under, on the same rule `history_window`
  # follows: the facts that decide how the array below may be read, as tokens rather than as the
  # sentences the human panel prints beneath its selector.
  #
  # THIS BLOCK IS WHY THE CATALOGUE IS TWO KEYS AND NOT ONE. The endpoint already established the
  # shape — an array beside the window it arrived through — and a catalogue that hid its bounds
  # inside its own rows would leave a client no place to learn that the list stops.
  #
  # `walk_limit` and `walk_cut` are the load-bearing pair, and they exist for the same reason
  # `branch_scope` does. `Repository#branch_histories` walks at most `Repository::BRANCH_HISTORY_LIMIT`
  # branches, and that walk is NAME-ORDERED by construction — it asks the index for the next branch
  # alphabetically — so past the bound the result is an alphabetical PREFIX of the repository, and
  # "most history first" is an ordering over the branches it reached rather than over the branches
  # there are. On a repository past the bound the trunk can be missing from a list that otherwise
  # looks complete, and a client with no way to detect that would read "`main` is not here" as
  # "`main` has no runs" — the exact inversion `Repository::BRANCH_HISTORY_LIMIT` documents.
  # `RepositoriesHelper#trajectory_listing_basis` says this to a reader in English; a machine client
  # cannot act on a sentence, so it is served as a bound and a boolean.
  #
  # `walk_cut` IS DERIVED WITH `>=`, NOT `==`, copied from `RepositoriesHelper#trajectory_walk_cut?`
  # rather than re-reasoned: a pinned branch is added to the walk's result, so a cut walk can hand
  # back MORE rows than its own bound. That is also why `returned` is not a substitute for this
  # flag — `returned` can exceed `walk_limit`, and comparing the two is the derivation that breaks.
  #
  # `run_count_limit` is where each row's `run_count` STOPS COUNTING, and it belongs on the window
  # because it is one fact about the whole block, while `run_count_capped` is per-row because
  # whether a given branch reached it is a fact about that branch. Read off `Repository`'s own
  # constant rather than off `SINGLE_BRANCH_HISTORY_LIMIT` above, which happens to hold the same
  # number for an unrelated reason: that one is a bound this controller CHOOSES between for
  # `history`, and this one is the model's own `runs:` default, which the catalogue takes as given.
  #
  # `tie_break_served: false`, the same admission `history_window` makes and for the same effect.
  # The order is `run_count` desc, then the branch's last run desc, then its name — and the middle
  # key is not a field on a row here. So the ordering is NOT reproducible from what a client holds:
  # two branches with equal counts carry nothing that says which the server put first. The array's
  # own order is the answer rather than a rendering of one, which is also why nothing below
  # re-sorts it.
  def serialized_branches_window
    {
      order: "run_count_desc,last_run_at_desc,name_asc",
      tie_break_served: false,
      run_count_limit: Repository::TRAJECTORY_LIMIT,
      walk_limit: Repository::BRANCH_HISTORY_LIMIT,
      walk_cut: branch_histories.length >= Repository::BRANCH_HISTORY_LIMIT,
      returned: branch_histories.length
    }
  end

  # The branch names this repository has runs on — the half of `?branch=` that makes the other half
  # usable, and the only key on this endpoint that answers "what may I ask for?".
  #
  # WITHOUT IT `?branch=` IS UNREACHABLE BY ANY CLIENT THAT DOES NOT ALREADY KNOW THE ANSWER. The
  # only branch names an API client ever sees otherwise are the per-row `branch` values in
  # `history`, and unfiltered that array is the ten-row INTERLEAVED window `history_window` warns
  # about — on a repository whose CI reports on every PR, all ten rows are routinely `feature/*` and
  # the trunk never appears in it. So learning a name required reading the one window that
  # systematically hides the name most clients want. Guessing gives no feedback either: an unknown
  # branch and an idle branch both answer `history: []` with the ask echoed back, byte for byte, so
  # a client cannot converge by probing. The human panel makes exactly this argument for itself —
  # *"a reader cannot ask for a branch they were never told exists"* — and loads its choices whether
  # or not a branch was asked for. This is served under the same rule, for the same reason: the
  # client that needs it most is the one that has not selected anything yet.
  #
  # ONE BOUNDED QUERY, and specifically not a `SELECT DISTINCT branch` over the whole run history,
  # which is the O(history) scan `Repository#branch_histories` documents at length for refusing. The
  # walk costs one index descent per BRANCH and none per run, so this key's cost follows branch
  # cardinality — which does not grow without bound — rather than the history, which does.
  #
  # SERVED IN THE MODEL'S ORDER, NEVER RE-SORTED. `branch_histories` returns most-history-first with
  # an explicit tie-break, and re-sorting here would make the array's order a rendering rather than
  # the answer — the mistake `tie_break_served: false` exists to keep this endpoint from making.
  #
  # NOT CUT TO A DISPLAY SIZE. `RepositoriesHelper::TRAJECTORY_BRANCH_CHOICES` cuts the human
  # selector to eight, and that number is about what a row of links can carry before it stops being
  # a way to find a branch. A JSON array has no such limit, and leaking a display bound into a
  # machine response would drop branches for a reason that does not apply to the reader.
  #
  # `branch IS NULL` runs are ABSENT, which the walk gives for free (see `BRANCH_HISTORY_SQL`). A
  # `null` branch is "the client did not say" — the meaning `latest_run.branch` and
  # `serialized_history_row` both pin — and the anonymous runs of every machine are not one branch.
  # Offering them a name here would offer a name `requested_branch` deliberately refuses to match.
  def serialized_branches
    branch_histories.map do |history|
      {
        name: history.name,
        # CAPPED at `run_count_limit`, and the cap is its own boolean rather than a rendered
        # `"30+"`. The human panel words it that way in a caption; this endpoint's standing rule is
        # tokens a client can compare rather than a caption it would have to read, and a client that
        # had to strip a `+` before comparing two counts would be parsing English again. The pair is
        # also the honest reading: the query STOPPED counting at the window the trajectory reaches,
        # so `run_count: 30, run_count_capped: true` says "at least thirty" without inventing a
        # figure nothing counted to, and `false` says the number is exact.
        run_count: history.run_count,
        run_count_capped: history.capped?
      }
    end
  end

  # The catalogue's rows, memoized: `show` reads them twice — once for the window's `returned` and
  # `walk_cut`, once for the array — and a second walk would double the key's cost for nothing.
  #
  # `Repository#branch_histories`' DEFAULTS ARE TAKEN AS GIVEN, and no bound is restated here. Both
  # numbers this response discloses are read straight off `Repository`, so the catalogue cannot come
  # to claim a bound the walk did not apply. It is also why this controller binds no third constant:
  # `Repository::BRANCH_HISTORY_LIMIT` (branches) and `Repository::TRAJECTORY_LIMIT` (runs) are two
  # different quantities already, `SINGLE_BRANCH_HISTORY_LIMIT` above is a third reading of the
  # second, and a locally-named fourth would say a word this file already uses for something else.
  #
  # `pinned:` CARRIES THE REQUESTED BRANCH, so a client that filtered on a branch can find that
  # branch in the same response that filtered on it. The walk's bound is alphabetical, so past it a
  # response could otherwise serve thirty `main` rows in `history` while omitting `main` from the
  # list of branches that have runs — one body contradicting itself. Pinning cannot invent a branch:
  # `WHERE tail.run_count > 0` drops a pinned name with no runs behind it, which is the same answer
  # an unknown `?branch=` gets in `history` and the correct one here. `Array(pinned).compact` in the
  # model makes the unfiltered case (`[nil]`) the same call as passing nothing.
  def branch_histories
    @branch_histories ||= repository.branch_histories(pinned: [requested_branch])
  end
end
