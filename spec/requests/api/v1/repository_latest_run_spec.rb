# frozen_string_literal: true

require "rails_helper"

# The auth contract for this endpoint lives in `repositories_spec.rb` and is deliberately left
# untouched. This file covers only the `latest_run` block — the agent-readable twin of the suite
# figures `repositories#show` renders.
RSpec.describe "GET /api/v1/repository — latest_run", type: :request do
  let(:repository) { create_repository }
  let(:api_key) { repository.api_keys.create! }

  def get_repository(key: api_key)
    get "/api/v1/repository", headers: { "Authorization" => "Bearer #{key.raw_token}" }

    response.parsed_body
  end

  describe "a repository with an ingested run" do
    let!(:test_run) do
      create_test_run(repository: repository,
                      commit_sha: "a1b2c3d4e5f6",
                      branch: "main",
                      total_specs_count: 40,
                      annotated_specs_count: 10,
                      duration_seconds: 42.5)
    end

    it "reports the latest run's suite facts" do
      body = get_repository

      expect(response).to have_http_status(:ok)
      expect(body["latest_run"]).to eq(
        "commit_sha" => "a1b2c3d4e5f6",
        "branch" => "main",
        "total_specs" => 40,
        "annotated_specs" => 10,
        "annotated_ratio" => 0.25,
        "duration_seconds" => 42.5,
        # Null, not an empty block: this fixture has no shards, so there is no composition to
        # explain and the MAX the key above reports *is* the SUM. The key is still present, on the
        # same rule `latest_run` itself follows one describe-block down.
        "shards" => nil,
        "ingested_at" => test_run.created_at.iso8601
      )
    end

    # AC2. Read off the same accessor `repositories#show` assigns to `@latest_test_run` rather than
    # re-stating the fixture's numbers: two independent hand-written expectations would still both
    # pass if the endpoint started reading a *different* row.
    it "reports the same row, and the same figures, that repositories#show renders" do
      shown = repository.latest_test_run
      block = get_repository["latest_run"]

      expect(block["commit_sha"]).to eq(shown.commit_sha)
      expect(block["branch"]).to eq(shown.branch)
      expect(block["total_specs"]).to eq(shown.total_specs_count)
      expect(block["annotated_specs"]).to eq(shown.annotated_specs_count)
      expect(block["duration_seconds"]).to eq(shown.duration_seconds)
      # The panel renders a second cost figure — `machine_seconds` — beside the wall clock, so
      # "the same figures" is only true if this endpoint accounts for it. This fixture has no
      # shards, and the *reason* the block is null is asserted rather than the null alone: a
      # hard-coded `be_nil` here would keep passing if the gate stopped being `multi_shard?`.
      # The composition where the two figures actually differ is covered further down.
      expect(shown).not_to be_multi_shard
      expect(shown.machine_seconds).to be_nil
      expect(block["shards"]).to be_nil
      expect(block["ingested_at"]).to eq(shown.created_at.iso8601)
    end

    it "leaves the existing repository and api_key blocks in place" do
      body = get_repository

      expect(body.dig("repository", "full_name")).to eq("acme/billing-service")
      expect(body["api_key"]).to have_key("last_used_at")
    end

    it "scopes latest_run to the key's own repository" do
      other = create_repository(user: create_user(github_uid: "2002", github_handle: "hubot"),
                                github_full_name: "acme/ledger")
      create_test_run(repository: other, commit_sha: "otherrepo", total_specs_count: 7)

      expect(get_repository.dig("latest_run", "commit_sha")).to eq("a1b2c3d4e5f6")
    end
  end

  # The `created_at desc, id desc` tie-break, which is the half of "same row" a single-run fixture
  # cannot exercise: two runs stamped the same instant order by id, so the endpoint and the
  # dashboard cannot name different commits for the same repository.
  describe "two runs ingested in the same instant" do
    it "breaks the created_at tie the same way Repository#latest_test_run does" do
      stamp = 1.hour.ago
      older = create_test_run(repository: repository, commit_sha: "older0", total_specs_count: 1)
      newer = create_test_run(repository: repository, commit_sha: "newer0", total_specs_count: 1)
      [older, newer].each { |run| run.update_columns(created_at: stamp) }

      expect(repository.latest_test_run).to eq(newer)
      expect(get_repository.dig("latest_run", "commit_sha")).to eq(repository.latest_test_run.commit_sha)
    end
  end

  # AC3. `null`, not a zeroed block: a repository whose CI has never reported must not be
  # indistinguishable from one that reported an empty suite.
  describe "a repository whose CI has never reported" do
    it "reports latest_run as null rather than a block of zeros" do
      body = get_repository

      expect(response).to have_http_status(:ok)
      expect(body).to have_key("latest_run")
      expect(body["latest_run"]).to be_nil
    end
  end

  # AC4. Both columns are nullable and Ingest::Payload accepts a body omitting either.
  describe "a run that reported no branch and no duration" do
    before do
      create_test_run(repository: repository, commit_sha: "nobranch", total_specs_count: 3,
                      annotated_specs_count: 1, branch: nil, duration_seconds: nil)
    end

    it "keeps branch null instead of substituting a name" do
      expect(get_repository["latest_run"]).to include("branch" => nil)
    end

    it "keeps duration_seconds null instead of asserting the run took no time" do
      expect(get_repository["latest_run"]).to include("duration_seconds" => nil)
    end
  end

  # AC5. `TestRun#annotated_fraction` floors at 0.0 by zero-denominator guard; emitting that here
  # would read as a *measured* zero share beside real fractions.
  describe "a run that reported zero tests" do
    before { create_test_run(repository: repository, commit_sha: "emptysuite", total_specs_count: 0) }

    it "reports no ratio rather than a confident 0.0" do
      expect(get_repository["latest_run"]).to include("annotated_ratio" => nil)
    end

    it "still reports the counts, so a client can see the suite was empty" do
      expect(get_repository["latest_run"]).to include("total_specs" => 0, "annotated_specs" => 0)
    end
  end

  # AC6. The unit trap: `TestRun#annotated_ratio` is a 0–100 percentage and `#annotated_fraction`
  # is the 0–1 fraction `/ingest` answers with. A client reading both endpoints must not find them
  # disagreeing by 100×.
  #
  # Written against an UNSHARDED run (no `ci_run_id`) on purpose. `Ingest::RunRecorder` folds every
  # shard of a sharded run onto one row and recomputes its counters as the SUM of the shards, so
  # mid-run the ingest response and a later GET legitimately describe different totals — asserting
  # they match across a sharded fixture would encode an invariant that does not hold.
  describe "agreement with the /ingest response for the same run" do
    it "answers the same annotated_ratio /ingest did, in the same 0–1 unit" do
      post "/api/v1/ingest",
           params: ingest_payload(
             commit_sha: "c0ffee1234",
             branch: "main",
             specs: [
               annotated_spec(file_path: "spec/models/invoice_spec.rb", line_number: 12),
               annotated_spec(file_path: "spec/requests/checkout_spec.rb", line_number: 30, layer: "request"),
               unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 7)
             ]
           ).to_json,
           headers: { "Content-Type" => "application/json",
                      "Authorization" => "Bearer #{api_key.raw_token}" }

      expect(response).to have_http_status(:accepted)
      ingested = response.parsed_body

      block = get_repository["latest_run"]

      expect(block["annotated_ratio"]).to eq(ingested["annotated_ratio"])
      expect(block["total_specs"]).to eq(ingested["total_specs"])
      expect(block["annotated_specs"]).to eq(ingested["annotated_specs"])
    end

    # Guards the direction the agreement above cannot catch on its own: both sides could drift to
    # the percentage together and still agree with each other.
    it "is the fraction, not the percentage the dashboard renders" do
      create_test_run(repository: repository, commit_sha: "quarter", total_specs_count: 40,
                      annotated_specs_count: 10)

      run = repository.latest_test_run

      expect(get_repository.dig("latest_run", "annotated_ratio")).to eq(run.annotated_fraction)
      expect(get_repository.dig("latest_run", "annotated_ratio")).not_to eq(run.annotated_ratio)
    end
  end

  # AC1/AC6. Every example above this point runs at `shard_count == 0` — the one composition where
  # the run's MAX and its SUM are the same number, and therefore the one composition that cannot
  # show whether the endpoint knows the difference.
  #
  # The durations are the suite's canonical fixture, shared with
  # `spec/requests/api/v1/ingest_spec.rb` (which builds them through `Ingest::RunRecorder` and pins
  # the MAX at 74.25) and `spec/requests/repositories_spec.rb` (which renders them in the Overview
  # panel). Three surfaces, one set of rows: if the API and the panel ever start naming different
  # cost figures for the same run, one of these files goes red.
  describe "a run assembled from more than one shard" do
    # Written directly, in the shape `repositories_spec.rb`'s own `sharded_run` helper uses. The
    # recorder is exercised in the ingest spec; the question here is only what the serializer does
    # with the rows it leaves behind.
    def sharded_run(durations, commit_sha:)
      run = repository.test_runs.create!(commit_sha: commit_sha, ci_run_id: "gha-#{commit_sha}",
                                         total_specs_count: 20_000, annotated_specs_count: 5000,
                                         duration_seconds: durations.compact.max)
      durations.each_with_index do |seconds, index|
        run.test_run_shards.create!(shard_id: (index + 1).to_s, total_specs_count: 5000,
                                    annotated_specs_count: 1250, duration_seconds: seconds)
      end
      run
    end

    # The defect, stated as an expectation. 74.25s of waiting against 253.75s of machine time is a
    # 3.4× gap on this fixture, and until now the endpoint served only the smaller number.
    it "serves the machine time beside the wall clock, and states what each was computed over" do
      sharded_run([61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0179")

      block = get_repository["latest_run"]

      # AC2: unchanged in key, type and value. It is still the MAX.
      expect(block["duration_seconds"]).to eq(74.25)
      expect(block["shards"]).to eq(
        "count" => 4,
        "timed_count" => 4,
        "machine_seconds" => 253.75,
        "coverage" => { "duration_seconds" => 4, "machine_seconds" => 4 }
      )
    end

    # AC5's "the same figures repositories#show renders", on the composition where there is
    # actually a second figure to compare. Read off the accessors the panel renders from rather
    # than the fixture's arithmetic: restating `253.75` here would still pass if the endpoint
    # summed a different set of rows than the panel does.
    it "reports the same cost figures repositories#show renders for the same run" do
      sharded_run([61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0180")

      shown = repository.latest_test_run
      block = get_repository["latest_run"]

      expect(shown).to be_multi_shard
      expect(block["duration_seconds"]).to eq(shown.duration_seconds)
      expect(block.dig("shards", "machine_seconds")).to eq(shown.machine_seconds)
      expect(block.dig("shards", "count")).to eq(shown.shard_count)
      expect(block.dig("shards", "timed_count")).to eq(shown.timed_shard_count)
    end

    # The coverage exists for this row. `test_run_shards.duration_seconds` is nullable and
    # `Ingest::Payload` accepts a shard without a timing, so a silent shard is an ordinary state —
    # and the SILENT ONE IS THE SLOWEST here on purpose, because a cancelled or timed-out job
    # usually is. Both figures are then computed over three rows: the SUM is a floor, and the MAX
    # is a maximum over a subset that excluded the very shard that would have set it.
    it "reports both figures' coverage when a shard reported no timing" do
      sharded_run([61.0, 58.5, nil, 60.0], commit_sha: "feedfacecafe0181")

      block = get_repository["latest_run"]

      # 61.0, not 74.25: the shard that would have been the maximum said nothing.
      expect(block["duration_seconds"]).to eq(61.0)
      expect(block["shards"]).to eq(
        "count" => 4,
        "timed_count" => 3,
        "machine_seconds" => 179.5,
        # The whole point of the block. Without these a client reads "the run took 61s and cost
        # 179.5s" with no way to learn that both were measured over three of four shards — the
        # caption the Overview panel has and JSON does not.
        "coverage" => { "duration_seconds" => 3, "machine_seconds" => 3 }
      )
    end

    # AC1's actual requirement, restated as a check a client could run: the coverage is reported as
    # COUNTS, not as the prose `TestRun#machine_seconds_coverage` / `#wall_clock_coverage` write
    # for the panel. A client that has to regex "slowest of the 3 that reported" out of a string
    # has not been told anything it can compute with.
    it "carries the coverage as counts a client can divide, not as the panel's sentences" do
      run = sharded_run([61.0, 58.5, nil, 60.0], commit_sha: "feedfacecafe0182")

      shards = get_repository.dig("latest_run", "shards")

      expect(shards.values_at("count", "timed_count")).to all(be_a(Integer))
      # Asserted one at a time: `not_to include(a, b)` negates "includes BOTH", so it would pass
      # on a body carrying one of the two sentences.
      expect(shards.to_json).not_to include(run.machine_seconds_coverage)
      expect(shards.to_json).not_to include(run.wall_clock_coverage)
      expect(shards.to_json).not_to match(/[a-z]{3,} of /)
    end

    # AC3. `null` is not `0.0`, and this is the composition where the difference bites hardest: a
    # four-shard run where nothing reported still ran, and serializing its cost as a measured zero
    # would be the endpoint asserting the suite was free.
    it "keeps machine_seconds null, not zero, when no shard reported a timing" do
      sharded_run([nil, nil, nil, nil], commit_sha: "feedfacecafe0183")

      block = get_repository["latest_run"]

      expect(block["duration_seconds"]).to be_nil
      expect(block["shards"]).to eq(
        "count" => 4,
        "timed_count" => 0,
        "machine_seconds" => nil,
        "coverage" => { "duration_seconds" => 0, "machine_seconds" => 0 }
      )
    end
  end

  # AC4. One shard's MAX *is* its SUM, so there is no composition to disambiguate and no second
  # figure to print — the run is served exactly as it always was, with the key present and null.
  # `multi_shard?` and not `shard_count.positive?` is the gate for precisely this row.
  describe "a run assembled from a single shard" do
    it "reports no shard block, because its wall clock and its machine time are one number" do
      run = repository.test_runs.create!(commit_sha: "oneshard0000", ci_run_id: "gha-oneshard",
                                         total_specs_count: 5000, duration_seconds: 61.0)
      run.test_run_shards.create!(shard_id: "1", total_specs_count: 5000, duration_seconds: 61.0)

      block = get_repository["latest_run"]

      expect(run.machine_seconds).to eq(run.duration_seconds)
      expect(block).to have_key("shards")
      expect(block["shards"]).to be_nil
      expect(block["duration_seconds"]).to eq(61.0)
    end
  end

  # AC7. The block is derived from `TestRun#shard_totals` — one memoized aggregate on
  # `index_test_run_shards_on_test_run_id` answering all three counts at once — so the endpoint's
  # cost does not move with the number of shards. A per-shard read, or one query per figure, shows
  # up here immediately; the 20,000-example fixture is 4 shards today and nothing stops it being 40.
  describe "what the shard figures cost the endpoint" do
    def count_queries
      count = 0
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
        count += 1 unless payload[:cached] || payload[:name].in?(["SCHEMA", "TRANSACTION"])
      end
      yield
      count
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    def sharded_run(shard_count, commit_sha:)
      run = repository.test_runs.create!(commit_sha: commit_sha, ci_run_id: "gha-#{commit_sha}",
                                         total_specs_count: 20_000, duration_seconds: 74.25)
      shard_count.times do |index|
        run.test_run_shards.create!(shard_id: (index + 1).to_s, total_specs_count: 5000,
                                    duration_seconds: 60.0 + index)
      end
      run
    end

    it "costs the same on a 4-shard run, a 40-shard run and a run with no shards at all" do
      create_test_run(repository: repository, commit_sha: "noshards0000", duration_seconds: 42.5)
      get_repository
      baseline = count_queries { get_repository }

      sharded_run(4, commit_sha: "fourshards00")
      expect(count_queries { get_repository }).to eq(baseline)

      sharded_run(40, commit_sha: "fortyshards0")
      expect(count_queries { get_repository }).to eq(baseline)
      expect(get_repository.dig("latest_run", "shards", "count")).to eq(40)
    end
  end
end
