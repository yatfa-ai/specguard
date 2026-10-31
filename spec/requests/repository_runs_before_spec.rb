# frozen_string_literal: true

require "rails_helper"

# SPGD-1984: the "Recent runs" panel pages past its widening cap with `?runs_before=` — a keyset
# cursor naming the position the listed window ENDED at, answered with the runs strictly older
# than it on the same `(created_at DESC, id: DESC)` ordering everything else on this page sorts
# by. These examples hold down the whole slice in the panel's own vocabulary, mirroring
# `repository_runs_branch_spec.rb`'s one-param-one-file shape: the guard matrix (every hostile
# shape is no ask), the keyset continuity (zero overlap, zero gap, shared `created_at` included —
# the two failure modes a bare `created_at <` / `<=` would produce, skipped ties and repeated
# cursors), the caption and link states per page, the composition with `?runs=` and
# `?runs_branch=`, the sha links across a page boundary, the cost, and the dead-cursor posture.
RSpec.describe "Repository recent runs keyset paging", type: :request do
  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }
  let(:default_runs) { RequestedRunsParam::DEFAULT_RUNS }
  let(:max_runs) { RequestedRunsParam::MAX_RUNS }

  def page = Capybara.string(response.body)

  def runs_rows = page.find("#recent-runs table").all("tbody tr")

  # The seeded shas the rows list, in rendered order (newest first). The seeds use distinct
  # shas on purpose, so the row sequence IS the run sequence and the keyset's continuity is
  # assertable from the DOM alone.
  def listed_shas = runs_rows.map { |row| row.text[/win\d{4}/] }

  # Creates `count` runs, one per minute, and returns them NEWEST FIRST (index 0 is the newest),
  # so a fixture can name boundary positions arithmetically: position k (1-based, newest first)
  # is `runs[k - 1]`.
  def seed_runs(count, branch: "main", prefix: "win")
    Array.new(count) do |i|
      create_test_run(repository: repository, commit_sha: format("#{prefix}%04d", i),
                      branch: branch, created_at: (i + 1).minutes.ago)
    end
  end

  describe "the keyset continuation" do
    # @intent: {"entity": "RecentRunsPanel", "action": "page past the cap without overlap or gap", "behavior": "following Older runs from the newest 50 of 55 runs renders exactly the next five rows in the same ordering, repeating no listed row and skipping none, with the two runs sharing one created_at at the boundary neither repeated nor skipped", "layer": "request"}
    it "continues the newest-first ordering exactly, ties at the boundary included" do
      runs = seed_runs(55)
      # The page boundary is exactly where same-instant ties land: two runs ingested in the same
      # second, one ending page one and one beginning page two, seeded through the
      # `update_all(created_at:)` discipline the window-baseline file uses. After the update the
      # shared pair sits at positions 50 (runs[50], the higher id) and 51 (runs[49]), and the
      # row-value comparison `(created_at, id) <` must answer the lower-id half without repeating
      # the cursor — a bare `created_at <` would skip it, a bare `<=` would repeat the cursor.
      TestRun.where(id: [runs[49].id, runs[50].id]).update_all(created_at: 50.minutes.ago)

      get repository_path(repository, runs: max_runs)

      expect(runs_rows.size).to eq(50)
      first_page_shas = listed_shas
      expect(first_page_shas.last).to eq("win0050")

      get page.find_link("Older runs")[:href].split("#").first

      expect(response).to have_http_status(:ok)
      expect(listed_shas).to eq(%w[win0049 win0051 win0052 win0053 win0054])
      # Zero overlap: nothing on page two appeared on page one, cursor included.
      expect(listed_shas & first_page_shas).to be_empty
    end
  end

  describe "the caption and the links" do
    # @intent: {"entity": "RecentRunsPanel", "action": "offer Older runs where the widen link is suppressed", "behavior": "on the newest page at the ceiling the caption still says newest 50 of 55, the Show-up-to link is gone, and an Older runs link naming the oldest listed row appears in its place", "layer": "request"}
    it "offers Older runs at the cap where the widen link used to dead-end" do
      runs = seed_runs(55)

      get repository_path(repository, runs: max_runs)

      expect(runs_rows.size).to eq(50)
      expect(page.find("#recent-runs-window")).to have_text("Showing the newest 50 of 55 runs.")
      expect(page).to have_no_link("Show up to #{max_runs} runs")
      older = page.find_link("Older runs")
      expect(older[:href]).to include("runs_before=#{runs[49].id}").and include("runs=#{max_runs}")
    end

    # @intent: {"entity": "RecentRunsPanel", "action": "caption a paged page", "behavior": "a page reached past the cap reads Runs older than the newest 50 runs, offers Newest runs back without cursor bytes, and offers the next Older runs only while rows follow", "layer": "request"}
    it "says the window is paged, offers the way back, and offers the next page only when one exists" do
      runs = seed_runs(max_runs * 2 + 5)

      get repository_path(repository, runs: max_runs)
      get page.find_link("Older runs")[:href].split("#").first

      expect(runs_rows.size).to eq(50)
      expect(page.find("#recent-runs-window")).to have_text("Runs older than the newest #{max_runs} runs.")
      newest = page.find_link("Newest runs")
      expect(newest[:href]).to include("runs=#{max_runs}")
      expect(newest[:href]).not_to include("runs_before")
      # A mid-window page has a page after it, starting at this page's own oldest row.
      older = page.find_link("Older runs")
      expect(older[:href]).to include("runs_before=#{runs[99].id}")

      get older[:href].split("#").first

      expect(runs_rows.size).to eq(5)
      expect(page.find("#recent-runs-window")).to have_text("Runs older than the newest #{max_runs} runs.")
      expect(page).to have_link("Newest runs")
      # The last page offers no further page.
      expect(page).to have_no_link("Older runs")
    end

    # @intent: {"entity": "RecentRunsPanel", "action": "keep the default page untouched", "behavior": "a default page on a widened-eligible repository renders the widen link and no Older runs link, and no link on the page carries runs_before bytes", "layer": "request"}
    it "renders no cursor affordance and no cursor bytes on the default page" do
      seed_runs(55)

      get repository_path(repository)

      expect(page).to have_link("Show up to #{max_runs} runs")
      expect(page).to have_no_link("Older runs")
      hrefs = page.all("a[href*='commit_sha=']", minimum: 1).map { |a| a[:href] }
      expect(hrefs).to all(satisfy { |href| !href.include?("runs_before") })
    end
  end

  describe "composition with the other panel asks" do
    # @intent: {"entity": "RecentRunsPanel", "action": "page one branch's series", "behavior": "runs_branch, runs and runs_before compose, the followed page holding exactly that branch's next rows with a basis note naming the paged population rather than the newest runs, and All branches un-narrows while keeping the reader paged, its un-narrowed note unchanged", "layer": "request"}
    it "pages a narrowed series and lets All branches un-narrow without dropping the position" do
      seed_runs(55, branch: "main")
      5.times { |i| create_test_run(repository: repository, commit_sha: format("feat%04d", i),
                                    branch: "feature/x", created_at: (i + 1).seconds.ago) }

      get repository_path(repository, runs_branch: "main", runs: max_runs)
      expect(page.find("#recent-runs-window")).to have_text("Showing the newest 50 of 55 runs on main.")
      get page.find_link("Older runs")[:href].split("#").first

      expect(runs_rows.size).to eq(5)
      expect(page.find("#recent-runs")).to have_no_text("feat0004")
      # SPGD-1991: the followed page is a paged NARROWED window — the rows are the branch's
      # runs older than the cursor — so the basis note names that population and cannot open
      # with the newest-runs claim the branch's own newest page carries.
      basis = page.find("#recent-runs-basis")
      expect(basis).to have_text("Runs CI reported from the main branch, older than the newest #{max_runs} runs, newest first.")
      expect(basis).to have_no_text("The newest runs CI reported from")
      all_branches = page.find_link("All branches")
      expect(all_branches[:href]).not_to include("runs_branch")
      expect(all_branches[:href]).to include("runs_before=")

      get all_branches[:href].split("#").first

      expect(runs_rows.size).to eq(5)
      expect(page.find("#recent-runs-window")).to have_text("Runs older than the newest #{max_runs} runs.")
      # SPGD-1991: paging alone leaves the un-narrowed note untouched — the pooled history is
      # interleaved on every page of it, the cursor only moves where the page sits.
      expect(page.find("#recent-runs-basis"))
        .to have_text("One history across every branch CI reports from, interleaved, newest first")
    end

    # @intent: {"entity": "RecentRunsPanel", "action": "clear the asks from a paged page", "behavior": "Newest runs keeps the carried widening and drops only the cursor, Back to the newest 10 drops both and lands on the default newest page, and a Branch cell narrows to its own branch at its newest page with no cursor bytes", "layer": "request"}
    it "clears the cursor through Newest runs, Back to the newest 10, and the Branch cells" do
      seed_runs(55)

      get repository_path(repository, runs: max_runs)
      cursor_href = page.find_link("Older runs")[:href].split("#").first
      get cursor_href

      newest = page.find_link("Newest runs")
      get newest[:href].split("#").first
      expect(runs_rows.size).to eq(50)
      expect(page.find("#recent-runs-window")).to have_text("Showing the newest 50 of 55 runs.")

      get cursor_href
      back = page.find_link("Back to the newest #{default_runs}")
      expect(back[:href]).not_to include("runs=")
      get back[:href].split("#").first
      expect(runs_rows.size).to eq(default_runs)
      expect(page.find("#recent-runs-window")).to have_text("Showing the newest #{default_runs} of 55 runs.")

      get cursor_href
      branch_cell = runs_rows.first.all("td")[1]
      expect(branch_cell.find("a")[:href]).not_to include("runs_before")
    end
  end

  describe "sha links across the page boundary" do
    # SPGD-1940's defect shape, one page over: a row whose sha's NEWEST holder sits on the page
    # BEFORE it. The view's own newest-first walk cannot see that holder — within the page the
    # sha is unique — so only the dashboard's newest-per-sha set gets this row's link right. The
    # fixture builds the duplicate across the boundary on purpose: the older twin is the row a
    # page-local walk would mis-link.
    # @intent: {"entity": "RecentRunsPanel", "action": "address a paged row by run id when its newest holder is on the previous page", "behavior": "on the second page a row whose commit_sha was reported newer on page one has a Read this run href with run=<its id> and no commit_sha=, while a unique-sha sibling keeps its sha link", "layer": "request"}
    it "addresses a paged row by run id when its sha's newest holder is on the previous page" do
      runs = seed_runs(55)
      runs[48].update!(commit_sha: "dupsha1")  # position 49 — page one
      runs[50].update!(commit_sha: "dupsha1")  # position 51 — page two
      expect(runs[50].id).to be > runs[48].id

      get repository_path(repository, runs: max_runs)
      get page.find_link("Older runs")[:href].split("#").first

      paged_row = runs_rows.find { |row| row.text.include?("dupsha1") }
      read_href = paged_row.find("a", exact_text: "Read this run", visible: :all)[:href]
      expect(read_href).to include("run=#{runs[50].id}")
      expect(read_href).not_to include("commit_sha=")

      unique_row = runs_rows.find { |row| row.text.include?("win0051") }
      unique_href = unique_row.find("a", exact_text: "Read this run", visible: :all)[:href]
      expect(unique_href).to include("commit_sha=win0051")
    end
  end

  describe "a runs_before parameter that is not a cursor" do
    [
      ["an array", "runs_before[]=5"],
      ["a nested hash", "runs_before[a]=b"],
      ["an array of hashes", "runs_before[][a]=b"],
      ["a string carrying a NUL", "runs_before=5%006"],
      ["a blank string", "runs_before="],
      ["a non-integer string", "runs_before=abc"],
      ["a plus-signed integer", "runs_before=+5"],
      ["a space-prefixed integer", "runs_before=%205"],
      ["a hex literal", "runs_before=0x10"],
      ["zero", "runs_before=0"],
      ["a negative integer", "runs_before=-3"],
      ["an integer past the bigint ceiling", "runs_before=9223372036854775808"]
    ].each do |shape, query|
      # @intent: {"entity": "RequestedRunsBeforeParam", "action": "treat hostile runs_before as no ask", "behavior": "a runs_before parameter in a non-String shape, carrying a NUL, blank, non-integer, signed, spaced, hex, zero, negative or past the bigint ceiling answers 200 with the default newest window and no cursor bytes on any link", "layer": "request"}
      it "answers 200 with the default window and no cursor bytes when runs_before arrives as #{shape}" do
        seed_runs(25)

        get "#{repository_path(repository)}?#{query}"

        expect(response).to have_http_status(:ok)
        expect(runs_rows.size).to eq(default_runs)
        expect(page.find("#recent-runs-window")).to have_text("Showing the newest #{default_runs} of 25 runs")
        hrefs = page.all("a[href*='commit_sha=']", minimum: 1).map { |a| a[:href] }
        expect(hrefs).to all(satisfy { |href| !href.include?("runs_before") })
      end
    end

    # @intent: {"entity": "RequestedRunsBeforeParam", "action": "answer a dead cursor with the default page", "behavior": "a well-formed runs_before id matching no row of this repository, foreign or deleted, renders the default newest window with no notice and no cursor bytes on any link", "layer": "request"}
    it "answers a well-formed foreign or deleted id with the plain default page" do
      other = create_repository(user: @user, github_full_name: "acme/other")
      foreign_run = create_test_run(repository: other)
      deleted = create_test_run(repository: repository)
      deleted.destroy!
      seed_runs(25)

      get repository_path(repository, runs_before: foreign_run.id)

      expect(runs_rows.size).to eq(default_runs)
      expect(page.find("#recent-runs-window")).to have_text("Showing the newest #{default_runs} of 25 runs")
      expect(page).to have_no_text("run ##{foreign_run.id}")

      get repository_path(repository, runs_before: deleted.id)

      expect(runs_rows.size).to eq(default_runs)
      hrefs = page.all("a[href*='commit_sha=']", minimum: 1).map { |a| a[:href] }
      expect(hrefs).to all(satisfy { |href| !href.include?("runs_before") })
    end
  end

  describe "a cursor at the end of the history" do
    # @intent: {"entity": "RecentRunsPanel", "action": "answer a past-the-end cursor honestly", "behavior": "a cursor naming the repository's oldest run renders the No runs older than that state with a Newest runs way back, never the no-runs-yet wording that would deny the runs above the cursor", "layer": "request"}
    it "renders its own empty state rather than the nothing-has-been-reported one" do
      runs = seed_runs(25)

      get repository_path(repository, runs_before: runs.last.id)

      expect(response).to have_http_status(:ok)
      panel = page.find("#recent-runs")
      expect(panel).to have_text("No runs older than that")
      expect(panel).to have_link("Newest runs")
      expect(panel).to have_no_text("Nothing has been reported")
    end
  end

  describe "query cost" do
    # @intent: {"entity": "RecentRunsPanel", "action": "price the cursor at two statements", "behavior": "a paged page issues exactly two more test_runs statements than the default page - the cursor resolution and the newest-run-per-sha read - and the default page issues no cursor query at all", "layer": "request"}
    it "costs the cursor read and the newest-per-sha read paged, and the default page nothing" do
      runs = seed_runs(55)

      default = queries_against(/FROM "test_runs"/) { get repository_path(repository) }
      paged = queries_against(/FROM "test_runs"/) do
        get repository_path(repository, runs: max_runs, runs_before: runs[49].id)
      end

      # +1 for the cursor resolution (priced only when asked, like the branch total), +1 for the
      # newest-run-per-sha read behind the rows' links (SPGD-1940's argument, one shape over).
      expect(paged.size).to eq(default.size + 2)
      expect(paged.count { |sql| sql.include?("DISTINCT ON") }).to eq(1)
      expect(default.count { |sql| sql.include?("DISTINCT ON") }).to eq(0)
    end
  end
end
