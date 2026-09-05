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
  # second flag-style `Requested*Param` this object reads, and the one whose cost is the whole
  # reason it exists. `NearDuplicateClusters` is linear but measured at seconds, not
  # milliseconds — the class comment carries the table — so the ask is what confines the cost to
  # the client that named it. See `RequestedNearDuplicatesParam`, which holds the reasoning in
  # full, including why `?near_duplicates=false` is an ask like any other.
  include RequestedNearDuplicatesParam

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
      # `history` is served over. See `serialized_unstable_tests_window`.
      unstable_tests_window: serialized_unstable_tests_window,
      unstable_tests: serialized_unstable_tests,
      # BESIDE `unstable_tests` and NOT inside `latest_run`, on that block's own membership rule:
      # `latest_run` is single-run facts by construction, and this is a statement about ONE TEST
      # ACROSS SEVERAL RUNS. `latest_run.slowest_examples` is the same question at single-run grain
      # and stays exactly where it is — this is its complement, not its replacement.
      #
      # It is the DURATION axis of what `unstable_tests` does for the OUTCOME axis — both are
      # matched to a DURABLE TEST. That block groups on `spec_identity_id`, so an annotated test
      # that was REWORDED keeps its outcome history there, and this one groups on
      # `spec_identity_id` too, so a test that MOVED or was REWORDED keeps its runtime history. See
      # `serialized_slowest_tests_window`.
      slowest_tests_window: serialized_slowest_tests_window,
      slowest_tests: serialized_slowest_tests,
      # BESIDE `unstable_tests` and for the same structural reason it sits out here: a statement
      # about the WINDOW rather than about one run. `history` serves how the suite grew — one total
      # per run, no area grain on any row — and `latest_run.spec_directories` serves the area grain
      # of exactly one run. An agent holding every other key on this endpoint can compute THAT the
      # suite grew and never WHERE, which is the half of the roadmap's second axis ("how the suite
      # has grown over time and in which areas") nothing here answered. See
      # `serialized_directory_growth_window`.
      directory_growth_window: serialized_directory_growth_window,
      directory_growth: serialized_directory_growth,
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
      directory_run_growth_window: serialized_directory_run_growth_window,
      directory_run_growth: serialized_directory_run_growth,
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
      directory_runtime_growth_window: serialized_directory_runtime_growth_window,
      directory_runtime_growth: serialized_directory_runtime_growth,
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
      directory_run_file_growth_window: serialized_directory_run_file_growth_window,
      directory_run_file_growth: serialized_directory_run_file_growth,
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
      directory_runtime_file_growth_window: serialized_directory_runtime_file_growth_window,
      directory_runtime_file_growth: serialized_directory_runtime_file_growth,
      # SERVED ON THE ASK AND NEVER WITHOUT IT — `NearDuplicateClusters` is linear but measured in
      # seconds rather than milliseconds (seven queries at every size; its class comment carries the
      # table), so this is the one block on this endpoint whose cost had to be opted into rather
      # than bounded. `?near_duplicates=` is the ask, and a client that does not send it gets the
      # key present and `null` — the no-ask spelling every gate on this endpoint uses — and pays
      # not one query for it. See `serialized_near_duplicates`.
      near_duplicates: serialized_near_duplicates,
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
  def serialized_delivery_health
    {
      refusing: rejected_ingests.refusing?,
      last_rejection_at: rejected_ingests.last_rejection_at&.iso8601,
      rejections_window: {
        limit: IngestRejection::PANEL_LIMIT,
        bounded: rejected_ingests.bounded?,
        retention_rows: IngestRejection::REPOSITORY_RETENTION_ROWS,
        any_reasons_truncated: rejected_ingests.truncated_rows?
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
    # THE RETIREMENT SPLIT, taken in Ruby off the ONE SELECT: stranded keys are a LIVE-keys
    # question (a key rotated and THEN revoked is both, and the revocation is the newer fact —
    # reporting it as merely rotated would understate the state a client needs to act on), and the
    # presented-revoked half reads the retained rows a `WHERE` would have filtered out. One query,
    # as before; `rotated_and_unused?`'s comment carries the rule against re-expressing that
    # predicate in SQL.
    keys = repository.api_keys.to_a
    stranded = keys.reject(&:revoked?).select(&:rotated_and_unused?)
    presented_revoked = keys.select(&:revoked_and_still_presented?)

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
  def serialized_ingest_rejection_row(rejection)
    {
      occurred_at: rejection.occurred_at.iso8601,
      reported_client: rejection.reported_client,
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

  # WHICH FILE the run spent its wall clock in — the same decomposition `repositories#show` has
  # rendered since SPGD-275, served to the client that has no page to read.
  #
  # This is `LatestRunSerializer#serialized_shards`' argument one axis over, and the substitution
  # is exact. The scalars above say a run cost 253.75s; not one of them is a file, so an agent
  # reading only those cannot learn WHERE the suite is slow — it can learn that it is.
  # And a shard is not the answer: a shard
  # is a CI partition, `TestRun#shard_durations`' own comment is explicit that it is not a code
  # area, and "shard 3 was slow" names a machine while "spec/models/invoice_spec.rb was slow" names
  # something a reader can go and edit.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query. `SpecFileDurations` is already
  # view-free — `repositories_controller.rb` is its only other caller — so the API and the panel
  # rank the same files in the same order off the same rows of the same run, which is this file's
  # governing rule at the top and the one thing a second copy of the query could not promise.
  #
  # `rows` MIRRORS `SpecFileDurations#rows` VERBATIM and re-sorts nothing, on the rule
  # `LatestRunSerializer#serialized_shard_rows` follows: the aggregate orders
  # `SUM(duration_seconds) DESC NULLS LAST, spec_file_path ASC`, and that NULLS LAST is
  # load-bearing rather than incidental — a re-sort
  # here on a plain `desc` would put the file that reported NOTHING at the head of a list whose
  # whole contract is "heaviest first". Inheriting the order is what makes `rows.first` and the
  # panel's heaviest file the same file by construction instead of by coincidence.
  #
  # STRUCTURED COUNTS, NOT PROSE, the rule `LatestRunSerializer#serialized_shards` states and
  # this block obeys one grain down. `Row#coverage_label` words this same coverage as `"4 of 12"`
  # and `#duration_label`
  # words the total as `"1.23s"` / `"not reported"`; a machine-readable client cannot act on either
  # without parsing it. So `recorded_count` and `timed_count` go out as the integers those
  # sentences are built from and `total_seconds` as a raw float. This is also how the honesty
  # constraint is met PER ROW rather than only for the block: `SUM` skips NULLs silently, so a file
  # whose examples were half untimed reports a total covering half of it, and every row states what
  # its own total was summed over instead of leaving one caption to cover a list of mixed coverage.
  #
  # `total_seconds` is `null`, NEVER `0.0`, for a file none of whose examples reported a timing —
  # `duration_seconds` above and `shards.machine_seconds` already follow this rule, and
  # `SpecObservation.file_durations_in` deliberately uses `pluck` over `group(...).sum` so the SQL
  # NULL survives the trip rather than being helpfully zeroed on the way. A measured `0.0` is a
  # measurement; "nobody reported" is not, and the row still carries its counts so a client can see
  # which it got.
  #
  # `file_count` IS NOT `rows.size`, and serving only the array would reintroduce the exact lie the
  # aggregate was widened to close. The list stops at `HEAVIEST_FILES_LIMIT`, so its own length
  # cannot tell "the 10 heaviest of 300" from "all 3 this run touched" — a truncated list silently
  # wearing the shape of a complete one. `COUNT(*) OVER ()` is evaluated after `GROUP BY` and
  # before `LIMIT` precisely so this figure comes back on every row of the same pass, which is also
  # why it cannot describe a different row set from the one listed.
  #
  # `limit` beside it is the bound that PRODUCED the list, so a client learns that it stopped
  # without knowing this constant. Read off `SpecObservation`'s own constant rather than restated
  # here, on the precedent `branches_window.run_count_limit` sets: the model's default is taken as
  # given, and a locally-bound fourth number would let the response claim a bound the query did not
  # apply. `file_count > limit` is how a client detects truncation, which is `#truncated?` without
  # this endpoint shipping the comparison instead of the operands.
  #
  # `null` — THE KEY STILL PRESENT — for a run that recorded no observation rows at all: one
  # ingested before SPGD-255, or one whose client sends no per-example detail. Never a zeroed
  # block, on `shards`' rule verbatim: a client tests one thing (`spec_files == null` → "this run
  # disclosed no per-example grain") rather than distinguishing an absent key from a null one, and
  # a `file_count: 0` beside an empty array would assert a run that touched no spec files.
  #
  # GATED ON `#recorded?` ITSELF — called, not re-spelled as `rows.any?` here. The object's own
  # answer to its own question: a group exists in that aggregate if and only if a row exists, so
  # the predicate and the emptiness of `rows` cannot come apart, and a controller re-spelling it
  # would be a second copy free to drift the day the presenter learns to hold rows it did not read.
  #
  # EXACTLY ONE EXTRA QUERY, on every run, recorded or not — and constant in the size of the suite.
  # `SpecFileDurations.for` issues `file_durations_in` unconditionally, so `#recorded?` is an answer
  # DERIVED from the read rather than a gate in front of it; there is no cheaper way to ask, since
  # no counter cache exists on `test_runs`. That is the honest cost and it is stated as constant
  # rather than minimal: one grouped aggregate behind
  # `index_spec_observations_on_test_run_id_and_spec_file_path`, EXPLAIN-certified in
  # `spec/models/spec_observation_spec.rb`, so a 20,000-example suite costs exactly what a
  # 40-example one does. It sits inside the budget `LatestRunSerializer#serialized_shards` states.
  def serialized_spec_files(test_run)
    limit = requested_limit || SpecObservation::HEAVIEST_FILES_LIMIT
    durations = SpecFileDurations.for(test_run, limit: limit)

    return nil unless durations.recorded?

    {
      rows: durations.rows.map do |row|
        {
          path: row.path,
          total_seconds: row.total_seconds,
          recorded_count: row.recorded_count,
          timed_count: row.timed_count
        }
      end,
      file_count: durations.file_count,
      # The APPLIED limit, never the ask verbatim: an over-large ask is clamped by the guard, and
      # `file_count > limit` is how a client detects truncation — a `limit` the response did not
      # honour would make that comparison lie in exactly the direction the field exists to prevent.
      # Beside `file_count`, counted before the LIMIT and exact, the two operands of the disclosure
      # travel together.
      limit: limit
    }
  end

  # WHERE the wall clock went, by code AREA — the block above one rung up, and the same
  # decomposition `repositories#show` has rendered on its by-directory panel. Added BESIDE
  # `spec_files` rather than in place of it, on this endpoint's standing rule: a client reading
  # `spec_files` today reads the same key, type and values tomorrow.
  #
  # NOT DERIVABLE FROM THE BLOCK ABOVE, which is the whole reason it is served at all. That list
  # stops at `HEAVIEST_FILES_LIMIT`, so an agent holding it has ten files out of a run that may
  # have touched three hundred — and `SpecDirectoryDurations`' own comment states the arithmetic:
  # *"a directory holding forty files at two seconds each is eighty seconds of the run with not one
  # of its rows in that list. Concentration re-concentrates at every rung."* Summing the ten files
  # a client can see by their parent directory answers a different question from summing the run.
  # And a shard is not the substitute either — `TestRun#shard_durations`' comment is explicit that
  # a CI partition is not a code area.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query — this file's governing rule,
  # stated in full on `serialized_spec_files` above. `SpecDirectoryDurations` is view-free, so the
  # API and the panel rank the same areas in the same order off the same rows of the same run.
  #
  # Every rule `serialized_spec_files` states applies here unchanged and is NOT restated: the
  # `null`-with-the-key-present shape, the `#recorded?` gate, structured counts over labels,
  # `total_seconds` never coalesced to `0.0`, `directory_count` off the window function rather than
  # `rows.size`, and the inherited order. Read them there. They are one behaviour described once,
  # and a second copy here is a second thing to keep true.
  #
  # What the grain changes is only what each of those costs when it is got wrong, and every one
  # costs MORE here: an area is a bigger population than a file, so an all-untimed area rendered as
  # `0.0` is a bigger invented measurement, and NULLS FIRST would name it the heaviest area in the
  # suite rather than merely the heaviest file.
  #
  # EXACTLY ONE EXTRA QUERY, on every run, recorded or not — and constant in the size of the suite.
  # `SpecDirectoryDurations.for` issues `directory_durations_in` unconditionally, so `#recorded?` is
  # an answer DERIVED from the read rather than a gate in front of it; there is no cheaper way to
  # ask, since no counter cache exists on `test_runs`. It needs no index of its own: the read groups
  # on an EXPRESSION and narrows on a COLUMN, and only the second decides the access path, so
  # `index_spec_observations_on_test_run_id` serves it — EXPLAIN-certified at the 20-run seed in
  # `spec/models/spec_observation_spec.rb` rather than asserted here.
  def serialized_spec_directories(test_run)
    limit = requested_limit || SpecObservation::HEAVIEST_DIRECTORIES_LIMIT
    durations = SpecDirectoryDurations.for(test_run, limit: limit)

    return nil unless durations.recorded?

    {
      rows: durations.rows.map do |row|
        {
          path: row.path,
          total_seconds: row.total_seconds,
          recorded_count: row.recorded_count,
          timed_count: row.timed_count,
          # The third figure of the area-grain reading, served as the OPERANDS the panel states it
          # from and never as the density itself. `COUNT(DISTINCT name)` skips NULLs, so
          # `distinct_name_count` alone is a ratio a client would compute against the wrong
          # denominator — over `recorded_count`, which includes rows the count could not see, an
          # area whose producer sent no descriptions reads as total redundancy. `named_count` is
          # what it WAS counted over, so a client divides by the same figure the panel does and can
          # subtract to see what was excluded. No verdict here for the same reason there is none on
          # the Row: the reading is the client's.
          distinct_name_count: row.distinct_name_count,
          named_count: row.named_count
        }
      end,
      directory_count: durations.directory_count,
      # The APPLIED limit, never the ask verbatim — the same rule `serialized_spec_files` states
      # for its own `limit`, not restated here beyond noting the two must agree in kind: both are
      # clamped by the same guard, and both sit beside a count taken before the LIMIT.
      limit: limit
    }
  end

  # WHICH TESTS ARE SLOW — the per-EXAMPLE grain, and the one question the two blocks above are
  # structurally unable to answer. They rank populations; this ranks individuals, and an agent that
  # has learned `spec/models/` cost ninety seconds has no way to get from there to a test to open.
  # `repositories#show` has rendered this list since SPGD-266; it has never reached a client that
  # cannot read a panel.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query — this file's governing rule,
  # stated in full on `serialized_spec_files` above. `SlowestExamples` is view-free, so the API and
  # the panel rank the same examples of the same run in the same order, off the same two reads.
  #
  # OPERANDS, NEVER THE PANEL'S LABELS, and this grain is where that rule costs the most. Every row
  # this serializes has four label methods one call away — `SpecObservation#label`,
  # `#location_label`, `#duration_label`, `#outcome_label` — and each of them FOLDS A FALLBACK
  # STRING INTO THE VALUE ("not reported", `"path:line"`, `"1.5s"`). That is precisely the prose
  # this endpoint refuses: a client cannot subtract `"1.5s"` and cannot tell `#label`'s location
  # fallback from a test genuinely named after its own file. So:
  #
  #   - `name` is NULLABLE and serialized as `null` when absent, rather than substituted with
  #     `#label`'s location fallback. `Ingest::ObservationRecorder#attributes` writes it through
  #     `presence_of`, so a null is the honest record that the producer sent no description — and a
  #     client that wants the fallback can build it from the two path operands below.
  #   - `file_path` + `line_number` are the DEFINITION SITE and are served as two operands rather
  #     than as the joined string `#location_label` builds from them.
  #   - `spec_file_path` is the INCLUDING file, nullable, and it is what makes this block JOINABLE:
  #     it is the column the two rollups above aggregate on, so a client can carry a ranked test
  #     back to the rollup row it belongs to. `SpecObservation`'s "Two paths, two meanings" note is
  #     explicit that it and `line_number` are NOT one coordinate — keep all three distinct and let
  #     the client choose, rather than pairing two of them here.
  #   - `outcome` is a NULLABLE RAW STRING, echoed verbatim. `null` keeps its documented meaning
  #     "the client did not say" and must never be folded into `"passed"`; nothing platform-side
  #     validates the column (`Ingest::Payload` does not), so an unrecognised string is echoed too.
  #
  # `recorded_count` / `timed_count` / `limit` follow `serialized_spec_files` exactly — what the
  # ranking was taken over, and the bound that cut the list, read off `SpecObservation::SLOWEST_LIMIT`
  # rather than restated here.
  #
  # `reported_outcome_count` IS NOT SCOPE CREEP, and it is the one figure the by-file blocks have no
  # counterpart for. Outcome coverage OVER THE RUN is not derivable from the ten rows served: a
  # client seeing ten `null` outcomes cannot tell "this run reported no outcomes at all" from "these
  # ten happened to be silent", and only the first of those makes a zero `failed` count mean
  # silence rather than health. That is the Vacuous Green separation `SlowestExamples#outcomes_reported?`
  # exists for, and the count is already in hand at zero extra query cost — `SlowestExamples.for`
  # splats the whole of `SpecObservation::COVERAGE_COUNTS`. Its `failed_count` / `pending_count` /
  # `other_outcome_count` siblings are deliberately NOT served: they describe the run's outcome
  # composition, not this ranking's coverage, and belong with a run-level health block.
  #
  # `null` — with the key still present — for a run that recorded no observation rows, on `shards`'
  # rule verbatim, and never a zeroed block: a `recorded_count: 0` beside an empty array would
  # assert a run that ran no examples. GATED ON `#recorded?` ITSELF, called rather than re-spelled
  # as `rows.any?`: the predicate is `recorded_count.positive?` and separates "no rows" from "no
  # timings", and a run that recorded fifty examples and timed none of them has a real per-example
  # grain to disclose — with an empty ranking over it — which `rows.any?` would blank.
  #
  # EXACTLY TWO EXTRA QUERIES, on every run, recorded or not — and constant in the size of the
  # suite. `SlowestExamples.for` issues both unconditionally, so `#recorded?` is an answer DERIVED
  # from the reads rather than a gate in front of them: an indexed backward scan capped at
  # `SLOWEST_LIMIT`, and one aggregate over the same index's leading column, both behind
  # `index_spec_observations_on_test_run_id_and_duration_seconds` and both EXPLAIN-certified in
  # `spec/models/spec_observation_spec.rb`. This block issues the read the panel issues, unchanged,
  # so that certification transfers rather than needing to be repeated in a request spec.
  def serialized_slowest_examples(test_run)
    slowest = SlowestExamples.for(test_run)

    return nil unless slowest.recorded?

    {
      rows: slowest.rows.map do |observation|
        {
          name: observation.name,
          file_path: observation.file_path,
          line_number: observation.line_number,
          spec_file_path: observation.spec_file_path,
          duration_seconds: observation.duration_seconds,
          outcome: observation.outcome,
          # THE LAYER THE TEST'S OWN ANNOTATION DECLARED — one of the four `open-test-intent` enum
          # tokens (`unit` / `integration` / `request` / `system`), or `null`.
          #
          # THIS IS THE COLUMN'S FIRST AND ONLY READER, AND IT SHIPPED WITH THE COLUMN ON PURPOSE.
          # `db/migrate/20260811120000_create_spec_identities.rb` refused the field with a condition
          # rather than a flat no — *"a column nothing reads is a column that will be read wrongly
          # later"* — so `intent_layer` was not allowed to exist without a caller. Serving it here
          # is that condition being met, not a convenience bolted onto a storage change.
          #
          # SERVED RAW, NEVER WORDED. The stored string is already a bounded token that
          # `Ingest::Payload#validate_intent` checked against the schema's enum before the run was
          # accepted, so a client can branch on it, group by it, and compare it across runs. Passing
          # it through a humanising helper the way `outcome` has `SpecObservation#outcome_label`
          # would turn a machine-readable axis into prose an agent has to parse back — and this
          # endpoint exists for the reader that cannot look at a panel.
          #
          # WHY THIS BLOCK AND NOT `unannotated_examples`. That block's population is BY DEFINITION
          # the rows carrying no layer, so serving the key there would be a column of guaranteed
          # nulls. This ranking spans annotated and unannotated rows alike — it ranks on duration and
          # filters on nothing else — so the key is informative on some rows and honestly null on
          # others, which is the only shape in which "which layers is this suite's slowest work in?"
          # is answerable at all.
          #
          # `null` IS A REAL ANSWER AND IS KEPT DISTINGUISHABLE FROM A VALUE — the key is always
          # present, never omitted for a row that has no layer. It carries TWO readings this block
          # cannot separate and must not pretend to: the example is unannotated (it declared no
          # layer, and the envelope requires `intent` to be ABSENT when `status` is `"unannotated"`),
          # or it was ingested before this column existed and cannot be given one retroactively. In
          # neither case is a default admissible: substituting a directory guess would serve an
          # inference in the field reserved for a declaration, and substituting `""` would make "not
          # declared" indistinguishable from a layer named by the empty string.
          intent_layer: observation.intent_layer
        }
      end,
      recorded_count: slowest.recorded_count,
      timed_count: slowest.timed_count,
      reported_outcome_count: slowest.reported_outcome_count,
      limit: SpecObservation::SLOWEST_LIMIT
    }
  end

  # WHICH DESCRIPTIONS ONE RUN RECORDED MORE THAN ONCE, ranked by the wall clock those examples cost
  # between them — the ⭐overcoverage reading `repositories#show` has rendered since SPGD-344,
  # carried here so it reaches a client that cannot read a panel.
  #
  # INSIDE `latest_run` rather than beside it, on the membership test the comment on
  # `unstable_tests` states in full: every key that block serves is a statement about ONE run's
  # rows, and "this test is unstable" is a statement about one test across several.
  # `RepeatedDescriptions.for` narrows both of its reads to a single `test_run_id`, so this is a
  # statement about one run's rows and belongs inside `latest_run` with every other block that
  # meets it.
  #
  # STATED AS A RULE, NOT AS A TALLY, on purpose. The claims above used to carry a count of the
  # run-grain blocks — accurate when written, falsified as each later block was added below them.
  # The paragraph directly below carries a count as well, and it stays accurate: it counts the
  # blocks positioned ABOVE this point, which nothing added below can change. That is the
  # discriminator, and the reason the rewrite stopped where it did — a count of set membership rots
  # when a member joins it, and a count of position above a fixed point does not. Every run-grain
  # block added after this one has landed below it.
  #
  # THE GRAIN IS THE DESCRIPTION, which is a grain none of the four blocks above can reach. They
  # roll a run's rows up by where the code LIVES — the example, its file, its area — and no
  # rollup of "where" can see that two of those rows claim to test the same thing. The measurement
  # existed nowhere before that panel: no read in this application groups examples by description
  # outside failures — the flakiness panel groups on `spec_identity_id`, and identity is not a
  # description — so on a green suite, the normal case, nothing grouped examples by description at
  # all.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query — this file's governing rule,
  # stated in full on `serialized_spec_files` above. `RepeatedDescriptions` is view-free, so the
  # API and the panel rank the same descriptions of the same run in the same order, off the same
  # two reads.
  #
  # OPERANDS, NEVER THE PANEL'S PROSE, and every row here has two label methods one call away.
  # `Row#duration_label` renders `"1.23s"` or `"not reported"` and `Row#coverage_label` renders
  # `"6 of 8"`; a client can subtract neither. So `total_seconds` is the raw float — `null`, never
  # `0.0`, for a group nothing timed, which `Row#timed?` exists to keep distinguishable — and
  # `recorded_count` / `timed_count` are the two integers that fraction is built from. `files_seen`
  # is served through the row's own accessor, which is `Array()`-normalized and sorted, so the
  # `ARRAY_AGG … FILTER` SQL NULL cannot leak into the JSON as a bare `null` element.
  #
  # `group_count` beside `limit`, on the rule `spec_files` states: `rows.size` cannot tell "the 10
  # costliest of 80" from "all 3", and `group_count` is the `COUNT(*) OVER ()` counted after the
  # `HAVING` and before the `LIMIT`, so it counts every repeated description however few come back.
  # `limit` is READ OFF `SpecObservation::REPEATED_DESCRIPTIONS_LIMIT` rather than restated here, on
  # the precedent `history_window.run_count_limit` and `slowest_examples.limit` set. The operands,
  # never `#truncated?` — this endpoint ships figures a client compares, not comparisons.
  #
  # THE THREE HONESTY FIGURES ARE THE POINT OF THE BLOCK, and they are why an empty `rows` here
  # carries more keys than an empty ranking one grain up. `#recorded?`, `#named?` and `#any?` are
  # three different facts — the object's class comment says so in those words — and an empty
  # ranking over a run that wrote NO rows, an empty ranking over a run whose producer sent no
  # descriptions, and an empty ranking over a suite whose every description is unique are the same
  # empty list. Only the first two are silence, and reporting any of them as "no redundancy here"
  # is *Vacuous Green*. So `recorded_count` says how many rows the run wrote, `unnamed_row_count`
  # says how many of them the grouping could not see (they are excluded in SQL, so no window over
  # that read could ever have counted them — hence the second query), and the client holds
  # `named_row_count`'s two operands without this endpoint shipping the subtraction.
  #
  # `repeated_recorded_count` / `repeated_timed_count` are the window pair, over the WHOLE repeated
  # population rather than over the head that fit, which is what keeps a truncated run from reading
  # as fully timed on the strength of ten rows.
  #
  # NO VERDICT KEY. A description carried by several examples is evidence of repetition AND the
  # ordinary shape of a table-driven loop or a shared example group; the object deliberately has no
  # `#redundant?` and this response has no counterpart. It presents, and does not judge.
  #
  # `null` — with the key still present — for a run that recorded no observation rows, on
  # `slowest_examples`' rule verbatim, and never a zeroed block: a `recorded_count: 0` beside an
  # empty array would assert a run that ran no examples. GATED ON `#recorded?` ITSELF, called
  # rather than re-spelled as `rows.any?`: a run that recorded five hundred examples whose every
  # description is unique has a real description grain to disclose, with an honest empty ranking and
  # a zero `group_count` over it, and `rows.any?` would blank exactly that run.
  #
  # RE-SORTED NOWHERE. The order is the aggregate's `SUM(duration_seconds) DESC NULLS LAST, name
  # ASC` — a group nobody timed sorts LAST rather than heading a list about what repetition cost.
  #
  # EXACTLY TWO EXTRA QUERIES, on every run, recorded or not — and constant in the size of the
  # suite. `RepeatedDescriptions.for` issues both unconditionally, so `#recorded?` is an answer
  # DERIVED from the reads rather than a gate in front of them: one grouped aggregate behind
  # `index_spec_observations_on_test_run_id`, and one two-column count over the same narrow. Both
  # are EXPLAIN-certified in `spec/models/spec_observation_spec.rb`, and this block issues the
  # panel's reads unchanged, so that certification transfers rather than needing to be repeated in
  # a request spec.
  def serialized_repeated_descriptions(test_run)
    repeated = RepeatedDescriptions.for(test_run)

    return nil unless repeated.recorded?

    {
      rows: repeated.rows.map do |row|
        {
          name: row.name,
          total_seconds: row.total_seconds,
          recorded_count: row.recorded_count,
          timed_count: row.timed_count,
          files_seen: row.files_seen
        }
      end,
      group_count: repeated.group_count,
      recorded_count: repeated.recorded_count,
      unnamed_row_count: repeated.unnamed_row_count,
      repeated_recorded_count: repeated.repeated_recorded_count,
      repeated_timed_count: repeated.repeated_timed_count,
      limit: SpecObservation::REPEATED_DESCRIPTIONS_LIMIT
    }
  end

  # WHICH FILES ONE AREA HOLDS — the middle rung of area → file → example, and the one move an
  # agent holding every other key on this endpoint could not make. `spec_directories` above names
  # the ten areas the run spent its wall clock in and stops there; `spec_files` is a capped ten of
  # the run's own heaviest files, and `SpecDirectoryDurations`' comment states why that is not the
  # same list under another name — *"a directory holding forty files at two seconds each is eighty
  # seconds of the run with not one of its rows in that list"*. The heaviest AREA is exactly the one
  # whose files a by-file top ten cannot show. `slowest_examples` reaches the per-example grain only
  # for the ten examples that are slowest RUN-WIDE, so for every other area the sentence its own
  # comment opens with — *"an agent that has learned `spec/models/` cost ninety seconds has no way
  # to get from there to a test to open"* — was still true after that block shipped.
  #
  # INSIDE `latest_run` rather than beside it, on the membership test the comment on
  # `unstable_tests` states in full: every key this block serves is a statement about ONE run's
  # rows. `SpecDirectoryFiles.for` narrows to a single `test_run_id`, so it belongs with the other
  # five. And `latest_run` is not re-anchored by `?branch=`, so an area ask composes with a branch
  # ask without either touching the other. It IS re-anchored by `?commit_sha=`, and this drill-in
  # follows it there WITHOUT READING THE PARAMETER: both hang off the one `latest_test_run` memo, so
  # the rows here and the `latest_run` they are an area OF can never come from two different runs.
  # Which run that is, `run_anchor` says. It is the repository's newest one only on a default call,
  # and on an explicit ask this list is STILL the panel's: `RepositoriesController` reads
  # `?commit_sha=` through this same `RequestedCommitShaParam` — the comment beside its own include
  # is the corroboration — so both surfaces re-anchor on the run the client named.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query — this file's governing rule, stated
  # in full on `serialized_spec_files` above. `SpecDirectoryFiles` is view-free, so the API and the
  # panel list the same files of the same area of the same run, in the same order, off the one read.
  #
  # OPERANDS, NEVER THE PANEL'S LABELS, on the rule `serialized_repeated_descriptions` states.
  # `Row#duration_label` and `Row#coverage_label` are both one call away and both fold prose into a
  # value: an untimed file renders "not reported", which a client must receive as `null` rather than
  # as a string it would have to recognise, and `"1 of 3"` is two integers a client cannot subtract.
  #
  # `null` — with the key present — MEANS "YOU DID NOT ASK", and it is the one thing this key must
  # not spell the way its siblings do. Those are served unconditionally and gate on `#recorded?`;
  # copying that gate here would collapse two different facts into one spelling — *"you did not
  # ask"* and *"the area you asked about has no rows"* — which is precisely the collapse
  # `serialized_history` refuses for an unknown `?branch=`, where the ask is RESTATED beside a zero
  # rather than answered with somebody else's rows. So an ask that matched nothing gets the block
  # with `rows: []` and its `path` restated, and a client can tell the two apart because the second
  # never wears the first's spelling. An area a run recorded nothing for is an ordinary answer — a
  # stale bookmark, a directory deleted since, a typo — and never an error, as
  # `RequestedSpecDirectoryParam` argues for the malformed shapes it treats as no ask at all.
  #
  # `file_count` is the AREA's, off the read's `COUNT(*) OVER ()` and never `rows.size`, which is
  # the truncated figure — the rule `spec_files.file_count` states one grain up. `recorded_count`
  # and `timed_count` are the area's too, off the two `SUM(COUNT(...)) OVER ()` windows, so they
  # describe the population the list was cut from rather than the files that fit on the page. A
  # client that folded the serialized rows to re-derive either would be computing the page's figure
  # under the area's name, which is the figure `SpecDirectoryFiles#any_timed?` exists to refuse.
  # `limit` is READ OFF `SpecObservation::SPEC_DIRECTORY_FILES_LIMIT` rather than restated, on the
  # precedent every capped block here sets — it is its own constant and neither of the tens above.
  #
  # EXACTLY ONE ADDITIONAL QUERY WHEN ASKED, AND NONE WHEN NOT — which is where this key departs
  # from `spec_directories`, whose read is issued on every request so that `#recorded?` is an answer
  # derived from it. Here the gate is the ASK and it is decided before any query is issued, so a
  # client that never sends the parameter pays nothing for the key's existence. The read is bounded
  # by the size of the AREA rather than of the suite and needs no index of its own: it narrows on
  # `test_run_id` and adds an EXPRESSION predicate no index can serve, so
  # `index_spec_observations_on_test_run_id` serves it — EXPLAIN-certified at the 20-run seed in
  # `spec/models/spec_observation_spec.rb`, which is where a plan belongs.
  def serialized_spec_directory_files(test_run)
    return nil if requested_spec_directory.nil?

    files = SpecDirectoryFiles.for(test_run, requested_spec_directory)

    {
      # The ask, restated as the server read it — never echoed from the raw parameter, on
      # `history_window.branch`'s rule: a malformed shape is no ask at all and reaches no block, so
      # what is served here is always the path the rows were actually gathered under.
      path: files.path,
      rows: files.rows.map do |row|
        {
          path: row.path,
          # Nullable, never coalesced to `0.0`: a file whose every example went untimed is SQL NULL
          # out of the aggregate, and a zero there would assert a file that cost nothing.
          total_seconds: row.total_seconds,
          recorded_count: row.recorded_count,
          timed_count: row.timed_count
        }
      end,
      file_count: files.file_count,
      recorded_count: files.recorded_count,
      timed_count: files.timed_count,
      limit: SpecObservation::SPEC_DIRECTORY_FILES_LIMIT
    }
  end

  # WHICH EXAMPLES ONE FILE HOLDS — the bottom rung of area → file → example, and the move an agent
  # holding every other key on this endpoint still could not make. The key above names the files of
  # one area and stops there; an agent that has walked `spec/models/` down to
  # `spec/models/order_spec.rb — 340 examples, six minutes` has learned WHICH file to open and has
  # nothing to open it with. Neither per-example block already here answers it: `slowest_examples`
  # reaches this grain only for the ten examples that are slowest RUN-WIDE — usually holding not one
  # row of the file that was opened — and `spec_files` is a capped ten RANKING of the run's heaviest
  # files rather than a listing of anything.
  #
  # INSIDE `latest_run` rather than beside it, on the membership test the comment on `unstable_tests`
  # states in full: every key this block serves is a statement about ONE run's rows.
  # `SpecObservation.in_file` narrows to a single `test_run_id`, so it belongs with the others. And
  # `latest_run` is not re-anchored by `?branch=`, so a file ask composes with a branch ask and with
  # an area ask without any of the three touching another. `?commit_sha=` is the one ask that DOES
  # move the anchor, and this drill-in moves with it unread — the file is always a file OF the run
  # `latest_run` named, because both read the single `latest_test_run` memo, and `run_anchor` names
  # that run. It is the repository's newest one only on a default call, and on an explicit ask this
  # list is STILL the panel's: `RepositoriesController` reads `?commit_sha=` through this same
  # `RequestedCommitShaParam`, so under an explicit ask the two surfaces agree — both re-anchor on
  # the run the client named rather than diverging.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query — this file's governing rule, stated
  # in full on `serialized_spec_files` above. `SpecFileExamples` is view-free apart from
  # `#coverage_label`, which is skipped here exactly as the rung above skips `Row#duration_label` and
  # `Row#coverage_label`, so the API and the panel list the same examples of the same file of the
  # same run, in the same order, off the one read.
  #
  # THE ROW SHAPE IS `serialized_slowest_examples`' SEVEN FIELDS, field for field, because this
  # endpoint's two per-example blocks describe the same rows of the same table and a client that
  # learned to read one must not have to learn a second shape to read the other. The seventh is
  # `intent_layer` (SPGD-851), which arrived on the run-wide ranking and reached this block through
  # exactly that rule rather than because this block asked for it — the field list below says so at
  # the rows themselves. `duration_seconds`
  # is nullable and NEVER coalesced to `0.0`: an example this run recorded and did not time has no
  # duration to report — `Ingest::ObservationRecorder#attributes` writes the nil faithfully — and a
  # zero there would assert an example that cost nothing. Those rows are LISTED rather than
  # excluded, at the end of the list, which is the whole reason this block's population counts can
  # ride back on the rows at all where `slowest_examples`' had to be a second read.
  #
  # NO `reported_outcome_count`. `SlowestExamples` exposes one and this object does not, and the
  # difference is not an oversight to paper over with a re-derivation off the serialized rows: that
  # figure would be the PAGE's, computed under the file's name, which is the one thing every count
  # on this block is arranged to avoid.
  #
  # `null` — with the key present — MEANS "YOU DID NOT ASK", on the spelling the key above fixed and
  # for the same reason: the siblings are served unconditionally and gate on `#recorded?`, and
  # copying that gate here would collapse *"you did not ask"* and *"the file you asked about has no
  # rows"* into one answer. So an ask that matched nothing gets the block with `rows: []` and its
  # `path` restated — HTTP 200, never a 404, since a deleted spec file, a renamed one and a stale
  # bookmark are all ordinary ways to arrive here, as `RequestedSpecFileParam` argues in full.
  #
  # `recorded_count` and `timed_count` are the FILE's, off the two `COUNT(…) OVER ()` windows of
  # `SpecObservation::FILE_POPULATION_COUNTS` — evaluated after the WHERE and before the LIMIT, so
  # they describe the population the list was cut from rather than the examples that fit on the
  # page. A client that folded the serialized rows to re-derive either would be computing the page's
  # figure under the file's name. `limit` is READ OFF `SpecObservation::FILE_EXAMPLES_LIMIT` rather
  # than restated, on the precedent every capped block here sets — it is its own constant and
  # neither `SLOWEST_LIMIT` nor `SPEC_DIRECTORY_FILES_LIMIT`.
  #
  # EXACTLY ONE ADDITIONAL QUERY WHEN ASKED, AND NONE WHEN NOT, on the key above's rule: the gate is
  # the ASK and it is decided before any read is issued, so a client that never sends the parameter
  # pays nothing for the key's existence. The read is bounded by the FILE rather than by the suite
  # and rides `index_spec_observations_on_test_run_id_and_spec_file_path`, the composite index
  # EXPLAIN-certified for exactly this narrow in `spec/models/spec_observation_spec.rb`. Because
  # this block issues the read the panel issues, unchanged, that certification transfers rather than
  # needing to be repeated in a request spec.
  def serialized_spec_file_examples(test_run)
    return nil if requested_spec_file.nil?

    examples = SpecFileExamples.for(test_run, requested_spec_file)

    {
      # The ask, restated as the server read it — never echoed from the raw parameter, on
      # `history_window.branch`'s rule: a malformed shape is no ask at all and reaches no block, so
      # what is served here is always the path the rows were actually gathered under.
      path: examples.path,
      # THE SAME SEVEN FIELDS `serialized_slowest_examples` SERVES, AND THE REPETITION IS CHOSEN. The
      # two per-example blocks on this endpoint must agree field for field, and a shared
      # `serialized_example_row` would make that structural rather than asserted — the stronger
      # guarantee, and it is declined here for this file's standing reason: each block states its
      # own contract beside its own rows, and a field list extracted to a helper sits where neither
      # block's comment can explain why it holds what it holds. What enforces the agreement instead
      # is a `contain_exactly` over these names in each block's request spec, so a field added to
      # one and not the other goes red rather than shipping a client two per-example shapes.
      #
      # `intent_layer` is here BECAUSE OF THAT RULE, not because this block asked for it. It was
      # added to `serialized_slowest_examples` (SPGD-851) and the cross-block guard in
      # `repository_repeated_description_examples_spec.rb` went red — which is the guard working:
      # one shape, served by every block that describes these rows. It is the DECLARED layer, null
      # for an unannotated row and for one ingested before the column existed; see
      # `serialized_slowest_examples` for why it is served raw and never worded.
      rows: examples.rows.map do |observation|
        {
          name: observation.name,
          file_path: observation.file_path,
          line_number: observation.line_number,
          spec_file_path: observation.spec_file_path,
          duration_seconds: observation.duration_seconds,
          outcome: observation.outcome,
          intent_layer: observation.intent_layer
        }
      end,
      recorded_count: examples.recorded_count,
      timed_count: examples.timed_count,
      limit: SpecObservation::FILE_EXAMPLES_LIMIT
    }
  end

  # WHICH EXAMPLES SAY ONE THING — the drill-in out of `repeated_descriptions` above, and the last
  # ranking on this endpoint whose rows dead-ended. That block reports that a description is carried
  # by eight examples costing ninety seconds between them and names the files they ran in, and
  # `files_seen` is where it stops: a string array a client can read and cannot act on. Until this
  # key, writing SQL was the only way to learn WHICH eight, what each cost, where each sits and how
  # each ended.
  #
  # NOT REACHABLE FROM ANY OTHER KEY HERE, which is the whole reason it is served. `slowest_examples`
  # is the run-wide top ten and a group's members are usually absent from it entirely;
  # `spec_file_examples` over each path in `files_seen` is N unrelated lists, each capped at fifty by
  # DURATION, with no guarantee any of the group's members are in any of them — a two-file group
  # followed that way returns two lists of rows that need not include one row of it. The reason is
  # the one `serialized_repeated_descriptions` states above and this key inherits: the three rollups
  # name where the code LIVES, and no rollup of "where" can see that two of those rows say the same
  # thing.
  #
  # THE THIRD DRILL-IN AND NOT A FOURTH RUNG. `spec_directory_files` and `spec_file_examples` are
  # the middle and bottom of area → file → example, and this is not under either of them: it opens
  # a SENTENCE rather than a place, and its rows routinely span several files — which is precisely
  # the shape a reader came to see. A group whose three rows sit at consecutive line numbers in one
  # file reads as a table-driven loop; the same description at three unrelated sites reads as
  # something else, and nothing here decides which.
  #
  # INSIDE `latest_run` rather than beside it, on the membership test the comment on `unstable_tests`
  # states in full: `SpecObservation.with_description` narrows to a single `test_run_id`, so this is
  # a statement about ONE run's rows. And `latest_run` is not re-anchored by `?branch=`, so a
  # description ask composes with all three of the other asks without any of the four touching
  # another. The fifth ask is the exception and is meant to be: `?commit_sha=` re-anchors
  # `latest_run`, and this drill-in re-anchors with it without reading the parameter, because the
  # group is always a group WITHIN the run that one `latest_test_run` memo picked. `run_anchor` is
  # what names it. Only on a default call is that the repository's newest run, and these rows are
  # the panel's on an explicit ask too — `RepositoriesController` reads `?commit_sha=` through this
  # same `RequestedCommitShaParam`, so both surfaces re-anchor on the run the client named.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query — this file's governing rule, stated
  # in full on `serialized_spec_files` above. `RepeatedDescriptionExamples` is view-free apart from
  # `#coverage_label`, which is skipped here exactly as the two rungs above skip `Row#duration_label`
  # and `SpecFileExamples#coverage_label`: `"25 of 40"` is two integers a client cannot subtract.
  #
  # THE ROW SHAPE IS `serialized_slowest_examples`' SEVEN FIELDS, field for field, on the rule
  # `serialized_spec_file_examples` states: this endpoint's now THREE per-example blocks describe the
  # same rows of the same table, and a client that learned to read one must not have to learn a
  # second shape to read the others. `duration_seconds` is nullable and NEVER coalesced to `0.0` —
  # and at this grain an untimed row is often exactly the row a reader came for, because a test that
  # never ran is one way three examples come to say the same thing. Those rows are LISTED rather than
  # excluded, at the END of the list, which is what `with_description`'s `NULLS LAST` is for.
  #
  # NO CAPTION PREDICATES. The object exposes `#lists_untimed?`, `#truncated?`, `#complete?` and
  # `#any_timed?`, and every one of them is a COMPARISON between figures served below. This endpoint
  # ships the operands and lets a client word it — `recorded_count > rows.length` is `#truncated?`
  # without this block shipping the comparison instead of the two numbers it is drawn from.
  #
  # `recorded_count` and `timed_count` are the GROUP's, off the two `COUNT(…) OVER ()` windows of
  # `SpecObservation::DESCRIPTION_POPULATION_COUNTS` — evaluated after the WHERE and before the
  # LIMIT, so they describe the population the list was cut from rather than the examples that fit on
  # the page. On a truncated group neither is re-derivable from the serialized rows, which is the
  # point of serving them: a client that folded `rows` to count them would be computing the page's
  # figure under the description's name. `limit` is READ OFF
  # `SpecObservation::REPEATED_DESCRIPTION_EXAMPLES_LIMIT` rather than restated, on the precedent
  # every capped block here sets — it is its own constant and is neither `FILE_EXAMPLES_LIMIT` nor
  # `SPEC_DIRECTORY_FILES_LIMIT`.
  #
  # `null` — with the key present — MEANS "YOU DID NOT ASK", on the spelling the two keys above fixed
  # and for the same reason: the siblings are served unconditionally and gate on `#recorded?`, and
  # copying that gate here would collapse *"you did not ask"* and *"the description you asked about
  # has no rows"* into one answer. So an ask that matched nothing gets the block with `rows: []` and
  # its `name` restated — HTTP 200, never a 404, since a test renamed since, a description edited and
  # a stale bookmark are all ordinary ways to arrive here, as `RequestedRepeatedDescriptionParam`
  # argues in full.
  #
  # EXACTLY ONE ADDITIONAL QUERY WHEN ASKED, AND NONE WHEN NOT, on the two keys above's rule: the
  # gate is the ASK and it is decided before any read is issued, so a client that never sends the
  # parameter pays nothing for the key's existence. The read is bounded by the GROUP's run rather
  # than by the suite and rides `index_spec_observations_on_test_run_id`, EXPLAIN-certified for
  # exactly this narrow in `spec/models/spec_observation_spec.rb`. Because this block issues the read
  # the panel issues, unchanged, that certification transfers rather than needing to be repeated in a
  # request spec.
  def serialized_repeated_description_examples(test_run)
    return nil if requested_repeated_description.nil?

    examples = RepeatedDescriptionExamples.for(test_run, requested_repeated_description)

    {
      # The ask, restated as the server read it — never echoed from the raw parameter, on the rule
      # `path` follows on both sibling blocks: a malformed shape is no ask at all and reaches no
      # block, so what is served here is always the description the rows were actually gathered
      # under.
      name: examples.name,
      # THE SAME SEVEN FIELDS the two per-example blocks above serve, and the repetition is chosen for
      # the reason `serialized_spec_file_examples` states in full: each block states its own contract
      # beside its own rows, and what enforces the agreement is a `contain_exactly` over these names
      # in each block's request spec, so a field added to one and not the others goes red rather than
      # shipping a client three per-example shapes.
      #
      # `intent_layer` is here BECAUSE OF THAT RULE (SPGD-851): it was added to the run-wide ranking
      # and the cross-block guard in this block's own request spec — the one assertion that reads all
      # three shapes off a single response — went red until the field reached all three. The DECLARED
      # layer, null for an unannotated row and for one ingested before the column existed.
      rows: examples.rows.map do |observation|
        {
          name: observation.name,
          file_path: observation.file_path,
          line_number: observation.line_number,
          spec_file_path: observation.spec_file_path,
          duration_seconds: observation.duration_seconds,
          outcome: observation.outcome,
          intent_layer: observation.intent_layer
        }
      end,
      recorded_count: examples.recorded_count,
      timed_count: examples.timed_count,
      limit: SpecObservation::REPEATED_DESCRIPTION_EXAMPLES_LIMIT
    }
  end

  # WHICH TESTS CARRY NO `@intent` — the rows behind the product's stated primary adoption metric,
  # and until this key the one figure on either surface that could be reported and not opened.
  #
  # ⚠️ NOT "which tests SpecGuard cannot see", which is what this comment and this block's own
  # description said until SPGD-711. That population is `intent_readings.unreadable`, and it is far
  # smaller: most of the rows here carry a `Class#method behavior` description SpecGuard reads. Each
  # row's `reading` says which, and `unreadable_count` beside `recorded_count` is the only figure in
  # this block any "cannot see" sentence may be built on.
  #
  # `latest_run.total_specs` and `latest_run.annotated_specs` sit twenty lines above this key, and
  # `annotated_ratio` beside them. Their difference is what `repositories#show` used to render under
  # "Not visible to SpecGuard" as *"SpecGuard cannot see the other N tests"*, and a subtraction is the whole
  # answer a reader has ever been given: an agent told to raise annotation coverage receives
  # `annotated_ratio: 0.43` and cannot name ONE of the tests that number is about. Every other ranking
  # on this endpoint has a drill-down rung — `spec_directory` → files, `spec_file` → examples,
  # `repeated_description` → examples, `unstable_test` → runs — and this was the sole exception.
  #
  # THE COUNT AND THE LIST ARE ONE PREDICATE, WHICH IS WHY THE ROWS COME OFF `spec_observations.status`
  # AND NOT FROM ANYWHERE ELSE. `Ingest::Payload#annotated_specs` rejects `status == "unannotated"` and
  # its size becomes `annotated_specs_count`; `Ingest::ObservationRecorder#attributes` writes that same
  # string onto every row of the same delivery. So `recorded_count` here and `total_specs -
  # annotated_specs` above are one derivation evaluated twice rather than two figures that agree today
  # — the property this file demands of a count and its list everywhere else, and the reason this rung
  # needed no migration and no new data. `SpecObservation.unannotated_in` argues it in full, and the
  # reconciliation is pinned in `spec/requests/api/v1/repository_unannotated_examples_spec.rb` for an
  # UNSHARDED run: on a sharded one those counters are re-derived by SUM over `test_run_shards` while
  # these rows are what was actually stored, which is the same separation `serialized_spec_files`
  # states for its own denominator.
  #
  # THE WORKLIST CAN BE POINTED AT WHERE THE WORK IS, WITH THE TWO PARAMETERS THAT ALREADY NARROW
  # EVERY OTHER PER-EXAMPLE QUESTION HERE. Sent alone the flag answers the WHOLE RUN in one order,
  # capped, and a team adopting SpecGuard on the module they are actually touching could not ask for
  # its unannotated tests: they got a hundred rows from wherever `spec/` sorts first, and the only
  # route to `spec/services/` was to annotate every alphabetically-earlier example first — a hundred
  # at a time, each batch costing a CI run and a re-ingest. Sent WITH `?spec_file=` or
  # `?spec_directory=`, the population narrows to it — rows and `recorded_count` both — on the
  # `area → file → example` ladder those two parameters already are, and on the predicates this
  # application already owns: `where(spec_file_path: …)` and `DIRECTORY_EXPRESSION` compared for
  # EQUALITY, which is the IMMEDIATE PARENT and never a prefix, so `spec/models/orders` is its own
  # area rather than part of `spec/models`. See `SpecObservation.unannotated_in`, which argues the
  # predicates, the AND-ing of the pair and the absence of a precedence rule between them.
  #
  # THE TWO PARAMETERS DO NOT STOP OPENING THEIR OWN BLOCKS. They are read once, by the guards this
  # controller already includes, and each reaches its own drill-in beside this one — `?spec_file=` →
  # `spec_file_examples`, `?spec_directory=` → `spec_directory_files`. They do not reach equally far,
  # and the asymmetry is the point rather than a rounding: `?spec_directory=` alone carries on to the
  # two directory file-growth pairs as well, six served keys against `?spec_file=`'s two. It is that
  # ONE DRILL-IN EACH, not the growth pairs and not this block, that makes the empty answer here
  # reconcilable rather than ambiguous, and it is stated in full at the keys below.
  #
  # INSIDE `latest_run` rather than beside it, on the membership test the comment on `unstable_tests`
  # states in full: `SpecObservation.unannotated_in` narrows to a single `test_run_id`, so this is a
  # statement about ONE run's rows. And `latest_run` is not re-anchored by `?branch=`, so this ask
  # composes with the other four — narrowing on two of them and leaving the other two untouched, none
  # of the five re-anchoring another. `?commit_sha=` is the exception and is meant to be: it
  # re-anchors `latest_run`, and this drill-in re-anchors with it WITHOUT READING THE PARAMETER,
  # because both hang off the one `latest_test_run` memo and `run_anchor` names the run they landed
  # on. That matters more here than on its siblings — "what is still unannotated" is the question an
  # adopting repository asks after every push, so asking it of an older commit is the ordinary use
  # rather than the exotic one.
  #
  # THE ROW SHAPE IS SIX FIELDS AND DELIBERATELY NOT THE OTHER BLOCKS' SEVEN. The three per-example
  # blocks above agree field for field on purpose — `serialized_spec_file_examples` states why, and a
  # `contain_exactly` in each of their request specs enforces it — and this block is not a fourth
  # member of that set. Those three list examples a reader has come to MEASURE, so they carry
  # `duration_seconds` and `outcome`; this one lists examples a reader has come to OPEN AND EDIT, so it
  # carries what opens a file plus what SpecGuard already read of the row, and nothing else. `outcome`
  # would be worse than surplus here: an
  # unannotated example's outcome is a fact about the last run, and a worklist sorted for editing that
  # also whispers "this one failed" invites the reader to do the other job. The third withheld field is
  # `intent_layer` (SPGD-851), and it is withheld for a STRUCTURAL reason rather than an editorial one:
  # this block's population is BY DEFINITION the rows carrying no layer — an unannotated example
  # declared none, and the envelope requires `intent` to be ABSENT when `status` is `"unannotated"` —
  # so the key would be a column of guaranteed nulls, saying nothing on every row it appeared on. The
  # six are `name`, `spec_file_path`, `file_path` and `line_number`, plus `reading` and
  # `derived_intent` (SPGD-711) — and of the locating four the last three are the pair
  # `serialized_spec_file_examples` keeps apart plus the line: `file_path` is where the example is
  # DEFINED and `spec_file_path` is the file that RAN it, which differ for a shared example group, and
  # a reader opening the wrong one of the two finds nothing to annotate.
  #
  # `null` — WITH THE KEY PRESENT — MEANS "YOU DID NOT ASK", on the spelling the three drill-ins above
  # fixed, and the distinction it protects is the sharpest on this block. A fully-annotated run is not
  # an empty file or a stale bookmark: it is the STATE THE METRIC EXISTS TO REACH, so it arrives as the
  # block with `rows: []` and `recorded_count: 0` — HTTP 200, never a 404 and never a `null`. Collapsing
  # it into the no-ask spelling would answer the best possible outcome with the one word reserved for
  # "you did not ask", and a client walking a repository to completion would watch the block vanish at
  # the moment it succeeded and be unable to tell that from its own parameter having been dropped.
  #
  # `recorded_count` IS THE UNANNOTATED POPULATION OF WHATEVER WAS ASKED FOR — the whole run by
  # default, and the narrowed slice when `?spec_file=` or `?spec_directory=` came with the flag. It is
  # the `COUNT(*) OVER ()` window of `SpecObservation::UNANNOTATED_POPULATION_COUNTS`, evaluated after
  # the WHERE and before the LIMIT, so it describes what the ask holds rather than what fit on the
  # page — and it narrows with the rows for free rather than through a second aggregate. Re-deriving
  # it by folding `rows` is wrong here far more often than on the siblings: this population is
  # routinely the WHOLE RUN — a repository that has just installed the gem has `recorded_count ==
  # total_specs` on day one — so the cap fires as the normal case rather than the exotic one, and
  # `recorded_count > rows.length` is a comparison this block ships the two OPERANDS of rather than the
  # answer to — the same ships-the-numbers rule the siblings follow, and the reason
  # `UnannotatedExamples` defines no `truncated?` for a caller that does not exist yet.
  #
  # ⚠️ WHICH IS WHY THE NARROWING IS ECHOED. `recorded_count` is the one figure on this endpoint a
  # client is invited to reconcile against a headline — `total_specs - annotated_specs`, one predicate
  # evaluated twice — and a narrowed count silently breaks that reconciliation. So the two keys below
  # say which population the count is of, and a client that sent neither sees `null` twice and can
  # reconcile exactly as before.
  #
  # NO SECOND COUNT, where all three siblings serve one. Each of theirs discloses COVERAGE of the
  # column its rows are ranked by, and this block ranks by nothing and serves neither nullable column
  # — see `SpecObservation::UNANNOTATED_POPULATION_COUNTS`, where the omission is argued as a choice
  # rather than left as an absence. `limit` is READ OFF `SpecObservation::UNANNOTATED_EXAMPLES_LIMIT`
  # rather than restated, on the precedent every capped block here sets — it is its own constant and is
  # neither `FILE_EXAMPLES_LIMIT` nor `REPEATED_DESCRIPTION_EXAMPLES_LIMIT`.
  #
  # EXACTLY ONE ADDITIONAL QUERY WHEN ASKED, AND NONE WHEN NOT, on the three drill-ins' rule: the gate
  # is the ASK and it is decided before any read is issued, so a client that never sends the parameter
  # pays nothing for the key's existence. The narrowing does not change that — it is a predicate on the
  # one read, not a second one, and it is read off guards this controller already includes for their
  # own blocks. The read is bounded by the RUN rather than by the suite and rides
  # `index_spec_observations_on_test_run_id`, EXPLAIN-certified for exactly this narrow — and for both
  # narrowed shapes — in `spec/models/spec_observation_spec.rb`.
  # `latest_run.intent_readings` — see the key on `serialized_latest_run` for what the four figures
  # are and which of them may not be read as annotation coverage.
  #
  # Unconditional, unlike the two `?unannotated_examples=` blocks below, and that is deliberate
  # rather than an oversight about cost. Those two are a HUNDRED-ROW WORKLIST and a TEN-ROW RANKING
  # — payload a client that did not ask for it should not be handed. This is four integers off one
  # aggregate over one run, and it is what makes `unreadable` reachable without a second request. A
  # client that has to opt in to the correction goes on reading the subtraction, which is the state
  # SPGD-711 exists to end.
  def serialized_intent_readings(test_run)
    readings = test_run.intent_readings

    { authored: readings.authored, derived: readings.derived, unreadable: readings.unreadable,
      recorded: readings.recorded }
  end

  # THE SUITE-WIDE DUPLICATE CENSUS, served to whoever named it — the first block on this endpoint
  # whose GRAIN is the repository rather than a run or a window of runs, and therefore the first one
  # that had to be opted into on cost rather than bounded on rows. `NearDuplicateClusters` is linear
  # but measured in seconds (its class comment carries the table), so `?near_duplicates=` is the ask
  # and `nil` below is the no-ask answer: the key is present and `null`, and a client that did not
  # ask pays not one query — pinned by a query-count assertion in this block's request spec, because
  # the cost is the reason the gate exists.
  #
  # == Why the disclosure rides the count and cannot be split from it
  #
  # `similarity_basis` and `similarity_floor` are served off the OBJECT'S OWN METHODS rather than
  # restated here, so this endpoint cannot drift from what `NearDuplicateClusters` says about
  # itself — and when `SIMILARITY` is re-derived for the shipped provider (open work the constant's
  # own comment names), the endpoint reports the new figure without being touched. No spec in this
  # slice may pin either as a literal; the sibling spec `near_duplicate_clusters_spec.rb` already
  # establishes that discipline for the constants themselves. A cluster count rendered without the
  # statement of what the similarity means is the *Vacuous Green* failure in a new spelling, which
  # is why `#similarity_basis` is a method rather than a footnote — and why the two keys sit FIRST
  # on this block, ahead of every figure they qualify.
  #
  # == Raw figures only, never the object's prose
  #
  # `duration_label`, `coverage_label` and `identity_coverage_label` exist on the object and on
  # every `Cluster` and `Member`, and NONE of them is served: they are human sentences built by
  # `SpecObservation.humanized_duration` / `.coverage_fraction`, and a machine-readable client
  # cannot act on a sentence without parsing it. The raw `total_seconds` floats and raw counts are
  # served instead — the operands, never the wording, on this endpoint's standing rule.
  #
  # == The membership/weight split, at the two grains the object reads them
  #
  # `member_count` is texts in this REPOSITORY across every run; `example_count` is examples in the
  # run `weighed_run_id` names and only that run. A three-example table-driven loop is ONE member
  # and THREE examples, and the headline property of the whole object is that those are different
  # numbers served side by side — a naive serializer that counted identity rows would flatten the
  # figure the ranking is built on. The request spec pins the three-example case through this
  # endpoint specifically.
  #
  # `NearDuplicateClusters.for(repository)` is called with `run:` defaulted, on the ticket's own
  # constraint: the object's `validate_run!` RAISES `ArgumentError` on a run from another
  # repository, deliberately — the caption half is keyed on `test_run_id` with no tenant predicate,
  # so a foreign run would report another tenant's `recorded_count` beside this tenant's clusters.
  # That is a caller's bug and is not rescued here. `nil` (never ingested) passes through cleanly
  # as the `UNRUN` constant, so the block serves rather than raises for a repository with no run.
  #
  # No 404 on the empty answer: a repository whose every test reads differently is the SUCCESS
  # state, and the object's own three-way `recorded?` / `clusterable?` / `any?` split is what keeps
  # the three silences — nothing ingested, nothing embedded, nothing reads alike — distinguishable
  # at the wire via `recorded_count`, `identity_count` and the cluster list.
  def serialized_near_duplicates
    return nil unless requested_near_duplicates?

    clusters = NearDuplicateClusters.for(repository)

    {
      similarity_floor: clusters.similarity_floor,
      similarity_basis: clusters.similarity_basis,
      weighed_run_id: clusters.weighed_run_id,
      cluster_count: clusters.cluster_count,
      truncated: clusters.truncated?,
      saturated_identity_count: clusters.saturated_identity_count,
      unresolved_count: clusters.unresolved_count,
      recorded_count: clusters.recorded_count,
      identity_count: clusters.identity_count,
      clustered_identity_count: clusters.clustered_identity_count,
      clustered_timed_count: clusters.clustered_timed_count,
      clustered_example_count: clusters.clustered_example_count,
      clusters: clusters.clusters.map { |cluster| serialized_near_duplicate_cluster(cluster) }
    }
  end

  # ONE cluster of tests that read alike, with the figures the ranking is built on — as numbers
  # rather than as the sentences `NearDuplicateClusters::Cluster#duration_label` would build. Per
  # the class comment's ⭐ sections, `member_count` and `example_count` are read at two different
  # grains and served as two different numbers; `unobserved_members` discloses that the member
  # list holds an identity the weighed run did not observe (deleted, renamed, not selected) rather
  # than leaving it to be inferred from a small sum; `similarity_range` is the object's
  # `[strongest, weakest]` pair, both already rounded by the method that owns the rounding, because
  # membership is transitive while similarity is not and the gap between the two edges is the point.
  def serialized_near_duplicate_cluster(cluster)
    {
      signal_source: cluster.signal_source,
      member_count: cluster.member_count,
      example_count: cluster.example_count,
      total_seconds: cluster.total_seconds,
      timed_count: cluster.timed_count,
      similarity_range: cluster.similarity_range,
      unobserved_members: cluster.unobserved_members?,
      members: cluster.members.map do |member|
        { text: member.text, file_path: member.file_path, line_number: member.line_number,
          example_count: member.example_count, total_seconds: member.total_seconds }
      end
    }
  end

  def serialized_unannotated_examples(test_run)
    return nil unless requested_unannotated_examples?

    examples = UnannotatedExamples.for(test_run, spec_file: requested_spec_file,
                                                 spec_directory: requested_spec_directory)

    {
      # THE ASK RESTATED IS THE NARROWING, AND `null` WHEN THERE WAS NONE. The flag itself carries no
      # value to echo — the sibling drill-ins echo the key the client picked out of a ranking, and
      # this parameter is a presence rather than a pick; see `RequestedUnannotatedExamplesParam` for
      # why it is the flag-style one. What CAN be restated is where in the run the client asked to
      # start, and it has to be: `recorded_count` moves with it.
      #
      # As the server READ them, never echoed from the raw parameter, on `history_window.branch`'s
      # rule and `spec_file_examples.path`'s: a malformed shape is no ask at all and reaches no
      # narrowing, so what is served here is always the value the rows were actually gathered under.
      #
      # BOTH ARE AND-ED WHEN BOTH ARRIVE, and a contradictory pair — an area and a file outside it —
      # is answered with `rows: []` and both narrowings echoed, which reads as an empty intersection
      # rather than as one parameter having been dropped. `SpecObservation.unannotated_in` argues why
      # there is no precedence rule.
      #
      # AN UNKNOWN PATH IS THE SAME EMPTY BLOCK, never a 404 and never a prefix match onto a
      # neighbouring file or a sibling subdirectory — `serialized_spec_file_examples` fixed that
      # answer and this inherits it. Unknown-vs-fully-annotated is not distinguished here, and a
      # client that needs the two apart already has them in the SAME RESPONSE BODY for free: with
      # `?spec_file=`, `spec_file_examples.recorded_count > 0` beside a zero here means the file
      # exists and is fully annotated, and both zero means the run recorded nothing at that path.
      # `?spec_directory=` reconciles against `spec_directory_files` the same way. No new field, no
      # new query.
      spec_file: examples.spec_file,
      spec_directory: examples.spec_directory,
      # SIX ROW FIELDS, NOT THE OTHER PER-EXAMPLE BLOCKS' SEVEN, and the difference is asserted rather
      # than structural on purpose — the same way their agreement is. The two sets are not nested:
      # this block withholds three of theirs and carries two — `reading` and `derived_intent` — that
      # none of them serves. A `contain_exactly` over these
      # names in this block's request spec goes red if `duration_seconds`, `outcome` or `intent_layer`
      # is added here, and the siblings' own `contain_exactly`s go red if one of theirs is dropped to
      # match, so neither set can drift into the other unnoticed.
      rows: examples.rows.map do |observation|
        {
          name: observation.name,
          file_path: observation.file_path,
          line_number: observation.line_number,
          spec_file_path: observation.spec_file_path,
          # WHAT SPECGUARD READS OF THIS ROW, per row, so the caller never has to re-derive it — and
          # so it cannot re-derive it DIFFERENTLY, which is what a client seeing `name` and no
          # reading would end up doing. `reading` is `"derived"` or `"unreadable"` and never
          # `"authored"`: this list is narrowed to `status = 'unannotated'`, so the third state
          # cannot appear here (see `SpecObservation::UNANNOTATED_POPULATION_COUNTS` for the same
          # argument about the missing count).
          #
          # `derived_intent` is the three fields themselves, or `null`, and the two keys are
          # redundant on purpose: the reading is what a client BRANCHES on, the fields are what it
          # SHOWS, and an agent asked to check whether SpecGuard has the test right needs the second.
          # `layer` is absent from it because it is inferred from the directory rather than read from
          # the description — see `DerivedIntent`, which states in full what an authored `@intent`
          # still buys over this.
          reading: observation.reading,
          derived_intent: serialized_derived_intent(observation)
        }
      end,
      recorded_count: examples.recorded_count,
      # The same population split by reading. Windows over the same rows and the same WHERE as
      # `recorded_count`, so all three narrow together under `spec_file` / `spec_directory` — a
      # client cannot end up holding a derived count for one slice beside a total for another.
      #
      # This is where the endpoint stops being able to be read as "the tests SpecGuard cannot see".
      # `recorded_count` reconciles against `total_specs - annotated_specs` exactly as it always did
      # and means what it always meant — no authored `@intent`. `unreadable_count` is the only figure
      # here any "cannot see" sentence may be built on.
      #
      # ⚠️ ALL THREE ARE POPULATION-GRAIN AGAINST A CAPPED `rows`, and for this pair that is sharper
      # than it is for `recorded_count`. The read leads with the rows nothing could be read from — so
      # `rows` fills with unreadable examples FIRST, and the derived ones are exactly what a cap
      # drops. A client that counts non-null `derived_intent` over `rows` and expects `derived_count`
      # is comparing a page against a population, and on a capped response the honest answer to that
      # comparison is routinely zero-of-many rather than merely short. `limit` below is shipped so
      # the client can tell a capped response from a whole one; `recorded_count > rows.size` is the
      # comparison, and it is a client's sentence to write for the reason `UnannotatedExamples`
      # states. The dashboard's own caption got this wrong in exactly this cell (SPGD-711), which is
      # why it is written down here rather than left as a property of the ordering.
      derived_count: examples.derived_count,
      unreadable_count: examples.unreadable_count,
      limit: SpecObservation::UNANNOTATED_EXAMPLES_LIMIT
    }
  end

  # One row's derived reading as three fields, or `null` when the description yielded none.
  #
  # Nil rather than a hash of nils: "SpecGuard read nothing from this description" is one state, and
  # three null fields is a shape a client would have to test three times to recognise.
  def serialized_derived_intent(observation)
    derived = observation.derived_intent
    return nil unless derived

    { entity: derived.entity, action: derived.action, behavior: derived.behavior }
  end

  # WHERE THE ANNOTATION DEBT IS, by code area — the ranking the block above is a worklist under, and
  # the answer to the question that block could not be asked. `unannotated_examples` is ordered
  # file-navigably and says so; `?spec_file=` / `?spec_directory=` narrow it, and both only help a
  # client that already knows which area to name. Nothing in this response body said. This key does.
  #
  # NO NEW REQUEST PARAMETER. It rides `requested_unannotated_examples?` — the same gate, decided
  # before any read is issued — on this file's rule that THE GATE IS THE ASK: a client that never
  # sends the flag pays nothing for the key's existence, and one that does gets the ranking and the
  # worklist off one request rather than having to learn a second parameter to make the first usable.
  # EXACTLY ONE ADDITIONAL QUERY FOR THIS KEY WHEN ASKED, AND NONE WHEN NOT — so the ask now costs
  # TWO reads in total, one per block, which is what the cost examples in
  # `repository_unannotated_examples_spec.rb` pin.
  #
  # ⭐ THIS MAP IS WHOLE-RUN EVEN UNDER `?spec_file=` / `?spec_directory=`, AND ITS SIBLING IS NOT.
  # This is the one place on this endpoint where two keys of ONE block are deliberately scoped
  # differently, so it is disclosed here rather than left for a client to discover by arithmetic.
  #
  # `unannotated_examples.recorded_count` NARROWS with the narrowing — SPGD-608 made it so on purpose,
  # because the window rides the WHERE and a count beside a narrowed list has to describe the
  # population that list was cut from. This map does the opposite BY DESIGN: it is the thing a client
  # picks a narrowing FROM, and a map that narrowed to the area you had already picked would answer
  # nothing — one row, echoing the parameter back. So it stays whole-run and remains a way to choose
  # the NEXT area to go and work on, which is the whole reason the rung exists.
  #
  # The consequence a client must be able to explain: under a narrowing, `unannotated_examples.recorded_count`
  # is NOT the sum of `unannotated_directories[].unannotated_count`, and neither figure is wrong. The
  # first counts one area (or one file); the second ranks the whole run and is capped besides — so the
  # sum is short of the run's total whenever `directory_count > rows.size`, narrowing or no narrowing.
  # `spec_file` / `spec_directory` are echoed on the sibling block for exactly this reconciliation, and
  # `directory_count` beside these rows is the other half of it.
  #
  # `limit` is READ OFF `SpecObservation::UNANNOTATED_DIRECTORIES_LIMIT` rather than restated, on the
  # precedent every capped block here sets — it is its own constant and is neither
  # `HEAVIEST_DIRECTORIES_LIMIT` nor `UNANNOTATED_EXAMPLES_LIMIT`.
  #
  # OPERANDS, NEVER A FRACTION — this file's governing rule for every rollup it serves. The rows carry
  # `unannotated_count` and the `recorded_count` it was counted against, so a client divides by the
  # same figure the ranking was built on. A single percentage here would be a number a client cannot
  # take apart, and the sibling rollups' `coverage_label` is TIMING coverage and would be mistaken for
  # this one the moment either shipped a bare ratio.
  #
  # `null` WHEN THE FLAG WAS NOT SENT, and `null` — not an empty block — for a run that recorded no
  # per-example rows at all, which is `UnannotatedDirectories#recorded?` and the same absence
  # `serialized_spec_directories` answers that run with.
  #
  # ⭐ THAT SECOND NULL IS THE OTHER PLACE THESE TWO KEYS OF ONE BLOCK DISAGREE, and it is disclosed
  # here for the same reason the scope disagreement above is. On a run that recorded no per-example
  # rows, with the flag sent:
  #
  #     unannotated_examples    -> a present block, `rows: []`, `recorded_count: 0`
  #     unannotated_directories -> `null`
  #
  # A client reconciling those is doing exactly the arithmetic the paragraph above was written to
  # protect, so the difference has to be readable rather than inferred from two absent things looking
  # alike. It is NOT an inconsistency to iron out. The sibling's zero is ambiguous by construction —
  # "fully annotated" and "recorded nothing at all" are the same `recorded_count: 0` there, and that
  # block's own comment sends a client to neighbouring keys to tell such pairs apart. This key IS one
  # of those neighbours: a PRESENT map beside that zero means the run has a per-area grain and the
  # zero is the success state; a `null` map means the run recorded nothing and the zero is an absence
  # of data. Serving `rows: []` here instead would spend a distinction a client has no other way to
  # make in order to make two keys look the same. Both halves are pinned together in
  # `repository_unannotated_examples_spec.rb`, beside the fully-annotated run that reaches the same
  # zero with the map present.
  def serialized_unannotated_directories(test_run)
    return nil unless requested_unannotated_examples?

    directories = UnannotatedDirectories.for(test_run)

    return nil unless directories.recorded?

    {
      rows: directories.rows.map do |row|
        # The three readings beside the two totals that were already here. `unannotated_count` is
        # unchanged in meaning and in value — no authored `@intent` — and is what reconciles against
        # the run's counters; `derived_count` and `unreadable_count` split it, and are what stop a
        # client rendering the whole of it as debt SpecGuard is blind to.
        { path: row.path, unannotated_count: row.unannotated_count, recorded_count: row.recorded_count,
          authored_count: row.authored_count, derived_count: row.derived_count,
          unreadable_count: row.unreadable_count }
      end,
      directory_count: directories.directory_count,
      limit: SpecObservation::UNANNOTATED_DIRECTORIES_LIMIT
    }
  end

  # THE DRILL-IN SERIALIZERS ABOVE ARE PUBLIC, and this one statement is why: `LatestRunSerializer`
  # assembles the full-depth `latest_run` block and reaches each ask-dependent sub-block through
  # this object, because reading `params` through the `Requested*Param` concerns is the overview's
  # half of that collaboration and the serializer deliberately holds no ask of its own. They were
  # private when `serialized_latest_run` was the only caller, in here; the collaborator makes them
  # this object's published surface to that one serializer, and to nothing else — the list depth
  # calls none of them, which is the whole point of a depth.
  public :serialized_spec_files, :serialized_spec_directories, :serialized_slowest_examples,
         :serialized_repeated_descriptions, :serialized_spec_directory_files,
         :serialized_spec_file_examples, :serialized_repeated_description_examples,
         :serialized_intent_readings, :serialized_unannotated_examples,
         :serialized_unannotated_directories

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
    history_runs.map { |run| serialized_history_row(run) }
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
  # Counts and booleans, never prose: `TestRun#delivery_description` and `#wall_clock_coverage`
  # word these same shard facts in English for the panel, and `LatestRunSerializer#serialized_shards` already
  # settled that a machine-readable client cannot act on a sentence without parsing it.
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
  def history_runs
    @history_runs ||= preload_shard_counts(
      repository.recent_test_runs(limit: history_limit, branch: requested_branch).to_a
    )
  end

  # The contract the flakiness rows below are served under — and, when they are `null`, the reason
  # they are. Served UNCONDITIONALLY, on the key-always-present rule `latest_run.shards` argues for
  # itself above: a client tests one thing rather than distinguishing an absent key from a null one,
  # and the block that explains a `null` is worthless if it is itself absent whenever the `null`
  # happens.
  #
  # `grouped` IS THE LOAD-BEARING KEY, and it exists because of the branch decision below. Outcomes
  # compared across branches are outcomes of different code — `UnstableTests` states that rule for
  # itself — and unfiltered, `history_runs` is the INTERLEAVED all-branch window
  # `serialized_history_window` spends a paragraph warning about, on which consecutive rows are
  # routinely two different branches. Grouping outcomes over it would manufacture a flip out of two
  # branches: the same description failing on `feature/x` and passing on `main` is two pieces of
  # code, and calling it flaky is a false positive the object exists to avoid. So unfiltered,
  # `UnstableTests.for` IS NOT CALLED AT ALL — no rows, and no reads to produce them — and this
  # boolean is what says so.
  #
  # It is read off whether the object was CONSTRUCTED, never re-spelled as `requested_branch ?
  # true : false`. A second copy of the gate is a second thing to keep true, and the one that
  # decides what was read is the one worth serving. So `grouped` is exactly `unstable_tests !=
  # null`, in every response, and a client can test either.
  #
  # `grouped: true` IS NOT "SOMETHING WAS COMPARED". It says the window was eligible to be grouped
  # and was handed to the presenter — which is the branch decision and nothing more. What came of
  # it is the block's own business and is stated there: an unknown `?branch=` selects zero runs and
  # groups over an empty set, and a branch whose client never reported outcomes groups over a
  # populated one and still cannot compare. `run_count`, `recorded` and `comparable` are what
  # separate those, and they are in the block precisely because they are answers rather than
  # eligibility.
  #
  # `branch_scope` and `branch` are TWO keys rather than one interpolated token, and `branch` is
  # always served (`null` when the window was not narrowed) — `serialized_history_window` makes
  # both arguments in full and they are not repeated here. They carry the same values that block
  # carries in the same response, because both describe the SAME window: the rows below are grouped
  # over `history_runs`, which is what `history` is serialized from.
  #
  # `null` ROWS AND NEVER AN EMPTY LIST. `unstable_tests: []` would read as "nothing is flaky" when
  # it means "we refused to compare" — Vacuous Green exactly, in the shape this project keeps
  # finding it: a surface reporting a clean result for work it did not do. The `null` cannot be
  # misread, and this block says which of the two states produced it.
  #
  # `order` NAMES ALL THREE KEYS, and `tie_break_served` is `true` here — one of the blocks on
  # this endpoint where it is, as is `serialized_directory_growth_window`.
  # `UnstableTests#initialize` sorts by `(-failed_run_count, -run_count,
  # spec_identity_id)` and every one of those three is served on the row below, so unlike `history` and
  # `branches` — whose tie-breaks are an ingest sequence and a last-run timestamp that no row
  # carries — a client CAN reproduce this order from what it holds. Stated rather than assumed,
  # because the honest answer differs per block and a client that had to guess would re-sort one of
  # the two lists that must not be re-sorted.
  def serialized_unstable_tests_window
    {
      order: "failed_run_count_desc,run_count_desc,spec_identity_id_asc",
      tie_break_served: true,
      branch_scope: requested_branch ? "single_branch" : "all_branches",
      branch: requested_branch,
      grouped: !unstable_tests.nil?
    }
  end

  # WHICH TESTS ARE UNSTABLE ACROSS RUNS — the agent-readable half of the "Tests whose outcome
  # changed" panel `repositories#show` has rendered since SPGD-282, and the roadmap's fourth axis
  # ("where it is flaky"), which was the last of the four this endpoint had never been given.
  #
  # A DIFFERENT GRAIN FROM EVERYTHING IN `latest_run`, which is why it is served beside `history`
  # rather than inside that block. `slowest_examples` reaches the per-example grain of ONE run;
  # this is the first key on this endpoint that matches a test to ITSELF across runs, and no
  # arrangement of single-run facts answers it. An agent holding thirty responses could subtract
  # them — which is the polling-and-differencing this file's opening comment exists to refuse.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query — this file's governing rule,
  # stated in full on `serialized_spec_files`. `UnstableTests` is view-free, so the API and the
  # panel name the same tests, in the same order, off the same rows of the same window.
  #
  # OFF THE ALREADY-MEMOIZED WINDOW, so this adds NO run-window query. `history_runs` is
  # materialized once and `show` already reads it twice, and `UnstableTests.for`'s own signature
  # documents the window as *"ALREADY LOADED … handed in rather than re-queried"*, precisely so two
  # surfaces cannot come to be drawn on two windows that agree today. The object is order- and
  # anchor-indifferent: it reads `runs.map(&:id)` and `runs.size` and nothing else.
  #
  # `null` — THE KEY STILL PRESENT — under an unfiltered window, and the argument for that is on
  # `serialized_unstable_tests_window` above where the boolean that explains it lives.
  #
  # AN EMPTY `rows` IS A REAL ANSWER HERE and is not the same state. Under a branch-scoped window
  # the object IS constructed, and `rows: []` beside `comparable: true` means "we compared and
  # nothing flipped". Beside `comparable: false` it means "nobody told us how anything ended". The
  # two must never serialize identically, which is what the coverage keys below are for.
  #
  # STRUCTURED COUNTS AND BOOLEANS, NOT PROSE — this endpoint's standing rule, and this is the
  # block where it costs the most. `RepositoriesHelper` words this same coverage in TWELVE
  # `unstable_tests_*` helpers ("3 of the last 30 runs on main reported outcomes", "2 of 5"), and a
  # machine-readable client cannot act on a sentence without parsing it. So every figure those
  # sentences are built from goes out as an integer or a boolean and the client words it — or does
  # not word it at all and just divides.
  #
  # `comparable` IS THE VACUOUS GREEN GATE AND IS SERVED AS A FLAG, never as an empty list.
  # `UnstableTests#comparable?` is explicit about why: `outcome` is nullable and nothing validates
  # it, so a window whose client sends no outcomes stores a nil on every row of every run, which
  # yields no failures, therefore no candidates, therefore an empty list — *"the zero is real; what
  # it counts is silence"*. An empty list without this flag is "nobody told us" wearing the
  # spelling of "everything is stable".
  #
  # `recorded` is the coarser question one rung under it — whether the window has ANY per-example
  # grain at all — and separates a repository whose CI has never sent per-example detail from one
  # that sends it without outcomes. Both are read off the object's OWN predicates, called rather
  # than re-spelled here, on the rule `serialized_spec_files`' `#recorded?` gate states: a
  # controller-side copy of a predicate is free to drift the day the presenter's changes.
  #
  # `truncated` / `unexamined_count` DISCLOSE THE CANDIDATE CAP. The candidate step stops at
  # `SpecObservation::UNSTABLE_CANDIDATE_LIMIT` — a catastrophe valve for a window in which the
  # whole suite went red — and a capped list that does not say it stopped is read as the whole
  # story. The two OPERANDS (`candidate_count`, `examined_count`) go out beside the boolean, so a
  # client can check the comparison rather than take it; `limit` is read off `SpecObservation`'s own
  # constant rather than restated here, on the precedent `serialized_spec_files` sets, so the
  # response cannot claim a bound the query did not apply.
  #
  # `unnamed_count` IS AN EXCLUSION, not a population. A null `name` cannot be matched to itself
  # across runs — two nulls are not known to be one test — so those rows are dropped from the
  # matching before anything is grouped. Counted in ROWS and never in tests, because an unnamed row
  # is precisely a row this block cannot say is a test. `unresolved_count` is its sibling exclusion,
  # for the rows that reached no durable identity — the column the identity-grained matching
  # (SPGD-758) is denied by instead, served here beside the first with the same grain and the same
  # semantics.
  #
  # BOTH are `null` wherever the outcome gate below short-circuited — the two keys on that line
  # that go null while `candidate_count`, `examined_count`, `truncated` and `unexamined_count` stay
  # at their zeros. The split is not a stylistic one. Those four are OUTCOME facts, and in a window
  # nothing was examined in their zeros are true: no candidate was found because none was sought.
  # These two are ROW facts — their queries carry no outcome predicate — so the number of excluded
  # rows is fully determined in that window and merely never asked. A `0` would be a fabricated
  # exclusion, wire-identical to a window measured to hold none, and a client reading these keys to
  # learn how much of the window the matching dropped could not tell "not counted" from "counted
  # zero". Null rather than the true count because asking costs the second read the ONE-read
  # property below rules out; the HTML panel refuses to print any count over this same state.
  #
  # `shared_description_rows` IS ITS OWN LIST and never folded into `rows` — exactly as the panel
  # lists them separately. These are descriptions that varied across the window AND were carried by
  # more than one example in at least one run of it, so the description is not a key for that run:
  # its `failed` and its `passed` are two tests rather than one test that flipped. Reported rather
  # than dropped, because a dropped group is a silence a reader has no way to notice, and named as
  # what they are rather than as flakiness, because nothing here establishes which of it.
  #
  # AT MOST FOUR READS OF `spec_observations`, and CONSTANT in the length of the window and the size
  # of the suite — none of them new. They are the panel's own reads, already EXPLAIN-certified in
  # `spec/models/spec_observation_spec.rb`, so that certification transfers rather than needing to
  # be repeated in a request spec. The count is not constant in STATE, deliberately:
  # `UnstableTests.for` asks the gating question FIRST and on its own, so an incomparable window
  # costs ONE read and stops, and an unfiltered request costs NONE because the object is never
  # constructed.
  #
  # A FIFTH READ EXISTS AND IS THE CLIENT'S TO ASK FOR: `unstable_test_runs` below issues one more,
  # and only when `?unstable_test=` was sent. It is counted here rather than left for a reader to
  # discover, and it does not disturb the property above — it is bounded by ONE DESCRIPTION'S rows
  # over the same window, so it is constant in the size of the suite exactly as the four are.
  #
  # It does put ONE exception on the "incomparable window costs ONE read and stops" clause above:
  # the drill-in fires on the parameter alone, not on `comparable?`, so an incomparable window that
  # was ASKED a description costs that read too. That is deliberate rather than an oversight. A
  # window the ranking has nothing to say about is precisely the one where the raw per-run grain is
  # worth having — "no candidates" and "here is what this test actually did" are answers to
  # different questions, and gating the second on the first would withhold the grain exactly when
  # the aggregate above it went silent.
  def serialized_unstable_tests
    unstable = unstable_tests

    return nil if unstable.nil?

    {
      rows: unstable.rows.map { |row| serialized_unstable_test_row(row) },
      shared_description_rows: unstable.shared_description_rows.map { |row| serialized_unstable_test_row(row) },
      run_count: unstable.run_count,
      runs_with_rows: unstable.runs_with_rows,
      runs_reporting_outcomes: unstable.runs_reporting_outcomes,
      recorded: unstable.recorded?,
      comparable: unstable.comparable?,
      candidate_count: unstable.candidate_count,
      examined_count: unstable.examined_count,
      truncated: unstable.truncated?,
      unexamined_count: unstable.unexamined_count,
      unnamed_count: unstable.unnamed_count,
      unresolved_count: unstable.unresolved_count,
      limit: SpecObservation::UNSTABLE_CANDIDATE_LIMIT,
      unstable_test_runs: serialized_unstable_test_runs
    }
  end

  # ONE of the rows above, opened: that description's rows across the SAME window, run by run and in
  # window order — the fourth drill-in on this endpoint, on the ladder the three before it set
  # (`?spec_directory=` → `spec_directory_files`, `?spec_file=` → `spec_file_examples`,
  # `?repeated_description=` → `repeated_description_examples`).
  #
  # WHAT THE RANKING ABOVE CANNOT SAY, and the whole reason this exists. A row up there says
  # `run_count: 30`, `failed_run_count: 4`, `outcome_words: ["failed", "passed"]`. Those three
  # figures are IDENTICAL for two windows that call for opposite work: four failures in runs 27–30 is
  # a REGRESSION — find the commit between run 26 and run 27 — and four failures in runs 3, 11, 19
  # and 26 is FLAKINESS, where there is no culprit commit to find and the work is quarantine or
  # shared state. An agent told to "fix the flaky tests" treats every row as the second, and on the
  # first it hunts nondeterminism in a test that fails deterministically. `UNSTABLE_COMPOSITION` is
  # `COUNT`s and `ARRAY_AGG(DISTINCT …)` under `GROUP BY spec_identity_id` and is RIGHT to be — that is what
  # keeps the ranking constant in the size of the suite — so the axis is not recovered by changing
  # it. It is recovered by a rung below it.
  #
  # NOT DERIVABLE FROM ANY OTHER KEY HERE, which is what makes it a key rather than a convenience.
  # `history` rows carry `commit_sha`, `branch` and `ingested_at` and have no per-test grain;
  # `latest_run.spec_file_examples` and `latest_run.repeated_description_examples` carry an `outcome`
  # for the LATEST RUN only. A client holds at most one run's outcome per test beside thirty-run
  # aggregates, and no arithmetic over those produces a sequence.
  #
  # WHAT IT MAKES POSSIBLE, in one join the client already holds both sides of: `history` rows carry
  # `commit_sha` and these rows carry `commit_sha`, so the run this test started failing at is the
  # commit on the earliest row of the failing tail. That is the answer this endpoint could not give.
  #
  # `test_run_id` is served BESIDE `commit_sha` because a commit is not a key: the same commit is
  # legitimately ingested more than once — a re-run, a retry, a second workflow — and a reader
  # following a sequence has to be able to tell two runs of one commit apart before deciding a
  # failure moved.
  #
  # `outcome` GOES OUT VERBATIM and `null` STAYS `null`. Nothing platform-side validates that string
  # (`SpecObservation#outcome_label`), so quoting what arrived is the only reading that cannot be
  # wrong, and a run that recorded the test while reporting no outcome serializes as `null` rather
  # than as a pass — the separation `UnstableTests::Row#changed?` maintains one rung up by comparing
  # against `reported_outcome_count` rather than `recorded_count`, kept here so a client that stopped
  # sending outcomes cannot manufacture a flip that looks like a DATE.
  #
  # NESTED INSIDE `unstable_tests` rather than served beside it, on the shape the three sibling
  # drill-ins already set: each sits inside the block whose row it opens. It is gated by the ASK and
  # by the same `?branch=` the block itself is gated behind — an unfiltered window is interleaved
  # across branches (`serialized_history_window` warns about this at length), and an outcome sequence
  # read down an interleaved window is the outcomes of different code in run order, which is the one
  # reading of these rows that would be worse than not serving them.
  #
  # `null` — with the key present — MEANS "YOU DID NOT ASK", on the spelling the three drill-ins
  # fixed. An ask that matched nothing gets the block with `rows: []` and its `name` restated, HTTP
  # 200 and never a 404: the project's identity rule is semantic, so a RENAMED test starts a new
  # history and every bookmark to the old name goes stale by design.
  #
  # `run_count` and `limit` are the WINDOW and the CAP, disclosed on this block rather than left to
  # be read off the parent: this is a list, and a list that does not say how deep it was allowed to
  # go is read as the whole story. `recorded_count` beside them is the operand a client compares
  # against `rows.length` to see the cap bite — the operands, never the predicate, on
  # `serialized_repeated_description_examples`' standing rule for this endpoint.
  #
  # EXACTLY ONE ADDITIONAL QUERY WHEN ASKED, AND NONE WHEN NOT, on every drill-in's rule: the gate is
  # the ask and it is decided before any read is issued. The read is bounded by ONE DESCRIPTION'S
  # rows over at most thirty runs — constant in the size of the suite, not merely sublinear in it —
  # and rides `index_spec_observations_on_repository_id_and_name`, EXPLAIN-certified for exactly this
  # narrow in `spec/models/spec_observation_spec.rb`.
  def serialized_unstable_test_runs
    return nil if requested_unstable_test.nil?

    sequence = UnstableTestRuns.for(repository, history_runs, requested_unstable_test)

    {
      # The ask, restated as the server read it — never echoed from the raw parameter, on the rule
      # every sibling drill-in follows: a malformed shape is no ask at all and reaches no block, so
      # what is served here is always the description the rows were actually gathered under.
      name: sequence.name,
      rows: sequence.rows.map do |row|
        {
          test_run_id: row.test_run_id,
          commit_sha: row.commit_sha,
          branch: row.branch,
          ingested_at: row.ingested_at.iso8601,
          outcome: row.outcome,
          duration_seconds: row.duration_seconds,
          spec_file_path: row.spec_file_path,
          line_number: row.line_number
        }
      end,
      recorded_count: sequence.recorded_count,
      reported_outcome_count: sequence.reported_outcome_count,
      unreported_outcome_count: sequence.unreported_outcome_count,
      run_count: sequence.run_count,
      limit: SpecObservation::UNSTABLE_TEST_RUNS_LIMIT
    }
  end

  # One description across the window. Every counter the presenter carries, flat, on
  # `serialized_slowest_examples`' shape — and every one of them an OPERAND rather than one of the
  # labels `UnstableTests::Row` builds for the panel. `#appearance_label` and `#failure_label` word
  # these same figures as `"2 of 5"`, which a client would have to split on a space before it could
  # compare two rows.
  #
  # BOTH DENOMINATORS ARE SERVED, and they are different denominators. `run_count` is the runs this
  # description APPEARED in — not the window's length, which is on the block above — because a test
  # added halfway through the window failed in two of the fifteen runs that ran it, and dividing by
  # thirty would report a stability it was never measured for. `recorded_count` is its ROWS, which
  # exceeds `run_count` exactly when the description was carried by more than one example in a run.
  #
  # `outcome_words` IS ECHOED VERBATIM and never reworded into a verdict — the model's own
  # echo-don't-judge rule, which `SpecObservation#outcome_label` carries the reason for: nothing
  # platform-side validates that string, so quoting what arrived is the only reading that cannot be
  # wrong. An unrecognised word goes out unrecognised.
  #
  # `outcome_words` and `files_seen` are read through the ROW'S ACCESSORS, never off the struct
  # members: both aggregates are `ARRAY_AGG(…) FILTER (…)`, which is SQL NULL rather than an empty
  # array for a group with nothing to collect, and both accessors `Array()`-normalise that and sort
  # — so two rows carrying the same set serialize the same way instead of in whatever order the
  # planner returned.
  #
  # `unreported_outcome_count` is runs that recorded this description and said NOTHING about how it
  # ended. Not a pass, and counted as one nowhere: `#changed?` compares against
  # `reported_outcome_count` and not against `recorded_count`, precisely so a client that stopped
  # sending outcomes cannot manufacture a flip. Served so a client can see the same separation
  # rather than infer it.
  #
  # `shared_description` rides on EVERY row, in both lists, on the rule `serialized_history_row`'s
  # per-row `branch` follows: a client should be able to read a row's classification off the row
  # rather than off the list it arrived in. `multi_file` is beside it and is a DISCLOSURE rather
  # than a defect — the project's identity rule is semantic, so a test that moved is the same test
  # and keeps its history, but a reader looking for a flaky test in one file needs to know the
  # history spans two.
  def serialized_unstable_test_row(row)
    {
      name: row.name,
      recorded_count: row.recorded_count,
      run_count: row.run_count,
      reported_outcome_count: row.reported_outcome_count,
      unreported_outcome_count: row.unreported_outcome_count,
      failed_count: row.failed_count,
      failed_run_count: row.failed_run_count,
      outcome_words: row.outcome_words,
      files_seen: row.files_seen,
      multi_file: row.multi_file?,
      shared_description: row.shared_description?,
      spec_identity_id: row.spec_identity_id,
      renamed: row.renamed?,
      descriptions: row.descriptions
    }
  end

  # The contract the runtime rows below are served under — and, when they are `null`, the reason
  # they are. Served UNCONDITIONALLY, on the key-always-present rule `latest_run.shards` and
  # `serialized_unstable_tests_window` both argue for in full and which is not repeated here: a
  # client tests one thing rather than distinguishing an absent key from a null one, and a block
  # that explains a `null` is worthless if it is itself absent whenever the `null` happens.
  #
  # `grouped` IS THE LOAD-BEARING KEY, and it exists for the branch reason its flakiness sibling
  # gives, which binds at least as hard here. `SlowestTests#branch` states the rule for itself:
  # *"Runtimes compared across branches are runtimes of different code, so the window is
  # branch-anchored exactly as those are."* Unfiltered, `history_runs` is the INTERLEAVED
  # all-branch window `serialized_history_window` spends a paragraph warning about — and this
  # object is ANCHORED, so the damage is worse than a mixed total. The anchor would be whichever
  # branch happened to run last, and the ⭐ partition it decides would rank THAT branch's tests
  # against the window's other branch's history. So unfiltered, `SlowestTests.for` IS NOT CALLED AT
  # ALL — no anchor, no reads — and this boolean is what says so.
  #
  # It is read off whether the object was CONSTRUCTED, never re-spelled as `requested_branch ?
  # true : false`, on the rule the sibling states: a second copy of the gate is a second thing to
  # keep true. So `grouped` is exactly `slowest_tests != null`, in every response.
  #
  # `order` DESCRIBES `SlowestTests::Row#sort_key` TRUTHFULLY, all three keys and the nil rule:
  # `[total_seconds.nil? ? 1 : 0, -(total_seconds || 0.0), -recorded_count, spec_identity_id]`. The
  # NULLS LAST clause is named rather than left implicit because it is the one part a client would
  # get backwards by defaulting — a test nobody timed is not a test that cost nothing, and sorting
  # its nil as a zero would put it at whichever end the client's language happens to put nils.
  #
  # `tie_break_served: true`, and it is true because `spec_identity_id` GOES OUT ON THE ROW. All
  # four operands of the sort — the nil flag, the total, the appearance count and the identity —
  # are served, so a client CAN reproduce this exact order from what it holds. Had the identity
  # been withheld this would have had to say `false`: the final tie-break would not be
  # reproducible, and two tests totalling identically over the same number of runs would be a pair
  # a client could not order. That is the same honesty `serialized_history_window` shows in the
  # other direction, where the tie-break is an ingest sequence no row carries.
  #
  # `branch_scope` and `branch` are TWO keys rather than one interpolated token, and `branch` is
  # always served (`null` when the window was not narrowed) — `serialized_history_window` makes
  # both arguments in full. They carry the same values `history_window` and `unstable_tests_window`
  # carry in the same response, because all three describe the SAME window.
  def serialized_slowest_tests_window
    {
      order: "total_seconds_desc_nulls_last,recorded_count_desc,spec_identity_id_asc",
      tie_break_served: true,
      branch_scope: requested_branch ? "single_branch" : "all_branches",
      branch: requested_branch,
      grouped: !slowest_tests.nil?
    }
  end

  # WHICH TESTS COST THE MOST WALL CLOCK ACROSS RUNS — the agent-readable half of the "Slowest tests
  # over the window" panel `repositories#show` renders, and the roadmap's first axis of suite
  # intelligence ("per-test duration") at the grain the Project Goals pin as semantic.
  #
  # A DIFFERENT GRAIN FROM `latest_run.slowest_examples`, which is why it is served beside
  # `unstable_tests` rather than inside that block. `slowest_examples` reaches the per-example grain
  # of ONE run — `SlowestExamples.for(test_run)` is bounded to one run by construction — and this is
  # the same question over a window, matched to a DURABLE TEST rather than to a coordinate. An agent
  # holding thirty responses could not assemble it: no identity crosses the wire on that block, so
  # grouping client-side means grouping on `(file_path, line_number)`, which splits a moved test's
  # history in two, or on `name`, which survives a move but not a rename. `SlowestTests`' class
  # comment states both failure modes and what the identity grain buys instead: *"a test that moved
  # keeps its runtime history."*
  #
  # AND A DIFFERENT GRAIN FROM `unstable_tests`, which is the neighbour it most resembles. That
  # block groups on `spec_identity_id` too — the question is about outcomes on a DURABLE TEST — so
  # an annotated test that was REWORDED keeps one outcome history there, disclosed by the `renamed`
  # key on its own row. An unannotated renamed test is still two tests there, on the owner-settled
  # rule that an unannotated rename loses its history.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query — this file's governing rule, stated
  # in full on `serialized_spec_files`. `SlowestTests` is view-free, so the API and the panel name
  # the same tests in the same order off the same rows of the same window.
  #
  # OFF THE ALREADY-MEMOIZED WINDOW, so this adds NO run-window query — see `slowest_tests` below,
  # where the ⭐ ORDERING HAZARD that distinguishes this call site from the flakiness one is stated
  # in full. It is not a copy of that gate and must not be read as one.
  #
  # `null` — THE KEY STILL PRESENT — under an unfiltered window, and the argument for that is on
  # `serialized_slowest_tests_window` above where the boolean that explains it lives.
  #
  # AN EMPTY `rows` IS A REAL ANSWER HERE and is not the same state. Under a branch-scoped window
  # the object IS constructed, and `rows: []` beside `state: "ranked"` means "we ranked and this
  # suite holds nothing slow". The two must never serialize identically, which is what `state` is
  # for.
  #
  # ⭐ `state` IS LOAD-BEARING, not a convenience. An empty list has FOUR meanings here and
  # `SlowestTests`' class comment separates them: `no_runs` (the window is empty), `unrecorded` (the
  # anchor wrote no per-example rows), `unresolved` (it wrote rows and none of them has been matched
  # to a durable test yet) and `ranked`. Only the last may be read as "nothing in this suite is
  # slow". `Ingest::IdentityResolutionJob` is asynchronous, so `unresolved` is the ORDINARY state
  # for the seconds after an ingest — Vacuous Green exactly, in the shape this project keeps finding
  # it, and a block that served those four as one empty array would report a clean result for work
  # it did not do.
  #
  # `anchor_run` NAMES THE RUN THAT DECIDED MEMBERSHIP. The candidates are the newest run's slowest
  # tests and the window merely supplies their history, so a test that ran in the first twenty runs
  # of the window and not in the newest is NOT HERE — a partition the rows cannot be read to
  # discover. `test_run_id` goes out BESIDE `commit_sha` for the reason `unstable_test_runs` states:
  # a commit is not a key, since the same commit is legitimately ingested more than once.
  #
  # `recorded` / `resolved` / `excluded_unresolved_rows` are read off the object's OWN predicates,
  # CALLED rather than re-spelled here, on the rule `serialized_spec_files`' `#recorded?` gate
  # states: a controller-side copy of a predicate is free to drift the day the presenter's changes.
  # The same goes for `truncated`, `complete` and `untimed_count`.
  #
  # `truncated` / `unexamined_count` DISCLOSE THE CANDIDATE CAP, with both OPERANDS
  # (`candidate_count`, and `rows.length` the client already holds) beside the boolean so a client
  # can check the comparison rather than take it. `limit` is read off `SpecObservation::SLOWEST_LIMIT`
  # rather than restated here, on the precedent `serialized_slowest_examples` sets, so the response
  # cannot claim a bound the query did not apply.
  #
  # ⚠️ `null` VERSUS `0` IS CONTRACTUAL ON FIVE KEYS, and it is `SlowestTests::UNREAD` serialized
  # through rather than a shape to be tidied. `recorded_count`, `unresolved_count`,
  # `candidate_count`, `resolved_count` and `timed_count` are `nil` in every state that returned
  # before the read that would have produced them, and a `0` there would be wire-indistinguishable
  # from a window MEASURED to have excluded nothing — which is exactly the distinction these keys
  # exist to let a client draw. `serialized_unstable_tests` makes the identical split for its
  # `unnamed_count`.
  #
  # STRUCTURED COUNTS AND BOOLEANS, NOT PROSE — this endpoint's standing rule. `RepositoriesHelper`
  # words this same coverage for the panel and `SlowestTests` exposes four label readers
  # (`duration_label`, `slowest_label`, `coverage_label`, `appearance_label`); not one of them is
  # served. A machine client cannot act on "9 of 12" without parsing it, so the OPERANDS go out and
  # the client divides.
  #
  # AT MOST THREE READS of `spec_observations`, and ONE in the gating states — none of them new, and
  # none growing with the size of the suite or the length of the window. They are the panel's own
  # reads, `EXPLAIN`-certified in `spec/models/spec_observation_spec.rb`, so that certification
  # transfers rather than needing to be repeated in a request spec (the precedent
  # `serialized_slowest_examples` and `serialized_unstable_tests` both rely on). An unfiltered
  # request costs NONE, because the object is never constructed.
  def serialized_slowest_tests
    slowest = slowest_tests

    return nil if slowest.nil?

    {
      rows: slowest.rows.map { |row| serialized_slowest_test_row(row) },
      state: slowest.state.to_s,
      anchor_run: serialized_slowest_tests_anchor_run(slowest.anchor_run),
      run_count: slowest.run_count,
      recorded: slowest.recorded?,
      resolved: slowest.resolved?,
      excluded_unresolved_rows: slowest.excluded_unresolved_rows?,
      recorded_count: slowest.recorded_count,
      unresolved_count: slowest.unresolved_count,
      resolved_count: slowest.resolved_count,
      candidate_count: slowest.candidate_count,
      timed_count: slowest.timed_count,
      untimed_count: slowest.untimed_count,
      complete: slowest.complete?,
      truncated: slowest.truncated?,
      unexamined_count: slowest.unexamined_count,
      limit: SpecObservation::SLOWEST_LIMIT
    }
  end

  # The run the ⭐ partition was taken from, named as a REFERENCE rather than restated as a run
  # block. `test_run_id` leads and `commit_sha` rides beside it on `unstable_test_runs`' rule — a
  # commit is not a key, because a re-run, a retry or a second workflow ingests the same commit
  # again — and `branch` is served because the anchor is the one run whose branch decided which
  # tests are on the list at all.
  #
  # `null` — the key still present — in `:no_runs`, where the window held no run to anchor on. That
  # is the one state where there is no run to name, and it is exactly the state `state` reports.
  def serialized_slowest_tests_anchor_run(run)
    return nil if run.nil?

    {
      test_run_id: run.id,
      commit_sha: run.commit_sha,
      branch: run.branch,
      ingested_at: run.created_at.iso8601
    }
  end

  # ONE durable test's runtime across the window.
  #
  # `spec_identity_id` IS THE FIELD THIS WHOLE BLOCK EXISTS FOR, and it is the only stable join key
  # a client can carry between two responses. Neither `slowest_examples` nor `unstable_tests` serves
  # an identity, which is precisely why a client holding them cannot rebuild this ranking. It is
  # also what makes `tie_break_served: true` on the window block honest.
  #
  # `total_seconds` BESIDE `slowest_seconds`, never one without the other: sixty seconds is one
  # minute-long test or sixty runs of a one-second one, and a ranking ordered on the sum alone
  # cannot tell a reader which they are looking at. Neither is coalesced to `0.0` — a group nothing
  # timed serves `null`, on the rule `serialized_spec_files` states, because a zero there is an
  # invented measurement.
  #
  # ⭐ `moved` AND `renamed` ARE THE POINT OF THE IDENTITY GRAIN and no other key on this endpoint
  # can express either. `moved` is this test recorded under more than one spec file across the
  # window — the guarantee being KEPT rather than an anomaly, and a fact about where to go looking.
  # `renamed` is its description changing while its identity did not — the same disclosure
  # `unstable_tests` makes on its own rows, since both reads group on `spec_identity_id`.
  #
  # `descriptions` and `files_seen` are the OPERANDS behind those two booleans, so a client can see
  # what the flag is claiming rather than take it. Both are read through the Struct's own readers
  # and never off the raw attributes: the aggregates are `ARRAY_AGG(…) FILTER (…)`, i.e. SQL NULL
  # for a group with nothing to collect, and the readers are where the `Array()` wrap and the sort
  # live — so two rows carrying the same set serialize the same way.
  #
  # `repeated_within_run` says this test ran more than once in at least one run — a table-driven
  # loop or a shared example group — which is what separates "slow in twelve runs" from "run three
  # times in each of four". `recorded_count` and `run_count` are the two operands beside it.
  #
  # `timed` / `timed_count` / `untimed_count` keep a blank duration from being read as a zero. A row
  # that reaches this list untimed is ordinary, not a defect: an example that never ran has no
  # duration to report.
  def serialized_slowest_test_row(row)
    {
      spec_identity_id: row.spec_identity_id,
      total_seconds: row.total_seconds,
      slowest_seconds: row.slowest_seconds,
      run_count: row.run_count,
      recorded_count: row.recorded_count,
      timed_count: row.timed_count,
      untimed_count: row.untimed_count,
      timed: row.timed?,
      repeated_within_run: row.repeated_within_run?,
      moved: row.moved?,
      renamed: row.renamed?,
      descriptions: row.descriptions,
      files_seen: row.files_seen
    }
  end

  # The presenter, or `nil` when no ranking was allowed — memoized across the nil with `defined?`
  # rather than `||=`, for the reason `unstable_tests` states below and under the same double read
  # (`show` asks for the window block's `grouped` and then for the rows).
  #
  # ⭐ THE WINDOW IS HANDED IN REVERSED, AND THAT IS THIS METHOD'S WHOLE SUBTLETY — the one place
  # this gate is NOT a copy of its flakiness sibling, which sits ten lines below and is otherwise
  # line-for-line identical.
  #
  # `SlowestTests.for` documents its parameter as *"the window, ALREADY LOADED and OLDEST FIRST"*
  # and takes `runs.last` as its ANCHOR — the run that decides WHICH TESTS ARE IN THE LIST AT ALL
  # (its ⭐ PARTITION section). `history_runs` is `Repository#recent_test_runs`, ordered
  # `(created_at, id) DESC` — NEWEST first. Handing it in unreversed DOES NOT RAISE:
  # `validate_anchor!` checks tenancy only, and an old run of the same repository passes it. What
  # comes back is a fully-populated, plausible block that ranks the OLDEST run's slowest tests,
  # reports THAT run's figures in `recorded_count` / `resolved_count` / `timed_count`, and names it
  # in `anchor_run` — an answer to a question nobody asked, wearing the shape of the right one.
  # `spec/requests/api/v1/repository_slowest_tests_spec.rb` guards it by asserting the served
  # `anchor_run` is the NEWEST run of the window, which fails if this `.reverse` is dropped.
  #
  # The adjacent precedent is what makes it easy to walk into and is NOT a licence: `UnstableTests.for`
  # documents the same parameter with no ordering clause and is order- and anchor-indifferent — it
  # reads `runs.map(&:id)` and `runs.size` and nothing else, and says so — so `unstable_tests` hands
  # `history_runs` straight in and is right to. `spec_directory_window_growth` further down is the
  # OTHER call site that must reverse, and carries the same warning.
  #
  # `.reverse` AND NEVER `.reverse!`. `serialized_history` maps the same memoized array and
  # `serialized_history_window` declares `order: "ingested_at_desc,ingest_sequence_desc"` over it;
  # reversing in place would make the endpoint's own ordering contract a lie, in the same response
  # body, for every client reading `history`.
  #
  # NO SECOND WINDOW QUERY, and that is deliberate rather than incidental: `history_runs` is
  # materialized once, and both `UnstableTests` and `SlowestTests` document their window as handed
  # in precisely so two surfaces cannot come to be drawn on two windows that agree today with no
  # structural reason to keep agreeing.
  #
  # The branch gate lives HERE, in one place, so the boolean the window serves and the decision that
  # produced it cannot come apart — see `serialized_slowest_tests_window` for why an unfiltered
  # window is refused rather than answered.
  def slowest_tests
    return @slowest_tests if defined?(@slowest_tests)

    @slowest_tests =
      requested_branch && SlowestTests.for(repository, history_runs.reverse, branch: requested_branch)
  end

  # The presenter, or `nil` when no comparison was allowed — memoized, because `show` reads it
  # twice: once for the window block's `grouped` and once for the rows. Without the memo the whole
  # thing is built twice and the block's four reads become eight, which is what the cost examples
  # next door count.
  #
  # MEMOIZED ACROSS THE NIL — `defined?` rather than `||=` — so the memo means "already decided"
  # rather than "already truthy". That distinction is free TODAY: `requested_branch &&`
  # short-circuits before any read, so re-evaluating the nil case costs nothing and a `||=` would
  # behave identically. It stops being free the moment this gate consults anything that costs, and
  # the shape that cannot regress is the one that does not depend on the answer being truthy.
  #
  # The branch gate lives HERE, in one place, so the boolean the window serves and the decision that
  # produced it cannot come apart. See `serialized_unstable_tests_window` for why an unfiltered
  # window is refused rather than answered.
  def unstable_tests
    return @unstable_tests if defined?(@unstable_tests)

    @unstable_tests =
      requested_branch && UnstableTests.for(repository, history_runs, branch: requested_branch)
  end

  # The contract the growth-by-area rows below are served under — and, when they are `null`, the
  # reason they are. Served UNCONDITIONALLY, on the key-always-present rule `latest_run.shards` and
  # `serialized_unstable_tests_window` both argue for: a client tests one thing rather than
  # distinguishing an absent key from a null one, and a block that explains a `null` is worthless if
  # it is itself absent whenever the `null` happens.
  #
  # `grouped` IS THE LOAD-BEARING KEY, and it exists for the branch reason its flakiness sibling
  # gives, which binds at least as hard here. `SpecDirectoryWindowGrowth` picks its baseline with
  # two in-memory predicates — `TestRun#suite_size_measured?` and `TestRun#assembled_like?`, which
  # is `shard_count` equality — and NEITHER looks at `branch`. Handed the INTERLEAVED all-branch
  # window `serialized_history_window` warns about, the walk would anchor on a `main` run and
  # baseline against a `feature/x` run that happened to be sharded the same way, and report "this
  # area grew by 300 examples" where the truth is two different pieces of code. So unfiltered, the
  # object IS NOT CONSTRUCTED — no rows, and no read to produce them — and this boolean says so.
  #
  # Read off whether the object was CONSTRUCTED, never re-spelled as `requested_branch ? true :
  # false`. A second copy of the gate is a second thing to keep true, and the one that decides what
  # was read is the one worth serving. So `grouped` is exactly `directory_growth != null`.
  #
  # `grouped: true` IS NOT "SOMETHING WAS COMPARED", the same disclaimer the flakiness window
  # carries: the object is constructed for every branch-scoped ask, and what came of it is the
  # block's own business. Its `state` is what separates the eight answers.
  #
  # `order` names both keys and `tie_break_served` is TRUE, which is the honest reading here and
  # not the only block on this endpoint where it is. `SpecObservation.directory_growth_between`
  # orders by `ABS(anchor_count - baseline_count) DESC` then `path ASC`, and both operands and the
  # path go out on every row — so a client CAN reproduce this order from what it holds, unlike
  # `history` (whose tie-break is an ingest sequence no row carries) and `branches`.
  #
  # `basis` IS THE OBJECT'S OWN LOAD-BEARING LIMITATION, served as a token because a client cannot
  # act on the paragraph `spec_directory_window_growth.rb` spends on it. The figures compare TWO
  # ENDPOINTS of a thirty-run window; they are not a series over it. An area that added 300
  # examples in run 12 and deleted them again in run 25 reads `change: 0` here, indistinguishable
  # from an area nothing happened in — and a thirty-run heading over a two-run measurement is
  # exactly the claim a caption would otherwise imply and nothing looked at. `covered_run_count`
  # says how far apart the two endpoints are; this says that two is all there are.
  def serialized_directory_growth_window
    {
      order: "abs_change_desc,path_asc",
      tie_break_served: true,
      basis: "two_endpoints",
      branch_scope: requested_branch ? "single_branch" : "all_branches",
      branch: requested_branch,
      grouped: !spec_directory_window_growth.nil?
    }
  end

  # WHICH AREAS OF THE SUITE GREW OR SHRANK ACROSS THE BRANCH WINDOW — the agent-readable half of
  # the panel `repositories#show` renders from the same object, and the "in which areas" half of the
  # roadmap's growth axis, which is the one this endpoint has never been given.
  #
  # A DIFFERENT GRAIN FROM EVERYTHING IN `latest_run`, which is why it is served beside `history`.
  # `latest_run.spec_directories` carries a per-directory `recorded_count` for exactly ONE run, and
  # `serialized_history_row` carries run TOTALS with no area grain on any row. Neither is the other's
  # missing half: an agent holding both, for every row of the window, knows how much the suite grew
  # and nothing about where. Two responses could not be subtracted into this either — that is the
  # polling-and-differencing this file's opening comment exists to refuse.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query — this file's governing rule, stated
  # in full on `serialized_spec_files`. `SpecDirectoryWindowGrowth` is view-free, so the API and the
  # panel name the same areas, in the same order, off the same rows of the same window.
  #
  # OFF THE ALREADY-MEMOIZED WINDOW, so this adds NO run-window query — see
  # `spec_directory_window_growth` for the ORDER that window has to be handed over in, which is the
  # one thing about this block that is not shared with its flakiness sibling.
  #
  # `state` IS SERVED AS THE SYMBOL AND NEVER COLLAPSED TO A BOOLEAN OR TO `null`. The object
  # distinguishes eight states, seven of them absences, and its own comment is why they are not one:
  # "every earlier run on this branch reported no tests", "they were all assembled differently from
  # this one" and "the run at the far end recorded no per-example rows" are one blank panel and
  # three different things to go and fix. `comparable` rides beside it as the single boolean a
  # client that only wants the rows can branch on, read off the object's own predicate rather than
  # re-derived here from the symbol.
  #
  # THE HONESTY FIGURES ARE SERVED, NOT DROPPED, and they are the block's actual payload in seven of
  # the eight states. The baseline is WALKED from the far end of the window, so the comparison a
  # client is handed can be SHORTER than the window it asked over — `window_run_count` is what the
  # window holds and `covered_run_count`/`runs_back` are what the figures span, and a 26-run
  # comparison under a 30-run heading is a fact about the measurement rather than an implementation
  # detail. The two skip counts stay SPLIT rather than summed, on the object's own rule: a client
  # that stopped reporting totals and a branch whose sharding changed are two different repairs, and
  # a bare "4 runs were skipped" is a fact nobody can act on.
  #
  # BOTH COMMIT SHAS, so a client can say WHICH TWO RUNS the figure spans and go read them. They are
  # nullable for the reason the states are: the walk finds no baseline in four of them, and there is
  # no run to name. Anchor and baseline rather than "first" and "last" — the anchor is the newest
  # run of the window and the baseline is the OLDER end, which is the direction every `change` on
  # every row below is signed in.
  #
  # ⭐ THE SPAN IS NULL WHEREVER THE SHA IS — one predicate, `baseline_run`, read ONCE into a local
  # and used for all FOUR span keys, so the figures and the run they are counted to cannot come
  # apart. `#covered_run_count` is `runs_back + 1` and `runs_back` keeps its `0` default in exactly
  # the four states the walk landed on no baseline in, so serving it raw asserts a ONE-RUN
  # COMPARISON that was never taken: `anchor_unmeasured` would carry `covered_run_count: 1` beside
  # `window_run_count: 2` and `shortened: false` — the block's own claim that the span equals the
  # window, and its own figures denying it, two keys apart. The degenerate end is worse: an unknown
  # `?branch=` selects ZERO runs and would serve a comparison spanning one run over a window holding
  # none, next to an `anchor_commit_sha` of `null`.
  #
  # `shortened` IS THE FOURTH, and it fails in the opposite direction from the other three, which is
  # why enumerating from `anchor_unmeasured` alone once left it ungated. The four no-baseline states
  # split in half on this key. `anchor_unmeasured` and `no_earlier_run` never enter the walk, so the
  # skip counters keep their `0` default and `shortened?` is benignly `false`. `no_measured_baseline`
  # and `no_comparable_composition` are reached ONLY from inside the walk, and only by every earlier
  # run being skipped — `skipped_count.positive?` is the very mechanism that reaches them — so
  # `shortened?` is necessarily `true` in both, ALWAYS, not merely sometimes. Ungated it printed
  # `shortened: true` beside `covered_run_count: null` and `baseline_commit_sha: null`: a shortened
  # span asserted for a comparison that was never taken. `false` would be no better than `true`
  # here — it is equally a claim about a span, namely that it equals the window — so the answer is
  # `null`, the same answer the other three give, for the same reason.
  #
  # The two SKIP COUNTS are NOT gated and must not be: they are facts about the walk rather than
  # about the span, they are the actionable half of both those states ("two earlier runs reported no
  # tests"), and they are true whether or not the walk found somewhere to land.
  #
  # The panel never prints the span in these states — `spec_directory_window_growth_span_sentence`
  # is reached only under `comparable? && any_movement?` — so this endpoint is the FIRST surface that
  # can be wrong with it, and a fabricated span sitting among the honesty fields is the exact failure
  # they exist to prevent. `null` is the same answer `baseline_commit_sha` already gives, and it is a
  # PINNED CONTRACT rather than a default: the spec asserts the keys in every one of the four.
  # The four states that DID land on a baseline — `comparable` and the three recorded-rows absences
  # — carry a true span, and it is their actionable payload ("the run that recorded nothing is two
  # back"), so the gate is `baseline_run` and never `comparable?`.
  #
  # `truncated` DISCLOSES THE CAP with both operands beside it. `directory_count` is counted BEFORE
  # `SpecObservation::MOVED_DIRECTORIES_LIMIT` applies (a window function, so it runs before the
  # `LIMIT`), which is what makes the comparison answerable at all; `limit` is read off that
  # constant rather than restated — this call site passes no `limit:`, so the constant IS the bound
  # the query applied. It is the object's default that makes that true, not the serving of it: the
  # object does not expose the limit it was built with, so a caller that ever passed `limit: 5` here
  # would need this key taught to follow it rather than re-read the constant.
  #
  # `baseline_recorded_count`/`anchor_recorded_count` are the DENOMINATORS the recorded-rows states
  # turn on — how many per-example rows each end wrote in total — and deliberately not
  # `TestRun#total_specs_count`, which is re-derived by SUM over shard reports and can legitimately
  # differ from the rows a run actually wrote. Every figure on this block is counted off those rows.
  #
  # ⭐ THOSE COUNTS ARE GATED ON `baseline_run` TOO, on the same rule as the span keys above them.
  # `SpecDirectoryWindowGrowth.from_tuples` is the ONLY path that reads the aggregate, and the only
  # one that passes `baseline_run:` — so the four states the walk short-circuits into before it
  # (`anchor_unmeasured`, `no_earlier_run`, `no_measured_baseline`, `no_comparable_composition`)
  # carry no totals at all and fall back to the object's `0` defaults. `baseline_run.nil?` is
  # therefore EXACTLY "the totals were never counted", with no third case. Served raw, those
  # defaults would print `anchor_recorded_count: 0` for an anchor that wrote four hundred rows, and
  # `directory_count: 0` for a comparison whose query was never issued — fabricated denominators
  # sitting among the fields that exist to be trustworthy. `truncated` rides along because it is
  # DERIVED from `directory_count` (`directory_count > rows.size`): once its operand is `null`, a
  # `false` beside it would be a completeness claim about a list this same body declares unknown.
  #
  # NOT `comparable?`, which is the weaker predicate and would null too much: `neither_recorded`,
  # `baseline_unrecorded` and `anchor_unrecorded` are non-comparable but DID read the aggregate, so
  # their totals are true — including their genuine `0`s — and are the actionable half of those
  # states. Four of the eight states carry these figures; the other four have none to carry.
  #
  # ONE READ OF `spec_observations` AT MOST, and none at all where there is nothing to compare. The
  # walk is pure in-memory predicates over rows already loaded, and the comparison itself is two run
  # ids in an `IN` list whatever the window's length — already plan-certified at the seeded table
  # size in `spec/models/spec_observation_spec.rb`, so that certification transfers rather than
  # needing to be repeated here. Same argument `serialized_unstable_tests` makes for itself.
  def serialized_directory_growth
    growth = spec_directory_window_growth

    return nil if growth.nil?

    baseline = growth.baseline_run

    {
      state: growth.state,
      comparable: growth.comparable?,
      rows: growth.rows.map { |row| serialized_directory_growth_row(row) },
      window_run_count: growth.window_run_count,
      covered_run_count: baseline && growth.covered_run_count,
      runs_back: baseline && growth.runs_back,
      shortened: baseline && growth.shortened?,
      skipped_unmeasured_count: growth.skipped_unmeasured_count,
      skipped_assembled_differently_count: growth.skipped_assembled_differently_count,
      anchor_commit_sha: growth.anchor_run&.commit_sha,
      baseline_commit_sha: baseline&.commit_sha,
      directory_count: baseline && growth.directory_count,
      truncated: baseline && growth.truncated?,
      baseline_recorded_count: baseline && growth.baseline_recorded_count,
      anchor_recorded_count: baseline && growth.anchor_recorded_count,
      limit: SpecObservation::MOVED_DIRECTORIES_LIMIT
    }
  end

  # One area's movement across the window, and BOTH OPERANDS it was taken across — never one of the
  # labels the row builds for the panel. `SpecDirectoryWindowGrowth::Row` carries `change_label`,
  # `change_reading`, `baseline_count_label` and `anchor_count_label`, which are typographic and
  # screen-reader spellings of these same numbers: a U+2212 for a negative, `"±0"` for an area that
  # did not move, `"New area"` where a delta would be arithmetic on a side that was never measured,
  # and delimited numerals throughout. A client served those would be splitting strings and
  # stripping glyphs to compare two rows. `serialized_unstable_test_row` set this rule; this block
  # is where it costs the most, because the labels here are the panel's whole vocabulary.
  #
  # `previous_count`/`latest_count` are the aggregate's own two sides and are the parent Struct's
  # names; they go out as `baseline_count`/`anchor_count`, the names the window object itself uses
  # for the two ends of the comparison and the two shas above are served under. The translation
  # happens once, here, rather than in every client's head.
  #
  # `moved`, `new_area` and `removed_area` are the three states the label collapses, served as the
  # booleans they are. `new_area` and `removed_area` are NOT derivable from `change` alone — an area
  # at zero on one side is a real absence, and `+40` against an absent side reads identically to an
  # existing area that gained forty examples, which is the one distinction a client scanning this
  # list most needs. The block that holds this row has already established that BOTH runs recorded
  # rows, which is what makes a zero on one side that area's own absence rather than a run that
  # recorded nothing anywhere.
  def serialized_directory_growth_row(row)
    {
      path: row.path,
      baseline_count: row.previous_count,
      anchor_count: row.latest_count,
      change: row.change,
      moved: row.moved?,
      new_area: row.new_area?,
      removed_area: row.removed_area?
    }
  end

  # The contract the RUN-OVER-RUN growth rows below are served under — and, when they are `null`,
  # the reason they are. Served UNCONDITIONALLY, on the key-always-present rule
  # `serialized_directory_growth_window` and `latest_run.shards` both argue for: a block that
  # explains a `null` is worthless if it is itself absent whenever the `null` happens.
  #
  # `_window` NAMES THE CONTRACT BLOCK HERE, NOT A RUN WINDOW — the suffix this endpoint has used
  # three times for "the facts that decide how the array beside it may be read". This comparison
  # spans exactly TWO runs and `basis` says so in a token rather than leaving the suffix to be read
  # as a claim about depth. The pairing is kept because a client that learned the shape once
  # (`history_window`/`history`, `unstable_tests_window`/`unstable_tests`,
  # `directory_growth_window`/`directory_growth`) should not have to learn a fourth.
  #
  # ⭐ `state` LIVES HERE AND NOT ON THE ROWS BLOCK, WHICH IS WHERE THIS BLOCK DIVERGES FROM ITS
  # WINDOW SIBLING AND WHY. There, `state` rides on the rows block because that block is `null`
  # only when the object was never constructed, and `grouped` out here covers that one case. Here
  # there are TWO ways to have no rows — the object was not constructed (no runs to compare) and
  # the object was constructed and could not compare — and a `state` on the rows block would be
  # absent in exactly the first of them. So the nine-way answer is served on the block that is
  # always present, and the rows block carries figures only.
  #
  # THE STATE ENUMERATION, in full, because a client must be able to enumerate it:
  #
  # * `no_latest_run` — CI has never reported. Serializer-level; see `spec_directory_growth`.
  # * `no_previous_run` — there is a latest run and no earlier run on its branch to compare it
  #   against. Serializer-level, and it covers TWO shapes that `branch` separates: a `branch` of
  #   `null` is a latest run whose client sent no branch (there is no branch to compare on, and
  #   `Repository#previous_test_run_on_branch` refuses to pool anonymous runs into a fictional
  #   history), and a named `branch` is a genuine first run on that branch.
  # * `latest_unmeasured`, `previous_unmeasured`, `assembled_differently` — `SpecDirectoryGrowth`'s
  #   three pre-query states, decided from the two runs alone.
  # * `neither_recorded`, `previous_unrecorded`, `latest_unrecorded` — its three row-decided states.
  # * `comparable` — the rows block below is non-null.
  #
  # The first two are ADDED AT THIS CALL SITE and are not model states, deliberately.
  # `SpecDirectoryGrowth.for` dereferences its second argument on its second line, so it must not be
  # handed a nil; widening it to accept one would change a contract the dashboard already guards for
  # itself (`repositories_controller.rb`, `if @latest_test_run && @previous_test_run`). The guard is
  # duplicated here rather than the model relaxed, and `no_previous_run` is a DISTINCT token from
  # `previous_unmeasured` because they are different repairs: "there is nothing to compare against"
  # against "the run we compared against reported no tests".
  #
  # `comparable` RIDES BESIDE `state` as the single boolean a client that only wants the rows can
  # branch on, read off the object's own predicate rather than re-derived from the symbol — and it
  # is exactly `directory_run_growth != null`, so there is one boolean here and not two.
  #
  # NO `?branch=` GATE, AND THAT IS THE FEATURE. `branch_scope` is the constant `single_branch`
  # because this comparison is branch-correct BY CONSTRUCTION rather than by a parameter:
  # `Repository#previous_test_run_on_branch` scopes to the latest run's own branch and refuses a
  # blank one. So `branch` names the branch the comparison WAS MADE ON — read off the latest run,
  # never off `requested_branch`, which narrows `history` and must not be read as having narrowed
  # this. Like `latest_run`, this block is NOT re-anchored by `?branch=`: under `?branch=main` on a
  # repository whose newest run is on `feature/x`, this still compares the two newest `feature/x`
  # runs, and `branch` says `feature/x` so the two cannot be confused. And like `latest_run` again,
  # it IS re-anchored by `?commit_sha=` — the one parameter that moves the anchor. Under an explicit
  # ask `anchor_commit_sha` and `branch` are the NAMED run's, and the baseline is the run before THAT
  # one on ITS branch, because `previous_test_run_on_branch` is handed the very `latest_test_run`
  # memo `latest_run` was built from. Both halves are stated here deliberately: this block is one of
  # the few that enumerates what does and does not move it, and an enumeration that named only the
  # parameter with no effect would be the more misleading half to leave standing alone.
  #
  # `basis` IS WHAT SEPARATES THIS PAIR FROM THE ONE ABOVE IT, and it is the key a client reads to
  # know which of the two growth measurements it is holding. `two_endpoints` there says the figures
  # are the two ends of a thirty-run window and not a series over it; `previous_run_on_branch` here
  # says the baseline is one specific run, named by `baseline_commit_sha`, and that the comparison
  # therefore has NO such gap in it — an area that gained 300 examples and gave them back cannot
  # hide inside a two-run comparison. Spelled as the baseline's RULE rather than as "adjacent_runs",
  # which would be read as adjacent in the history `history` serves and is not what this is: the two
  # runs are consecutive ON THEIR BRANCH, and the all-branch history routinely has other branches'
  # runs between them.
  #
  # `order` and `tie_break_served` are the WINDOW SIBLING'S OWN VALUES because they are the same
  # query's: `SpecObservation.directory_growth_between` orders by `ABS(...) DESC` then `path ASC`,
  # and both operands and the path go out on every row, so a client can reproduce this order from
  # what it holds.
  #
  # `anchor_commit_sha`/`baseline_commit_sha` NAME THE TWO RUNS, under the sibling's names rather
  # than "latest"/"previous", because the ROWS below are served as `anchor_count`/`baseline_count`
  # and a client must be able to tell which sha each operand was counted on. ANCHOR IS THE LATEST
  # RUN and BASELINE IS THE PREVIOUS ONE, which is the direction every `change` is signed in. Both
  # are nullable and independently so: `baseline_commit_sha` is `null` in both serializer states,
  # and `anchor_commit_sha` in `no_latest_run` alone.
  def serialized_directory_run_growth_window
    growth = spec_directory_growth

    {
      order: "abs_change_desc,path_asc",
      tie_break_served: true,
      basis: "previous_run_on_branch",
      branch_scope: "single_branch",
      branch: latest_test_run&.branch,
      state: growth&.state || (latest_test_run.nil? ? :no_latest_run : :no_previous_run),
      comparable: growth&.comparable? || false,
      anchor_commit_sha: latest_test_run&.commit_sha,
      baseline_commit_sha: previous_test_run&.commit_sha
    }
  end

  # WHICH AREAS OF THE SUITE GREW OR SHRANK IN THE LATEST PUSH — the agent-readable half of the
  # "Areas that grew or shrank" panel `repositories#show` renders from the same object, off the same
  # two runs, in the same order. It is the question the dashboard answers with no parameter at all
  # and this endpoint could not be asked: `directory_growth` beside it needs a `?branch=` and then
  # answers about the two ends of a thirty-run window, which is a different measurement.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query — this file's governing rule, stated
  # in full on `serialized_spec_files`. `SpecDirectoryGrowth` is view-free, so the API and the panel
  # cannot name different areas or different operands for the same repository.
  #
  # ⭐ `null` IN EVERY NON-COMPARABLE STATE, AND NOT A BLOCK OF ZEROS. The window sibling can gate
  # its honesty figures KEY BY KEY, on `baseline_run`, because its object keeps them in four of its
  # eight states — the four its aggregate read reaches — and drops them in the other four; this
  # object keeps them in ONE state only, so there is no per-key line to draw and the whole block
  # goes. (Seven-of-eight is the count of the window sibling's ABSENCE states, not of the states
  # that retain totals; it is a different figure and does not belong to this argument.)
  # `SpecDirectoryGrowth.from_tuples` returns `new(state: :previous_unrecorded)` and friends WITHOUT
  # the counts it just read, so every aggregate falls back to its `0` default. Serving them raw
  # would print `anchor_recorded_count: 0` for a latest run that recorded four hundred rows — a
  # fabricated denominator sitting among the fields that exist to be trustworthy, which is the
  # failure the sibling's ⭐ gates exist to prevent, refused here by a different route. The
  # actionable half of those states is the `state` token, and it is served unconditionally one key
  # up.
  #
  # So this block is non-null exactly when `directory_run_growth_window.comparable` is true, and
  # every figure in it was counted off the rows the `rows` array lists.
  #
  # ROWS THROUGH `serialized_directory_growth_row`, SHARED VERBATIM WITH THE WINDOW BLOCK and not a
  # second copy of it. That method is written entirely against `SpecDirectoryGrowth::Row` — `change`,
  # `moved?`, `new_area?` and `removed_area?` are all defined on the parent Struct, and
  # `SpecDirectoryWindowGrowth::Row` inherits them — so the two growth blocks read alike row for row,
  # including the `previous_count`/`latest_count` → `baseline_count`/`anchor_count` translation and
  # the rule against serving the panel's `*_label`/`change_reading` strings.
  #
  # `truncated` DISCLOSES THE CAP with both operands beside it, exactly as the sibling does:
  # `directory_count` is counted BEFORE the `LIMIT` applies (a window function, so it runs first),
  # and `limit` is read off `SpecObservation::MOVED_DIRECTORIES_LIMIT` rather than restated —
  # this call site passes no `limit:`, so the constant IS the bound the query applied.
  #
  # `baseline_recorded_count`/`anchor_recorded_count` are the DENOMINATORS the recorded-rows states
  # turn on, and deliberately not `TestRun#total_specs_count`, which is re-derived by SUM over shard
  # reports and can legitimately differ from the rows a run actually wrote.
  #
  # ONE READ OF `spec_observations` AT MOST, and none at all in five of the nine states: the two
  # serializer states never construct the object, and its own gate short-circuits three more before
  # any query. The comparison itself is two run ids in an `IN` list — the same aggregate already
  # plan-certified in `spec/models/spec_observation_spec.rb`, so that certification transfers.
  def serialized_directory_run_growth
    growth = spec_directory_growth

    return nil unless growth&.comparable?

    {
      rows: growth.rows.map { |row| serialized_directory_growth_row(row) },
      directory_count: growth.directory_count,
      truncated: growth.truncated?,
      baseline_recorded_count: growth.previous_recorded_count,
      anchor_recorded_count: growth.latest_recorded_count,
      limit: SpecObservation::MOVED_DIRECTORIES_LIMIT
    }
  end

  # One area's RUNTIME movement between two runs, its two operands, and the three different absences
  # that all render as an empty Change cell.
  #
  # A NEW METHOD AND NOT `serialized_directory_growth_row`, WHICH CANNOT BE REUSED HERE. That method
  # is written entirely against `SpecDirectoryGrowth::Row` — `previous_count`/`latest_count`,
  # `moved?`, `new_area?`, `removed_area?` — and `SpecDirectoryWindowGrowth::Row` INHERITS that
  # Struct, which is the whole reason those two blocks share it. `SpecDirectoryRuntimeGrowth::Row` is
  # an INDEPENDENT Struct with seconds operands and a predicate the count Struct does not have, so a
  # shared serializer would be a method branching on which Struct it was handed.
  #
  # `previous_seconds`/`latest_seconds` are the aggregate's own two sides and are the model's names;
  # they go out as `baseline_seconds`/`anchor_seconds`, this endpoint's wire convention for the two
  # ends of a comparison and the names `anchor_commit_sha`/`baseline_commit_sha` one key up give
  # them. The same translation `serialized_directory_growth_row` makes for the counts, made once here
  # rather than in every client's head.
  #
  # ⭐ THREE PREDICATES, BECAUSE THERE ARE THREE DIFFERENT ABSENCES AND THE MODEL KEEPS THEM APART.
  # `change` is `null` when an area is NEW, when it was REMOVED, and when both runs ran it and one of
  # them reported no timing for it — and those are three different things to go and fix. `comparable`
  # says only that there is nothing to subtract; `new_area`/`removed_area` say the area is on one side
  # only; `timing_gap` says both runs HAVE this area and the telemetry, not the code, is what is
  # missing. Collapsing them re-creates exactly the confusion `SpecDirectoryRuntimeGrowth::Row` spends
  # paragraphs refusing.
  #
  # `change`, `baseline_seconds` and `anchor_seconds` ARE LEGITIMATELY `null` and are served as the
  # nils they are — never coerced to `0`. `SUM` skips NULLs silently and `duration_seconds` is
  # nullable by design, so a zero here would be "this side was never timed" made byte-identical to
  # "this area took no time", which is the one reading the whole panel exists to refuse.
  #
  # NO VIEW STRINGS. `previous_label`, `latest_label`, `coverage_label`, `change_label` and
  # `change_reading` are typographic and screen-reader spellings of these same numbers — a U+2212 for
  # a negative, `"±0"`, `"not reported"`, `"New area"` — and a client served those would be splitting
  # strings and stripping glyphs to compare two rows. The rule `serialized_directory_growth_row`
  # states, held at the grain where the labels are richest.
  def serialized_directory_runtime_growth_row(row)
    {
      path: row.path,
      baseline_seconds: row.previous_seconds,
      anchor_seconds: row.latest_seconds,
      change: row.change,
      comparable: row.comparable?,
      moved: row.moved?,
      new_area: row.new_area?,
      removed_area: row.removed_area?,
      timing_gap: row.timing_gap?
    }
  end

  # The contract the RUN-OVER-RUN RUNTIME growth rows below are served under — and, when they are
  # `null`, the reason they are. Served UNCONDITIONALLY, on the key-always-present rule every window
  # block on this endpoint holds: a block that explains a `null` is worthless if it is itself absent
  # whenever the `null` happens.
  #
  # `_window` NAMES THE CONTRACT BLOCK, NOT A RUN WINDOW — the suffix this endpoint has now used four
  # times for "the facts that decide how the array beside it may be read". This comparison spans
  # exactly TWO runs and `basis` says so in a token.
  #
  # ⭐ TWELVE STATES, AND THE ENUMERATION IS THE POINT. `SpecDirectoryRuntimeGrowth` has TEN of its
  # own — three MORE than its count sibling, because this grain has a second kind of absence:
  #
  # * `no_latest_run` — CI has never reported. ADDED AT THIS CALL SITE; see the accessor.
  # * `no_previous_run` — there is a latest run and no earlier run on its branch. ADDED HERE too, and
  #   it covers the same two shapes `branch` separates for the count sibling: a `null` branch is a
  #   latest run whose client sent none, a named branch is a genuine first run on it.
  # * `latest_unmeasured`, `previous_unmeasured`, `assembled_differently` — the three pre-query
  #   states, decided from the two runs alone and short-circuiting the read.
  # * `neither_recorded`, `previous_unrecorded`, `latest_unrecorded` — a side wrote no per-example
  #   ROWS at all (a client that posts only totals).
  # * `neither_timed`, `previous_untimed`, `latest_untimed` — THE GRAIN THE COUNT SIBLING HAS NO
  #   EQUIVALENT OF. A side recorded rows and none of them carried a duration. "The previous run
  #   recorded no per-example detail" and "the previous run reported no timings" are the same blank
  #   panel and two entirely different things to go and fix, which is why the model asks the RECORDED
  #   questions first and the TIMED ones only of a side that has rows.
  # * `comparable` — the rows block below is non-null.
  #
  # `comparable` RIDES BESIDE `state` as the single boolean a client that only wants the rows can
  # branch on, read off the object's own predicate rather than re-derived from the symbol — and it is
  # exactly `directory_runtime_growth != null`, so there is one boolean here and not two.
  #
  # ⭐ `order` IS THE COUNT SIBLING'S STRING PLUS `_nulls_last`, AND THE DIFFERENCE IS NOT COSMETIC.
  # `SpecObservation.directory_runtime_growth_between` orders by `ABS(...) DESC NULLS LAST`, and the
  # count read has no such clause because a `COUNT` is never NULL. Here the ordering key IS nil for
  # every area a side did not time, and those rows therefore sort LAST rather than first — which is
  # the whole reason a listed row can be untimed at all (the movement ran out before the cap did).
  # Copying `abs_change_desc,path_asc` across would be a token a client could not reproduce this
  # order from, so the token states what the query actually asked.
  #
  # NO `?branch=` GATE, AND THAT IS THE FEATURE — `branch_scope` is the constant `single_branch`
  # because `Repository#previous_test_run_on_branch` scopes to the latest run's OWN branch and
  # refuses a blank one, so this is branch-correct by construction rather than by a parameter. Like
  # `latest_run` and the count pair, this block is NOT re-anchored by `?branch=`: `branch` names the
  # branch the comparison WAS MADE ON, read off the latest run and never off `requested_branch`. And
  # like both of them it IS re-anchored by `?commit_sha=`, the one parameter that moves the anchor:
  # `anchor_commit_sha` and `branch` become the NAMED run's and the baseline the run before THAT one
  # on ITS branch, off the same `latest_test_run` memo. That is what keeps the two growth windows
  # under one request from sitting on two different runs — neither chooses, both follow.
  #
  # `basis` is `previous_run_on_branch`, the count pair's token and for its reason: the baseline is
  # one specific run, named by `baseline_commit_sha`, so the comparison has no gap in it — an area
  # that gained a minute and gave it back cannot hide inside a two-run comparison.
  #
  # `anchor_commit_sha`/`baseline_commit_sha` NAME THE TWO RUNS under the sibling's names, because
  # the ROWS below are served as `anchor_seconds`/`baseline_seconds` and a client must be able to
  # tell which sha each operand was summed on. ANCHOR IS THE LATEST RUN and BASELINE IS THE PREVIOUS
  # ONE, which is the direction every `change` is signed in. Both are nullable and independently so.
  def serialized_directory_runtime_growth_window
    growth = spec_directory_runtime_growth

    {
      order: "abs_change_desc_nulls_last,path_asc",
      tie_break_served: true,
      basis: "previous_run_on_branch",
      branch_scope: "single_branch",
      branch: latest_test_run&.branch,
      state: growth&.state || (latest_test_run.nil? ? :no_latest_run : :no_previous_run),
      comparable: growth&.comparable? || false,
      anchor_commit_sha: latest_test_run&.commit_sha,
      baseline_commit_sha: previous_test_run&.commit_sha
    }
  end

  # WHICH AREAS OF THE SUITE GOT SLOWER OR FASTER IN THE LATEST PUSH — the agent-readable half of the
  # panel `repositories#show` renders from the same object, off the same two runs, in the same order.
  #
  # ⭐ NOT A RESTATEMENT OF `directory_run_growth`, AND NEITHER IS DERIVABLE FROM THE OTHER. That
  # block ranks areas by how their example COUNT moved; this one ranks them by how their summed
  # example TIME moved. `SpecDirectoryRuntimeGrowth`'s class comment carries the argument in full:
  # an area where somebody made an existing spec slow adds ZERO examples, so its
  # `ABS(latest_count - previous_count)` is `0`, it sorts last on that block and falls off the cap —
  # it is not a row there missing a column, it is not on that list at all. The independence runs both
  # ways: splitting one slow spec into four fast ones is `+3` examples and LESS time.
  #
  # It is also the grain `history` stops one short of. `test_runs.duration_seconds` is one figure per
  # run, so an agent holding every other key here can be told the run got ninety seconds slower and
  # can never ask WHERE. The per-area grain exists only in `spec_observations`.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query — this file's governing rule, stated
  # in full on `serialized_spec_files`. `SpecDirectoryRuntimeGrowth` is view-free, so the API and the
  # panel cannot name different areas or different operands for the same repository.
  #
  # ⭐ `null` IN EVERY NON-COMPARABLE STATE, AND THE COUNT SIBLING'S ARGUMENT FOR THAT DOES NOT
  # TRANSFER VERBATIM — so here is the one that does. There, `SpecDirectoryGrowth.from_tuples`
  # returns its row-decided states WITHOUT the counts it just read, so serving them raw would print
  # `anchor_recorded_count: 0` for a run that recorded four hundred rows. `SpecDirectoryRuntimeGrowth`
  # does the opposite deliberately: `from_tuples` passes `**totals` into EVERY state it constructs,
  # so in its six row-derived absence states the four denominators are real. Only the three gate
  # states, which never ran a query, carry the `0` defaults.
  #
  # It goes `null` anyway, for three reasons in order. (1) A key whose presence rule is "populated in
  # six of nine model states and zeroed in three" is a contract a client cannot hold in its head;
  # "non-null exactly when `directory_runtime_growth_window.comparable` is true" is one sentence and
  # is the rule the two shipped growth blocks already teach. (2) A per-key gate would not actually
  # eliminate the fabricated-denominator failure — the three gate states would still carry zeros —
  # it would only narrow it, at the cost of that rule. (3) The actionable half of every
  # non-comparable state is the `state` token, served unconditionally one key up.
  #
  # Serving the honest totals in the six row-derived states is a well-formed enhancement to the
  # window block and deliberately NOT smuggled in here.
  #
  # ⭐ ALL FOUR DENOMINATORS, NOT THE TWO THE COUNT SIBLING SERVES. This block has two grains of
  # absence and therefore two grains of denominator: how many rows each run RECORDED, and how many of
  # those carried a TIMING. The model's own rule — "1,204 examples reported a timing" is 1,204 of
  # something unstated — and the whole reading this block turns on is whether an area got faster or
  # merely went quiet. The count sibling has only the recorded pair because it has no timing grain.
  #
  # `truncated` DISCLOSES THE CAP with both operands beside it: `directory_count` is counted BEFORE
  # the `LIMIT` applies (a window function, so it runs first), and `limit` is read off
  # `SpecObservation::RETIMED_DIRECTORIES_LIMIT` rather than restated — this call site passes no
  # `limit:`, so the constant IS the bound the query applied. A DIFFERENT constant from the count
  # sibling's `MOVED_DIRECTORIES_LIMIT`, which happens to hold the same number today and is not the
  # same bound.
  #
  # ONE READ OF `spec_observations` AT MOST, and none at all in five of the twelve states: the two
  # serializer states never construct the object, and its own gate short-circuits three more before
  # any query. `SpecObservation.directory_runtime_growth_between` is already plan-certified in
  # `spec/models/spec_observation_spec.rb`, so that certification transfers.
  def serialized_directory_runtime_growth
    growth = spec_directory_runtime_growth

    return nil unless growth&.comparable?

    {
      rows: growth.rows.map { |row| serialized_directory_runtime_growth_row(row) },
      directory_count: growth.directory_count,
      truncated: growth.truncated?,
      baseline_recorded_count: growth.previous_recorded_count,
      anchor_recorded_count: growth.latest_recorded_count,
      baseline_timed_count: growth.previous_timed_count,
      anchor_timed_count: growth.latest_timed_count,
      limit: SpecObservation::RETIMED_DIRECTORIES_LIMIT
    }
  end

  # The contract the PER-FILE growth rows below are served under — and, when they are `null`, which
  # of the two reasons applies. Served UNCONDITIONALLY, on the key-always-present rule the two
  # blocks above it argue for: a block that explains a `null` is worthless if it is itself absent
  # whenever the `null` happens, and here it is absent on the commonest request of all — the one
  # that named no area.
  #
  # ⭐ `path` IS THE ASK RESTATED, AND IT IS THE DISCRIMINATOR. The rows block is `null` in two
  # different situations and a client must be able to tell them apart:
  #
  # * `path` is `null` — YOU DID NOT ASK. No `?spec_directory=` reached the server, or the shape it
  #   carried was not a string (`RequestedSpecDirectoryParam` treats a malformed shape as no ask at
  #   all, which is why this is never echoed from the raw parameter).
  # * `path` is set and `comparable` is `false` — you asked, and the comparison this drills out of
  #   refuses. `state` says which of the eight refusals.
  # * `path` is set and `comparable` is `true` — the rows block is populated.
  #
  # So the rows block is non-null exactly when `path` is non-null AND `comparable` is true. This is
  # the same separation `serialized_spec_directory_files` keeps between *"you did not ask"* and
  # *"the area you asked about has no rows"*, reached the other way round: that key is `null`
  # wholesale when unasked, and this one cannot be, because its `null` has a second cause to
  # explain.
  #
  # ⭐ `state` AND `comparable` ARE THE PARENT'S VERDICT, READ OFF THE PARENT — never re-derived and
  # never read off this drill-in's own object, which is not even constructed when nobody asked.
  # `SpecDirectoryFileGrowth` carries the parent's state verbatim and refuses to build anything the
  # moment the parent is not comparable, and its class comment gives the load-bearing reason: two of
  # the six model states (`previous_unrecorded`/`latest_unrecorded`) are facts about a RUN, and
  # everything this object reads is narrowed to one area. An area only the latest run recorded has
  # zero previous-side rows — `previous_unrecorded` spelled identically and meaning something else
  # entirely. So this block's `state` is `directory_run_growth_window.state`, always, by
  # construction: the drill-in is ABSENT whenever the block it drills out of cannot compare, and it
  # never offers a second opinion about two runs.
  #
  # The safe navigation is LOAD BEARING and not stylistic — `spec_directory_growth` is `nil` in the
  # two serializer-level states, and the same `latest_test_run.nil?` fallback the sibling window
  # block uses tells those two apart off the one memoized accessor.
  #
  # NO SECOND SPELLING OF THE OPERANDS. `branch`, `anchor_commit_sha` and `baseline_commit_sha` are
  # served once, on `directory_run_growth_window`, and are identical here by construction — this is
  # the SAME comparison between the SAME two runs, narrowed to one area. Repeating them would be two
  # blocks under one request naming one run two ways, which is the hazard the shared
  # anchor/baseline vocabulary exists to prevent.
  #
  # `limit` LIVES HERE rather than on the rows block, unlike its sibling's: it is a fact about how
  # the array beside it may be read, and a client that asked for an area and got `null` should still
  # be able to learn what a populated answer would have been capped at. Read off
  # `SpecObservation::SPEC_DIRECTORY_FILE_GROWTH_LIMIT` rather than restated — it is its own
  # constant, neither the areas' ten nor the durations drill-down's.
  def serialized_directory_run_file_growth_window
    growth = spec_directory_growth

    {
      path: requested_spec_directory,
      order: "abs_change_desc,path_asc",
      tie_break_served: true,
      basis: "previous_run_on_branch",
      state: growth&.state || (latest_test_run.nil? ? :no_latest_run : :no_previous_run),
      comparable: growth&.comparable? || false,
      limit: SpecObservation::SPEC_DIRECTORY_FILE_GROWTH_LIMIT
    }
  end

  # WHICH FILES OF THE ASKED-FOR AREA GREW OR SHRANK IN THE LATEST PUSH — the agent-readable half of
  # the "Files that grew or shrank in this directory" panel `repositories#show` renders from the
  # same object, off the same two runs, in the same order.
  #
  # THE SAME OBJECT THE PANEL READS, never a hand-written query — this file's governing rule, stated
  # in full on `serialized_spec_files`. `SpecDirectoryFileGrowth` is view-free, so the API and the
  # panel cannot name different files or different operands for the same area of the same
  # repository.
  #
  # ⭐ `null` IN EVERY NON-COMPARABLE STATE, AND NOT A BLOCK OF ZEROS — the rule its parent block
  # pins by its own example. `SpecDirectoryFileGrowth.for` returns `new(path:, state:)` for a parent
  # that cannot compare, WITHOUT any of the counts, so every aggregate falls back to its `0`
  # default: serving them raw would print `anchor_recorded_count: 0` for a latest run that recorded
  # four hundred rows in that very area — a fabricated denominator sitting among the fields that
  # exist to be trustworthy. The actionable half of those states is the `state` token, and it is
  # served unconditionally one key up.
  #
  # `file_count` is the AREA's — every file EITHER run recorded a row for, counted BEFORE the
  # `LIMIT` by a window function and therefore never `rows.size`, which is the truncated figure. So
  # `truncated` is disclosed against a population rather than against the list's own length, and the
  # caption a client builds from these figures cannot describe a different row set from the rows it
  # was handed.
  #
  # `baseline_recorded_count`/`anchor_recorded_count` are THIS AREA'S rows, deliberately not the
  # identically-named whole-run figures on the parent block: every figure here comes back from the
  # one grouped aggregate that returned the rows, narrowed by the same area predicate. A client
  # mixing the two would divide an area's population by the suite's.
  #
  # ONE READ OF `spec_observations` AT MOST, and none at all unless a caller asked for an area AND
  # the parent comparison is comparable — the gate is a read of an object already in memory, so it
  # short-circuits before any query in all eight refusing states even with `?spec_directory=` set.
  # The read is bounded by the size of the AREA rather than of the suite and needs no index of its
  # own: see `SpecObservation.file_growth_between`.
  def serialized_directory_run_file_growth
    growth = spec_directory_file_growth

    return nil unless growth&.comparable?

    {
      rows: growth.rows.map { |row| serialized_directory_file_growth_row(row) },
      file_count: growth.file_count,
      truncated: growth.truncated?,
      baseline_recorded_count: growth.previous_recorded_count,
      anchor_recorded_count: growth.latest_recorded_count
    }
  end

  # One spec file's movement between two runs, and BOTH OPERANDS it was taken across — never one of
  # the labels the row builds for the panel. `SpecDirectoryFileGrowth::Row` carries `change_label`,
  # `change_reading`, `previous_count_label` and `latest_count_label`, which are typographic and
  # screen-reader spellings of these same numbers; `serialized_directory_growth_row` states in full
  # why a client served those would be splitting strings and stripping glyphs.
  #
  # `previous_count`/`latest_count` go out as `baseline_count`/`anchor_count`, the vocabulary both
  # growth pairs on this endpoint already use, so the two blocks under one request cannot name the
  # same run two ways. ANCHOR IS THE LATEST RUN and BASELINE IS THE PREVIOUS ONE, which is the
  # direction every `change` is signed in.
  #
  # NOT `serialized_directory_growth_row` REUSED, though the arithmetic and the two translated names
  # are identical. `new_file`/`removed_file` are not `new_area`/`removed_area` — they are claims
  # about a different grain, and a shared mapper would have to take its own nouns as arguments,
  # which is a parameterised key name standing where two plain ones were. That is the disposition
  # `SpecDirectoryFileGrowth::Row` itself takes on the same question one layer down.
  #
  # `new_file` and `removed_file` are NOT derivable from `change` alone: a file at zero on one side
  # is that file's real absence, and `+47` against an absent side reads identically to an existing
  # file that gained forty-seven examples. At THIS grain that distinction is the whole subject — a
  # file at "new" beside one at "removed" is the shape of a rename, and two files at `+47` and `−47`
  # is not. The block holding these rows has already established, through the parent's gate, that
  # BOTH runs recorded rows, which is what makes a zero on one side that file's own absence rather
  # than a run that recorded nothing anywhere.
  def serialized_directory_file_growth_row(row)
    {
      path: row.path,
      baseline_count: row.previous_count,
      anchor_count: row.latest_count,
      change: row.change,
      moved: row.moved?,
      new_file: row.new_file?,
      removed_file: row.removed_file?
    }
  end

  # The contract the PER-FILE RUNTIME growth rows below are served under — and, when they are
  # `null`, which of the two reasons applies. Served UNCONDITIONALLY, on the key-always-present rule
  # every window block on this endpoint holds: a block that explains a `null` is worthless if it is
  # itself absent whenever the `null` happens, and here it is absent on the commonest request of all
  # — the one that named no area.
  #
  # ⭐ `path` IS THE ASK RESTATED, AND IT IS THE DISCRIMINATOR — the count drill-in's rule verbatim,
  # because the two blocks are `null` under exactly the same two situations and a client must be able
  # to tell them apart:
  #
  # * `path` is `null` — YOU DID NOT ASK. No `?spec_directory=` reached the server, or the shape it
  #   carried was not a string (`RequestedSpecDirectoryParam` treats a malformed shape as no ask at
  #   all, which is why this is never echoed from the raw parameter).
  # * `path` is set and `comparable` is `false` — you asked, and the comparison this drills out of
  #   refuses. `state` says which of the ELEVEN refusals.
  # * `path` is set and `comparable` is `true` — the rows block is populated.
  #
  # ⭐ `state` AND `comparable` ARE THE PARENT'S VERDICT, READ OFF `directory_runtime_growth` — never
  # re-derived, and never read off this drill-in's own object, which is not even constructed when
  # nobody asked. `SpecDirectoryFileRuntimeGrowth` carries the parent's state verbatim and refuses to
  # build anything the moment the parent is not comparable.
  #
  # The reason is the count drill-in's, WIDENED by this quantity and the class comment states it in
  # full: SIX of `SpecDirectoryRuntimeGrowth`'s nine refusals — the two RECORDED pairs and all three
  # TIMED ones — are computed from window totals across EVERY area, so they are facts about a RUN,
  # and everything this object reads is narrowed to one area. An area only the latest run timed has
  # zero previous-side timed rows: that is `previous_untimed` spelled identically and meaning
  # something else entirely — "the earlier run reported no timings ANYWHERE" against "this area was
  # not timed" — and a drill-in that re-derived it would print that sentence directly beneath
  # `directory_runtime_growth`, which is at that moment listing that same run's per-area seconds. The
  # count drill-in has TWO such states; this has SIX, so the inheritance is more load bearing here
  # and not less.
  #
  # ⭐ AND SPECIFICALLY NOT A `timed_shard_count` GATE. The Overview runtime delta takes one and this
  # is the finest runtime grain on the endpoint, so it is the block that looks likeliest to owe it.
  # `SpecDirectoryRuntimeGrowth` DECIDED that for this family and the reasoning is grain-independent:
  # that guard is the denominator of a MAX over the shards that reported, and these reads SUM
  # per-example rows — machine time, not wall clock — so there is no MAX to fold. Narrowing a sum to
  # one area's files does not turn it into a maximum. Where a shard genuinely went missing,
  # the parent's `assembled_like?` catches it, and the parent has already asked.
  #
  # The safe navigation is LOAD BEARING and not stylistic — `spec_directory_runtime_growth` is `nil`
  # in the two serializer-level states, and the same `latest_test_run.nil?` fallback every window
  # block here uses tells those two apart off the one memoized accessor.
  #
  # NO SECOND SPELLING OF THE OPERANDS. `branch`, `anchor_commit_sha` and `baseline_commit_sha` are
  # served once, on `directory_runtime_growth_window`, and are identical here by construction — this
  # is the SAME comparison between the SAME two runs, narrowed to one area. Repeating them would be
  # two blocks under one request naming one run two ways.
  #
  # `order` CARRIES `nulls_last` where the count drill-in's does not, and the difference is real
  # rather than cosmetic: `SUM(duration_seconds)` over a file no side timed is SQL NULL, so the
  # ordering key is NULL and those rows are pushed to the TAIL rather than to the head. A client
  # reproducing this ordering without that clause would sort the files nobody measured to the top of
  # a list about slowdowns. The same token `directory_runtime_growth_window` serves, for the same
  # reason one grain up.
  #
  # `limit` LIVES HERE rather than on the rows block, following the count drill-in at this GRAIN
  # rather than the runtime block at this QUANTITY — and the grain is the one that decides it. A
  # client that asked for an area and got `null` should still be able to learn what a populated
  # answer would have been capped at, which is a question only the drill-ins can be asked. Read off
  # `SpecObservation::SPEC_DIRECTORY_FILE_RUNTIME_GROWTH_LIMIT` rather than restated — it is its own
  # constant, and it happens to hold the same number as the count drill-in's for an unrelated reason:
  # the two rank the SAME files by INDEPENDENT quantities, which is precisely why they are two
  # constants.
  def serialized_directory_runtime_file_growth_window
    growth = spec_directory_runtime_growth

    {
      path: requested_spec_directory,
      order: "abs_change_desc_nulls_last,path_asc",
      tie_break_served: true,
      basis: "previous_run_on_branch",
      state: growth&.state || (latest_test_run.nil? ? :no_latest_run : :no_previous_run),
      comparable: growth&.comparable? || false,
      limit: SpecObservation::SPEC_DIRECTORY_FILE_RUNTIME_GROWTH_LIMIT
    }
  end

  # WHICH FILES OF THE ASKED-FOR AREA GOT SLOWER OR FASTER IN THE LATEST PUSH — the cell that
  # completes the {area, file} × {count, runtime} square, and the one an agent holding the other
  # three could not compute.
  #
  # ⭐ NOT A RESTATEMENT OF `directory_run_file_growth`, AND NEITHER IS DERIVABLE FROM THE OTHER.
  # That block ranks this area's files by how their example COUNT moved; this one ranks them by how
  # their summed example TIME moved. A file where somebody made an existing example slow adds ZERO
  # examples, so its `ABS(latest_count - previous_count)` is `0`, it sorts last there and falls off
  # the cap — it is not a row on that block missing a column, it is not on that list at all. The
  # independence runs both ways: splitting one slow spec into four fast ones is `+3` examples and
  # LESS time.
  #
  # THE SAME OBJECT ANY PANEL WOULD READ, never a hand-written query — this file's governing rule,
  # stated in full on `serialized_spec_files`. `SpecDirectoryFileRuntimeGrowth` is view-free, so a
  # later `repositories#show` panel over the same cell cannot name different files or different
  # operands for the same area of the same repository.
  #
  # ⭐ `null` IN EVERY NON-COMPARABLE STATE, AND NOT A BLOCK OF ZEROS — the rule its two neighbours
  # pin by their own examples. `SpecDirectoryFileRuntimeGrowth.for` returns `new(path:, state:)` for
  # a parent that cannot compare, WITHOUT any of the counts, so every aggregate would fall back to
  # its `0` default: serving them raw would print `anchor_timed_count: 0` for a latest run that timed
  # four hundred rows in that very area — a fabricated denominator sitting among the fields that
  # exist to be trustworthy. The actionable half of those states is the `state` token, served
  # unconditionally one key up.
  #
  # ⭐ ALL FOUR DENOMINATORS, NOT THE TWO THE COUNT DRILL-IN SERVES, and here they are not optional
  # decoration — they are what keeps the block honest. This grain has TWO absences: how many rows
  # each run RECORDED in this area, and how many of those carried a TIMING. `SUM` skips NULLs
  # silently, so a file half of whose examples were untimed reports a total covering half of it, and
  # the whole reading this block turns on is whether a file got faster or merely went quiet. Without
  # the timed pair a client cannot tell those apart, and `baseline_seconds` would be a number over an
  # unstated population. The count drill-in has only the recorded pair because it has no timing grain
  # to state anything against.
  #
  # `file_count` is the AREA's — every file EITHER run recorded a row for, counted BEFORE the `LIMIT`
  # by a window function and therefore never `rows.size`, which is the truncated figure. So
  # `truncated` is disclosed against a population rather than against the list's own length.
  #
  # All four denominators are THIS AREA'S, deliberately not the identically-named whole-run figures
  # on `directory_runtime_growth`: every figure here comes back from the one grouped aggregate that
  # returned the rows, narrowed by the same area predicate. A client mixing the two would divide an
  # area's population by the suite's.
  #
  # ONE READ OF `spec_observations` AT MOST, and none at all unless a caller asked for an area AND
  # the parent comparison is comparable — the gate is a read of an object already in memory, so it
  # short-circuits before any query in all eleven refusing states even with `?spec_directory=` set.
  # The read is bounded by the size of the AREA rather than of the suite and needs no index of its
  # own: see `SpecObservation.file_runtime_growth_between`.
  def serialized_directory_runtime_file_growth
    growth = spec_directory_file_runtime_growth

    return nil unless growth&.comparable?

    {
      rows: growth.rows.map { |row| serialized_directory_file_runtime_growth_row(row) },
      file_count: growth.file_count,
      truncated: growth.truncated?,
      baseline_recorded_count: growth.previous_recorded_count,
      anchor_recorded_count: growth.latest_recorded_count,
      baseline_timed_count: growth.previous_timed_count,
      anchor_timed_count: growth.latest_timed_count
    }
  end

  # One spec file's RUNTIME movement between two runs, its two operands, and the three different
  # absences that all render as an empty Change cell.
  #
  # A NEW METHOD AND NEITHER NEIGHBOUR REUSED, for the reason `serialized_directory_runtime_growth_row`
  # gives against ITS count sibling and which holds twice here. `serialized_directory_file_growth_row`
  # is written entirely against `SpecDirectoryFileGrowth::Row` — `previous_count`/`latest_count`,
  # and no `comparable?` or `timing_gap?` at all — and
  # `serialized_directory_runtime_growth_row` is written against an independent Struct whose nouns
  # are AREAS. `SpecDirectoryFileRuntimeGrowth::Row` is a third independent Struct: seconds operands
  # like the second, file nouns like the first. Sharing either serializer would be a method branching
  # on which Struct it was handed, or a parameterised key name standing where two plain ones were.
  #
  # `previous_seconds`/`latest_seconds` are the aggregate's own two sides and are the model's names;
  # they go out as `baseline_seconds`/`anchor_seconds`, this endpoint's wire convention for the two
  # ends of a comparison and the names `anchor_commit_sha`/`baseline_commit_sha` give them on
  # `directory_runtime_growth_window`. ANCHOR IS THE LATEST RUN and BASELINE IS THE PREVIOUS ONE,
  # which is the direction every `change` is signed in.
  #
  # ⭐ THREE PREDICATES, BECAUSE THERE ARE THREE DIFFERENT ABSENCES AND THE MODEL KEEPS THEM APART.
  # `change` is `null` when a file is NEW, when it was REMOVED, and when both runs ran it and one of
  # them reported no timing for it — three different things to go and fix. `comparable` says only
  # that there is nothing to subtract; `new_file`/`removed_file` say the file is on one side only;
  # `timing_gap` says both runs HAVE this file and the telemetry, not the code, is what is missing.
  #
  # `new_file` and `removed_file` are NOT derivable from `change` alone — the count drill-in's rule,
  # and NULL-valued seconds make it sharper rather than softer: at this grain a file at "new" beside
  # one at "removed" is the shape of a rename, and two files at `+47s` and `−47s` is not. The block
  # holding these rows has already established, through the parent's gate, that BOTH runs recorded
  # rows, which is what makes a zero on one side that file's own absence rather than a run that
  # recorded nothing anywhere.
  #
  # `change`, `baseline_seconds` and `anchor_seconds` ARE LEGITIMATELY `null` and are served as the
  # nils they are — never coerced to `0`. `SUM` skips NULLs silently and `duration_seconds` is
  # nullable by design, so a zero here would be "this side was never timed" made byte-identical to
  # "this file took no time", which is the one reading the whole block exists to refuse.
  #
  # NO VIEW STRINGS, and at this cell there are none to omit — `SpecDirectoryFileRuntimeGrowth`
  # carries no labels at all, unlike the three siblings above whose `previous_label`, `latest_label`,
  # `coverage_label`, `change_label` and `change_reading` this method would have had to step around.
  # Those are typographic and screen-reader spellings of these same numbers — a U+2212 for a
  # negative, `"±0"`, `"not reported"`, `"New file"` — and a client served those would be splitting
  # strings and stripping glyphs to compare two rows. They land on that model WITH the
  # `repositories#show` panel that renders them, so the rule this comment states stays true by
  # construction here rather than by restraint: there is nothing on the object this method could
  # wrongly serve.
  def serialized_directory_file_runtime_growth_row(row)
    {
      path: row.path,
      baseline_seconds: row.previous_seconds,
      anchor_seconds: row.latest_seconds,
      change: row.change,
      comparable: row.comparable?,
      moved: row.moved?,
      new_file: row.new_file?,
      removed_file: row.removed_file?,
      timing_gap: row.timing_gap?
    }
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

  # The run-over-run presenter, or `nil` when there are not two runs to hand it — memoized across
  # the nil with `defined?` for the reason `unstable_tests` states, and under the same double read
  # (`show` asks the window block for `state` and then this block for the rows).
  #
  # ⭐ THE GUARD IS THIS METHOD'S WHOLE SUBTLETY AND IT IS NOT OPTIONAL. `SpecDirectoryGrowth.for`
  # dereferences `previous_test_run` on its SECOND LINE (`unless previous_test_run.suite_size_measured?`)
  # and has no nil state of its own — there are six non-comparable states and "there is no previous
  # run" is none of them. `previous_test_run` above is nil for three ordinary live shapes: a
  # repository CI has never reported on, a latest run whose client sent no branch, and the first run
  # on a branch. Handed straight in, every one of those is a `NoMethodError` on a plain
  # `GET /api/v1/repository`.
  #
  # GUARDED HERE AND NOT BY WIDENING THE MODEL, which is the same shape `RepositoriesController#show`
  # already uses (`if @latest_test_run && @previous_test_run`). Teaching `SpecDirectoryGrowth.for` to
  # accept a nil would give the object a seventh absence state that the dashboard — its other caller,
  # which guards for itself — can never reach, and would move a decision the two call sites make
  # identically into a contract only one of them relies on.
  #
  # The two guarded cases are told apart one key up, by `latest_test_run.nil?`, off this same
  # memoized accessor — so the state token and the object it stands in for cannot come apart.
  def spec_directory_growth
    return @spec_directory_growth if defined?(@spec_directory_growth)

    @spec_directory_growth =
      latest_test_run && previous_test_run && SpecDirectoryGrowth.for(latest_test_run, previous_test_run)
  end

  # The run-over-run RUNTIME presenter, or `nil` when there are not two runs to hand it — memoized
  # across the nil with `defined?` rather than `||=`, on this file's idiom for every nullable
  # accessor and under the same double read its count sibling has: `show` asks the window block for
  # `state` and then this block for the rows, so a `||=` would re-issue the previous-run lookup on
  # every repository that has none, which is the case this most needs to be cheap in.
  #
  # ⭐ THE GUARD IS THIS METHOD'S WHOLE SUBTLETY AND IT IS NOT OPTIONAL, exactly as one method up.
  # `SpecDirectoryRuntimeGrowth.for` dereferences `previous_test_run` on its SECOND LINE
  # (`unless previous_test_run.suite_size_measured?`) and has no nil state of its own — there are
  # nine non-comparable states and "there is no previous run" is none of them. `previous_test_run` is
  # nil for three ordinary live shapes: a repository CI has never reported on, a latest run whose
  # client sent no branch, and the first run on a branch. Handed straight in, every one of those is a
  # `NoMethodError` on a plain unparameterised `GET /api/v1/repository`.
  #
  # GUARDED HERE AND NOT BY WIDENING THE MODEL — the same shape `RepositoriesController#show` already
  # uses (`if @latest_test_run && @previous_test_run`), and the reason `spec_directory_growth` states
  # for its own guard: teaching `.for` to accept a nil would give the object a further absence
  # state that the dashboard — its other caller, which guards for itself — can never reach, and would
  # move a decision the two call sites make identically into a contract only one of them relies on.
  #
  # The two guarded cases are told apart one key up, by `latest_test_run.nil?`, off this same
  # memoized accessor — so the state token and the object it stands in for cannot come apart.
  #
  # A SECOND OBJECT OVER THE SAME TWO RUNS, and that is one more read rather than a doubling: this
  # asks a question `SpecDirectoryGrowth` structurally cannot answer (see
  # `serialized_directory_runtime_growth`), and its own gate short-circuits before any query in the
  # three states decidable from the two runs alone.
  def spec_directory_runtime_growth
    return @spec_directory_runtime_growth if defined?(@spec_directory_runtime_growth)

    @spec_directory_runtime_growth =
      latest_test_run && previous_test_run &&
      SpecDirectoryRuntimeGrowth.for(latest_test_run, previous_test_run)
  end

  # The per-file drill-in for the ONE area a caller asked about, or `nil` when nobody asked or there
  # was no comparison to narrow — memoized across the nil with `defined?` rather than `||=`, on the
  # idiom every nullable accessor in this file uses. Unlike `spec_directory_growth` above,
  # `spec_directory_window_growth` below, and `unstable_tests` further up, this accessor is read
  # ONCE: the contract block reads the PARENT, deliberately, so the verdict is never taken off this
  # object — which is not even constructed when nobody asked. The memoization is this file's idiom
  # held, not a second read paid for; the two guards below are what actually keep the key cheap.
  #
  # ⭐ TWO GUARDS, AND THEY REFUSE DIFFERENT THINGS. `requested_spec_directory` is the ASK — decided
  # from the params before any query, so a client that never sends the parameter pays nothing at all
  # for this key's existence. `spec_directory_growth` is the parent COMPARISON, and it is guarded
  # here for a reason the HTML call site is structurally immune to: `repositories_controller#show`
  # only ever reaches `SpecDirectoryFileGrowth.for` inside `if @latest_test_run && @previous_test_run`,
  # where the growth object has already been built. This endpoint serves the key on every request,
  # and `spec_directory_growth` is `nil` in both serializer-level states — a repository CI has never
  # reported on, and a latest run with no earlier run on its branch. `.for` dereferences its
  # `growth:` argument on its first line (`unless growth.comparable?`), so handing it that `nil` is
  # a `NoMethodError` on a plain `GET /api/v1/repository?spec_directory=spec/models`.
  #
  # GUARDED HERE AND NOT BY WIDENING THE MODEL, for the reason `spec_directory_growth` states about
  # its own guard one method up: teaching `.for` to accept a nil growth would give it an absence
  # state the dashboard — its other caller, which guards for itself — can never reach.
  #
  # ⭐ AND ONLY THOSE TWO. Comparability is NOT re-asked here: `.for` takes the parent object and
  # refuses on its own first line, reading memory rather than the database, so the six model-level
  # refusals cost this endpoint nothing while still producing an object that carries the parent's
  # state verbatim. Adding a `&.comparable?` to the condition above would be a fourth spelling of
  # predicates the parent has already asked on these same two runs — see `SpecDirectoryFileGrowth`,
  # which prices exactly that and explains why two of the six states are not re-derivable at this
  # grain in any case.
  def spec_directory_file_growth
    return @spec_directory_file_growth if defined?(@spec_directory_file_growth)

    @spec_directory_file_growth =
      if requested_spec_directory && spec_directory_growth
        SpecDirectoryFileGrowth.for(latest_test_run, previous_test_run, requested_spec_directory,
                                    growth: spec_directory_growth)
      end
  end

  # The per-file RUNTIME drill-in for the ONE area a caller asked about, or `nil` when nobody asked
  # or there was no comparison to narrow — memoized across the nil with `defined?` rather than `||=`,
  # on the idiom every nullable accessor in this file uses. Like its count sibling one method up this
  # accessor is read ONCE, because the contract block reads the PARENT deliberately: the memoization
  # is this file's idiom held, not a second read paid for, and the two guards below are what actually
  # keep the key cheap.
  #
  # ⭐ TWO GUARDS, AND THEY REFUSE DIFFERENT THINGS — the count drill-in's pair, against the RUNTIME
  # parent. `requested_spec_directory` is the ASK, decided from the params before any query, so a
  # client that never sends the parameter pays nothing at all for this key's existence.
  # `spec_directory_runtime_growth` is the parent COMPARISON, and it is `nil` in both
  # serializer-level states — a repository CI has never reported on, and a latest run with no earlier
  # run on its branch. `.for` dereferences its `growth:` argument on its first line
  # (`unless growth.comparable?`), so handing it that `nil` is a `NoMethodError` on a plain
  # `GET /api/v1/repository?spec_directory=spec/models`.
  #
  # ⭐ THE PARENT IS `spec_directory_runtime_growth` AND NEVER `spec_directory_growth`, which is the
  # one substitution that would compile, pass a careless reading, and be wrong in a way no type
  # catches. The two objects answer about the same two runs and both expose `state`/`comparable?`, so
  # the count parent would satisfy every call this method makes — and it would gate a RUNTIME
  # comparison on whether the two runs' example COUNTS were comparable. Those verdicts genuinely
  # differ: `neither_timed`, `previous_untimed` and `latest_untimed` exist only on the runtime object,
  # so a run that recorded four hundred rows and timed none of them is comparable to the count parent
  # and refused by this one. Gated on the wrong parent, this block would serve a table of nulls under
  # `comparable: true`.
  #
  # GUARDED HERE AND NOT BY WIDENING THE MODEL, for the reason `spec_directory_growth` states about
  # its own guard: teaching `.for` to accept a nil growth would give it an absence state a
  # self-guarding caller can never reach.
  #
  # ⭐ AND ONLY THOSE TWO. Comparability is NOT re-asked here: `.for` takes the parent object and
  # refuses on its own first line, reading memory rather than the database, so the NINE model-level
  # refusals cost this endpoint nothing while still producing an object that carries the parent's
  # state verbatim. Adding a `&.comparable?` to the condition above would be a further spelling of
  # predicates the parent has already asked on these same two runs — see
  # `SpecDirectoryFileRuntimeGrowth`, which prices exactly that and explains why SIX of the nine
  # states are not re-derivable at this grain in any case.
  def spec_directory_file_runtime_growth
    return @spec_directory_file_runtime_growth if defined?(@spec_directory_file_runtime_growth)

    @spec_directory_file_runtime_growth =
      if requested_spec_directory && spec_directory_runtime_growth
        SpecDirectoryFileRuntimeGrowth.for(latest_test_run, previous_test_run, requested_spec_directory,
                                           growth: spec_directory_runtime_growth)
      end
  end

  # The presenter, or `nil` when no comparison was allowed — memoized across the nil with `defined?`
  # rather than `||=`, for the reason `unstable_tests` states above and under the same double read
  # (`show` asks for the window block's `grouped` and then for the rows).
  #
  # ⭐ THE WINDOW IS HANDED IN REVERSED, AND THAT IS THIS METHOD'S WHOLE SUBTLETY.
  # `SpecDirectoryWindowGrowth.for` documents its parameter as *"the window, ALREADY LOADED and
  # OLDEST FIRST"*, takes `runs.last` as its ANCHOR and walks from index 0 for the BASELINE.
  # `history_runs` is `Repository#recent_test_runs`, ordered `(created_at, id) DESC` — NEWEST first.
  # Handing it in unreversed does not raise: `runs.last` becomes the OLDEST run, the walk finds a
  # baseline among the NEWER ones, and every `change` comes back SIGN-FLIPPED — a suite that grew
  # reports its areas shrinking, under a block that looks perfectly well-formed. The human panel
  # avoids this by construction because `Repository#suite_size_trajectory` ends `.to_a.reverse`; this
  # call site has to do it deliberately.
  #
  # The adjacent precedent is what makes it easy to walk into and is NOT a licence: `UnstableTests.for`
  # documents the same parameter with no ordering clause and is order-indifferent — it reads
  # `runs.map(&:id)` and groups — so `unstable_tests` above hands `history_runs` straight in and is
  # right to. This one is not order-indifferent, and the two lines are otherwise identical.
  #
  # `.reverse` AND NEVER `.reverse!`. `serialized_history` maps the same memoized array and
  # `serialized_history_window` declares `order: "ingested_at_desc,ingest_sequence_desc"` over it;
  # reversing in place would make the endpoint's own ordering contract a lie, in the same response
  # body, for every client reading `history`.
  #
  # The branch gate lives HERE, in one place, so the boolean the window serves and the decision that
  # produced it cannot come apart — see `serialized_directory_growth_window` for why an unfiltered
  # window is refused rather than answered.
  def spec_directory_window_growth
    return @spec_directory_window_growth if defined?(@spec_directory_window_growth)

    @spec_directory_window_growth =
      requested_branch && SpecDirectoryWindowGrowth.for(history_runs.reverse, branch: requested_branch)
  end

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
