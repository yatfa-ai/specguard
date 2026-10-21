# frozen_string_literal: true

# The sentences of the near-duplicate census panel (coverage, examples not compared, the
# declared-layer tally and its cross-layer leaders) on repositories#show, with the constants they
# read. Lifted out of RepositoriesHelper, which had grown past what one file can be read as; the
# methods are unchanged. Reached by implicit receiver, since every helper is mixed into the one
# view class — which is also how `drawer_row_id`, shared console machinery that stays in
# RepositoriesHelper, is reached from here.
module NearDuplicateClustersHelper
  private

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

  # The census-wide declared-layer tally, stated where the caption would otherwise leave the
  # truncated page to be read as the whole: the page holds the top-ranked groups only, and this
  # is the one figure that answers "how many of ALL the groups are tested on more than one layer".
  # Read from the stored `layer_redundancy_counts` (counted over every cluster, never the page).
  # nil when the key is absent (a census stored before the tally existed — the counts cannot be
  # derived from the stored page, so the caption renders exactly as it did), or when it is not the
  # three-Integer shape.
  def near_duplicate_layer_redundancy_clause(census)
    return nil unless census.is_a?(Hash)

    counts = census["layer_redundancy_counts"]
    return nil unless counts.is_a?(Hash)

    cross, same, undeclared = counts.values_at("cross_layer", "same_layer", "undeclared")
    return nil unless [cross, same, undeclared].all?(Integer)

    total = cross + same + undeclared
    clause = "#{number_with_delimiter(cross)} of the #{number_with_delimiter(total)} #{"group".pluralize(total)} " \
             "#{cross == 1 ? "spans" : "span"} more than one declared layer, " \
             "#{number_with_delimiter(same)} #{same == 1 ? "is" : "are"} confined to one layer, " \
             "#{number_with_delimiter(undeclared)} declared none."
    examples = near_duplicate_cross_layer_examples(census)
    # `safe_join`, not interpolation: the examples clause may carry the in-page anchor (SPGD-1856),
    # and interpolating a SafeBuffer into a plain String strips its html_safe flag — the anchor
    # would render as escaped text. The joined pieces are server-built, so the result stays safe.
    examples ? safe_join([clause, " ", examples]) : clause
  end

  # How many stored cross-layer leaders the caption may name, and how long a description may run
  # before it is cut — the stored key holds up to three rows (SPGD-1844).
  NEAR_DUPLICATE_LEADER_ROWS = 3
  NEAR_DUPLICATE_LEADER_DESCRIPTION = 80

  # The drawer kind the near-duplicate cluster table mints its rows under — shared between the
  # partial that renders the rows and the caption that anchors to them, so the two ends of one
  # in-page anchor read one constant rather than two literals free to drift.
  NEAR_DUPLICATE_CLUSTER_DRAWER_KIND = "Group of tests that read alike"

  # Names the census's best cross-layer groups after the tally — "e.g. A ↔ B (a_spec.rb + b_spec.rb)" —
  # from the stored `layer_redundancy_leaders["cross_layer"]`, which is taken over EVERY cluster and so
  # can name a group past the stored page. A leader whose stored `rank` sits ON the page renders as an
  # in-page anchor to its drawer row (SPGD-1856); an off-page, unranked or unreadable leader renders
  # the same phrase as plain text — its read is the API ask, and the caption's "a page of the census"
  # sentence keeps disclosing the page. Degrades as stored: nil (the caption is exactly what it was)
  # for a census stored before the key, for an empty kind, and for any non-conforming shape — not an
  # Array of at most three rows, or a row without a description list and a file list of strings.
  def near_duplicate_cross_layer_examples(census)
    leaders = census["layer_redundancy_leaders"]
    return nil unless leaders.is_a?(Hash)

    rows = leaders["cross_layer"]
    return nil unless rows.is_a?(Array) && rows.any? && rows.size <= NEAR_DUPLICATE_LEADER_ROWS

    phrases = rows.map { |row| near_duplicate_leader_phrase(row, near_duplicate_leader_anchor(census, row)) }
    return nil if phrases.any?(&:nil?)

    # `safe_join`, not interpolation: a phrase may carry the in-page anchor (SPGD-1856), and Array#join
    # calls to_s on its elements — stripping a SafeBuffer's html_safe flag and leaving the anchor to
    # render escaped. The pieces are server-built, so the joined result stays safe.
    safe_join(["e.g. ", safe_join(phrases, "; "), "."])
  end

  # The in-page anchor for a cross-layer leader the stored page holds: the drawer row id the table
  # minted for the cluster at `rank - 1` — the SAME seed the partial passes
  # (`cluster-#{index}-#{lead_text}`, index derived from the stored rank, never a second id scheme).
  # `nil` — plain text — when the row carries no `rank` (a census stored before ranks existed),
  # when the rank sits past the page (the drawer was deliberately not stored), or when the page row
  # the rank names does not carry the leader's own smallest member text, so a hand-edited payload
  # cannot anchor a phrase at a drawer that is not its group.
  def near_duplicate_leader_anchor(census, row)
    rank = row.is_a?(Hash) ? row["rank"] : nil
    return nil unless rank.is_a?(Integer)

    cluster = Array(census["clusters"])[rank - 1]
    return nil unless cluster.is_a?(Hash)

    members = Array(cluster["members"])
    lead = members.first
    return nil unless lead.is_a?(Hash) && lead["text"].present?

    # The leader's descriptions are its member texts sorted, so the first one IS the cluster's
    # smallest member text — the cheap identity check between the named leader and the page row
    # the rank points at.
    return nil unless Array(row["descriptions"]).first == members.filter_map { |m| m.is_a?(Hash) && m["text"] }.min

    drawer_row_id(NEAR_DUPLICATE_CLUSTER_DRAWER_KIND, "cluster-#{rank - 1}-#{lead['text']}")
  end

  # The phrase itself: the first two stored descriptions joined around the group's files, wrapped in
  # the in-page anchor when one was composed. The text is identical either way, so a reader (and a
  # spec) reading the sentence sees the same words on both sides of the page boundary.
  def near_duplicate_leader_phrase(row, anchor = nil)
    return nil unless row.is_a?(Hash)

    descriptions, files = row.values_at("descriptions", "files_seen")
    return nil unless [descriptions, files].all? { |list| list.is_a?(Array) && list.any? && list.all?(String) }

    names = descriptions.first(2).map { |text| truncate(text, length: NEAR_DUPLICATE_LEADER_DESCRIPTION) }
    phrase = "#{names.join(" ↔ ")} (#{files.join(" + ")})"
    anchor ? link_to(phrase, "##{anchor}", class: "rc-link") : phrase
  end
end
