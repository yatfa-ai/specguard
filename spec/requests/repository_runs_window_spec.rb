# frozen_string_literal: true

require "rails_helper"

# SPGD-1911: the "Recent runs" panel is a WINDOW over an append-only history. These examples hold
# down that it says so only when it is one, that `?runs=` widens it to a bounded ceiling, and that
# the parameter is guarded like every other magnitude ask on this page.
RSpec.describe "Repository recent runs window", type: :request do
  before { @user = sign_in_via_github }

  let(:default_runs) { RequestedRunsParam::DEFAULT_RUNS }
  let(:max_runs) { RequestedRunsParam::MAX_RUNS }

  def page = Capybara.string(response.body)

  def runs_rows = page.find("#recent-runs table").all("tbody tr")

  def seed_runs(repository, count)
    count.times { |i| repository.test_runs.create!(commit_sha: format("win%04d", i), branch: "main", created_at: i.minutes.ago) }
  end

  describe "the disclosure" do
    # @intent: {"entity": "RecentRunsPanel", "action": "stay silent when not a window", "behavior": "a repository holding no more runs than the default window renders no window caption, widen link or back link", "layer": "request"}
    it "adds no text when every run is listed" do
      repository = create_repository(user: @user)
      seed_runs(repository, default_runs)

      get repository_path(repository)

      expect(runs_rows.size).to eq(default_runs)
      expect(page).to have_no_css("#recent-runs-window")
      expect(page).to have_no_link("Show up to #{max_runs} runs")
      expect(page).to have_no_link("Back to the newest #{default_runs}")
    end

    # @intent: {"entity": "RecentRunsPanel", "action": "disclose the window", "behavior": "with more runs than the default window the panel says it shows the newest ten of the total and offers a link to show up to the ceiling", "layer": "request"}
    it "says it shows the newest N of M and offers to widen" do
      repository = create_repository(user: @user)
      seed_runs(repository, 25)

      get repository_path(repository)

      expect(runs_rows.size).to eq(default_runs)
      expect(page.find("#recent-runs-window")).to have_text("Showing the newest #{default_runs} of 25 runs")
      link = page.find_link("Show up to #{max_runs} runs")
      expect(link[:href]).to include("runs=#{max_runs}").and include("#recent-runs")
      expect(page).to have_no_link("Back to the newest #{default_runs}")
    end

    # @intent: {"entity": "RecentRunsPanel", "action": "widen the window", "behavior": "?runs=25 on a 25-run repository lists all 25 rows, drops the caption and offers a back link to the default window", "layer": "request"}
    it "lists every run when widened to cover them, and links back" do
      repository = create_repository(user: @user)
      seed_runs(repository, 25)

      get repository_path(repository, runs: 25)

      expect(runs_rows.size).to eq(25)
      expect(page).to have_no_css("#recent-runs-window")
      back = page.find_link("Back to the newest #{default_runs}")
      expect(back[:href]).not_to include("runs=")
    end

    # @intent: {"entity": "RecentRunsPanel", "action": "disclose a partial widening", "behavior": "a widened window still shorter than the total says newest 20 of 60 and offers the ceiling link only while below it", "layer": "request"}
    it "keeps the caption while the widened window is still partial, and drops the widen link at the ceiling" do
      repository = create_repository(user: @user)
      seed_runs(repository, max_runs + 10)

      get repository_path(repository, runs: 20)
      expect(runs_rows.size).to eq(20)
      expect(page.find("#recent-runs-window")).to have_text("Showing the newest 20 of #{max_runs + 10} runs")
      expect(page).to have_link("Show up to #{max_runs} runs")

      get repository_path(repository, runs: max_runs)
      expect(runs_rows.size).to eq(max_runs)
      expect(page.find("#recent-runs-window")).to have_text("Showing the newest #{max_runs} of #{max_runs + 10} runs")
      expect(page).to have_no_link("Show up to #{max_runs} runs")
      expect(page).to have_link("Back to the newest #{default_runs}")
    end

    # @intent: {"entity": "RecentRunsPanel", "action": "clamp the ask", "behavior": "?runs=999999 lists exactly the ceiling number of rows", "layer": "request"}
    it "clamps an enormous ask to the ceiling" do
      repository = create_repository(user: @user)
      seed_runs(repository, max_runs + 5)

      get repository_path(repository, runs: "999999")

      expect(response).to have_http_status(:ok)
      expect(runs_rows.size).to eq(max_runs)
    end

    # @intent: {"entity": "RecentRunsPanel", "action": "carry the widening", "behavior": "a drill-down link on a widened page keeps runs in its query string while the same link on a default page carries none", "layer": "request"}
    it "carries the widening through drill-down links, and only when asked" do
      repository = create_repository(user: @user)
      seed_runs(repository, 12)

      get repository_path(repository)
      default_hrefs = page.all("a[href*='commit_sha=']", minimum: 1).map { |a| a[:href] }
      expect(default_hrefs).to all(satisfy { |href| !href.include?("runs=") })

      get repository_path(repository, runs: 12)
      widened_hrefs = page.all("[href*='commit_sha=']", visible: :all, minimum: 1).map { |a| a[:href] }
      expect(widened_hrefs).to all(include("runs=12"))
    end
  end

  describe "a runs parameter that is not a widening" do
    [
      ["an array", "runs[]=50"],
      ["a nested hash", "runs[a]=b"],
      ["an array of hashes", "runs[][a]=b"],
      ["a blank string", "runs="],
      ["a non-integer string", "runs=abc"],
      ["zero", "runs=0"],
      ["a negative integer", "runs=-3"]
    ].each do |shape, query|
      # @intent: {"entity": "RequestedRunsParam", "action": "treat non-widening runs as no ask", "behavior": "a runs parameter that is not a positive integer answers 200 with the default ten rows and no back link", "layer": "request"}
      it "answers 200 with the default window when runs arrives as #{shape}" do
        repository = create_repository(user: @user)
        seed_runs(repository, 25)

        get "#{repository_path(repository)}?#{query}"

        expect(response).to have_http_status(:ok)
        expect(runs_rows.size).to eq(default_runs)
        expect(page.find("#recent-runs-window")).to have_text("of 25 runs")
        expect(page).to have_no_link("Back to the newest #{default_runs}")
      end
    end
  end

  describe "the Delete control on a widened window" do
    # @intent: {"entity": "RecentRunsPanel", "action": "delete past the tenth run", "behavior": "a repo.delete holder widening to 25 runs sees a Delete button on every one of the 25 rows", "layer": "request"}
    it "renders Delete on every row for a repo.delete holder" do
      repository = create_repository(user: @user)
      seed_runs(repository, 25)

      get repository_path(repository, runs: 25)

      expect(runs_rows.size).to eq(25)
      expect(page.all("#recent-runs tbody tr button", text: "Delete").size).to eq(25)
    end

    # @intent: {"entity": "RecentRunsPanel", "action": "withhold delete from a viewer", "behavior": "a view-only member widening to 25 runs sees all 25 rows and no Delete button", "layer": "request"}
    it "renders no Delete for a view-only member, however wide the window" do
      repository = create_repository(user: @user)
      seed_runs(repository, 25)
      member = sign_in_via_github(uid: "9999", info: { nickname: "viewer" })
      create_membership(repository: repository, user: member, permissions: %w[view])

      get repository_path(repository, runs: 25)

      expect(runs_rows.size).to eq(25)
      expect(page.all("#recent-runs tbody tr button", text: "Delete")).to be_empty
    end
  end

  describe "query cost" do
    # @intent: {"entity": "RecentRunsPanel", "action": "keep widening free", "behavior": "rendering 25 sharded runs widened issues the same number of queries as rendering the default ten of them", "layer": "request"}
    it "issues the same number of queries widened as default" do
      repository = create_repository(user: @user)
      25.times do |i|
        run = repository.test_runs.create!(commit_sha: format("qry%04d", i), branch: "main", ci_run_id: "ci#{i}",
                                           total_specs_count: 8, created_at: (i + 1).hours.ago)
        2.times { |s| run.test_run_shards.create!(shard_id: s.to_s, total_specs_count: 4) }
      end

      get repository_path(repository)
      default_count = count_queries { get repository_path(repository) }
      widened_count = count_queries { get repository_path(repository, runs: 25) }

      expect(runs_rows.size).to eq(25)
      expect(widened_count).to eq(default_count)
    end
  end
end
