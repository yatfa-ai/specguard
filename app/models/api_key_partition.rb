# frozen_string_literal: true

# THE live / revoked / stranded PARTITION of a loaded set of `ApiKey` rows, answered once and read
# by every surface that needs a side of it.
#
# == Why this is one object
#
# `ApiKey` has always single-sourced the PREDICATES — `revoked?`, `revoked_and_still_presented?`,
# `rotated_and_unused?`, and the `live`/`revoked` scopes. What no one single-sourced was the
# PARTITION built from them, so every surface that needed a side of it re-derived the split:
#
# * `RepositoriesController#show` split its loaded rows into live / revoked / stranded /
#   presented-revoked for the keys table and the connection indicator,
# * `RepositoryOverview#serialized_credential_health` split them again for the agent-facing
#   credential-health block, in a second spelling,
# * and the repositories grid (`RepositoriesController#index`) excluded the revoked rows in SQL —
#   `ApiKey.live` — and derived the rotation state per card in a third.
#
# Three spellings of one rule is three chances to change two of them and have nothing in the suite
# see the third drift, and they were not hypothetical: the same rule was typed into the overview
# and the controller in lockstep twice in the partition's first six days (SPGD-804, SPGD-814), and
# the grid's SQL spelling is precisely the hazard `RepositoryOverview#serialized_credential_health`'s
# own comment names — "a WHERE clause here would be a second expression of `rotated_and_unused?`'s
# rule, free to drift from the one the two web surfaces read". The exclusion itself was not wrong
# (the `live` scope filters on `revoked_at IS NULL` only, and nothing here re-expresses a
# predicate's rule in SQL — see the constraints below); it was one more copy of the split. This
# class is the one copy. `spec/models/api_key_partition_spec.rb` holds the repo-wide property that
# the split is spelled here and nowhere else.
#
# == The contract
#
# The constructor takes a LOADED collection of rows — never a relation and never a repository. The
# callers' loads differ and are budget-pinned (`show` and the grid each hold ONE `api_keys` SELECT
# per page, guarded by an absolute page budget and by a per-table statement count respectively), so
# the load stays at the call site and this object answers only about the rows it was handed.
#
# It assumes nothing about WHICH rows those are: the live/revoked split is over the collection
# given. `show` and the API hand in ALL of one repository's rows — the presented-revoked half
# reads the retained rows a `WHERE revoked_at IS NULL` would have filtered out before they could
# be seen — while the grid hands in its live-only load, for which the live side is then the whole
# of it. Both are correct hands; neither is assumed.
#
# == The answers
#
# * {#live_rows} and {#revoked_rows} — the retirement split, by `revoked?` per row.
# * {#stranded_rows} — the live side ∧ `rotated_and_unused?`. READ OFF THE LIVE SIDE, and that
#   placement is the rule "revocation outranks rotation": a key rotated and THEN revoked is both,
#   the revocation is the newer and stronger fact, and it must surface as revoked — never as
#   stranded. Pinned by `spec/requests/api/v1/repository_credential_health_spec.rb` ("reports a
#   rotated-then-revoked key as revoked, not as stranded") and by the grid's own example.
# * {#presented_revoked_rows} — the revoked side ∧ `revoked_and_still_presented?`.
# * {#last_api_request_at} and {#last_live_api_request_at} — the two figures `show`'s connection
#   indicator branches on. They live here, beside the partition, because they are computed FROM it
#   and are two more lines of the same rule: the first is the newest use across the LIVE rows
#   (a revoked row's `last_used_at` is the history of a credential that no longer exists, and a
#   rotation retires a token without touching its use, so the figure outlives the credential that
#   produced it); the second is the same figure restricted to the rows whose `last_used_at` still
#   describes the token they carry now — blank exactly in the window between a rotation and the
#   replacement reaching CI.
# * {#stranded_rotation_time} — the chain-equivalent verdict the repositories grid renders, with
#   the date its sentence is held to. See that method; the shape is show's branch chain, not the
#   bare row predicate, and the difference is load-bearing.
class ApiKeyPartition
  # One repository's rows, already loaded — the shape `show` and
  # `RepositoryOverview#serialized_credential_health` hold. The rows are loaded HERE, at the call
  # site, so the one-SELECT discipline those pages are pinned to stays visible where the query is
  # issued rather than hiding inside a model's lazy read.
  #
  # `to_a` is honest on both sides of the hand-off: an Array is returned as itself, and a caller
  # that hands in a relation still gets exactly one load rather than one per question.
  def self.for(rows)
    new(rows: rows.to_a)
  end

  # One page's rows spanning N repositories, grouped in Ruby — the grid's shape. `show` holds one
  # repository's rows and the API one collection; the grid loads once for the whole page and then
  # asks per-card questions of each repository's slice, so this is that slice taken once: every
  # repository that has at least one handed-in row gets its own partition, and a repository with
  # none gets no entry at all (the count side reads `0` through its own `.to_i` default, the
  # rotation side reads `nil` — both exactly what "no keys" must render as).
  #
  # The same two-constructor split `RejectedIngests` draws for this same grid: a constructor per
  # caller shape, so no caller re-derives at its own site what the object exists to answer.
  def self.grouped_by_repository(rows)
    rows.to_a.group_by(&:repository_id)
        .transform_values { |repository_rows| new(rows: repository_rows) }
  end

  def initialize(rows:)
    @rows = rows.to_a
    @live_rows = @rows.reject(&:revoked?)
    @revoked_rows = @rows.select(&:revoked?)
    @stranded_rows = @live_rows.select(&:rotated_and_unused?)
    @presented_revoked_rows = @revoked_rows.select(&:revoked_and_still_presented?)
    @last_api_request_at = @live_rows.filter_map(&:last_used_at).max
    @last_live_api_request_at = (@live_rows - @stranded_rows).filter_map(&:last_used_at).max
  end

  attr_reader :live_rows, :revoked_rows, :stranded_rows, :presented_revoked_rows,
              :last_api_request_at, :last_live_api_request_at

  # The repositories grid's rotation trigger: the date its stranded sentence is dated from, or
  # `nil` for every repository that does not read the way show's rotated branch reads.
  #
  # THE TRIGGER IS SHOW'S CHAIN, NOT THE ROW PREDICATE. The decision card that settled the grid's
  # original extraction settled this fork, and this carries it: on `show` the rotated-but-unused
  # state is branch 4 of an exclusive chain, reached only when nothing is refusing AND
  # {#last_api_request_at} is present AND {#last_live_api_request_at} is blank — some live key has
  # authenticated, and every token that ever did has since been rotated away, so CI is presenting a
  # credential that no longer exists. `ApiKey#rotated_and_unused?` is the predicate that state is
  # DERIVED from (the model's own word), not the state itself. Keyed on it per row, the card would
  # contradict `show` on a repository whose live key keeps CI connected (the stranded key beside it
  # holds nothing back — `show` says Connected) and on a key rotated before it ever authenticated
  # (`show` says Not connected yet — no token was ever routed through it, so no replacement is
  # hanging). Both divergence cases are pinned by request specs, which is what makes the chain
  # shape a contract and not a preference.
  #
  # The chain's refusing conjunct is carried by the CARD'S ORDER rather than by suppression: the
  # refusal marker renders first, and a card holding both facts shows both. That ordering lives at
  # the grid, which renders the cards; this method answers only the rotated question, so a refusal
  # beside a stranded key reaches it here as `nil`-or-a-date and never as a suppressed fact.
  #
  # The date is the OLDEST stranded `rotated_at`, and never the newest: each stranded key satisfies
  # the rule against its own rotation, so the only date true of all of them at once is the oldest —
  # the NEWEST would date a five-day-dead pipeline at one minute whenever a second key was rotated
  # just now. The same choice the connection indicator's own branch makes over the same column.
  #
  # The trigger cannot fire on an empty stranded set: with nothing stranded,
  # {#last_live_api_request_at} reads the very rows {#last_api_request_at} does and the two cannot
  # hold "present AND blank" at once — so the `min` below runs over a non-empty set, and every
  # stranded row carries a `rotated_at` (the predicate's first limb is exactly that), never a
  # filtered-out nil.
  def stranded_rotation_time
    return nil unless last_api_request_at.present? && last_live_api_request_at.blank?

    stranded_rows.filter_map(&:rotated_at).min
  end
end
