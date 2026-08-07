# frozen_string_literal: true

module RepositoriesHelper
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
        "#{trajectory_withheld_reasons(trajectory)}. Those runs are not smaller suites, they are " \
        "less complete reports, and a line through them would be a picture of how much each run " \
        "had delivered rather than of the suite."
    end
  end

  # The withheld runs grouped by WHY, never totalled into one number. "3 withheld" hides an
  # in-flight build inside the same figure as a client that is reporting nothing, and only one of
  # those is a fault.
  def trajectory_withheld_reasons(trajectory)
    reasons = []

    unmeasured = trajectory.withheld_unmeasured.size
    if unmeasured.positive?
      reasons << "#{unmeasured} reported no tests at all"
    end

    mismatched = trajectory.withheld_composition.size
    if mismatched.positive?
      reasons << "#{mismatched} #{mismatched == 1 ? "was" : "were"} assembled from a different " \
                 "number of shard reports than the rest"
    end

    reasons.to_sentence
  end

  private

  # `0` gets its own wording rather than riding the count. "only 0 of them are comparable" is a
  # sentence about a number; "none of them can be plotted" is a sentence about this repository.
  def trajectory_comparable_phrase(trajectory)
    plotted = trajectory.plotted.size
    return "none of them can be plotted" if plotted.zero?

    "only #{plotted} of them can be compared with each other"
  end
end
