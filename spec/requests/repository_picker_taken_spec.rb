# frozen_string_literal: true

require "rails_helper"

# SPGD-1902: the single-repository picker greys out and badges repositories SpecGuard already holds.
#
# `github_full_name` is unique across SpecGuard and case-insensitively so, which means a listed
# repository somebody has already registered can only ever be picked into a 422. The bulk picker
# already refuses to offer such a row; this is the same fact on `/repositories/new` and
# `/repositories/:id/edit`. Display only — the 422 examples in repository_github_verification_spec
# and repository_registration_web_path_spec still pin the gate itself.
RSpec.describe "Already-registered repositories in the single-repository picker", type: :request do
  before { @user = sign_in_via_github }

  let(:other_user) { create_user(github_uid: "9999", github_handle: "someone-else") }

  def options
    Nokogiri::HTML(response.body).css("select#repository_github_full_name option")
  end

  def option_for(value) = options.find { |o| o["value"] == value }

  describe "GET /repositories/new" do
    before do
      create_repository(user: other_user, github_full_name: "acme/b")
      create_repository(user: create_user(github_uid: "8888", github_handle: "third"),
                        github_full_name: "Acme/C")
      stub_github(repos: [github_repo("acme/a"), github_repo("acme/b"), github_repo("acme/c")])
    end

    # @intent: {"entity": "GET /repositories/new", "action": "disable registered repositories", "behavior": "options for a repository registered by another user and one registered under different case carry disabled, data-taken and the already registered note, while the free repository stays selectable with unchanged text", "layer": "request"}
    it "disables and badges taken repositories and leaves the free one alone" do
      get new_repository_path

      expect(option_for("acme/a")["disabled"]).to be_nil
      expect(option_for("acme/a")["data-taken"]).to be_nil
      expect(option_for("acme/a").text).to eq("acme/a")

      %w[acme/b acme/c].each do |name|
        expect(option_for(name)).to have_attributes(text: "#{name} · already registered")
        expect(option_for(name)["disabled"]).to be_present
        expect(option_for(name)["data-taken"]).to eq("true")
      end
    end

    # @intent: {"entity": "GET /repositories/new", "action": "order the registered note", "behavior": "a private archived registered repository reads private, archived, already registered in that order", "layer": "request"}
    it "puts the registered note after private and archived" do
      create_repository(user: other_user, github_full_name: "acme/vault")
      stub_github(repos: [github_repo("acme/vault", private: true, archived: true)])

      get new_repository_path

      expect(option_for("acme/vault").text).to eq("acme/vault · private, archived, already registered")
    end

    # @intent: {"entity": "GET /repositories/new", "action": "read taken names once", "behavior": "a page that renders the picker issues exactly one LOWER(github_full_name) IN query", "layer": "request"}
    it "asks which names are held in exactly one query" do
      queries = queries_against(/LOWER\(repositories\.github_full_name\) IN/) { get new_repository_path }

      expect(queries.size).to eq(1)
    end

    # @intent: {"entity": "GET /repositories/new", "action": "leave a mixed listing without the empty alert", "behavior": "the Nothing left to register alert is absent while at least one repository is registrable", "layer": "request"}
    it "does not say there is nothing left while something is registrable" do
      get new_repository_path

      expect(response.body).not_to include("Nothing left to register")
    end
  end

  describe "when every listed repository is taken" do
    # @intent: {"entity": "GET /repositories/new", "action": "explain an all-taken listing", "behavior": "the Nothing left to register alert renders above the form and every option is disabled", "layer": "request"}
    it "says so rather than showing a wall of disabled rows" do
      create_repository(user: other_user, github_full_name: "acme/b")
      stub_github(repos: [github_repo("acme/b")])

      get new_repository_path

      expect(response.body).to include("Nothing left to register")
      expect(options.reject { |o| o["value"].blank? }).to all(satisfy { |o| o["disabled"].present? })
    end
  end

  describe "branches that render no picker" do
    # @intent: {"entity": "GET /repositories/new", "action": "skip the taken-names read without a picker", "behavior": "install-needed, reconnect, unavailable and empty-listing pages issue no LOWER(github_full_name) IN query", "layer": "request"}
    it "issues no taken-names query" do
      pattern = /LOWER\(repositories\.github_full_name\) IN/

      uninstall_github_app(@user)
      stub_github(unauthorized: true)
      expect(queries_against(pattern) { get new_repository_path }).to be_empty

      stub_github(unavailable: true)
      expect(queries_against(pattern) { get new_repository_path }).to be_empty
    end

    # @intent: {"entity": "GET /repositories/new", "action": "skip the taken-names read on an empty listing", "behavior": "an installed App covering nothing issues no LOWER(github_full_name) IN query", "layer": "request"}
    it "issues no taken-names query for an empty listing" do
      stub_github(repos: [])

      queries = queries_against(/LOWER\(repositories\.github_full_name\) IN/) { get new_repository_path }

      expect(queries).to be_empty
    end

    # @intent: {"entity": "GET /repositories/new", "action": "skip the taken-names read when reconnect is needed", "behavior": "an installed App with a rejected token shows Reconnect and issues no LOWER(github_full_name) IN query", "layer": "request"}
    it "issues no taken-names query while offering the reconnect button" do
      allow(SpecGuard::GithubApp).to receive_messages(configured?: true, slug: "specguard")
      stub_github(unauthorized: true)

      queries = queries_against(/LOWER\(repositories\.github_full_name\) IN/) { get new_repository_path }

      expect(response.body).to include("Reconnect to GitHub")
      expect(queries).to be_empty
    end
  end

  describe "GET /repositories/:id/edit" do
    # @intent: {"entity": "GET /repositories/:id/edit", "action": "keep own name selectable", "behavior": "the repository's own current name is not disabled while another registered name in the listing is", "layer": "request"}
    it "never marks the repository's own current name as taken" do
      repository = create_repository(user: @user, github_full_name: "acme/mine")
      create_repository(user: other_user, github_full_name: "acme/theirs")
      stub_github(repos: [github_repo("acme/mine"), github_repo("acme/theirs"), github_repo("acme/free")])

      get edit_repository_path(repository)

      expect(option_for("acme/mine")["disabled"]).to be_nil
      expect(option_for("acme/mine").text).to eq("acme/mine")
      expect(option_for("acme/theirs")["disabled"]).to be_present
      expect(option_for("acme/theirs").text).to eq("acme/theirs · already registered")
      expect(option_for("acme/free")["disabled"]).to be_nil
    end
  end

  describe "Repository.registered_names_among" do
    # @intent: {"entity": "Repository", "action": "read registered names case-insensitively", "behavior": "returns downcased held names for any-case input, ignores free names and runs no query for empty input", "layer": "unit"}
    it "answers case-insensitively, globally, and without a query when empty" do
      create_repository(user: other_user, github_full_name: "Acme/Held")

      expect(Repository.registered_names_among(%w[acme/HELD acme/free])).to eq(Set["acme/held"])
      expect(queries_against("repositories") { Repository.registered_names_among([]) }).to be_empty
    end
  end
end
