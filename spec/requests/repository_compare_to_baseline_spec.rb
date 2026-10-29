# frozen_string_literal: true

require "rails_helper"

# `?compare_to=<branch>` (SPGD-1981): the explicit, labelled baseline for every run-pair
# "What changed" figure on the console. The default comparison — `Repository#
# previous_test_run_on_branch`, the newest same-branch predecessor — is untouched and stays the
# only baseline any page draws without an ask; this parameter swaps `@previous_test_run` for
# `Repository#baseline_test_run_on_branch`'s row (newest run on the NAMED branch at or before the
# run being read) and every sentence that would have said "the previous run on this branch" names
# the asked branch instead.
#
# What this file guards that the model specs cannot:
#
#   * THE DEAD END ENDS. A PR branch whose CI has reported once has no same-branch predecessor,
#     so this is the first comparison the page can offer such a reader at all — deltas, layers,
#     areas and the two basis notes all read against the asked branch's run.
#   * NO SILENT FALLBACK. A missed ask (no run at or before this one on the named branch) is
#     stated, never substituted away.
#   * BYTE IDENTITY. A same-branch ask is the comparison the default already makes, so it renders
#     byte-for-byte what no parameter renders; so do every malformed shape the guard treats as no
#     ask. The one dead-end page that changes under no ask at all is the one the offer link is
#     FOR — asserted explicitly, not assumed.
#   * THE HONESTY GUARDS TRAVEL. `run_figures` refuses a bad pair on its own terms and the swap
#     happens above it, so a cross-branch pair that is not assembled alike, or timed over
#     different shard counts, is refused with the sentences the same-branch pair has always had.
RSpec.describe "Repository console — ?compare_to= explicit cross-branch baseline", type: :request do
  MAIN_SHA = "main0000000001"
  PR_SHA = "pr00000000000001"

  before { @user = sign_in_via_github }

  def new_repository
    @repository_seq = (@repository_seq || 0) + 1

    create_repository(user: @user, github_full_name: "acme/service-#{@repository_seq}")
  end

  def ingest(repository, commit_sha:, specs:, branch: "main", duration: 60.0, at: nil)
    run = Ingest::RunRecorder.record(
      repository,
      { commit_sha: commit_sha, branch: branch, total_specs_count: specs.size,
        annotated_specs_count: 0, duration_seconds: duration },
      specs: specs.map(&:deep_stringify_keys)
    )
    TestRun.where(id: run.id).update_all(created_at: at) if at
    run
  end

  def area_specs(directory, count, each: 1.0, offset: 0, layer: nil)
    Array.new(count) do |i|
      line = offset + i + 1
      if layer
        annotated_spec(file_path: "#{directory}/a_spec.rb", line_number: line, duration: each,
                       layer: layer, name: "#{layer} example #{offset + i}")
      else
        unannotated_spec(file_path: "#{directory}/a_spec.rb", line_number: line, duration: each)
      end
    end
  end

  # The ticket's headline fixture, in two shapes. MAIN runs are older than the PR run in both;
  # the PR branch has ONE run of its own, so the same-branch predecessor the page falls back to
  # does not exist.
  def first_run_pr_branch(with_layers: false)
    repository = new_repository
    ingest(repository, commit_sha: MAIN_SHA, branch: "main", duration: 90.0, at: 2.hours.ago,
                      specs: area_specs("spec/models", 3) +
                             (with_layers ? area_specs("spec/models", 2, each: 2.0, offset: 50, layer: "unit") : []))
    ingest(repository, commit_sha: PR_SHA, branch: "feature", duration: 510.0, at: 1.minute.ago,
                      specs: area_specs("spec/models", 5, offset: 300) +
                             (with_layers ? area_specs("spec/models", 1, each: 3.0, offset: 350, layer: "unit") : []))
    repository
  end

  def verdict_suite_stat(body)
    Capybara.string(body).all(".rc-stat").find do |stat|
      stat.first(".rc-stat-label")&.text&.squish == "Tests in suite"
    end
  end

  # The sign-in flash is consumed by the first render after it, so any two responses that are
  # about to be compared BYTE FOR BYTE are both taken after one warm-up GET — otherwise the first
  # response carries the "Connected …" banner the second does not, and the comparison fails on a
  # session artefact rather than on the ask.
  def body_of(repository, params = {})
    get repository_path(repository, params: params)
    response.body
  end

  def byte_identical_bodies(repository, with_params:)
    body_of(repository)
    without_ask = body_of(repository)
    with_ask = body_of(repository, with_params)

    expect(with_ask).to eq(without_ask)
  end

  def sha_links_within(scope, sha)
    scope.all("a").select { |a| a.text.squish == sha.first(7) }
  end

  describe "a first run on a PR branch, measured against main by ask" do
    it "reads the suite-size and runtime deltas against main's run and names the ask" do
      repository = first_run_pr_branch

      get repository_path(repository, params: { compare_to: "main" })

      expect(response).to have_http_status(:ok)
      stat = verdict_suite_stat(response.body)
      # 5 examples on the PR run against main's 3 — the delta the default path could never draw.
      expect(stat).to have_text("+2", normalize_ws: true)
      expect(stat).to have_text("vs the newest run on main", normalize_ws: true)
      expect(stat).to have_no_text("no earlier run to compare")

      basis = Capybara.string(response.body).find("#suite-size-basis")
      expect(basis).to have_text("measured against #{MAIN_SHA.first(7)}", normalize_ws: true)
      expect(basis).to have_text("the newest run on main", normalize_ws: true)
      expect(basis).to have_text("a different branch, asked for", normalize_ws: true)
      expect(basis).to have_text("You asked for this comparison with ?compare_to=main", normalize_ws: true)
      expect(sha_links_within(basis, MAIN_SHA).size).to eq(1)

      runtime_basis = Capybara.string(response.body).find("#runtime-basis")
      expect(runtime_basis).to have_text("The total runtime is measured against #{MAIN_SHA.first(7)}",
                                         normalize_ws: true)
      expect(runtime_basis).to have_text("the newest run on main", normalize_ws: true)
    end

    it "reads the runtime delta against main's run in the verdict" do
      repository = first_run_pr_branch

      get repository_path(repository, params: { compare_to: "main" })

      stat = Capybara.string(response.body).all(".rc-stat").find do |candidate|
        candidate.first(".rc-stat-label")&.text&.squish == "Total runtime"
      end
      # 510s against main's 90s — again, a delta the dead-ending default could never show.
      expect(stat).to have_text("+7m", normalize_ws: true)
      expect(stat).to have_text("vs the newest run on main", normalize_ws: true)
    end

    it "names the asked branch in the section header and the layer since-lines" do
      repository = first_run_pr_branch(with_layers: true)

      get repository_path(repository, params: { compare_to: "main" })

      page = Capybara.string(response.body)
      header = page.find("#changes .rc-section-head p")
      expect(header).to have_text("Against the newest run on", normalize_ws: true)
      expect(header).to have_text("a different branch, asked for", normalize_ws: true)

      %w[#layer-run-growth #layer-runtime-growth].each do |id|
        line = page.find(id)
        expect(line).to have_text("Since #{MAIN_SHA.first(7)} on main (asked for):", normalize_ws: true)
        # 2 unit examples on main against 1 on the PR branch.
        expect(line).to have_text("unit −1", normalize_ws: true)
      end

      # The two delta columns' headers and the Recent-runs caption — the short labels that would
      # otherwise still promise a "previous run" the figures are not using.
      expect(page).to have_css("th", text: "Since main")
      expect(page).to have_no_css("th", text: "Since previous run")
      caption = page.find("#recent-runs-basis")
      expect(caption).to have_text("by your ask — against the newest run on main", normalize_ws: true)
    end

    it "names the asked branch in the area panels' captions and row readings" do
      repository = first_run_pr_branch

      get repository_path(repository, params: { compare_to: "main" })

      page = Capybara.string(response.body)
      basis = page.find("#spec-directory-growth-basis")
      expect(basis).to have_text("measured between this run and #{MAIN_SHA.first(7)}", normalize_ws: true)
      expect(basis).to have_text("the newest run on main", normalize_ws: true)
      expect(basis).to have_no_text("the previous run on this branch")

      readings = page.find("#spec-directory-growth").all("td[aria-label]").map { |td| td["aria-label"] }
      # spec/models: 3 examples on main, 5 on the PR branch.
      expect(readings).to include("2 examples more than the newest run on main")

      time_basis = page.find("#spec-directory-runtime-growth-basis")
      expect(time_basis).to have_text("measured between this run and #{MAIN_SHA.first(7)}", normalize_ws: true)
      expect(time_basis).to have_text("the newest run on main", normalize_ws: true)
    end

    it "carries the ask through the page's links" do
      repository = first_run_pr_branch

      get repository_path(repository, params: { compare_to: "main" })

      basis = Capybara.string(response.body).find("#suite-size-basis")
      link = sha_links_within(basis, MAIN_SHA).sole
      expect(link[:href]).to eq(repository_path(repository, commit_sha: MAIN_SHA, anchor: "summary",
                                                compare_to: "main"))
    end
  end

  describe "an ask that cannot be honoured" do
    # No run of `stale` exists at all. The page renders the default same-branch dead end — the
    # sub-captions still say "no earlier run to compare" and no delta names main — and SAYS the
    # ask found nothing, the way @trajectory_branch_request says its fallback happened.
    it "states the miss instead of substituting a branch" do
      repository = first_run_pr_branch

      get repository_path(repository, params: { compare_to: "stale" })

      expect(response).to have_http_status(:ok)
      stat = verdict_suite_stat(response.body)
      expect(stat).to have_text("no earlier run to compare", normalize_ws: true)
      expect(response.body).not_to include("vs the newest run on main")
      expect(response.body).not_to include("the newest run on main")

      basis = Capybara.string(response.body).find("#suite-size-basis")
      expect(basis).to have_text("You asked to compare against stale", normalize_ws: true)
      expect(basis).to have_text("no run from that branch exists at or before this run", normalize_ws: true)
      # ...and the page is still the same-branch dead end, not a cross-branch one in disguise.
      expect(basis).to have_text("No earlier run on feature", normalize_ws: true)
    end

    it "says the miss on a page that still has a same-branch delta to show" do
      repository = new_repository
      ingest(repository, commit_sha: "featold0000001", branch: "feature", duration: 60.0, at: 2.hours.ago,
                        specs: area_specs("spec/models", 3))
      ingest(repository, commit_sha: PR_SHA, branch: "feature", duration: 510.0, at: 1.minute.ago,
                        specs: area_specs("spec/models", 5, offset: 300))

      get repository_path(repository, params: { compare_to: "stale" })

      # The delta that shows is still the same-branch one, under its own name...
      stat = verdict_suite_stat(response.body)
      expect(stat).to have_text("+2", normalize_ws: true)
      expect(stat).to have_text("vs the previous run", normalize_ws: true)
      # ...and the basis note says the cross-branch ask found nothing.
      basis = Capybara.string(response.body).find("#suite-size-basis")
      expect(basis).to have_text("You asked to compare against stale", normalize_ws: true)
      expect(basis).to have_text("this delta is still the same-branch one", normalize_ws: true)
    end
  end

  describe "the dead-end offer" do
    # The offer exists to be pressed from the dead end, which is a NO-PARAM page: the default
    # first-run-on-branch render gains exactly one link, naming the most recently pushed other
    # branch that has a run at or before this one.
    it "offers the cross-branch comparison from the default dead-end page" do
      repository = first_run_pr_branch

      get repository_path(repository)

      basis = Capybara.string(response.body).find("#suite-size-basis")
      expect(basis).to have_text("Runs on other branches are deliberately not compared", normalize_ws: true)
      offer = basis.all("a").find { |a| a.text.squish == "Compare against main" }
      expect(offer).to be_present
      expect(offer[:href]).to eq(repository_path(repository, compare_to: "main", anchor: "summary"))
    end

    it "lands on the offered comparison honoured" do
      repository = first_run_pr_branch

      get repository_path(repository)
      offer = Capybara.string(response.body).find("#suite-size-basis")
                        .all("a").find { |a| a.text.squish == "Compare against main" }
      get offer[:href].split("#").first

      stat = verdict_suite_stat(response.body)
      expect(stat).to have_text("vs the newest run on main", normalize_ws: true)
    end

    # A branch whose only runs are NEWER has no state to measure against, and a link to a refused
    # comparison is a dead end offering a second dead end. The default page anchors on the
    # repository's newest run overall — which is then the newest thing in the table and every
    # other run is at-or-before it — so this state is reached by re-anchoring on the older run,
    # the way a reader bookmarked to one commit arrives.
    it "offers nothing when the asked branch has only runs newer than the anchored run" do
      repository = new_repository
      ingest(repository, commit_sha: PR_SHA, branch: "feature", duration: 60.0, at: 2.hours.ago,
                        specs: area_specs("spec/models", 3))
      ingest(repository, commit_sha: MAIN_SHA, branch: "main", duration: 90.0, at: 1.minute.ago,
                        specs: area_specs("spec/models", 4))

      get repository_path(repository, params: { commit_sha: PR_SHA })

      basis = Capybara.string(response.body).find("#suite-size-basis")
      expect(basis).to have_text("No earlier run on feature", normalize_ws: true)
      expect(basis.all("a").find { |a| a.text.squish.start_with?("Compare against") }).to be_nil
    end

    it "offers nothing when the asked branch is the only branch" do
      repository = new_repository
      ingest(repository, commit_sha: PR_SHA, branch: "feature", duration: 60.0, at: 1.minute.ago,
                        specs: area_specs("spec/models", 3))

      get repository_path(repository)

      expect(Capybara.string(response.body).find("#suite-size-basis").all("a")).to be_empty
    end

    # A page whose ask RESOLVED already shows the comparison the offer exists to reach.
    it "offers nothing once the ask is honoured" do
      repository = first_run_pr_branch

      get repository_path(repository, params: { compare_to: "main" })

      expect(Capybara.string(response.body).find("#suite-size-basis")
        .all("a").find { |a| a.text.squish.start_with?("Compare against") }).to be_nil
    end
  end

  describe "the paths that must not change" do
    # The same-branch ask IS the comparison the default makes, so it renders byte-for-byte what
    # no parameter renders — on a comparable page, where deltas and notes are all up.
    it "renders a same-branch ask byte-for-byte as no ask" do
      repository = new_repository
      ingest(repository, commit_sha: "featold0000001", branch: "feature", duration: 60.0, at: 2.hours.ago,
                        specs: area_specs("spec/models", 3))
      ingest(repository, commit_sha: PR_SHA, branch: "feature", duration: 510.0, at: 1.minute.ago,
                        specs: area_specs("spec/models", 5, offset: 300))

      byte_identical_bodies(repository, with_params: { compare_to: "feature" })
    end

    it "renders a blank ask byte-for-byte as no ask" do
      repository = first_run_pr_branch

      byte_identical_bodies(repository, with_params: { compare_to: "" })
    end

    # The shapes a query string can legally parse into that are NOT a branch name, pinned against
    # the byte-identical default on the same reasoning the malformed-branch shared example pins
    # its surfaces: only the positive path separates a guard from a swallow.
    def expect_compare_to_param_treated_as_no_ask(query)
      repository = first_run_pr_branch

      byte_identical_bodies(repository, with_params: query)
    end

    it_behaves_like "a surface that treats a malformed compare_to parameter as no ask"
  end

  describe "the honesty guards travel with the ask" do
    # The swap happens above `run_figures`, so the guards are the same ones the same-branch pair
    # has always answered to — asserted here once per guard, cross-branch, because a guard that
    # silently passed for same-branch pairs and failed cross-branch ones (or the reverse) would
    # otherwise surface only in production data.
    it "refuses a cross-branch pair assembled differently with the existing sentence" do
      repository = new_repository
      main = ingest(repository, commit_sha: MAIN_SHA, branch: "main", duration: 90.0, at: 2.hours.ago,
                            specs: area_specs("spec/models", 3))
      2.times { |i| main.test_run_shards.create!(shard_id: i.to_s, total_specs_count: 2) }
      ingest(repository, commit_sha: PR_SHA, branch: "feature", duration: 510.0, at: 1.minute.ago,
                        specs: area_specs("spec/models", 5, offset: 300))

      get repository_path(repository, params: { compare_to: "main" })

      stat = verdict_suite_stat(response.body)
      expect(stat).to have_no_text("vs the newest run on main")
      basis = Capybara.string(response.body).find("#suite-size-basis")
      expect(basis).to have_text("not measuring the same thing", normalize_ws: true)
    end

    it "refuses a cross-branch pair timed over different shard counts with the existing sentence" do
      repository = new_repository
      main = ingest(repository, commit_sha: MAIN_SHA, branch: "main", duration: 90.0, at: 2.hours.ago,
                            specs: area_specs("spec/models", 3))
      2.times { |i| main.test_run_shards.create!(shard_id: i.to_s, total_specs_count: 2, duration_seconds: 45.0) }
      pr = ingest(repository, commit_sha: PR_SHA, branch: "feature", duration: 510.0, at: 1.minute.ago,
                          specs: area_specs("spec/models", 5, offset: 300))
      # Same shard count as main (so the suite sizes ARE comparable) and one shard that reported
      # no timing — the timed-count half of the runtime guard.
      pr.test_run_shards.create!(shard_id: "0", total_specs_count: 3, duration_seconds: 510.0)
      pr.test_run_shards.create!(shard_id: "1", total_specs_count: 2)

      get repository_path(repository, params: { compare_to: "main" })

      stat = verdict_suite_stat(response.body)
      # The suite sizes ARE comparable (same shard count) and read against main...
      expect(stat).to have_text("+2", normalize_ws: true)
      expect(stat).to have_text("vs the newest run on main", normalize_ws: true)
      # ...but the wall clocks are not, and the refusal names the denominators.
      runtime_basis = Capybara.string(response.body).find("#runtime-basis")
      expect(runtime_basis).to have_text("measured over different", normalize_ws: true)
      expect(runtime_basis).to have_text("timed 2 of its 2", normalize_ws: true)
    end
  end

  describe "what the ask deliberately does not touch" do
    # The branch-WINDOW pair compares the two ends of a branch's own history and is out of scope:
    # the ask re-points the run pair only. With `?branch=feature` drawing feature's window and
    # `?compare_to=main` re-pointing the run pair, both facts hold on one page.
    it "leaves the window panels on the branch's own history" do
      repository = first_run_pr_branch
      ingest(repository, commit_sha: "featold0000001", branch: "feature", duration: 60.0, at: 2.hours.ago,
                        specs: area_specs("spec/legacy", 3))
      # The window pair needs its newest run to be the page's anchor run, so re-anchor on feature.
      get repository_path(repository, params: { branch: "feature", compare_to: "main" })
      with_ask_window = Capybara.string(response.body).find("#spec-directory-window-growth-basis").text(
        normalize_ws: true
      )

      get repository_path(repository, params: { branch: "feature" })
      without_ask_window = Capybara.string(response.body).find("#spec-directory-window-growth-basis").text(
        normalize_ws: true
      )

      expect(with_ask_window).to eq(without_ask_window)
      # ...while the run pair beside it IS re-pointed.
      expect(response.body).not_to include("vs the newest run on main")
      get repository_path(repository, params: { branch: "feature", compare_to: "main" })
      expect(response.body).to include("vs the newest run on main")
    end
  end
end
