# frozen_string_literal: true

require "rails_helper"

# The "What changed" comparison basis — the previous run every delta on the console page is
# measured against — named by sha at eighteen sentences across five partials, and since SPGD-1860
# every naming is the family's read gesture: a link into that run's own page, anchored at the
# Summary (`drill_down_path(@repository, commit_sha: <full sha>, anchor: "summary")`), the same
# pattern _near_duplicate_clusters, _recent_runs and _unstable_test_runs already use.
#
# What this file guards that the sentence specs cannot:
#
#   * THE HREF IS THE FULL SHA. `latest_test_run_for_commit` matches exactly, so a href carrying
#     the seven visible characters would resolve nil, silently fall back to the newest run, and
#     only the run-anchor notice would say so. Every example recomputes the expected path from
#     `repository_path` the way spec/requests/repository_window_slowest_tests_spec.rb does —
#     deliberately not through `drill_down_path` itself, which reads controller ivars this spec
#     does not have.
#
#   * THE LINK IS REAL MARKUP. The seven EmptyState-interpolated sentences travel through a
#     `with_description` block because the component's `description:` param renders ESCAPED.
#     Capybara's `.text` decodes entities, so no text assertion can tell a rendered anchor from an
#     escaped one — every empty-state example asserts on the ELEMENT, and the component spec pins
#     the escaped negative.
#
#   * +0 QUERIES. Every link is built from the one `@previous_test_run` row the dashboard already
#     loads on every render; a link site that re-read it would show up as a second
#     `(test_runs.created_at, test_runs.id) < (?, ?)` statement — the row-value shape only
#     `previous_test_run_on_branch` issues (`<=` is the trajectory's, and does not match).
RSpec.describe "Repository previous-run comparison-basis links", type: :request do
  # The two shas every fixture names its runs by — module constants so the expected-href helper
  # can default to the basis run.
  PREV_SHA = "prev00000000001"
  LATEST_SHA = "late00000000002"

  before { @user = sign_in_via_github }

  def new_repository
    @repository_seq = (@repository_seq || 0) + 1

    create_repository(user: @user, github_full_name: "acme/service-#{@repository_seq}")
  end

  # The expected destination of a basis link: the named run's page at the Summary. Recomputed from
  # the router, not from the view helper, on the documented reasoning of the window-slowest file.
  def expected_prev_href(repository, sha = PREV_SHA, **asks)
    repository_path(repository, commit_sha: sha, anchor: "summary", **asks)
  end

  # One run on the wire. `specs:` omitted is the totals-only client; `duration:` rides the payload
  # so the runtime basis has a wall clock to difference.
  def ingest(repository, commit_sha:, specs: nil, branch: "main", total: nil, duration: 60.0, at: nil)
    payload = { commit_sha: commit_sha, branch: branch,
                total_specs_count: total || specs&.size || 0,
                annotated_specs_count: 0, duration_seconds: duration }
    options = specs.nil? ? {} : { specs: specs.map(&:deep_stringify_keys) }
    run = Ingest::RunRecorder.record(repository, payload, **options)
    TestRun.where(id: run.id).update_all(created_at: at) if at
    run
  end

  # One example in an area, with its own timing and (when `layer:` is given) a declared intent —
  # one corpus serving every panel this file reads: area counts, area times, declared layers, and
  # the two basis notes.
  def area_specs(directory, count, each: 1.0, offset: 0, layer: nil, file: nil)
    Array.new(count) do |i|
      file_path = file || "#{directory}/a_spec.rb"
      line = offset + i + 1
      if layer
        annotated_spec(file_path: file_path, line_number: line, duration: each, layer: layer,
                       name: "#{layer} example #{offset + i}")
      else
        unannotated_spec(file_path: file_path, line_number: line, duration: each)
      end
    end
  end

  # The shared corpus: two comparable runs whose counts AND times AND declared layers all move, so
  # every basis sentence on the page renders at once.
  def moved_suite
    repository = new_repository
    ingest(repository, commit_sha: PREV_SHA, at: 2.hours.ago, duration: 90.0,
                      specs: area_specs("spec/models", 3, each: 1.0) +
                             area_specs("spec/models", 2, each: 2.0, offset: 50, layer: "unit") +
                             area_specs("spec/legacy", 4, each: 0.5, offset: 100))
    ingest(repository, commit_sha: LATEST_SHA, at: 1.minute.ago, duration: 510.0,
                      specs: area_specs("spec/models", 5, each: 5.0, offset: 300) +
                             area_specs("spec/models", 1, each: 3.0, offset: 350, layer: "unit") +
                             area_specs("spec/legacy", 2, each: 0.25, offset: 400))
    repository
  end

  # An element-scoped link read: every anchor whose text is a previous-run sha, with its href.
  # Element-scoped, never page-scoped, on the growth file's rule — several panels name runs and
  # some already link them (the run tables), so a page-wide search satisfies this suite with the
  # basis sites deleted.
  def sha_links_within(scope, sha = PREV_SHA)
    scope.all("a").select { |a| a.text.squish == sha.first(7) }
  end

  describe "the two comparison-basis notes on the Overview" do
    it "links the suite-size basis to the run it is measured against" do
      repository = moved_suite

      get repository_path(repository)

      basis = Capybara.string(response.body).find("#suite-size-basis")
      expect(basis).to have_text("measured against #{PREV_SHA.first(7)}", normalize_ws: true)
      links = sha_links_within(basis)
      expect(links.size).to eq(1)
      expect(links.sole[:href]).to eq(expected_prev_href(repository))
    end

    it "links the runtime basis to the same run" do
      repository = moved_suite

      get repository_path(repository)

      basis = Capybara.string(response.body).find("#runtime-basis")
      expect(basis).to have_text("The total runtime is measured against #{PREV_SHA.first(7)}",
                                 normalize_ws: true)
      links = sha_links_within(basis)
      expect(links.size).to eq(1)
      expect(links.sole[:href]).to eq(expected_prev_href(repository))
    end

    it "links the sha where the previous run reported no tests, in the basis note's own words" do
      repository = new_repository
      repository.test_runs.create!(commit_sha: PREV_SHA, branch: "main", total_specs_count: 0,
                                   created_at: 2.hours.ago)
      ingest(repository, commit_sha: LATEST_SHA, total: 40)

      get repository_path(repository)

      basis = Capybara.string(response.body).find("#suite-size-basis")
      expect(basis).to have_text("(#{PREV_SHA.first(7)}) reported no tests", normalize_ws: true)
      links = sha_links_within(basis)
      expect(links.size).to eq(1)
      expect(links.sole[:href]).to eq(expected_prev_href(repository))
    end

    it "renders no link where there is no previous run to name" do
      repository = new_repository
      ingest(repository, commit_sha: LATEST_SHA, total: 40)

      get repository_path(repository)

      basis = Capybara.string(response.body).find("#suite-size-basis")
      expect(basis).to have_text("No earlier run on main", normalize_ws: true)
      expect(sha_links_within(basis)).to be_empty
    end

    it "renders no link where the run names no branch and cannot be placed in a history" do
      repository = new_repository
      ingest(repository, commit_sha: LATEST_SHA, total: 40, branch: nil)

      get repository_path(repository)

      basis = Capybara.string(response.body).find("#suite-size-basis")
      expect(basis).to have_text("reported no branch", normalize_ws: true)
      expect(sha_links_within(basis)).to be_empty
    end
  end

  describe "the declared-layer movement lines" do
    it "links both layer lines to the run their deltas are measured against" do
      repository = moved_suite

      get repository_path(repository)

      page = Capybara.string(response.body)
      %w[#layer-run-growth #layer-runtime-growth].each do |id|
        line = page.find(id)
        expect(line).to have_text("Since #{PREV_SHA.first(7)} on main:", normalize_ws: true)
        links = sha_links_within(line)
        expect(links.size).to eq(1)
        expect(links.sole[:href]).to eq(expected_prev_href(repository))
      end
    end
  end

  describe "the area panels' basis captions" do
    it "links the count panel's caption" do
      repository = moved_suite

      get repository_path(repository)

      basis = Capybara.string(response.body).find("#spec-directory-growth-basis")
      expect(basis).to have_text("measured between this run and #{PREV_SHA.first(7)}", normalize_ws: true)
      links = sha_links_within(basis)
      expect(links.size).to eq(1)
      expect(links.sole[:href]).to eq(expected_prev_href(repository))
    end

    it "links the time panel's caption" do
      repository = moved_suite

      get repository_path(repository)

      basis = Capybara.string(response.body).find("#spec-directory-runtime-growth-basis")
      expect(basis).to have_text("measured between this run and #{PREV_SHA.first(7)}", normalize_ws: true)
      links = sha_links_within(basis)
      expect(links.size).to eq(1)
      expect(links.sole[:href]).to eq(expected_prev_href(repository))
    end

    it "links the files-in-directory caption and carries the open drill-in beside the sha ask" do
      repository = moved_suite

      get repository_path(repository, params: { spec_directory: "spec/models" })

      basis = Capybara.string(response.body).find("#spec-directory-file-growth-basis")
      expect(basis).to have_text("measured between this run and #{PREV_SHA.first(7)}", normalize_ws: true)
      links = sha_links_within(basis)
      expect(links.size).to eq(1)
      # The explicit commit_sha ask rides BESIDE the drill-in the page is open on — reading the
      # basis run must not close the area the reader is reading.
      expect(links.sole[:href])
        .to eq(expected_prev_href(repository, spec_directory: "spec/models"))
    end

    it "keeps the link out of the empty states that name no previous run" do
      repository = new_repository
      ingest(repository, commit_sha: PREV_SHA, at: 2.hours.ago,
                        specs: area_specs("spec/models", 3))
      repository.test_runs.create!(commit_sha: LATEST_SHA, branch: "main", total_specs_count: 0,
                                   created_at: 1.minute.ago)

      get repository_path(repository)

      panel = Capybara.string(response.body).find("#spec-directory-growth")
      empty = panel.find("[class*='border-dashed']")
      expect(empty.text(normalize_ws: true)).to include("This run reported no tests")
      expect(empty.all("a")).to be_empty
    end
  end

  describe "the EmptyState-interpolated sentences" do
    # The positive control for the escaped-markup hazard: same fixture shape the sentence specs
    # use, asserted on the ELEMENT. `.text` decodes entities, so "the sentence renders" is
    # satisfiable by escaped markup — only a real anchor proves the block slot worked.
    it "renders the area-count empty state's sha as a live link" do
      repository = new_repository
      repository.test_runs.create!(commit_sha: PREV_SHA, branch: "main", total_specs_count: 0,
                                   created_at: 2.hours.ago)
      ingest(repository, commit_sha: LATEST_SHA,
                        specs: area_specs("spec/models", 3, offset: 300))

      get repository_path(repository)

      panel = Capybara.string(response.body).find("#spec-directory-growth")
      empty = panel.find("[class*='border-dashed']")
      expect(empty.text(normalize_ws: true))
        .to include("previous run on this branch (#{PREV_SHA.first(7)}) reported no tests")
      links = sha_links_within(empty)
      expect(links.size).to eq(1)
      expect(links.sole[:href]).to eq(expected_prev_href(repository))
    end

    it "renders the area-time empty state's sha as a live link" do
      repository = new_repository
      ingest(repository, commit_sha: PREV_SHA, at: 2.hours.ago, duration: 90.0,
                        specs: area_specs("spec/models", 3, each: nil, offset: 0))
      ingest(repository, commit_sha: LATEST_SHA, at: 1.minute.ago, duration: 510.0,
                        specs: area_specs("spec/models", 3, each: 5.0, offset: 300))

      get repository_path(repository)

      panel = Capybara.string(response.body).find("#spec-directory-runtime-growth")
      empty = panel.find("[class*='border-dashed']")
      expect(empty.text(normalize_ws: true)).to include("reported no timings")
      links = sha_links_within(empty)
      expect(links.size).to eq(1)
      expect(links.sole[:href]).to eq(expected_prev_href(repository))
    end
  end

  describe "the cost of the links" do
    # AC: +0 queries. The row every link is built from is the ONE previous-run lookup the
    # dashboard already pays (`repository_dashboard.rb`: `previous_test_run_on_branch`); the
    # row-value `<` shape is unique to it — the trajectory's `<=` does not match the pattern — so
    # a second match would mean a link site re-read what it already had. The placeholders match
    # both spellings the adapter logs (bound `$1, $2` and literal `?`).
    it "issues no previous-run lookup beyond the one the page already paid" do
      repository = moved_suite

      previous_run_lookups =
        queries_against(/\(test_runs\.created_at, test_runs\.id\) < \((?:\?|\$\d+), (?:\?|\$\d+)\)/) do
          get repository_path(repository)
        end

      basis = Capybara.string(response.body).find("#suite-size-basis")
      expect(sha_links_within(basis)).to be_present
      expect(previous_run_lookups.size).to eq(1)
    end
  end

  describe "following the link" do
    # The request the link makes: from a delta measured against the middle run, read that run's
    # own page. Its filter bar names it as the run being read and offers the way back, and its
    # own verdict is a delta against ITS previous run — the one run older still on the branch.
    it "lands on the baseline run's page, which measures against its own baseline" do
      repository = new_repository
      ingest(repository, commit_sha: "old000000000001", at: 5.hours.ago, duration: 30.0,
                        specs: area_specs("spec/models", 2))
      ingest(repository, commit_sha: PREV_SHA, at: 2.hours.ago, duration: 90.0,
                        specs: area_specs("spec/models", 4, offset: 100))
      ingest(repository, commit_sha: LATEST_SHA, at: 1.minute.ago, duration: 510.0,
                        specs: area_specs("spec/models", 7, offset: 300))

      get repository_path(repository)

      basis = Capybara.string(response.body).find("#suite-size-basis")
      full_href = sha_links_within(basis).sole[:href]
      expect(full_href).to eq(expected_prev_href(repository))
      # Request specs do not follow fragments, and Rack reads none of it — the anchor is the
      # page's own business, verified by the comparison above and stripped only for the get.
      get full_href.split("#").first

      expect(response).to have_http_status(:ok)
      run_chip = Capybara.string(response.body).find(".rc-run")
      expect(run_chip).to have_text("Reading run #{PREV_SHA.first(7)}")
      # The way back the run-anchor chip carries: this page is anchored, so the reset is offered.
      expect(run_chip).to have_text("Show the newest run")
      # And the page's own verdict is a delta against ITS previous run, not a bare level: the
      # sub-caption reads "vs the previous run" and never "no earlier run to compare".
      verdict_stat = Capybara.string(response.body).all(".rc-stat").find do |stat|
        stat.first(".rc-stat-label")&.text&.squish == "Tests in suite"
      end
      expect(verdict_stat).to have_text("vs the previous run")
      expect(verdict_stat).to have_no_text("no earlier run to compare")
      # …and the basis THAT page measures against is the run older still, linked the same way.
      anchored_basis = Capybara.string(response.body).find("#suite-size-basis")
      older_links = sha_links_within(anchored_basis, "old000000000001")
      expect(older_links.sole[:href])
        .to eq(expected_prev_href(repository, "old000000000001"))
    end
  end
end
