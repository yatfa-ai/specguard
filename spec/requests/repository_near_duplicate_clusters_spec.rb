# frozen_string_literal: true

require "rails_helper"

# The "Groups of tests that read alike" panel on repositories#show — the dashboard's first reading of
# the STORED near-duplicate census (`NearDuplicateCensus`), which until SPGD-1624 only the JSON API
# and the MCP bridge could see.
#
# Its own file, on the precedent every per-example panel here sets: each fixture needs identities
# whose texts read ALIKE, which no other page spec wants. The fixture is
# `spec/requests/api/v1/repository_near_duplicates_spec.rb`'s, built the same way and for the same
# reason — `Ingest::Payload` -> `RunRecorder` -> `IdentityResolver`, then the census requested and
# computed through the model seam and the job that really run it — so every state rendered here is
# one the real pipeline stores. `with lexical embeddings` makes `expired` / `outright` really read
# alike (cosine 0.89); the suite-wide stub would make every pair near-orthogonal.
#
# FOUR STATES, and the panel exists to keep them apart:
#
#   no stored row             -> "No census yet" (and no numeral anywhere)
#   row, recorded_count 0     -> "This run recorded no per-example rows"
#   row, no clusters          -> "Nothing reads alike at this floor"      (a positive finding)
#   row, clusters             -> the ranking
RSpec.describe "Repository near-duplicate clusters panel", type: :request do
  include_context "with lexical embeddings"

  let(:expired) { "Checkout rejects an expired card" }
  let(:outright) { "Checkout rejects an expired card outright" }
  let(:shipping) { "Shipping calculates a delivery estimate" }
  let(:inventory) { "Inventory decrements a stocked item" }

  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }

  def panel = Capybara.string(response.body).find("#near-duplicate-clusters")

  def panel? = Capybara.string(response.body).has_css?("#near-duplicate-clusters")

  def spec_row(file_path:, line_number:, name:, id:, duration: 0.5)
    { id: id, spec_file_path: file_path, file_path: file_path, line_number: line_number,
      name: name, duration: duration, outcome: "passed", status: "unannotated", intent: nil }
  end

  def record_and_resolve(repo, specs, commit_sha: "feedfacecafe0001")
    payload = Ingest::Payload.new(
      { "commit_sha" => commit_sha, "branch" => "main", "duration_seconds" => 60.0,
        "specs" => specs.map(&:deep_stringify_keys) }
    )
    raise "ingest fixture is not a valid payload: #{payload.errors.inspect}" unless payload.valid?

    run = Ingest::RunRecorder.record(repo, payload.test_run_attributes, specs: payload.specs)
    Ingest::IdentityResolver.resolve(run)
    run
  end

  def ingest(repo, specs, **)
    run = record_and_resolve(repo, specs, **)
    NearDuplicateCensus.request_refresh!(repo.id)
    Ingest::NearDuplicateCensusJob.perform_now(repo.id)
    run
  end

  # The headline fixture: the API spec's pair, where `expired` is a THREE-example table-driven loop
  # (one member, three examples) beside `outright` (one) — two members, four examples, one cluster.
  def pair_specs(duration: 0.2)
    [spec_row(file_path: "spec/models/checkout_spec.rb", line_number: 3, name: expired,
              id: "./spec/models/checkout_spec.rb[1:1]", duration: duration),
     spec_row(file_path: "spec/models/checkout_spec.rb", line_number: 4, name: expired,
              id: "./spec/models/checkout_spec.rb[1:2]", duration: duration),
     spec_row(file_path: "spec/models/checkout_spec.rb", line_number: 5, name: expired,
              id: "./spec/models/checkout_spec.rb[1:3]", duration: duration),
     spec_row(file_path: "spec/models/checkout_spec.rb", line_number: 9, name: outright,
              id: "./spec/models/checkout_spec.rb[2:1]", duration: duration * 2),
     spec_row(file_path: "spec/services/shipping_spec.rb", line_number: 12, name: shipping,
              id: "./spec/services/shipping_spec.rb[1:1]", duration: 1.0)]
  end

  describe "a repository with a stored census holding a cluster" do
    before { ingest(repository, pair_specs) }

    # @intent: {"entity": "NearDuplicateCensus", "action": "render a stored cluster", "behavior": "the panel shows the cluster's member text, file path and line, member and example counts, summed wall clock, the similarity basis, the floor and the computed_at stamp", "layer": "request"}
    it "renders the cluster, its basis, its floor and its stamp" do
      get repository_path(repository)

      stored = NearDuplicateCensus.stored_block_for(repository)
      text = panel.text(normalize_ws: true)

      expect(panel).to have_css("[data-near-duplicate-cluster]", count: 1)
      expect(text).to include(expired, outright)
      # Every stored member's `file_path:line_number`, read off the stored block rather than typed:
      # a table-driven member reports ONE of its rows' lines, and which one is not this example's
      # question.
      stored["clusters"].sole["members"].each do |member|
        expect(text).to include("#{member['file_path']}:#{member['line_number']}")
      end
      expect(text).to include("2 members", "4 examples")
      expect(text).to include("1.00s")
      expect(text).to include(NearDuplicateClusters::SIMILARITY_BASIS)
      expect(text).to include("at least #{NearDuplicateClusters::SIMILARITY}")
      expect(panel.find("time")[:datetime]).to eq(stored["computed_at"])
      expect(text).to include(stored["weighed_run_id"].to_s)
      expect(text).to include("not as a finding of duplication")
      # The page stated a clean cluster list, so the three other states' text is absent.
      expect(text).not_to include("No census yet")
      expect(text).not_to include("Nothing reads alike")
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "disclose two grains", "behavior": "a three-example table-driven member shows 3 examples beside the cluster's 2 members, so the member and example grains stay distinct through rendering", "layer": "request"}
    it "shows the three-example table-driven member's example count beside the member count" do
      get repository_path(repository)

      loop_row = panel.all("li li").find { |row| row.text(normalize_ws: true).include?("#{expired} (") }

      expect(loop_row.text(normalize_ws: true)).to include("(3 examples)")
      expect(panel.text(normalize_ws: true)).to include("2 members · 4 examples")
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "render for a view member", "behavior": "a member without keys.manage sees the same panel, because the census is read-only suite telemetry outside the manage_keys gate", "layer": "request"}
    it "renders for a view-only member too" do
      member = create_user(github_uid: "9990", github_handle: "viewer")
      create_membership(repository: repository, user: member)
      sign_in_via_github(uid: "9990")

      get repository_path(repository)

      expect(response.body).not_to include("api-keys")
      expect(panel).to have_text(expired)
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "never compute live", "behavior": "rendering the page issues exactly one near_duplicate_censuses read and no spec_identities statement, so the panel cannot fall back to the live clustering", "layer": "request"}
    it "reads the stored row once and never touches spec_identities" do
      get repository_path(repository)

      census_reads = queries_against('FROM "near_duplicate_censuses"') { get repository_path(repository) }
      identity_reads = queries_against("spec_identities") { get repository_path(repository) }

      expect(panel).to have_css("[data-near-duplicate-cluster]")
      expect(census_reads.size).to eq(1)
      expect(identity_reads).to be_empty
    end
  end

  # @intent: {"entity": "NearDuplicateCensus", "action": "bound census queries", "behavior": "the page issues one near_duplicate_censuses statement whether the stored census holds one cluster or several, so no per-cluster query exists", "layer": "request"}
  it "costs the same single census read at many clusters as at one" do
    one = create_repository(user: @user, github_full_name: "acme/one-cluster")
    ingest(one, pair_specs)
    many = create_repository(user: @user, github_full_name: "acme/many-clusters")
    ingest(many, pair_specs + [
      spec_row(file_path: "spec/models/stock_spec.rb", line_number: 3, name: inventory,
               id: "./spec/models/stock_spec.rb[1:1]"),
      spec_row(file_path: "spec/models/stock_spec.rb", line_number: 7, name: "#{inventory} outright",
               id: "./spec/models/stock_spec.rb[2:1]")
    ])

    get repository_path(one)
    one_reads = queries_against('FROM "near_duplicate_censuses"') { get repository_path(one) }
    expect(panel).to have_css("[data-near-duplicate-cluster]", count: 1)
    get repository_path(many)
    many_reads = queries_against('FROM "near_duplicate_censuses"') { get repository_path(many) }

    expect(panel).to have_css("[data-near-duplicate-cluster]", count: 2)
    expect(one_reads.size).to eq(1)
    expect(many_reads.size).to eq(1)
  end

  describe "a cluster whose examples were never timed" do
    before do
      ingest(repository, pair_specs.map { |row| row.merge(duration: nil) })
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "render an untimed cluster", "behavior": "a cluster with total_seconds nil renders not timed and never a zero duration", "layer": "request"}
    it "says not timed, never a zero" do
      get repository_path(repository)

      cluster = panel.find("[data-near-duplicate-cluster]")
      expect(NearDuplicateCensus.stored_block_for(repository)["clusters"].sole["total_seconds"]).to be_nil
      expect(cluster.text(normalize_ws: true)).to include("not timed")
      expect(cluster.text).not_to match(/0\.00s|\b0s\b/)
    end
  end

  describe "the four states" do
    # @intent: {"entity": "NearDuplicateCensus", "action": "render no stored row", "behavior": "a repository with no stored census renders the No census yet state with no numeral and no cluster list", "layer": "request"}
    it "(a) no stored row: says no census yet and prints no numeral" do
      expect(NearDuplicateCensus.find_by(repository_id: repository.id)).to be_nil

      get repository_path(repository)

      expect(panel.find("#near-duplicate-clusters-none-yet").text(normalize_ws: true))
        .to include("No census yet — the first one is computed after the next ingest")
      expect(panel).to have_no_css("[data-near-duplicate-cluster]")
      expect(panel).to have_no_css("#near-duplicate-clusters-basis")
      expect(panel.text).not_to match(/\d/)
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "render a marker-only row", "behavior": "a row created by the refresh marker whose payload was never computed is served as no census, not as zeros", "layer": "request"}
    it "(a) a never-computed marker row reads as no census, never as zeros" do
      NearDuplicateCensus.create!(repository_id: repository.id, refresh_wanted_at: Time.current)

      get repository_path(repository)

      expect(panel).to have_css("#near-duplicate-clusters-none-yet")
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "render an unrecorded run", "behavior": "a stored census whose weighed run recorded no per-example rows says so and does not claim nothing reads alike", "layer": "request"}
    it "(b) recorded_count 0: says the run recorded no per-example rows" do
      ingest(repository, [])

      get repository_path(repository)

      expect(NearDuplicateCensus.stored_block_for(repository)["recorded_count"]).to eq(0)
      expect(panel.find("#near-duplicate-clusters-unrecorded").text(normalize_ws: true))
        .to include("This run recorded no per-example rows")
      expect(panel).to have_no_css("#near-duplicate-clusters-clear")
      expect(panel).to have_no_css("[data-near-duplicate-cluster]")
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "render the success state", "behavior": "a stored census over distinct tests with no clusters says nothing reads alike at this floor, stating the identity count", "layer": "request"}
    it "(c) no clusters over real identities: says nothing reads alike at this floor" do
      ingest(repository, [
        spec_row(file_path: "spec/models/checkout_spec.rb", line_number: 3, name: expired,
                 id: "./spec/models/checkout_spec.rb[1:1]"),
        spec_row(file_path: "spec/services/shipping_spec.rb", line_number: 12, name: shipping,
                 id: "./spec/services/shipping_spec.rb[1:1]")
      ])

      get repository_path(repository)

      stored = NearDuplicateCensus.stored_block_for(repository)
      expect(stored["clusters"]).to be_empty
      expect(stored["identity_count"]).to be_positive
      clear = panel.find("#near-duplicate-clusters-clear")
      expect(clear.text(normalize_ws: true)).to include("Nothing reads alike at this floor")
      expect(clear.text(normalize_ws: true)).to include("2 tests")
      expect(panel).to have_css("#near-duplicate-clusters-basis")
      expect(panel).to have_no_css("[data-near-duplicate-cluster]")
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "render clusters", "behavior": "a stored census with clusters renders the list and none of the three empty-state nodes", "layer": "request"}
    it "(d) clusters present: renders the list and no empty-state node" do
      ingest(repository, pair_specs)

      get repository_path(repository)

      expect(panel).to have_css("#near-duplicate-cluster-list")
      expect(panel).to have_no_css("#near-duplicate-clusters-none-yet")
      expect(panel).to have_no_css("#near-duplicate-clusters-unrecorded")
      expect(panel).to have_no_css("#near-duplicate-clusters-clear")
      expect(panel.find("#near-duplicate-clusters-page").text(normalize_ws: true))
        .to include("All 1 group of tests that read alike")
    end
  end

  # The page-wide truncation disclosure: a capped list reads as a page, not as the census.
  # @intent: {"entity": "NearDuplicateCensus", "action": "disclose a capped list", "behavior": "when the stored census is truncated the panel states the costliest N of the cluster_count rather than all of them", "layer": "request"}
  it "states a truncated census as a page of the whole" do
    ingest(repository, pair_specs)
    census = NearDuplicateCensus.find_by!(repository_id: repository.id)
    census.update!(payload: census.payload.merge("truncated" => true, "cluster_count" => 7))

    get repository_path(repository)

    expect(panel.find("#near-duplicate-clusters-page").text(normalize_ws: true))
      .to include("The 1 costliest of 7 groups", "a page of the census, not all of it")
  end

  # @intent: {"entity": "NearDuplicateCensus", "action": "render layer redundancy", "behavior": "a cluster whose members declare two layers reads spans 2 declared layers, one confined to a single layer reads one layer, and an undeclared cluster says neither", "layer": "request"}
  it "words layer_redundancy for each of its three values" do
    ingest(repository, pair_specs)
    census = NearDuplicateCensus.find_by!(repository_id: repository.id)
    cluster = census.payload["clusters"].sole

    {
      "cross_layer" => [%w[request model], "spans 2 declared layers"],
      "same_layer" => [%w[request], "one layer"],
      nil => [[nil], nil]
    }.each do |redundancy, (layers, wording)|
      groups = layers.map { |layer| { "layer" => layer, "members" => [] } }
      census.update!(payload: census.payload.merge(
        "clusters" => [cluster.merge("layer_redundancy" => redundancy, "layer_groups" => groups)]
      ))

      get repository_path(repository)
      text = panel.find("[data-near-duplicate-cluster]").text(normalize_ws: true)

      if wording
        expect(text).to include(wording)
      else
        expect(text).not_to match(/declared layer|one layer/)
      end
    end
  end
end
