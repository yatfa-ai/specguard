# frozen_string_literal: true

require "rails_helper"

# The NAMED-BASELINE arms of the three run-pair area rows' screen-reader sentences (SPGD-2065).
#
# SPGD-1981 made `?compare_to=<branch>` thread `basis_branch` into `SpecDirectoryGrowth`,
# `SpecDirectoryFileGrowth` and `SpecDirectoryRuntimeGrowth`, so a row's `change_reading` names the
# comparand that was asked for ("the newest run on main") instead of saying "the previous run on
# this branch" of a figure measured against another branch. The same-branch (nil) spellings are
# pinned byte for byte in the per-class specs; every arm of the NAMED spelling is pinned here, so a
# site that went back to the nil spelling (or hard-coded "the previous run") fails an example.
#
# == Why the runs are ingested rather than inserted
#
# Through `Ingest::RunRecorder`, exactly as `spec_directory_file_growth_spec.rb` does it and for its
# reason (SPGD-91): the rows under test are built by each presenter's real `.for` read, with
# `basis_branch: "main"` handed in the way `RepositoryDashboard` hands it, rather than by hand.
RSpec.describe "run-pair row readings under a named baseline (?compare_to=)" do
  let(:repository) { create_repository }

  def ingest(commit_sha:, specs:)
    payload = { commit_sha: commit_sha, branch: "main", total_specs_count: specs.size,
                annotated_specs_count: 0, duration_seconds: 60.0 }
    Ingest::RunRecorder.record(repository, payload, specs: specs.map(&:deep_stringify_keys))
  end

  # `count` examples in one file, timed at `each` seconds, or UNTIMED when `each` is nil. `offset`
  # keeps the two runs' example ids from lining up: no correspondence between runs is ever claimed.
  def file_specs(path, count, each: 1.0, offset: 0)
    Array.new(count) do |i|
      unannotated_spec(file_path: path, line_number: offset + i + 1, duration: each)
    end
  end

  def runs(previous_specs:, latest_specs:)
    ingest(commit_sha: "prev00000000001", specs: previous_specs)
    repository.test_runs.last.update!(created_at: 2.hours.ago)
    ingest(commit_sha: "late00000000002", specs: latest_specs)

    repository.test_runs.order(:created_at).to_a.reverse # => [latest, previous]
  end

  def readings(rows) = rows.to_h { |row| [row.path, row.change_reading] }

  describe SpecDirectoryGrowth do
    def growth(previous_specs:, latest_specs:, basis_branch: "main")
      latest, previous = runs(previous_specs: previous_specs, latest_specs: latest_specs)
      described_class.for(latest, previous, basis_branch: basis_branch)
    end

    # One run pair carrying every arm at once: a new area, a removed one, one that did not move,
    # one that lost examples and one that gained them.
    def every_arm(basis_branch: "main")
      growth(
        previous_specs: file_specs("spec/removed/a_spec.rb", 3) +
                        file_specs("spec/same/a_spec.rb", 2, offset: 100) +
                        file_specs("spec/fewer/a_spec.rb", 6, offset: 200) +
                        file_specs("spec/more/a_spec.rb", 1, offset: 300),
        latest_specs: file_specs("spec/new/a_spec.rb", 4, offset: 400) +
                      file_specs("spec/same/a_spec.rb", 2, offset: 500) +
                      file_specs("spec/fewer/a_spec.rb", 4, offset: 600) +
                      file_specs("spec/more/a_spec.rb", 4, offset: 700),
        basis_branch: basis_branch
      )
    end

    # @intent: { entity: "SpecDirectoryGrowth::Row", action: "name the asked branch in every reading", behavior: "under basis_branch main each of the five change_reading arms (new, removed, unchanged, fewer, more) names the newest run on main and never the previous run on this branch", layer: "unit" }
    it "names the asked branch in every arm of the reading" do
      expect(readings(every_arm.rows)).to eq(
        "spec/new" => "4 examples, an area the newest run on main did not record",
        "spec/removed" => "3 examples in the newest run on main and none now",
        "spec/same" => "unchanged since the newest run on main",
        "spec/fewer" => "2 examples fewer than the newest run on main",
        "spec/more" => "3 examples more than the newest run on main"
      )
    end

    # The contrast that makes the named arm a pin and not a restatement: the same run pair with no
    # ask keeps the default sentences, so neither spelling can pass for the other.
    # @intent: { entity: "SpecDirectoryGrowth::Row", action: "keep the same-branch sentence when no baseline was asked", behavior: "the same run pair built with a nil basis_branch reads the previous run, never the newest run on main", layer: "unit" }
    it "keeps the same-branch spelling when no baseline was asked" do
      expect(readings(every_arm(basis_branch: nil).rows)).to eq(
        "spec/new" => "4 examples, an area the previous run did not record",
        "spec/removed" => "3 examples in the previous run and none now",
        "spec/same" => "unchanged since the previous run on this branch",
        "spec/fewer" => "2 examples fewer than the previous run on this branch",
        "spec/more" => "3 examples more than the previous run on this branch"
      )
    end
  end

  describe SpecDirectoryFileGrowth do
    def file_growth(basis_branch: "main")
      latest, previous = runs(
        previous_specs: file_specs("spec/models/removed_spec.rb", 3) +
                        file_specs("spec/models/same_spec.rb", 2, offset: 100) +
                        file_specs("spec/models/fewer_spec.rb", 6, offset: 200) +
                        file_specs("spec/models/more_spec.rb", 1, offset: 300),
        latest_specs: file_specs("spec/models/new_spec.rb", 4, offset: 400) +
                      file_specs("spec/models/same_spec.rb", 2, offset: 500) +
                      file_specs("spec/models/fewer_spec.rb", 4, offset: 600) +
                      file_specs("spec/models/more_spec.rb", 4, offset: 700)
      )
      parent = SpecDirectoryGrowth.for(latest, previous, basis_branch: basis_branch)

      described_class.for(latest, previous, "spec/models", growth: parent, basis_branch: basis_branch)
    end

    # @intent: { entity: "SpecDirectoryFileGrowth::Row", action: "name the asked branch in every reading", behavior: "under basis_branch main each of the five file change_reading arms (new file, removed file, unchanged, fewer, more) names the newest run on main", layer: "unit" }
    it "names the asked branch in every arm of the reading" do
      expect(readings(file_growth.rows)).to eq(
        "spec/models/new_spec.rb" => "4 examples, a file the newest run on main did not record",
        "spec/models/removed_spec.rb" => "3 examples in the newest run on main and none now",
        "spec/models/same_spec.rb" => "unchanged since the newest run on main",
        "spec/models/fewer_spec.rb" => "2 examples fewer than the newest run on main",
        "spec/models/more_spec.rb" => "3 examples more than the newest run on main"
      )
    end

    # @intent: { entity: "SpecDirectoryFileGrowth::Row", action: "keep the same-branch sentence when no baseline was asked", behavior: "the same run pair built with a nil basis_branch reads the previous run, never the newest run on main", layer: "unit" }
    it "keeps the same-branch spelling when no baseline was asked" do
      expect(readings(file_growth(basis_branch: nil).rows)).to eq(
        "spec/models/new_spec.rb" => "4 examples, a file the previous run did not record",
        "spec/models/removed_spec.rb" => "3 examples in the previous run and none now",
        "spec/models/same_spec.rb" => "unchanged since the previous run on this branch",
        "spec/models/fewer_spec.rb" => "2 examples fewer than the previous run on this branch",
        "spec/models/more_spec.rb" => "3 examples more than the previous run on this branch"
      )
    end
  end

  describe SpecDirectoryRuntimeGrowth do
    # Every arm at once. `spec/timed` is timed in both runs so the panel as a whole is comparable
    # and the per-area untimed arms are reachable at all; `spec/gap` is UNTIMED in the earlier run
    # only, which is the `untimed_reading` arm that names the comparand.
    def runtime_growth(basis_branch: "main")
      latest, previous = runs(
        previous_specs: file_specs("spec/removed/a_spec.rb", 2, each: 1.5) +
                        file_specs("spec/same/a_spec.rb", 2, each: 1.0, offset: 100) +
                        file_specs("spec/faster/a_spec.rb", 2, each: 3.0, offset: 200) +
                        file_specs("spec/slower/a_spec.rb", 2, each: 1.0, offset: 300) +
                        file_specs("spec/gap/a_spec.rb", 2, each: nil, offset: 400),
        latest_specs: file_specs("spec/new/a_spec.rb", 2, each: 2.0, offset: 500) +
                      file_specs("spec/same/a_spec.rb", 2, each: 1.0, offset: 600) +
                      file_specs("spec/faster/a_spec.rb", 2, each: 1.0, offset: 700) +
                      file_specs("spec/slower/a_spec.rb", 2, each: 3.0, offset: 800) +
                      file_specs("spec/gap/a_spec.rb", 2, each: 1.0, offset: 900)
      )

      described_class.for(latest, previous, basis_branch: basis_branch)
    end

    # @intent: { entity: "SpecDirectoryRuntimeGrowth::Row", action: "name the asked branch in every reading", behavior: "under basis_branch main each of the six runtime change_reading arms (new, removed, same time, faster, slower, untimed on the baseline side) names the newest run on main", layer: "unit" }
    it "names the asked branch in every arm of the reading" do
      growth = runtime_growth

      expect(growth).to be_comparable
      expect(readings(growth.rows)).to eq(
        "spec/new" => "4.00s of examples, an area the newest run on main did not record",
        "spec/removed" => "3.00s of examples in the newest run on main and none now",
        "spec/same" => "took the same time as it did in the newest run on main",
        "spec/faster" => "4.00s faster than the newest run on main",
        "spec/slower" => "4.00s slower than the newest run on main",
        "spec/gap" => "the newest run on main reported no timing for this area, so there is nothing to compare"
      )
    end

    # @intent: { entity: "SpecDirectoryRuntimeGrowth::Row", action: "keep the same-branch sentence when no baseline was asked", behavior: "the same run pair built with a nil basis_branch reads the previous run, never the newest run on main", layer: "unit" }
    it "keeps the same-branch spelling when no baseline was asked" do
      expect(readings(runtime_growth(basis_branch: nil).rows)).to eq(
        "spec/new" => "4.00s of examples, an area the previous run did not record",
        "spec/removed" => "3.00s of examples in the previous run and none now",
        "spec/same" => "took the same time as it did in the previous run on this branch",
        "spec/faster" => "4.00s faster than the previous run on this branch",
        "spec/slower" => "4.00s slower than the previous run on this branch",
        "spec/gap" => "the previous run on this branch reported no timing for this area, so there is nothing to compare"
      )
    end

    # The two untimed-AND-absent compound arms spell the comparand too: an area that is new (or
    # removed) and whose only side is untimed says so with the short noun.
    # @intent: { entity: "SpecDirectoryRuntimeGrowth::Row", action: "name the asked branch in the compound new and removed untimed readings", behavior: "a new area this run did not time and a removed area the baseline did not time each name the newest run on main", layer: "unit" }
    it "names the asked branch where a new or removed area is also untimed" do
      latest, previous = runs(
        previous_specs: file_specs("spec/timed/a_spec.rb", 1) +
                        file_specs("spec/removed/a_spec.rb", 2, each: nil, offset: 100),
        latest_specs: file_specs("spec/timed/a_spec.rb", 1, offset: 200) +
                      file_specs("spec/new/a_spec.rb", 2, each: nil, offset: 300)
      )
      rows = readings(described_class.for(latest, previous, basis_branch: "main").rows)

      expect(rows["spec/new"]).to eq(
        "an area the newest run on main did not record, and this run reported no timing for it"
      )
      expect(rows["spec/removed"]).to eq(
        "an area this run does not have, and the newest run on main reported no timing for it"
      )
    end
  end
end
