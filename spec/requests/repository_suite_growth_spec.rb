# frozen_string_literal: true

require "rails_helper"

# The suite-size delta on the Overview panel — the first figure SpecGuard renders off *two* rows of
# `test_runs` rather than one. Everything else on that panel is a level, and a level cannot say
# whether 20,013 tests is 47 more than yesterday or 400 fewer.
#
# Its own file rather than more examples in the Overview block of spec/requests/repositories_spec.rb
# for the reason spec/requests/repository_runs_spec.rb states for itself: that file is the
# API-keys/Overview file and is edited by sibling slices, and every example here needs the same
# two-runs-on-a-branch setup.
#
# Runs are built directly rather than posted to /ingest: the write side has its own file
# (spec/requests/api/v1/ingest_spec.rb) and this slice does not touch it.
RSpec.describe "Repository suite-size growth", type: :request do
  before { @user = sign_in_via_github }

  def overview_panel = Capybara.string(response.body).find("#overview")

  # ELEMENT-scoped, never panel-scoped, and that is load-bearing — the same trap
  # spec/requests/repository_runs_spec.rb:23-30 documents from a verified mutation, one surface
  # over. Three states here produce a no-delta panel and two of them share the words "no earlier
  # run"; a panel-level `have_text("no earlier run")` therefore passes for the NULL-branch state
  # with the branch check deleted. Every assertion below names the element it means.
  def delta_figure = overview_panel.find("#suite-size-delta")

  def basis_line = overview_panel.find("#suite-size-basis")

  # The "Tests in suite" cell itself, so "the delta rendered" can never be satisfied by the figure
  # having drifted into some other row of the def list.
  def suite_size_cell
    overview_panel.find(:xpath, ".//dt[normalize-space()='Tests in suite']/following-sibling::dd[1]")
  end

  def grew_by_47(repository)
    repository.test_runs.create!(commit_sha: "a1b2c3d4e5f6", branch: "main", total_specs_count: 1_000,
                                 annotated_specs_count: 100, created_at: 3.hours.ago)
    repository.test_runs.create!(commit_sha: "fedcba987654", branch: "main", total_specs_count: 1_047,
                                 annotated_specs_count: 110, created_at: 1.minute.ago)
  end

  it "reports the suite grew, in the same cell as the size it changed" do
    repository = create_repository(user: @user)
    grew_by_47(repository)

    get repository_path(repository)

    expect(response).to have_http_status(:ok)
    expect(delta_figure.text).to eq("+47")
    # The level and the change are one statement, not two figures a reader has to relate.
    expect(suite_size_cell.text).to eq("1,047 +47")
  end

  it "names the run the change is measured against, and its age" do
    repository = create_repository(user: @user)
    grew_by_47(repository)

    get repository_path(repository)

    # A change with no stated basis is not a fact a reader can check. The short SHA, the branch it
    # is scoped to, and how old it is — all three on the surface, next to the number.
    expect(basis_line).to have_text("measured against a1b2c3d", normalize_ws: true)
    expect(basis_line).to have_text("the previous run on main", normalize_ws: true)
    expect(basis_line).to have_text("about 3 hours ago", normalize_ws: true)
    expect(basis_line).to have_text("Only runs on the same branch are compared", normalize_ws: true)
  end

  # Criterion 2, and the one that makes the figure a change rather than a magnitude: `400` beside a
  # suite size reads as a second, smaller count of something, not as 400 tests gone.
  it "renders a decrease signed, never as an unsigned magnitude" do
    repository = create_repository(user: @user)
    repository.test_runs.create!(commit_sha: "beforedelete", branch: "main", total_specs_count: 1_400,
                                 created_at: 2.hours.ago)
    repository.test_runs.create!(commit_sha: "afterdeleted", branch: "main", total_specs_count: 1_000,
                                 created_at: 1.minute.ago)

    get repository_path(repository)

    expect(delta_figure.text).to eq("−400")
    expect(delta_figure.text).not_to eq("400")
    expect(delta_figure.text).not_to eq("+400")
    expect(suite_size_cell.text).to eq("1,000 −400")
  end

  # "Compared, and it did not move" is an answer, and a different one from "there was nothing to
  # compare against". Suppressing the figure here would make the two identical.
  it "says the suite did not move rather than falling silent" do
    repository = create_repository(user: @user)
    repository.test_runs.create!(commit_sha: "steady00000a", branch: "main", total_specs_count: 1_000,
                                 created_at: 2.hours.ago)
    repository.test_runs.create!(commit_sha: "steady00000b", branch: "main", total_specs_count: 1_000,
                                 created_at: 1.minute.ago)

    get repository_path(repository)

    # `±0`, not `+0` — no change has no direction to claim.
    expect(delta_figure.text).to eq("±0")
    expect(basis_line).to have_text("measured against steady", normalize_ws: true)
  end

  # Criterion 3, and the reason the whole thing is branch-scoped. `test_runs` is one interleaved
  # history — the "Recent runs" table below lists it exactly that way — so the row immediately
  # before the latest is routinely another branch entirely.
  it "does not compare across branches, and says why there is no change to show" do
    repository = create_repository(user: @user)
    repository.test_runs.create!(commit_sha: "trunkrun0001", branch: "main", total_specs_count: 1_000,
                                 created_at: 2.hours.ago)
    repository.test_runs.create!(commit_sha: "featurerun01", branch: "feature/x", total_specs_count: 20,
                                 created_at: 1.minute.ago)

    get repository_path(repository)

    # No delta at all — not a `−980` taken against a branch that never had those tests.
    expect(overview_panel).to have_no_css("#suite-size-delta")
    expect(suite_size_cell.text).to eq("20")
    expect(basis_line).to have_text("No earlier run on feature/x", normalize_ws: true)
    # The run it must NOT have reached for. Asserted on the basis line specifically: "main" appears
    # elsewhere on this page in other repositories' fixtures and in the Recent-runs table below.
    expect(basis_line).to have_no_text("main", normalize_ws: true)
    # ...and it must not be reporting the *other* no-delta state instead.
    expect(basis_line).to have_no_text("reported no branch", normalize_ws: true)
  end

  it "says a branch's first run is its first run" do
    repository = create_repository(user: @user)
    repository.test_runs.create!(commit_sha: "firstever001", branch: "main", total_specs_count: 42)

    get repository_path(repository)

    expect(overview_panel).to have_no_css("#suite-size-delta")
    expect(basis_line).to have_text("No earlier run on main", normalize_ws: true)
    expect(basis_line).to have_text("first run SpecGuard has from that branch", normalize_ws: true)
  end

  # Criterion 4. A live state, not hypothetical: Ingest::Payload writes `branch` through
  # `.presence` and validates a missing one as acceptable. Distinct from "no earlier run on this
  # branch" because it is a different thing to go and fix — a CI client that is not sending a
  # branch, rather than a young branch.
  it "says a run that named no branch cannot be placed in a history" do
    repository = create_repository(user: @user)
    repository.test_runs.create!(commit_sha: "earlieranon", branch: nil, total_specs_count: 1_000,
                                 created_at: 2.hours.ago)
    repository.test_runs.create!(commit_sha: "latestanon0", branch: nil, total_specs_count: 1_047,
                                 created_at: 1.minute.ago)

    get repository_path(repository)

    # Every anonymous run pooled under `branch IS NULL` would have made this a confident `+47`
    # across two runs that may have come from anywhere.
    expect(overview_panel).to have_no_css("#suite-size-delta")
    expect(suite_size_cell.text).to eq("1,047")
    expect(basis_line).to have_text("reported no branch", normalize_ws: true)
    # The state-2 wording, which shares the "no earlier run" idea and must not stand in for this.
    expect(basis_line).to have_no_text("No earlier run on", normalize_ws: true)
  end

  # Criterion 5: the never-ingested empty state is untouched. Neither element exists — a basis line
  # explaining why there is no comparison would be a second, softer answer beside "no run at all".
  it "leaves the never-ingested empty state alone" do
    repository = create_repository(user: @user)

    get repository_path(repository)

    expect(overview_panel).to have_text("No CI run has reported yet", normalize_ws: true)
    expect(overview_panel).to have_no_css("#suite-size-delta")
    expect(overview_panel).to have_no_css("#suite-size-basis")
  end

  # The tie-break, from the surface. The Overview and the Recent-runs table are read side by side,
  # so the run compared against has to be the row the table prints directly beneath the latest —
  # not an older one a looser `created_at <` would have skipped to.
  it "compares against the same-instant predecessor the runs table prints beneath the latest" do
    repository = create_repository(user: @user)
    at = 1.hour.ago
    repository.test_runs.create!(commit_sha: "olderrun0001", branch: "main", total_specs_count: 5,
                                 created_at: 2.hours.ago)
    repository.test_runs.create!(commit_sha: "tiedfirst001", branch: "main", total_specs_count: 10,
                                 created_at: at)
    repository.test_runs.create!(commit_sha: "tiedsecond01", branch: "main", total_specs_count: 12,
                                 created_at: at)

    get repository_path(repository)

    expect(overview_panel).to have_text("Measured on tiedsec", normalize_ws: true)
    # +2 against its same-instant twin. Against the two-hours-ago run it would read +7.
    expect(delta_figure.text).to eq("+2")
    expect(basis_line).to have_text("measured against tiedfir", normalize_ws: true)
  end

  # Criterion 6, from the page. The absolute "exactly one query" is asserted where it can be
  # measured honestly — around the model call itself, in spec/models/repository_spec.rb. It is NOT
  # asserted here, and that is deliberate: a page-versus-page difference has a control that walks
  # the same code path, so an implementation which re-read `latest_test_run` internally would
  # inflate both renders by one and leave the difference at 1. Verified by mutation — that
  # implementation keeps this file green and turns the model-level count red. What these two
  # examples can honestly hold is that the comparison adds no per-row work: it costs the same
  # whether it finds a predecessor or not, and the same however long the branch's history is.
  describe "what the comparison costs the page" do
    def count_queries
      count = 0
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
        count += 1 unless payload[:cached] || payload[:name].in?(["SCHEMA", "TRANSACTION"])
      end
      yield
      count
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it "costs no more when it finds a run to compare against than when it does not" do
      repository = create_repository(user: @user)
      repository.test_runs.create!(commit_sha: "firstofbranch", branch: "main", total_specs_count: 10,
                                   created_at: 2.hours.ago)

      get repository_path(repository)
      baseline = count_queries { get repository_path(repository) }
      expect(overview_panel).to have_no_css("#suite-size-delta")

      # An earlier run appears on the same branch, so the lookup now returns a row and the page
      # renders the delta. A second lookup — or one per candidate — would show up here.
      repository.test_runs.first.update!(created_at: 3.hours.ago)
      repository.test_runs.create!(commit_sha: "secondofbrnch", branch: "main", total_specs_count: 12,
                                   created_at: 1.minute.ago)
      get repository_path(repository)

      expect(count_queries { get repository_path(repository) }).to eq(baseline)
      expect(delta_figure.text).to eq("+2")
    end

    it "costs the same however long the branch's history is" do
      repository = create_repository(user: @user)
      3.times do |i|
        repository.test_runs.create!(commit_sha: "history0000#{i}", branch: "main",
                                     total_specs_count: 10 + i, created_at: (5 - i).hours.ago)
      end

      get repository_path(repository)
      baseline = count_queries { get repository_path(repository) }

      # A LIMIT 1 lookup does not care; anything that walked the history would.
      5.times do |i|
        repository.test_runs.create!(commit_sha: "more00000000#{i}", branch: "main",
                                     total_specs_count: 20 + i, created_at: (4 - i).minutes.ago)
      end

      expect(count_queries { get repository_path(repository) }).to eq(baseline)
    end
  end

  # The panel sits outside the `keys.manage` gate — suite telemetry, not credential metadata — so
  # the delta does too. It is the same class of fact as the suite size it modifies.
  it "is visible to a member with only 'view'" do
    repository = create_repository(user: @user)
    grew_by_47(repository)
    member = sign_in_via_github(uid: "9999")
    create_membership(repository: repository, user: member, permissions: %w[view])

    get repository_path(repository)

    expect(response).to have_http_status(:ok)
    expect(delta_figure.text).to eq("+47")
  end
end
