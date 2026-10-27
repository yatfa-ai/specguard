# frozen_string_literal: true

# The /account page's own composition helpers. Today that is one job: the Close-account panel
# (SPGD-853) quantifies its disclosure (SPGD-1934) from the credential rows the two key tables
# above the panel already enumerated, so a person closing an account that still carries live
# automation is told exactly what stops — how many `sgu_` tokens, how many `sga_` agent keys,
# and how many repositories those agent keys' stored sets span.
#
# Every number here is read off the relations `AccountsController#show` already loaded for the
# tables. The live/revoked side of each kind is read off `ApiKeyPartition.for(rows).live_rows` —
# the seam that owns that split (`spec/models/api_key_partition_spec.rb` holds the repo-wide
# property that it is spelled there and nowhere else), whose constructor takes the LOADED rows
# and answers from them, so the panel adds no query of its own. Nothing here re-derives an
# enforcement fact — the split mirrors what `UserApiKey.authenticate` and
# `AgentApiKey.authenticate` resolve through their `User.active` merges, read the only way a
# browser render can read it.
module AccountsHelper
  # The `sgu_` tokens that would die with the closure, read off the loaded table relation through
  # the partition seam so the panel and the confirm share one count and no extra query is paid
  # for it.
  def closure_live_user_keys(user_api_keys)
    ApiKeyPartition.for(user_api_keys).live_rows
  end

  # The same split for the agent keys: a revoked `sga_` row already authenticates nothing, so
  # it is not counted as something the closure cuts — the count names the live cut only.
  def closure_live_agent_keys(agent_api_keys)
    ApiKeyPartition.for(agent_api_keys).live_rows
  end

  # THE BLAST RADIUS across a person's live agent keys, counted the way
  # `RepositoriesHelper#agent_key_coverage_sentence` counts one key: off the STORED sets, not
  # off a name list. The union is distinct, so two keys sharing a repository count that
  # repository once — the number is how many repositories stop receiving authenticated calls
  # from this person's agent keys, not how many grants named one.
  def closure_agent_repository_count(live_agent_keys)
    live_agent_keys.flat_map(&:repository_ids).uniq.size
  end

  # THE `sgu_` HALF of the death sentence. A person holding live tokens is told how many;
  # a person holding none keeps the page's standing generic sentence, which stays true for
  # them without inventing a zero to count.
  def closure_user_key_phrase(live_user_keys, code: false)
    count = live_user_keys.size
    name = code ? tag.code("sgu_", class: "font-mono text-xs") : "sgu_"
    phrase = if count.zero?
               "every #{name} token"
             else
               "your #{count} live #{name} #{'token'.pluralize(count)}"
             end
    # Every interpolation above is an Integer, a literal, or `tag.code`'s own html_safe output,
    # so the composed phrase is safe to hand to the view unescaped.
    phrase.html_safe
  end

  # THE `sga_` HALF, as a fragment: the live count and the repositories the stored sets span.
  # The verb is composed beside it, since the count decides "stops" against "stop" and both
  # sentences below end this fragment with it.
  def closure_agent_key_clause(live_agent_keys)
    count = live_agent_keys.size
    verb = count == 1 ? "stops" : "stop"
    "#{pluralize(count, 'live agent key')}, " \
      "covering #{pluralize(closure_agent_repository_count(live_agent_keys), 'repository')}, " \
      "#{verb} working immediately"
  end

  # The panel bullet's mutable tail, HTML-shaped: the `sgu_` enumeration, then the agent-key
  # sentence when any are live, then the standing warning clause. The zero-agent state appends
  # nothing, which is what keeps today's sentence for an owner with no live agent keys.
  def closure_key_death_html(live_user_keys, live_agent_keys)
    sentence = +"#{closure_user_key_phrase(live_user_keys, code: true)}"
    if live_agent_keys.any?
      sentence << " — and so does every agent key you minted: " \
                  "#{closure_agent_key_clause(live_agent_keys)}"
    end
    sentence << ", including keys still running on machines you no longer have."
    sentence.html_safe
  end

  # The confirm dialog's twin of the sentence above, plain text: the dialog is where a person
  # actually reads the consequence, and `agent_key_revoke_confirmation`'s paired-with-its-notice
  # rule applies here too — panel and dialog must not say different things about the same cut.
  def closure_key_death_plain(live_user_keys, live_agent_keys)
    sentence = +"Every sgu_ API key you hold stops working immediately"
    if live_user_keys.any?
      count = live_user_keys.size
      sentence << " — #{count} live #{'token'.pluralize(count)}"
    end
    if live_agent_keys.any?
      sentence << (live_user_keys.any? ? " — and so does every agent key you minted: " :
                                          ", and so does every agent key you minted: ")
      sentence << closure_agent_key_clause(live_agent_keys)
    end
    sentence << ", including keys on machines you no longer have."
    sentence
  end

  # THE "WHAT REMAINS" TRUTHS (SPGD-1934) — the one sentence this page used to spend on every
  # key kind at once ("the keys you minted remain") invited the wrong reading for agent keys,
  # whose rows stay but whose tokens die with the owner. The two truths: repository CI keys
  # keep authenticating untouched, and the personal/agent rows remain as rows with dead
  # tokens. An owner holding neither kind keeps today's sentence, which is the whole truth
  # for them.
  def closure_keys_remain_html(holds_keys)
    return "Your repositories, test runs, spec intents, the keys you minted and the " \
           "memberships you granted all remain, with your name still on them." unless holds_keys

    "Your repositories, test runs, spec intents and the memberships you granted all " \
      "remain, with your name still on them. Repository CI keys " \
      "(#{tag.code('sgk_', class: 'font-mono text-xs')}) keep authenticating — closure does " \
      "not touch them — while your personal and agent keys remain as rows carrying your " \
      "name, their tokens dead.".html_safe
  end

  # The confirm's twin of the remain-truths, plain text and paired with the panel the way the
  # death sentences above are.
  def closure_keys_remain_plain(holds_keys)
    return "Nothing is deleted — your repositories, runs, intents, keys and memberships " \
           "remain, with your name on them." unless holds_keys

    "Nothing is deleted — your repositories, runs, intents and memberships remain, with " \
      "your name on them. Repository CI keys keep working; your personal and agent keys " \
      "remain as rows with dead tokens."
  end

  # THE OWNED-REPOSITORY DISCLOSURE (SPGD-1947). Closure leaves a person's repositories exactly
  # as they are — which is the problem for the ones the person alone could run. The owner holds
  # no membership row and every permission implicitly, so once they cannot sign in a repository
  # is administrable only by members whose stored `permissions` include `keys.manage` or
  # `members.manage`; renaming is `RepositoryPolicy`'s `OWNER_ONLY` and is lost for every one of
  # them. This classification is read off the owned set and the permission map
  # `AccountsController#show` loaded (one grouped read, none for a person owning nothing):
  #
  #   * unopenable — no membership at all, so nobody can open it;
  #   * unadministrable — members exist, but none can manage keys or members, so no `sgk_` key
  #     can be minted or revoked and the member list cannot change.
  #
  # A repository with a member holding either administering permission is fine and is counted
  # in the total only.
  CLOSURE_ADMINISTERING_PERMISSIONS = [RepositoryMembership::KEYS_MANAGE,
                                       RepositoryMembership::MEMBERS_MANAGE].freeze
  # How many repositories each list names before it falls back to "and N more".
  CLOSURE_OWNED_NAME_CAP = 3
  ClosureOwnedRepositories = Data.define(:total, :unopenable, :unadministrable)

  # "Members" here means members who can still sign in: the permissions map is built from live
  # users only, so a closed member's row never reaches this method.
  def closure_owned_repositories(owned_repositories, permissions_by_repository)
    unopenable = []
    unadministrable = []
    owned_repositories.each do |repository|
      memberships = permissions_by_repository.fetch(repository.id, [])
      if memberships.empty?
        unopenable << repository
      elsif memberships.none? { |permissions| (permissions & CLOSURE_ADMINISTERING_PERMISSIONS).any? }
        unadministrable << repository
      end
    end
    ClosureOwnedRepositories.new(total: owned_repositories.size, unopenable: unopenable,
                                 unadministrable: unadministrable)
  end

  # The consequence clauses and the repositories each one names — shared by the panel and the
  # confirm so the two cannot say different things (the SPGD-1934 paired-copy rule). Empty for a
  # person whose every owned repository has a member who can administer it.
  def closure_owned_clauses(summary)
    clauses = []
    if summary.unopenable.any?
      count = summary.unopenable.size
      clauses << ["#{count} #{count == 1 ? 'has' : 'have'} no other members and will become " \
                  "unopenable", summary.unopenable]
    end
    if summary.unadministrable.any?
      count = summary.unadministrable.size
      clauses << ["#{count} #{count == 1 ? 'has' : 'have'} members but none who can manage keys " \
                  "or members, so #{count == 1 ? 'its' : 'their'} CI keys can no longer be minted " \
                  "or revoked from SpecGuard", summary.unadministrable]
    end
    clauses
  end

  # The names a clause carries, capped: the first few, then "and N more".
  def closure_owned_name_list(repositories)
    shown = repositories.first(CLOSURE_OWNED_NAME_CAP)
    hidden = repositories.size - shown.size
    [shown, hidden]
  end

  # The panel bullet's body, HTML-shaped: each named repository links to its Members page, the
  # place the remedy (add a member who can manage) is performed.
  def closure_owned_repositories_html(summary)
    parts = [h("You own #{pluralize(summary.total, 'repository')}.")]
    clauses = closure_owned_clauses(summary)
    unless clauses.empty?
      rendered = clauses.map do |text, repositories|
        shown, hidden = closure_owned_name_list(repositories)
        links = safe_join(shown.map { |repository|
          link_to(repository.github_full_name, repository_members_path(repository),
                  class: "font-mono text-xs")
        }, ", ")
        more = hidden.positive? ? " and #{hidden} more" : ""
        safe_join([text, " (", links, more, ")"])
      end
      parts << " Of those, " << safe_join(rendered, "; ") << "."
    end
    parts << " Renaming a repository is owner-only, so none of them can be renamed once the " \
             "account is closed."
    unless clauses.empty?
      parts << " Add a member holding " << tag.code("keys.manage", class: "font-mono text-xs") <<
        " or " << tag.code("members.manage", class: "font-mono text-xs") <<
        " first, or remove the repository."
    end
    safe_join(parts)
  end

  # The confirm dialog's twin of the sentence above, plain text.
  def closure_owned_repositories_plain(summary)
    sentence = +"You own #{pluralize(summary.total, 'repository')}."
    clauses = closure_owned_clauses(summary)
    unless clauses.empty?
      rendered = clauses.map do |text, repositories|
        shown, hidden = closure_owned_name_list(repositories)
        names = shown.map(&:github_full_name).join(", ")
        names << " and #{hidden} more" if hidden.positive?
        "#{text} (#{names})"
      end
      sentence << " Of those, #{rendered.join('; ')}."
    end
    sentence << " Renaming a repository is owner-only, so none of them can be renamed once the " \
                "account is closed."
    sentence << " Add a member holding keys.manage or members.manage first, or remove the " \
                "repository." unless clauses.empty?
    sentence
  end
end
