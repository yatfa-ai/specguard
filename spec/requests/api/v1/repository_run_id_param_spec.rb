# frozen_string_literal: true

require "rails_helper"

# `?run=<id>` on the repository-overview API (SPGD-2018): the console's row-level run ask
# (SPGD-1927/1928) brought to the same routes the sha ask has served since SPGD-544.
#
# The gap this closes is the re-run pair. `test_runs` has no uniqueness on `commit_sha`, so a CI
# re-run of one commit is a SECOND row, and the endpoint's only existing run ask — `?commit_sha=`,
# resolved by `Repository#latest_test_run_for_commit` — always answers with the NEWEST of them.
# The older row was unreadable here, while `DELETE /api/v1/repositories/:repository_id/runs/:id`
# (SPGD-2014) can already delete it by id: an agent could delete a run it could not first inspect.
# `?run=<id>` names the row itself, the only handle that distinguishes two rows printing the same
# seven characters.
#
# Its own file rather than more examples in the latest_run file, on the reasoning
# `repository_compare_to_baseline_spec.rb` states for its own parameter: this is not a fact about a
# block, it is a fact about WHICH RUN the whole body describes, and one file per ask keeps "which
# shapes does `?run=` tolerate" a single question.
#
# What this file guards:
#
#   * THE RE-RUN PAIR OPENS. `?run=<older id>` answers with the OLDER run — `latest_run.id` equal
#     to it, under an anchor that says it resolved — and every run-grain block re-anchors with it,
#     because the anchor is chosen in the one memo (`RepositoryOverview#latest_test_run`) they all
#     flow through.
#   * THE SHA ASK IS NOT CHANGED. `?commit_sha=` alone still answers the newest row of its sha.
#   * A MISS IS DISCLOSED, NEVER SILENT. A well-formed id matching nothing — an unknown id, or a
#     foreign repository's id, which the scoped `find_by` cannot serve — falls back to the newest
#     run under `resolved: false` with the raw ask echoed. No 404.
#   * RUN BEATS SHA. Both asks on one request and the id wins, matching the console's precedence;
#     the anchor names which ask was honoured.
#   * MALFORMED IS NO ASK. The shapes are pinned ONCE in
#     `spec/support/shared_examples/malformed_run_id_param.rb`; what is local here is that this
#     surface's no-ask answer is BYTE-IDENTICAL to the un-asked body, not merely the same anchor.
RSpec.describe "GET /api/v1/repository — ?run= names one run", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:repository) { create_repository }
  let(:api_key) { repository.api_keys.create! }

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

  # TWO rows on ONE sha plus a newer run on another — the re-run pair is the whole point. Their
  # `total_specs_count`s do not overlap, so an assertion about the older run cannot be satisfied by
  # a body that quietly answered with its sibling. Backdated explicitly rather than relying on
  # insertion order, because every ordering here — newest run, previous run on the branch — is by
  # `created_at`, and two rows written in the same example land microseconds apart.
  def re_run_history
    first_run = create_test_run(repository: repository, commit_sha: "0nesha00cafe0001",
                                branch: "main", total_specs_count: 11, created_at: 3.hours.ago)
    re_run = create_test_run(repository: repository, commit_sha: "0nesha00cafe0001",
                             branch: "main", total_specs_count: 22, created_at: 2.hours.ago)
    newest = create_test_run(repository: repository, commit_sha: "newest00cafe0002",
                             branch: "main", total_specs_count: 33, created_at: 1.hour.ago)

    [first_run, re_run, newest]
  end

  describe "a re-run pair named by id" do
    # THE defect this ticket closes, asserted end to end: the older row of the pair was reachable
    # by no ask this endpoint served — the sha ask always answers the newest — so both halves are
    # asserted, because either alone is passable by a broken implementation. Serving the older
    # `latest_run` silently would satisfy the first half, and an anchor claiming a resolved ask
    # beside the newest `latest_run` would satisfy the second.
    # @intent: { entity: "Run anchor", action: "open older re-run by id", behavior: "?run=<older id> of a two-rows-one-sha pair answers latest_run.id equal to the older row with run_anchor resolved true and the raw ask echoed", layer: "request" }
    it "answers with the older run of the pair and says the ask resolved" do
      first_run, re_run, = re_run_history

      body = get_repository(query: { run: first_run.id.to_s })

      expect(response).to have_http_status(:ok)
      expect(body["latest_run"]["id"]).to eq(first_run.id)
      expect(body["latest_run"]).not_to include("id" => re_run.id)
      expect(body["run_anchor"]).to include(
        "source" => "requested", "resolved" => true, "requested_run_id" => first_run.id,
        "commit_sha" => first_run.commit_sha, "branch" => "main"
      )
    end

    # The property the single-memo design exists for, at the grain where a sha cannot distinguish
    # the two rows: `latest_run` carries the id (SPGD-2014) and the growth windows carry the
    # baseline OF THE ASKED RUN — no earlier run exists on the branch behind the first row, where
    # behind the newest row there is a whole history. A partial re-anchor (one block moved, the
    # windows left on the newest run) fails here because the baseline differs.
    # @intent: { entity: "Run anchor", action: "re-anchor every run-grain block", behavior: "under ?run=<older id> latest_run.id and both growth windows anchor on the asked run, whose branch baseline is nil because no earlier run exists", layer: "request" }
    it "re-anchors every run-grain block onto the asked row" do
      first_run, _re_run, = re_run_history

      body = get_repository(query: { run: first_run.id.to_s })

      expect(body["latest_run"]["id"]).to eq(first_run.id)
      expect(body["directory_run_growth_window"]).to include(
        "anchor_commit_sha" => first_run.commit_sha
      )
      expect(body["directory_run_growth_window"]["baseline_commit_sha"]).to be_nil
      expect(body["directory_runtime_growth_window"]).to include(
        "anchor_commit_sha" => first_run.commit_sha
      )
    end

    # `history` is NOT re-anchored by either run ask — it stays the repository's recent runs,
    # newest first — so under `?run=<older id>` the body legitimately describes the asked row in
    # `latest_run` while `history[0]` is that row's same-sha sibling. Stated as an expectation
    # rather than left as an unremarked property of the fixture, so a later slice that "fixes" the
    # mismatch by narrowing `history` has to argue with this example.
    # @intent: { entity: "Run anchor", action: "leave history unanchored", behavior: "under ?run=<older id> history stays newest-first so history[0] is the sibling row latest_run does not describe", layer: "request" }
    it "leaves history where it was while latest_run describes the asked row" do
      first_run, re_run, newest = re_run_history

      body = get_repository(query: { run: first_run.id.to_s })

      expect(body["history"].first["id"]).to eq(newest.id)
      expect(body["history"].map { |row| row["id"] }).to include(re_run.id, first_run.id)
      expect(body["latest_run"]["id"]).to eq(first_run.id)
    end

    # The priced read: a run ask costs the SAME number of `test_runs` reads as a default body —
    # it REPLACES one newest-row read with the indexed primary-key read rather than adding to the
    # count. `latest_test_run` falls back with a short-circuiting `||`, so the default path issues
    # its newest-run read and the run-asked path issues `WHERE id =` instead, and the memo makes
    # that one read serve every block in the body. (The console's own priced-read test sees +1
    # rather than a swap because that page loads the newest run unconditionally for its
    # Recent-runs panel; this endpoint has no such unconditional read.) The swap is asserted BY
    # SHAPE — exactly one query differs, and it is the id read — because equal counts alone would
    # also pass a run ask that issued its own read AND dropped a different one. Counted warm, on
    # the second request of each, because a first request carries schema and cache work nothing
    # on this endpoint chose to do.
    # @intent: { entity: "Run anchor", action: "price the run-id read", behavior: "a run-asked overview issues the same number of test_runs queries as a default overview, with exactly one read swapped from the newest-row read to the indexed id read", layer: "request" }
    it "swaps the newest-row read for the indexed id read and adds no read" do
      first_run, = re_run_history

      get_repository
      default_reads = queries_against('"test_runs"') { get_repository }

      asked_reads = queries_against('"test_runs"') do
        get_repository(query: { run: first_run.id.to_s })
      end

      expect(asked_reads.size).to eq(default_reads.size)
      swapped = default_reads.zip(asked_reads).reject { |default_sql, asked_sql| default_sql == asked_sql }
      expect(swapped.size).to eq(1)
      expect(swapped.first.last).to include('"test_runs"."id" = ')
    end
  end

  describe "a sha ask without a run ask" do
    # The pre-existing ask is untouched: with no `?run=` present, `?commit_sha=` resolves exactly
    # as it did before this parameter existed — the NEWEST row of its sha, which for a re-run pair
    # is the sibling this parameter exists to get past.
    # @intent: { entity: "Run anchor", action: "keep sha ask naming newest", behavior: "?commit_sha= alone on a one-sha-two-rows pair answers latest_run.id equal to the newest row with no run ask echoed", layer: "request" }
    it "answers the newest row of the sha and echoes no run ask" do
      _first, re_run, = re_run_history

      body = get_repository(query: { commit_sha: re_run.commit_sha })

      expect(body["latest_run"]["id"]).to eq(re_run.id)
      expect(body["run_anchor"]).to include(
        "source" => "requested", "resolved" => true,
        "requested_commit_sha" => re_run.commit_sha, "requested_run_id" => nil
      )
    end
  end

  describe "a run ask that misses" do
    # A well-formed id that matches nothing: a stale bookmark, a deleted run and an id from before
    # a re-ingest are ordinary ways to arrive. Not a 404 and not a malformed request — a fallback,
    # disclosed, with the raw ask echoed, exactly the stance the sha ask takes for an unknown sha.
    # @intent: { entity: "Run anchor", action: "fall back on unknown run id", behavior: "a run id this repository never held answers the newest run with run_anchor resolved false and the raw ask echoed", layer: "request" }
    it "falls back to the newest run and says the ask was made and missed" do
      _first, _re_run, newest = re_run_history

      body = get_repository(query: { run: "424242" })

      expect(response).to have_http_status(:ok)
      expect(body["latest_run"]["id"]).to eq(newest.id)
      expect(body["run_anchor"]).to include(
        "source" => "requested", "resolved" => false, "requested_run_id" => 424_242,
        "commit_sha" => newest.commit_sha
      )
    end

    # A foreign repository's id is the same miss and not a leak: the resolution reaches `find_by`
    # through THIS repository's `test_runs`, so the other repository's row can never be served —
    # the ask falls back to THIS repository's newest run, disclosed the same way an unknown id is.
    # @intent: { entity: "Run anchor", action: "refuse foreign run id", behavior: "another repository's run id answers this repository's newest run with resolved false, never the foreign run", layer: "request" }
    it "treats another repository's run id as a miss, not a cross-repository read" do
      _first, _re_run, newest = re_run_history
      other = create_repository(user: repository.user, github_full_name: "acme/other-repo")
      foreign = create_test_run(repository: other, commit_sha: "0ther00cafe0001",
                                branch: "main", total_specs_count: 1)

      body = get_repository(query: { run: foreign.id.to_s })

      expect(response).to have_http_status(:ok)
      expect(body["latest_run"]["id"]).to eq(newest.id)
      expect(body["latest_run"]["commit_sha"]).to eq(newest.commit_sha)
      expect(body["run_anchor"]).to include(
        "source" => "requested", "resolved" => false, "requested_run_id" => foreign.id
      )
    end

    # The largest id the column can hold is a well-formed ask that misses — the fallback, with the
    # ask echoed as sent — and its literal is spelled out rather than read off
    # `RequestedRunIdParam::MAX_RUN_ID`, so a mutated constant cannot make the example agree with
    # itself.
    # @intent: { entity: "Run anchor", action: "accept the largest legal bigint run id", behavior: "?run=9223372036854775807 is a well-formed ask that misses and answers the newest run with resolved false and the ask echoed", layer: "request" }
    it "treats the largest bigint run id as a well-formed ask that misses" do
      _first, _re_run, newest = re_run_history

      body = get_repository(query: { run: "9223372036854775807" })

      expect(response).to have_http_status(:ok)
      expect(body["latest_run"]["id"]).to eq(newest.id)
      expect(body["run_anchor"]).to include(
        "resolved" => false, "requested_run_id" => 9_223_372_036_854_775_807
      )
    end
  end

  describe "run ask and sha ask together" do
    # The precedence rule, matching `RepositoryDashboard`'s: the id wins. The sha ask resolves to
    # the NEWEST same-sha row, so a body that honoured the sha instead would carry
    # `latest_run.id == re_run.id` — the sibling this parameter exists to get past.
    # @intent: { entity: "Run anchor", action: "prefer run ask over sha ask", behavior: "with both ?run=<older id> and ?commit_sha= naming the same commit's two rows, latest_run.id is the older row and the anchor echoes both asks with resolved true", layer: "request" }
    it "resolves the run ask ahead of the sha ask" do
      first_run, re_run, = re_run_history

      body = get_repository(query: { run: first_run.id.to_s, commit_sha: re_run.commit_sha })

      expect(body["latest_run"]["id"]).to eq(first_run.id)
      expect(body["run_anchor"]).to include(
        "source" => "requested", "resolved" => true,
        "requested_commit_sha" => re_run.commit_sha, "requested_run_id" => first_run.id
      )
    end

    # The miss half of the same precedence: the sha ask is consulted ONLY when there is no run
    # ask, so a run ask that misses falls back to the newest run and never to the sha's row — the
    # same rule the console's if/elsif resolution states by construction.
    # @intent: { entity: "Run anchor", action: "not consult sha on run miss", behavior: "a missing run ask beside a resolvable commit_sha falls back to the newest run rather than the named sha's row", layer: "request" }
    it "does not consult the sha ask when the run ask misses" do
      first_run, re_run, newest = re_run_history

      body = get_repository(query: { run: "424242", commit_sha: re_run.commit_sha })

      expect(body["latest_run"]["id"]).to eq(newest.id)
      expect(body["latest_run"]["id"]).not_to eq(first_run.id)
      expect(body["run_anchor"]).to include(
        "source" => "requested", "resolved" => false, "requested_run_id" => 424_242
      )
    end
  end

  describe "a run-id parameter that is not a run id" do
    # The shapes a `?run=` query string can legally parse into that are not a run id are listed
    # ONCE, in `spec/support/shared_examples/malformed_run_id_param.rb`, against the guard they all
    # land on (`RequestedRunIdParam#requested_run_id`). What is local here is how THIS surface says
    # it dropped the ask: the un-asked body, byte-identical — `run_anchor` reads `source: "default"`
    # with both echoes null, because a page that fell back without an ask must not claim one was
    # made, and every other block is untouched by a parameter the guard never let through.
    def expect_run_param_treated_as_no_ask(query)
      _first, _re_run, newest = re_run_history

      body = get_repository(query: query)

      expect(response).to have_http_status(:ok)
      expect(body["latest_run"]["id"]).to eq(newest.id)
      expect(body["run_anchor"]).to include(
        "source" => "default", "resolved" => true,
        "requested_commit_sha" => nil, "requested_run_id" => nil
      )
    end

    it_behaves_like "a surface that treats a malformed run-id parameter as no ask"

    # The byte-identity half, on three representative shapes from the shared list — the
    # container shapes the guard refuses first, the NUL shape the String half alone lets through,
    # and the digits-only over-bigint value `Integer()` would parse but the bind would raise on.
    # The whole body, not just the anchor: a parameter dropped by the guard cannot have touched
    # anything else, and this is what says so from the wire rather than from the code.
    # @intent: { entity: "Run anchor", action: "cost a malformed run ask nothing", behavior: "a container, NUL-carrying or over-bigint run parameter answers byte-identical to the un-asked body", layer: "request" }
    [
      ["an array", { run: ["5"] }],
      ["a string carrying a NUL", { run: "5\u00006" }],
      ["an integer beyond the bigint ceiling", { run: "99999999999999999999" }]
    ].each do |shape, query|
      it "answers byte-identical to the un-asked body when run arrives as #{shape}" do
        re_run_history

        byte_identical_bodies(with_params: query)
      end
    end

    # The positive-path example the shared examples' own doc comment requires to sit beside them:
    # a guard that swallowed EVERY value would answer byte-identical on every malformed shape too,
    # and nothing above separates "the guard rejects non-ids" from "the parameter does nothing".
    # @intent: { entity: "Run anchor", action: "accept string run ids", behavior: "a run parameter that is a plain id re-anchors the body onto that run's row", layer: "request" }
    it "honours a run parameter that IS an id" do
      first_run, = re_run_history

      expect(get_repository(query: { run: first_run.id.to_s })["latest_run"]["id"])
        .to eq(first_run.id)
    end
  end

  describe "cross-surface parity with the console" do
    before { @user = sign_in_via_github }

    # The console fixture's own shape: the signed-in person's repository, so the page renders.
    let(:repository) { create_repository(user: @user) }

    # Success criterion: the API and the console answer the same question about the same id and
    # must not disagree about which row they picked — both resolve through the same guard and the
    # same scoped `find_by` order, so this pins the parity from the outside rather than by reading
    # both implementations.
    # @intent: { entity: "Run anchor", action: "match console resolved anchor", behavior: "the API under ?run=<older id> and the console page anchored on the same id both name the older run's sha", layer: "request" }
    it "names the same run as the console page for an id that resolves" do
      first_run, _re_run, = re_run_history

      api_body = get_repository(query: { run: first_run.id.to_s })
      get repository_path(repository, run: first_run.id)

      expect(api_body["latest_run"]["id"]).to eq(first_run.id)
      expect(page_text).to include("Reading run #{first_run.commit_sha.first(7)}")
    end

    private

    def page_text
      Capybara.string(response.body).find(".rc-run").text.squish
    end
  end
end
