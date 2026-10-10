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
    # The magnitude ask rides the same carry, but ONLY when there is one: `nil` in the hash above
    # would put `?limit=` on every link of a default page — bytes that say an ask was made when
    # none was — and this page's no-ask render is pinned byte-for-byte. Added conditionally after
    # the hash rather than inside it, so an explicit `limit: nil` override ("Back to the 10
    # heaviest") still beats a carried widening through the ordinary `merge` below.
    asks[:limit] = @limit_request if @limit_request
    asks[:window] = @window_request if @window_request
    # `?layer=` rides the same conditional carry for the same reason: it narrows the "Slowest tests"
    # panel only, and opening a file or an area must not silently drop the layer the reader chose —
    # while a default page's links stay byte-identical because no `layer:` is emitted without an ask.
    asks[:layer] = @layer_request if @layer_request

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

  # The copy in the per-row Delete confirm dialog on the "Recent runs" panel (SPGD-812). Question
  # form, matching `remove_confirmation` above; the sentence must name what goes so the dialog is
  # an informed consent rather than a speed bump — this run, its shards, its per-example
  # observations, and that it cannot be undone.
  def delete_run_confirmation(test_run)
    "Delete run #{test_run.commit_sha.first(7)}? This removes the run, its shards and its " \
      "per-example observations from #{test_run.repository.github_full_name}, and it cannot be undone."
  end

  # The counterpart after the click, called from `RunsController#destroy` — the same
  # confirmation/notice pair `remove_confirmation` / `remove_notice` established.
  #
  # Past tense, and it names the run by commit sha and branch so a member who deleted the wrong
  # row of ten seven-character hashes can tell which one went. `branch` is nullable, so a run
  # that reported no branch reads "branch not reported" rather than a blank — the same fallback
  # the Branch column itself renders.
  def delete_run_notice(test_run)
    branch = test_run.branch.presence || "branch not reported"
    "Deleted run #{test_run.commit_sha.first(7)} (#{branch}) and its shards and observations."
  end

  # The two halves of the SAME disclosure for the agent-key revoke (SPGD-989): what the presser
  # is told BEFORE the cut, and what they are told after. They live together, and reach one
  # shared coverage sentence, for the reason `remove_confirmation` / `remove_notice` above state
  # in full — a fix applied to only one of them is a contradiction read in sequence.
  #
  # Both name the key's FULL stored repository set, count first and names beside it, because
  # `revoke!` on a multi-repository key cuts the token everywhere: the dialog is the one-act
  # honesty the members-page revoke dialog established, and it is what lets the trigger stay
  # THIS repository's `keys.manage` rather than a wider grant (see
  # RepositoryAgentKeysController's header). The count is the STORED set's, never the list's: a
  # repository named at mint and deleted since leaves the array but not the count, so the
  # sentence says so explicitly instead of letting "covers 3" sit beside two names.
  #
  # `repository_names` is handed in by both callers, already resolved — the page from the map
  # `RepositoriesController#show` preloaded (one SELECT for the whole table, never one per row),
  # the destroy action from its own single read — and sorted, so the copy is stable across
  # renders and matches between the two halves.
  # The names behind one key's stored set, read off the map `RepositoriesController#show`
  # preloaded for the whole table — never a query per row, and the same map the destroy action
  # resolves for its own notice. Sorted, so the confirm copy is stable across renders and the
  # two halves of the disclosure cannot disagree about order.
  def agent_key_repository_names(agent_api_key)
    repository_map = @agent_key_repositories || {}
    agent_api_key.repository_ids.filter_map { |id| repository_map[id]&.github_full_name }.sort
  end

  def agent_key_revoke_confirmation(agent_api_key, repository_names)
    "Revoke #{agent_api_key.name}? It covers #{agent_key_coverage_sentence(agent_api_key, repository_names)}. " \
      "Revoking it here cuts the token on every repository in that set — anything still using it stops working immediately."
  end

  def agent_key_revoke_notice(agent_api_key, repository_names)
    "Revoked #{agent_api_key.name}. It covered #{agent_key_coverage_sentence(agent_api_key, repository_names)} — " \
      "its token no longer authenticates anywhere."
  end

  # The one place the coverage phrase is decided for both sentences above — the same
  # one-place rule `MembershipsHelper#minted_keys_agreement` states for its own pair. Count
  # first (the blast radius, read off the STORED array), names second, deletions disclosed in
  # the middle where the eye already is.
  #
  # Public in this module the way every other method here is: the file carries no private
  # section, and an inline shared fragment is not worth becoming the first one.
  def agent_key_coverage_sentence(agent_api_key, repository_names)
    stored_count = agent_api_key.repository_ids.size
    deleted_count = stored_count - repository_names.size
    names = repository_names.any? ? ": #{repository_names.join(', ')}" : ""
    deleted = deleted_count.positive? ? " (#{pluralize(deleted_count, 'repository')} since deleted)" : ""

    "#{pluralize(stored_count, 'repository')}#{names}#{deleted}"
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
    # With `?layer=` asked every count is the LAYER's, so the population is named as such rather than
    # as "this run's" — "the 40 request-layer examples", not a claim the run recorded only 40.
    examples = if slowest_examples.layer?
                 "#{number_with_delimiter(recorded)} #{slowest_examples.layer}-layer " \
                   "#{"example".pluralize(recorded)} this run recorded"
               else
                 "#{number_with_delimiter(recorded)} #{"example".pluralize(recorded)} this run recorded"
               end

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
    # A rollup ranked by a declared layer states the LAYER's figures for each row, while the open
    # area (`SpecDirectoryFiles`) stays all-layer: the two no longer state "the same fraction", so
    # the cross-reference is withheld rather than made false.
    return false if rollup.layer?

    rollup.rows.any? { |row| row.path == path }
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

  # The Layer cell of the three per-example tables ("Slowest tests", "Examples in this spec file",
  # "Examples under this description") — ONE seam, so the three cannot word it differently.
  #
  # THE STORED COLUMN, VERBATIM, AND NOTHING ELSE. `spec_observations.intent_layer` is what the
  # example's own `@intent` declared (`Ingest::ObservationRecorder#intent_attributes` stores it
  # unconditionally and `Ingest::Payload` has already checked it against the four-token enum), so
  # the token is printed as stored. A nil — or a blank one — is "no annotation declared a layer"
  # and reads the muted word `undeclared`, the word `SpecDirectoryDurations.layer_counts_label`
  # prints for the same fact at the area grain.
  #
  # NEVER INFERRED. Not from the spec path (a `layer: "request"` example under `spec/models/` is a
  # request test, and an unannotated one under `spec/models/` is undeclared, not "unit") and not
  # from `DerivedIntent`, which carries no layer by design. A guess in this cell would be read as
  # a declaration, which is the one thing the column exists to tell apart.
  def declared_layer_label(observation)
    layer = observation.intent_layer
    return layer if layer.present?

    content_tag(:span, "undeclared", class: "text-app-muted")
  end

  # The "declared layer(s)" line of a "Tests whose outcome changed" row — the cross-run
  # counterpart of `declared_layer_label`, taking the row's DISTINCT declared layers
  # (`UnstableTests::Row#declared_layers`) rather than one observation. Same vocabulary: tokens
  # printed as stored, and an empty set reads the muted word `undeclared`. NEVER inferred from the
  # spec path or `DerivedIntent`. The span carries `data-declared-layers` so it is never mistaken
  # for the files/descriptions disclosures beside it.
  def declared_layers_label(layers)
    layers = Array(layers)
    if layers.empty?
      content_tag(:span, safe_join(["declared layer: ", content_tag(:span, "undeclared", class: "text-app-muted")]),
                  class: "block text-xs text-app-muted", data: { declared_layers: "" })
    else
      content_tag(:span, "declared #{'layer'.pluralize(layers.size)}: #{layers.join(', ')}",
                  class: "block text-xs text-app-muted", data: { declared_layers: "" })
    end
  end

  # The title of the index's FILTERED-empty state — the page a `?q=` or `?role=` ask narrowed to
  # nothing on an account that holds repositories (`RepositoriesController#narrowing_matched_nothing?`
  # is the gate; this is its words).
  #
  # IT NAMES THE READER'S OWN ASK, in the reader's own spelling, and that is the whole
  # requirement: an empty result that says only "No repositories" is indistinguishable from an
  # account with none, and the registration invitation the truly-empty page carries would be a
  # falsehood here. The search text is echoed VERBATIM from `requested_search` — not downcased,
  # not trimmed again — for the reason `RequestedSearchParam` records: the match is
  # case-insensitive in SQL, so altering the spelling could not change which rows matched, only
  # what the page claims the reader searched for. The role limb folds into the same sentence when
  # both asks are live, so the title stays one claim a reader can check against the controls
  # directly above it.
  #
  # SORT HAS NO LIMB HERE, deliberately: `?sort=` cannot empty the set (it reorders), so a page
  # this state renders was emptied by `?q=` or `?role=` alone, and naming an ordering would be
  # narrating a control that did nothing.
  def no_repositories_match_title
    if requested_search
      case requested_role
      when "owned" then %(No repositories you registered match “#{requested_search}”)
      when "shared" then %(No shared repositories match “#{requested_search}”)
      else %(No repositories match “#{requested_search}”)
      end
    elsif requested_role == "owned"
      "No repositories you have registered"
    else
      "No repositories have been shared with you"
    end
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

  # ⭐ What share of the suite the near-duplicate panel's groups cover, off the STORED census Hash
  # (string keys, exactly as `NearDuplicateCensus.stored_block_for` returns it — never the live
  # `NearDuplicateClusters`). Two grains, kept apart because the census keeps them apart:
  #
  #   * TESTS  — `clustered_identity_count` of `identity_count` (distinct compared test texts);
  #   * EXAMPLES — `clustered_example_count` of `recorded_count` (every run row the weighed run
  #     recorded). `recorded_count` INCLUDES the rows that resolved to no comparable text, so the
  #     sentence says its denominator is the run's recorded total rather than the compared subset.
  #
  # nil unless all four figures are Integers and both denominators are positive: a census stored
  # before a key existed renders no sentence, never "0 of 0" or an invented zero.
  def near_duplicate_coverage_sentence(census)
    return nil unless census.is_a?(Hash)

    keys = %w[clustered_identity_count identity_count clustered_example_count recorded_count]
    values = keys.map { |key| census[key] }
    return nil unless values.all?(Integer)

    clustered_tests, tests, clustered_examples, recorded = values
    return nil unless tests.positive? && recorded.positive?

    "These groups cover #{number_with_delimiter(clustered_tests)} of #{number_with_delimiter(tests)} " \
      "compared #{"test".pluralize(tests)}, and #{number_with_delimiter(clustered_examples)} of the " \
      "#{number_with_delimiter(recorded)} #{"example".pluralize(recorded)} the weighed run recorded " \
      "(a total that includes examples that could not be compared)."
  end

  # The examples the census could not compare, stated where the panel would otherwise read as if
  # every recorded example had been looked at. `unresolved_count` counts rows that reached no
  # resolvable text; it is the sibling of `SlowestTestsHelper#slowest_tests_unresolved_clause` and names the same
  # cause (matching runs just after a run lands). nil when the key is absent, not an Integer, or 0 —
  # a "0 examples were not compared" clause would be arithmetic.
  def near_duplicate_unresolved_clause(census)
    return nil unless census.is_a?(Hash)

    count = census["unresolved_count"]
    return nil unless count.is_a?(Integer) && count.positive?

    "#{number_with_delimiter(count)} #{"example".pluralize(count)} in the weighed run reached no " \
      "resolvable text and #{count == 1 ? "was" : "were"} not compared; that matching runs just " \
      "after a run lands rather than during it."
  end

  # --- the console (`repositories/show`) -----------------------------------------------------

  # Every ask that opens a drill-in, as the set a "close" link has to clear. The global asks
  # (branch, window, layer, commit_sha) are left alone: closing a drawer must not change the page.
  DRILL_IN_ASKS = %i[spec_file spec_directory repeated_description unstable_test unstable_test_from].freeze

  def drill_in_open?
    [@spec_file_examples, @spec_directory_files, @spec_directory_file_growth, @unannotated_examples,
     @repeated_description_examples, @unstable_test_runs].any?
  end

  def close_drill_in_path(repository)
    drill_down_path(repository, anchor: nil, **DRILL_IN_ASKS.index_with { nil })
  end

  # An outcome strip cell per run of the window, oldest first. `outcomes` is {run_id => outcome}.
  # Absent = the test did not appear in that run (a gap, not a pass).
  def outcome_strip(runs, outcomes)
    cells = runs.map do |run|
      outcome = outcomes[run.id]
      state = if !outcomes.key?(run.id) then "absent"
              elsif outcome.nil? then "unreported"
              else outcome
              end
      title = "#{run.commit_sha.first(7)} · #{state == 'absent' ? 'not run' : (state == 'unreported' ? 'outcome not reported' : state)}"
      content_tag(:i, "", data: { o: state }, title: title)
    end
    content_tag(:span, safe_join(cells), class: "rc-strip", role: "img",
                aria: { label: "Outcome in each of the last #{runs.size} runs, oldest first" })
  end

  # A comparison delta that can never wrap inside its cell. Tone is a reading, not a verdict:
  # `good` when the thing a reader wants smaller got smaller, `bad` when it grew, `info` for size.
  def delta_tag(text, tone: :flat, label: nil)
    content_tag(:span, text, class: "delta delta-#{tone}", aria: { label: label })
  end

  def delta_tone_for(change, bigger_is_worse:)
    return :flat if change.nil? || change.zero?

    (change.positive? == bigger_is_worse) ? :bad : :good
  end

  # The global filter bar's branch menu: the branches with the most history, the one being read
  # pulled to the front, and an honest line about what is not listed.
  BRANCH_MENU_LIMIT = 12

  def console_branch_items(repository, histories, current_branch)
    shown = histories.first(BRANCH_MENU_LIMIT)
    current = histories.find { |history| history.name == current_branch }
    shown = [current, *shown.first(BRANCH_MENU_LIMIT - 1)] if current && shown.none? { |history| history.name == current_branch }
    shown.map do |history|
      { name: history.name,
        runs: history.capped? ? "#{history.run_count}+ runs" : pluralize(history.run_count, "run"),
        href: drill_down_path(repository, branch: history.name, commit_sha: nil, anchor: nil,
                              **DRILL_IN_ASKS.index_with { nil }),
        current: history.name == current_branch }
    end
  end

  def console_window_items(repository)
    @window_choices.map do |size|
      { label: "#{size} runs", current: size == @window_size,
        href: drill_down_path(repository, window: (size == Repository::TRAJECTORY_LIMIT ? nil : size),
                              anchor: nil, **DRILL_IN_ASKS.index_with { nil }) }
    end
  end

  def console_layer_items(repository)
    [["All layers", nil], *SpecObservation::DECLARED_LAYER_KEYS.map { |layer| [layer.to_s, layer.to_s] }].map do |label, value|
      { label: label, current: value == @layer_request,
        href: drill_down_path(repository, layer: value, anchor: nil) }
    end
  end

  # The figures the old Overview panel computed inline, computed once. Every rule is the panel's own
  # (a delta is withheld unless both runs were measured and assembled the same way); only the place
  # moved, so the verdict, the cost panel and the notes read one answer.
  RunFigures = Struct.new(:run, :previous, :total, :annotated, :readings, :measured, :comparable,
                          :size_delta, :runtime_comparable, :wall_delta, :machine_delta, :sharded,
                          :shards, keyword_init: true)

  def run_figures(run, previous)
    return nil if run.nil?

    like = previous && run.assembled_like?(previous)
    comparable = run.suite_size_measured? && previous&.suite_size_measured? && like
    runtime_comparable = like && run.duration_reported? && previous.duration_reported? &&
                         run.timed_shard_count == previous.timed_shard_count
    wall = run.duration_seconds - previous.duration_seconds if runtime_comparable
    sharded = run.multi_shard?
    machine = if sharded && wall && run.machine_seconds_reported? && previous.machine_seconds_reported?
                run.machine_seconds - previous.machine_seconds
              end
    RunFigures.new(run: run, previous: previous, total: run.total_specs_count.to_i,
                   annotated: run.annotated_specs_count.to_i, readings: run.intent_readings,
                   measured: run.suite_size_measured?, comparable: comparable,
                   size_delta: (run.total_specs_count.to_i - previous.total_specs_count.to_i if comparable),
                   runtime_comparable: runtime_comparable, wall_delta: wall, machine_delta: machine,
                   sharded: sharded, shards: run.shard_count)
  end

  # --- the detail drawer -----------------------------------------------------------------------
  # A table row that opens the drawer. `facts` are [label, value] pairs; `actions` are
  # [label, href, variant] links (a row's real destinations — the server drill-in, GitHub);
  # `body` is optional extra markup. Nothing is fetched: the detail is a <template> in the row.
  def drawer_row(seed, kind:, title:, facts: [], actions: [], body: nil, &cells)
    id = "row-#{kind.parameterize}-#{Digest::SHA1.hexdigest(seed.to_s).first(8)}"
    detail = tag.template(data: { drawer_body: "" }) do
      safe_join([
        (tag.dl(class: "rc-facts") do
          safe_join(facts.reject { |_, value| value.blank? }.flat_map { |label, value| [tag.dt(label), tag.dd(value)] })
        end if facts.any?),
        body,
        (tag.div(class: "rc-drawer-actions") do
          safe_join(actions.map do |label, href, variant|
            link_to(label, href, class: UI::ButtonComponent.classes(variant: variant || :secondary, size: :sm),
                    target: (href.to_s.start_with?("http") ? "_blank" : nil), rel: "noopener noreferrer")
          end)
        end if actions.any?)
      ].compact)
    end
    tag.tr(safe_join([capture(&cells), detail]), id: id, data: { drawer_title: title, drawer_kind: kind })
  end

  # The cell that is the row's keyboard handle: a real button, so Enter/Space open the drawer and
  # the row does not need an underlined link to be discoverable.
  def row_open(label, mono: false)
    tag.button(label, type: "button", class: "row-open#{' mono' if mono}")
  end

  def layers_stack(layer_counts, key: true)
    return nil if layer_counts.nil?

    total = layer_counts.values.sum
    return nil if total.zero?

    ranks = { unit: "1", integration: "2", request: "3", system: "4", undeclared: "x" }
    parts = layer_counts.select { |_, count| count.positive? }
    bar = tag.span(class: "rc-stack", role: "img",
                   aria: { label: parts.map { |layer, count| "#{layer} #{number_with_delimiter(count)}" }.join(", ") }) do
      safe_join(parts.map { |layer, count| tag.i("", data: { r: ranks[layer] }, style: "flex: #{count} 1 0") })
    end
    key_list = tag.ul(class: "rc-key") do
      safe_join(parts.map { |layer, count| tag.li(safe_join([layer.to_s, " ", tag.strong(number_with_delimiter(count))]), data: { r: ranks[layer] }) })
    end
    key ? safe_join([bar, key_list]) : bar
  end

  # The runs the pass/fail strips are drawn across, oldest first — the same window every other
  # trajectory panel reads, so a strip's cell N is the run the suite-growth chart's point N is.
  def trajectory_runs_for_strips = @suite_trajectory.runs

  # What the server-rendered drawer is about, named from whichever drill-in the URL opened. The
  # newest ask (the narrowest) names it; the others ride inside it.
  def drill_in_kind
    if @unstable_test_runs then "Test, run by run"
    elsif @repeated_description_examples then "Repeated description"
    elsif @unannotated_examples && !@spec_file_examples then "Unannotated tests"
    elsif @spec_file_examples then "Spec file"
    elsif @spec_directory_files || @spec_directory_file_growth then "Spec directory"
    end
  end

  def drill_in_title
    @unstable_test_runs&.name || @repeated_description_examples&.name || @spec_file_examples&.path ||
      @spec_directory_files&.path || @spec_directory_file_growth&.path
  end
end
