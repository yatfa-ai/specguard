# frozen_string_literal: true

require "rails_helper"

# `?commit_sha=` on repositories#show — the ask that names WHICH RUN the page is anchored on.
#
# The page had no such ask at all. Every run-grain panel on it hung off `@latest_test_run`, which
# was the repository's newest run unconditionally, while the JSON endpoint (SPGD-544) and the MCP
# bridge (SPGD-552) had both been answerable about a named run since they shipped. The bridge states
# the cost of the gap about itself: without a run ask the anchor names the repository's newest run,
# "which may be another branch's, with no error and no signal that you were answered about someone
# else's commit". On the web there was no ask AND no signal.
#
# Its own file rather than more examples in any panel's, for the reason the sibling files state:
# this is not a fact about a panel, it is a fact about WHICH RUN every panel is describing, and the
# examples that matter most are precisely the ones about panels that must NOT follow it.
#
# Runs are written through `Ingest::RunRecorder` rather than inserted by hand wherever a rollup is
# read, because the rollups read `spec_observations` and a hand-built fixture would assert against a
# shape nothing in production writes.
RSpec.describe "Repository run anchor", type: :request do
  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }

  def page = Capybara.string(response.body)

  def panel(id) = page.find("##{id}")

  # Whitespace-collapsed, because every sentence these examples read is assembled across several
  # ERB lines: a phrase that reads as one on the page has a newline in the middle of it in the
  # source, and an assertion against a literal space would pin the indentation rather than the copy.
  def panel_text(id) = panel(id).text.squish

  # `nil` rather than a raise when the page said nothing about its anchor, so the no-ask examples
  # can assert the ABSENCE — which is the whole of what "renders exactly as it did before the
  # parameter existed" means here. `all(...).first` and not Capybara's `first`, which defaults to
  # `minimum: 1` and raises on the very state these examples are asserting.
  def anchor_notice = page.all("#run-anchor-notice").first&.text&.squish

  def ingest_run(commit_sha:, specs:, at: nil, branch: "main")
    run = Ingest::RunRecorder.record(
      repository,
      { commit_sha: commit_sha, branch: branch, total_specs_count: specs.size,
        annotated_specs_count: 0, duration_seconds: 60.0 },
      specs: specs.map(&:deep_stringify_keys)
    )
    run.update!(created_at: at) if at
    run
  end

  def spec_in(path, line) = unannotated_spec(file_path: path, line_number: line, duration: 1.0)

  # TWO runs whose suites do not overlap in any panel, which is what makes "the page followed the
  # ask" observable rather than inferred: the older run's areas, files and examples are absent from
  # the newer one entirely, so a page still anchored on the newest run cannot accidentally satisfy
  # an assertion about the older one.
  #
  # Backdated explicitly rather than relying on insertion order, because two rows written in the
  # same example land microseconds apart and every ordering here — newest run, previous run on the
  # branch, the "Recent runs" list — is by `created_at`.
  def two_run_history
    older = ingest_run(commit_sha: "0lder000cafe0001", at: 3.hours.ago,
                       specs: [spec_in("spec/models/order_spec.rb", 1),
                               spec_in("spec/models/refund_spec.rb", 2),
                               spec_in("spec/models/invoice_spec.rb", 3)])
    newer = ingest_run(commit_sha: "newest00cafe0002", at: 1.hour.ago,
                       specs: [spec_in("spec/requests/checkout_spec.rb", 4)])

    [older, newer]
  end

  describe "a sha the repository has a run for" do
    # Success criterion 1. Named panels rather than a sampling: the ask re-anchors `@latest_test_run`
    # and roughly twenty panels hang off that ivar, so what is being pinned is that the RE-ANCHORING
    # is at the ivar and not at each panel — one of them reading the parameter for itself is exactly
    # how two panels on one page come to name two different commits.
    it "describes the named run in every run-grain panel, not the repository's newest" do
      older, = two_run_history

      get repository_path(repository, commit_sha: older.commit_sha)

      expect(response).to have_http_status(:ok)
      # The Overview's own basis line, which is where the page names the run its figures came from.
      expect(panel_text("overview")).to include("Measured on #{older.commit_sha.first(7)}")
      # The two rollups and the annotation map, each of which ranks rows of ONE run. The newest run
      # holds no `spec/models` row at all, so this cannot pass on a page that ignored the ask.
      expect(panel_text("spec-file-durations")).to include("spec/models/order_spec.rb")
      expect(panel_text("spec-directory-durations")).to include("spec/models")
      expect(panel_text("unannotated-directories")).to include("spec/models")
      # And the per-example worklist, the deepest rung, which is narrowed by a second ask that must
      # compose with this one rather than reset it.
      expect(panel_text("slowest-examples")).to include("spec/models/order_spec.rb")
    end

    # The drill-ins are the panels that would be easiest to leave behind: each one is guarded on its
    # own ask AND on the run, and each takes the run as an argument rather than reading it.
    it "opens a drill-down against the named run rather than against the newest one" do
      older, = two_run_history

      get repository_path(repository, commit_sha: older.commit_sha, spec_directory: "spec/models")

      expect(panel_text("spec-directory-files")).to include("spec/models/refund_spec.rb")
      expect(panel_text("unannotated-examples")).to include("spec/models/refund_spec.rb")
    end

    # Success criterion 3, first half. The resolved ask is disclosed, and it is not decoration: every
    # panel goes on correctly labelling the run it drew, which is exactly how a page pinned to a
    # three-week-old commit reads to a reader who arrived by a link.
    it "says the page is anchored on the run the URL named" do
      older, = two_run_history

      get repository_path(repository, commit_sha: older.commit_sha)

      expect(anchor_notice).to include("anchored on #{older.commit_sha.first(7)}")
      expect(anchor_notice).to include("the run this URL names")
    end
  end

  describe "a sha the repository has no run for" do
    # Success criterion 2. Not a 404 and not an error — a stale bookmark, a pruned run and a commit
    # whose CI never reported are all ordinary ways to arrive here.
    it "falls back to the newest run rather than 404ing" do
      _older, newer = two_run_history

      get repository_path(repository, commit_sha: "deadbeefdeadbeef")

      expect(response).to have_http_status(:ok)
      expect(panel_text("overview")).to include("Measured on #{newer.commit_sha.first(7)}")
    end

    # Success criterion 2, second half, and criterion 3. THE defect this ticket exists to close: the
    # URL names one sha, the page describes another run, and until now nothing anywhere said the ask
    # had not been honoured.
    it "says the fallback happened and which run it is showing instead" do
      _older, newer = two_run_history

      get repository_path(repository, commit_sha: "deadbeefdeadbeef")

      expect(anchor_notice).to include("SpecGuard has no run for deadbeefdeadbeef")
      expect(anchor_notice).to include("anchored on #{newer.commit_sha.first(7)}")
    end

    # Success criterion 3, stated as the property rather than as two separate texts: the two answers
    # to an ask must not be able to render the same page. A guard that dropped the ask silently
    # would satisfy every assertion above about the fallback's FIGURES — they are the newest run's
    # either way — and only this separates "we fell back and said so" from "we ignored you".
    it "does not render a fallback the way it renders a resolved ask" do
      older, = two_run_history

      get repository_path(repository, commit_sha: older.commit_sha)
      resolved = response.body

      get repository_path(repository, commit_sha: "deadbeefdeadbeef")

      expect(response.body).not_to eq(resolved)
      expect(anchor_notice).not_to eq(nil)
    end

    # The repository with no runs at all, which is the one state where the fallback substituted
    # nothing: "anchored on — instead" would name an empty string where a commit should be, and the
    # Overview's empty state below says CI has never reported, which is true and is not what this
    # reader asked.
    it "says so plainly when there is no run to fall back to either" do
      get repository_path(repository, commit_sha: "deadbeefdeadbeef")

      expect(response).to have_http_status(:ok)
      expect(anchor_notice).to include("no run at all on this repository yet")
    end
  end

  describe "no ask at all" do
    # The page as it was. A default call must be byte-identical to the one this page served before
    # the parameter existed — the disclosure is silent, and the anchor is the newest run.
    it "anchors on the newest run and says nothing about anchors" do
      _older, newer = two_run_history

      get repository_path(repository)

      expect(panel_text("overview")).to include("Measured on #{newer.commit_sha.first(7)}")
      expect(anchor_notice).to be_nil
    end

    # `?commit_sha=` is "no ask", not `WHERE commit_sha = ''`. The column is NOT NULL and `TestRun`
    # validates its presence, so a blank matches nothing — and an implementation that queried on it
    # would fall back while the page claimed a request had been made.
    it "reads a blank commit_sha as no ask rather than as an empty query" do
      _older, newer = two_run_history

      get repository_path(repository, commit_sha: "")

      expect(panel_text("overview")).to include("Measured on #{newer.commit_sha.first(7)}")
      expect(anchor_notice).to be_nil
    end
  end

  # Success criterion 2, third part. The three shapes a query string can legally parse into that are
  # not a sha are listed ONCE, in `spec/support/shared_examples/malformed_commit_sha_param.rb`,
  # against the guard they all land on (`RequestedCommitShaParam#requested_commit_sha`) — the same
  # guard the JSON endpoint reads, which is why this surface INCLUDES the module rather than
  # re-deriving it. What is local here is how THIS surface says it dropped the ask.
  #
  # The disclosure is asserted alongside the anchor, and that is the half a bare 200 would miss: a
  # guard that dropped the ask but left the page claiming one would be a page asserting it had
  # honoured a request it ignored.
  describe "a commit-sha parameter that is not a sha" do
    def expect_commit_sha_param_treated_as_no_ask(query)
      _older, newer = two_run_history

      get repository_path(repository, **query)

      expect(response).to have_http_status(:ok)
      expect(panel_text("overview")).to include("Measured on #{newer.commit_sha.first(7)}")
      expect(anchor_notice).to be_nil
    end

    it_behaves_like "a surface that treats a malformed commit-sha parameter as no ask"

    # The positive-path example the shared examples' own doc comment requires to sit beside them: a
    # guard that swallowed EVERY value would answer 200 on all three malformed shapes too, and
    # nothing above separates "the guard rejects non-Strings" from "the parameter does nothing".
    it "honours a commit_sha that IS a string" do
      older, = two_run_history

      get repository_path(repository, commit_sha: older.commit_sha)

      expect(panel_text("overview")).to include("Measured on #{older.commit_sha.first(7)}")
    end
  end

  # Success criterion 5. ⭐ The trap the JSON endpoint hit first and wrote the rule out for, at
  # `Api::V1::RepositoriesController#rejected_ingests`: delivery health is a fact about the
  # repository's DELIVERY STREAM and not about whichever run the reader anchored to. Handing the
  # re-anchored run to `RejectedIngests` compares the newest REFUSAL against an arbitrary pinned
  # OLDER run, so any reader bookmarking an old commit on a perfectly healthy repository is told
  # their deliveries are being refused.
  #
  # The whole point is that this ships green: the panel renders, every figure in it is real, and the
  # verdict over them is inverted. Only an example that anchors on an old run of a HEALTHY repository
  # can see it.
  describe "the delivery-health verdict under an anchor" do
    let(:api_key) { repository.api_keys.create! }

    # Refused between the two accepted runs, and every timestamp set explicitly rather than left to
    # insertion order: the verdict is a strict `>` between two instants, and rows written in one
    # example land microseconds apart.
    def healthy_repository_with_an_older_refusal
      older = ingest_run(commit_sha: "0lder000cafe0001", at: 3.hours.ago,
                         specs: [spec_in("spec/models/order_spec.rb", 1)])

      post "/api/v1/ingest",
           params: { specs: [] }.to_json,
           headers: { "Content-Type" => "application/json",
                      "Authorization" => "Bearer #{api_key.raw_token}" }
      IngestRejection.last.update!(occurred_at: 2.hours.ago)

      ingest_run(commit_sha: "newest00cafe0002", at: 1.hour.ago,
                 specs: [spec_in("spec/requests/checkout_spec.rb", 2)])

      older
    end

    it "does not flip to 'refusing' when the reader anchors on an old run" do
      older = healthy_repository_with_an_older_refusal

      get repository_path(repository, commit_sha: older.commit_sha)

      expect(panel_text("connect")).to include("Connected")
      expect(panel_text("connect")).not_to include("Deliveries refused")
    end

    # The other half, so the example above cannot pass by the verdict having been disabled: the same
    # fixture with the newest accepted run removed IS refusing, and says so under the same anchor.
    it "still reports a genuinely refusing repository under an anchor" do
      older = healthy_repository_with_an_older_refusal
      repository.test_runs.where.not(id: older.id).destroy_all

      get repository_path(repository, commit_sha: older.commit_sha)

      expect(panel_text("connect")).to include("Deliveries refused")
    end
  end

  # Success criterion 6. History is a SERIES and the anchor is a ROW, so neither the "Recent runs"
  # list nor the suite trajectory follows the ask. The identity the page's own wiring comment used to
  # promise unconditionally — the Overview's run is always the top row here — holds on a default call
  # and is NOT expected to hold under an explicit ask; the disclosure and the marked row are what
  # keep the difference from reading as a rendering bug.
  describe "the panels that are histories rather than rows" do
    it "leaves Recent runs newest-first under an anchor on an older run" do
      older, newer = two_run_history

      get repository_path(repository, commit_sha: older.commit_sha)

      shas = panel("recent-runs").all("tbody tr td:first-child").map { |cell| cell.text.strip }
      expect(shas).to eq([newer.commit_sha.first(7), older.commit_sha.first(7)])
    end

    it "marks the anchored row rather than the top one" do
      older, = two_run_history

      get repository_path(repository, commit_sha: older.commit_sha)

      current = panel("recent-runs").all("a[aria-current]").map(&:text)
      expect(current).to eq([older.commit_sha.first(7)])
    end

    it "marks nothing when the reader chose nothing" do
      two_run_history

      get repository_path(repository)

      expect(panel("recent-runs").all("a[aria-current]")).to be_empty
    end

    it "qualifies the caption only where the qualification applies" do
      older, = two_run_history

      get repository_path(repository)
      expect(page.find("#recent-runs-basis").text.squish).not_to include("not necessarily the newest")

      get repository_path(repository, commit_sha: older.commit_sha)
      expect(page.find("#recent-runs-basis").text.squish).to include("not necessarily the newest")
    end

    # The suite trajectory keeps drawing the branch of the repository's NEWEST run, because
    # `?commit_sha=` says nothing about which series to draw — that ask is `?branch=`, and this panel
    # is built around it. Asserted through the branch fallback notice, which is the panel's own
    # statement of which branch it settled on: anchoring on a run of another branch must not move it.
    it "does not move the suite trajectory onto the anchored run's branch" do
      older = ingest_run(commit_sha: "0lder000cafe0001", at: 3.hours.ago, branch: "feature/x",
                         specs: [spec_in("spec/models/order_spec.rb", 1)])
      ingest_run(commit_sha: "newest00cafe0002", at: 1.hour.ago, branch: "main",
                 specs: [spec_in("spec/requests/checkout_spec.rb", 2)])

      get repository_path(repository, commit_sha: older.commit_sha)

      expect(panel_text("suite-trajectory")).to include("on main")
      expect(panel_text("suite-trajectory")).not_to include("on feature/x")
    end
  end

  # Success criterion 8. The two surfaces answer the same question about the same sha and must not
  # be able to disagree about which run they picked — the web resolves through
  # `Repository#latest_test_run_for_commit` and the JSON endpoint through the same method behind its
  # own memo, and this is what says so from the outside rather than by reading both implementations.
  #
  # Worth pinning at a sha that resolves AND at one that does not, because the two surfaces disclose
  # the fallback in different vocabularies and the failure would be for one of them to 404, or to
  # resolve to a different row, where the other fell back.
  describe "cross-surface parity with the JSON endpoint" do
    let(:api_key) { repository.api_keys.create! }

    def api_run_anchor(sha)
      get "/api/v1/repository", params: { commit_sha: sha },
                                headers: { "Authorization" => "Bearer #{api_key.raw_token}" }

      response.parsed_body["run_anchor"]
    end

    it "names the same run as the API's run_anchor for a sha that resolves" do
      older, = two_run_history

      anchor = api_run_anchor(older.commit_sha)
      get repository_path(repository, commit_sha: older.commit_sha)

      expect(anchor).to include("resolved" => true, "commit_sha" => older.commit_sha)
      expect(panel_text("overview")).to include("Measured on #{anchor["commit_sha"].first(7)}")
    end

    it "falls back to the same run as the API's run_anchor for a sha that does not" do
      two_run_history

      anchor = api_run_anchor("deadbeefdeadbeef")
      get repository_path(repository, commit_sha: "deadbeefdeadbeef")

      expect(anchor).to include("resolved" => false, "requested_commit_sha" => "deadbeefdeadbeef")
      expect(panel_text("overview")).to include("Measured on #{anchor["commit_sha"].first(7)}")
      expect(anchor_notice).to include("anchored on #{anchor["commit_sha"].first(7)}")
    end
  end

  # Success criterion 9. The commit cells became links and the panel stays outside the `manage_keys`
  # gate, which is two claims and they are checked separately: a `view` member sees the panel, and
  # the link is a NAVIGATION rather than a control — it re-reads the same telemetry under a different
  # anchor, behind the same `:view` authorization as the page it re-renders. The `rendered_controls`
  # matrix in spec/requests/repository_sharing_spec.rb is where controls are pinned, and this must
  # not enter it.
  it "offers the run anchor to a view-only member, and the anchor answers them" do
    older, = two_run_history
    member = sign_in_via_github(uid: "9999", info: { nickname: "hubot" })
    create_membership(repository: repository, user: member)

    get repository_path(repository, commit_sha: older.commit_sha)

    expect(response).to have_http_status(:ok)
    expect(panel("recent-runs").all("a").map(&:text)).to include(older.commit_sha.first(7))
    expect(panel_text("overview")).to include("Measured on #{older.commit_sha.first(7)}")
  end
end
