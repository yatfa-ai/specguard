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

  # The one formatting seam over `duration_seconds`. Both surfaces that render the column go
  # through it, so what it decides here is what the page shows in both places.
  describe "#duration_label" do
    def run_lasting(seconds)
      repository.test_runs.create!(commit_sha: "abc123", duration_seconds: seconds)
    end

    it "keeps the tenth for a suite that finished inside a minute" do
      expect(run_lasting(12.5).duration_label).to eq("12.5s")
      expect(run_lasting(1.0).duration_label).to eq("1.0s")
    end

    # The headline case: `372.4s` is a true number nobody reads as "six minutes".
    it "reads a longer run in minutes and seconds rather than raw seconds" do
      expect(run_lasting(372.4).duration_label).to eq("6m 12s")
      expect(run_lasting(59.4).duration_label).to eq("59.4s")
      expect(run_lasting(60.0).duration_label).to eq("1m")
    end

    it "reads a run over an hour in hours, minutes and seconds" do
      expect(run_lasting(3600.0).duration_label).to eq("1h 0m")
      expect(run_lasting(3612.0).duration_label).to eq("1h 0m 12s")
      expect(run_lasting(7325.0).duration_label).to eq("2h 2m 5s")
    end

    # A zero minute that sits between two non-zero parts has to survive: dropping it turns
    # "one hour and twelve seconds" into a string that reads as "one hour twelve minutes".
    it "keeps a zero minutes part when there are hours in front of it" do
      expect(run_lasting(3612.0).duration_label).not_to eq("1h 12s")
    end

    # `duration_seconds` is nullable and Ingest::Payload accepts nil explicitly, so "the client
    # sent no timing" is a state the column can be in — and it is not "the run took no time".
    it "says a missing timing was not reported rather than calling it zero" do
      run = run_lasting(nil)

      expect(run.duration_label).to eq("not reported")
      expect(run.duration_label).not_to eq("0.0s")
      expect(run).not_to be_duration_reported
    end

    # The other half of that distinction, and the reason `duration_reported?` asks `nil?` rather
    # than `present?`: a genuinely measured zero is a measurement and must print as one.
    it "prints a run that genuinely measured zero as zero" do
      run = run_lasting(0.0)

      expect(run.duration_label).to eq("0.0s")
      expect(run).to be_duration_reported
    end
  end

  # The database half of the run-identity invariant. `Ingest::RunRecorder` looks a run up before
  # inserting, but a lookup and an insert are two statements and four shards POST at once — the
  # index is what makes the loser of that race an exception to rescue rather than a second row
  # with half the suite in it.
  describe "the run identity" do
    it "refuses a second row for a run this repository has already recorded" do
      repository.test_runs.create!(commit_sha: "deadbee", ci_run_id: "gha-42")

      expect { repository.test_runs.create!(commit_sha: "deadbee", ci_run_id: "gha-42") }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "lets two repositories record the same CI run id" do
      other = create_repository(user: create_user(github_uid: "2002", github_handle: "hubot"),
                                github_full_name: "acme/ledger")
      repository.test_runs.create!(commit_sha: "deadbee", ci_run_id: "gha-42")

      expect { other.test_runs.create!(commit_sha: "deadbee", ci_run_id: "gha-42") }
        .to change(TestRun, :count).by(1)
    end

    # The local path the roadmap's DoD protects: a laptop `bundle exec rspec` has no CI variables
    # to read, so every one of its runs is unnamed and every one still gets a row of its own.
    it "lets a repository record any number of runs that no CI provider named" do
      expect do
        3.times { repository.test_runs.create!(commit_sha: "deadbee", ci_run_id: nil) }
      end.to change(TestRun, :count).by(3)
    end
  end
end
