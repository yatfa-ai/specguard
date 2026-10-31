# frozen_string_literal: true

require "rails_helper"

# SPGD-1922: the "Recent runs" panel can be NARROWED to one branch with `?runs_branch=`, offered
# from each Branch cell. These examples hold down the whole slice in the panel's own vocabulary:
# the narrowing is honoured and offered (the cells link, rows without a branch do not), it
# composes with `?runs=`, the panel says what it is showing and offers the way out, a branch with
# no runs narrows to an honest empty state rather than another branch's rows, the parameter is
# guarded like every other branch ask on this page, the delete round-trips the narrowing, and the
# narrowing costs exactly one extra query — the branch total the caption reads.
#
# `?branch=` deliberately does NOT narrow this panel: that parameter selects the Suite-growth
# trajectory's series, and one example here pins the separation, because a regression that merged
# the two asks would re-point a panel a reader has already aimed — silently, on a page that would
# otherwise look perfectly healthy.
RSpec.describe "Repository recent runs branch narrowing", type: :request do
  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }
  let(:default_runs) { RequestedRunsParam::DEFAULT_RUNS }
  let(:max_runs) { RequestedRunsParam::MAX_RUNS }

  def page = Capybara.string(response.body)

  def runs_rows = page.find("#recent-runs table").all("tbody tr")

  def run_row(commit) = page.find("#recent-runs table").find("tbody tr", text: commit)

  # The Branch cell is the second column, per the header order the runs spec pins.
  def branch_cell(commit) = run_row(commit).all("td")[1]

  def seed_run(commit_sha:, branch:, created_at:)
    repository.test_runs.create!(commit_sha: commit_sha, branch: branch, created_at: created_at)
  end

  describe "the narrowing" do
    # @intent: {"entity": "RecentRunsPanel", "action": "narrow the panel to one branch", "behavior": "?runs_branch=main lists only main's runs in the panel's newest-first order, with no run from any other branch", "layer": "request"}
    it "lists only the asked branch's runs, newest first" do
      seed_run(commit_sha: "oldmain1", branch: "main", created_at: 3.hours.ago)
      seed_run(commit_sha: "featrow", branch: "feature/x", created_at: 2.hours.ago)
      seed_run(commit_sha: "oldmain2", branch: "main", created_at: 90.minutes.ago)
      seed_run(commit_sha: "newmain1", branch: "main", created_at: 1.hour.ago)

      get repository_path(repository, runs_branch: "main")

      expect(response).to have_http_status(:ok)
      expect(runs_rows.size).to eq(3)
      expect(runs_rows.first).to have_text("newmain1")
      expect(runs_rows.last).to have_text("oldmain1")
      expect(page).to have_no_text("featrow")
    end

    # @intent: {"entity": "RecentRunsPanel", "action": "offer the narrowing from Branch cells", "behavior": "each Branch cell of a run that reported a branch links to the panel narrowed to that branch, and a run reporting no branch renders a link-less not reported cell", "layer": "request"}
    it "links each named branch cell to the panel narrowed to it, and none for a branchless run" do
      seed_run(commit_sha: "onmain1", branch: "main", created_at: 2.hours.ago)
      seed_run(commit_sha: "onfeat1", branch: "feature/x", created_at: 1.hour.ago)
      seed_run(commit_sha: "nobranch1", branch: nil, created_at: 30.minutes.ago)

      get repository_path(repository)

      expect(branch_cell("onmain1")).to have_link("main")
      expect(branch_cell("onmain1").find("a")[:href]).to include("runs_branch=main")
      expect(branch_cell("onfeat1")).to have_link("feature/x")
      expect(branch_cell("onfeat1").find("a")[:href]).to include("runs_branch=feature%2Fx")
      expect(branch_cell("nobranch1")).to have_text("not reported")
      expect(branch_cell("nobranch1")).to have_no_css("a")
    end

    # @intent: {"entity": "RequestedRunsBranchParam", "action": "narrow a slashed branch whole", "behavior": "a branch whose name carries a slash narrows to exactly its own runs, the slash surviving the round trip", "layer": "request"}
    it "narrows a branch whose name carries a slash" do
      seed_run(commit_sha: "deepone1", branch: "feature/deep", created_at: 2.hours.ago)
      seed_run(commit_sha: "onmain1", branch: "main", created_at: 1.hour.ago)

      get repository_path(repository, runs_branch: "feature/deep")

      expect(response).to have_http_status(:ok)
      expect(runs_rows.size).to eq(1)
      expect(runs_rows.first).to have_text("deepone1")
      expect(page.find("#recent-runs-branch")).to have_text("Runs on feature/deep only.")
    end

    # @intent: {"entity": "RecentRunsPanel", "action": "keep trajectory ask off the panel", "behavior": "?branch=, which selects the Suite-growth series, leaves the Recent runs panel interleaved across every branch", "layer": "request"}
    it "does not narrow the panel when ?branch= names a trajectory series" do
      seed_run(commit_sha: "onmain1", branch: "main", created_at: 2.hours.ago)
      seed_run(commit_sha: "onfeat1", branch: "feature/x", created_at: 1.hour.ago)

      get repository_path(repository, branch: "feature/x")

      expect(response).to have_http_status(:ok)
      expect(runs_rows.size).to eq(2)
      expect(page).to have_text("onmain1")
      expect(page).to have_no_css("#recent-runs-branch")
    end
  end

  describe "the disclosure" do
    # @intent: {"entity": "RecentRunsPanel", "action": "disclose the narrowed window", "behavior": "a narrowed panel listing fewer runs than its branch holds says newest 10 of 12 runs on main, offers to widen while carrying the narrowing, and says Runs on main only with an All branches link back", "layer": "request"}
    it "says newest N of M on the branch, offers to widen, and offers the way out" do
      12.times { |i| seed_run(commit_sha: format("brn%04d", i), branch: "main", created_at: (i + 1).hours.ago) }
      3.times { |i| seed_run(commit_sha: format("oth%04d", i), branch: "feature/x", created_at: (i + 1).minutes.ago) }

      get repository_path(repository, runs_branch: "main")

      expect(runs_rows.size).to eq(10)
      expect(page.find("#recent-runs-branch")).to have_text("Runs on main only.")
      widen = page.find_link("All branches")
      expect(widen[:href]).not_to include("runs_branch")
      expect(page.find("#recent-runs-window"))
        .to have_text("Showing the newest 10 of 12 runs on main.")
      ceiling = page.find_link("Show up to #{max_runs} runs")
      expect(ceiling[:href]).to include("runs=#{max_runs}").and include("runs_branch=main")
    end

    # @intent: {"entity": "RecentRunsPanel", "action": "stay silent on a full branch", "behavior": "a narrowed panel listing every run its branch holds renders the Runs-on note but no window caption or widen link", "layer": "request"}
    it "renders no window disclosure when the branch is fully listed" do
      3.times { |i| seed_run(commit_sha: format("brn%04d", i), branch: "main", created_at: (i + 1).hours.ago) }
      8.times { |i| seed_run(commit_sha: format("oth%04d", i), branch: "feature/x", created_at: (i + 1).minutes.ago) }

      get repository_path(repository, runs_branch: "main")

      expect(runs_rows.size).to eq(3)
      expect(page.find("#recent-runs-branch")).to have_text("Runs on main only.")
      expect(page).to have_no_css("#recent-runs-window")
      expect(page).to have_no_link("Show up to #{max_runs} runs")
    end

    # @intent: {"entity": "RecentRunsPanel", "action": "compose the asks", "behavior": "runs_branch composes with runs, the branch arithmetic winning the caption, and the All branches link returns the panel to every branch", "layer": "request"}
    it "composes with ?runs= and the All branches link undoes the narrowing" do
      12.times { |i| seed_run(commit_sha: format("brn%04d", i), branch: "main", created_at: (i + 1).hours.ago) }
      2.times { |i| seed_run(commit_sha: format("oth%04d", i), branch: "feature/x", created_at: (i + 1).minutes.ago) }

      get repository_path(repository, runs_branch: "main", runs: 5)
      expect(runs_rows.size).to eq(5)
      expect(page.find("#recent-runs-window")).to have_text("Showing the newest 5 of 12 runs on main.")
      expect(page).to have_link("Back to the newest #{default_runs}")

      # "All branches" undoes the NARROWING and nothing else: `runs=5` is a carried ask
      # (SPGD-1911's rule — a panel-level gesture must not collapse a widening), so the followed
      # page is the same five-row window, re-pooled across every branch.
      get page.find_link("All branches")[:href].split("#").first
      expect(runs_rows.size).to eq(5)
      expect(page).to have_no_css("#recent-runs-branch")
      expect(page).to have_text("oth0001")
      expect(page).to have_text("brn0000")
    end

    # @intent: {"entity": "RecentRunsPanel", "action": "carry the narrowing", "behavior": "a drill-down link on a narrowed page keeps runs_branch in its query string while the same link on a default page carries none", "layer": "request"}
    it "carries the narrowing through drill-down links, and only when asked" do
      seed_run(commit_sha: "onmain1", branch: "main", created_at: 1.hour.ago)

      get repository_path(repository)
      default_hrefs = page.all("a[href*='commit_sha=']", minimum: 1).map { |a| a[:href] }
      expect(default_hrefs).to all(satisfy { |href| !href.include?("runs_branch") })

      get repository_path(repository, runs_branch: "main")
      narrowed_hrefs = page.all("a[href*='commit_sha=']", visible: :all, minimum: 1).map { |a| a[:href] }
      expect(narrowed_hrefs).to all(include("runs_branch=main"))
    end

    # SPGD-1940: `test_runs` has no uniqueness on `commit_sha`, and a sha link opens the NEWEST run
    # on that sha repository-wide. On a narrowed window the feature row is the only row with its
    # sha, so a window-local "seen" list would send the reader to the main run the panel does not
    # list, with nothing saying so. Such a row is addressed by run id instead.
    # @intent: {"entity": "RecentRunsPanel", "action": "address a narrowed row by run id when its sha was reported from another branch", "behavior": "on ?runs_branch=feature/x a row whose commit_sha was also reported from main has a Read this run href with run=<its id> and runs_branch= and no commit_sha=, and following it anchors the page on that feature run", "layer": "request"}
    it "addresses a narrowed row by run id when its sha also exists on another branch" do
      feature_run = seed_run(commit_sha: "sharedsha1", branch: "feature/x", created_at: 3.hours.ago)
      seed_run(commit_sha: "sharedsha1", branch: "main", created_at: 2.hours.ago)
      seed_run(commit_sha: "uniqfeat1", branch: "feature/x", created_at: 4.hours.ago)

      get repository_path(repository, runs_branch: "feature/x")

      href = run_row("sharedsha1").find("a", exact_text: "Read this run", visible: :all)[:href]
      expect(href).to include("run=#{feature_run.id}")
      expect(href).to include("runs_branch=")
      expect(href).not_to include("commit_sha=")
      # A unique sha keeps the sha link it has always had.
      unique_href = run_row("uniqfeat1").find("a", exact_text: "Read this run", visible: :all)[:href]
      expect(unique_href).to include("commit_sha=uniqfeat1")

      uri = URI.parse(href)
      get [uri.path, uri.query].compact.join("?")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("run ##{feature_run.id}")
    end
  end

  describe "a runs_branch parameter that is not a narrowing" do
    [
      ["an array", "runs_branch[]=main"],
      ["a nested hash", "runs_branch[a]=b"],
      ["an array of hashes", "runs_branch[][a]=b"],
      ["a string carrying a NUL", "runs_branch=ma%00in"],
      ["a blank string", "runs_branch="]
    ].each do |shape, query|
      # @intent: {"entity": "RequestedRunsBranchParam", "action": "treat non-string and NUL-carrying runs_branch as no ask", "behavior": "a runs_branch parameter in a non-String shape, carrying a NUL, or blank answers 200 with the all-branch interleaved window rather than 500, matching an absent parameter", "layer": "request"}
      it "answers 200 with every branch when runs_branch arrives as #{shape}" do
        9.times { |i| seed_run(commit_sha: format("old%04d", i), branch: "main", created_at: (i + 10).hours.ago) }
        seed_run(commit_sha: "newfeat1", branch: "feature/x", created_at: 5.minutes.ago)

        get "#{repository_path(repository)}?#{query}"

        expect(response).to have_http_status(:ok)
        expect(page).to have_text("newfeat1")
        expect(page).to have_no_css("#recent-runs-branch")
      end
    end
  end

  describe "a branch with no runs" do
    # @intent: {"entity": "RecentRunsPanel", "action": "show an honest empty state", "behavior": "narrowing to a branch with no runs renders No runs on ghost with an All branches link and none of the other branches' rows", "layer": "request"}
    it "renders the asked branch's empty state and never falls back to other branches" do
      seed_run(commit_sha: "onmain1", branch: "main", created_at: 1.hour.ago)

      get repository_path(repository, runs_branch: "ghost")

      expect(response).to have_http_status(:ok)
      panel = page.find("#recent-runs")
      expect(panel).to have_text("No runs on ghost")
      expect(panel).to have_link("All branches")
      expect(panel).to have_no_text("onmain1")
      expect(page).to have_no_css("#recent-runs-basis")
    end
  end

  describe "the basis note" do
    # SPGD-1991: the narrowed branch of `#recent-runs-basis` claims these rows are the branch's
    # newest runs — true on the narrowing's own newest page, false the moment a `runs_before=`
    # cursor is carried into the same ask, where the rows are the runs older than the cursor.
    # The un-paged sentence is pinned here; the paged shape is pinned where the cursor lives
    # (repository_runs_before_spec.rb, the composition example).
    # @intent: {"entity": "RecentRunsPanel", "action": "say the narrowed basis", "behavior": "a narrowed un-paged panel's basis note opens with The newest runs CI reported from the main branch, newest first, naming one branch's series rather than the pooled history", "layer": "request"}
    it "names the branch's newest runs on the narrowing's own newest page" do
      3.times { |i| seed_run(commit_sha: format("bas%04d", i), branch: "main", created_at: (i + 1).hours.ago) }

      get repository_path(repository, runs_branch: "main")

      expect(page.find("#recent-runs-basis"))
        .to have_text("The newest runs CI reported from the main branch, newest first.")
    end
  end

  describe "the Delete control on a narrowed panel" do
    # @intent: {"entity": "RecentRunsPanel", "action": "carry the narrowing in the delete form", "behavior": "a narrowed panel's Delete forms each carry a hidden runs_branch field with the asked value, and the default panel's forms carry none", "layer": "request"}
    it "renders the narrowing in the Delete form only when the panel was narrowed" do
      12.times { |i| seed_run(commit_sha: format("brn%04d", i), branch: "main", created_at: (i + 1).hours.ago) }
      2.times { |i| seed_run(commit_sha: format("oth%04d", i), branch: "feature/x", created_at: (i + 1).minutes.ago) }

      get repository_path(repository)
      expect(Capybara.string(response.body)).to have_no_css("#recent-runs form input[name='runs_branch']")

      get repository_path(repository, runs_branch: "main")
      inputs = Capybara.string(response.body).all("#recent-runs form input[name='runs_branch']", visible: :all)
      expect(inputs.size).to eq(10)
      expect(inputs.map { |i| i[:value] }.uniq).to eq(["main"])
    end

    # @intent: {"entity": "RunsController", "action": "carry the asked narrowing", "behavior": "deleting with runs_branch=main redirects to the repository page with runs_branch=main and the followed page still lists only main with a caption counting one fewer run", "layer": "request"}
    it "redirects back to the narrowed panel and the followed page keeps it" do
      12.times { |i| seed_run(commit_sha: format("brn%04d", i), branch: "main", created_at: (i + 1).hours.ago) }
      3.times { |i| seed_run(commit_sha: format("oth%04d", i), branch: "feature/x", created_at: (i + 1).minutes.ago) }
      victim = repository.test_runs.where(branch: "main").order(:created_at).first

      delete repository_run_path(repository, victim), params: { runs_branch: "main" }

      expect(response).to redirect_to(repository_path(repository, runs_branch: "main"))
      follow_redirect!
      page = Capybara.string(response.body)
      expect(page.find("#recent-runs table").all("tbody tr").size).to eq(10)
      expect(page.find("#recent-runs")).to have_no_text("oth0002")
      expect(page.find("#recent-runs-window")).to have_text("Showing the newest 10 of 11 runs on main.")
    end

    # @intent: {"entity": "RunsController", "action": "carry both asks on delete", "behavior": "deleting with runs and runs_branch redirects with both, and a narrowed delete of the branch's last run lands on the branch's empty state rather than another branch's rows", "layer": "request"}
    it "carries both asks, and an emptied branch narrows to its own empty state" do
      11.times { |i| seed_run(commit_sha: format("brn%04d", i), branch: "main", created_at: (i + 1).hours.ago) }
      seed_run(commit_sha: "lonemain1", branch: "solo", created_at: 30.minutes.ago)
      seed_run(commit_sha: "onfeat1", branch: "feature/x", created_at: 5.minutes.ago)

      delete repository_run_path(repository, repository.test_runs.find_by!(commit_sha: "brn0000")),
             params: { runs: "25", runs_branch: "main" }
      expect(response).to redirect_to(repository_path(repository, runs: 25, runs_branch: "main"))

      delete repository_run_path(repository, repository.test_runs.find_by!(commit_sha: "lonemain1")),
             params: { runs_branch: "solo" }
      follow_redirect!
      page = Capybara.string(response.body)
      expect(page.find("#recent-runs")).to have_text("No runs on solo")
      expect(page.find("#recent-runs")).to have_no_text("onfeat1")
    end

    [
      ["an array", "runs_branch[]=x"],
      ["a nested hash", "runs_branch[a]=b"],
      ["a string carrying a NUL", "runs_branch=ma%00in"],
      ["a blank string", "runs_branch="]
    ].each do |shape, query|
      # @intent: {"entity": "RunsController", "action": "ignore a hostile runs_branch ask", "behavior": "a runs_branch parameter that is not a plain branch-name string redirects to the bare repository path exactly as a delete with no ask", "layer": "request"}
      it "redirects to the bare repository path when runs_branch arrives as #{shape}" do
        run = seed_run(commit_sha: "victim1", branch: "main", created_at: 1.hour.ago)

        delete "#{repository_run_path(repository, run)}?#{query}"

        expect(response).to redirect_to(repository_path(repository))
        expect(response.location).not_to include("runs_branch")
      end
    end

    # @intent: {"entity": "RunsController", "action": "round-trip an unknown branch", "behavior": "a well-formed but unknown branch on delete is honoured, not ignored, and the followed panel answers with that branch's empty state rather than the surviving branch's rows", "layer": "request"}
    it "round-trips a well-formed unknown branch as the narrowing it asked for" do
      survivor = seed_run(commit_sha: "onmain1", branch: "main", created_at: 2.hours.ago)
      victim = seed_run(commit_sha: "victim1", branch: "main", created_at: 1.hour.ago)

      delete repository_run_path(repository, victim), params: { runs_branch: "ghost" }

      expect(response).to redirect_to(repository_path(repository, runs_branch: "ghost"))
      follow_redirect!
      page = Capybara.string(response.body)
      expect(page.find("#recent-runs")).to have_text("No runs on ghost")
      expect(page.find("#recent-runs")).to have_no_text("onmain1")
      expect(TestRun.exists?(survivor.id)).to be true
    end
  end

  describe "query cost" do
    # @intent: {"entity": "RecentRunsPanel", "action": "price the narrowing at one count", "behavior": "rendering the panel narrowed to a branch issues exactly two more test_runs statements than the default page - the branch total and the newest-run-per-sha read - and no other read moves", "layer": "request"}
    it "costs one extra count and one newest-per-sha read narrowed, and the default page none" do
      12.times { |i| seed_run(commit_sha: format("brn%04d", i), branch: "main", created_at: (i + 1).hours.ago) }
      2.times { |i| seed_run(commit_sha: format("oth%04d", i), branch: "feature/x", created_at: (i + 1).minutes.ago) }

      default = queries_against(/FROM "test_runs"/) { get repository_path(repository) }
      narrowed = queries_against(/FROM "test_runs"/) { get repository_path(repository, runs_branch: "main") }

      expect(runs_rows.size).to eq(10)
      # +1 for the branch total, and at most +1 for the newest-run-per-sha read behind the rows'
      # "Read this run" links (SPGD-1940).
      expect(narrowed.size).to eq(default.size + 2)
      expect(narrowed.count { |sql| sql.include?("COUNT") })
        .to eq(default.count { |sql| sql.include?("COUNT") } + 1)
      expect(narrowed.count { |sql| sql.include?("DISTINCT ON") }).to eq(1)
      expect(default.count { |sql| sql.include?("DISTINCT ON") }).to eq(0)
    end
  end
end
