# frozen_string_literal: true

require "rails_helper"

# `UnannotatedDirectories#truncated?` — whether the ranking a surface is about to caption is the
# whole of the run's areas or the head of them.
#
# Its own file, and specifically for the reason this object's own comment gave when it deleted this
# predicate the first time: *"a predicate no surface calls is a claim this object makes that nothing
# has ever checked"*, and it named the condition for the predicate coming back — the dashboard panel
# that calls it, *"with the spec that runs it"*. This is that spec, and it runs BOTH answers rather
# than only the interesting one: a truncation predicate that is never exercised on a COMPLETE list
# is satisfied by `def truncated? = true`, which renders "the 3 of the 3 directories" as a sample.
#
# The panel's own examples live in spec/requests/repository_unannotated_directories_spec.rb and read
# the caption those answers produce. What they cannot do is put the boundary under a microscope: the
# cap is ten, so the run where `directory_count == rows.size` exactly — the one `>` gets right and
# `>=` gets wrong on every complete list — is a fixture that reads through the page as an ordinary
# untruncated panel and asserts nothing about the comparison.
#
# The runs are INGESTED rather than inserted, on this suite's standing rule: `Ingest::RunRecorder`
# writes the `spec_observations` rows this object groups, and a hand-built fixture would be asserting
# against a shape nothing in production writes.
RSpec.describe UnannotatedDirectories do
  let(:repository) { create_repository }

  def ingest(specs)
    Ingest::RunRecorder.record(
      repository,
      { commit_sha: "feedfacecafe0001", branch: "main", total_specs_count: specs.size,
        annotated_specs_count: specs.count { |spec| spec[:status] == "annotated" },
        duration_seconds: 60.0 },
      specs: specs.map(&:deep_stringify_keys)
    )
    repository.latest_test_run
  end

  # One unannotated example in each of `count` distinct areas, so the number of areas the run touched
  # is exactly `count` and nothing about the fixture depends on how the rows rank against each other.
  def run_touching(count)
    ingest((1..count).map do |i|
      unannotated_spec(file_path: "spec/d#{format('%02d', i)}/a_spec.rb", line_number: i)
    end)
  end

  describe "a run with more areas than the ranking lists" do
    # The state the caption exists for: a list that is the head of a longer population. Asserted
    # against the two operands as well as the predicate, so an example that passed because the cap
    # stopped working would fail here rather than read as a truncated run.
    it "reports the list as cut" do
      directories = described_class.for(run_touching(25))

      expect(directories.rows.size).to eq(SpecObservation::UNANNOTATED_DIRECTORIES_LIMIT)
      expect(directories.directory_count).to eq(25)
      expect(directories).to be_truncated
    end
  end

  describe "a run whose areas all fit" do
    # The OTHER answer, and the one a predicate hard-wired to `true` fails: a complete list captioned
    # as a sample tells a reader there are areas it is not showing them when there are none.
    it "reports the list as complete" do
      directories = described_class.for(run_touching(3))

      expect(directories.rows.size).to eq(3)
      expect(directories.directory_count).to eq(3)
      expect(directories).not_to be_truncated
    end

    # THE BOUNDARY, and the only fixture in either file that can see it. A run touching exactly as
    # many areas as the cap lists comes back with `directory_count == rows.size` and is COMPLETE —
    # every area it touched is on the page. `>=` passes every other example in this file and turns
    # this one run into a list that claims it is hiding rows it is not.
    it "reports a run touching exactly the limit as complete" do
      directories = described_class.for(run_touching(SpecObservation::UNANNOTATED_DIRECTORIES_LIMIT))

      expect(directories.rows.size).to eq(SpecObservation::UNANNOTATED_DIRECTORIES_LIMIT)
      expect(directories.directory_count).to eq(SpecObservation::UNANNOTATED_DIRECTORIES_LIMIT)
      expect(directories).not_to be_truncated
    end
  end

  # A run that wrote no per-example rows at all — the run a client posting only totals writes, which
  # is why it is built through `create_test_run` rather than through an empty ingest: the state is a
  # run WITH a suite count and WITHOUT the detail behind it. The aggregate comes back empty,
  # `directory_count` is the honest zero of an empty read, and the comparison must not manufacture a
  # truncation out of two zeroes. `#recorded?` is what a surface branches on here — this pins that the
  # predicate stays quiet in the state where there is nothing to be the head of.
  describe "a run with no per-example rows" do
    it "claims no truncation" do
      directories = described_class.for(create_test_run(repository: repository, total_specs_count: 900))

      expect(directories).not_to be_recorded
      expect(directories.directory_count).to eq(0)
      expect(directories).not_to be_truncated
    end
  end

  # The predicate is a fact about the LIST, not about the run's debt — an area every one of whose
  # examples is annotated is a row here (see the class comment), so a fully annotated run past the
  # cap is truncated exactly as a run drowning in debt is. Worth pinning because the caption that
  # calls this sits beside a "no unannotated tests in this run" state, and a predicate that quietly
  # tracked DEBT rather than LENGTH would make the two disagree on precisely that run.
  describe "a fully annotated run with more areas than the ranking lists" do
    it "reports the list as cut, on length rather than on debt" do
      directories = described_class.for(ingest((1..25).map do |i|
        annotated_spec(file_path: "spec/d#{format('%02d', i)}/a_spec.rb", line_number: i)
      end))

      expect(directories.rows.map(&:unannotated_count).uniq).to eq([0])
      expect(directories).to be_truncated
    end
  end
end
