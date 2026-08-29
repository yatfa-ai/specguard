# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 — Bearer authentication", type: :request do
  let(:repository) { create_repository }
  let(:api_key) { repository.api_keys.create! }

  # @intent: { entity: "Repository", action: "authenticate a request", behavior: "a Bearer token carrying a valid repository key resolves to that repository and the body reports its full name over HTTP 200", layer: "request" }
  it "resolves the repository behind a valid Bearer key" do
    get "/api/v1/repository", headers: { "Authorization" => "Bearer #{api_key.raw_token}" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("repository", "full_name")).to eq("acme/billing-service")
  end

  # @intent: { entity: "ApiKey", action: "stamp last use", behavior: "authenticating with the Bearer key writes last_used_at, which is nil before the request and present after it", layer: "request" }
  it "records when the key was last used" do
    expect(api_key.last_used_at).to be_nil

    get "/api/v1/repository", headers: { "Authorization" => "Bearer #{api_key.raw_token}" }

    expect(api_key.reload.last_used_at).to be_present
  end

  # @intent: { entity: "ApiKey", action: "refuse an unknown token", behavior: "an unrecognized Bearer token answers HTTP 401 with an unauthorized JSON error rather than any repository data", layer: "request" }
  it "rejects a bad key with 401" do
    get "/api/v1/repository", headers: { "Authorization" => "Bearer sgk_definitely-not-a-key" }

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body["error"]).to eq("unauthorized")
  end

  # @intent: { entity: "ApiKey", action: "refuse a missing header", behavior: "a request carrying no Authorization header at all is turned away with HTTP 401 before any lookup happens", layer: "request" }
  it "rejects a missing Authorization header with 401" do
    get "/api/v1/repository"

    expect(response).to have_http_status(:unauthorized)
  end

  # @intent: { entity: "ApiKey", action: "refuse a non-Bearer scheme", behavior: "a token sent under a scheme other than Bearer, such as Basic, is refused with HTTP 401 even though the credential itself is valid", layer: "request" }
  it "rejects a non-Bearer scheme with 401" do
    get "/api/v1/repository", headers: { "Authorization" => "Basic #{api_key.raw_token}" }

    expect(response).to have_http_status(:unauthorized)
  end

  # @intent: { entity: "Repository", action: "scope the response", behavior: "each repository key sees only the repository it was minted for, so a second repository answers under its own name when reached with its own key", layer: "request" }
  it "scopes the response to the key's own repository" do
    other = create_repository(user: create_user(github_uid: "2002", github_handle: "hubot"),
                              github_full_name: "acme/ledger")
    other_key = other.api_keys.create!

    get "/api/v1/repository", headers: { "Authorization" => "Bearer #{other_key.raw_token}" }

    expect(response.parsed_body.dig("repository", "full_name")).to eq("acme/ledger")
  end

  # ⭐ SPGD-816. The retention disclosure is ADDED BESIDE the anchor's existing keys, and this is the
  # example that says the addition cost nothing: `run_anchor` grew by exactly two keys, no other
  # block grew or shrank at all, and every pre-existing key kept its name, its type and its value.
  #
  # Asserted as an EXACT key set on both levels rather than key by key, on `repository_latest_run_
  # spec`'s rule for the top level: `include` would pass a third key added by accident, and
  # `have_key` would pass a key silently dropped. Bidirectional or it is not a contract.
  describe "the retention disclosure on run_anchor" do
    let(:headers) { { "Authorization" => "Bearer #{api_key.raw_token}" } }

    def anchor_for(query = {})
      get "/api/v1/repository", params: query, headers: headers
      response.parsed_body
    end

    # @intent: { entity: "run_anchor", action: "disclose retention", behavior: "the retention disclosure adds exactly observations_retained and retention_runs beside the five pre-existing run_anchor keys, each unchanged in name, type and value", layer: "request" }
    it "adds exactly two keys to run_anchor and leaves the other five as they were" do
      run = create_test_run(repository: repository, branch: "main", commit_sha: "feedfacecafe",
                            total_specs_count: 12)

      anchor = anchor_for["run_anchor"]

      expect(anchor.keys).to contain_exactly("source", "requested_commit_sha", "resolved",
                                             "commit_sha", "branch",
                                             "observations_retained", "retention_runs")
      # The five, unchanged in name, type and value — a default call is what it always was.
      expect(anchor.slice("source", "requested_commit_sha", "resolved", "commit_sha", "branch"))
        .to eq("source" => "default", "requested_commit_sha" => nil, "resolved" => true,
               "commit_sha" => run.commit_sha, "branch" => "main")
    end

    # The addition is local to `run_anchor`. Every other block is untouched, which is the half an
    # example that only read `run_anchor` could not see.
    # @intent: { entity: "run_anchor", action: "contain the disclosure", behavior: "the two new keys appear on run_anchor only; latest_run and the delivery_health rejections window keep their original key sets untouched", layer: "request" }
    it "leaves every other block's keys exactly where they were" do
      create_test_run(repository: repository, branch: "main", total_specs_count: 12)

      body = anchor_for

      expect(body["latest_run"].keys).not_to include("observations_retained", "retention_runs")
      expect(body["delivery_health"]["rejections_window"].keys)
        .to contain_exactly("limit", "bounded", "retention_rows", "any_reasons_truncated")
    end

    # ⭐ THE DEFECT ITSELF, pinned as the direct comparison the ticket asks for. Before this key
    # existed these two responses were byte-identical in every respect a client could act on: a run
    # that RESOLVED and whose per-example rows aged out, and a run that genuinely RECORDED NOTHING.
    # Both resolve, both report a run, and every per-example rollup under both returns zero rows —
    # so the confident reading ("this suite has no slow tests") was indistinguishable from the
    # retention reading ("this suite's slow tests are no longer on file").
    #
    # `total_specs_count` is deliberately EQUAL on the two sides. The point is not that the runs
    # differ — it is that the RETENTION STATE differs and used to be unsayable, so anything the two
    # bodies disagree about here is the disclosure doing its job and nothing else.
    # @intent: { entity: "run_anchor", action: "separate retention states", behavior: "a resolved run whose per-example rows aged out of branch retention reports observations_retained false while an in-window run reports true, so the two retention states are distinguishable at the wire", layer: "request" }
    it "no longer serializes an aged-out run identically to one that recorded nothing" do
      stub_const("SpecObservation::BRANCH_RETENTION_RUNS", 3)
      start = 100.days.ago

      # Five runs on `main`: the oldest is strictly past the boundary, so the rule no longer keeps
      # its rows. It measured a suite — `total_specs_count` says 12 — and still says so.
      aged_out = create_test_run(repository: repository, branch: "main", commit_sha: "a" * 12,
                                 created_at: start, total_specs_count: 12)
      4.times do |i|
        create_test_run(repository: repository, branch: "main", commit_sha: "b#{i}#{'0' * 10}",
                        created_at: start + (i + 1).minutes, total_specs_count: 12)
      end
      # A run on its own branch, well inside the window, whose rows were never pruned.
      inside = create_test_run(repository: repository, branch: "quiet", commit_sha: "c" * 12,
                               created_at: start + 10.minutes, total_specs_count: 12)

      aged_body = anchor_for(commit_sha: aged_out.commit_sha)["run_anchor"]
      inside_body = anchor_for(commit_sha: inside.commit_sha)["run_anchor"]

      # Both resolved, both measured the same suite size — every axis that existed before today
      # agrees, which is exactly why the conflation survived.
      expect(aged_body["resolved"]).to be(true)
      expect(inside_body["resolved"]).to be(true)
      expect(aged_out.total_specs_count).to eq(inside.total_specs_count)

      # And the one axis that now separates them.
      expect(aged_body["observations_retained"]).to be(false)
      expect(inside_body["observations_retained"]).to be(true)
      expect(aged_body).not_to eq(inside_body)
    end
  end
end
