# frozen_string_literal: true

require "rails_helper"

# The single-repository picker's search, driven in a real browser (SPGD-1902).
#
# The server renders repositories SpecGuard already holds as `disabled` options carrying
# `data-taken`. `repository_picker_controller.js#refine` used to set `option.disabled = !matches`
# for every option, which RE-ENABLES a taken row the moment a search matches it — and its "selected
# is hidden" fallback could then land on it. Only a browser runs that controller, so a request spec
# (which asserts on the HTML the server rendered) cannot notice the regression.
RSpec.describe "Single-repository picker search", type: :system do
  before do
    stub_github(repos: [github_repo("acme/api"), github_repo("acme/api-taken"), github_repo("acme/web")])
    sign_in_via_github_in_browser
    create_repository(user: create_user(github_uid: "9999", github_handle: "someone-else"),
                      github_full_name: "acme/api-taken")
    visit new_repository_path
  end

  def option(value) = find("#repository_github_full_name option[value='#{value}']", visible: :all)

  # Selenium reports a boolean DOM property as the string "true"/"false"; read it as a boolean.
  def disabled?(value) = option(value).native.property("disabled") == true

  # @intent: { entity: "RepositoryPicker", action: "search for a query that matches a registered repository", behavior: "the registered row stays disabled, the count names how many are already registered, and the selection lands on the registrable match rather than the taken one", layer: "system" }
  it "keeps a matching taken row disabled and never selects it" do
    fill_in "Search your repositories", with: "api"

    expect(page).to have_content("1 repository matches, 1 already registered")
    expect(disabled?("acme/api-taken")).to be(true)
    expect(disabled?("acme/api")).to be(false)
    expect(find("#repository_github_full_name").value).not_to eq("acme/api-taken")
  end

  # @intent: { entity: "RepositoryPicker", action: "search for a query that matches only a registered repository", behavior: "nothing is selectable, the selection is cleared and the count reads zero matches with one already registered", layer: "system" }
  it "selects nothing when the only match is taken" do
    fill_in "Search your repositories", with: "taken"

    expect(page).to have_content("0 repositories match, 1 already registered")
    expect(disabled?("acme/api-taken")).to be(true)
    expect(find("#repository_github_full_name").value).to eq("")
  end

  # @intent: { entity: "RepositoryPicker", action: "clear the search after matching a registered repository", behavior: "the taken row is still disabled and the free rows are enabled again", layer: "system" }
  it "restores the free rows but not the taken one when the search is cleared" do
    fill_in "Search your repositories", with: "web"
    fill_in "Search your repositories", with: ""

    expect(disabled?("acme/api-taken")).to be(true)
    expect(disabled?("acme/web")).to be(false)
    expect(disabled?("acme/api")).to be(false)
  end
end
