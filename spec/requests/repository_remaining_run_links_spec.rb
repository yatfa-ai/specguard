# frozen_string_literal: true

require "rails_helper"

# The run-naming sites the link family landed last (SPGD-1867) — the three SPGD-1860/1865 named
# out of scope: the Suite growth panel's withheld-run sentence (both shas), the "Declared layers
# by run" strip's per-row sha cells, and the slowest-tests window's `:unrecorded` empty state.
# Every naming takes the family's read gesture:
#
#   link_to sha.first(7), drill_down_path(@repository, commit_sha: <full sha>, anchor: "summary")
#
# What this file guards that the sentence specs cannot:
#
#   * THE :unrecorded LINK IS REAL MARKUP. The state passes its sentence through the
#     `with_description` block slot, because `UI::EmptyStateComponent` renders the `description:`
#     PARAM escaped — an `<a>` interpolated there renders as visible markup text. Capybara's
#     `.text` decodes entities, so no text assertion can tell a rendered anchor from an escaped
#     one; the assertions here are on the ELEMENT, and
#     spec/components/ui/empty_state_component_spec.rb pins the escaped negative.
#
#   * THE HREF IS THE FULL SHA. `Repository#latest_test_run_for_commit` matches `commit_sha:`
#     exactly, so a href carrying the seven visible characters would resolve nil, silently fall
#     back to the newest run, and only the run-anchor notice would say so. Expected paths are
#     recomputed from `repository_path` — deliberately not through `drill_down_path` itself,
#     which reads controller ivars this spec does not have (the documented reasoning of
#     spec/requests/repository_previous_run_links_spec.rb).
#
#   * THE STATES WITHOUT A SHA STAY LINK-FREE. `:unresolved` names no run; neither it nor
#     `:no_runs` carries the gesture.
#
#   * +0 QUERIES. Every link is built from rows the page already loaded (the trajectory's plotted
#     cohort and its newest/last rows; the window walk's own `anchor_run`). A link site that
#     re-read the run would surface as a `test_runs` statement keyed on a sha — of which a
#     default page render issues none: the run-anchor resolution behind
#     `latest_test_run_for_commit` only runs when the reader ASKED for a run
#     (`repository_dashboard.rb` guards `@run_anchor_request &&`).
RSpec.describe "Repository remaining run links (Suite growth + :unrecorded)", type: :request do
  KEPT_A = "keptA000000001"
  KEPT_B = "keptB000000002"
  KEPT_C = "keptC000000003"
  ZERO_SHA = "zero0000000001"
  EMPTY_SHA = "empty0000000001"

  before { @user = sign_in_via_github }

  def page = Capybara.string(response.body)

  def trajectory_panel = page.find("#suite-trajectory")

  def basis_line = trajectory_panel.find("#suite-trajectory-basis")

  # Three plotted runs with a recorded layer mix (so the strip draws) plus a newest run that
  # reported no tests at all — withheld as unmeasured, which is what turns the sentence on: the
  # line stops one run short of the SHA the Overview names.
  def growth_repository
    repository = create_repository(user: @user)
    [KEPT_A, KEPT_B, KEPT_C].each_with_index do |sha, index|
      run = repository.test_runs.create!(commit_sha: sha, branch: "main", total_specs_count: 3,
                                         annotated_specs_count: 0, created_at: (3 - index).days.ago)
      2.times do |line|
        run.spec_observations.create!(
          repository: repository, example_id: "./spec/unit_spec.rb[1:#{index}:#{line}]",
          file_path: "spec/unit_spec.rb", spec_file_path: "spec/unit_spec.rb", line_number: line + 1,
          status: "unannotated", intent_layer: "unit"
        )
      end
      run.spec_observations.create!(
        repository: repository, example_id: "./spec/legacy_spec.rb[1:#{index}]",
        file_path: "spec/legacy_spec.rb", spec_file_path: "spec/legacy_spec.rb", line_number: 10,
        status: "unannotated", intent_layer: nil
      )
    end
    repository.test_runs.create!(commit_sha: ZERO_SHA, branch: "main", total_specs_count: 0,
                                 annotated_specs_count: 0, created_at: 1.minute.ago)
    repository
  end

  # One run that reported a suite size and a duration but no per-example detail — the state the
  # `:unrecorded` empty state exists for.
  def unrecorded_repository
    repository = create_repository(user: @user)
    Ingest::RunRecorder.record(
      repository,
      { commit_sha: EMPTY_SHA, branch: "main", total_specs_count: 0,
        annotated_specs_count: 0, duration_seconds: 60.0 }
    )
    TestRun.where(commit_sha: EMPTY_SHA).update_all(created_at: 2.days.ago)
    repository
  end

  # The expected destination of a run link: the named run's page at the Summary. Recomputed from
  # the router, not from the view helper, on the reasoning the previous-run file records.
  def expected_href(repository, sha, **asks)
    repository_path(repository, commit_sha: sha, anchor: "summary", **asks)
  end

  # Element-scoped link read, never panel-scoped or page-scoped: several panels on this page name
  # runs and some already link them (the run tables), so a wider search satisfies these examples
  # with the new links deleted (the growth file's rule).
  def sha_links_within(scope, sha)
    scope.all("a").select { |a| a.text.squish == sha.first(7) }
  end

  describe "the slowest-tests window's :unrecorded empty state" do
    it "renders the anchor run's sha as a live link carrying the full sha" do
      repository = unrecorded_repository

      get repository_path(repository)

      state = page.find("#slowest-tests-window-unrecorded")
      expect(state.text(normalize_ws: true))
        .to include("#{EMPTY_SHA.first(7)}, the newest run in this window, reported no per-example detail at all")
      links = sha_links_within(state, EMPTY_SHA)
      expect(links.size).to eq(1)
      expect(links.sole[:href]).to eq(expected_href(repository, EMPTY_SHA))
    end

    it "keeps the link out of the :unresolved state, which names no run" do
      repository = create_repository(user: @user)
      2.times do |index|
        run = Ingest::RunRecorder.record(
          repository,
          { commit_sha: "unres#{index}00000", branch: "main", total_specs_count: 1,
            annotated_specs_count: 0, duration_seconds: 60.0 },
          specs: [unannotated_spec(file_path: "spec/a_spec.rb", line_number: index + 1,
                                   duration: 1.0, name: "a test #{index}").deep_stringify_keys]
        )
        TestRun.where(id: run.id).update_all(created_at: (2 - index).days.ago)
      end

      get repository_path(repository)

      state = page.find("#slowest-tests-window-unresolved")
      expect(state.text(normalize_ws: true)).to include("has been matched to a durable test yet")
      expect(state.all("a")).to be_empty
    end

    # AC: +0 queries at the anchor_run site too. `anchor_run` is the window walk's own loaded row
    # (`SlowestTests` carries it as an attr_reader); a link site that re-read the run would
    # surface as a test_runs statement keyed on a sha.
    it "pays no sha-keyed test_runs read to build the :unrecorded link" do
      repository = unrecorded_repository

      sha_reads = queries_against(/FROM "test_runs" WHERE .*"commit_sha" =/) do
        get repository_path(repository)
      end

      state = page.find("#slowest-tests-window-unrecorded")
      expect(sha_links_within(state, EMPTY_SHA)).to be_present
      expect(sha_reads).to be_empty
    end

    # The request the link makes: from the state that says "no per-test detail", open the run it
    # named. The full-sha href must resolve — this is the load the seven-character href would
    # silently drop.
    it "lands on the anchor run's page when the link is followed" do
      repository = unrecorded_repository

      get repository_path(repository)

      full_href = sha_links_within(page.find("#slowest-tests-window-unrecorded"), EMPTY_SHA).sole[:href]
      expect(full_href).to eq(expected_href(repository, EMPTY_SHA))
      get full_href.split("#").first

      expect(response).to have_http_status(:ok)
      run_chip = page.find(".rc-run")
      expect(run_chip).to have_text("Reading run #{EMPTY_SHA.first(7)}")
    end
  end

  describe "the Suite growth panel's withheld-run sentence and strip" do
    # AC: +0 queries across the whole panel. The sentence's two rows and every strip row come off
    # the trajectory's already-loaded cohort.
    it "pays no sha-keyed test_runs read to build the sentence and strip links" do
      repository = growth_repository

      sha_reads = queries_against(/FROM "test_runs" WHERE .*"commit_sha" =/) do
        get repository_path(repository)
      end

      expect(sha_links_within(basis_line, ZERO_SHA)).to be_present
      expect(sha_links_within(basis_line, KEPT_C)).to be_present
      expect(sha_links_within(trajectory_panel.find("#suite-trajectory-layers"), KEPT_A)).to be_present
      expect(sha_reads).to be_empty
    end

    # drill_down_path carries the page's open asks and the explicit commit_sha beats any carried
    # run anchor: the Suite growth panel is branch-anchored, so a reader who ASKED for a branch
    # keeps it beside the run they are opening.
    it "carries the open branch ask beside the withheld sentence's sha links" do
      repository = growth_repository

      get repository_path(repository, branch: "main")

      links = basis_line.all("a")
      expect(links.map { |a| a[:href] }).to eq([
        expected_href(repository, ZERO_SHA, branch: "main"),
        expected_href(repository, KEPT_C, branch: "main")
      ])
    end

    it "carries the open layer ask beside the strip's per-row links" do
      repository = growth_repository

      get repository_path(repository, params: { layer: "unit" })

      rows = trajectory_panel.find("#suite-trajectory-layers").all("ol li")
      expect(rows.map { |li| li["data-commit-sha"] }).to eq([KEPT_A, KEPT_B, KEPT_C])
      rows.each do |li|
        sha = li["data-commit-sha"]
        expect(li).to have_link(sha.first(7),
                                href: expected_href(repository, sha, layer: "unit"))
      end
    end
  end
end
