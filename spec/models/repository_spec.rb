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
  end

  it "takes its api keys, runs and intents with it when destroyed" do
    repository = create_repository
    repository.api_keys.create!
    create_spec_intent(repository: repository)

    expect { repository.destroy! }.to change(ApiKey, :count).by(-1).and change(SpecIntent, :count).by(-1)
  end
end
