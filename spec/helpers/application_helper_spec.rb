# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationHelper, type: :helper do
  describe "#test_run_annotated_share" do
    let(:repository) { create_repository(user: create_user) }

    # @intent: { entity: "ApplicationHelper", action: "word annotated share", behavior: "a measured run prints the 0-100 percentage, delimited counts and the carry-an-@intent sentence, so 5,000 of 20,000 reads 25.0% and never 0.25%", layer: "unit" }
    it "prints the percentage (not the 0-1 fraction) with delimited counts" do
      run = create_test_run(repository: repository, total_specs_count: 20_000, annotated_specs_count: 5_000)

      expect(helper.test_run_annotated_share(run))
        .to eq("25.0% — 5,000 of 20,000 tests carry an @intent.")
    end

    # @intent: { entity: "ApplicationHelper", action: "word annotated share", behavior: "a measured run with no annotated tests reads 0.0% — 0 of 7", layer: "unit" }
    it "states a real zero for a measured, fully unannotated run" do
      run = create_test_run(repository: repository, total_specs_count: 7, annotated_specs_count: 0)

      expect(helper.test_run_annotated_share(run)).to eq("0.0% — 0 of 7 tests carry an @intent.")
    end

    # @intent: { entity: "ApplicationHelper", action: "word annotated share", behavior: "a run that reported no tests, and a missing run, yield nil rather than a 0.0% share", layer: "unit" }
    it "returns nil when no suite was measured" do
      run = create_test_run(repository: repository, total_specs_count: 0, annotated_specs_count: 0)

      expect(helper.test_run_annotated_share(run)).to be_nil
      expect(helper.test_run_annotated_share(nil)).to be_nil
    end
  end
end
