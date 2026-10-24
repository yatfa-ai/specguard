# frozen_string_literal: true

module RepositoriesHelper
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
    # `?runs=` rides the same conditional carry (SPGD-1911): following a link elsewhere must not
    # collapse a widened Recent runs panel, and a default page's links stay byte-identical.
    asks[:runs] = @runs_request if @runs_request
    # `?runs_branch=` rides the same conditional carry (SPGD-1922): the Recent runs panel's branch
    # narrowing survives a click elsewhere on the page, and a page asked for no narrowing carries
    # no `runs_branch` bytes at all. An EXPLICIT override (the Branch cells pass the row's own
    # branch) beats the carried ask through the ordinary merge below, which is what lets one row's
    # cell point at its own branch on a page already narrowed to another one.
    asks[:runs_branch] = @runs_branch_request if @runs_branch_request
    asks[:window] = @window_request if @window_request
    # `?layer=` rides the same conditional carry for the same reason (which panels it narrows is
    # listed in the `RequestedLayerParam` header): opening a file or an area must not silently drop
    # the layer the reader chose —
    # while a default page's links stay byte-identical because no `layer:` is emitted without an ask.
    asks[:layer] = @layer_request if @layer_request
    # `?near_duplicate_cluster=` rides the same conditional carry (SPGD-1888): it opens a drawer on
    # the census panel, and following a link elsewhere on the page must not silently close it.
    asks[:near_duplicate_cluster] = @near_duplicate_cluster_request if @near_duplicate_cluster_request

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

  # The two halves of the SAME disclosure for the repository's own ingest-key (`sgk_`) revoke
  # (SPGD-1906): what the presser is told BEFORE the cut, and what they are told after — the
  # sibling of the member and agent-key pairs, and for the same reason they live together.
  #
  # Display copy only. The view hands in what the page already holds — `live_count` is
  # `@api_keys.size` and `stranded` is `@rotated_unused_api_keys.include?(api_key)`, both read off
  # the single partition `RepositoryDashboard` builds — so the confirm costs no query on render.
  # The last-used clause follows the table cell's own rule: a rotated-and-unused key's
  # `last_used_at` was stamped by a token that no longer exists, so it is never printed as an age.
  #
  # "Only live" is stated about the INGEST KEYS of this repository, never about ingest paths: an
  # `sga_` agent key holding `runs.ingest` can still ingest, so the sentence names what stops (CI
  # authenticating with THIS key) and not that nothing can.
  def api_key_revoke_confirmation(api_key, live_count:, stranded:)
    parts = ["Revoke #{api_key.name}? Its token stops working immediately."]
    if live_count == 1
      parts << "It is this repository's only live ingest key — CI authenticating with it stops " \
               "ingesting until a new key is minted. To rotate without a gap, use Regenerate, " \
               "which issues the replacement token for this key."
    end
    parts << api_key_last_used_clause(api_key, stranded: stranded)
    parts.compact.join(" ")
  end

  def api_key_revoke_notice(api_key, remaining_live:)
    notice = "Revoked #{api_key.name}. Its token no longer authenticates."
    return notice if remaining_live

    "#{notice} No live API key remains for this repository — mint a replacement with New API key " \
      "so CI can ingest again."
  end

  # nil for a rotated-and-unused key: the clause is dropped rather than rewritten, because the only
  # honest age for it is the table cell's "not used since rotation", which is not a last use.
  def api_key_last_used_clause(api_key, stranded:)
    return "It has not been used since it was rotated." if stranded

    api_key.last_used_at ? "Last used #{time_ago_in_words(api_key.last_used_at)} ago." : "It has never been used."
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

    "SpecGuard has no runs on #{asked}, so this page is read on #{trajectory.branch} — the " \
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

  # Whether the walk stopped rather than finished — the fact that turns every claim about this
  # list from one about the repository into one about a prefix of it.
  #
  # `>=` rather than `==`: a pinned branch is added to the walk's result, so a cut walk can hand
  # back more rows than its own bound. It cannot hand back FEWER than the bound and still be cut,
  # and a complete walk that lands exactly on the bound is the ambiguity "At least" already covers.
  def trajectory_walk_cut?(histories)
    histories.size >= Repository::BRANCH_HISTORY_LIMIT
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

  # --- the console (`repositories/show`) -----------------------------------------------------

  # Every ask that opens a drill-in, as the set a "close" link has to clear. The global asks
  # (branch, window, layer, commit_sha) are left alone: closing a drawer must not change the page.
  DRILL_IN_ASKS = %i[spec_file spec_directory repeated_description unstable_test unstable_test_from].freeze

  def drill_in_open?
    [@spec_file_examples, @spec_directory_files, @spec_directory_file_growth, @spec_directory_window_file_growth,
     @spec_directory_window_file_runtime_growth, @unannotated_examples,
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
  def delta_tag(text, tone: :flat, label: nil, id: nil)
    content_tag(:span, text, class: "delta delta-#{tone}", id: id, aria: { label: label })
  end

  def delta_tone_for(change, bigger_is_worse:)
    return :flat if change.nil? || change.zero?

    (change.positive? == bigger_is_worse) ? :bad : :good
  end

  # The global filter bar's branch menu: the branches with the most history, the one being read
  # pulled to the front, and an honest line about what is not listed.
  # Every branch the page loaded, one item each, in `Repository#branch_histories`' order — most
  # history first. NOT cut: the filter bar's menu is the page's only index of branches, and a branch
  # that is not named in it cannot be asked for. (The old Suite growth panel cut a row to eight and
  # backed it with a second, complete menu; with one filter bar there is only the complete one.)
  def console_branch_items(repository, histories, current_branch)
    histories.map do |history|
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
  # The DOM id `drawer_row` gives a row, derived from the row's kind and its seed — the ONE
  # derivation an in-page anchor may compose against (SPGD-1856's caption anchors reuse it; a
  # second scheme would mint a link to nowhere). `seed` is caller-shaped, so a caller that wants
  # an anchorable row composes the SAME seed at both ends.
  def drawer_row_id(kind, seed)
    "row-#{kind.parameterize}-#{Digest::SHA1.hexdigest(seed.to_s).first(8)}"
  end

  # A table row that opens the drawer. `facts` are [label, value] pairs; `actions` are
  # [label, href, variant] links (a row's real destinations — the server drill-in, GitHub);
  # `body` is optional extra markup. Nothing is fetched: the detail is a <template> in the row.
  def drawer_row(seed, kind:, title:, facts: [], actions: [], body: nil, row_data: {}, &cells)
    id = drawer_row_id(kind, seed)
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
    tag.tr(safe_join([capture(&cells), detail]), id: id, data: { drawer_title: title, drawer_kind: kind, **row_data })
  end

  # The cell that is the row's keyboard handle: a real button, so Enter/Space open the drawer and
  # the row does not need an underlined link to be discoverable.
  #
  # `current:` marks the row the reader is on (the run being read) with `aria-current`, matched on the
  # ROW and never on a value: two runs of one commit print the same seven characters.
  def row_open(label, mono: false, current: false)
    tag.button(label, type: "button", class: "row-open#{' mono' if mono}", aria: { current: current ? "true" : nil })
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
    # "Undeclared" is ALWAYS named, even at zero: it is the examples that declared no layer, and a
    # key that omitted it would let a reader take a fully-declared file and a file nobody counted
    # for the same thing. The bar draws only what has a count; the key states the whole mix.
    key_parts = layer_counts.select { |layer, count| count.positive? || layer == :undeclared }
    key_list = tag.ul(class: "rc-key") do
      safe_join(key_parts.map { |layer, count| tag.li(safe_join([layer.to_s, " ", tag.strong(number_with_delimiter(count))]), data: { r: ranks[layer] }) })
    end
    key ? safe_join([bar, key_list]) : bar
  end

  # The shared key of the "Declared layers by run" strip: all five declared layers in
  # `SpecObservation::DECLARED_LAYER_KEYS` order, "undeclared" included, so one legend serves every
  # bar (`layers_stack(..., key: false)` draws bars only). The swatch ranks are the bars' own.
  def declared_layers_key
    ranks = { unit: "1", integration: "2", request: "3", system: "4", undeclared: "x" }
    tag.ul(class: "rc-key", aria: { label: "Declared layers" }) do
      safe_join(SpecObservation::DECLARED_LAYER_KEYS.map { |layer| tag.li(layer.to_s, data: { r: ranks[layer] }) })
    end
  end

  # The strip's accessible text: names every layer, and states the oldest and newest drawn run's mix
  # as counts — operands only, no verdict. `runs` are the drawn runs, oldest first.
  def declared_layers_summary(runs, branch)
    describe = lambda do |run|
      run.layer_counts.map { |layer, count| "#{layer} #{number_with_delimiter(count)}" }.join(", ")
    end
    "Declared layers across #{runs.size} #{'run'.pluralize(runs.size)} on #{branch}. " \
      "The oldest declared #{describe.call(runs.first)}; the newest declared #{describe.call(runs.last)}. " \
      "Each bar is one run, oldest first, and shows that run's own split across unit, integration, " \
      "request, system and undeclared; a bar's length is its share of that run, not its size."
  end

  # The "Machine time by declared layer, by run" strip's data: `{layer => [[run, seconds], …]}` in
  # `SpecObservation::DECLARED_LAYER_KEYS` order, oldest run first, for every layer that has at least
  # one TIMED plotted run (`total_seconds` non-nil — a layer with no timed example is NOT a zero-second
  # layer, so it contributes no point). A run whose `layer_durations` is nil (no per-example rows)
  # contributes to no layer. `runs` are the plotted runs, oldest first, already primed.
  def declared_layer_time_series(runs)
    SpecObservation::DECLARED_LAYER_KEYS.index_with do |layer|
      runs.filter_map do |run|
        seconds = run.layer_durations&.dig(layer, :total_seconds)
        [run, seconds] unless seconds.nil?
      end
    end.reject { |_, points| points.empty? }
  end

  # The strip's accessible text: names every drawn layer and states its oldest and newest drawn figure,
  # as seconds — operands only, no verdict.
  def declared_layer_time_summary(series, branch)
    parts = series.map do |layer, points|
      "#{layer} #{number_with_precision(points.first.last, precision: 1)} s in the oldest drawn run and " \
        "#{number_with_precision(points.last.last, precision: 1)} s in the newest"
    end
    "Machine time by declared layer across the plotted runs on #{branch}: #{parts.join('; ')}. " \
      "Each chart is one layer, oldest run first, on its own vertical axis that does not start at zero. " \
      "Each figure is a sum of example durations — machine time, not wall clock."
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
    elsif @spec_directory_files || @spec_directory_file_growth || @spec_directory_window_file_growth ||
          @spec_directory_window_file_runtime_growth then "Spec directory"
    end
  end

  def drill_in_title
    @unstable_test_runs&.name || @repeated_description_examples&.name || @spec_file_examples&.path ||
      @spec_directory_files&.path || @spec_directory_file_growth&.path ||
      @spec_directory_window_file_growth&.path || @spec_directory_window_file_runtime_growth&.path
  end
end
