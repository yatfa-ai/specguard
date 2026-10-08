# frozen_string_literal: true

# Two bounded PROJECTIONS of the stored near-duplicate census block — the short ranking and the
# one-cluster drill-in — for a reader whose context cannot take the whole block.
#
# `?near_duplicates=` serves every stored cluster with BOTH member listings (the flat `members`
# and the same members re-grouped as `layer_groups`). The cluster cap bounds the cluster count and
# not the member count, so one large cluster dominates the payload. This object is the
# `?spec_directory=` / `?spec_file=` shape applied to the census: a ranking with no member lists
# ({#summary}), and a drill-in that opens one cluster with its members carried ONCE ({#cluster}).
#
# It is a pure function of the block {NearDuplicateCensus.stored_block_for} already serves — the
# one stored row, merged with its stamps. It issues no query of its own (never `spec_identities`
# or `spec_observations`), changes nothing stored, and never mutates the hash it is handed. The
# existing `near_duplicates` block is untouched by it.
#
# == Ranks are positions in a snapshot
#
# `rank` is the 1-based position in the STORED order — the existing order, with no reordering or
# filtering here. A recompute can move every position, so the drill-in echoes `computed_at` and
# `weighed_run_id` (and `cluster_count`) beside the rank: a rank without the snapshot it indexes
# is a claim about nothing.
class NearDuplicateCensusView
  # The stored block's list of clusters.
  CLUSTERS_KEY = "clusters"

  def initialize(block)
    @block = block
  end

  # THE RANKING. The stored head keys first — `similarity_floor`, `similarity_basis`,
  # `layer_source`, then the population figures, `weighed_run_id` and `computed_at`, in the stored
  # order — then `clusters`: every existing scalar of each row, with BOTH member listings dropped
  # and four derived keys added: `rank`, `files_seen` (sorted distinct member file paths),
  # `file_count`, `overlap_kind` and `declared_layers` (distinct non-null layer names). `layer_redundancy`,
  # `similarity_range` and `unobserved_members` ride unchanged.
  #
  # `nil` when nothing is stored, per the census's own rule.
  def summary
    return nil if @block.nil?

    rows = clusters.each_with_index.map { |cluster, index| summary_row(cluster, index + 1) }

    # `merge` of an existing key keeps its position, so `clusters` stays where the stored block
    # wrote it (ahead of the two stamps).
    @block.merge(CLUSTERS_KEY => rows)
  end

  # THE DRILL-IN for `requested` (the raw ask, echoed verbatim). `rank` is the integer read from
  # it, or `nil` when it is not a positive integer; `cluster` is the stored cluster at that
  # position or `nil` — an unknown, zero, negative or non-numeric rank is a null cluster with the
  # ask echoed, never an error.
  #
  # The members are carried ONCE: `layer_groups` when `layer_redundancy` is non-nil, else the flat
  # `members` — the dashboard partial's own rule — and `member_listing` says which one the
  # cluster holds.
  #
  # `nil` when nothing is stored.
  def cluster(requested)
    return nil if @block.nil?

    rank = parse_rank(requested)
    stored = rank && rank <= clusters.size ? clusters[rank - 1] : nil

    {
      "requested" => requested,
      "rank" => rank,
      "cluster_count" => @block["cluster_count"],
      "weighed_run_id" => @block["weighed_run_id"],
      "computed_at" => @block["computed_at"],
      "member_listing" => stored && member_listing(stored),
      "cluster" => stored && single_listing(stored)
    }
  end

  private

  def clusters = Array(@block[CLUSTERS_KEY])

  # A positive integer written in digits and nothing else: `"2"` is rank 2; `"0"`, `"-1"`, `"1.5"`,
  # `"+1"`, `"abc"` and `"1e2"` read nothing. Surrounding whitespace is a typo, not a different ask.
  def parse_rank(requested)
    text = requested.to_s.strip
    return nil unless text.match?(/\A\d+\z/)

    rank = text.to_i
    rank.positive? ? rank : nil
  end

  def summary_row(cluster, rank)
    files = Array(cluster["members"]).filter_map { |member| member["file_path"] }.uniq.sort
    layers = Array(cluster["layer_groups"]).filter_map { |group| group["layer"] }.uniq

    cluster.except("members", "layer_groups").merge(
      "rank" => rank, "files_seen" => files, "file_count" => files.size, "declared_layers" => layers,
      # Derived from the row's own members, so a payload stored before the key existed gets it too.
      "overlap_kind" => files.size > 1 ? "multi_file" : "single_file"
    )
  end

  def member_listing(cluster)
    cluster["layer_redundancy"].nil? ? "members" : "layer_groups"
  end

  def single_listing(cluster)
    dropped = member_listing(cluster) == "members" ? "layer_groups" : "members"
    cluster.except(dropped)
  end
end
