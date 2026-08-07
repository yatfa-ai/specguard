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
  # bounded walk with the PINNED branch outside `:branch_limit` (`app/models/repository.rb:255-259`),
  # which is the same fact `trajectory_walk_cut?` uses `>=` for. On a cut repository the branch being
  # drawn is routinely in this list *because the walk never reached it* — pin `main` on a repository
  # of `feature/*` and it arrives behind every one of them — so naming the size as the walked figure
  # is off by the pins, in the one branch of this method written to not overclaim. A bare count
  # claims nothing about provenance and is true however a row got here; the bound the reader
  # actually needs is carried by the clause after it, which is unconditionally true.
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
  # thing. Escaping is ERB's, which is why this returns a plain String and not `html_safe` markup.
  def trajectory_branch_fallback_notice(requested, trajectory)
    return nil if requested.blank? || trajectory.branch == requested

    asked = truncate(requested, length: 60)

    if trajectory.branch.blank?
      return "SpecGuard has no runs on #{asked}. The latest run named no branch, so there is " \
             "still no history to draw."
    end

    "SpecGuard has no runs on #{asked}, so this panel is drawn on #{trajectory.branch} — the " \
      "branch of the repository's latest run — instead."
  end

  private

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
      href: repository_path(repository, branch: history.name),
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
end
