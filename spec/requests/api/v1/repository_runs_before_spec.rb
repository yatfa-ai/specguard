# frozen_string_literal: true

require "rails_helper"

# `?runs_before=<run id>` on the repository-overview API (SPGD-2020): the console's keyset cursor
# (SPGD-1984) brought to the routes that serve `history`.
#
# The gap this closes: `history` is a hard-capped window (10 unfiltered, 30 under `?branch=`) and
# `history_window` served only `limit`/`returned`, so a run older than the newest 10/30 was
# unnameable over the API — and so unreachable by `DELETE …/runs/:id` (SPGD-2014) and `?run=<id>`
# (SPGD-2018), both of which take an id. The cursor makes the whole series walkable.
#
# What this file guards:
#
#   * THE KEYSET CONTINUES EXACTLY. Page two shares no id with page one and leaves no gap, a
#     same-`created_at` tie pair at the boundary included — the failure a bare `created_at <` (skips
#     the tie) or `<=` (repeats the cursor) would produce.
#   * THE WALK TERMINATES AND ENUMERATES. Following `history_window.next_runs_before` until it is
#     `null` visits every run exactly once, checked against `repository.test_runs.count`.
#   * `?branch=` COMPOSES. The branch predicate rides with the keyset, paging one branch's series
#     past its 30 cap; `total_count` counts the same scope.
#   * A MISS IS DISCLOSED. An unknown or foreign id is no cursor, observable as
#     `runs_before_resolved: false`, and answers the unfiltered window.
#   * MALFORMED IS NO ASK, with `requested_runs_before: null` (the guard's answer is the one
#     echoed).
#   * THE CURSOR MOVES `history` ONLY. The window-grain blocks and `latest_run` stay on the newest
#     runs, so a paged body is never a mix of anchors.
#   * NO CURSOR, NO COST BEYOND ONE COUNT.
RSpec.describe "GET /api/v1/repository — ?runs_before= pages history", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:repository) { create_repository }
  let(:api_key) { repository.api_keys.create! }

  def get_repository(query: {})
    get "/api/v1/repository", params: query, headers: { "Authorization" => "Bearer #{api_key.raw_token}" }

    response.parsed_body
  end

  def history_ids(body) = body["history"].map { |row| row["id"] }

  # `count` runs, one per minute, NEWEST FIRST (index 0 is the newest).
  def seed_runs(count, branch: "main", prefix: "pg")
    Array.new(count) do |i|
      create_test_run(repository: repository, commit_sha: format("#{prefix}%04d", i),
                      branch: branch, created_at: (i + 1).minutes.ago)
    end
  end

  describe "the keyset continuation" do
    # @intent: { entity: "History window", action: "continue past the cap without overlap or gap", behavior: "?runs_before=<id of history[9]> answers the runs strictly older than it, repeating none of page one and skipping none, with a same-created_at pair straddling the page boundary neither repeated nor skipped", layer: "request" }
    it "continues newest-first exactly, ties at the boundary included" do
      runs = seed_runs(25)
      # The boundary is where ties land. runs[9] and runs[10] share ONE instant; the ordering is
      # `(created_at, id) DESC`, so the higher id (runs[10]) closes page one and the lower id
      # (runs[9]) opens page two — the pair a bare `created_at <` would skip and a bare `<=` would
      # repeat the cursor for.
      TestRun.where(id: [runs[9].id, runs[10].id]).update_all(created_at: 10.minutes.ago)
      expected_first = runs.first(9) + [runs[10]]
      expected_second = [runs[9]] + runs[11, 9]

      first = get_repository
      expect(history_ids(first)).to eq(expected_first.map(&:id))
      cursor = first["history_window"]["next_runs_before"]
      expect(cursor).to eq(runs[10].id)

      second = get_repository(query: { runs_before: cursor.to_s })

      expect(response).to have_http_status(:ok)
      expect(history_ids(second)).to eq(expected_second.map(&:id))
      expect(history_ids(second) & history_ids(first)).to be_empty
      expect(second["history_window"]).to include(
        "before" => cursor, "requested_runs_before" => cursor, "runs_before_resolved" => true,
        "limit" => 10, "returned" => 10, "next_runs_before" => second["history"].last["id"]
      )
    end

    # @intent: { entity: "History window", action: "walk the whole series", behavior: "following next_runs_before from the newest page until it is null lists every run of the repository exactly once and ends on a short page", layer: "request" }
    it "enumerates every run exactly once by following next_runs_before until null" do
      seed_runs(23)
      seen = []
      query = {}
      pages = 0

      loop do
        body = get_repository(query: query)
        seen.concat(history_ids(body))
        pages += 1
        cursor = body["history_window"]["next_runs_before"]
        break if cursor.nil?

        query = { runs_before: cursor.to_s }
        raise "walk did not terminate" if pages > 10
      end

      expect(seen).to match_array(repository.test_runs.pluck(:id))
      expect(seen.uniq).to eq(seen)
      expect(pages).to eq(3)
    end

    # A page that is exactly full and ends exactly at the oldest run still answers a cursor; the
    # next request is an empty page whose own cursor is null, so the walk still ends.
    # @intent: { entity: "History window", action: "end the walk after an exactly-full last page", behavior: "when the series length is a multiple of the limit the final cursor answers an empty page with next_runs_before null and every run listed once", layer: "request" }
    it "ends on an empty page when the series is an exact multiple of the limit" do
      runs = seed_runs(20)

      second = get_repository(query: { runs_before: runs[9].id.to_s })
      expect(history_ids(second)).to eq(runs[10, 10].map(&:id))
      expect(second["history_window"]["next_runs_before"]).to eq(runs[19].id)

      third = get_repository(query: { runs_before: runs[19].id.to_s })
      expect(third["history"]).to eq([])
      expect(third["history_window"]).to include("returned" => 0, "next_runs_before" => nil,
                                                 "runs_before_resolved" => true)
    end
  end

  describe "total_count and the always-present keys" do
    # @intent: { entity: "History window", action: "count the scope", behavior: "total_count is the repository's run count unfiltered and the branch's run count under ?branch=, unchanged by a cursor", layer: "request" }
    it "counts the in-scope runs, with and without a branch and a cursor" do
      main = seed_runs(12)
      seed_runs(4, branch: "feature/x", prefix: "fx")

      expect(get_repository["history_window"]["total_count"]).to eq(16)
      expect(get_repository(query: { branch: "main" })["history_window"]["total_count"]).to eq(12)
      expect(get_repository(query: { branch: "feature/x" })["history_window"]["total_count"]).to eq(4)
      expect(get_repository(query: { branch: "nope" })["history_window"]["total_count"]).to eq(0)
      expect(get_repository(query: { runs_before: main[3].id.to_s })["history_window"]["total_count"]).to eq(16)
    end

    # @intent: { entity: "History window", action: "serve the cursor keys without an ask", behavior: "a call with no runs_before serves before null, requested_runs_before null, runs_before_resolved true, a populated next_runs_before when the page is full and null when it is not", layer: "request" }
    it "serves the new keys on a default call" do
      runs = seed_runs(11)

      expect(get_repository["history_window"]).to include(
        "before" => nil, "requested_runs_before" => nil, "runs_before_resolved" => true,
        "next_runs_before" => runs[9].id, "total_count" => 11, "window_blocks_anchor" => "newest_runs"
      )

      other = create_repository(user: repository.user, github_full_name: "acme/short")
      create_test_run(repository: other, commit_sha: "short0001", branch: "main")
      short_key = other.api_keys.create!
      get "/api/v1/repository", headers: { "Authorization" => "Bearer #{short_key.raw_token}" }
      expect(response.parsed_body["history_window"]).to include("next_runs_before" => nil, "total_count" => 1)
    end

    # @intent: { entity: "History window", action: "serve the keys on an empty repository", behavior: "a repository CI never reported to serves total_count 0 and next_runs_before null", layer: "request" }
    it "serves a zero total on a repository with no runs" do
      expect(get_repository["history_window"]).to include("total_count" => 0, "next_runs_before" => nil, "returned" => 0)
    end
  end

  describe "composition with ?branch=" do
    # @intent: { entity: "History window", action: "page one branch's series past its cap", behavior: "?branch=main&runs_before=<oldest of 30> answers only main rows older than it while other branches' interleaved runs are never listed", layer: "request" }
    it "pages one branch's series past its 30-run cap" do
      main = seed_runs(35)
      # Interleave another branch's runs so a lost branch predicate is visible.
      seed_runs(5, branch: "feature/x", prefix: "fx")

      first = get_repository(query: { branch: "main" })
      expect(history_ids(first)).to eq(main.first(30).map(&:id))
      expect(first["history_window"]).to include("limit" => 30, "total_count" => 35,
                                                 "next_runs_before" => main[29].id)

      second = get_repository(query: { branch: "main", runs_before: main[29].id.to_s })

      expect(history_ids(second)).to eq(main.last(5).map(&:id))
      expect(second["history_window"]).to include("returned" => 5, "next_runs_before" => nil,
                                                  "branch" => "main", "total_count" => 35)
    end
  end

  describe "the plural route" do
    # @intent: { entity: "History window", action: "page under a user key", behavior: "GET /api/v1/repositories/:id honours ?runs_before= with the same cursor keys, since both routes assemble one RepositoryOverview", layer: "request" }
    it "pages the named repository's history under a person key" do
      runs = seed_runs(13)
      token = create_user_api_key(user: repository.user).raw_token

      get "/api/v1/repositories/#{repository.id}", params: { runs_before: runs[9].id.to_s },
                                                    headers: { "Authorization" => "Bearer #{token}" }

      body = response.parsed_body
      expect(response).to have_http_status(:ok)
      expect(history_ids(body)).to eq(runs.last(3).map(&:id))
      expect(body["history_window"]).to include("before" => runs[9].id, "returned" => 3,
                                                "next_runs_before" => nil, "total_count" => 13)
    end
  end

  describe "a cursor that misses" do
    # @intent: { entity: "History window", action: "disclose an unknown cursor", behavior: "a well-formed run id this repository never held serves the unfiltered newest window with before null, the ask echoed and runs_before_resolved false", layer: "request" }
    it "falls back to the newest window and says the ask missed" do
      runs = seed_runs(12)

      body = get_repository(query: { runs_before: "424242" })

      expect(response).to have_http_status(:ok)
      expect(history_ids(body)).to eq(runs.first(10).map(&:id))
      expect(body["history_window"]).to include("before" => nil, "requested_runs_before" => 424_242,
                                                "runs_before_resolved" => false)
    end

    # @intent: { entity: "History window", action: "refuse a foreign cursor", behavior: "another repository's run id is the same miss, never positioning this history on the foreign repository's runs", layer: "request" }
    it "treats another repository's run id as a miss" do
      runs = seed_runs(12)
      other = create_repository(user: repository.user, github_full_name: "acme/other-repo")
      foreign = create_test_run(repository: other, commit_sha: "0ther0001", branch: "main")

      body = get_repository(query: { runs_before: foreign.id.to_s })

      expect(history_ids(body)).to eq(runs.first(10).map(&:id))
      expect(body["history_window"]).to include("before" => nil, "requested_runs_before" => foreign.id,
                                                "runs_before_resolved" => false)
    end
  end

  describe "a runs_before parameter that is not a cursor" do
    [
      ["an array", { runs_before: ["1"] }],
      ["a nested hash", { runs_before: { a: "b" } }],
      ["a string carrying a NUL", { runs_before: "5\u00006" }],
      ["a blank string", { runs_before: "" }],
      ["a non-integer string", { runs_before: "abc" }],
      ["zero", { runs_before: "0" }],
      ["a negative integer", { runs_before: "-3" }],
      ["an integer past the bigint ceiling", { runs_before: "9223372036854775808" }]
    ].each do |shape, query|
      # @intent: { entity: "RequestedRunsBeforeParam", action: "treat non-cursor shapes as no ask", behavior: "a runs_before in a container shape, carrying a NUL, blank, non-numeric, zero, negative or past the bigint ceiling answers 200 with the default window and requested_runs_before null, resolved true", layer: "request" }
      it "answers the default window with no ask echoed when runs_before arrives as #{shape}" do
        runs = seed_runs(12)

        body = get_repository(query: query)

        expect(response).to have_http_status(:ok)
        expect(history_ids(body)).to eq(runs.first(10).map(&:id))
        expect(body["history_window"]).to include("before" => nil, "requested_runs_before" => nil,
                                                  "runs_before_resolved" => true)
      end
    end
  end

  describe "what the cursor does not move" do
    # @intent: { entity: "History window", action: "keep window-grain blocks and latest_run on the newest runs", behavior: "under a resolved cursor latest_run, unstable_tests and directory_growth keep the bodies a default call serves while only history and its window change, and window_blocks_anchor says newest_runs", layer: "request" }
    it "pages history alone and leaves latest_run and the window-grain blocks anchored on the newest runs" do
      runs = seed_runs(14)
      query = { branch: "main" }
      default_body = get_repository(query: query)

      paged = get_repository(query: query.merge(runs_before: runs[5].id.to_s))

      expect(history_ids(paged)).to eq(runs[6..].map(&:id))
      expect(paged["latest_run"]).to eq(default_body["latest_run"])
      expect(paged["latest_run"]["id"]).to eq(runs.first.id)
      %w[unstable_tests directory_growth directory_growth_window layer_growth layer_growth_window
         slowest_tests slowest_tests_window].each do |key|
        expect(paged[key]).to eq(default_body[key]), "#{key} moved with the cursor"
      end
      expect(paged["history_window"]["window_blocks_anchor"]).to eq("newest_runs")
    end
  end

  describe "the cost" do
    # @intent: { entity: "History window", action: "price the cursor", behavior: "a default overview issues exactly one COUNT over test_runs and no indexed cursor lookup", layer: "request" }
    it "adds one COUNT and no cursor lookup on a call with no cursor" do
      seed_runs(12)
      get_repository
      reads = queries_against('"test_runs"') { get_repository }

      expect(reads.count { |sql| sql.include?("COUNT(*)") }).to eq(1)
      expect(reads.count { |sql| sql.include?('"test_runs"."id" = ') }).to eq(0)
    end

    # Unfiltered, the window-grain blocks are branch-gated and never load `history_runs`, so the
    # cursor's page REPLACES the newest-window read and the only addition is the indexed lookup of
    # the cursor row. Under `?branch=` the blocks do read the newest window, so the page is a
    # genuine second read (+2: lookup and page).
    # @intent: { entity: "History window", action: "price a resolved cursor", behavior: "a resolved cursor on an unfiltered overview adds exactly one test_runs read, the cursor lookup, and under ?branch= adds the lookup plus the second page read", layer: "request" }
    it "adds the cursor lookup, and a second page read only where the window blocks also read history" do
      runs = seed_runs(25)
      get_repository
      default_reads = queries_against('"test_runs"') { get_repository }
      asked_reads = queries_against('"test_runs"') { get_repository(query: { runs_before: runs[9].id.to_s }) }

      expect(asked_reads.size - default_reads.size).to eq(1)
      expect(asked_reads.count { |sql| sql.include?('"test_runs"."id" = ') }).to eq(1)

      get_repository(query: { branch: "main" })
      branch_default = queries_against('"test_runs"') { get_repository(query: { branch: "main" }) }
      branch_asked = queries_against('"test_runs"') do
        get_repository(query: { branch: "main", runs_before: runs[9].id.to_s })
      end

      expect(branch_asked.size - branch_default.size).to eq(2)
    end
  end
end
