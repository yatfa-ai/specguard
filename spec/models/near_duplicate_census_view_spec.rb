# frozen_string_literal: true

require "rails_helper"

# The projections over a HAND-BUILT stored block: no database, no ingest — the view is a pure
# function of the hash `NearDuplicateCensus.stored_block_for` serves, so its contract is pinned on
# hashes shaped exactly like that block (string keys, the written order, stamps last).
RSpec.describe NearDuplicateCensusView do
  def member(index, file: "spec/models/m#{index}_spec.rb")
    { "text" => "Thing #{index}", "file_path" => file, "line_number" => index,
      "example_count" => 1, "total_seconds" => 0.1 }
  end

  def cluster(members:, layered: false)
    groups = layered ? [{ "layer" => "unit", "members" => members.first(2) },
                        { "layer" => "request", "members" => members.drop(2) },
                        { "layer" => nil, "members" => [] }] : [{ "layer" => nil, "members" => members }]
    { "signal_source" => "name", "member_count" => members.size, "example_count" => members.size,
      "total_seconds" => 1.0, "timed_count" => members.size, "similarity_range" => [0.9, 0.86],
      "unobserved_members" => false, "layer_redundancy" => layered ? "cross_layer" : nil,
      "layer_groups" => groups, "members" => members }
  end

  let(:big) { cluster(members: Array.new(30) { |i| member(i, file: "spec/models/big_#{i % 4}_spec.rb") }) }
  let(:layered) { cluster(members: Array.new(4) { |i| member(i + 100) }, layered: true) }
  let(:unsorted) do
    files = %w[spec/z_spec.rb spec/a_spec.rb spec/z_spec.rb spec/m_spec.rb]
    cluster(members: files.each_with_index.map { |file, i| member(i + 200, file: file) })
  end
  let(:block) do
    { "similarity_floor" => 0.85, "similarity_basis" => "basis", "layer_source" => nil,
      "cluster_count" => 3, "truncated" => false, "clusters" => [big, layered, unsorted],
      "weighed_run_id" => 7, "computed_at" => "2026-10-08T00:00:00Z" }
  end

  def member_objects(node)
    case node
    when Hash then (node.key?("file_path") && node.key?("line_number") ? 1 : 0) + node.values.sum { member_objects(it) }
    when Array then node.sum { member_objects(it) }
    else 0
    end
  end

  describe "#summary" do
    subject(:summary) { described_class.new(block).summary }

    # @intent: { entity: "NearDuplicateCensusView", action: "summarise without member objects", behavior: "a 30-member cluster contributes no member object anywhere under the summary and the head keys keep the stored order with the stamps last", layer: "unit" }
    it "carries no member object anywhere, however large the cluster" do
      expect(member_objects(block)).to be > 30
      expect(member_objects(summary)).to eq(0)
      expect(summary.keys).to eq(block.keys)
    end

    # @intent: { entity: "NearDuplicateCensusView", action: "pass the leaders through", behavior: "the summary serves a stored layer_redundancy_leaders head key unchanged and in its stored position, a stored rank on a leader row included", layer: "unit" }
    it "serves layer_redundancy_leaders unchanged in the stored position" do
      leaders = { "cross_layer" => [{ "rank" => 7, "descriptions" => ["a"], "files_seen" => ["x"] }],
                  "same_layer" => [], "undeclared" => [] }
      stored = block.merge("layer_redundancy_leaders" => leaders)

      summary = described_class.new(stored).summary

      expect(summary["layer_redundancy_leaders"]).to eq(leaders)
      expect(summary.keys).to eq(stored.keys)
    end

    # @intent: { entity: "NearDuplicateCensusView", action: "derive the row keys", behavior: "each row keeps every stored scalar and gains a 1-based rank, sorted distinct files_seen, file_count and the distinct non-null declared_layers", layer: "unit" }
    it "derives rank, files_seen, file_count and declared_layers per row" do
      first, second = summary["clusters"]

      expect(first).to include("rank" => 1, "file_count" => 4, "declared_layers" => [])
      expect(first["files_seen"]).to eq(first["files_seen"].sort.uniq)
      expect(second).to include("rank" => 2, "declared_layers" => %w[unit request],
                                "layer_redundancy" => "cross_layer", "similarity_range" => [0.9, 0.86],
                                "unobserved_members" => false)
      expect(first.except("rank", "files_seen", "file_count", "declared_layers", "overlap_kind"))
        .to eq(big.except("members", "layer_groups"))
    end

    # @intent: { entity: "NearDuplicateCensusView", action: "derive overlap_kind", behavior: "every summary row carries overlap_kind derived from its own members, so a payload stored without the key still gets it, and a stored value never overrides what the members say", layer: "unit" }
    it "derives overlap_kind from the row's members, independent of layer_redundancy" do
      one_file = cluster(members: [ member(1, file: "spec/a_spec.rb"), member(2, file: "spec/a_spec.rb") ])

      rows = described_class.new(block.merge("clusters" => [ big, layered, one_file ])).summary["clusters"]

      expect(rows.map { it["overlap_kind"] }).to eq(%w[multi_file multi_file single_file])
      expect(rows[1]["layer_redundancy"]).to eq("cross_layer")
      expect(big).not_to have_key("overlap_kind")
    end

    # @intent: { entity: "NearDuplicateCensusView", action: "derive files_seen", behavior: "files_seen is the sorted distinct member file paths even when the stored members arrive unsorted and with repeats, and file_count counts the distinct paths", layer: "unit" }
    it "sorts and de-duplicates files_seen from unsorted stored members" do
      row = summary["clusters"].last

      expect(row["files_seen"]).to eq(%w[spec/a_spec.rb spec/m_spec.rb spec/z_spec.rb])
      expect(row["file_count"]).to eq(3)
    end

    # @intent: { entity: "NearDuplicateCensusView", action: "leave the stored hash alone", behavior: "building the summary or a cluster does not mutate the block it was handed", layer: "unit" }
    it "does not mutate the stored block" do
      frozen = Marshal.load(Marshal.dump(block))
      described_class.new(block).summary
      described_class.new(block).cluster("1")

      expect(block).to eq(frozen)
    end

    # @intent: { entity: "NearDuplicateCensusView", action: "serve null for no census", behavior: "a nil stored block gives a nil summary and a nil cluster", layer: "unit" }
    it "is nil when nothing is stored" do
      expect(described_class.new(nil).summary).to be_nil
      expect(described_class.new(nil).cluster("1")).to be_nil
    end
  end

  describe "#cluster" do
    # @intent: { entity: "NearDuplicateCensusView", action: "carry members once", behavior: "a flat-member cluster serves members and no layer_groups, a layered one serves layer_groups and no members, and member_listing names which", layer: "unit" }
    it "carries members once, by the listing the redundancy selects" do
      flat = described_class.new(block).cluster("1")
      expect(flat["member_listing"]).to eq("members")
      expect(flat["cluster"]).not_to have_key("layer_groups")
      expect(member_objects(flat["cluster"])).to eq(30)

      grouped = described_class.new(block).cluster("2")
      expect(grouped["member_listing"]).to eq("layer_groups")
      expect(grouped["cluster"]).not_to have_key("members")
      expect(member_objects(grouped["cluster"])).to eq(4)
      expect(grouped).to include("requested" => "2", "rank" => 2, "cluster_count" => 3,
                                 "weighed_run_id" => 7, "computed_at" => "2026-10-08T00:00:00Z")
    end

    # @intent: { entity: "NearDuplicateCensusView", action: "refuse to guess a rank", behavior: "zero, negative, fractional, signed, non-numeric and out-of-range ranks give a null cluster with the ask echoed and no rank read", layer: "unit" }
    it "gives a null cluster, echoing the ask, for any rank that is not a position" do
      %w[0 -1 1.5 +1 abc 1e2 4 99999999999999999999].each do |ask|
        answered = described_class.new(block).cluster(ask)

        expect(answered).to include("requested" => ask, "cluster" => nil, "member_listing" => nil)
      end
    end

    # SPGD-1856: the census's per-kind leaders are taken over every cluster, so a leader can sit
    # past the stored page — and since the writer stores each leader's rank, that rank is a
    # resolvable ask. The answer is the leader row REDUCED: stored scalars plus its descriptions,
    # never a members/layer_groups listing the page cap deliberately did not store off-page, with
    # `member_listing` saying "descriptions" so the coarser grain is disclosed, not discovered.
    # @intent: { entity: "NearDuplicateCensusView", action: "resolve a past-page leader", behavior: "a rank past the stored page that equals a stored leader's rank answers the reduced leader row with member_listing descriptions, echoing the ask and the snapshot stamps", layer: "unit" }
    it "answers a past-page leader rank with the reduced leader row" do
      leader = { "rank" => 15, "member_count" => 3, "example_count" => 9, "total_seconds" => 4.0,
                 "timed_count" => 3, "similarity_range" => [0.9, 0.86], "overlap_kind" => "multi_file",
                 "layer_redundancy" => "cross_layer", "declared_layers" => %w[unit request],
                 "files_seen" => %w[spec/a_spec.rb spec/b_spec.rb], "file_count" => 2,
                 "descriptions" => ["Alpha describes", "Beta describes", "Gamma describes"] }
      ranked = block.merge("cluster_count" => 34, "truncated" => true,
                           "layer_redundancy_leaders" =>
                             { "cross_layer" => [leader], "same_layer" => [], "undeclared" => [] })

      answered = described_class.new(ranked).cluster("15")

      expect(answered).to include("requested" => "15", "rank" => 15, "cluster_count" => 34,
                                  "weighed_run_id" => 7, "computed_at" => "2026-10-08T00:00:00Z",
                                  "member_listing" => "descriptions")
      expect(answered["cluster"]).to eq(leader)
      expect(answered["cluster"].keys).not_to include("members", "layer_groups")
    end

    # @intent: { entity: "NearDuplicateCensusView", action: "keep the on-page answer", behavior: "an on-page rank answers the stored cluster with its members carried once and never consults a stored leader row that carries the same rank", layer: "unit" }
    it "answers an on-page rank from the stored page and never consults the leaders" do
      impostor = { "rank" => 1, "member_count" => 1, "descriptions" => ["An impostor row"], "files_seen" => ["x"] }
      ranked = block.merge("layer_redundancy_leaders" =>
                             { "cross_layer" => [impostor], "same_layer" => [], "undeclared" => [] })

      answered = described_class.new(ranked).cluster("1")

      expect(answered["member_listing"]).to eq("members")
      expect(answered["cluster"]).to eq(big.except("layer_groups"))
      expect(JSON.generate(answered)).not_to include("An impostor row")
    end

    # @intent: { entity: "NearDuplicateCensusView", action: "refuse a past-page non-leader", behavior: "a past-page rank that is no stored leader's rank still answers a null cluster with the ask echoed", layer: "unit" }
    it "keeps a past-page non-leader rank a null cluster, echoing the ask" do
      leader = { "rank" => 15, "member_count" => 3, "descriptions" => ["Alpha describes"], "files_seen" => ["x"] }
      ranked = block.merge("cluster_count" => 34, "layer_redundancy_leaders" =>
                             { "cross_layer" => [leader], "same_layer" => [], "undeclared" => [] })

      answered = described_class.new(ranked).cluster("12")

      expect(answered).to include("requested" => "12", "rank" => 12, "cluster_count" => 34,
                                  "cluster" => nil, "member_listing" => nil)
    end

    # A census stored before ranks existed — every census stored today — degrades exactly as
    # stored: leader rows without a `rank` never match, so a past-page ask stays a null cluster.
    # The non-numeric ask is the sharp edge: a rank-less row's missing `rank` is nil, and reading
    # it against a nil ask without the guard would mint a leader out of an unparseable ask.
    # @intent: { entity: "NearDuplicateCensusView", action: "degrade a rank-less census", behavior: "leader rows stored without a rank never answer a past-page ask, and a non-numeric ask stays null over rank-less leader rows", layer: "unit" }
    it "answers a past-page ask null when the stored leaders carry no rank" do
      leader = { "member_count" => 3, "descriptions" => ["Alpha describes"], "files_seen" => ["x"] }
      ranked = block.merge("cluster_count" => 34, "layer_redundancy_leaders" =>
                             { "cross_layer" => [leader], "same_layer" => [], "undeclared" => [] })

      expect(described_class.new(ranked).cluster("15"))
        .to include("requested" => "15", "rank" => 15, "cluster" => nil, "member_listing" => nil)
      expect(described_class.new(ranked).cluster("abc"))
        .to include("requested" => "abc", "rank" => nil, "cluster" => nil, "member_listing" => nil)
    end
  end
end
