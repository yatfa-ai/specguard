# frozen_string_literal: true

require "rails_helper"

# The four window panels' baseline-run naming — since SPGD-1865 every window-panel sentence that
# names the walked baseline by sha names it as the family's read gesture: a link into that run's
# own page, anchored at the Summary (`drill_down_path(@repository, commit_sha: <full sha>,
# anchor: "summary")`), the same pattern the run-pair family landed in SPGD-1852 and SPGD-1860.
# The panels: "Areas that grew or shrank over the window", its file drill-in, "Areas that got
# slower or faster over the window", and its file drill-in.
#
# What this file guards that the sentence specs cannot:
#
#   * THE HREF IS THE FULL SHA. `Repository#latest_test_run_for_commit` matches `commit_sha:`
#     exactly, so a href carrying the seven visible characters would resolve nil, silently fall
#     back to the newest run, and only the run-anchor notice would say so. Every example
#     recomputes the expected path from `repository_path` — deliberately not through
#     `drill_down_path` itself, which reads controller ivars this spec does not have (the
#     documented reasoning of spec/requests/repository_previous_run_links_spec.rb).
#
#   * THE LINK IS REAL MARKUP. The window baseline sentence returns a SafeBuffer since SPGD-1865,
#     and every EmptyState-interpolated consumer takes it through a `with_description` block — or,
#     on the runtime refusal splat, as the SafeBuffer the helper returns for the four sha-bearing
#     arms. Capybara's `.text` decodes entities, so no text assertion can tell a rendered anchor
#     from an escaped one — every empty-state example asserts on the ELEMENT, and
#     spec/components/ui/empty_state_component_spec.rb pins the escaped negative.
#
#   * +0 QUERIES. The row every link is built from is `baseline_run`, the window walk's own loaded
#     row (`SpecDirectoryWindowContext`). A link site that re-read the run would surface as a
#     `test_runs` statement keyed on a sha — of which a default page render issues none: the
#     run-anchor resolution behind `latest_test_run_for_commit` only runs when the reader ASKED
#     for a run (`repository_dashboard.rb` guards `@run_anchor_request &&`).
RSpec.describe "Repository window-panel baseline-run links", type: :request do
  BASE_SHA = "base00000000001"
  HEAD_SHA = "head00000000004"
  OLD_SHA = "old00000000003"

  before { @user = sign_in_via_github }

  def new_repository
    @repository_seq = (@repository_seq || 0) + 1

    create_repository(user: @user, github_full_name: "acme/service-#{@repository_seq}")
  end

  def page = Capybara.string(response.body)

  # The expected destination of a baseline link: the named run's page at the Summary. Recomputed
  # from the router, not from the view helper, on the reasoning the previous-run file records.
  def expected_base_href(repository, sha = BASE_SHA, **asks)
    repository_path(repository, commit_sha: sha, anchor: "summary", **asks)
  end

  def ingest(repository, commit_sha:, at:, specs: nil, total: nil, duration: 60.0, branch: "main")
    payload = { commit_sha: commit_sha, branch: branch,
                total_specs_count: total || specs&.size || 0,
                annotated_specs_count: 0, duration_seconds: duration }
    options = specs.nil? ? {} : { specs: specs.map(&:deep_stringify_keys) }
    run = Ingest::RunRecorder.record(repository, payload, **options)
    TestRun.where(id: run.id).update_all(created_at: at)
    run
  end

  # One example in an area, with its own timing (`each: nil` is the untimed example the runtime
  # panel's refusal arms name) and an optional declared layer.
  def area_specs(directory, count, each: 1.0, offset: 0, layer: nil)
    Array.new(count) do |i|
      file_path = "#{directory}/a_spec.rb"
      line = offset + i + 1
      if layer
        annotated_spec(file_path: file_path, line_number: line, duration: each, layer: layer,
                       name: "#{layer} example #{offset + i}")
      else
        unannotated_spec(file_path: file_path, line_number: line, duration: each)
      end
    end
  end

  # Two runs whose counts AND times move, so all four window panels render comparable.
  def moved_window
    repository = new_repository
    ingest(repository, commit_sha: BASE_SHA, at: 2.hours.ago, duration: 90.0,
                      specs: area_specs("spec/models", 3, each: 1.0) +
                             area_specs("spec/legacy", 4, each: 0.5, offset: 100))
    ingest(repository, commit_sha: HEAD_SHA, at: 1.minute.ago, duration: 510.0,
                      specs: area_specs("spec/models", 5, each: 5.0, offset: 300) +
                             area_specs("spec/legacy", 2, each: 0.25, offset: 400))
    repository
  end

  # Element-scoped link read, never panel-scoped or page-scoped: several panels on this page name
  # runs and some already link them (the run tables), so a wider search satisfies these examples
  # with the window links deleted (the growth file's rule).
  def sha_links_within(scope, sha = BASE_SHA)
    scope.all("a").select { |a| a.text.squish == sha.first(7) }
  end

  def basis_note(panel_id) = page.find(panel_id)

  def empty_state_within(panel_id) = page.find(panel_id).find("[class*='border-dashed']")

  describe "the four basis captions" do
    it "links the area-count caption to the walked baseline run" do
      repository = moved_window

      get repository_path(repository)

      basis = basis_note("#spec-directory-window-growth-basis")
      expect(basis).to have_text("Measured against #{BASE_SHA.first(7)}", normalize_ws: true)
      links = sha_links_within(basis)
      expect(links.size).to eq(1)
      expect(links.sole[:href]).to eq(expected_base_href(repository))
    end

    it "links the area-time caption to the same run" do
      repository = moved_window

      get repository_path(repository)

      basis = basis_note("#spec-directory-window-runtime-growth-basis")
      expect(basis).to have_text("Measured against #{BASE_SHA.first(7)}", normalize_ws: true)
      links = sha_links_within(basis)
      expect(links.size).to eq(1)
      expect(links.sole[:href]).to eq(expected_base_href(repository))
    end

    it "links the files-count caption and carries the open drill-in beside the sha ask" do
      repository = moved_window

      get repository_path(repository, params: { spec_directory: "spec/models" })

      basis = basis_note("#spec-directory-window-file-growth-basis")
      expect(basis).to have_text("Measured against #{BASE_SHA.first(7)}", normalize_ws: true)
      links = sha_links_within(basis)
      expect(links.size).to eq(1)
      # The explicit commit_sha ask rides BESIDE the drill-in the page is open on — reading the
      # baseline must not close the area the reader is reading.
      expect(links.sole[:href]).to eq(expected_base_href(repository, spec_directory: "spec/models"))
    end

    it "links the files-time caption the same way" do
      repository = moved_window

      get repository_path(repository, params: { spec_directory: "spec/models" })

      basis = basis_note("#spec-directory-window-file-runtime-growth-basis")
      expect(basis).to have_text("Measured against #{BASE_SHA.first(7)}", normalize_ws: true)
      links = sha_links_within(basis)
      expect(links.size).to eq(1)
      expect(links.sole[:href]).to eq(expected_base_href(repository, spec_directory: "spec/models"))
    end
  end

  describe "the EmptyState-interpolated sentences" do
    # The positive control for the escaped-markup hazard: asserted on the ELEMENT. `.text` decodes
    # entities, so "the sentence renders" is satisfiable by escaped markup — only a real anchor
    # proves the block slot (or the SafeBuffer param) worked.
    it "renders the area-count layer-empty state's sha as a live link, carrying the layer ask" do
      repository = new_repository
      ingest(repository, commit_sha: BASE_SHA, at: 2.hours.ago, duration: 90.0,
                        specs: area_specs("spec/models", 3, each: 1.0))
      ingest(repository, commit_sha: HEAD_SHA, at: 1.minute.ago, duration: 510.0,
                        specs: area_specs("spec/models", 5, each: 5.0, offset: 300))

      get repository_path(repository, params: { layer: "unit" })

      empty = empty_state_within("#spec-directory-window-growth")
      expect(empty.text(normalize_ws: true))
        .to include("Neither the run at the far end of this window nor the newest run")
      links = sha_links_within(empty)
      expect(links.size).to eq(1)
      expect(links.sole[:href]).to eq(expected_base_href(repository, layer: "unit"))
    end

    it "renders the area-time layer-empty state's sha as a live link too" do
      repository = new_repository
      ingest(repository, commit_sha: BASE_SHA, at: 2.hours.ago, duration: 90.0,
                        specs: area_specs("spec/models", 3, each: 1.0))
      ingest(repository, commit_sha: HEAD_SHA, at: 1.minute.ago, duration: 510.0,
                        specs: area_specs("spec/models", 5, each: 5.0, offset: 300))

      get repository_path(repository, params: { layer: "unit" })

      empty = empty_state_within("#spec-directory-window-runtime-growth")
      expect(empty.text(normalize_ws: true))
        .to include("there is no unit-layer time to compare area by area")
      links = sha_links_within(empty)
      expect(links.size).to eq(1)
      expect(links.sole[:href]).to eq(expected_base_href(repository, layer: "unit"))
    end

    it "renders the area-count empty state's sha as a live link" do
      repository = new_repository
      ingest(repository, commit_sha: BASE_SHA, at: 2.hours.ago, duration: 90.0,
                        specs: area_specs("spec/models", 3, each: 1.0))
      ingest(repository, commit_sha: HEAD_SHA, at: 1.minute.ago, duration: 510.0,
                        specs: area_specs("spec/models", 3, each: 5.0, offset: 300))

      get repository_path(repository)

      empty = empty_state_within("#spec-directory-window-growth")
      expect(empty.text(normalize_ws: true)).to include("No area moved across this window")
      links = sha_links_within(empty)
      expect(links.size).to eq(1)
      expect(links.sole[:href]).to eq(expected_base_href(repository))
    end

    it "renders the area-time empty state's sha as a live link" do
      repository = new_repository
      ingest(repository, commit_sha: BASE_SHA, at: 2.hours.ago, duration: 90.0,
                        specs: area_specs("spec/models", 3, each: 2.0))
      ingest(repository, commit_sha: HEAD_SHA, at: 1.minute.ago, duration: 510.0,
                        specs: area_specs("spec/models", 3, each: 2.0, offset: 300))

      get repository_path(repository)

      empty = empty_state_within("#spec-directory-window-runtime-growth")
      expect(empty.text(normalize_ws: true)).to include("No area changed pace across this window")
      links = sha_links_within(empty)
      expect(links.size).to eq(1)
      expect(links.sole[:href]).to eq(expected_base_href(repository))
    end

    it "renders the files-count empty state's sha as a live link, carrying the drill-in" do
      repository = new_repository
      ingest(repository, commit_sha: BASE_SHA, at: 2.hours.ago, duration: 90.0,
                        specs: area_specs("spec/models", 3, each: 1.0) +
                               area_specs("spec/legacy", 2, each: 1.0, offset: 100))
      ingest(repository, commit_sha: HEAD_SHA, at: 1.minute.ago, duration: 510.0,
                        specs: area_specs("spec/models", 3, each: 5.0, offset: 300) +
                               area_specs("spec/legacy", 4, each: 3.0, offset: 200))

      get repository_path(repository, params: { spec_directory: "spec/models" })

      empty = empty_state_within("#spec-directory-window-file-growth")
      expect(empty.text(normalize_ws: true)).to include("No file moved across this window")
      links = sha_links_within(empty)
      expect(links.size).to eq(1)
      expect(links.sole[:href]).to eq(expected_base_href(repository, spec_directory: "spec/models"))
    end

    it "renders the files-time empty state's sha as a live link too" do
      repository = new_repository
      ingest(repository, commit_sha: BASE_SHA, at: 2.hours.ago, duration: 90.0,
                        specs: area_specs("spec/models", 3, each: 2.0) +
                               area_specs("spec/legacy", 2, each: 1.0, offset: 100))
      ingest(repository, commit_sha: HEAD_SHA, at: 1.minute.ago, duration: 510.0,
                        specs: area_specs("spec/models", 3, each: 2.0, offset: 300) +
                               area_specs("spec/legacy", 4, each: 3.0, offset: 200))

      get repository_path(repository, params: { spec_directory: "spec/models" })

      empty = empty_state_within("#spec-directory-window-file-runtime-growth")
      expect(empty.text(normalize_ws: true)).to include("No file changed pace across this window")
      links = sha_links_within(empty)
      expect(links.size).to eq(1)
      expect(links.sole[:href]).to eq(expected_base_href(repository, spec_directory: "spec/models"))
    end
  end

  describe "the sha-bearing refusal arms" do
    it "renders baseline_unrecorded as a live link on both window panels" do
      repository = new_repository
      ingest(repository, commit_sha: BASE_SHA, at: 2.hours.ago, total: 10)
      ingest(repository, commit_sha: HEAD_SHA, at: 1.minute.ago, duration: 510.0,
                        specs: area_specs("spec/models", 3, each: 5.0))

      get repository_path(repository)

      # The area-count panel words its own arm inline; the sha it names is the link.
      empty = empty_state_within("#spec-directory-window-growth")
      expect(empty.text(normalize_ws: true))
        .to include("The run this comparison landed on (#{BASE_SHA.first(7)}, 1 back in this window)")
      links = sha_links_within(empty)
      expect(links.size).to eq(1)
      expect(links.sole[:href]).to eq(expected_base_href(repository))

      # The area-time panel takes its arm from the runtime refusal helper.
      empty = empty_state_within("#spec-directory-window-runtime-growth")
      expect(empty.text(normalize_ws: true))
        .to include("The run this comparison landed on (#{BASE_SHA.first(7)}")
      links = sha_links_within(empty)
      expect(links.size).to eq(1)
      expect(links.sole[:href]).to eq(expected_base_href(repository))
    end

    it "renders baseline_untimed as a live link" do
      repository = new_repository
      ingest(repository, commit_sha: BASE_SHA, at: 2.hours.ago, duration: 90.0,
                        specs: area_specs("spec/models", 3, each: nil))
      ingest(repository, commit_sha: HEAD_SHA, at: 1.minute.ago, duration: 510.0,
                        specs: area_specs("spec/models", 3, each: 5.0))

      get repository_path(repository)

      empty = empty_state_within("#spec-directory-window-runtime-growth")
      expect(empty.text(normalize_ws: true))
        .to include("The run at the far end of this window (#{BASE_SHA.first(7)}, 1 back) reported no timings")
      links = sha_links_within(empty)
      expect(links.size).to eq(1)
      expect(links.sole[:href]).to eq(expected_base_href(repository))
    end

    it "renders neither_timed as a live link" do
      repository = new_repository
      ingest(repository, commit_sha: BASE_SHA, at: 2.hours.ago, duration: 90.0,
                        specs: area_specs("spec/models", 3, each: nil))
      ingest(repository, commit_sha: HEAD_SHA, at: 1.minute.ago, duration: 510.0,
                        specs: area_specs("spec/models", 3, each: nil, offset: 300))

      get repository_path(repository)

      empty = empty_state_within("#spec-directory-window-runtime-growth")
      expect(empty.text(normalize_ws: true))
        .to include("Neither this run nor #{BASE_SHA.first(7)}, the run at the far end of this window, " \
                    "reported a duration")
      links = sha_links_within(empty)
      expect(links.size).to eq(1)
      expect(links.sole[:href]).to eq(expected_base_href(repository))
    end

    it "renders the neither-recorded fallback as a live link on both window panels" do
      repository = new_repository
      ingest(repository, commit_sha: BASE_SHA, at: 2.hours.ago, total: 10)
      ingest(repository, commit_sha: HEAD_SHA, at: 1.minute.ago, total: 12)

      get repository_path(repository)

      # The area-count panel's own inline fallback …
      empty = empty_state_within("#spec-directory-window-growth")
      expect(empty.text(normalize_ws: true))
        .to include("Neither this run nor #{BASE_SHA.first(7)}, the run at the far end of this window, " \
                    "recorded per-example detail")
      links = sha_links_within(empty)
      expect(links.size).to eq(1)
      expect(links.sole[:href]).to eq(expected_base_href(repository))

      # … and the area-time panel's helper arm.
      empty = empty_state_within("#spec-directory-window-runtime-growth")
      links = sha_links_within(empty)
      expect(links.size).to eq(1)
      expect(links.sole[:href]).to eq(expected_base_href(repository))
    end
  end

  describe "the refusal arms that name no baseline" do
    it "keeps the link out of anchor_unrecorded, which names no run but this one" do
      repository = new_repository
      ingest(repository, commit_sha: BASE_SHA, at: 2.hours.ago, duration: 90.0,
                        specs: area_specs("spec/models", 3, each: 1.0))
      ingest(repository, commit_sha: HEAD_SHA, at: 1.minute.ago, total: 10)

      get repository_path(repository)

      empty = empty_state_within("#spec-directory-window-growth")
      expect(empty.text(normalize_ws: true)).to include("This run recorded no per-example detail")
      expect(empty.all("a")).to be_empty
      # The runtime panel's helper arm takes the same verdict and stays link-free as well.
      expect(empty_state_within("#spec-directory-window-runtime-growth").all("a")).to be_empty
    end

    it "keeps the link out of no_earlier_run, where there is no run to name" do
      repository = new_repository
      ingest(repository, commit_sha: HEAD_SHA, at: 1.minute.ago, duration: 90.0,
                        specs: area_specs("spec/models", 3, each: 1.0))

      get repository_path(repository)

      empty = empty_state_within("#spec-directory-window-growth")
      expect(empty.text(normalize_ws: true)).to include("No window to compare across yet")
      expect(empty.all("a")).to be_empty
    end
  end

  describe "the cost of the links" do
    # AC: +0 queries. The row every link is built from is `baseline_run`, the window walk's own
    # loaded row; a link site that re-read the run would surface as a test_runs statement keyed on
    # a sha, and a default page render issues none of those.
    it "issues no test_runs read keyed on a commit sha beyond the ones the page already paid" do
      repository = moved_window

      sha_reads = queries_against(/FROM "test_runs" WHERE .*"commit_sha" =/) do
        get repository_path(repository)
      end

      basis = basis_note("#spec-directory-window-growth-basis")
      expect(sha_links_within(basis)).to be_present
      expect(sha_reads).to be_empty
    end
  end

  describe "following the link" do
    # The request the link makes: from a window caption, read the run it measured against. Its
    # filter bar names it as the run being read and offers the way back.
    it "lands on the baseline run's page, anchored on the run the caption named" do
      repository = new_repository
      ingest(repository, commit_sha: OLD_SHA, at: 5.hours.ago, duration: 30.0,
                        specs: area_specs("spec/models", 2))
      ingest(repository, commit_sha: BASE_SHA, at: 2.hours.ago, duration: 90.0,
                        specs: area_specs("spec/models", 4, offset: 100))
      ingest(repository, commit_sha: HEAD_SHA, at: 1.minute.ago, duration: 510.0,
                        specs: area_specs("spec/models", 7, offset: 300))

      get repository_path(repository)

      # Three comparable runs: the walk lands on the OLDEST one, and that is the run the caption
      # links.
      basis = basis_note("#spec-directory-window-growth-basis")
      full_href = sha_links_within(basis, OLD_SHA).sole[:href]
      expect(full_href).to eq(expected_base_href(repository, OLD_SHA))
      # Request specs do not follow fragments, and Rack reads none of it — the anchor is the
      # page's own business, verified by the comparison above and stripped only for the get.
      get full_href.split("#").first

      expect(response).to have_http_status(:ok)
      run_chip = page.find(".rc-run")
      expect(run_chip).to have_text("Reading run #{OLD_SHA.first(7)}")
      # The way back the run-anchor chip carries: this page is anchored, so the reset is offered.
      expect(run_chip).to have_text("Show the newest run")
      # And the page now reading the old run still captions the window's own walked baseline —
      # the same run, linked the same way — rather than losing the caption to the anchor.
      anchored_basis = basis_note("#spec-directory-window-growth-basis")
      expect(sha_links_within(anchored_basis, OLD_SHA).sole[:href])
        .to eq(expected_base_href(repository, OLD_SHA))
    end
  end
end
