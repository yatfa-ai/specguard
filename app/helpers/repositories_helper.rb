# frozen_string_literal: true

module RepositoriesHelper
  # How many branches the "Suite growth" selector lists.
  #
  # `Repository#branch_histories` walks up to `Repository::BRANCH_HISTORY_LIMIT`; this is how many
  # of them a reader is shown, and the two are deliberately different numbers by two orders of
  # magnitude. The walk's bound is about where a repository's branch cardinality stops being
  # human-scale; this one is about what a row of links can carry before it stops being a way to
  # find a branch. Keeping them apart is not tidiness — the walk is ALPHABETICAL, so a walk bounded
  # near this number would hand the history sort an alphabetical prefix and drop the trunk out of
  # the list ordering by history exists to keep in it.
  #
  # The ones shown are the ones with the most history — `trajectory_hidden_branches_sentence` says
  # so rather than leaving a truncated list to look complete, and says it only as far as the walk
  # can support it.
  TRAJECTORY_BRANCH_CHOICES = 8

  # ONE statement of the carry-through rule this page's drill-downs all obey, for every link that
  # opens or closes one of them.
  #
  # The rule itself is old and is argued at each panel: `?branch=` anchors the "Suite growth" chart,
  # and `?spec_file=` / `?spec_directory=` / `?repeated_description=` / `?unstable_test=` each anchor
  # a drill-down panel of their own, so a gesture aimed at ONE of them must not close the others as a
  # side effect. Opening a file is not a request to close the area; closing an area is not a request
  # to close the file; and so on in every direction.
  #
  # What was missing was a place to SAY it once. The READ side of these asks has been abstracted
  # since they were built — `app/controllers/concerns/requested_*_param.rb`, one concern each — but
  # the EMIT side was hand-enumerated at every link site, one independent argument decision per ask
  # per link, re-made by hand every time a rung was added. That is not a rule, it is a
  # matrix maintained by remembering, and it failed exactly the way such a matrix fails: the
  # area-open link was written after `?spec_file=` already shipped, did not carry it, and was later
  # edited to ADD another ask without anyone noticing the missing one. Every new drill-down cost a
  # retrofit at every pre-existing site, and every pre-existing site was a place to forget.
  #
  # So: CARRY IS THE DEFAULT, and a caller names only what it CHANGES.
  #
  #   carry — omit the key entirely; the reader's own ask rides through
  #   set   — pass a value (`spec_file: file.path`)
  #   clear — pass an explicit `nil` (`spec_file: nil`); `repository_path` drops nil params
  #
  # `asks.merge(overrides)` and specifically NOT `asks.merge(overrides.compact)`. Every CLEARING
  # gesture on the page — the "Close" buttons and "Show the newest run" — clears its own ask by
  # passing nil, and compacting the OVERRIDES drops that nil before it can override anything: the
  # reader's current ask survives the merge and every one of them becomes a no-op that navigates to
  # the page it is already on. That is the precise inversion of the defect this exists to make
  # impossible. A nil in `overrides` is a decision, not an absence.
  #
  # Named rather than counted, deliberately. `git grep -n "<ask>: nil" -- app/views` is the roll, and
  # it keeps growing — the run anchor got its way back, and every drill-in added since has brought
  # its own way out — so a figure here would be a stale casualty count in the one comment someone
  # reads to decide whether a "tidying" `.compact` is safe.
  #
  # Compacting the merged RESULT is merely pointless rather than harmful (`repository_path` already
  # omits nil params), but it reads as though nils were unwanted here, which is the belief that leads
  # to the fatal version. Neither belongs in this chain.
  #
  # `anchor:` is required and stays per-site: where a gesture lands is a property of the gesture, not
  # of the asks, and one of them ("Close file") chooses its anchor from what else is open.
  #
  # The asks are read from the raw REQUEST ivars, never from a resolved object — `branch` is
  # `@trajectory_branch_request` and not the run the fallback settled on, and `commit_sha` is
  # `@run_anchor_request` and not the run it resolved to, so a link reproduces what the reader asked
  # for rather than what they got. A site that wants a resolved value passes it as an override
  # instead (the area-files table names `@spec_directory_files.path`, its own panel's subject, rather
  # than leaning on that ivar and the request agreeing).
  #
  # `commit_sha` is the one ask here that RE-ANCHORS rather than narrows — it names which run every
  # panel describes, where the others pick a series or open a panel of the run already chosen — and
  # it is in this hash for exactly the reason they are: a gesture aimed at one ask must not close the
  # others as a side effect. Opening an area is not a request to jump back to the newest run.
  #
  # `unstable_test_from` is the one entry here that is NOT an ask. It opens no panel and narrows no
  # population — it QUALIFIES `unstable_test`, naming which ranking the reader opened it from so the
  # "Close test" control can return them there. It is in this hash for a reason the six asks make
  # obvious in the negative: if it did not ride through, opening a file while a test was open would
  # drop the origin and silently re-point that control at the other panel, which is the same class
  # of defect carry-by-default exists to kill. A qualifier that does not follow its principal is
  # worse than none, because it is right until the reader touches anything else.
  #
  # It clears the way every ask does — "Close test" passes an explicit `nil` for it alongside the
  # test itself, because a gesture that removes the subject must not leave its qualifier behind.
  def drill_down_path(repository, anchor:, **overrides)
    asks = { branch: @trajectory_branch_request,
             commit_sha: @run_anchor_request,
             spec_file: @spec_file_request,
             spec_directory: @spec_directory_request,
             repeated_description: @repeated_description_request,
             unstable_test: @unstable_test_request,
             unstable_test_from: @unstable_test_origin_request }

    repository_path(repository, **asks.merge(overrides), anchor: anchor)
  end

  # Both halves of the same disclosure for repository removal: what the presser is told *before*
  # they confirm, and what they are told *after*. They live together for the reason
  # `MembershipsHelper#revoke_confirmation` and `#revoke_notice` do — they make the same claim about
  # the same act, and a fix applied to only one of them is a contradiction read in sequence.
  #
  # `repo.delete` is the only irreversible power the sharing model hands a non-owner:
  # `RepositoriesController#destroy` gates at `:repo_delete`, not `:owner`. Both sentences used to be
  # byte-identical for the owner and for that member, so a member read two sentences written as if
  # the repository were theirs. It is not, and `Repository`'s `dependent: :destroy` chain takes the
  # owner's API keys, the whole ingested run history, every stored intent and every other member's
  # access with it.
  #
  # The owner path is deliberately verbatim what it always was. An owner destroying their own
  # repository learns nothing from being told whose it is, and a dialog that grows a sentence for
  # everyone is a dialog everyone starts skimming — the same reason `revoke_confirmation` says
  # nothing extra to an owner revoking a colleague who minted no keys.
  #
  # The owner is named through `repository.user.display_name`, NEVER off `github_full_name`. The
  # slug's org segment is a *GitHub* org, not a SpecGuard account, and nothing constrains the two to
  # match (see the comment on `Repository#user`); SPGD-145 retired `owner_login` for exactly this.
  # Reading it off the slug would confidently name the wrong person.
  #
  # `owner:` is passed in rather than recomputed here, so both call sites ask the one policy object
  # the request already built (`ApplicationController#repository_policy`, memoized per repository)
  # instead of a helper opening a second, unmemoized route to the same question.

  # The copy in the Remove confirm dialog, rendered by repositories/show.
  #
  # The first sentence is unchanged for BOTH paths, and that is load-bearing beyond taste:
  # `spec/requests/repository_sharing_spec.rb` detects whether the Remove control rendered at all by
  # looking for the substring `and all of its data?`. Appending a second sentence preserves that
  # marker; rewording the first would silently blind the control matrix that pins who may see this
  # button.
  def remove_confirmation(repository, owner:)
    question = "Remove #{repository.github_full_name} and all of its data?"
    return question if owner

    "#{question} It belongs to #{repository.user.display_name} — this destroys their repository " \
      "along with its API keys, its entire run history and every other member's access."
  end

  # The counterpart after the click, called from `RepositoriesController#destroy` — the same shape
  # `MembershipsController#destroy` already uses for `revoke_notice`.
  #
  # Past tense and no lever to pull: unlike a revoked colleague's surviving API keys, nothing here
  # is recoverable and there is nothing to send the reader to. What it does instead is say plainly
  # whose repository just went, so a member who clicked through on the wrong row can tell the owner
  # rather than discover it from them.
  def remove_notice(repository, owner:)
    removed = "Removed #{repository.github_full_name}."
    return removed if owner

    "#{removed} It was #{repository.user.display_name}'s repository — its API keys, its run " \
      "history and every other member's access went with it."
  end

  # Why the "Suite growth" panel is not drawing a line, when there are runs on the branch but fewer
  # than two the platform will compare.
  #
  # Two different things to go and look at, and they must not share a sentence. A young branch fills
  # in on its own and there is nothing to do; a branch whose runs were all withheld has a reason
  # behind each withholding — an in-flight build that will resolve in minutes, a cancelled job that
  # never will, a run that reported nothing — and the reader can only act on the second if they are
  # told which it is.
  #
  # Every number here is counted off the same `SuiteTrajectory` the chart would have been drawn
  # from, so the empty state cannot claim a different history from the one that was loaded.
  def trajectory_thin_description(trajectory)
    history = "#{trajectory.considered_count} #{"run".pluralize(trajectory.considered_count)} " \
              "on #{trajectory.branch}"

    if trajectory.withheld_count.zero?
      "SpecGuard has #{history} so far, and a trajectory needs at least two points to be one. " \
        "A single measurement drawn as a line is a flat line, which says the suite is stable — " \
        "and one run cannot say that."
    else
      "SpecGuard has #{history}, but #{trajectory_comparable_phrase(trajectory)}: " \
        "#{trajectory_withheld_reasons(trajectory)}. None of those is a smaller suite — they are " \
        "runs whose totals cover different amounts of delivered work, so a line through them " \
        "would be a picture of what each run reported rather than of the suite."
    end
  end

  # The withheld runs grouped by WHY, never totalled into one number. "3 withheld" hides an
  # in-flight build inside the same figure as a client that is reporting nothing, and only one of
  # those is a fault.
  #
  # The composition mismatch splits for the same reason, one level down. It is symmetric — a run is
  # withheld whenever its shard count differs from the cohort's, in either direction — but "had
  # reported only some of its parts" is true only of the runs holding FEWER, and reads as a fault
  # that will clear on its own. Said of a run assembled from MORE parts, or one delivered whole, it
  # is false: a repository mid-shard-migration would be told its complete new runs are half-arrived.
  # The old wording here ("assembled from a different number of shard reports") had the further
  # problem that for a whole delivery it means "0 shard reports", which is precisely what
  # `TestRun#delivery_description`'s comment exists to forbid.
  def trajectory_withheld_reasons(trajectory)
    reasons = []

    unmeasured = trajectory.withheld_unmeasured.size
    if unmeasured.positive?
      reasons << "#{unmeasured} reported no tests at all"
    end

    part_way = trajectory.withheld_part_way.size
    if part_way.positive?
      reasons << "#{part_way} had reported only some of #{part_way == 1 ? "its" : "their"} parts"
    end

    others = trajectory.withheld_other_composition.size
    if others.positive?
      reasons << "#{others} #{others == 1 ? "was" : "were"} assembled from more parts than the " \
                 "rest, or arrived whole where the rest were sharded"
    end

    reasons.to_sentence
  end

  # The branches the "Suite growth" panel offers, as `UI::PageNavComponent` items.
  #
  # Ordered by `Repository#branch_histories` — most history first — and cut to
  # `TRAJECTORY_BRANCH_CHOICES`. `trajectory_hidden_branches_sentence` states what the cut left out;
  # a truncated list with nothing said about it reads as the complete set of branches.
  def trajectory_branch_choices(repository, histories, current_branch)
    trajectory_shown_branches(histories, current_branch).map do |history|
      trajectory_branch_item(repository, history, current_branch)
    end
  end

  # Every branch the panel loaded, as one menu — or `nil` when the row above already names them all.
  #
  # The row is cut to `TRAJECTORY_BRANCH_CHOICES` because that is what a row of links can carry.
  # `@trajectory_branches` is not: `RepositoriesController#show` already holds up to
  # `Repository::BRANCH_HISTORY_LIMIT` of them, each with the name, the run count and the capped
  # flag this menu needs, out of the SAME one query the row is built from. Nothing here re-asks the
  # database for anything — the rows are in memory and already in the order they are wanted in.
  #
  # Deliberately the FULL list and not the cut's remainder. This is the page's index of branches,
  # and an index that omits the eight entries you can see elsewhere is one a reader has to hold two
  # lists in their head to use. It also keeps the menu's own label honest: "All 11 branches" over a
  # menu of three would be the same untrue-by-omission claim the hidden-branches sentence exists to
  # prevent.
  #
  # Ordered by `Repository#branch_histories` — most history first — and NOT pulled to front the way
  # `trajectory_shown_branches` is. The row bends its order to guarantee the drawn branch appears at
  # all; the menu never has to, because it omits nothing, and an index whose order moved as the
  # reader clicked would make them re-find their place on every visit.
  def trajectory_branch_menu_choices(repository, histories, current_branch)
    return nil unless trajectory_branches_overflow?(histories)

    histories.map { |history| trajectory_branch_item(repository, history, current_branch) }
  end

  # What that menu may call itself, or `nil` when there is no menu.
  #
  # "All" is a claim about the repository, and it is only available while the walk FINISHED. Past
  # `Repository::BRANCH_HISTORY_LIMIT` the menu holds every branch SpecGuard walked to and an
  # unknown number of others exist, so the label drops to the bare count it can support — the same
  # distinction `trajectory_hidden_branches_sentence` draws with "At least", made where a reader
  # about to open the menu will read it.
  def trajectory_branch_menu_label(histories)
    return nil unless trajectory_branches_overflow?(histories)

    trajectory_walk_cut?(histories) ? "#{histories.size} branches" : "All #{histories.size} branches"
  end

  # What the selector left out, or `nil` when it left out nothing.
  #
  # Three claims, and they are separated because they can fail separately.
  #
  # The COUNT is "at least" when the walk itself stopped at its own bound: past that point SpecGuard
  # has not counted the branches either, and a bare number would be a figure nothing measured.
  #
  # The REACH claim is what the sentence gained when the branches stopped being merely counted at a
  # reader and became something they can open. It says where the ones missing from the row are, and
  # it stops short of "here they all are" whenever the walk was cut: a repository past the walk's
  # bound still has branches this page has never seen, and the menu cannot offer one it never
  # reached. That is the same bound "At least" reports, said about reachability instead of arithmetic.
  #
  # The cut wording says "these #{n}" and NOT "the #{n} SpecGuard walked to". The count is a count of
  # this list, and this list is not the walk's output: `Repository#branch_histories` UNIONs the
  # bounded walk with the PINNED branch outside `:branch_limit` (the `candidate` CTE of
  # `BRANCH_HISTORY_SQL`, whose `SELECT pin FROM unnest(ARRAY[:pinned_branches]…)` arm sits outside
  # the subquery carrying the `LIMIT :branch_limit`), which is the same fact `trajectory_walk_cut?`
  # uses `>=` for. On a cut repository the branch being drawn is routinely in this list *because the
  # walk never reached it* — pin `main` on a repository of `feature/*` and it arrives behind every
  # one of them — so naming the size as the walked figure is off by the pins, in the one branch of
  # this method written to not overclaim. A bare count claims nothing about provenance and is true
  # however a row got here; the bound the reader actually needs is carried by the clause after it,
  # which is unconditionally true.
  #
  # The ORDERING claim is the one that has to be earned. "The branches with the most history are
  # listed first" is true of the branches the WALK REACHED, and the walk is alphabetical — so on a
  # repository with more branches than it walks, the head of this list is the busiest of an
  # alphabetical prefix and not of the repository. Saying so is the whole point: a sentence
  # promising an ordering the query cannot deliver is worse than no sentence, because it tells a
  # reader who cannot find `main` that `main` must not have any history.
  #
  # It is also not the plain ordering when the branch being drawn had to be pulled to the front to
  # be shown at all (see `trajectory_shown_branches`) — the reader is then looking at one branch out
  # of order on purpose, and the sentence names that rather than describing a list they can see is
  # not sorted that way.
  def trajectory_hidden_branches_sentence(histories, current_branch)
    hidden = histories.size - TRAJECTORY_BRANCH_CHOICES
    return nil unless hidden.positive?

    cut = trajectory_walk_cut?(histories)
    counted = cut ? "At least #{hidden}" : hidden.to_s
    reach = if cut
              "The branch menu names these #{histories.size}, and cannot offer one the walk " \
                "never reached."
            else
              "The branch menu names all #{histories.size}."
            end

    "#{counted} further #{"branch".pluralize(hidden)} #{hidden == 1 ? "has" : "have"} runs and " \
      "#{hidden == 1 ? "is" : "are"} not in the row above. #{reach} " \
      "#{trajectory_listing_basis(histories, current_branch)}"
  end

  # Said when the reader asked for a branch SpecGuard has no runs on, and the panel drew another
  # one instead.
  #
  # Without this the URL says `?branch=feature/gone` and the panel draws `main` — every figure on it
  # correctly labelled `main`, and nothing anywhere saying the ask was not honoured. A reader who
  # followed a stale bookmark would read the trunk's history as their branch's.
  #
  # `nil` whenever the ask WAS honoured, including the ordinary no-ask case, so this sentence only
  # ever appears next to a substitution it is describing.
  #
  # The asked-for name is truncated: it is unvalidated URL input, and a branch name is a short
  # thing. `escape: false` because the escaping is ERB's, done once at the render — `truncate`
  # defaults to escaping its input and returning a `SafeBuffer`, and interpolating that into a plain
  # String yields an unsafe String carrying already-escaped content, which ERB then escapes a second
  # time (`?branch=a%26b` printing `a&amp;b` on the page). Returning raw text and letting the view
  # escape it keeps one escape at one seam, which is what this returning a plain String is for.
  def trajectory_branch_fallback_notice(requested, trajectory)
    return nil if requested.blank? || trajectory.branch == requested

    asked = truncate(requested, length: 60, escape: false)

    if trajectory.branch.blank?
      return "SpecGuard has no runs on #{asked}. The latest run named no branch, so there is " \
             "still no history to draw."
    end

    "SpecGuard has no runs on #{asked}, so this panel is drawn on #{trajectory.branch} — the " \
      "branch of the repository's latest run — instead."
  end

  # == The run every panel on this page is anchored on

  # WHICH RUN this page is describing, said out loud whenever `?commit_sha=` named one — the web's
  # counterpart to the `run_anchor` block `RepositoryOverview#serialized_run_anchor`
  # serializes on every call.
  #
  # `nil` on the ordinary no-ask page, which is the whole of the difference between this and the
  # API's block. A JSON client reads its anchor out of a field and pays nothing for one it did not
  # ask about; a reader pays for every sentence on the page, and "this page is anchored on the run
  # that reported most recently" under a panel already headed "Measured on abc1234" is a sentence
  # that teaches a reader to skim the ones that matter.
  #
  # BOTH answers to an ask are stated, and they must not be able to render the same. The resolved
  # one is not decoration: the anchor is invisible from the figures themselves — every panel is
  # correctly labelled with the run it drew, and correctly labelled is exactly how a page pinned to
  # a three-week-old commit reads to someone who arrived by a link. The fallback one is the defect
  # this feature exists to close, and the reason it cannot be left silent is the one the JSON
  # endpoint gives about the same substitution: without it the URL names a sha, the page describes
  # a different run, and nothing anywhere says the ask was not honoured.
  #
  # Decided on WHETHER THE ASK RESOLVED — `anchored` is the row `?commit_sha=` found, or nil — and
  # never by comparing two shas. That is `serialized_run_anchor`'s rule (`resolved:` is read off the
  # finder, not off an equality) and it is what stops the disclosure and the choice it discloses from
  # coming apart: a repository can hold two runs of one commit, and the sha a reader asked for is
  # then equal to the sha they were served on a page that resolved their ask exactly.
  #
  # Both branches return a plain String and not `html_safe` markup, so escaping is ERB's — the same
  # stance `#trajectory_branch_fallback_notice` takes one ask over, and it matters here because the
  # fallback branch prints back a sha nobody validated.
  def run_anchor_notice(requested, anchored, shown)
    return nil if requested.blank?
    return run_anchor_fallback_sentence(requested, shown) if anchored.nil?

    "This page is anchored on #{anchored.commit_sha.first(7)} — the run this URL names — rather " \
      "than on whichever run reported most recently. Every panel describing a single run describes " \
      "that one. “Recent runs” and “Suite growth” are histories rather than rows, so they are not " \
      "re-anchored: the run named here need not be the newest one below."
  end

  # What the anchor means FOR THE "RECENT RUNS" LIST — the panel's half of the same disclosure
  # `#run_anchor_notice` makes in the Overview.
  #
  # ⭐ THE SECOND STATEMENT ABOUT ONE CHOICE, and it is computed from the same two facts the choice
  # itself is: the resolved run (never the raw ask) and the rows actually rendered. That is the rule
  # `#run_anchor_notice` states above and the reason it is repeated here rather than assumed: a
  # caption gated on the ASK claims the URL's run is the marked one on a page that fell back and
  # marked nothing, which is the Overview flatly contradicted one panel below by the sentence meant
  # to close exactly that gap. `RequestedCommitShaParam` names the shape — "the fallback would then
  # serve the newest run while `run_anchor` claimed a request had been made."
  #
  # THREE states because the reader is in one of three positions, and only the first is the state a
  # single unconditional sentence describes:
  #
  # * **Resolved, and in the window** — there is a marked row, so the caption says the marked row is
  #   the one every panel above describes and warns it need not be the top one.
  # * **Resolved, but behind the panel's bound** — `@recent_test_runs` is capped at ten rows, and an
  #   anchored run outside that window is simply not here to mark. The reader still needs to know
  #   their ask was honoured, so the sentence says which run holds the page AND that no row is
  #   marked; sending them hunting for a mark that was never rendered is the failure mode.
  # * **Fell back** — SILENT. The Overview already said the sha resolved to nothing and named the
  #   substitute, and there is no marking here to explain. A second telling would restate a fact the
  #   reader has read one panel up, in a panel that has nothing to add to it.
  #
  # `listed` is passed in rather than read off `@recent_test_runs`, so the membership test and the
  # `aria-current` marking in the view cannot come to be asked of two different collections — the
  # same reason `anchored` is the row rather than a sha.
  def recent_runs_anchor_note(anchored, listed)
    return nil if anchored.nil?

    if listed.any? { |test_run| test_run.id == anchored.id }
      return "This page is anchored on a run the URL named, so the marked row here is the one " \
             "every panel above describes — and it is not necessarily the newest."
    end

    "This page is anchored on #{anchored.commit_sha.first(7)} — the run the URL named, which every " \
      "panel above describes. It is not among the most recent runs listed here, so no row below is " \
      "marked."
  end

  # == The "Slowest tests" panel's outcome sentence

  # What this run's rows said HAPPENED to the examples they recorded — counted off those rows and
  # never off the Overview's suite size, which is re-derived by SUM over shard reports and can
  # legitimately disagree with them.
  #
  # ONE method for BOTH branches of the panel, which is a deliberate decision and not an accident
  # of extraction. The `else` branch — rows exist, not one of them timed — renders an empty state
  # instead of a ranking, and it would have been easy to let this sentence fall through with the
  # table. It must not: "nothing was timed" is a fact about DURATIONS and says nothing whatever
  # about outcomes, and a run that reported no timings and four failures is exactly the run whose
  # reader most needs the second half. Sharing the method also means the caption and the empty
  # state cannot end up quoting different failure counts for the same rows — the contradiction
  # `remove_confirmation`/`remove_notice` live together to avoid.
  #
  # `failed` and `pending` are counted BY NAME and the remainder is worded as "something other
  # than either", never as "passed". Nothing platform-side validates that string (see
  # `SpecObservation::COVERAGE_COUNTS`), so calling the remainder a pass would be asserting a value
  # nobody checked.
  #
  # The no-outcomes case is worded as an ABSENCE and gets no zero. `outcome` is nullable, so a run
  # whose client sends none stores a nil on every row and `failed_count` is legitimately 0 — and
  # "0 failed" printed over that run is "nothing to check" wearing the spelling of "everything
  # passed". It is the same separation `SlowestExamples#recorded?` draws between "no rows" and "no
  # timings", made on the outcome axis by `#outcomes_reported?`.
  def slowest_examples_outcome_sentence(slowest_examples)
    recorded = slowest_examples.recorded_count
    examples = "#{number_with_delimiter(recorded)} #{"example".pluralize(recorded)} this run recorded"

    unless slowest_examples.outcomes_reported?
      return "Not one of the #{examples} reported an outcome, so nothing here says whether any of " \
             "them passed. That is a run which did not say, rather than a run with nothing wrong " \
             "in it."
    end

    "#{slowest_examples_outcome_scope(slowest_examples, examples)}: " \
      "#{slowest_examples_outcome_breakdown(slowest_examples)}." \
      "#{slowest_examples_unreported_clause(slowest_examples)}"
  end

  # == The opened spec file's basis sentence

  # What the drill-down list under a single spec file IS — how much of the file it shows, and
  # whether it is ordered by anything.
  #
  # Two axes, and the four sentences they make are written out rather than assembled from clauses,
  # because three of the four are wrong in a way only the fourth's wording hides.
  #
  # TRUNCATION is the axis every capped list on this page discloses: the cap is
  # `SpecObservation::FILE_EXAMPLES_LIMIT` and a reader cannot see it, so a list whose length
  # happens to equal it reads as the whole file. It is stated whether or not anything was cut, for
  # the reason `SpecFileDurations#truncated?` gives one grain up — "all 12 examples" and "the 50
  # heaviest of 340" are the two facts, and a bare list is neither.
  #
  # ORDER is the axis that is new here. Every sibling list on this page EXCLUDES untimed rows, so
  # "slowest first" is unconditionally true of them; this one lists them, because a file's untimed
  # examples are part of that file's population and hiding them would leave the list disagreeing
  # with the `recorded_count` printed beside it. On a file that reported no timing at all there is
  # therefore a list and no ranking — every row ties — and "slowest first" over it would be
  # promising an order nothing measured. It says "in the order this run recorded them" instead,
  # which is what `id` ascending actually gives.
  #
  # The truncated-and-unranked sentence is the one this exists for: "the 50 slowest of 340" is
  # false on a file nothing timed, and it is the sentence a reader is most likely to act on.
  #
  # The two axes are not independent where they MEET, which is why there are five sentences and not
  # four. A truncated file that timed SOME of its examples runs the timed rows out before the cap
  # does, and the page then ends in untimed rows: on 340 examples of which 40 are timed, the list
  # is 40 ranked rows followed by 10 of 300 that nothing ranked. "The 50 slowest" is false of that
  # page twice over — those last ten are not the slowest of anything, and the 290 untimed rows it
  # does not mention are not on the page at all. `#lists_untimed?` is that meeting, and it gets its
  # own sentence naming both populations and what was cut from each.
  def spec_file_examples_scope_sentence(examples)
    recorded = number_with_delimiter(examples.recorded_count)
    shown = number_with_delimiter(examples.rows.size)
    plural = "example".pluralize(examples.recorded_count)

    if examples.any_timed?
      return "All #{recorded} #{plural} this run recorded in it, slowest first." unless examples.truncated?
      return spec_file_examples_mixed_tail_sentence(examples) if examples.lists_untimed?

      "The #{shown} slowest of the #{recorded} examples this run recorded in it, slowest first."
    elsif examples.truncated?
      "The first #{shown} of the #{recorded} examples this run recorded in it, in the order this " \
        "run recorded them — nothing here was timed, so there is no order to rank them in."
    else
      "All #{recorded} #{plural} this run recorded in it, in the order this run recorded them — " \
        "nothing here was timed, so there is no order to rank them in."
    end
  end

  # == The opened repeated description's basis sentence

  # What the drill-down list under a single repeated description IS — how much of the group it
  # shows, and whether it is ordered by anything.
  #
  # The same two axes, in the same five sentences, as `#spec_file_examples_scope_sentence` above,
  # and deliberately its own method rather than a widening of that one with a noun argument.
  #
  # The two are not the same claim wearing different words. That one says "in it", where "it" is a
  # FILE and the phrase "this run recorded in it" is what makes the denominator a file's population;
  # this says "under this description", where the population is the rows of one run that share a
  # sentence and may sit in any number of files. Parameterising the noun would make one sentence
  # stand for two claims about two different populations, which is the thing every `_LIMIT` constant
  # in `SpecObservation` is kept separate to prevent — and it would put the wording of both panels
  # behind a single edit nobody meant to make at either.
  #
  # The ORDER axis is louder here than one rung over, and it is why the unranked sentences are worth
  # writing out. A file that timed nothing is an unusual file; a repeated description that timed
  # nothing is an ORDINARY group — the ranking above sorts exactly such groups to the end of itself
  # and says so — so the reader who opened one is meeting the unranked list as a normal state rather
  # than an edge of one. "Slowest first" over it would promise an order nothing measured.
  #
  # Nothing here uses the word "duplicate", by the rule the panel this drills out of states: a shared
  # description is equally a table-driven loop, a shared example group, or the same test written
  # twice, and a sentence describing the list must not decide which.
  def repeated_description_examples_scope_sentence(examples)
    recorded = number_with_delimiter(examples.recorded_count)
    shown = number_with_delimiter(examples.rows.size)
    plural = "example".pluralize(examples.recorded_count)

    if examples.any_timed?
      return "All #{recorded} #{plural} this run recorded under it, slowest first." unless examples.truncated?
      return repeated_description_examples_mixed_tail_sentence(examples) if examples.lists_untimed?

      "The #{shown} slowest of the #{recorded} examples this run recorded under it, slowest first."
    elsif examples.truncated?
      "The first #{shown} of the #{recorded} examples this run recorded under it, in the order this " \
        "run recorded them — nothing here was timed, so there is no order to rank them in."
    else
      "All #{recorded} #{plural} this run recorded under it, in the order this run recorded them — " \
        "nothing here was timed, so there is no order to rank them in."
    end
  end

  # == The "Spec files in this directory" panel's sentences

  # Whether the area the drill-down panel is open on has its own row in the "Heaviest spec
  # directories" rollup above it — the question that decides whether the panel may cross-reference
  # that rollup at all.
  #
  # It is a real question and not a formality. The rollup is capped at
  # `SpecObservation::HEAVIEST_DIRECTORIES_LIMIT`, and `?spec_directory=` is a URL a reader types,
  # edits and bookmarks: the run's eleventh-heaviest area renders this panel with rows and real
  # counts while having no row above it at all. A caption is a claim, and "the same fraction the row
  # for this area states in the panel above" is a claim about a DIFFERENT panel's contents that the
  # object making it cannot see. So the view asks here rather than assuming, and says it only where
  # the reader can turn around and check it.
  #
  # Off the rollup's own rows rather than off a second query: the rows are already loaded and the
  # question is precisely "is it on the page", which is what `rows` means and what a re-read would
  # not answer.
  def spec_directory_listed_in_rollup?(rollup, path)
    return false if rollup.nil?

    rollup.rows.any? { |row| row.path == path }
  end

  # == The "Tests whose outcome changed" panel's sentences

  # What window every figure on the panel was drawn from — how many runs, on which branch, and how
  # many of them said anything at all about how their examples ended.
  #
  # The third figure is the one that cannot be left out. `outcome` is nullable, so a run of nils is
  # an ordinary state, and a window's LENGTH says nothing about how much of it reported. "Across
  # the last 30 runs on main" over a window where three of them reported outcomes is a claim about
  # thirty runs made from three, and every count under it inherits the overstatement.
  #
  # Reported in RUNS throughout, never in rows: the comparison this panel makes is between runs, so
  # its denominator has to be one a reader can put the row counts beside.
  def unstable_tests_window_sentence(unstable)
    runs = "#{number_with_delimiter(unstable.run_count)} #{"run".pluralize(unstable.run_count)}"
    reported =
      if unstable.runs_reporting_outcomes == unstable.run_count
        "every one of which reported an outcome for at least one example"
      else
        "#{number_with_delimiter(unstable.runs_reporting_outcomes)} of which reported an outcome " \
          "for any example"
      end

    "Across the last #{runs}#{window_branch_clause(unstable)}, #{reported}." \
      "#{unstable_tests_silent_runs_clause(unstable)}"
  end

  # The matching rule, said on the panel rather than left in the code — because it is a rule a
  # reader has to know to read the list at all, and because it is the one thing here that is a
  # DECISION rather than a measurement. A test that moved keeps its history; a renamed one starts a
  # new history and its old one stops at the rename. Both are consequences a reader can only check
  # against their own repository if they are told the rule.
  def unstable_tests_matching_sentence
    "Tests are matched across those runs by their durable identity, not by file and not by line, " \
      "since both move under a test that did not change. So a test that moved keeps its history " \
      "here, and a test whose wording changed while its annotation held keeps its history too — " \
      "an unannotated test is identified by its description, so a reworded unannotated test " \
      "starts a new one."
  end

  # Where the panel stops looking, stated as a boundary rather than implied by an absence.
  #
  # The search begins at the runs' failures, which is what makes it affordable at the design point
  # (see `SpecObservation.unstable_identity_candidates_in`). The cost of that narrowing is real and specific:
  # a test that alternated `pending` and `passed` and never failed varied its outcome and is not
  # reported. A reader who is not told that reads this list as "every test whose outcome varied".
  def unstable_tests_boundary_sentence
    "The search starts from what failed, so a test that alternated between other outcomes — " \
      "pending in one run, passed in the next — without ever failing is outcome variance this " \
      "panel does not report."
  end

  # What the window held that the matching could not use, and what the narrowing did not reach.
  # All are silences, and a silence a reader cannot see is the one thing a panel counted off a
  # partial population must not leave them to discover.
  def unstable_tests_exclusion_sentence(unstable)
    [unstable_tests_unnamed_clause(unstable), unstable_tests_unresolved_clause(unstable),
     unstable_tests_truncation_clause(unstable)].compact.join(" ").presence
  end

  # Why there is no list and no zero: fewer than two runs of the window reported an outcome, so
  # there is no comparison to make and nothing this panel could print that would not be a figure
  # about silence.
  #
  # This is the panel's *Vacuous Green* refusal, and the description says which of the two states a
  # reader is looking at, because they are indistinguishable in every other way. A window whose
  # runs all passed and a window whose client sends no outcomes both produce an empty list; only
  # this sentence separates "we compared and found nothing" from "there was nothing to compare".
  #
  # The gate is `runs_reporting_outcomes >= 2`, so it is false in TWO states, and they have
  # different causes and different remedies. Silence is one of them; the other is a window that
  # reported perfectly well and holds exactly one run to have reported it. Both the leading clause
  # AND the explanation behind it are therefore per-state: "said nothing" is a claim about THIS
  # window, and asserting it over a window that did say something is the mirror of the Vacuous
  # Green hazard this method exists to refuse — a report read as silence, sending a reader to check
  # their formatter config when what they need is a second run. The two branches are worded so that
  # each names the thing its own reader has to change.
  def unstable_tests_incomparable_description(unstable)
    reported, cause =
      if unstable.runs_reporting_outcomes.zero?
        ["not one of them said how any example ended",
         "What CI reports here is optional and nothing validates it, so a window that said " \
           "nothing and a window with nothing wrong in it produce the same empty list. This one " \
           "said nothing, and no count is printed over it."]
      else
        ["one of them said how an example ended",
         "That report is real — it is simply the only one here, and an outcome needs an earlier " \
           "outcome to have changed from. A second run that reports is what this window is short " \
           "of, and no count is printed over it."]
      end

    "Comparing outcomes takes at least two runs that reported them — one run's outcome cannot have " \
      "changed from anything. Of the #{number_with_delimiter(unstable.run_count)} " \
      "#{"run".pluralize(unstable.run_count)}#{window_branch_clause(unstable)}, " \
      "#{reported}. #{cause}"
  end

  # The honest zero — reachable only behind `#comparable?`, and worded against the runs it was
  # actually drawn from rather than against the length of the window.
  #
  # Three different zeroes, said differently, because they are three different facts about a
  # repository: nothing failed at all, things failed but always failed, and something DID vary but
  # under a description this panel cannot attribute to one example. Collapsing the first two would
  # tell a reader with a permanently red test that their suite is stable. Collapsing the third
  # would be worse than imprecise — "not one of them reported any other outcome" is FALSE over a
  # window whose shared-description group reported two, and it would sit directly above the section
  # saying so.
  #
  # Every one of them is also worded against the descriptions it was drawn from, and not only
  # against the runs. A zero is a UNIVERSAL — "no description varied", "not one of them reported
  # any other outcome" — and when the candidate cap bit, the population it quantifies over is the
  # part of the window this panel examined rather than the window. Left unqualified it asserts a
  # property of descriptions that were never read, inches under the clause disclosing that they
  # were not read (`#unstable_tests_truncation_clause`). That is the same defect the shared-
  # description branch exists to refuse, one silence over: a caption is a claim about the list it
  # was counted off, so when the list is part of the candidates the caption says which part.
  def unstable_tests_none_description(unstable)
    reporting = "#{number_with_delimiter(unstable.runs_reporting_outcomes)} " \
                "#{"run".pluralize(unstable.runs_reporting_outcomes)}" \
                "#{window_branch_clause(unstable)} that reported outcomes"

    if unstable.shared_description_rows.any?
      "No description belonging to a single example changed its outcome " \
        "#{unstable_tests_examined_scope(unstable, reporting)}. What did vary, varied under a " \
        "description more than one example answers to, which is reported below rather than " \
        "counted here.#{unstable_tests_unexamined_caveat(unstable)}"
    elsif unstable.candidate_count.zero?
      # Unreachable under truncation by construction: the cap can only have bitten a window in
      # which something failed, so there is no unexamined population to qualify this one against.
      "No example failed in any of the #{reporting}, so there is nothing here whose outcome could " \
        "have changed. That is a comparison this window supported and it came back empty."
    elsif unstable.truncated?
      "#{number_with_delimiter(unstable.examined_count)} of the " \
        "#{number_with_delimiter(unstable.candidate_count)} descriptions that failed somewhere in " \
        "the #{reporting} were the ones compared across runs, and not one of those reported any " \
        "other outcome anywhere in them. Tests that fail consistently are not what this panel is " \
        "looking for.#{unstable_tests_unexamined_caveat(unstable)}"
    else
      "#{number_with_delimiter(unstable.candidate_count)} " \
        "#{"description".pluralize(unstable.candidate_count)} failed somewhere in the " \
        "#{reporting}, and not one of them reported any other outcome anywhere in them. Tests that " \
        "fail consistently are not what this panel is looking for."
    end
  end

  # The population a zero on this panel quantifies over. "Across the window" is only true when
  # every description that failed in it was compared; when the cap bit it is true of the examined
  # part alone, and the phrase says which part rather than letting the reader supply the wrong one.
  def unstable_tests_examined_scope(unstable, reporting)
    return "across the #{reporting}" unless unstable.truncated?

    "among the #{number_with_delimiter(unstable.examined_count)} of " \
      "#{number_with_delimiter(unstable.candidate_count)} failing descriptions this panel compared " \
      "across the #{reporting}"
  end

  # What a zero above a capped candidate list does NOT establish, said in the same breath as the
  # zero. `#unstable_tests_truncation_clause` discloses the cap against the LIST — "not represented
  # above" — which is a statement about rows that were printed; this one is about a claim, and the
  # claim is the thing a reader would otherwise carry away as clean.
  def unstable_tests_unexamined_caveat(unstable)
    return "" unless unstable.truncated?

    # `unexamined_count == 1` is one description past the cap, not a contrived state — the count is
    # the pre-LIMIT total, so a window with `UNSTABLE_CANDIDATE_LIMIT + 1` failing descriptions
    # lands here. Verb and pronoun agree with the noun, as at `#unstable_tests_shared_description_
    # sentence` and the trajectory captions above.
    one = unstable.unexamined_count == 1

    " The other #{number_with_delimiter(unstable.unexamined_count)} " \
      "#{"description".pluralize(unstable.unexamined_count)} that failed in this window " \
      "#{one ? "was" : "were"} never compared across runs, so nothing here is a finding about " \
      "#{one ? "it" : "them"}."
  end

  # The groups the matching rule could not rule on, said as what they are. Not flakiness and not
  # dropped: a description carried by two examples in one run holds that run's `failed` and its
  # `passed` at the same time, and either reading — listing it above, or omitting it — asserts
  # something nothing here established.
  def unstable_tests_shared_description_sentence(unstable)
    count = unstable.shared_description_rows.size

    "#{number_with_delimiter(count)} #{"description".pluralize(count)} varied in outcome across " \
      "this window AND #{count == 1 ? "was" : "were"} carried by more than one example in at least " \
      "one run of it. A description is not a key within a single run — a table-driven loop, or two " \
      "examples simply given the same words, put several under one — so what varied may be which " \
      "of those examples was which rather than a test that changed. Listed here rather than " \
      "counted above, because calling them flaky would be a false positive manufactured by the " \
      "matching rule."
  end

  # == The opened unstable test's sentences

  # DID THE CAP BITE — asked once here and never recomputed, because three sentences on this panel
  # branch on it and the failure mode of the panel is those sentences DISAGREEING inside one
  # paragraph. The scope sentence says "the 200 oldest of the 250 rows", the alert above the table
  # says the newest rows are missing, and the reading rule says which readings survive that; two of
  # those spelling the comparison out by hand is two places for one of them to keep the old
  # unconditional wording after the other is fixed. That is not hypothetical — it is exactly how
  # this panel shipped the first time, with a scope sentence that disclosed the truncation and a
  # reading rule two clauses later that contradicted it.
  #
  # `recorded_count` is counted over the WINDOW and before the cap, and `rows` is what survived it,
  # so their difference is the number of rows the cap dropped and nothing else. Neither is a count
  # of runs, and this predicate deliberately says nothing about runs: whether whole RUNS fell off
  # depends on how many rows each run carries, and the surface's claims are worded so they do not
  # need to know.
  def unstable_test_runs_capped?(sequence) = sequence.recorded_count > sequence.rows.size

  # What the sequence IS — how much of this description's history the window holds, and how much of
  # THAT is on the page.
  #
  # Its own method rather than a widening of `#spec_file_examples_scope_sentence` or
  # `#repeated_description_examples_scope_sentence`, for the reason the second of those states about
  # the first: those two count a RUN's examples and this counts a WINDOW's rows, so parameterising a
  # noun would make one sentence stand for claims about two populations that are free to diverge.
  #
  # Counted in ROWS and never in runs, and that is the sentence's one hard rule. One row per run is
  # what the data usually is rather than a promise this list makes, and it comes apart in BOTH
  # directions: a run that recorded nothing under this description contributes no row — a test added
  # halfway through a window of thirty has fifteen — and a description carried by more than one
  # example in a run contributes one row per example. So `rows.length` is neither the window's length
  # nor bounded below by it, and a sentence saying "12 of the last 30 runs" off this list would be
  # reporting a coverage nobody counted. The window's own length is stated beside the count as what
  # it is: the span these rows were drawn from, not their denominator.
  #
  # The cap is disclosed only when it BIT, and whether it bit is asked of
  # `#unstable_test_runs_capped?` rather than recomputed here — see that predicate for why the
  # comparison is written down once. The object is not asked: `UnstableTestRuns` serves
  # `recorded_count` as an operand — counted before the cap — and no `truncated?` predicate, on the
  # standing rule that this ladder serves operands and the surface states the reading.
  #
  # WHICH END the cap keeps is a property of the WINDOW and not of the read, and this sentence is
  # the only place that difference is visible. `SpecObservation.outcome_sequence_in` orders by
  # `array_position` over the run ids it was handed, so the rows come back in the order of the
  # window itself — and this page's window (`Repository#suite_size_trajectory`) is OLDEST FIRST,
  # because it is the window the "Suite growth" chart above is plotted along. So the cap keeps the
  # OLDEST rows here, where the same method under `GET /api/v1/repository` keeps the newest ones off
  # a newest-first window. Reading the direction off the object would be reading it off a promise
  # nothing makes; it is stated here, for this window, in this caller's words.
  def unstable_test_runs_scope_sentence(sequence)
    recorded = number_with_delimiter(sequence.recorded_count)
    shown = number_with_delimiter(sequence.rows.size)
    plural = "row".pluralize(sequence.recorded_count)
    runs = "#{number_with_delimiter(sequence.run_count)} #{"run".pluralize(sequence.run_count)}"

    if unstable_test_runs_capped?(sequence)
      "The #{shown} oldest of the #{recorded} #{plural} the last #{runs} of this window recorded " \
        "under it, in the window's own order — oldest run first, the direction the “Suite growth” " \
        "chart above is plotted in."
    else
      "All #{recorded} #{plural} the last #{runs} of this window recorded under it, in the " \
        "window's own order — oldest run first, the direction the “Suite growth” chart above is " \
        "plotted in."
    end
  end

  # HOW TO READ THE COLUMN, said on the panel because it is the entire reason the panel exists.
  #
  # The ranking above cannot make this distinction and is right not to try: its row says `30 runs,
  # 4 failed, [failed, passed]`, and those three figures are IDENTICAL for two windows that call for
  # opposite work. Four failures at the newest four runs is a regression with a commit to find; four
  # failures scattered through thirty is flakiness with none. A reader who has the sequence but not
  # the rule reads a shape and guesses, and the guess that costs most is hunting nondeterminism in a
  # test that fails deterministically on code that changed.
  #
  # Worded by POSITION IN THIS LIST rather than by "recent" or "latest", because the two are not the
  # same word here: this window runs oldest first, so the newest run is the LAST row and a sentence
  # about "the failures at the top" would point a reader at the opposite end of the evidence from
  # the one it means. The scope sentence beside it states the direction; this one names the end.
  #
  # == Why this is CONDITIONED on the cap and not static
  #
  # It was static once, on the argument that it is "a rule for reading the list rather than a claim
  # about this one, so it has nothing to drift from". That argument was wrong on its own premise.
  # "Failures bunched at the END of this list — ITS NEWEST RUNS" is a claim about this list: it
  # asserts that the end of the rendered rows is the newest end of the window. On a newest-first
  # window that would hold whatever the cap did, but this window is OLDEST FIRST, so the `LIMIT`
  # sheds the NEWEST rows — and the moment it bites, the sentence is false in the one direction the
  # panel cannot survive being false in.
  #
  # The geometry is ordinary rather than exotic. Truncation needs more than 200 rows over at most 30
  # runs, i.e. more than ~6.7 rows per run — one description carried by ten examples in a run is a
  # table-driven loop. At 25 runs × 10 rows the newest FIVE RUNS are not on the page at all, so a
  # test that started failing at run 21 renders as 200 consecutive passes under a rule instructing
  # the reader that failures at the end mean regression and no failures scattered means no
  # flakiness. Neither branch applies, nothing on the page says the answer is missing rather than
  # negative, and the available conclusions are "this test is fine" or "this panel is broken". Both
  # are the wrong-culprit-commit failure `UnstableTestRuns`' "window is HANDED IN" section calls the
  # one error this drill-in cannot survive, reached from the other side.
  #
  # So the regression branch is WITHHELD when the cap bit, rather than reworded. The flakiness
  # branch survives untouched and is stated: scattered failures among the rows that ARE here are
  # still scattered failures. What cannot be done is read a regression off an end that is not the
  # end — and, just as importantly, read the ABSENCE of failures there as health, which is the
  # reading a reader falls into by default and the one that lets a live regression off the page.
  #
  # Both branches are counted off `#unstable_test_runs_capped?`, the same predicate the scope
  # sentence and the alert use, so the three cannot disagree about whether the cap bit.
  def unstable_test_runs_reading_sentence(sequence)
    return unstable_test_runs_capped_reading_sentence if unstable_test_runs_capped?(sequence)

    "Read down the sequence rather than across the counts. Failures bunched at the END of this " \
      "list — its newest runs — are a regression, and the commit to look at is the one on the " \
      "first failing row after the last row that passed; failures scattered through the list are " \
      "flakiness, where there is no culprit commit to find and the work is quarantine or shared " \
      "state."
  end

  # The reading rule with the regression branch withheld, for a list the cap stopped short of the
  # window's newest rows. Its own method rather than a second string inside the branch above, so the
  # two readings are side by side in the file where a later edit to one is read against the other.
  #
  # It states what is NOT available before what is, which is the opposite of the usual ordering and
  # deliberate: the failure mode here is a reader applying the regression rule to a truncated end,
  # so the withdrawal has to arrive before the rule that survives it. And it names the absence of
  # failures explicitly, because "no failures at the end" is not a neutral observation on a list
  # whose end was cut off — it is the reading that turns a missing answer into a clean bill of
  # health.
  def unstable_test_runs_capped_reading_sentence
    "Read down the sequence rather than across the counts — but not off the end of it here. The " \
      "regression reading is taken off the window's newest runs, and the newest rows are the ones " \
      "the cap dropped, so the end of this list is not the end of this window's evidence: " \
      "failures sitting there need not be where the trouble started, and no failures sitting " \
      "there is not evidence that the test is passing now. Failures scattered through the rows " \
      "that ARE here are still flakiness, where there is no culprit commit to find and the work " \
      "is quarantine or shared state."
  end

  # THE CAP, SAID LOUDLY — the heading of the alert that sits above the table when the list stopped
  # short of the window's newest rows.
  #
  # A clause in the basis paragraph is not enough here, and that is a judgement about this panel
  # rather than a general preference for alerts. On its siblings a truncated list is a footnote: the
  # by-file and by-description drill-ins are read for WHAT IS IN THEM, and a reader who sees the top
  # 200 of 250 rows has the answer they came for. This panel is read for WHERE IN THE SEQUENCE the
  # failures sit, and the cap removes the end the reading is taken from — so truncation does not
  # shorten the answer here, it removes it, and does so while leaving a full-looking table of 200
  # rows on the page. A missing answer that looks exactly like a negative one is the thing a reader
  # cannot detect for themselves, which is the standing test for whether a disclosure belongs in the
  # prose or in front of it.
  def unstable_test_runs_cap_alert_title = "This list stops short of the window's newest rows"

  # WHAT the cap took and WHERE the list therefore ends, with the way to see the missing end.
  #
  # Three facts, and each one is checkable against something else on this page rather than taken on
  # trust: how many rows are missing (against the scope sentence's two figures), which commit the
  # list ends at (against the "Recent runs" panel below, where the window's actual newest commit is
  # printed — that comparison is the whole point of naming the sha, and on a window whose newest
  # runs fell off entirely the two shas differ, visibly), and how long ago that was (because "the
  # list ends four commits back" is a different size of gap on a busy branch than on a quiet one).
  #
  # It claims the rows are the newest and NOT that whole runs are missing, which is the precise
  # thing that is true in both truncation geometries. The read is ordered by window position and
  # capped, so what it sheds is always a suffix in window order — the newest rows recorded under
  # this description, full stop. Whether that suffix is two rows off the newest run or five entire
  # runs depends on how many examples carry the description per run, and a sentence asserting either
  # shape would be false in the other one. "The end of this list is not the end of this window's
  # evidence" is true whenever the cap bit and is the claim the reading rule needs; nothing here
  # says more than that.
  #
  # The escape hatch is real and is the same sequence over the OTHER window: `GET
  # /api/v1/repository`'s `unstable_test` block reads `recent_test_runs`, which is ordered
  # newest-first, so its cap sheds the OLDEST rows and keeps exactly the end this page drops. That
  # is a property of the two windows rather than of the read — `SpecObservation.outcome_sequence_in`
  # orders by `array_position` over the run ids it is handed and imposes no direction of its own —
  # which is why the pointer can be given as a fact rather than as a hope.
  def unstable_test_runs_cap_alert_body(sequence)
    dropped = sequence.recorded_count - sequence.rows.size
    last = sequence.rows.last

    "The cap keeps this window's OLDEST rows, so the #{number_with_delimiter(dropped)} " \
      "#{"row".pluralize(dropped)} it dropped are the newest ones recorded under this description. " \
      "The list ends at #{last.commit_sha.first(7)}, ingested #{time_ago_in_words(last.ingested_at)} " \
      "ago — compare that against the newest commit in “Recent runs” below to see how far short of " \
      "the window it stops. For the other end of the same sequence, read `unstable_test` over " \
      "`GET /api/v1/repository`: its window runs newest first, so its cap sheds the oldest rows and " \
      "keeps the ones missing here."
  end

  # Rows this window recorded under the description that said NOTHING about how it ended, counted
  # and stated — the silence the sequence would otherwise read as a gap in the story.
  #
  # `outcome` is nullable and nothing platform-side validates it, so a client that stopped sending
  # outcomes writes rows that are present and silent. Those are not passes and are counted as one
  # nowhere: `UnstableTests::Row#changed?` compares against `reported_outcome_count` rather than
  # `recorded_count` one rung up precisely so such a client cannot manufacture a flip, and a sequence
  # that let them read as passes would manufacture the same flip HERE — where it would look like a
  # date, which is the one wrong answer this panel is read to produce.
  #
  # Counted over the WINDOW rather than over the listed rows, so a truncated list's silence is still
  # countable, and rendered only when there is any: a clause reading "0 of them said nothing" is a
  # sentence about arithmetic rather than about this test.
  #
  # The NOUN is carried on the denominator — "1 of the 3 rows" and not "1 of the 3". This clause
  # renders after the reading rule, which is several sentences of its own, so the "3 rows" it is
  # counting against is no longer in the reader's ear by the time the bare number arrives; and the
  # paragraph it sits in is one that also counts RUNS, which is the other noun a reader would supply
  # for it. One word removes the choice.
  def unstable_test_runs_silence_clause(sequence)
    silent = sequence.unreported_outcome_count
    return "" unless silent.positive?

    recorded = sequence.recorded_count

    " #{number_with_delimiter(silent)} of the #{number_with_delimiter(recorded)} " \
      "#{"row".pluralize(recorded)} said nothing about how it ended. Silence is not a pass and is " \
      "not counted as one here, so a gap in the column is a run that recorded the test and " \
      "reported no outcome for it."
  end

  # The window recorded nothing under the description that was asked for. An ordinary answer and not
  # an error, on the spelling `RepeatedDescriptionExamples`' empty state fixed one ladder over:
  # `?unstable_test=` is a URL a reader types, edits and bookmarks, so a typo, a reworded description
  # and a stale bookmark all arrive here.
  #
  # It NAMES THE DESCRIPTION BACK, because an empty state without a subject is a sentence about
  # nothing — and here the subject is a sentence somebody wrote, which is the one thing a reader can
  # check against their own suite.
  #
  # And it names the RULE that makes the commonest cause of this state ordinary rather than broken:
  # the project matches tests by description alone, so a renamed test STARTS A NEW HISTORY and its
  # old one stops at the rename. A reader who does not know that reads an empty panel as a lost
  # history rather than as two.
  def unstable_test_runs_none_description(sequence)
    runs = "#{number_with_delimiter(sequence.run_count)} #{"run".pluralize(sequence.run_count)}"

    "None of the last #{runs} of this window recorded an example described " \
      "“#{sequence.name}”. Tests are matched here by their description alone, so a test renamed or " \
      "reworded since starts a new history under its new description and this one stops at the " \
      "rename — a bookmark to the old wording goes stale by design. The “Tests whose outcome " \
      "changed” panel above lists the descriptions this window did record."
  end

  # == The "Areas that grew or shrank over the window" panel's sentences

  # WHICH run this comparison was actually taken against, and how far back it sits.
  #
  # The panel's single most important sentence, and the one that has no counterpart on the last-push
  # panel beside it. There, "the previous run on this branch" names the comparand exactly: there is
  # only one candidate and it is either usable or the panel says why not. Here the baseline is WALKED
  # — the oldest run of the window that can be compared against this one — so the comparand is a
  # choice the reader did not make and cannot see, and a figure headed "across the window" that was
  # in fact taken across four runs is a wrong measurement rather than a vague one.
  #
  # Three facts, because three different readers need different ones: the commit, so it can be looked
  # up; how far back, so the figure can be sized against the window; and how long ago, because "26
  # runs back" is a week on one branch and a quarter on another.
  def spec_directory_window_growth_baseline_sentence(growth)
    position =
      if growth.runs_back == 1
        "the run immediately before it"
      else
        "#{number_with_delimiter(growth.runs_back)} runs back"
      end

    "Measured against #{growth.baseline_run.commit_sha.first(7)} — #{position} in this window, " \
      "#{time_ago_in_words(growth.baseline_run.created_at)} ago — and this run."
  end

  # How much of the window the comparison actually spans, and what the walk stepped over to reach
  # its baseline.
  #
  # A window is a promise about depth, so a comparison that spans less of it than the heading says
  # has to say by how much and why. Both reasons are named separately rather than totalled: a run
  # that reported no tests is a client or a job that failed to report, and a run assembled from a
  # different number of parts is a sharding change — two different things to go and fix, and a bare
  # "3 runs were skipped" is neither.
  def spec_directory_window_growth_span_sentence(growth)
    branch = window_branch_clause(growth)
    unless growth.shortened?
      return "It spans all #{number_with_delimiter(growth.window_run_count)} " \
             "#{"run".pluralize(growth.window_run_count)} of this window#{branch}."
    end

    "It spans #{number_with_delimiter(growth.covered_run_count)} of the last " \
      "#{number_with_delimiter(growth.window_run_count)} " \
      "#{"run".pluralize(growth.window_run_count)}#{branch}: the " \
      "#{number_with_delimiter(growth.skipped_count)} older " \
      "#{"run".pluralize(growth.skipped_count)} could not be compared against this one — " \
      "#{spec_directory_window_growth_skipped_reasons(growth)}."
  end

  # Why the walk reached the far end of the window without finding a baseline — the two states
  # decidable from the runs alone, said apart because they are two different repairs.
  #
  # The composition branch names this run's own delivery, through the same `TestRun#delivery_description`
  # seam the Overview delta and the last-push panel word this with, so a reader is told what the
  # earlier runs would have had to match rather than only that they did not.
  # Each branch counts the runs ITS OWN condition rejected, off the split counters, rather than
  # every earlier run in the window. The walk rejects on two conditions and `next`s past the
  # unmeasured ones before composition is ever asked of them, so a composition sentence sized to
  # the whole window makes two wrong claims at once: it blames sharding for runs whose sharding was
  # never looked at (and is often fine — an unmeasured run reports zero shards, which is assembled
  # exactly like an unsharded anchor), and it then counts those same runs a second time in the
  # clause below. Both are the rule the `#..._skipped_reasons` comment sets: a reason given for
  # runs it did not apply to is a wrong explanation, not a vague one.
  #
  # `:no_measured_baseline` was previously right only by accident — it is unreachable while any run
  # mismatched, so "every earlier run" happened to equal the unmeasured count. Deriving it makes
  # the accident a guarantee.
  def spec_directory_window_growth_no_baseline_description(growth)
    if growth.state == :no_measured_baseline
      unmeasured = growth.skipped_unmeasured_count
      return "#{unmeasured == 1 ? "The" : "Every one of the"} " \
             "#{spec_directory_window_growth_earlier_runs(growth, unmeasured)} reported no tests, " \
             "so there is no measured end to compare this run against. A run that reported zero " \
             "tests has a count but not a measurement, and differencing against it would charge " \
             "this branch for a gap in the reporting."
    end

    # Qualified as the runs that got PAST the measured check, but only where some run did not —
    # where none was rejected earlier the qualifier would distinguish nothing.
    mismatched = growth.skipped_assembled_differently_count
    runs = spec_directory_window_growth_earlier_runs(growth, mismatched)
    runs += " that reported tests" if growth.skipped_unmeasured_count.positive?

    "#{mismatched == 1 ? "The" : "Not one of the"} #{runs} " \
      "#{mismatched == 1 ? "was not" : "was"} assembled the way this run was — this run was " \
      "#{growth.anchor_run.delivery_description}. A run's examples arrive shard by shard, so a " \
      "difference taken across two compositions would report areas growing and shrinking that no " \
      "commit touched.#{spec_directory_window_growth_unmeasured_clause(growth)}"
  end

  # == The "Slowest tests across the window" panel's sentences
  #
  # The repository-grain sibling of the per-run "Slowest tests" panel's caption, and it has one
  # sentence that panel structurally cannot write: a matching rule. One run's ranking matches
  # nothing, so it has nothing to disclose about how two rows became one test; this one groups on
  # `spec_identity_id` and every row here may be a history assembled across a move and a reword.

  # What the list IS, over what window, ordered on what — before anything else, because a ranked
  # list whose ordering is unstated is read as "the worst of everything" and this one is neither.
  #
  # The ORDERING is named rather than assumed. Every other duration panel on this page ranks one
  # run, where "slowest" has exactly one meaning; here there are two, the window total and the
  # single worst run, both are rendered side by side in the table below, and only one of them
  # decided the order. A reader scanning the "Slowest single run" column down a list ordered on the
  # other one needs to have been told.
  #
  # And the superlative is WITHDRAWN in the one state where it is false. Under the cap this list is
  # not the window's most expensive tests — it is the anchor run's slowest, re-totalled over the
  # window — so a lead reading "The 10 tests that cost this suite the most" would be a claim the
  # truncation clause then takes back two sentences later. A partitive ("10 of the tests that…")
  # says the same thing about the same rows without ever asserting the closure the cap denies.
  def slowest_tests_window_sentence(slowest)
    tests = "#{number_with_delimiter(slowest.rows.size)} #{"test".pluralize(slowest.rows.size)}"
    runs = "#{number_with_delimiter(slowest.run_count)} #{"run".pluralize(slowest.run_count)}"
    opening = if slowest.truncated?
                "#{number_with_delimiter(slowest.rows.size)} of the tests"
              else
                "The #{tests}"
              end

    "#{opening} that cost this suite the most wall clock across the last " \
      "#{runs}#{window_branch_clause(slowest)}, ordered on that window TOTAL — not on any single " \
      "run of it."
  end

  # The matching rule, on the panel rather than in the code, for the reason the sibling panel above
  # states its own: it is the one thing here that is a DECISION rather than a measurement, and its
  # consequences are ones a reader can only check against their own repository if they are told it.
  #
  # And the rule here is the OPPOSITE of its neighbour's. `#unstable_tests_matching_sentence` — the
  # "Tests whose outcome changed" panel further up the page — matches on the description alone and
  # says so: a moved test keeps its history there and a renamed one starts a new one. This panel
  # matches on the durable identity, so BOTH survive, and a reader carrying the other panel's rule
  # down the page would misread every row that discloses a move or a reword below. Two panels on
  # one page with two different matching rules is exactly the drift a shared sentence would hide,
  # so each states its own.
  def slowest_tests_matching_sentence
    "Tests are matched across those runs by the durable identity SpecGuard resolved for them — " \
      "not by file, not by line and not by description, since all three move under a test that " \
      "did not change. So a test that MOVED keeps its history here, and so does one that was " \
      "reworded; where either happened, the row below says so."
  end

  # ⭐ The partition, named. WHICH tests are on this list was decided by one run — the newest in the
  # window — and the window then supplied their history, so a test deleted halfway through is
  # absent however slow it was while it lived.
  #
  # It cannot be recovered from the rows: nothing in a list of ten tests tells a reader which
  # eleventh is missing, and "the slowest tests in this repository" is precisely the reading this
  # sentence exists to narrow. The run is NAMED rather than described, so a reader who thinks a
  # test should be here can go and look at the run that decided it was not.
  def slowest_tests_anchor_sentence(slowest)
    "Which tests are ranked was decided by #{slowest.anchor_run.commit_sha.first(7)}, the newest " \
      "run in this window: a test that run did not report is not in the suite being asked about " \
      "and is not here, however long it took while it existed."
  end

  # How much of the ranked population carried a timing — the same three-state sentence the per-run
  # panel writes one grain down, over this panel's own denominator.
  #
  # The denominator is the anchor's RESOLVED rows and never its recorded ones, because the rows it
  # could not identify are a separate exclusion with a separate sentence (`#slowest_tests_
  # exclusion_sentence`), and folding the two together would report a timing gap for rows that were
  # dropped before timing was ever asked about. `SlowestTests#coverage_label` holds that pairing so
  # this sentence cannot state a fraction whose halves came from two different populations.
  def slowest_tests_coverage_sentence(slowest)
    if slowest.complete?
      return "Every one of the #{number_with_delimiter(slowest.resolved_count)} " \
             "#{"row".pluralize(slowest.resolved_count)} that run resolved to a durable test " \
             "reported a duration, so the ranking covers the whole of what it identified."
    end

    "Ranked over the #{slowest.coverage_label} rows that run resolved to a durable test that " \
      "reported a duration; #{number_with_delimiter(slowest.untimed_count)} reported none. A test " \
      "that never ran has no duration to report, so a missing timing is a faithful record rather " \
      "than a gap — and it is why a row here can read \"not reported\" instead of 0.00s."
  end

  # The two silences: rows the anchor wrote that could not be identified, and candidates the cap
  # never examined. Both are facts about the population the ranking was drawn from rather than notes
  # about it, and both are rendered only where they are TRUE of this window — a clause reading "0
  # rows carried no durable identity" is a sentence about arithmetic.
  def slowest_tests_exclusion_sentence(slowest)
    [slowest_tests_unresolved_clause(slowest), slowest_tests_truncation_clause(slowest)]
      .compact.join(" ").presence
  end

  # ⭐ Why an empty ranking is not "nothing in this suite is slow" — the panel's *Vacuous Green*
  # refusal, and the state a reader meets for the seconds after every single ingest.
  #
  # `Ingest::IdentityResolutionJob` runs out of band, so the newest run's rows land identified by
  # nothing at all and are matched to durable tests a moment later. Rendered as an empty list that
  # is "nobody has told us yet" wearing the spelling of "everything is fast", and the two are
  # indistinguishable in every other way — which is the whole reason `SlowestTests` separates
  # `#recorded?` from `#resolved?` rather than serving one `#any?`.
  #
  # The row count is stated because it is what makes the sentence checkable: a reader told that
  # 4,900 rows are waiting can see that their run arrived and that only the matching is outstanding.
  def slowest_tests_unresolved_description(slowest)
    rows = "#{number_with_delimiter(slowest.recorded_count)} " \
           "#{"row".pluralize(slowest.recorded_count)}"

    "#{slowest.anchor_run.commit_sha.first(7)}, the newest run in this window, recorded #{rows} " \
      "and not one of them has been matched to a durable test yet. That matching runs just after a " \
      "run lands rather than during it, so this is the ordinary state for the moments after an " \
      "ingest and it clears on its own. It is reported as what it is: no ranking has been made " \
      "here, which is a different fact from a suite in which nothing is slow."
  end

  private

  # Said when the reader named a run SpecGuard has none of, and the page anchored on another one.
  #
  # Two states, because they are two different facts about this repository and only one of them is
  # about the sha. A repository with runs substituted its newest one and the sentence names it, so
  # the reader can see which run they are actually reading; a repository with NO runs substituted
  # nothing at all, and telling that reader the page "is anchored on — instead" would name an empty
  # string where a commit should be. It is the same split `#trajectory_branch_fallback_notice` makes
  # for a trajectory whose fallback branch is itself blank.
  #
  # The asked-for sha is truncated, and this is the only place on the page that echoes it back: it
  # is unvalidated URL input, and `test_runs.commit_sha` is a plain `string` column written from
  # whatever CI reported — short form and long form both — so there is no length this could rely on.
  #
  # `escape: false` for the reason `#trajectory_branch_fallback_notice` gives over the same idiom:
  # this returns a plain String precisely so that ERB escapes it, once, at the render. `truncate`
  # escaping first would put a `SafeBuffer` of already-escaped text inside a String that is not
  # itself safe, and the echoed sha would reach the page escaped twice.
  def run_anchor_fallback_sentence(requested, shown)
    asked = truncate(requested, length: 60, escape: false)

    if shown.nil?
      return "SpecGuard has no run for #{asked}, and no run at all on this repository yet — so " \
             "there is nothing here anchored on it."
    end

    "SpecGuard has no run for #{asked}, so this page is anchored on " \
      "#{shown.commit_sha.first(7)} — the run that reported most recently — instead."
  end

  # "2 earlier runs in this window on main" — the noun phrase both no-baseline branches count with,
  # written once so the two of them cannot drift into describing the same window differently. The
  # COUNT is the caller's, because the two branches are about different subsets of the window.
  def spec_directory_window_growth_earlier_runs(growth, count)
    "#{number_with_delimiter(count)} earlier #{"run".pluralize(count)} in this window" \
      "#{window_branch_clause(growth)}"
  end

  # The walk's two rejections, in the words of what each one is. Joined rather than templated
  # per-state so a window that hit both says both, and neither clause is printed where its count is
  # zero — a reason given for runs it did not apply to is a wrong explanation, not a vague one.
  #
  # A single stepped-over run says "it", because the sentence has already counted it: "the 1 older
  # run could not be compared — 1 reported no tests" counts one run twice in eleven words, and a
  # reader re-reads it looking for the second one.
  def spec_directory_window_growth_skipped_reasons(growth)
    unmeasured = growth.skipped_unmeasured_count
    mismatched = growth.skipped_assembled_differently_count

    if growth.skipped_count == 1
      return unmeasured.positive? ? "it reported no tests" : "it was assembled from a different " \
                                                             "number of parts"
    end

    reasons = []
    reasons << "#{number_with_delimiter(unmeasured)} reported no tests" if unmeasured.positive?
    if mismatched.positive?
      reasons << "#{number_with_delimiter(mismatched)} #{mismatched == 1 ? "was" : "were"} " \
                 "assembled from a different number of parts"
    end

    reasons.join(" and ")
  end

  # Runs the walk rejected before it ever reached the composition question. Only where there were
  # any: the composition sentence is true of the runs it describes, and appending "a further 0" to
  # it would be a clause about nothing.
  def spec_directory_window_growth_unmeasured_clause(growth)
    count = growth.skipped_unmeasured_count
    return "" unless count.positive?

    " A further #{number_with_delimiter(count)} #{"run".pluralize(count)} in the window reported " \
      "no tests at all."
  end

  # " on main", or nothing at all. `suite_size_trajectory` returns an empty window for a run that
  # named no branch, so the panel is not rendered without one — but a sentence that would read
  # "the last 30 runs on " if that ever changed is worse than one that simply says less.
  #
  # Shared by all four panels drawn on that window — the outcome panel, the area-movement one, its
  # no-baseline states and the window-grain slowest-tests ranking — for the reason every seam on
  # this page is shared: two spellings of "on main" is two things that agree today with no
  # structural reason to keep agreeing.
  def window_branch_clause(panel)
    panel.branch.presence ? " on #{panel.branch}" : ""
  end

  # Runs of the window that wrote no per-example rows at all — a different absence from "reported
  # no outcome", and one the sentence above would otherwise fold into it. A run ingested before
  # these rows existed, or one whose client sends no per-example detail, is a run of the window
  # with nothing at this grain rather than a run that was quiet about outcomes.
  def unstable_tests_silent_runs_clause(unstable)
    silent = unstable.run_count - unstable.runs_with_rows
    return "" unless silent.positive?

    " #{number_with_delimiter(silent)} of them recorded no per-example rows at all."
  end

  # Rows the matching had to leave out, counted and stated. A null description cannot be matched to
  # itself across runs — two nulls are not known to be one example — so pooling them under one
  # group would invent a test with a history. Excluding them silently is the other failure: the
  # panel would be a claim about the window made from part of it, with nothing saying which part.
  #
  # Counted in ROWS, deliberately, and worded that way. An unnamed row is precisely a row this
  # panel cannot say is a test, so reporting a number of "tests" here would be the same identity
  # claim the exclusion exists to decline.
  #
  # The second clause states the rule about the rows this window actually holds, so it counts with
  # the first. At one row there is no pair to be unequal and nothing to pool it with, so the reason
  # is the one that still holds of a single null: it cannot be matched to ITSELF across runs.
  def unstable_tests_unnamed_clause(unstable)
    return nil unless unstable.unnamed_count.positive?

    one = unstable.unnamed_count == 1
    reason = if one
               "a null description is not known to be one test with itself across runs, so it is"
             else
               "two of those are not known to be one test, so they are"
             end

    "#{number_with_delimiter(unstable.unnamed_count)} " \
      "#{"row".pluralize(unstable.unnamed_count)} in this window carried no description; " \
      "#{reason} excluded from the matching rather than pooled into #{one ? "a test" : "one"}."
  end

  # The sibling exclusion, for the rows that carried a description but reached no durable identity
  # — the column the identity-grained matching (SPGD-758) is denied by instead. Same grain as the
  # clause above, same refusal: a row the resolver never matched to a test cannot be followed
  # across runs, and dropping it silently would be a claim about a population the panel did not
  # read. Counted in ROWS for the same reason the unnamed count is.
  #
  # Rendered under the same conditions and behind the same `comparable?` guard as the clause above:
  # the count is `nil`, never `0`, on an incomparable window, and this clause is reached only
  # through `#unstable_tests_exclusion_sentence` inside the panel's compared branch.
  def unstable_tests_unresolved_clause(unstable)
    return nil unless unstable.unresolved_count.positive?

    one = unstable.unresolved_count == 1

    "#{number_with_delimiter(unstable.unresolved_count)} " \
      "#{"row".pluralize(unstable.unresolved_count)} in this window reached no durable identity " \
      "(it was never matched to a test), and #{one ? "was" : "were"} excluded from the matching " \
      "rather than pooled."
  end

  # The cap, disclosed only when it bit — and stated as what was KEPT rather than as a bare number
  # cut, because which end of the candidate list survived is the part that decides what this panel
  # could still see. Fewest failures first: a description that failed in every run of the window is
  # one whose outcome did not change, so the cap sheds that end first.
  def unstable_tests_truncation_clause(unstable)
    return nil unless unstable.truncated?

    "#{number_with_delimiter(unstable.candidate_count)} descriptions failed somewhere in this " \
      "window — more than this panel examines at once — so the " \
      "#{number_with_delimiter(unstable.examined_count)} that failed fewest times were the ones " \
      "compared across runs, and the other #{number_with_delimiter(unstable.unexamined_count)} " \
      "#{unstable.unexamined_count == 1 ? "is" : "are"} not represented above."
  end

  # The truncated file whose timed rows ran out before the cap did — a ranked head and an unranked
  # tail on one page, and the only shape here where the list shows part of BOTH populations.
  #
  # It counts each population separately because one figure cannot describe both: the timed rows
  # are ranked and complete (a listed untimed row means the cap never reached the timed ones), the
  # untimed rows are a sample of a population nothing ordered, and the remainder is the part of the
  # file this page does not have. Said as one number — "the 50 slowest" — every one of those three
  # facts is lost and the first is stated backwards.
  def spec_file_examples_mixed_tail_sentence(examples)
    "The #{number_with_delimiter(examples.shown_timed_count)} timed examples of the " \
      "#{number_with_delimiter(examples.recorded_count)} this run recorded in it, slowest first, " \
      "then #{number_with_delimiter(examples.shown_untimed_count)} of the " \
      "#{number_with_delimiter(examples.untimed_count)} that reported no duration and nothing " \
      "ranked — the remaining #{number_with_delimiter(examples.untimed_omitted_count)} are not " \
      "shown."
  end

  # The same meeting of the two axes for the repeated-description drill-down, and its own sentence
  # for the reason its caller is its own method: "in it" names a file's population and "under it"
  # names a description's, and one string standing for both would make that a single edit nobody
  # meant to make at either panel.
  def repeated_description_examples_mixed_tail_sentence(examples)
    "The #{number_with_delimiter(examples.shown_timed_count)} timed examples of the " \
      "#{number_with_delimiter(examples.recorded_count)} this run recorded under it, slowest " \
      "first, then #{number_with_delimiter(examples.shown_untimed_count)} of the " \
      "#{number_with_delimiter(examples.untimed_count)} that reported no duration and nothing " \
      "ranked — the remaining #{number_with_delimiter(examples.untimed_omitted_count)} are not " \
      "shown."
  end

  # How much of the run the breakdown after it covers. Worded "Every one of the …" when it covers
  # all of them, matching the timing sentence directly above it on the page rather than inventing a
  # second way to say the same shape of thing.
  def slowest_examples_outcome_scope(slowest_examples, examples)
    reported = slowest_examples.reported_outcome_count
    return "Every one of the #{examples} reported an outcome" if reported == slowest_examples.recorded_count

    "#{number_with_delimiter(reported)} of the #{examples} reported an outcome"
  end

  # The two counted names, plus the remainder when there is one.
  #
  # The zeroes here are honest zeroes and are printed: they sit behind `#outcomes_reported?`, so
  # "0 failed" is only ever reached on a run that DID report outcomes and reported no failures
  # among them. The remainder clause is omitted entirely when it is zero, because "0 reported
  # something other than either" is a sentence about arithmetic rather than about this run.
  def slowest_examples_outcome_breakdown(slowest_examples)
    counted = ["#{number_with_delimiter(slowest_examples.failed_count)} failed",
               "#{number_with_delimiter(slowest_examples.pending_count)} pending"]

    other = slowest_examples.other_outcome_count
    return counted.to_sentence unless other.positive?

    counted << "#{number_with_delimiter(other)} reported something other than either — not read " \
               "as a pass, since nothing validates what CI sends here"
    counted.to_sentence
  end

  # The rows that said nothing, on a run where some rows did. Silence inside a population that
  # reported is not covered by the counts before it, and leaving it to be reached by subtraction is
  # how a reader concludes a failure count was taken over more rows than it was.
  def slowest_examples_unreported_clause(slowest_examples)
    unreported = slowest_examples.unreported_outcome_count
    return "" unless unreported.positive?

    " The other #{number_with_delimiter(unreported)} reported none."
  end

  # One branch as one item, for BOTH the row and the menu.
  #
  # The two controls differ in WHICH branches they carry — the row is cut and pulls the drawn branch
  # to the front, the menu is the untouched full list — and that difference is the point of having
  # two of them. They must not differ in what an item IS. Both mean "go to this branch", so for a
  # given branch they have to produce the same href and the same idea of `current`; while the two
  # `map` bodies were written out separately, nothing but convention held that. Adding an anchor
  # fragment to one, or changing how `current` is decided, would have left the row and the menu
  # quietly disagreeing about the same branch on the same page.
  #
  # With this extracted, the ordering IS the only difference in the code, which is what the comments
  # on both callers already say the intent is.
  def trajectory_branch_item(repository, history, current_branch)
    { label: trajectory_branch_label(history),
      href: drill_down_path(repository, branch: history.name, anchor: "suite-trajectory"),
      current: history.name == current_branch }
  end

  # Whether the row had to leave anything out — the one condition the menu and the hidden-branches
  # sentence both hang off.
  #
  # They are the two halves of one disclosure (what the row omitted, and where to find it), so they
  # appear and disappear together by construction rather than by two conditions kept in step by
  # hand. A page that counted three hidden branches with no menu under it, or offered a menu that
  # said nothing was hidden, would be a contradiction read in sequence.
  def trajectory_branches_overflow?(histories)
    histories.size > TRAJECTORY_BRANCH_CHOICES
  end

  # Whether the walk stopped rather than finished — the fact that turns every claim about this
  # list from one about the repository into one about a prefix of it.
  #
  # `>=` rather than `==`: a pinned branch is added to the walk's result, so a cut walk can hand
  # back more rows than its own bound. It cannot hand back FEWER than the bound and still be cut,
  # and a complete walk that lands exactly on the bound is the ambiguity "At least" already covers.
  def trajectory_walk_cut?(histories)
    histories.size >= Repository::BRANCH_HISTORY_LIMIT
  end

  # How the shown list is ordered, said in the terms that are actually true of it.
  def trajectory_listing_basis(histories, current_branch)
    order = if trajectory_pulled_to_front?(histories, current_branch)
              "The branch being drawn is listed first, then the branches with the most history."
            else
              "The branches with the most history are listed first."
            end

    return order unless trajectory_walk_cut?(histories)

    "#{order} SpecGuard stops after walking #{number_with_delimiter(Repository::BRANCH_HISTORY_LIMIT)} " \
      "branches, so that is an ordering over the ones it walked and not over every branch here."
  end

  # Whether the branch being drawn is only in the list because it was pulled there.
  def trajectory_pulled_to_front?(histories, current_branch)
    return false if current_branch.blank? || histories.first&.name == current_branch

    trajectory_shown_branches(histories, current_branch).first&.name == current_branch
  end

  # The branches that fit, in `Repository#branch_histories`' order — most history first, which is
  # the order a cut is worth making in.
  #
  # The order does NOT move as the reader clicks between branches. A list that reshuffled under the
  # pointer — the selected branch jumping to the front on every click — would make the reader
  # re-find their place each time, and the branch they just clicked is already marked `current`.
  #
  # The one exception is a selected branch that would otherwise not be shown AT ALL: it is pulled
  # to the front, displacing the thinnest history that would have been. That is a real case rather
  # than a defensive one — a reader can arrive by URL on a branch holding a single run while a dozen
  # busier branches sit ahead of it, and a selector that cannot show you what you are looking at is
  # worse than one that lists a branch out of order.
  def trajectory_shown_branches(histories, current_branch)
    shown = histories.first(TRAJECTORY_BRANCH_CHOICES)
    return shown if shown.any? { |history| history.name == current_branch }

    current = histories.find { |history| history.name == current_branch }
    return shown if current.nil?

    [current, *shown.first(TRAJECTORY_BRANCH_CHOICES - 1)]
  end

  # A branch and how much history it holds, as one link label.
  #
  # A capped count is worded `30+` and never as the exact figure the query stopped at, because it
  # stopped rather than finished — see `Repository::BranchHistory`. Below the cap the count is
  # exact, and inflected, because "1 runs" on the branch a reader is deciding about is the kind of
  # sentence that makes them doubt the figure next to it.
  def trajectory_branch_label(history)
    runs = if history.capped?
             "#{history.run_count}+ runs"
           else
             pluralize(history.run_count, "run")
           end

    "#{history.name} (#{runs})"
  end

  # `0` gets its own wording rather than riding the count. "only 0 of them are comparable" is a
  # sentence about a number; "none of them can be plotted" is a sentence about this repository.
  def trajectory_comparable_phrase(trajectory)
    plotted = trajectory.plotted.size
    return "none of them can be plotted" if plotted.zero?

    "only #{plotted} of them can be compared with each other"
  end

  # == The two units the "Suite growth" panel plots, worded once each
  #
  # `UI::SparklineComponent` holds no unit (see its `initialize`), so each series hands it the
  # wording of its own figures. These are those two, kept beside each other because that is the
  # whole reason the component stopped holding one: a chart of tests and a chart of seconds sit in
  # the same panel, and the day a third series lands it must be impossible for it to inherit either
  # of these by accident.
  #
  # One method per lambda, named for the seam it fills, and never a positional pair: the two size
  # formatters differ only in whether they append the noun, so a call site that destructured them in
  # the wrong order would render an axis reading `20,013 tests` and markers reading `20,013` — a
  # silent swap with nothing at the call site able to catch it.

  # The suite-size series' axis-and-table wording. Exactly what the component used to hard-code,
  # moved out to its caller: the bare delimited figure, for the places that have a heading beside
  # them to say what it counts.
  def trajectory_size_formatter
    ->(value) { number_with_delimiter(value.to_i) }
  end

  # The suite-size series' marker wording. A `<title>` is read on its own, with no heading beside it,
  # so this is the one place the noun has to appear.
  def trajectory_size_point_formatter
    ->(value) { "#{number_with_delimiter(value.to_i)} #{"test".pluralize(value.to_i)}" }
  end

  # The runtime series. One lambda and not two: `1m 14s` names its own unit, so the marker needs no
  # second spelling and must not get one.
  #
  # Routed through `TestRun#duration_label`, which is the single formatting seam for this column and
  # says so — "the same float cannot render two ways on one page". It is an instance method because
  # the thing it words is a column, and the chart holds the floats rather than the rows, so the
  # value is wrapped in an unsaved run to ask it. That is deliberately the awkward half: the
  # alternative is calling `humanized_seconds`, which is private and STAYS private (see the comment
  # on `TestRun#shard_distribution_labels`, which states the rule), and a spelling of seconds that
  # bypassed the seam, on a page that already words this column through it, is precisely the drift
  # `duration_label`'s own comment exists to prevent.
  #
  # Two things about that `TestRun.new` that are not visible from here:
  #
  # - It is NEVER saved. It is a box for a float, built so an instance method can be asked about it,
  #   and it has no id, no repository and no shards.
  # - It sits on a per-cell render path — roughly THREE times per plotted point, so a 30-run cohort
  #   builds ~90 throwaway runs per render. Measured, rendering the component over 30 points with a
  #   counting lambda: 92. The three are the marker `<title>`, the text-alternative row, and
  #   `UI::SparklineComponent#ambiguous_wordings`' pass over the series — which is what decides
  #   whether a row's wording collides with a different plotted value, and so runs on every render
  #   whether or not anything is disclosed. Exactly: `2n + distinct values + 2`, the trailing two
  #   being the axis bounds; a cohort whose runs all measured the same duration costs 63, not 92.
  #   Before the ambiguity pass existed this read twice per point and ~60, and it was 62 measured
  #   the same way — the third traversal is what SPGD-232 bought the text alternative's equivalence
  #   with, and it is the honest price of it. These figures are not on trust: the formula and both
  #   counts are pinned by "how many times a render calls the caller's formatter" in
  #   `spec/components/ui/sparkline_component_spec.rb`, so a fourth traversal fails a spec here
  #   rather than quietly making this paragraph wrong — which is how it went wrong the first time.
  #
  #   That is cheap today and the panel's query-count guard proves it costs no round trips: `.new`
  #   builds an `AttributeSet` and fires no callbacks. It stops being cheap the day `TestRun` gains
  #   an `after_initialize` that touches an association, and nothing in `TestRun` warns of this
  #   caller — so if that day comes, the fix is to move the wording to a value object rather than to
  #   keep paying for a row here.
  def trajectory_runtime_formatter
    ->(value) { TestRun.new(duration_seconds: value).duration_label }
  end

  # Rows the anchor run wrote that the ranking could not attribute to any test, counted and stated.
  # A row with no durable identity is precisely a row this panel cannot say WHICH test it belongs
  # to, so it cannot be summed into one and cannot be listed as one — and excluding it silently
  # would make the list a claim about the run made from part of it, with nothing saying which part.
  #
  # Counted in ROWS, deliberately, and worded that way, for `#unstable_tests_unnamed_clause`'s
  # reason at its own grain: reporting a number of "tests" for rows whose test is unknown would be
  # the identity claim the exclusion exists to decline.
  #
  # This clause and the `:unresolved` state above are the same fact at two sizes — some of the
  # anchor's rows unmatched, or all of them — which is why the wording of both names the matching
  # rather than the row.
  def slowest_tests_unresolved_clause(slowest)
    return nil unless slowest.excluded_unresolved_rows?

    count = slowest.unresolved_count
    "#{number_with_delimiter(count)} #{"row".pluralize(count)} that run recorded " \
      "#{count == 1 ? "has" : "have"} not been matched to a durable test yet and " \
      "#{count == 1 ? "is" : "are"} not in this ranking; that matching runs just after a run " \
      "lands rather than during it."
  end

  # ⭐ The cap, disclosed only where it bit — and disclosed as TWO facts rather than one, because
  # this panel narrows on one ordering and then ranks on another.
  #
  # The sibling clause one panel up (`#unstable_tests_truncation_clause`) has only the first half to
  # state: which end of the candidate list survived. Here the cap is applied on each test's duration
  # in the ANCHOR RUN and the surviving list is then ordered on its WINDOW TOTAL, so the two
  # orderings are different and a test can be excluded by one while it would have led the other — a
  # test that is cheap today and has a long expensive history is exactly that shape. That is
  # inherent to narrowing before aggregating, which is what makes the whole read affordable
  # (`SlowestTests` carries the arithmetic), and it is a fact about the list a reader cannot recover
  # from any row of it.
  #
  # ⚠️ It counts DURABLE TESTS THE ANCHOR RESOLVED, and says so, rather than reaching for "tests
  # that ran". `#candidate_count` comes off `.slowest_identity_candidates_in`, which is
  # `where.not(spec_identity_id: nil).group(:spec_identity_id)` — it cannot see the unresolved rows
  # AT ALL, and those are exactly what `#slowest_tests_unresolved_clause` declines to call tests one
  # clause earlier in the same paragraph. Where an anchor is both truncated and partly unresolved
  # the two clauses render side by side, so a figure that quietly folded the unmatched rows back in
  # would contradict its own neighbour by the width of them. `SlowestTests#recorded_count` draws
  # that line in as many words, and `#unstable_tests_truncation_clause` keeps it the same way by
  # naming its grouping key and its predicate instead of the word "tests".
  def slowest_tests_truncation_clause(slowest)
    return nil unless slowest.truncated?

    unexamined = slowest.unexamined_count

    "#{number_with_delimiter(slowest.candidate_count)} durable tests that run resolved — more " \
      "than this panel ranks at once — so the #{number_with_delimiter(slowest.rows.size)} " \
      "slowest OF THOSE were the ones whose window history was summed, and the other " \
      "#{number_with_delimiter(unexamined)} #{unexamined == 1 ? "is" : "are"} not represented " \
      "above. The cap is applied on that run's durations and the list is then ordered on the " \
      "window total, so a test that is cheap today and was expensive across the window falls " \
      "through it."
  end
end
