# frozen_string_literal: true

require "rails_helper"

# The client-side column sort of the console tables, driven in a real browser (SPGD-2080).
#
# `datatable_controller.js` is the only place that decides row order after the server has rendered a
# capped ranking, and it is the sorter behind every `UI::TableComponent.new(sortable: true)` panel.
# The request specs that read these tables assert on the HTML the server rendered (a `data-sort`
# ATTRIBUTE is present); none of them clicks a header, so none can observe the controller. Only a
# browser runs it. Recent runs is the panel under test because its rows carry all three inputs the
# key parser branches on: a numeric `data-sort` (Tests), a text cell (Branch) and a cell reading
# `not reported` (a run that reported no branch).
RSpec.describe "Console table column sort", type: :system do
  # Newest first, which is the order the server renders. Two runs tie on Tests (12), so the original
  # DOM order is observable: `a1` precedes `c3` in the page and must precede it after every sort.
  # The test counts are chosen so that sorting them as TEXT ("12" < "40" < "7") disagrees with
  # sorting them as numbers (7 < 12 < 40).
  RUNS = [
    { commit_sha: "a1a1a1a1", branch: "main",  total_specs_count: 12, created_at: 1.hour.ago },
    { commit_sha: "b2b2b2b2", branch: "zeta",  total_specs_count: 40, created_at: 2.hours.ago },
    { commit_sha: "c3c3c3c3", branch: nil,     total_specs_count: 12, created_at: 3.hours.ago },
    { commit_sha: "d4d4d4d4", branch: "alpha", total_specs_count: 7,  created_at: 4.hours.ago }
  ].freeze

  before do
    stub_github
    user = sign_in_via_github_in_browser
    repository = create_repository(user: user)
    RUNS.each { |attrs| create_test_run(repository: repository, **attrs) }
    visit repository_path(repository)
  end

  # Matched case-insensitively: the stylesheet upper-cases header text, and a browser reports the
  # text it renders.
  def header(label) = find("#recent-runs thead th button", text: /\A#{label}\z/i)

  def sort_by(label) = header(label).click

  # The commit column, top to bottom, abbreviated to the seven characters the table prints.
  def commits = all("#recent-runs tbody tr td:first-child .row-open").map(&:text)

  def aria_sorted = all("#recent-runs thead th[aria-sort]").map { |th| [th.text.capitalize, th[:"aria-sort"]] }

  # @intent: { entity: "DatatableController", action: "click a numeric column header twice", behavior: "the rows order by the numeric data-sort ascending then descending, rows with an equal value keep their original relative order in both directions, and aria-sort names the direction on the clicked header", layer: "system" }
  it "sorts a numeric column by value, toggles direction, and keeps ties in their original order" do
    expect(commits).to eq(%w[a1a1a1a b2b2b2b c3c3c3c d4d4d4d])

    sort_by("Tests")
    expect(aria_sorted).to eq([["Tests", "ascending"]])
    expect(commits).to eq(%w[d4d4d4d a1a1a1a c3c3c3c b2b2b2b])

    sort_by("Tests")
    expect(aria_sorted).to eq([["Tests", "descending"]])
    expect(commits).to eq(%w[b2b2b2b a1a1a1a c3c3c3c d4d4d4d])
  end

  # @intent: { entity: "DatatableController", action: "click a text column header twice when one row has no value", behavior: "the row whose cell reads not reported sorts last in both directions while the reported values order ascending then descending", layer: "system" }
  it "sorts a missing value last in both directions" do
    sort_by("Branch")
    expect(aria_sorted).to eq([["Branch", "ascending"]])
    expect(commits).to eq(%w[d4d4d4d a1a1a1a b2b2b2b c3c3c3c])

    sort_by("Branch")
    expect(aria_sorted).to eq([["Branch", "descending"]])
    expect(commits).to eq(%w[b2b2b2b a1a1a1a d4d4d4d c3c3c3c])
  end

  # @intent: { entity: "DatatableController", action: "click one column header after another", behavior: "only the most recently clicked header carries aria-sort", layer: "system" }
  it "marks only the most recently sorted header" do
    sort_by("Tests")
    sort_by("Branch")

    expect(aria_sorted).to eq([["Branch", "ascending"]])
  end
end
