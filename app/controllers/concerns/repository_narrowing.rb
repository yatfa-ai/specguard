# frozen_string_literal: true

# THE THREE NARROWING ASKS a surface listing repositories reads — `?q=`, `?role=owned|shared` and
# `?sort=stale` — together with the ONE APPLICATION of each: the predicates they chain onto the
# relation, and the ordering `stale` means.
#
# The three `Requested*Param` guards are included here rather than at each call site, so a surface
# that reads these asks gets the guards and their application from the same place and cannot end up
# with one without the other.
#
# ONE MODULE, TWO BASES, on `ShardCountPreloading`'s and `DeliveryHealthLookups`' stated precedent:
# this is included into an `ActionController::Base` (the repositories card grid) and an
# `ActionController::API` (`GET /api/v1/repositories`). Nothing below touches view helpers or
# anything an API controller lacks, so the differing bases were never an obstacle to sharing —
# which is why this is a module rather than the two verbatim copies it replaces.
#
# ## Why the APPLICATION is shared and not just the reads
#
# The sibling modules share a READ; this one has to share a RULE, and that is the stronger reason
# rather than a weaker one. `is_a?(String)` is a shape clamp — a guard against a URL — but
# `[run.nil? ? 0 : 1, created_at, github_full_name]` is a PRODUCT DECISION about what "stale"
# means, and `where.not(user_id:)` is a product decision about what "shared" means. Two copies of a
# shape clamp drift into two error behaviors; two copies of a product decision drift into a grid and
# an agent-facing list that answer the same account in different orders, each one's comment still
# claiming they agree. That is `DeliveryHealthLookups`' own stated failure ("so a listing and the
# page it links to can never name different runs") one level up: from WHICH RUN to WHICH ORDER.
#
# ## Parameterized on the data, and not on an ivar
#
# `narrow_repositories` takes the scope and the viewer, and `stale_first` takes the loaded set and
# the runs map, for exactly the reason `DeliveryHealthLookups` records for its own id-set argument:
# `RepositoriesController` holds its list in an ivar and its viewer in `current_user`, while
# `Api::V1::UserRepositoriesController#index` holds its list in a LOCAL and its viewer in
# `current_api_user`, so an argument is the only spelling both callers can reach. Neither method
# memoizes: what is worth caching, and under what key, is the caller's question rather than this
# module's.
module RepositoryNarrowing
  extend ActiveSupport::Concern

  # The three guards, one per parameter, each with its own rule about which shapes it tolerates —
  # the split every `Requested*Param` sibling argues for in full. Unknown, non-String, empty and
  # out-of-vocabulary values all settle to `nil`, the no-ask, and never a 400; sharing the guards
  # is what makes a shape one surface clamps to no-ask IMPOSSIBLE to answer differently on the
  # other.
  include RequestedSearchParam
  include RequestedRoleParam
  include RequestedSortParam

  private

  # `?q=` THEN `?role=`, both as predicates chained ON THE RELATION HANDED IN, and the chaining is
  # the security claim rather than a convenience: the WHERE is applied by the database to rows the
  # scope already admits, so a repository the viewer cannot open never ENTERS the relation — not
  # "enters and is filtered out after loading", and not "answers a probe by name". `accessible_by`
  # hands back a relation precisely so callers can chain their own concerns onto it.
  #
  # `?q=` is `ILIKE '%…%'` — case-insensitive substring, per the parameter's contract — with the
  # WILDCARD CHARACTERS ESCAPED, and the escape is not pedantry: `_` is a legal and ordinary part
  # of a repository name (`org/my_repo`), so an unescaped `_` would quietly widen "my_repo" to
  # match `my-repo` and `myxrepo`, answering a substring ask with a pattern match.
  # `sanitize_sql_like` backslash-escapes `%`, `_` and `\`, which is the escape character Postgres
  # `LIKE` already reads by default — no `ESCAPE` clause to keep in step with the helper.
  #
  # `?role=owned` is `user_id = viewer.id`; `?role=shared` is its COMPLEMENT WITHIN the accessible
  # set — `where.not(user_id: …)` chained on the same relation, not a second reading of the
  # membership table, so owned-but-also-shared is impossible by construction (the same no-overlap
  # invariant `accessible_by` leans on) and the two asks partition exactly the set the
  # unparameterised surface serves.
  #
  # NEITHER ADDS A QUERY: they are predicates on the ONE relation the caller was already going to
  # load, so a narrowed set narrows every id-keyed lookup downstream for free.
  def narrow_repositories(scope, viewer)
    if requested_search
      scope = scope.where("github_full_name ILIKE :pattern",
                          pattern: "%#{ActiveRecord::Base.sanitize_sql_like(requested_search)}%")
    end

    case requested_role
    when "owned" then scope.where(user_id: viewer.id)
    when "shared" then scope.where.not(user_id: viewer.id)
    else scope
    end
  end

  # THE `?sort=stale` ORDERING, and the ONE definition of what "stale" means — never-ingested
  # first, then least-recently-ingested first, newest last.
  #
  # APPLIED OVER THE LOADED SET, NOT IN SQL, and the ticket for it names that the caller's query
  # count does not move. It does not: every `created_at` this reads is on a run the caller ALREADY
  # resolved for the whole list in one `DISTINCT ON` — `DeliveryHealthLookups#latest_test_runs_for`,
  # whose map is passed in — so a SQL spelling of the same ordering would re-derive per-repository
  # recency in a join only to throw the join away after the sort. Sorting the materialized Array
  # costs no query, on either surface.
  #
  # THE `nil` LIMB IS FIRST RATHER THAN SORTED AS ZERO, because "never ingested" is not "ingested
  # at the epoch": the card renders it as its own state ("No runs yet"), and the stalest thing on
  # the list is the repository CI has never reached at all. `github_full_name` breaks ties within a
  # limb so the sequence is DETERMINISTIC — a `?sort=stale` URL is shareable, two readers pasting
  # the same link must see the same cards in the same order, and a client diffing one response
  # against another must not see a reshuffle — which Ruby's `sort_by` does not promise on its own.
  #
  # `Time.zone.at(0)` is a SENTINEL THAT IS NEVER ACTUALLY COMPARED: a nil run has already sorted
  # into limb `0`, and limb `0` entries are only ever compared against each other, where this term
  # is equal on both sides and the `github_full_name` tie-break decides. It is here to keep the
  # tuple's second element a Time on every branch — comparing a Time against `nil` would raise —
  # so epoch-versus-nil carries no meaning to preserve.
  def stale_first(repositories, latest_runs)
    repositories.sort_by do |repository|
      run = latest_runs[repository.id]
      [run.nil? ? 0 : 1, run&.created_at || Time.zone.at(0), repository.github_full_name]
    end
  end
end
