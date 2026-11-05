# frozen_string_literal: true

require "rails_helper"

# `?compare_to=<branch>` on the repository-overview API (SPGD-2009): SPGD-1981's explicit,
# labelled cross-branch baseline brought to every run-pair growth block the endpoint serves. The
# default comparison — `Repository#previous_test_run_on_branch`, the newest same-branch
# predecessor — is untouched and stays the only baseline any un-asked response draws; this
# parameter swaps `RepositoryOverview#previous_test_run` for `Repository#
# baseline_test_run_on_branch`'s row (the newest run on the NAMED branch at or before the run
# being read), and every run-pair window block that would have claimed `previous_run_on_branch`
# names `named_branch_baseline` and carries the ask instead.
#
# What this file guards that the model specs cannot:
#
#   * THE DEAD END ENDS. A PR branch whose CI has reported once has no same-branch predecessor,
#     so this is the first comparison the API can offer such a client at all — every run-pair
#     block reads against the asked branch's run, on both the count and the time axis, including
#     the two per-file drill-ins.
#   * NO SILENT FALLBACK. A missed ask (no run at or before this one on the named branch) is
#     `baseline_unavailable`, stated with the raw ask echoed, never substituted away — even when
#     a same-branch predecessor EXISTS and would have been comparable.
#   * BYTE IDENTITY. A same-branch ask is the comparison the default already makes, so it answers
#     byte-for-byte what no parameter answers; so do every malformed shape the guard treats as no
#     ask.
#   * THE ANCHOR COMPOSES. `?commit_sha=` picks the run, `?compare_to=` picks what it is measured
#     against; the two asks ride one request without redefining each other, the way the console's
#     `?branch=`/`?compare_to=` pair does.
#   * NOTHING COSTS MORE. The swap replaces one baseline lookup with another and adds no read:
#     an honoured ask costs exactly what a comparable same-branch response costs, and an
#     un-asked response is untouched.
RSpec.describe "GET /api/v1/repository — ?compare_to= explicit cross-branch baseline", type: :request do
  include FreshKeyRepositoryReads

  include ActiveSupport::Testing::TimeHelpers

  API_MAIN_SHA = "main0000000001"
  API_OLDER_MAIN_SHA = "oldermain000001"
  API_PR_SHA = "pr00000000000001"
  API_FEAT_OLD_SHA = "featold00000001"

  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }

  # The raw response bytes, for the byte-identity pins. Every call mints its own key, so no
  # `last_used_at` from an earlier request can leak into a later body; the calls inside one
  # byte-identity pin run under one frozen clock so the per-request auth stamp is the same
  # instant in both bodies rather than the wall clock's.
  def raw_body_of(query: {})
    token = repository.api_keys.create!.raw_token
    get "/api/v1/repository", params: query, headers: { "Authorization" => "Bearer #{token}" }

    response.body
  end

  def byte_identical_bodies(with_params:)
    freeze_time
    raw_body_of
    without_ask = raw_body_of
    with_ask = raw_body_of(query: with_params)
    unfreeze_time

    expect(with_ask).to eq(without_ask)
  end

  def ingest(specs, commit_sha:, at:, repo: repository, branch: "main", duration: 60.0)
    run = Ingest::RunRecorder.record(
      repo,
      { commit_sha: commit_sha, branch: branch, total_specs_count: specs.size,
        annotated_specs_count: 0, duration_seconds: duration },
      specs: specs.map(&:deep_stringify_keys)
    )
    TestRun.where(id: run.id).update_all(created_at: at)
    run
  end

  def area_specs(directory, count, each: 1.0, offset: 0, layer: nil)
    Array.new(count) do |i|
      line = offset + i + 1
      if layer
        annotated_spec(file_path: "#{directory}/a_spec.rb", line_number: line, duration: each,
                       layer: layer, name: "#{layer} example #{offset + i}")
      else
        unannotated_spec(file_path: "#{directory}/a_spec.rb", line_number: line, duration: each)
      end
    end
  end

  # The ticket's headline fixture, in two shapes. MAIN runs are older than the PR run in both;
  # the PR branch has ONE run of its own, so the same-branch predecessor the default falls back
  # to does not exist. The layered shape gives both runs a declared `unit` mix and real
  # durations, so the two time-axis blocks are comparable too.
  def first_run_pr_branch(with_layers: false)
    ingest(area_specs("spec/models", 3) +
           (with_layers ? area_specs("spec/models", 2, each: 2.0, offset: 50, layer: "unit") : []),
           commit_sha: API_MAIN_SHA, at: 2.hours.ago, branch: "main", duration: 90.0)
    ingest(area_specs("spec/models", 5, offset: 300) +
           (with_layers ? area_specs("spec/models", 1, each: 3.0, offset: 350, layer: "unit") : []),
           commit_sha: API_PR_SHA, at: 1.minute.ago, branch: "feature", duration: 510.0)
  end

  describe "a first run on a PR branch, measured against main by ask" do
    # @intent: { entity: "layer_run_growth", action: "serve the asked baseline", behavior: "a first feature run asked against main serves comparable layer blocks under basis named_branch_baseline naming main's run as baseline_commit_sha with the raw ask echoed", layer: "request" }
    it "reads the declared-layer mix against main's run and names the ask" do
      first_run_pr_branch(with_layers: true)

      body = get_repository(query: { compare_to: "main" })

      expect(body["layer_run_growth_window"]).to include(
        "basis" => "named_branch_baseline", "branch" => "feature", "state" => "comparable",
        "comparable" => true, "anchor_commit_sha" => API_PR_SHA, "baseline_commit_sha" => API_MAIN_SHA,
        "baseline_branch" => "main", "requested_compare_to" => "main"
      )
      # 2 unit examples on main against 1 on the PR branch — a delta the dead-ending default
      # could never show.
      expect(body["layer_run_growth"]["layers"]["unit"])
        .to eq("baseline_count" => 2, "anchor_count" => 1, "change" => -1)
    end

    # @intent: { entity: "directory_run_growth", action: "serve the asked baseline", behavior: "the area run-pair pair reads against main's run under the new basis with the ask echoed, on both the count and the time axis", layer: "request" }
    it "reads the area growth against main's run on both the count and the time axis" do
      first_run_pr_branch(with_layers: true)

      body = get_repository(query: { compare_to: "main" })

      %w[directory_run_growth_window directory_runtime_growth_window].each do |key|
        expect(body[key]).to include(
          "basis" => "named_branch_baseline", "branch_scope" => "single_branch",
          "state" => "comparable", "comparable" => true, "anchor_commit_sha" => API_PR_SHA,
          "baseline_commit_sha" => API_MAIN_SHA, "baseline_branch" => "main",
          "requested_compare_to" => "main"
        )
      end
      # spec/models: 5 examples on main, 6 on the PR branch; 7.0s on main, 8.0s on the PR branch.
      expect(body["directory_run_growth"]["rows"].sole).to include(
        "path" => "spec/models", "baseline_count" => 5, "anchor_count" => 6, "change" => 1
      )
      expect(body["directory_runtime_growth"]["rows"].sole).to include(
        "path" => "spec/models", "baseline_seconds" => 7.0, "anchor_seconds" => 8.0, "change" => 1.0
      )
    end

    # @intent: { entity: "directory_run_file_growth", action: "carry the ask into the drill-ins", behavior: "both per-file run-pair windows flip to the named basis and echo the ask while still spelling no operand their parent block already served", layer: "request" }
    it "carries the ask into the per-file drill-ins without re-spelling the operands" do
      first_run_pr_branch(with_layers: true)

      body = get_repository(query: { compare_to: "main", spec_directory: "spec/models" })

      %w[directory_run_file_growth_window directory_runtime_file_growth_window].each do |key|
        expect(body[key]).to include(
          "basis" => "named_branch_baseline", "state" => "comparable", "comparable" => true,
          "baseline_branch" => "main", "requested_compare_to" => "main"
        )
        # The operands stay the parent area block's, spelled once — under an ask exactly as
        # without one.
        expect(body[key]).not_to have_key("anchor_commit_sha")
        expect(body[key]).not_to have_key("baseline_commit_sha")
      end
      expect(body["directory_run_file_growth"]["rows"].sole).to include(
        "path" => "spec/models/a_spec.rb", "baseline_count" => 5, "anchor_count" => 6, "change" => 1
      )
      expect(body["directory_runtime_file_growth"]["rows"].sole).to include(
        "path" => "spec/models/a_spec.rb", "baseline_seconds" => 7.0, "anchor_seconds" => 8.0
      )
    end

    # @intent: { entity: "layer_runtime_growth", action: "serve the asked baseline on the time axis", behavior: "the layer time pair reads unit against main's run under the named basis with the ask echoed", layer: "request" }
    it "reads the layer time movement against main's run" do
      first_run_pr_branch(with_layers: true)

      body = get_repository(query: { compare_to: "main" })

      expect(body["layer_runtime_growth_window"]).to include(
        "basis" => "named_branch_baseline", "state" => "comparable", "comparable" => true,
        "baseline_branch" => "main", "requested_compare_to" => "main"
      )
      expect(body["layer_runtime_growth"]["layers"]["unit"]).to include(
        "baseline_seconds" => 4.0, "anchor_seconds" => 3.0, "change" => -1.0
      )
    end

    # The swap happens ABOVE the growth gates — `previous_test_run` is re-pointed, the gates are
    # the same ones the same-branch pair has always answered to — so a cross-branch pair that is
    # not assembled alike is refused with the sentence the same-branch pair has always had.
    # @intent: { entity: "layer_run_growth", action: "refuse a bad cross-branch pair", behavior: "a cross-branch pair assembled over different shard counts serves assembled_differently with the ask echoed and no rows", layer: "request" }
    it "refuses a cross-branch pair assembled differently with the existing state" do
      repository
      main = ingest(area_specs("spec/models", 3), commit_sha: API_MAIN_SHA, at: 2.hours.ago)
      2.times { |i| main.test_run_shards.create!(shard_id: i.to_s, total_specs_count: 2) }
      ingest(area_specs("spec/models", 5, offset: 300), commit_sha: API_PR_SHA, at: 1.minute.ago,
                                                          branch: "feature")

      body = get_repository(query: { compare_to: "main" })

      expect(body["layer_run_growth_window"]).to include(
        "basis" => "named_branch_baseline", "state" => "assembled_differently", "comparable" => false,
        "baseline_branch" => "main", "requested_compare_to" => "main"
      )
      expect(body["layer_run_growth"]).to be_nil
    end
  end

  describe "an ask that cannot be honoured" do
    # The miss is stated, never substituted away — and this is pinned against the sharpest
    # fallback temptation there is: the PR branch has a same-branch predecessor here, so a
    # fallback WOULD have produced a comparable pair.
    # @intent: { entity: "layer_run_growth", action: "state a missed ask", behavior: "compare_to naming a branch with no run at or before the anchored run serves baseline_unavailable with the ask echoed and no fallback to the comparable same-branch predecessor", layer: "request" }
    it "serves baseline_unavailable with no fallback to the same-branch predecessor" do
      ingest(area_specs("spec/models", 3), commit_sha: API_FEAT_OLD_SHA, at: 2.hours.ago, branch: "feature")
      ingest(area_specs("spec/models", 5, offset: 300), commit_sha: API_PR_SHA, at: 1.minute.ago,
                                                          branch: "feature")

      body = get_repository(query: { compare_to: "stale" })

      %w[layer_run_growth_window layer_runtime_growth_window directory_run_growth_window
         directory_runtime_growth_window].each do |key|
        expect(body[key]).to include(
          "basis" => "named_branch_baseline", "state" => "baseline_unavailable",
          "comparable" => false, "baseline_commit_sha" => nil, "baseline_branch" => "stale",
          "requested_compare_to" => "stale"
        )
      end
      expect(body["layer_run_growth"]).to be_nil
      expect(body["layer_runtime_growth"]).to be_nil
      expect(body["directory_run_growth"]).to be_nil
      expect(body["directory_runtime_growth"]).to be_nil
    end

    # @intent: { entity: "directory_run_file_growth", action: "state a missed ask in the drill-ins", behavior: "both per-file run-pair windows serve baseline_unavailable with the ask echoed under a asked spec_directory", layer: "request" }
    it "states the miss in the per-file drill-ins" do
      first_run_pr_branch

      body = get_repository(query: { compare_to: "stale", spec_directory: "spec/models" })

      %w[directory_run_file_growth_window directory_runtime_file_growth_window].each do |key|
        expect(body[key]).to include(
          "basis" => "named_branch_baseline", "state" => "baseline_unavailable",
          "comparable" => false, "baseline_branch" => "stale", "requested_compare_to" => "stale"
        )
      end
      expect(body["directory_run_file_growth"]).to be_nil
      expect(body["directory_runtime_file_growth"]).to be_nil
    end

    # The ask compares a run against a branch, so without an anchored run there is nothing to be
    # "other than" — the ask does not participate and the fundamental fact is served unchanged.
    # @intent: { entity: "layer_run_growth", action: "ignore the ask without an anchored run", behavior: "compare_to on a repository CI never reported on serves no_latest_run with no echo and no baseline keys", layer: "request" }
    it "does not participate when CI has never reported" do
      body = get_repository(query: { compare_to: "main" })

      expect(body["layer_run_growth_window"]).to include(
        "basis" => "previous_run_on_branch", "state" => "no_latest_run", "comparable" => false,
        "anchor_commit_sha" => nil, "baseline_commit_sha" => nil
      )
      expect(body["layer_run_growth_window"]).not_to have_key("requested_compare_to")
      expect(body["layer_run_growth_window"]).not_to have_key("baseline_branch")
      expect(body["layer_run_growth"]).to be_nil
    end
  end

  describe "the asks that compose" do
    # OLDER_MAIN is the run of main "as of" the anchored PR run; MAIN is NEWER than the anchor
    # and must NOT be drawn as the baseline — substituting it would answer "did my PR change the
    # suite versus main now" for a question asked about then.
    # @intent: { entity: "layer_run_growth", action: "compose commit_sha with compare_to", behavior: "anchoring on the PR run by commit_sha with compare_to main baselines against the newest main run at or before it, not the newer one", layer: "request" }
    it "measures the commit_sha-anchored run against the named branch as of that run" do
      ingest(area_specs("spec/models", 2), commit_sha: API_OLDER_MAIN_SHA, at: 4.hours.ago)
      ingest(area_specs("spec/models", 3, offset: 400), commit_sha: API_PR_SHA, at: 3.hours.ago,
                                                          branch: "feature")
      ingest(area_specs("spec/models", 4, offset: 800), commit_sha: API_MAIN_SHA, at: 1.minute.ago)

      body = get_repository(query: { commit_sha: API_PR_SHA, compare_to: "main" })

      expect(body["run_anchor"]).to include("commit_sha" => API_PR_SHA, "resolved" => true)
      expect(body["latest_run"]["commit_sha"]).to eq(API_PR_SHA)
      expect(body["layer_run_growth_window"]).to include(
        "basis" => "named_branch_baseline", "branch" => "feature", "state" => "comparable",
        "comparable" => true, "anchor_commit_sha" => API_PR_SHA, "baseline_commit_sha" => API_OLDER_MAIN_SHA,
        "baseline_branch" => "main", "requested_compare_to" => "main"
      )
      expect(body["layer_run_growth"]).to be_present
    end

    # The contrast half of the composition: the same anchor without the ask stays the dead end,
    # so the comparable block above came from the ask and not from the anchor.
    # @intent: { entity: "layer_run_growth", action: "keep the anchor from implying the baseline", behavior: "the same commit_sha anchor without compare_to serves no_previous_run because the anchored branch has one run", layer: "request" }
    it "stays the same-branch dead end when the same anchor carries no ask" do
      ingest(area_specs("spec/models", 2), commit_sha: API_OLDER_MAIN_SHA, at: 4.hours.ago)
      ingest(area_specs("spec/models", 3, offset: 400), commit_sha: API_PR_SHA, at: 3.hours.ago,
                                                          branch: "feature")
      ingest(area_specs("spec/models", 4, offset: 800), commit_sha: API_MAIN_SHA, at: 1.minute.ago)

      body = get_repository(query: { commit_sha: API_PR_SHA })

      expect(body["layer_run_growth_window"]).to include(
        "basis" => "previous_run_on_branch", "state" => "no_previous_run", "comparable" => false,
        "anchor_commit_sha" => API_PR_SHA
      )
      expect(body["layer_run_growth_window"]).not_to have_key("requested_compare_to")
    end
  end

  describe "the paths that must not change" do
    # The same-branch ask IS the comparison the default makes, so it answers byte-for-byte what
    # no parameter answers.
    # @intent: { entity: "layer_run_growth", action: "absorb a same-branch ask", behavior: "compare_to naming the anchored run's own branch answers byte-for-byte what no parameter answers", layer: "request" }
    it "renders a same-branch ask byte-for-byte as no ask" do
      ingest(area_specs("spec/models", 3), commit_sha: API_FEAT_OLD_SHA, at: 2.hours.ago, branch: "feature")
      ingest(area_specs("spec/models", 5, offset: 300), commit_sha: API_PR_SHA, at: 1.minute.ago,
                                                          branch: "feature")

      byte_identical_bodies(with_params: { compare_to: "feature" })
    end

    # @intent: { entity: "layer_run_growth", action: "absorb a blank ask", behavior: "a blank compare_to answers byte-for-byte what no parameter answers", layer: "request" }
    it "renders a blank ask byte-for-byte as no ask" do
      first_run_pr_branch

      byte_identical_bodies(with_params: { compare_to: "" })
    end

    # The shapes a query string can legally parse into that are NOT a branch name, pinned against
    # the byte-identical default on the same reasoning the malformed-branch shared example pins
    # its surfaces: only the positive path separates a guard from a swallow.
    def expect_compare_to_param_treated_as_no_ask(query)
      first_run_pr_branch

      byte_identical_bodies(with_params: query)
    end

    it_behaves_like "a surface that treats a malformed compare_to parameter as no ask"

    # The parameter machinery must cost an un-asked call nothing: the classification memos are
    # decided from params and the already-memoized anchor, so the only previous-run lookup on an
    # un-asked response is the same-branch one that was always there.
    # @intent: { entity: "layer_run_growth", action: "cost an un-asked call nothing", behavior: "an un-asked comparable response issues the row-value previous-run lookup exactly once and no created_at lookup at all", layer: "request" }
    it "issues only the same-branch lookup on an un-asked response" do
      ingest(area_specs("spec/models", 3), commit_sha: API_FEAT_OLD_SHA, at: 2.hours.ago, branch: "feature")
      ingest(area_specs("spec/models", 5, offset: 300), commit_sha: API_PR_SHA, at: 1.minute.ago,
                                                          branch: "feature")
      get_repository

      statements = executed_sql { get_repository }

      expect(statements.grep(/\(test_runs\.created_at, test_runs\.id\) < /).length).to eq(1)
      expect(statements.grep(/created_at <=/)).to be_empty
    end

    # And the swap REPLACES the lookup rather than adding one: an honoured cross-branch ask
    # costs exactly what a comparable same-branch response costs, one baseline lookup either way.
    # @intent: { entity: "layer_run_growth", action: "swap the lookup without adding one", behavior: "an honoured cross-branch ask issues the created_at named-branch lookup exactly once and costs the same total as a comparable same-branch response", layer: "request" }
    it "costs a comparable same-branch response exactly the same total under an honoured ask" do
      ingest(area_specs("spec/models", 3), commit_sha: API_FEAT_OLD_SHA, at: 2.hours.ago, branch: "feature")
      ingest(area_specs("spec/models", 5, offset: 300), commit_sha: API_PR_SHA, at: 1.minute.ago,
                                                          branch: "feature")
      get_repository
      same_branch_cost = count_queries { get_repository }

      repository
      first_run_pr_branch(with_layers: true)
      get_repository(query: { compare_to: "main" })

      expect(count_queries { get_repository(query: { compare_to: "main" }) }).to eq(same_branch_cost)
      statements = executed_sql { get_repository(query: { compare_to: "main" }) }
      expect(statements.grep(/created_at <=/).length).to eq(1)
      expect(statements.grep(/\(test_runs\.created_at, test_runs\.id\) < /)).to be_empty
    end
  end

  describe "the plural endpoint" do
    # The ask reaches `GET /api/v1/repositories/:id` through the same overview object, so a
    # person key reading a repository gets the same contract the `sgk_` key route serves.
    # @intent: { entity: "layer_run_growth", action: "serve the ask on the plural route", behavior: "GET repositories/:id under a person key reads a first feature run against main under the named basis with the ask echoed", layer: "request" }
    it "serves the ask on GET /api/v1/repositories/:id for a person key" do
      first_run_pr_branch(with_layers: true)
      user_key = create_user_api_key(user: @user)

      get "/api/v1/repositories/#{repository.id}", params: { compare_to: "main" },
                                                   headers: { "Authorization" => "Bearer #{user_key.raw_token}" }

      body = response.parsed_body
      expect(response).to have_http_status(:ok)
      expect(body["layer_run_growth_window"]).to include(
        "basis" => "named_branch_baseline", "state" => "comparable", "comparable" => true,
        "anchor_commit_sha" => API_PR_SHA, "baseline_commit_sha" => API_MAIN_SHA,
        "baseline_branch" => "main", "requested_compare_to" => "main"
      )
      expect(body["layer_run_growth"]).to be_present
    end
  end
end
