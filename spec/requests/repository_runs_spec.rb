# frozen_string_literal: true

require "rails_helper"

# The "Recent runs" panel on repositories#show — the first read surface over the append-only
# `test_runs` history. Everything the panel renders comes off columns ingestion populates on every
# run, so these examples build runs directly rather than posting to /ingest: the write side has its
# own file (spec/requests/api/v1/ingest_spec.rb) and this slice does not touch it.
#
# Deliberately its own file rather than more examples in spec/requests/repositories_spec.rb, which
# is the API-keys file and is being edited by a sibling slice.
RSpec.describe "Repository recent runs", type: :request do
  before { @user = sign_in_via_github }

  # Scoped to the panel's own anchor: the page renders two tables, and an unscoped `find("table")`
  # is exactly the ambiguity this slice had to fix in the API-keys file.
  def runs_table = Capybara.string(response.body).find("#recent-runs table")

  def run_headers = runs_table.all("thead th").map(&:text)

  def run_row(commit) = runs_table.find("tbody tr", text: commit)

  # Cell-level, not row-level, and that is load-bearing. Several cells share the "not reported"
  # wording, so a row-level `have_text("not reported")` for the duration is satisfied by a nil
  # *branch* in the same row — it passes with the duration column deleted. Verified by mutation:
  # forcing nil duration down the numeric branch leaves the row assertion green and only the
  # indexed one red. Indices follow the header order asserted below.
  COMMIT, BRANCH, TESTS, DURATION, ANNOTATED, AGE = (0..5).to_a

  def run_cells(commit) = run_row(commit).all("td").map { |cell| cell.text.strip }

  def runs_panel = Capybara.string(response.body).find("#recent-runs")

  it "lists a run's commit, branch, suite size, duration, annotation share and age" do
    repository = create_repository(user: @user)
    repository.test_runs.create!(commit_sha: "a1b2c3d4e5f6", branch: "main", total_specs_count: 3,
                                 annotated_specs_count: 2, duration_seconds: 12.5)

    get repository_path(repository)

    expect(response).to have_http_status(:ok)
    expect(run_headers).to eq(["Commit", "Branch", "Tests", "Duration", "Annotated", "Ingested"])

    cells = run_cells("a1b2c3d")
    expect(cells[COMMIT]).to eq("a1b2c3d")
    expect(cells[BRANCH]).to eq("main")
    expect(cells[TESTS]).to eq("3")
    expect(cells[DURATION]).to eq("12.5s")
    # The PERCENTAGE, not the 0–1 fraction /ingest reports. 2/3 is 66.7%, and 0.667 rendered here
    # would be wrong by two orders of magnitude — the exact confusion TestRun's two methods exist
    # to prevent.
    expect(cells[ANNOTATED]).to eq("66.7%")
    expect(cells[AGE]).to match(/ago\z/)
  end

  it "renders the newest run first" do
    repository = create_repository(user: @user)
    repository.test_runs.create!(commit_sha: "oldrun0", created_at: 2.days.ago, total_specs_count: 1)
    repository.test_runs.create!(commit_sha: "newrun0", created_at: 1.hour.ago, total_specs_count: 1)

    get repository_path(repository)

    expect(runs_table.all("tbody tr").first).to have_text("newrun0")
  end

  # Honest state 1. "The client sent no timing" and "the run took no time" are different facts, and
  # `0.0s` renders them identically.
  it "says a run reported no duration rather than showing it as 0.0s" do
    repository = create_repository(user: @user)
    # A branch IS set here on purpose: with `branch: nil` the row also prints "not reported" in
    # the branch cell, and a row-level assertion would pass with the duration column deleted.
    repository.test_runs.create!(commit_sha: "notimed", branch: "main", total_specs_count: 4,
                                 annotated_specs_count: 1, duration_seconds: nil)

    get repository_path(repository)

    cells = run_cells("notimed")
    expect(cells[DURATION]).to eq("not reported")
    # Neither `0.0s` nor a silently blank cell: an omitted timing is a fact worth naming.
    expect(cells[DURATION]).not_to eq("0.0s")
    expect(cells[DURATION]).not_to be_empty
    # The rest of the row is unaffected by the missing timing.
    expect(cells[ANNOTATED]).to eq("25.0%")
  end

  # Honest state 3. `TestRun#annotated_ratio` floors at 0.0 by guard when there is no denominator;
  # printed beside real percentages that reads as a suite measured at zero annotations.
  it "does not print 0% for a run that reported no tests at all" do
    repository = create_repository(user: @user)
    repository.test_runs.create!(commit_sha: "emptyrn", branch: "main", total_specs_count: 0,
                                 annotated_specs_count: 0, duration_seconds: 2.0)

    get repository_path(repository)

    cells = run_cells("emptyrn")
    expect(cells[ANNOTATED]).to eq("no tests")
    expect(cells[ANNOTATED]).not_to eq("0.0%")
  end

  it "says a run reported no branch rather than leaving the cell blank" do
    repository = create_repository(user: @user)
    repository.test_runs.create!(commit_sha: "nobranc", branch: nil, total_specs_count: 2,
                                 annotated_specs_count: 1, duration_seconds: 1.0)

    get repository_path(repository)

    cells = run_cells("nobranc")
    expect(cells[BRANCH]).to eq("not reported")
    expect(cells[DURATION]).to eq("1.0s")
  end

  # Honest state 2. An empty table with a header row would say "we looked and there is nothing",
  # which is true — but a repository that has never ingested has a different thing to be told.
  it "renders an empty state, not an empty table, when nothing has been ingested" do
    repository = create_repository(user: @user)

    get repository_path(repository)

    expect(response).to have_http_status(:ok)
    expect(runs_panel).to have_text("No runs yet")
    expect(runs_panel).to have_no_selector("table")
  end

  it "shows at most ten runs" do
    repository = create_repository(user: @user)
    12.times { |i| repository.test_runs.create!(commit_sha: "sha000#{i}", created_at: i.hours.ago) }

    get repository_path(repository)

    expect(runs_table.all("tbody tr").size).to eq(10)
  end

  # This is the example that makes the `#api-keys` / `#recent-runs` scoping load-bearing, and it
  # is here on purpose. The page now renders two tables, but only for a repository that has BOTH a
  # key and a run — and no example in spec/requests/repositories_spec.rb creates a run, which is
  # why the bare `find("table")` there was still passing when this slice was written. The breakage
  # was latent, not immediate: it was waiting for the first example to hold both. Verified by
  # probe — with an unscoped finder, this exact fixture raises Capybara::Ambiguous.
  it "coexists with the API keys table, each separately addressable" do
    repository = create_repository(user: @user)
    repository.api_keys.create!(name: "CI")
    repository.test_runs.create!(commit_sha: "bothtwo", total_specs_count: 2, annotated_specs_count: 1)

    get repository_path(repository)

    page = Capybara.string(response.body)
    expect(page.all("table").size).to eq(2)
    expect(page.find("#recent-runs table")).to have_text("bothtwo").and have_no_text("CI")
    expect(page.find("#api-keys table")).to have_text("CI").and have_no_text("bothtwo")
  end

  it "does not list another repository's runs" do
    repository = create_repository(user: @user)
    other = create_repository(user: create_user(github_uid: "3003", github_handle: "hubot"),
                              github_full_name: "acme/ledger")
    other.test_runs.create!(commit_sha: "foreign", total_specs_count: 5)

    get repository_path(repository)

    expect(response.body).not_to include("foreign")
  end

  # The panel is suite telemetry, not credential metadata and not a control — so it sits outside
  # the `keys.manage` gate, exactly like the connection-health stat above it. For a `view` member
  # the API-keys panel is absent entirely, which makes this the page's only table.
  it "is visible to a member with only 'view'" do
    repository = create_repository(user: @user)
    repository.test_runs.create!(commit_sha: "shared1", branch: "main", total_specs_count: 8,
                                 annotated_specs_count: 4, duration_seconds: 3.0)
    member = sign_in_via_github(uid: "9999")
    create_membership(repository: repository, user: member, permissions: %w[view])

    get repository_path(repository)

    expect(response).to have_http_status(:ok)
    expect(run_row("shared1")).to have_text("50.0%").and have_text("main")
  end
end
