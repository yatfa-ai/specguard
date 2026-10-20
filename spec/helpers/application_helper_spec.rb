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

  describe "#test_run_pyramid_share" do
    let(:repository) { create_repository(user: create_user) }

    # The mixes are derived from stored rows (`layer_counts`' real source), never handed to the
    # helper as a literal hash — the same rule the repositories grid's `observe_layers` follows.
    def observe_layers(run, layer, count)
      count.times do |index|
        run.spec_observations.create!(
          repository: repository, example_id: "./spec/a_spec.rb[1:#{layer}#{index}]",
          file_path: "spec/a_spec.rb", spec_file_path: "spec/a_spec.rb", line_number: index + 1,
          status: "unannotated", intent_layer: layer == :undeclared ? nil : layer.to_s
        )
      end
    end

    # @intent: { entity: "ApplicationHelper", action: "word pyramid share", behavior: "a run whose mix is 2 unit, 2 integration, 1 request, 1 system prints Request+system 33.3% of declared layers — 2 of 6 declared tests.", layer: "unit" }
    it "prints the percentage (not the 0-1 fraction) with the operands and their denominator" do
      run = create_test_run(repository: repository, total_specs_count: 6, annotated_specs_count: 6)
      observe_layers(run, :unit, 2)
      observe_layers(run, :integration, 2)
      observe_layers(run, :request, 1)
      observe_layers(run, :system, 1)

      expect(helper.test_run_pyramid_share(run))
        .to eq("Request+system 33.3% of declared layers — 2 of 6 declared tests.")
    end

    # @intent: { entity: "ApplicationHelper", action: "word pyramid share", behavior: "a run of ten unit tests reads Request+system 0.0% of declared layers — 0 of 10 declared tests.", layer: "unit" }
    it "states a real zero, with its denominator, for a measured all-unit run" do
      run = create_test_run(repository: repository, total_specs_count: 10, annotated_specs_count: 10)
      observe_layers(run, :unit, 10)

      expect(helper.test_run_pyramid_share(run))
        .to eq("Request+system 0.0% of declared layers — 0 of 10 declared tests.")
    end

    # @intent: { entity: "ApplicationHelper", action: "word pyramid share", behavior: "a run whose every example is undeclared, a run that recorded no per-example rows, and a missing run yield nil rather than a 0.0% of declared layers", layer: "unit" }
    it "returns nil when nothing is declared" do
      undeclared = create_test_run(repository: repository, total_specs_count: 3)
      observe_layers(undeclared, :undeclared, 3)
      unmeasured = create_test_run(repository: repository, commit_sha: "cafe3381n",
                                   total_specs_count: 4, annotated_specs_count: 4)

      expect(helper.test_run_pyramid_share(undeclared)).to be_nil
      expect(helper.test_run_pyramid_share(unmeasured)).to be_nil
      expect(helper.test_run_pyramid_share(nil)).to be_nil
    end
  end
end
