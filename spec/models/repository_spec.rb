# frozen_string_literal: true

require "rails_helper"

RSpec.describe Repository do
  it "requires an org/repo shaped full name" do
    repository = create_user.repositories.new(github_full_name: "not-a-full-name")

    expect(repository).not_to be_valid
    expect(repository.errors[:github_full_name]).to include("must look like org/repo")
  end

  it "derives the short name from the full name" do
    expect(create_repository(github_full_name: "acme/billing-service").name).to eq("billing-service")
  end

  it "normalizes a pasted GitHub URL down to org/repo" do
    repository = create_repository(github_full_name: "https://github.com/acme/billing-service.git")

    expect(repository.github_full_name).to eq("acme/billing-service")
  end

  it "registers a given GitHub repository at most once" do
    create_repository(github_full_name: "acme/billing-service")
    duplicate = create_user(github_uid: "2002", github_handle: "hubot")
                .repositories.new(github_full_name: "acme/billing-service")

    expect(duplicate).not_to be_valid
  end

  describe "#annotated_ratio" do
    # Sourced from the latest TestRun's counters, not from `spec_intents`. Real ingestion persists
    # only annotated intents — the four intent columns are NOT NULL, so an unannotated spec is not
    # a row that can exist — which means counting rows here could only ever return 100%.
    it "reports the annotated share of the most recent run" do
      repository = create_repository
      repository.test_runs.create!(commit_sha: "abc123", total_specs_count: 3,
                                   annotated_specs_count: 2)

      expect(repository.annotated_ratio).to eq(66.7)
    end

    it "is not pinned to 100% by the intents ingestion actually persists" do
      repository = create_repository
      repository.test_runs.create!(commit_sha: "abc123", total_specs_count: 3,
                                   annotated_specs_count: 2)
      # Exactly what /ingest writes for that run once slice 3 lands: the two annotated specs, and
      # nothing at all for the third.
      create_spec_intent(repository: repository, line_number: 1)
      create_spec_intent(repository: repository, line_number: 2)

      expect(repository.spec_intents.count).to eq(2)
      expect(repository.annotated_ratio).to eq(66.7)
    end

    it "supersedes an older run rather than averaging over history" do
      repository = create_repository
      repository.test_runs.create!(commit_sha: "old", total_specs_count: 10,
                                   annotated_specs_count: 1, created_at: 1.day.ago)
      repository.test_runs.create!(commit_sha: "new", total_specs_count: 4,
                                   annotated_specs_count: 3)

      expect(repository.annotated_ratio).to eq(75.0)
    end

    it "breaks a same-instant tie on id so the reading is deterministic" do
      repository = create_repository
      at = 1.hour.ago
      repository.test_runs.create!(commit_sha: "first", total_specs_count: 4,
                                   annotated_specs_count: 1, created_at: at)
      repository.test_runs.create!(commit_sha: "second", total_specs_count: 4,
                                   annotated_specs_count: 3, created_at: at)

      expect(repository.annotated_ratio).to eq(75.0)
    end

    it "ignores another repository's runs" do
      repository = create_repository
      other = create_repository(user: create_user(github_uid: "2002", github_handle: "hubot"),
                                github_full_name: "acme/ledger")
      other.test_runs.create!(commit_sha: "abc123", total_specs_count: 4, annotated_specs_count: 4)

      expect(repository.annotated_ratio).to eq(0.0)
    end

    it "is 0.0 for a repository that has never ingested a run" do
      repository = create_repository

      expect(repository.annotated_ratio).to eq(0.0)
      expect(repository.annotated_ratio).to be_a(Float)
    end

    # The sharded case, read from this end. A sharded run used to land as one row per shard, so
    # `latest_test_run` picked whichever shard finished last — and shard completion order is not
    # stable, which made the headline move without the suite changing. Accumulation leaves one row
    # per run, so there is nothing left to pick between.
    it "reads a sharded run's accumulated row rather than one shard's slice of it" do
      repository = create_repository
      run = repository.test_runs.create!(commit_sha: "deadbee", ci_run_id: "gha-42",
                                         total_specs_count: 4900, annotated_specs_count: 500)
      TestRun.update_counters(run.id, total_specs_count: 15_100, annotated_specs_count: 4500)

      expect(repository.latest_test_run).to eq(run)
      expect(repository.latest_test_run.total_specs_count).to eq(20_000)
      expect(repository.annotated_ratio).to eq(25.0)
    end
  end

  describe "#recent_test_runs" do
    it "returns the newest runs first" do
      repository = create_repository
      repository.test_runs.create!(commit_sha: "oldest", created_at: 2.days.ago)
      repository.test_runs.create!(commit_sha: "middle", created_at: 1.day.ago)
      repository.test_runs.create!(commit_sha: "newest", created_at: 1.hour.ago)

      expect(repository.recent_test_runs.map(&:commit_sha)).to eq(%w[newest middle oldest])
    end

    it "breaks a same-instant tie on id, matching #latest_test_run" do
      # The Overview panel names `latest_test_run` and this panel's top row names the same run.
      # If the two orderings disagreed — and the id tie-break is the only thing that decides a
      # same-instant pair — the page would print two different commits for one run.
      repository = create_repository
      at = 1.hour.ago
      repository.test_runs.create!(commit_sha: "first", created_at: at)
      repository.test_runs.create!(commit_sha: "second", created_at: at)

      expect(repository.recent_test_runs.first).to eq(repository.latest_test_run)
      expect(repository.recent_test_runs.map(&:commit_sha)).to eq(%w[second first])
    end

    it "honours the limit, defaulting to ten" do
      repository = create_repository
      12.times { |i| repository.test_runs.create!(commit_sha: "sha#{i}", created_at: i.hours.ago) }

      expect(repository.recent_test_runs.count).to eq(10)
      expect(repository.recent_test_runs(limit: 3).map(&:commit_sha)).to eq(%w[sha0 sha1 sha2])
    end

    it "ignores another repository's runs" do
      repository = create_repository
      other = create_repository(user: create_user(github_uid: "2002", github_handle: "hubot"),
                                github_full_name: "acme/ledger")
      other.test_runs.create!(commit_sha: "not-mine")

      expect(repository.recent_test_runs).to be_empty
    end
  end

  it "takes its api keys, runs and intents with it when destroyed" do
    repository = create_repository
    repository.api_keys.create!
    create_spec_intent(repository: repository)

    expect { repository.destroy! }.to change(ApiKey, :count).by(-1).and change(SpecIntent, :count).by(-1)
  end
end
