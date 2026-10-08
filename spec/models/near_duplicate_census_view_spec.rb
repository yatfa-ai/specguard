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

    # @intent: { entity: "NearDuplicateCensusView", action: "derive the row keys", behavior: "each row keeps every stored scalar and gains a 1-based rank, sorted distinct files_seen, file_count and the distinct non-null declared_layers", layer: "unit" }
    it "derives rank, files_seen, file_count and declared_layers per row" do
      first, second = summary["clusters"]

      expect(first).to include("rank" => 1, "file_count" => 4, "declared_layers" => [])
      expect(first["files_seen"]).to eq(first["files_seen"].sort.uniq)
      expect(second).to include("rank" => 2, "declared_layers" => %w[unit request],
                                "layer_redundancy" => "cross_layer", "similarity_range" => [0.9, 0.86],
                                "unobserved_members" => false)
      expect(first.except("rank", "files_seen", "file_count", "declared_layers"))
        .to eq(big.except("members", "layer_groups"))
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
  end
end
