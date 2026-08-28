# frozen_string_literal: true

require "rails_helper"

# `?limit=` on `repositories#show` — the widening ask the two run-grain duration rollups honour,
# read through the shared `RequestedLimitParam` concern exactly as `GET /api/v1/repository` reads
# it (pinned in spec/requests/api/v1/repository_limit_param_spec.rb).
#
# Its own file, beside the two panel files it widens rather than inside either: the parameter names
# a magnitude, not a panel, and every example below asserts something about BOTH panels — the
# pairing is the contract. A file living inside `repository_spec_directory_durations_spec.rb` would
# make half of every assertion look like it had drifted in from the sibling.
#
# The fixture is one run of fifteen timed examples in fifteen distinct files under fifteen distinct
# directories, built through `Ingest::RunRecorder` rather than inserted by hand — a hand-built
# fixture would assert against a row shape nothing in production writes (the rule
# `repository_spec_directory_durations_spec.rb` states for its own builder).
RSpec.describe "Repository heaviest rollup limit parameter", type: :request do
  before { @user = sign_in_via_github }

  def files_panel = Capybara.string(response.body).find("#spec-file-durations")
  def directories_panel = Capybara.string(response.body).find("#spec-directory-durations")

  def file_row_paths = files_panel.all("tbody tr").map { it.first("td").text.strip }
  def directory_row_paths = directories_panel.all("tbody tr").map { it.first("td").text.strip }

  def ingest(repository, specs, commit_sha: "feedfacecafe0714")
    Ingest::RunRecorder.record(
      repository,
      { commit_sha: commit_sha, branch: "main", total_specs_count: specs.size,
        annotated_specs_count: 0, duration_seconds: 60.0 },
      specs: specs.map(&:deep_stringify_keys)
    )
  end

  # Fifteen files, each the sole file of its own directory, each timed, each distinct in cost so
  # the ranking is a strict order rather than a tie the planner resolves. Fifteen is one past BOTH
  # shipped caps, so both panels truncate by default — the state every widening example below
  # turns on — and is under `MAX_LIMIT`, so `?limit=15` is the "covers the population" case and the
  # clamp never silently interferes.
  def fifteen_file_run
    repository = create_repository(user: @user)
    specs = (1..15).map do |i|
      unannotated_spec(file_path: "spec/d#{format('%02d', i)}/a#{format('%02d', i)}_spec.rb",
                       line_number: i, duration: i.to_f)
    end
    ingest(repository, specs)
    repository
  end

  describe "without the ask" do
    it "renders both rollups at their shipped defaults" do
      get repository_path(fifteen_file_run)

      expect(file_row_paths.size).to eq(SpecObservation::HEAVIEST_FILES_LIMIT)
      expect(directory_row_paths.size).to eq(SpecObservation::HEAVIEST_DIRECTORIES_LIMIT)
      expect(files_panel.find("#spec-file-durations-basis"))
        .to have_text("The 10 heaviest of the 15 files", normalize_ws: true)
      expect(directories_panel.find("#spec-directory-durations-basis"))
        .to have_text("The 10 heaviest of the 15 directories", normalize_ws: true)
    end

    # Criterion 7's web half: the ask must add ZERO queries when absent, and widening one adds none
    # either — a LIMIT value changes rows returned, not round trips. Pinned as an equality between
    # two renders of the same fixture rather than an absolute number, which this page already pins
    # elsewhere (`repositories_spec.rb`'s budget of 22) and which would rot on the next unrelated
    # panel. `count_queries` comes from spec/support/query_capture.rb.
    it "issues the same number of queries with the ask as without it" do
      repository = fifteen_file_run
      get repository_path(repository) # warm the schema/statement caches
      without = count_queries { get repository_path(repository) }
      widened = count_queries { get repository_path(repository, limit: 15) }

      expect(widened).to eq(without)
    end
  end

  describe "with a widening ask" do
    it "widens both rollups and restates each population honestly" do
      get repository_path(fifteen_file_run, limit: 12)

      expect(file_row_paths.size).to eq(12)
      expect(directory_row_paths.size).to eq(12)
      # Both captions still disclose: a widened list that still cuts must still say so.
      expect(files_panel.find("#spec-file-durations-basis"))
        .to have_text("The 12 heaviest of the 15 files", normalize_ws: true)
      expect(directories_panel.find("#spec-directory-durations-basis"))
        .to have_text("The 12 heaviest of the 15 directories", normalize_ws: true)
    end

    # The "All N" branch that already existed, now reachable: an ask wider than the population
    # makes the list complete, and a complete list must not wear the shape of a sample.
    it "renders the all-files branch when the ask covers the population" do
      get repository_path(fifteen_file_run, limit: 15)

      expect(file_row_paths.size).to eq(15)
      expect(files_panel.find("#spec-file-durations-basis"))
        .to have_text("All 15 files the run named above recorded", normalize_ws: true)
      expect(files_panel.find("#spec-file-durations-basis"))
        .to have_no_text("heaviest of the")
      expect(directories_panel.find("#spec-directory-durations-basis"))
        .to have_text("All 15 directories the run named above recorded", normalize_ws: true)
    end

    # Criterion 3 on the surface a human reads: an over-large ask is CLAMPED, and the clamp is
    # visible in what rendered rather than silently served. The clamped size itself (200) exceeds
    # this fixture's population, so what the page shows is the complete-list state — the honest
    # statement of "we gave you at most the ceiling, and that was everything".
    it "clamps an ask past the ceiling rather than erroring" do
      get repository_path(fifteen_file_run, limit: 99_999)

      expect(response).to have_http_status(:ok)
      expect(file_row_paths.size).to eq(15)
      expect(files_panel.find("#spec-file-durations-basis"))
        .to have_text("All 15 files the run named above recorded", normalize_ws: true)
    end

    # Criterion 6: widening one panel closes no open drill-in, and — the reciprocity — a drill-in
    # opened from a widened page keeps the widening. Both halves are `drill_down_path`'s carry set,
    # asserted here on the links the widened page itself renders rather than on the helper in
    # isolation: what a reader can click is the contract.
    it "carries the widening through every drill-in link, and the drill-in back through the widening" do
      get repository_path(fifteen_file_run, limit: 12, spec_file: "spec/d01/a01_spec.rb")

      # A row link on the widened page keeps BOTH the file it opens and the widening in the URL.
      # `d04` is the LAST row of the widened window, the position most likely to lose a carried
      # ask to an off-by-one, and `d01` is opened as the page's own drill-in.
      row_link = files_panel.find("tbody a", text: "spec/d04/a04_spec.rb")
      expect(row_link[:href]).to include("limit=12")
      expect(row_link[:href]).to include("spec_file=spec%2Fd04%2Fa04_spec.rb")

      # And the widening control itself closes nothing already open.
      widen_link = files_panel.find("a", text: /Show up to/)
      expect(widen_link[:href]).to include("limit=#{RequestedLimitParam::MAX_LIMIT}")
      expect(widen_link[:href]).to include("spec_file=spec%2Fd01%2Fa01_spec.rb")
    end

    # A spelling `Kernel#Integer` accepts that reads as "obviously invalid": a BASE PREFIX. This
    # example exists to keep the guard's rationale comment honest — the comment once claimed
    # `"0x10"` answers nil when it parses to 16, and only an example asserting the real behaviour
    # (a base prefix widens to the value it parses to) keeps a future maintainer from
    # re-believing the false half.
    it "honours a base-prefixed spelling as the magnitude it parses to" do
      get repository_path(fifteen_file_run, limit: "0xc")

      expect(file_row_paths.size).to eq(12)
      expect(files_panel.find("#spec-file-durations-basis"))
        .to have_text("The 12 heaviest of the 15 files", normalize_ws: true)
    end

    # The same for whitespace-padded strings: `Integer(" 12 ")` answers 12, so the ask widens —
    # pinned so the guard's "what Kernel#Integer accepts, we honour" rule has both spellings
    # standing behind it.
    it "honours a whitespace-padded spelling as the magnitude it parses to" do
      get repository_path(fifteen_file_run, limit: " 12 ")

      expect(file_row_paths.size).to eq(12)
    end

    it "offers the way back to the shipped default once widened" do
      get repository_path(fifteen_file_run, limit: 12)

      expect(files_panel).to have_link("Back to the #{SpecObservation::HEAVIEST_FILES_LIMIT} heaviest")
      expect(files_panel.find("a", text: "Back to the #{SpecObservation::HEAVIEST_FILES_LIMIT} heaviest")[:href])
        .not_to include("limit=12")
    end
  end

  describe "a limit parameter that is not a widening" do
    # The no-ask answer is the DEFAULT render: both panels at ten rows, both captions saying so.
    # Not merely a 200 — a guard that swallowed every value would also answer 200, and only this
    # assertion tells the no-ask answer from an accidental widening. The positive-path examples
    # above are what prove the parameter does anything at all.
    def expect_limit_param_treated_as_no_ask(query)
      get repository_path(fifteen_file_run, params: query)

      expect(response).to have_http_status(:ok)
      expect(file_row_paths.size).to eq(SpecObservation::HEAVIEST_FILES_LIMIT)
      expect(directory_row_paths.size).to eq(SpecObservation::HEAVIEST_DIRECTORIES_LIMIT)
      expect(files_panel.find("#spec-file-durations-basis"))
        .to have_text("The 10 heaviest of the 15 files", normalize_ws: true)
    end

    it_behaves_like "a surface that treats a non-widening limit parameter as no ask"
  end
end
