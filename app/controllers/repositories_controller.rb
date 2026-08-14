# frozen_string_literal: true

class RepositoriesController < ApplicationController
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

  # The repositories this user may pick from, straight off GitHub, and the four different things to
  # say when that list cannot be loaded. Shared with `BulkRegistrationsController`, which renders a
  # picker built from the same listing and has to answer the same questions the same way.
  include GithubRepositoryListing

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
    # Deliberately a SEPARATE anchor from `@latest_test_run`, which stays exactly what it was: the
    # Overview's suite size, its delta and the Recent runs panel all name the latest run and go on
    # naming it whatever this parameter says. Only the trajectory moves — so a reader who selects a
    # branch cannot end up reading a headline figure about one run under a chart about another.
    #
    # An absent, blank or unrecognised branch falls back to `@latest_test_run` and renders exactly
    # what this page rendered before the parameter existed. A deleted branch, a typo and a stale
    # bookmark are all ordinary ways to arrive here. `@trajectory_branch_request` keeps the raw ask
    # so the panel can SAY the fallback happened, rather than quietly drawing a different branch
    # from the one the URL names.
    @trajectory_branch_request = requested_branch
    @trajectory_run = @repository.latest_test_run_on_branch(@trajectory_branch_request) || @latest_test_run
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
    # Held in a local because the panel below reads the SAME window. Two panels that each fetched
    # "the last thirty runs on this branch" would be two windows with no structural reason to keep
    # agreeing, on a page where one of them captions the other one's branch — and it would be a
    # second copy of a query that is already the page's most carefully bounded read.
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
    @spec_file_durations = SpecFileDurations.for(@latest_test_run) if @latest_test_run
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
    @spec_directory_durations = SpecDirectoryDurations.for(@latest_test_run) if @latest_test_run
    # The same run's rows at a grain none of the panels above reach: not which FILES or AREAS the
    # wall clock went into, but which DESCRIPTIONS more than one example of the run recorded, and
    # what those examples cost between them. Reachable from nowhere until now — `GROUP BY name`
    # exists twice in this application and both are narrowed to failures, so on a green suite
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
    # each ended. The rung the panel above had none of, and the last ranked list on this page whose
    # rows dead-ended.
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
      # durations drill-down above reads, deliberately not a second one. One ask now opens TWO
      # panels, each answering in its own grain: which files carry the area's wall clock, and which
      # of them moved since the previous run. That is how `drill_down_path` composes asks and it is
      # intended — a later reader should not "fix" it by splitting the parameter in two.
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
    if trajectory_runs.any?
      @unstable_tests = UnstableTests.for(@repository, trajectory_runs, branch: @trajectory_run&.branch)
      # The area grain of the panels above, asked of the WINDOW the two panels around it are already
      # drawn on: not which area moved since the last push but which area moved across the branch's
      # last thirty runs. The page had "growth over time" (the chart, one number per run, no area
      # grain at all) and "growth by area" (the panel above, exactly one push) and never their
      # intersection — an area gaining four examples a run is nobody's biggest mover on that panel
      # and sorts below its cap thirty times running.
      #
      # The THIRD reader of this same local, for the reason stated where it is taken: three panels
      # each fetching "the last thirty runs on this branch" would be three windows with no
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
  # each run whether it is `multi_shard?` and what it COST, and both `TestRun#shard_count` and
  # `#machine_seconds` are memoized per-instance reads of one `pick` (`test_run.rb`) — asked in the
  # card loop that is one `test_run_shards` query per card, the same N+1 shape this page has already
  # been cleaned of twice. One grouped aggregate answers all of it for the whole grid in a single
  # round trip, exactly as the Recent-runs table on `show` already does. The wall clock needs no
  # priming at all: `duration_seconds` is a column on the rows selected below. Primed HERE and not
  # in `#index`, so the aggregate is taken only when something actually reads the runs and a page of
  # no repositories still pays nothing.
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

  # The single gate every write of `github_full_name` passes through — and it is written as a save
  # rather than as a `before_action` guard for a structural reason: `repository_params` has two
  # callers (`#create` and `#update`), so a check bolted onto one action leaves the other one
  # writing the identity column unverified. Squatting would simply have moved from POST
  # /repositories to PATCH /repositories/:id and the gap would have read as closed.
  #
  # Order is load-bearing:
  #
  #   1. `valid?` first, so a slug that is not `org/repo` — or one already registered — is refused
  #      from the record's own rules and never becomes a GitHub round trip. It also runs
  #      `normalize_full_name`, so step 2 asks GitHub about the value that would actually be
  #      stored rather than about whatever was pasted.
  #   2. Ownership, and only when the identity is actually changing. A rename form submitted
  #      unchanged, like the one `rename_notice` exists to describe, must not re-ask GitHub — and
  #      must not fail closed on a GitHub outage for a write that changes nothing.
  #   3. `save`.
  #
  # Fails closed at every step: a verdict that is not `verified?` — including "GitHub could not be
  # reached" — does not save.
  def save_with_verified_ownership(repository)
    return false unless repository.valid?
    return false unless verify_github_ownership(repository)

    repository.save
  end

  # Records the refusal on the attribute it is about, so the form shows it under the field the user
  # has to change, exactly as a format or uniqueness failure does. The verdict is also kept for the
  # view, which offers an authorize button instead of an error when the fix is a grant rather than
  # an edit.
  def verify_github_ownership(repository)
    return true unless repository.will_save_change_to_github_full_name?

    @github_verdict = GithubOwnership.verify(user: current_user, full_name: repository.github_full_name)
    return true if @github_verdict.verified?

    repository.errors.add(:github_full_name, @github_verdict.message)
    false
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
  # refused for a grant the user does not have must offer the authorize button, and the listing
  # alone cannot know that happened.
  def github_verdict = @github_verdict

  # Submitting the form unchanged is a valid save, so don't claim a rename that didn't happen.
  def rename_notice
    if @repository.saved_change_to_github_full_name?
      "Renamed to #{@repository.github_full_name}."
    else
      "#{@repository.github_full_name} is already up to date."
    end
  end
end
