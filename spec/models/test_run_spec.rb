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

    it "rounds the same way the repository-wide ratio does" do
      run = repository.test_runs.create!(commit_sha: "abc123", annotated_specs_count: 2,
                                         total_specs_count: 3)
      create_spec_intent(repository: repository, line_number: 1, status: "annotated")
      create_spec_intent(repository: repository, line_number: 2, status: "annotated")
      create_spec_intent(repository: repository, line_number: 3, status: "unannotated")

      expect(run.annotated_ratio).to eq(repository.annotated_ratio)
    end
  end
end
