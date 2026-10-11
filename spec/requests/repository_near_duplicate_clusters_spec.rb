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
      # The table-row figures and the drawer facts both carry the two grains; the text is the drawer's.
      # The two grains are two cells of the group's row — members (distinct texts) and examples (rows).
      cells = panel.find("[data-near-duplicate-cluster]").all("td").map { |cell| cell.text(normalize_ws: true) }
      expect(cells[1]).to eq("2")
      expect(cells[2]).to eq("4")
      expect(text).to include("1.00s")
      expect(text).to include(NearDuplicateClusters::SIMILARITY_BASIS)
      expect(text).to include("at least #{NearDuplicateClusters::SIMILARITY}")
      expect(panel.find("time")[:datetime]).to eq(stored["computed_at"])
      expect(text).to include("not as a finding of duplication")
      # The page stated a clean cluster list, so the three other states' text is absent.
      expect(text).not_to include("No census yet")
      expect(text).not_to include("Nothing reads alike")
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "disclose two grains", "behavior": "a three-example table-driven member shows 3 examples beside the cluster's 2 members, so the member and example grains stay distinct through rendering", "layer": "request"}
    it "shows the three-example table-driven member's example count beside the member count" do
      get repository_path(repository)

      loop_row = panel.all("[data-near-duplicate-cluster] li").find { |row| row.text(normalize_ws: true).include?("#{expired} (") }

      expect(loop_row.text(normalize_ws: true)).to include("(3 examples)")
      cells = panel.find("[data-near-duplicate-cluster]").all("td").map { |cell| cell.text(normalize_ws: true) }
      expect(cells.values_at(1, 2)).to eq(%w[2 4])
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "render member time", "behavior": "each flat-list member row shows its own stored total_seconds through SpecObservation.humanized_duration, after its example count", "layer": "request"}
    it "shows each member's stored total_seconds in its row" do
      get repository_path(repository)

      members = NearDuplicateCensus.stored_block_for(repository)["clusters"].sole["members"]
      rows = panel.all("[data-near-duplicate-cluster] [data-near-duplicate-layer-group] > ul > li")
      expect(rows.size).to eq(members.size)
      members.each do |member|
        row = rows.find { |r| r.text(normalize_ws: true).include?("#{member['file_path']}:#{member['line_number']}") }
        expect(member["total_seconds"]).to be_a(Numeric)
        expect(row.text(normalize_ws: true)).to include(SpecObservation.humanized_duration(member["total_seconds"]))
        expect(row.text(normalize_ws: true)).not_to include("not timed")
      end
      expect(rows.map { |r| r.text(normalize_ws: true)[/\d+\.\d\ds\z/] }).to contain_exactly("0.60s", "0.40s")
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "caption member time", "behavior": "the panel basis states that a member's time counts only its timed examples in the weighed run, so a partially timed figure is a floor", "layer": "request"}
    it "captions that a member's time is a floor over its timed examples" do
      get repository_path(repository)

      expect(panel.text(normalize_ws: true)).to include(
        "A member's time counts only its timed examples in the weighed run",
        "the figure is a floor"
      )
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

  # SPGD-1642: the stamp names the weighed run by commit and branch, linked, never by its bigint id.
  describe "the stamp's weighed run" do
    let(:weighed_sha) { "aaaaaaaaaaaaaaaa0001" }
    let(:latest_sha) { "bbbbbbbbbbbbbbbb0002" }
    let(:census) { NearDuplicateCensus.find_by!(repository_id: repository.id) }

    def stamp = panel.find("#near-duplicate-clusters-stamp")

    # The stamp's prose with the timestamp element removed, so a numeral test cannot be satisfied or
    # broken by the ISO timestamp's own digits.
    def stamp_prose
      doc = Capybara.string(stamp.native.to_html)
      doc.all("time").each { |node| node.native.remove }
      doc.text(normalize_ws: true)
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "name the weighed run", "behavior": "the stamp names the weighed run by its 7-character commit sha as a link to the repository drill-down for that full sha, with its branch, and never prints the numeric weighed_run_id", "layer": "request"}
    it "links the weighed run's short sha with its branch and prints no run id" do
      ingest(repository, pair_specs, commit_sha: weighed_sha)
      run_id = census.weighed_run_id

      get repository_path(repository)

      href = repository_path(repository, commit_sha: weighed_sha, anchor: "summary")
      link = stamp.find("a")
      expect(link.text).to eq(weighed_sha.first(7))
      expect(link[:href]).to eq(href)
      expect(stamp_prose).to include("weighing run #{weighed_sha.first(7)} on main")
      expect(stamp_prose).not_to match(/(?<![\w-])#{run_id}(?![\w-])/)
      expect(stamp_prose).not_to include("not the run this page is on")
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "flag an older weighed run", "behavior": "when the weighed run's sha differs from the page's latest run the stamp says it is not the run the page is on", "layer": "request"}
    it "says the weighed run is not the run the page is on when a newer run exists" do
      ingest(repository, pair_specs, commit_sha: weighed_sha)
      record_and_resolve(repository, pair_specs, commit_sha: latest_sha)

      get repository_path(repository)

      expect(stamp_prose).to include("(not the run this page is on)")
      expect(stamp.all("a").size).to eq(1)
      expect(stamp.find("a").text).to eq(weighed_sha.first(7))
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "omit a nil branch", "behavior": "a weighed run with no branch renders the sha link with no branch clause and never prints nil", "layer": "request"}
    it "omits the branch clause when the weighed run has no branch" do
      ingest(repository, pair_specs, commit_sha: weighed_sha)
      TestRun.where(id: census.weighed_run_id).update_all(branch: nil)

      get repository_path(repository)

      expect(stamp.find("a").text).to eq(weighed_sha.first(7))
      expect(stamp_prose).not_to match(/\bon\b/)
      expect(stamp_prose.downcase).not_to include("nil")
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "state a deleted weighed run", "behavior": "when the weighed run row was deleted the stamp has no link and no numeral and says the run has since been deleted", "layer": "request"}
    it "says in words that the weighed run is gone, with no link and no numeral" do
      ingest(repository, pair_specs, commit_sha: weighed_sha)
      record_and_resolve(repository, pair_specs, commit_sha: latest_sha)
      run_id = census.weighed_run_id
      TestRun.where(id: run_id).destroy_all

      get repository_path(repository)

      expect(stamp).not_to have_css("a")
      expect(stamp_prose).to include("a run that has since been deleted")
      expect(stamp_prose).not_to match(/(?<![\w-])#{run_id}(?![\w-])/)
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "state no weighed run", "behavior": "a census with no weighed_run_id says no weighed run was recorded, with no link and no numeral", "layer": "request"}
    it "says no weighed run was recorded when the census has no weighed_run_id" do
      ingest(repository, pair_specs, commit_sha: weighed_sha)
      census.update_columns(weighed_run_id: nil)

      get repository_path(repository)

      expect(stamp).not_to have_css("a")
      expect(stamp_prose).to include("no weighed run recorded")
      expect(stamp_prose).not_to match(/\d/)
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

  # @intent: {"entity": "NearDuplicateCensus", "action": "bound weighed-sha lookup", "behavior": "the page resolves the weighed run's commit sha with exactly one test_runs statement whether the census holds one cluster or several, so no per-member lookup exists", "layer": "request"}
  it "resolves the weighed run's sha with one test_runs read at many clusters as at one" do
    one = create_repository(user: @user, github_full_name: "acme/one-sha")
    ingest(one, pair_specs)
    many = create_repository(user: @user, github_full_name: "acme/many-sha")
    ingest(many, pair_specs + [
      spec_row(file_path: "spec/models/stock_spec.rb", line_number: 3, name: inventory,
               id: "./spec/models/stock_spec.rb[1:1]"),
      spec_row(file_path: "spec/models/stock_spec.rb", line_number: 7, name: "#{inventory} outright",
               id: "./spec/models/stock_spec.rb[2:1]")
    ])
    weighed_lookup = ->(repo) { %r{FROM "test_runs" WHERE "test_runs"."repository_id" = \$?\d+ AND "test_runs"."id" = } }

    get repository_path(one)
    one_reads = queries_against(weighed_lookup.call(one)) { get repository_path(one) }
    expect(panel).to have_css("[data-near-duplicate-cluster]", count: 1)
    get repository_path(many)
    many_reads = queries_against(weighed_lookup.call(many)) { get repository_path(many) }

    expect(panel).to have_css("[data-near-duplicate-cluster]", count: 2)
    expect(one_reads.size).to eq(1)
    expect(many_reads.size).to eq(1)
  end

  # @intent: {"entity": "NearDuplicateCensus", "action": "skip the weighed-sha lookup", "behavior": "with no stored census the page issues no weighed-run test_runs lookup, so the page query budget is unchanged", "layer": "request"}
  it "issues no weighed-run lookup when there is no census" do
    weighed_lookup = %r{FROM "test_runs" WHERE "test_runs"."repository_id" = \$?\d+ AND "test_runs"."id" = }

    reads = queries_against(weighed_lookup) { get repository_path(repository) }

    expect(NearDuplicateCensus.find_by(repository_id: repository.id)).to be_nil
    expect(reads).to be_empty
  end

  # SPGD-1636: each member's coordinate links to GitHub, pinned to the census's WEIGHED run.
  describe "member definition-site links" do
    let(:weighed_sha) { "aaaaaaaaaaaaaaaa0001" }
    let(:latest_sha) { "bbbbbbbbbbbbbbbb0002" }
    let(:census) { NearDuplicateCensus.find_by!(repository_id: repository.id) }
    let(:cluster) { census.payload["clusters"].sole }

    # The weighed run is older than a newer run of the same repository, so the page's latest run and
    # the census's weighed run name DIFFERENT shas.
    before do
      ingest(repository, pair_specs, commit_sha: weighed_sha)
      record_and_resolve(repository, pair_specs, commit_sha: latest_sha)
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "link cluster members", "behavior": "every flat-list member row carries exactly one coordinate link equal to github_blob_url at the weighed run's sha, opening in a new tab with noopener noreferrer, and never the latest run's sha", "layer": "request"}
    it "links each flat-list member to the weighed run's sha, not the latest run's" do
      expect(repository.test_runs.order(:id).last.commit_sha).to eq(latest_sha)

      get repository_path(repository)

      members = cluster["members"]
      rows = panel.all("[data-near-duplicate-cluster] [data-near-duplicate-layer-group] > ul > li")
      expect(rows.size).to eq(members.size)
      members.each do |member|
        href = repository.github_blob_url(member["file_path"], member["line_number"], weighed_sha)
        links = panel.all("a[href='#{href}']")
        expect(links.size).to eq(1)
        expect(links.first[:target]).to eq("_blank")
        expect(links.first[:rel]).to eq("noopener noreferrer")
        expect(links.first.text).to eq("#{member['file_path']}:#{member['line_number']}")
      end
      expect(rows.sum { |row| row.all("a").size }).to eq(members.size)
      expect(panel.native.to_html).not_to include(latest_sha)
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "link layer-grouped members", "behavior": "a member stored in two layer groups links to the weighed run's sha under both, through the same row partial as the flat list", "layer": "request"}
    it "links layer-grouped members the same way, under every group they sit in" do
      expired_member = cluster["members"].find { |m| m["text"] == expired }
      outright_member = cluster["members"].find { |m| m["text"] == outright }
      census.update!(payload: census.payload.merge(
        "layer_source" => "declared via the intent protocol",
        "clusters" => [cluster.merge("layer_redundancy" => "cross_layer", "layer_groups" => [
          { "layer" => "request", "members" => [expired_member] },
          { "layer" => "unit", "members" => [expired_member, outright_member] }
        ])]
      ))

      get repository_path(repository)

      expect(panel).to have_css("[data-near-duplicate-layer-group]", count: 2)
      expect(panel.all("[data-near-duplicate-layer-group] li").size).to eq(3)
      expect(panel.all("[data-near-duplicate-layer-group] li a").size).to eq(3)
      href = repository.github_blob_url(expired_member["file_path"], expired_member["line_number"], weighed_sha)
      expect(panel.all("[data-near-duplicate-layer-group] a[href='#{href}']").size).to eq(2)
      expect(panel.native.to_html).not_to include(latest_sha)
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "degrade a deleted weighed run", "behavior": "a census whose weighed run row was deleted renders each member coordinate as plain text with no link and still answers 200", "layer": "request"}
    it "renders plain text, not a link, when the weighed run was deleted" do
      TestRun.where(id: census.weighed_run_id).destroy_all
      expect(NearDuplicateCensus.find_by!(repository_id: repository.id).weighed_run_id).to be_present

      get repository_path(repository)

      expect(response).to have_http_status(:ok)
      rows = panel.all("[data-near-duplicate-cluster] [data-near-duplicate-layer-group] > ul > li")
      expect(rows.size).to eq(cluster["members"].size)
      expect(rows.sum { |row| row.all("a").size }).to eq(0)
      cluster["members"].each do |member|
        expect(panel.text).to include("#{member['file_path']}:#{member['line_number']}")
      end
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "degrade a nil weighed run id", "behavior": "a census with no weighed_run_id renders each member coordinate as plain text with no link and still answers 200", "layer": "request"}
    it "renders plain text, not a link, when the census has no weighed_run_id" do
      census.update_columns(weighed_run_id: nil)

      get repository_path(repository)

      expect(response).to have_http_status(:ok)
      expect(panel.all("[data-near-duplicate-cluster] [data-near-duplicate-layer-group] > ul > li").sum { |row| row.all("a").size }).to eq(0)
      expect(panel).to have_text(expired)
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "note an unobserved member's link", "behavior": "a cluster listing an unobserved member says its link is pinned to the weighed run and may not resolve, and still links the member", "layer": "request"}
    it "notes that an unobserved member's link is pinned to the weighed run" do
      census.update!(payload: census.payload.merge(
        "clusters" => [cluster.merge("unobserved_members" => true)]
      ))

      get repository_path(repository)

      text = panel.text(normalize_ws: true)
      expect(text).to include("lists a test the weighed run did not observe")
      expect(text).to include("pinned to the weighed run and may not resolve on GitHub")
      expect(panel).to have_css("[data-near-duplicate-cluster] a", minimum: 1)
    end
  end

  # The stored `similarity_range` and census-level `saturated_identity_count`, rendered from the
  # stored Hash. Membership is transitive and similarity is not, so the stretch is stated.
  describe "the similarity stretch and the saturation caveat" do
    before { ingest(repository, pair_specs) }

    let(:census) { NearDuplicateCensus.find_by!(repository_id: repository.id) }
    let(:cluster) { census.payload["clusters"].sole }
    let(:caveat) { "may be part of a larger one" }

    def store(cluster_overrides: {}, drop: [], census_overrides: {})
      stored = cluster.merge(cluster_overrides).except(*drop)
      census.update!(payload: census.payload.merge("clusters" => [stored]).merge(census_overrides))
    end

    def cluster_text = panel.find("[data-near-duplicate-cluster]").text(normalize_ws: true)

    # @intent: {"entity": "NearDuplicateCensus", "action": "render similarity_range", "behavior": "a stored range of two different figures renders both inside that cluster, best then worst", "layer": "request"}
    it "renders both figures of a stretched range inside the cluster" do
      store(cluster_overrides: { "similarity_range" => [0.97, 0.86] })

      get repository_path(repository)

      expect(cluster_text).to include("alike at 0.97 at best, 0.86 at worst")
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "render a flat similarity_range", "behavior": "a stored range whose ends are equal renders one figure and no best/worst wording", "layer": "request"}
    it "renders one figure when strongest equals weakest" do
      store(cluster_overrides: { "similarity_range" => [0.89, 0.89] })

      get repository_path(repository)

      expect(cluster_text).to include("alike at 0.89")
      expect(cluster_text).not_to match(/at best|at worst/)
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "degrade a missing similarity_range", "behavior": "a cluster stored without similarity_range renders with no range text, no zero figure and no error", "layer": "request"}
    it "renders no range text for a cluster stored without one" do
      store(drop: ["similarity_range"])

      get repository_path(repository)

      expect(response).to have_http_status(:ok)
      expect(cluster_text).not_to match(/alike at|0\.0/)
      expect(panel).to have_css("[data-near-duplicate-cluster]", count: 1)
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "render saturation caveat", "behavior": "a positive saturated_identity_count renders the fragment caveat exactly once on the panel", "layer": "request"}
    it "states the fragment caveat once when identities were saturated" do
      store(census_overrides: { "saturated_identity_count" => 3 })

      get repository_path(repository)

      expect(panel.text(normalize_ws: true).scan(caveat).size).to eq(1)
      expect(panel).to have_css("#near-duplicate-clusters-saturation", count: 1)
      expect(panel).to have_no_css("[data-near-duplicate-cluster] #near-duplicate-clusters-saturation")
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "omit saturation caveat at zero", "behavior": "a zero or absent saturated_identity_count renders no caveat and no count clause", "layer": "request"}
    it "renders no caveat when nothing was saturated" do
      [0, nil].each do |value|
        store(census_overrides: { "saturated_identity_count" => value })

        get repository_path(repository)

        expect(panel.text(normalize_ws: true)).not_to include(caveat)
        expect(panel).to have_no_css("#near-duplicate-clusters-saturation")
      end
    end
  end

  # SPGD-1649: how much of the suite the groups cover, and how many examples were not compared —
  # both rendered from the stored Hash's figures, never recomputed.
  describe "coverage and the examples not compared" do
    before { ingest(repository, pair_specs) }

    let(:census) { NearDuplicateCensus.find_by!(repository_id: repository.id) }
    let(:cluster) { census.payload["clusters"].sole }
    let(:no_text) { "reached no resolvable text" }

    def store(drop: [], overrides: {}, clusters: nil)
      payload = census.payload.merge(overrides).except(*drop)
      payload = payload.merge("clusters" => clusters) if clusters
      census.update!(payload: payload)
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "state coverage", "behavior": "the panel states once how many compared tests and how many recorded examples the groups cover, taken from the stored census figures", "layer": "request"}
    it "states the groups' coverage of compared tests and of recorded examples" do
      get repository_path(repository)

      stored = NearDuplicateCensus.stored_block_for(repository)
      expect(stored.values_at("clustered_identity_count", "identity_count",
                              "clustered_example_count", "recorded_count")).to eq([2, 3, 4, 5])
      sentence = panel.find("#near-duplicate-clusters-coverage").text(normalize_ws: true)
      expect(sentence).to include("2 of 3 compared tests", "4 of the 5 examples the weighed run recorded")
      expect(panel).to have_css("#near-duplicate-clusters-coverage", count: 1)
      expect(panel).to have_no_css("[data-near-duplicate-cluster] #near-duplicate-clusters-coverage")
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "omit a zero unresolved clause", "behavior": "an unresolved_count of 0 renders no unresolved element and no reached-no-resolvable-text wording", "layer": "request"}
    it "renders no unresolved clause when nothing was unresolved" do
      store(overrides: { "unresolved_count" => 0 })

      get repository_path(repository)

      expect(panel).to have_no_css("#near-duplicate-clusters-unresolved")
      expect(panel.text(normalize_ws: true)).not_to include(no_text)
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "state unresolved examples", "behavior": "a positive unresolved_count renders once, with the count and the matching-runs-after-ingest explanation, outside any cluster", "layer": "request"}
    it "states the unresolved examples once when some were not compared" do
      store(overrides: { "unresolved_count" => 3 })

      get repository_path(repository)

      clause = panel.find("#near-duplicate-clusters-unresolved").text(normalize_ws: true)
      expect(clause).to include("3 examples", no_text, "were not compared", "just after a run lands")
      expect(panel.text(normalize_ws: true).scan(no_text).size).to eq(1)
      expect(panel).to have_no_css("[data-near-duplicate-cluster] #near-duplicate-clusters-unresolved")
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "singularize unresolved clause", "behavior": "an unresolved_count of 1 reads 1 example ... was not compared", "layer": "request"}
    it "uses the singular for one unresolved example" do
      store(overrides: { "unresolved_count" => 1 })

      get repository_path(repository)

      expect(panel.find("#near-duplicate-clusters-unresolved").text(normalize_ws: true))
        .to include("1 example in the weighed run", "was not compared")
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "state unresolved in the clear state", "behavior": "when no group exists but examples were unresolved, the nothing-reads-alike description also names them", "layer": "request"}
    it "appends the unresolved clause to the nothing-reads-alike state" do
      store(overrides: { "unresolved_count" => 3 }, clusters: [])

      get repository_path(repository)

      clear = panel.find("#near-duplicate-clusters-clear").text(normalize_ws: true)
      expect(clear).to include("Nothing reads alike at this floor", "3 examples", no_text)
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "omit unresolved in the clear state at zero", "behavior": "the nothing-reads-alike state names no unresolved examples when the count is 0", "layer": "request"}
    it "keeps the nothing-reads-alike state clean at zero unresolved" do
      store(overrides: { "unresolved_count" => 0 }, clusters: [])

      get repository_path(repository)

      expect(panel.find("#near-duplicate-clusters-clear").text(normalize_ws: true)).not_to include(no_text)
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "degrade missing coverage keys", "behavior": "a stored census lacking the clustered counts and unresolved_count renders neither element and no of-0 figure", "layer": "request"}
    it "renders neither sentence when the stored census lacks the keys" do
      store(drop: %w[clustered_identity_count clustered_example_count unresolved_count])

      get repository_path(repository)

      expect(response).to have_http_status(:ok)
      expect(panel).to have_no_css("#near-duplicate-clusters-coverage")
      expect(panel).to have_no_css("#near-duplicate-clusters-unresolved")
      expect(panel.text(normalize_ws: true)).not_to match(/of 0\b/)
      expect(panel).to have_css("[data-near-duplicate-cluster]", count: 1)
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "keep the page query budget", "behavior": "rendering the coverage and unresolved sentences issues no census or spec_identities query beyond the single stored read", "layer": "request"}
    it "adds no queries for the new sentences" do
      store(overrides: { "unresolved_count" => 3 })

      census_reads = queries_against('FROM "near_duplicate_censuses"') { get repository_path(repository) }
      identity_reads = queries_against("spec_identities") { get repository_path(repository) }

      expect(panel).to have_css("#near-duplicate-clusters-unresolved")
      expect(census_reads.size).to eq(1)
      expect(identity_reads).to be_empty
    end
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

    # @intent: {"entity": "NearDuplicateCensus", "action": "render untimed members", "behavior": "a member with total_seconds nil reads not timed in its own row and never prints a zero duration", "layer": "request"}
    it "says not timed on every member row, never a zero" do
      get repository_path(repository)

      members = NearDuplicateCensus.stored_block_for(repository)["clusters"].sole["members"]
      rows = panel.all("[data-near-duplicate-cluster] [data-near-duplicate-layer-group] > ul > li")
      expect(members.map { |m| m["total_seconds"] }).to all(be_nil)
      expect(rows.size).to eq(members.size)
      rows.each do |row|
        expect(row.text(normalize_ws: true)).to include("not timed")
        expect(row.text).not_to match(/0\.00s|\b0s\b/)
      end
    end
  end

  describe "the four states" do
    # @intent: {"entity": "NearDuplicateCensus", "action": "render no stored row", "behavior": "a repository with no stored census renders the No census yet state with no numeral and no cluster list", "layer": "request"}
    it "(a) no stored row: says no census yet and prints no numeral" do
      record_and_resolve(repository, pair_specs)
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
      record_and_resolve(repository, pair_specs)
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
      expect(panel).to have_css("#near-duplicate-clusters-stamp")
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

  # The page-wide truncation disclosure: a capped list reads as a page, not as the census. The
  # ordering words follow the stored `ranking_basis` (SPGD-1720): a row without it was computed
  # under the old cost-only order and keeps saying so.
  # @intent: {"entity": "NearDuplicateCensus", "action": "disclose a capped list", "behavior": "when the stored census is truncated and carries no ranking_basis the panel states the costliest N of the cluster_count rather than all of them", "layer": "request"}
  it "states a truncated census as a page of the whole" do
    ingest(repository, pair_specs)
    census = NearDuplicateCensus.find_by!(repository_id: repository.id)
    census.update!(payload: census.payload.except("ranking_basis")
                                   .merge("truncated" => true, "cluster_count" => 7))

    get repository_path(repository)

    sentence = panel.find("#near-duplicate-clusters-page").text(normalize_ws: true)
    expect(sentence).to include("The 1 costliest of 7 groups", "a page of the census, not all of it")
    expect(sentence).not_to include("spec file first")
  end

  # @intent: {"entity": "NearDuplicateCensus", "action": "disclose the ranking order", "behavior": "a census stored with ranking_basis says multi-file groups come first, then costliest, and never claims plain costliest-first", "layer": "request"}
  it "states the multi-file-first order only when the stored census carries ranking_basis" do
    ingest(repository, pair_specs)
    census = NearDuplicateCensus.find_by!(repository_id: repository.id)
    expect(census.payload["ranking_basis"]).to eq(NearDuplicateClusters::RANKING_BASIS)
    expect(census.payload.keys.first(4))
      .to eq(%w[similarity_floor similarity_basis layer_source ranking_basis])

    get repository_path(repository)
    sentence = panel.find("#near-duplicate-clusters-page").text(normalize_ws: true)
    expect(sentence).to include("All 1 group of tests that read alike, groups spanning more than one spec file first, then costliest")
    expect(sentence).not_to include("costliest first")

    census.update!(payload: census.payload.merge("truncated" => true, "cluster_count" => 7))
    get repository_path(repository)
    sentence = panel.find("#near-duplicate-clusters-page").text(normalize_ws: true)
    expect(sentence).to include("The 1 top-ranked of 7 groups", "spec file first, then costliest")
    expect(sentence).not_to include("costliest first")
  end

  # @intent: {"entity": "NearDuplicateCensus", "action": "render overlap kind", "behavior": "each row says whether its group spans one spec file or several, from the stored key and, for a payload stored without it, derived from its members", "layer": "request"}
  it "shows the overlap kind per row, derived from members when the key is not stored" do
    ingest(repository, pair_specs)
    census = NearDuplicateCensus.find_by!(repository_id: repository.id)
    cluster = census.payload["clusters"].sole
    expect(cluster["overlap_kind"]).to eq("single_file")

    get repository_path(repository)
    expect(panel.find("[data-near-duplicate-cluster]").text(normalize_ws: true)).to include("one spec file")

    members = cluster["members"]
    moved = members.each_with_index.map { |m, i| i.zero? ? m : m.merge("file_path" => "spec/requests/other_spec.rb") }
    census.update!(payload: census.payload.merge(
      "clusters" => [cluster.except("overlap_kind").merge("members" => moved)]
    ))

    get repository_path(repository)
    expect(panel.find("[data-near-duplicate-cluster]").text(normalize_ws: true))
      .to include("spans more than one spec file")
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

  # The layer cut, rendered from the STORED `layer_groups`. The stored payload is rewritten the way
  # the wording example above does it, but with REAL members in the groups, so a panel printing one
  # layer for every member (or dropping a group) fails.
  describe "the declared-layer cut" do
    before { ingest(repository, pair_specs) }

    let(:census) { NearDuplicateCensus.find_by!(repository_id: repository.id) }
    let(:cluster) { census.payload["clusters"].sole }
    let(:expired_member) { cluster["members"].find { |m| m["text"] == expired } }
    let(:outright_member) { cluster["members"].find { |m| m["text"] == outright } }

    def store_layers(redundancy:, groups:, layer_source: "declared via the intent protocol")
      census.update!(payload: census.payload.merge(
        "layer_source" => layer_source,
        "clusters" => [cluster.merge("layer_redundancy" => redundancy, "layer_groups" => groups)]
      ))
      get repository_path(repository)
    end

    def location(member) = "#{member['file_path']}:#{member['line_number']}"

    def group_text(layer)
      panel.all("[data-near-duplicate-layer-group]").find { |node| node.find("p").text.strip == layer }
           &.text(normalize_ws: true)
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "render the declared layers of a cluster", "behavior": "a cross-layer cluster names both stored layers and lists each member under the layer it was grouped in", "layer": "request"}
    it "names both layers and puts each member under its own layer" do
      store_layers(redundancy: "cross_layer", groups: [
        { "layer" => "request", "members" => [expired_member] },
        { "layer" => "unit", "members" => [outright_member] }
      ])

      text = panel.find("[data-near-duplicate-cluster]").text(normalize_ws: true)
      expect(text).to include("spans 2 declared layers: request, unit")
      expect(group_text("request")).to include(location(expired_member))
      expect(group_text("request")).not_to include(location(outright_member))
      expect(group_text("unit")).to include(location(outright_member))
      expect(group_text("unit")).not_to include(location(expired_member))
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "render member time in layer groups", "behavior": "layer-grouped member rows show the same stored total_seconds, and a member stored untimed reads not timed, through the same partial as the flat list", "layer": "request"}
    it "renders member time identically in layer groups, with not timed for a nil member" do
      untimed = outright_member.merge("total_seconds" => nil)
      store_layers(redundancy: "cross_layer", groups: [
        { "layer" => "request", "members" => [expired_member] },
        { "layer" => "unit", "members" => [expired_member, untimed] }
      ])

      expect(group_text("request")).to include(SpecObservation.humanized_duration(expired_member["total_seconds"]))
      expect(group_text("unit")).to include(SpecObservation.humanized_duration(expired_member["total_seconds"]))
      untimed_row = panel.all("[data-near-duplicate-layer-group] li", text: location(untimed)).sole
      expect(untimed_row.text(normalize_ws: true)).to include("not timed")
      expect(untimed_row.text).not_to match(/0\.00s|\b0s\b/)
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "render a member declaring two layers", "behavior": "a member stored in two layer groups renders under both, and the undeclared group reads no layer declared with its members", "layer": "request"}
    it "renders a two-layer member under both and the undeclared group as text" do
      store_layers(redundancy: "cross_layer", groups: [
        { "layer" => "request", "members" => [expired_member] },
        { "layer" => "unit", "members" => [expired_member] },
        { "layer" => nil, "members" => [outright_member] }
      ])

      expect(group_text("request")).to include(location(expired_member))
      expect(group_text("unit")).to include(location(expired_member))
      expect(group_text("no layer declared")).to include(location(outright_member))
      expect(panel.all("[data-near-duplicate-cluster] li", text: location(expired_member)).size).to eq(2)
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "state layer provenance", "behavior": "a census with a layer_source states once that layers are declared and never inferred from paths, not once per cluster", "layer": "request"}
    it "states the declared-not-inferred provenance once for the panel" do
      other = cluster.merge("layer_redundancy" => "same_layer",
                            "layer_groups" => [{ "layer" => "unit", "members" => cluster["members"] }])
      census.update!(payload: census.payload.merge(
        "layer_source" => "declared via the intent protocol",
        "clusters" => [cluster.merge("layer_redundancy" => "same_layer",
                                     "layer_groups" => [{ "layer" => "unit", "members" => cluster["members"] }]),
                       other]
      ))

      get repository_path(repository)

      expect(panel.all("[data-near-duplicate-cluster]").size).to eq(2)
      expect(panel.all("#near-duplicate-clusters-layer-source").size).to eq(1)
      expect(panel.text(normalize_ws: true).scan("never inferred from file paths").size).to eq(1)
    end

    # @intent: {"entity": "NearDuplicateCensus", "action": "render a layer-free census", "behavior": "a census whose layer_source is nil and whose clusters declared nothing renders no layer name, no declared wording and no no-layer-declared text", "layer": "request"}
    it "renders no layer text when the suite declared nothing" do
      store_layers(redundancy: nil, layer_source: nil, groups: [
        { "layer" => nil, "members" => cluster["members"] }
      ])

      row = panel.find("[data-near-duplicate-cluster]")
      expect(row.text(normalize_ws: true)).to include(location(expired_member), location(outright_member))
      # The console's table has a Layers column, so a group that declared nothing says exactly that —
      # "none declared" — and names no layer and carries no layer provenance sentence.
      expect(row.all("td")[4].text(normalize_ws: true)).to eq("none declared")
      expect(row.text(normalize_ws: true)).not_to match(/\b(unit|integration|request|system)\b/i)
      expect(panel).to have_no_css("#near-duplicate-clusters-layer-source")
      expect(panel.all("[data-near-duplicate-layer-group] p.rc-h")).to be_empty
      expect(panel.text(normalize_ws: true)).not_to include("as declared by each test")
    end
  end
end
