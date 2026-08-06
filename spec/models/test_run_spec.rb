# frozen_string_literal: true

require "rails_helper"

RSpec.describe TestRun do
  let(:repository) { create_repository }

  it "requires the commit it ran against" do
    run = repository.test_runs.new(commit_sha: nil)

    expect(run).not_to be_valid
    expect(run.errors[:commit_sha]).to be_present
  end

  it "belongs to a repository" do
    run = TestRun.new(commit_sha: "abc123")

    expect(run).not_to be_valid
    expect(run.errors[:repository]).to be_present
  end

  describe "#annotated_ratio" do
    it "is 0.0 for a run that counted no specs" do
      run = repository.test_runs.create!(commit_sha: "abc123")

      expect(run.total_specs_count).to eq(0)
      expect(run.annotated_ratio).to eq(0.0)
      expect(run.annotated_ratio).to be_a(Float)
    end

    it "is 0.0 when the counters were never written at all" do
      run = repository.test_runs.create!(commit_sha: "abc123", annotated_specs_count: nil,
                                         total_specs_count: nil)

      expect(run.annotated_ratio).to eq(0.0)
      expect(run.annotated_ratio).to be_a(Float)
    end

    it "reports the share of counted specs that were annotated, to one decimal" do
      run = repository.test_runs.create!(commit_sha: "abc123", annotated_specs_count: 2,
                                         total_specs_count: 3)

      expect(run.annotated_ratio).to eq(66.7)
    end

    it "is 100.0 when every counted spec was annotated" do
      run = repository.test_runs.create!(commit_sha: "abc123", annotated_specs_count: 7,
                                         total_specs_count: 7)

      expect(run.annotated_ratio).to eq(100.0)
    end

    # Both ratios read the same counters now, so this is a real agreement rather than the old
    # coincidence: it used to hold only because a factory fabricated a `status: "unannotated"`
    # spec_intent, which the four NOT NULL intent columns make impossible for ingestion to write.
    it "agrees with the repository-wide ratio it is the source of" do
      run = repository.test_runs.create!(commit_sha: "abc123", annotated_specs_count: 2,
                                         total_specs_count: 3)
      create_spec_intent(repository: repository, line_number: 1, test_run: run)
      create_spec_intent(repository: repository, line_number: 2, test_run: run)

      expect(run.annotated_ratio).to eq(66.7)
      expect(repository.annotated_ratio).to eq(run.annotated_ratio)
    end
  end

  describe "#annotated_fraction" do
    # The unit the /ingest API reports. Kept beside #annotated_ratio deliberately: the two differ
    # by 100×, and in a JSON body that gap is invisible until a client is already wrong by it.
    it "is the same share as a 0-1 fraction" do
      run = repository.test_runs.create!(commit_sha: "abc123", annotated_specs_count: 119,
                                         total_specs_count: 142)

      expect(run.annotated_fraction).to eq(0.838)
      expect(run.annotated_ratio).to eq(83.8)
    end

    it "rounds to three decimals" do
      run = repository.test_runs.create!(commit_sha: "abc123", annotated_specs_count: 2,
                                         total_specs_count: 3)

      expect(run.annotated_fraction).to eq(0.667)
    end

    it "is 1.0 when every counted spec was annotated" do
      run = repository.test_runs.create!(commit_sha: "abc123", annotated_specs_count: 7,
                                         total_specs_count: 7)

      expect(run.annotated_fraction).to eq(1.0)
    end

    it "is 0.0 for a run that counted no specs" do
      run = repository.test_runs.create!(commit_sha: "abc123")

      expect(run.annotated_fraction).to eq(0.0)
      expect(run.annotated_fraction).to be_a(Float)
    end

    it "is 0.0 when the counters were never written at all" do
      run = repository.test_runs.create!(commit_sha: "abc123", annotated_specs_count: nil,
                                         total_specs_count: nil)

      expect(run.annotated_fraction).to eq(0.0)
    end
  end
end
