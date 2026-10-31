# frozen_string_literal: true

require "rails_helper"

# `UnannotatedFiles#truncated?` — whether the ranking a surface is about to caption is the whole
# of the area's debt-carrying files or the head of them.
#
# Its own file, on the precedent `unannotated_directories_spec.rb` sets and quotes: a truncation
# predicate that is never exercised on a COMPLETE list is satisfied by `def truncated? = true`,
# which renders "the 3 of the 3 files" as a sample — so this file runs BOTH answers, and the
# boundary fixture (`file_count == rows.size` exactly) that only a strict `>` gets right.
#
# The panel's own examples live in spec/requests/repository_unannotated_examples_spec.rb and read
# the caption those answers produce. What they cannot do is put the boundary under a microscope:
# the cap is ten, so the run where the area's debt-carrying files exactly fill it reads through
# the page as an ordinary untruncated panel and asserts nothing about the comparison.
#
# The runs are INGESTED rather than inserted, on this suite's standing rule: `Ingest::RunRecorder`
# writes the `spec_observations` rows this object groups, and a hand-built fixture would be
# asserting against a shape nothing in production writes.
RSpec.describe UnannotatedFiles do
  let(:repository) { create_repository }
  let(:area) { "spec/models" }

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

  # One unannotated example in each of `count` distinct files of ONE area, so the number of files
  # the area holds carrying debt is exactly `count` and nothing about the fixture depends on how
  # the rows rank against each other.
  def area_holding(count)
    ingest((1..count).map do |i|
      unannotated_spec(file_path: "#{area}/file_#{format('%02d', i)}_spec.rb", line_number: i)
    end)
  end

  describe "an area holding more debt-carrying files than the ranking lists" do
    # The state the caption exists for: a list that is the head of a longer population. Asserted
    # against the two operands as well as the predicate, so an example that passed because the cap
    # stopped working would fail here rather than read as a truncated area.
    # @intent: { entity: "UnannotatedFiles", action: "flag a truncated ranking", behavior: "an area holding 25 debt-carrying files returns exactly the limit of rows, a file_count of 25, and a truthy truncated? predicate", layer: "unit" }
    it "reports the list as cut" do
      files = described_class.for(area_holding(25), area)

      expect(files.rows.size).to eq(SpecObservation::UNANNOTATED_FILES_LIMIT)
      expect(files.file_count).to eq(25)
      expect(files).to be_truncated
    end
  end

  describe "an area whose debt-carrying files all fit" do
    # The OTHER answer, and the one a predicate hard-wired to `true` fails: a complete list
    # captioned as a sample tells a reader there are files it is not showing them when there are
    # none.
    # @intent: { entity: "UnannotatedFiles", action: "report a complete list", behavior: "when every debt-carrying file fits within the cap, rows and file_count agree and truncated? is false so the caption claims no hidden rows", layer: "unit" }
    it "reports the list as complete" do
      files = described_class.for(area_holding(3), area)

      expect(files.rows.size).to eq(3)
      expect(files.file_count).to eq(3)
      expect(files).not_to be_truncated
    end

    # THE BOUNDARY, and the only fixture in this file that can see it. An area holding exactly as
    # many debt-carrying files as the cap lists comes back with `file_count == rows.size` and is
    # COMPLETE — every one of them is on the page. `>=` passes every other example in this file
    # and turns this one area into a list that claims it is hiding rows it is not.
    # @intent: { entity: "UnannotatedFiles", action: "pin the boundary at the limit", behavior: "an area holding exactly as many debt-carrying files as the cap lists is not truncated, distinguishing strict comparison from a >= that would falsely caption a full list as cut", layer: "unit" }
    it "reports an area holding exactly the limit as complete" do
      files = described_class.for(area_holding(SpecObservation::UNANNOTATED_FILES_LIMIT), area)

      expect(files.rows.size).to eq(SpecObservation::UNANNOTATED_FILES_LIMIT)
      expect(files.file_count).to eq(SpecObservation::UNANNOTATED_FILES_LIMIT)
      expect(files).not_to be_truncated
    end
  end

  # A run that wrote no per-example rows at all — the run a client posting only totals writes,
  # which is why it is built through `create_test_run` rather than through an empty ingest: the
  # state is a run WITH a suite count and WITHOUT the detail behind it. The aggregate comes back
  # empty, `file_count` is the honest zero of an empty read, and the comparison must not
  # manufacture a truncation out of two zeroes.
  describe "a run with no per-example rows" do
    # @intent: { entity: "UnannotatedFiles", action: "stay quiet without detail rows", behavior: "a totals-only run reports zero rows, zero debt-carrying files, and never manufactures a truncation from two zeroes", layer: "unit" }
    it "claims no truncation" do
      files = described_class.for(create_test_run(repository: repository, total_specs_count: 900), area)

      expect(files.rows).to be_empty
      expect(files.file_count).to eq(0)
      expect(files).not_to be_truncated
    end
  end

  # A file every one of whose examples is annotated is OMITTED here, where the area ranking keeps
  # the equivalent row at zero — and `file_count` counts the files CARRYING DEBT because the
  # read's window is evaluated after its HAVING. Worth pinning on the presenter as well as on the
  # read: a presenter that had carried the area's whole file count under the same name would
  # caption a truncated list with a population it is not the head of.
  describe "an area whose files are all fully annotated but one" do
    # @intent: { entity: "UnannotatedFiles", action: "count debt-carrying files only", behavior: "a fully-annotated sibling file adds nothing to file_count, which counts the files carrying debt rather than the area's every file", layer: "unit" }
    it "counts only the files carrying debt" do
      run = ingest([unannotated_spec(file_path: "#{area}/order_spec.rb", line_number: 1),
                    annotated_spec(file_path: "#{area}/invoice_spec.rb", line_number: 2)])

      files = described_class.for(run, area)

      expect(files.rows.map(&:path)).to eq(["#{area}/order_spec.rb"])
      expect(files.file_count).to eq(1)
      expect(files).not_to be_truncated
    end
  end

  # The area the list is of is held as ASKED, for the link each row renders and the caption that
  # names its subject — held even when nothing came back, on the rule `SpecDirectoryFiles#path`
  # states one rung over: "no files" without a subject is a sentence about nothing.
  describe "the ask it restates" do
    # @intent: { entity: "UnannotatedFiles", action: "hold the asked area", behavior: "the object carries the area it was asked for, even across an empty read", layer: "unit" }
    it "carries the area it was asked for, through an empty read too" do
      files = described_class.for(create_test_run(repository: repository), area)

      expect(files.spec_directory).to eq(area)
      expect(files.rows).to be_empty
    end
  end
end
