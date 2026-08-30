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

  # The "Recent runs" caption, which is the page's SECOND statement about the anchor and the one
  # that has to agree with the marking below it rather than with the raw ask.
  def recent_runs_caption = page.find("#recent-runs-basis").text.squish

  # The rows carrying `aria-current`, BY POSITION in the list. Positions rather than link text,
  # because the case that matters most is two runs of one commit — where every candidate row prints
  # the same seven characters and only the position separates the row the ask resolved to from the
  # row that merely shares its sha.
  def marked_row_positions
    panel("recent-runs").all("tbody tr").each_with_index
                        .select { |row, _| row.all("a[aria-current]").any? }.map(&:last)
  end


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
    # @intent: {"entity": "TestRun", "action": "re-anchor run-grain panels", "behavior": "with commit_sha naming the older run the Overview reads Measured on its 7-char sha and the file-duration, directory, unannotated and slowest-example panels list the older run's spec/models rows the newest run never held", "layer": "request"}
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
    # @intent: {"entity": "TestRun", "action": "drill into anchored run", "behavior": "commit_sha composed with spec_directory renders refund_spec.rb rows in the spec-directory-files and unannotated-examples drill-downs of the older run", "layer": "request"}
    it "opens a drill-down against the named run rather than against the newest one" do
      older, = two_run_history

      get repository_path(repository, commit_sha: older.commit_sha, spec_directory: "spec/models")

      expect(panel_text("spec-directory-files")).to include("spec/models/refund_spec.rb")
      expect(panel_text("unannotated-examples")).to include("spec/models/refund_spec.rb")
    end

    # Success criterion 3, first half. The resolved ask is disclosed, and it is not decoration: every
    # panel goes on correctly labelling the run it drew, which is exactly how a page pinned to a
    # three-week-old commit reads to a reader who arrived by a link.
    # @intent: {"entity": "TestRun", "action": "disclose resolved anchor", "behavior": "the anchor notice says the page is anchored on the named run's 7-char sha and that it is the run this URL names", "layer": "request"}
    it "says the page is anchored on the run the URL named" do
      older, = two_run_history

      get repository_path(repository, commit_sha: older.commit_sha)

      expect(anchor_notice).to include("anchored on #{older.commit_sha.first(7)}")
      expect(anchor_notice).to include("the run this URL names")
    end
  end

  # ⭐ THE WAY BACK OUT, which the ask shipped without. Entering the anchor costs one click from any
  # commit cell in "Recent runs"; leaving it cost URL surgery, because nothing on the page emitted
  # `commit_sha: nil` and `drill_down_path` carries the ask by default — so once anchored, every
  # subsequent drill-in, close and area link re-emitted it. The three sibling asks each shipped with
  # a clearing gesture ("Close file", "Close directory", "Close description") and this one is the
  # fourth, on the same rule: it names the one ask it clears and every other one rides through.
  #
  # Read off the RENDERED HREF rather than by constructing the expected URL here, because the failure
  # this guards against is precisely a link built by omission — a `drill_down_path` call that leaves
  # `commit_sha` out instead of passing an explicit nil produces a button that navigates to the page
  # it is already on, and an expectation written from the same belief would agree with it.
  describe "the gesture that clears the anchor" do
    def un_anchor_gesture = panel("overview").all("a", text: "Show the newest run").first

    def asks_in(href) = Rack::Utils.parse_nested_query(URI.parse(href).query)

    # The fragment is the button's landing anchor and is not part of the path a request spec issues;
    # `get` would read `#overview` as the last characters of the slug.
    def follow(href)
      uri = URI.parse(href)
      get [uri.path, uri.query].compact.join("?")
    end

    # @intent: {"entity": "TestRun", "action": "offer un-anchor gesture", "behavior": "the Overview's Show the newest run link is present and its href query carries no commit_sha key", "layer": "request"}
    it "offers a gesture whose href drops the anchor" do
      older, = two_run_history

      get repository_path(repository, commit_sha: older.commit_sha)

      expect(un_anchor_gesture).not_to be_nil
      expect(asks_in(un_anchor_gesture[:href])).not_to have_key("commit_sha")
    end

    # Success criterion, first half: ONE CLICK returns the page to the newest run. All three of the
    # page's statements about the anchor go with it — the Overview disclosure, and the "Recent runs"
    # marking, which is computed off `@run_anchor_run` and so clears for free with the ask.
    # @intent: {"entity": "TestRun", "action": "return to newest run", "behavior": "following the gesture answers 200 with the Overview measuring the newest run's sha, no anchor notice and no marked Recent-runs row", "layer": "request"}
    it "returns the page to the newest run when followed" do
      older, newer = two_run_history

      get repository_path(repository, commit_sha: older.commit_sha)
      follow(un_anchor_gesture[:href])

      expect(response).to have_http_status(:ok)
      expect(panel_text("overview")).to include("Measured on #{newer.commit_sha.first(7)}")
      expect(anchor_notice).to be_nil
      expect(marked_row_positions).to be_empty
    end

    # Success criterion, second half. Un-anchoring is not a request to close an open area, file or
    # description, nor to drop `?branch=` — the same invariant "Close file" and "Close directory"
    # keep about each other. The four asks name rows of the NEWEST run, so the page this lands on can
    # actually hold them open and the drill-down panel below is observable rather than inferred.
    #
    # The OWNER of that invariant is spec/requests/repository_drill_down_carry_spec.rb, where this
    # gesture has a row and its cells are checked by construction against every ask at once. This
    # example is not that check and does not replace it: it is written by the same hand that wrote the
    # href, which is exactly the reading a per-feature assertion cannot give — a future edit that
    # dropped a SIBLING'S ask is the failure the matrix exists for, and it would keep this green. What
    # this adds is the FOLLOW: the ask survives the href and the panel it names is still open on the
    # page the click lands on, which the matrix (an href-level spec) does not look at.
    # @intent: {"entity": "TestRun", "action": "keep sibling asks open", "behavior": "the un-anchor href retains branch, spec_directory, spec_file and repeated_description and the landed page still shows the spec-file-examples panel for checkout_spec.rb", "layer": "request"}
    it "keeps every other ask open" do
      older, = two_run_history
      open_asks = { branch: "main",
                    spec_directory: "spec/requests",
                    spec_file: "spec/requests/checkout_spec.rb",
                    repeated_description: "User is valid with a handle" }

      get repository_path(repository, commit_sha: older.commit_sha, **open_asks)
      href = un_anchor_gesture[:href]

      expect(asks_in(href)).to eq(open_asks.transform_keys(&:to_s))

      follow(href)

      expect(panel_text("spec-file-examples")).to include("spec/requests/checkout_spec.rb")
    end

    # ⭐ The gate that is easy to get wrong, because the disclosure this button sits beside renders on
    # BOTH branches. When `?commit_sha=` named no run the page is ALREADY showing the newest run, so
    # a button gated on the ask rather than on the resolved run would navigate the reader to the page
    # they are on — the precise no-op `drill_down_path`'s comment exists to make impossible.
    #
    # The fallback disclosure is asserted alongside the absence, so this cannot pass on a page that
    # simply failed to render the whole block.
    # @intent: {"entity": "TestRun", "action": "hide gesture on fallback", "behavior": "where the sha names no run the notice says SpecGuard has no run for it and the Show the newest run gesture is absent", "layer": "request"}
    it "is absent where the ask fell back, which is already showing the newest run" do
      two_run_history

      get repository_path(repository, commit_sha: "deadbeefdeadbeef")

      expect(anchor_notice).to include("SpecGuard has no run for deadbeefdeadbeef")
      expect(un_anchor_gesture).to be_nil
    end

    # And on the ordinary page, where there is no state to leave and no sentence to answer.
    # @intent: {"entity": "TestRun", "action": "hide gesture without ask", "behavior": "on a default page with no commit_sha parameter the un-anchor gesture does not render", "layer": "request"}
    it "is absent when the reader asked for no anchor at all" do
      two_run_history

      get repository_path(repository)

      expect(un_anchor_gesture).to be_nil
    end
  end

  describe "a sha the repository has no run for" do
    # Success criterion 2. Not a 404 and not an error — a stale bookmark, a pruned run and a commit
    # whose CI never reported are all ordinary ways to arrive here.
    # @intent: {"entity": "TestRun", "action": "fall back to newest", "behavior": "an unknown sha answers 200 rather than 404 and the Overview measures the newest run's sha", "layer": "request"}
    it "falls back to the newest run rather than 404ing" do
      _older, newer = two_run_history

      get repository_path(repository, commit_sha: "deadbeefdeadbeef")

      expect(response).to have_http_status(:ok)
      expect(panel_text("overview")).to include("Measured on #{newer.commit_sha.first(7)}")
    end

    # Success criterion 2, second half, and criterion 3. THE defect this ticket exists to close: the
    # URL names one sha, the page describes another run, and until now nothing anywhere said the ask
    # had not been honoured.
    # @intent: {"entity": "TestRun", "action": "disclose fallback run", "behavior": "the notice names the unmatched sha and says the page is anchored on the newest run's 7-char sha instead", "layer": "request"}
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
    # @intent: {"entity": "TestRun", "action": "distinguish fallback rendering", "behavior": "the body for an unresolved sha differs from the resolved-ask body and carries a non-nil anchor notice", "layer": "request"}
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
    # @intent: {"entity": "TestRun", "action": "disclose empty repository", "behavior": "on a repository with no runs at all the anchor notice says there is no run at all on this repository yet", "layer": "request"}
    it "says so plainly when there is no run to fall back to either" do
      get repository_path(repository, commit_sha: "deadbeefdeadbeef")

      expect(response).to have_http_status(:ok)
      expect(anchor_notice).to include("no run at all on this repository yet")
    end

    # ⭐ The page's SECOND statement about the anchor must not make its first one a liar. Gated on
    # the RAW ASK, the "Recent runs" caption claimed "this page is anchored on a run the URL named,
    # so the marked row here is the one every panel above describes" on the very page whose Overview
    # had just said SpecGuard has no run for that sha — two panels flatly contradicting each other,
    # one of them sending the reader to a marked row that a fallback never renders. Silence here is
    # the answer rather than a third wording: the Overview disclosed the substitution, and this panel
    # has no marking to explain.
    # @intent: {"entity": "TestRun", "action": "silence caption on fallback", "behavior": "the Recent runs caption never says anchored and no row is marked when the ask fell back", "layer": "request"}
    it "says nothing in the Recent runs caption, which has no marked row to explain" do
      two_run_history

      get repository_path(repository, commit_sha: "deadbeefdeadbeef")

      expect(recent_runs_caption).not_to include("anchored")
      expect(marked_row_positions).to be_empty
    end

    # The echoed sha is the one unvalidated value this page prints back, and it reaches the reader
    # escaped EXACTLY ONCE. `truncate` defaults to escaping its input and returning a `SafeBuffer`;
    # interpolating that into a plain String yields a String that is not itself safe but already
    # holds escaped text, and ERB escapes it again — so `?commit_sha=a%26b` printed `a&amp;b` at the
    # reader. It errs safe rather than dangerous, which is exactly why it survived being read: the
    # page was never unsafe, it was just wrong about a value it was quoting back.
    #
    # Both halves asserted, because the fix moved an escape: the sha renders as the reader typed it
    # AND the raw body carries no live markup.
    # @intent: {"entity": "TestRun", "action": "echo sha escaped once", "behavior": "a sha containing an ampersand and script markup is echoed once as typed in the notice while the raw body carries no live script markup", "layer": "request"}
    it "echoes an unvalidated sha escaped exactly once, and never as markup" do
      two_run_history

      get repository_path(repository, commit_sha: "a&b<script>x</script>")

      expect(anchor_notice).to include("SpecGuard has no run for a&b<script>x</script>")
      expect(response.body).not_to include("<script>x</script>")
    end
  end


  describe "no ask at all" do
    # The page as it was. A default call must be byte-identical to the one this page served before
    # the parameter existed — the disclosure is silent, and the anchor is the newest run.
    # @intent: {"entity": "TestRun", "action": "default to newest run", "behavior": "without the parameter the Overview measures the newest run's sha and no anchor notice renders", "layer": "request"}
    it "anchors on the newest run and says nothing about anchors" do
      _older, newer = two_run_history

      get repository_path(repository)

      expect(panel_text("overview")).to include("Measured on #{newer.commit_sha.first(7)}")
      expect(anchor_notice).to be_nil
    end

    # `?commit_sha=` is "no ask", not `WHERE commit_sha = ''`. The column is NOT NULL and `TestRun`
    # validates its presence, so a blank matches nothing — and an implementation that queried on it
    # would fall back while the page claimed a request had been made.
    # @intent: {"entity": "TestRun", "action": "treat blank as no ask", "behavior": "an empty commit_sha renders the newest-run page with no anchor notice rather than querying for an empty sha", "layer": "request"}
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
    # @intent: {"entity": "TestRun", "action": "honour string commit sha", "behavior": "a commit_sha that is a plain string re-anchors the Overview onto that run's 7-char sha", "layer": "request"}
    it "honours a commit_sha that IS a string" do
      older, = two_run_history

      get repository_path(repository, commit_sha: older.commit_sha)

      expect(panel_text("overview")).to include("Measured on #{older.commit_sha.first(7)}")
    end
  end

  # Success criterion 5. ⭐ The trap the JSON endpoint hit first and wrote the rule out for, at
  # `RepositoryOverview#rejected_ingests`: delivery health is a fact about the
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

    # @intent: {"entity": "TestRun", "action": "keep delivery verdict stable", "behavior": "anchoring on an older run of a healthy repository keeps the connection indicator saying Connected and never Deliveries refused", "layer": "request"}
    it "does not flip to 'refusing' when the reader anchors on an old run" do
      older = healthy_repository_with_an_older_refusal

      get repository_path(repository, commit_sha: older.commit_sha)

      expect(panel_text("connection-indicator")).to include("Connected")
      expect(panel_text("connection-indicator")).not_to include("Deliveries refused")
    end

    # The other half, so the example above cannot pass by the verdict having been disabled: the same
    # fixture with the newest accepted run removed IS refusing, and says so under the same anchor.
    # @intent: {"entity": "TestRun", "action": "report refusing repository", "behavior": "with the newest accepted run removed the same anchor renders Deliveries refused in the connection indicator", "layer": "request"}
    it "still reports a genuinely refusing repository under an anchor" do
      older = healthy_repository_with_an_older_refusal
      repository.test_runs.where.not(id: older.id).destroy_all

      get repository_path(repository, commit_sha: older.commit_sha)

      expect(panel_text("connection-indicator")).to include("Deliveries refused")
    end
  end

  # Success criterion 6. History is a SERIES and the anchor is a ROW, so neither the "Recent runs"
  # list nor the suite trajectory follows the ask. The identity the page's own wiring comment used to
  # promise unconditionally — the Overview's run is always the top row here — holds on a default call
  # and is NOT expected to hold under an explicit ask; the disclosure and the marked row are what
  # keep the difference from reading as a rendering bug.
  describe "the panels that are histories rather than rows" do
    # @intent: {"entity": "TestRun", "action": "keep runs list newest first", "behavior": "under an anchor on the older run Recent runs still lists the newer sha above the older one", "layer": "request"}
    it "leaves Recent runs newest-first under an anchor on an older run" do
      older, newer = two_run_history

      get repository_path(repository, commit_sha: older.commit_sha)

      shas = panel("recent-runs").all("tbody tr td:first-child").map { |cell| cell.text.strip }
      expect(shas).to eq([newer.commit_sha.first(7), older.commit_sha.first(7)])
    end

    # @intent: {"entity": "TestRun", "action": "mark anchored row", "behavior": "the only aria-current link in Recent runs is the anchored older run's 7-char sha", "layer": "request"}
    it "marks the anchored row rather than the top one" do
      older, = two_run_history

      get repository_path(repository, commit_sha: older.commit_sha)

      current = panel("recent-runs").all("a[aria-current]").map(&:text)
      expect(current).to eq([older.commit_sha.first(7)])
    end

    # @intent: {"entity": "TestRun", "action": "mark nothing by default", "behavior": "a default page renders no aria-current rows in Recent runs", "layer": "request"}
    it "marks nothing when the reader chose nothing" do
      two_run_history

      get repository_path(repository)

      expect(panel("recent-runs").all("a[aria-current]")).to be_empty
    end

    # ⭐ The rule the view argues for at length and nothing was checking: the mark is matched on the
    # ROW and never on the sha. `test_runs` has no uniqueness constraint on `commit_sha` — a CI
    # re-run of one commit is a second row — so `latest_test_run_for_commit` resolves an ask to
    # exactly one of them while a sha comparison would mark both, and the page would show two
    # "current" rows for a reader who is on one.
    #
    # Asserted by POSITION, which is the only thing that separates them: both rows print the same
    # seven characters. Newest-first, so the re-run is row 1 and the run it re-ran is row 2, and the
    # ask resolves to the newer of the two.
    # @intent: {"entity": "TestRun", "action": "mark one of duplicates", "behavior": "two runs sharing one sha plus a newer run yield exactly one marked row, at position 1 \u2014 the newer re-run", "layer": "request"}
    it "marks one row when two runs share a commit" do
      ingest_run(commit_sha: "0nesha00cafe0001", at: 3.hours.ago,
                 specs: [spec_in("spec/models/order_spec.rb", 1)])
      ingest_run(commit_sha: "0nesha00cafe0001", at: 2.hours.ago,
                 specs: [spec_in("spec/models/order_spec.rb", 1)])
      ingest_run(commit_sha: "newest00cafe0002", at: 1.hour.ago,
                 specs: [spec_in("spec/requests/checkout_spec.rb", 2)])

      get repository_path(repository, commit_sha: "0nesha00cafe0001")

      expect(marked_row_positions).to eq([1])
    end

    # @intent: {"entity": "TestRun", "action": "qualify caption conditionally", "behavior": "the Recent runs caption gains not necessarily the newest only under an explicit anchor and never on a default page", "layer": "request"}
    it "qualifies the caption only where the qualification applies" do
      older, = two_run_history

      get repository_path(repository)
      expect(recent_runs_caption).not_to include("not necessarily the newest")

      get repository_path(repository, commit_sha: older.commit_sha)
      expect(recent_runs_caption).to include("not necessarily the newest")
    end

    # The suite trajectory keeps drawing the branch of the repository's NEWEST run, because
    # `?commit_sha=` says nothing about which series to draw — that ask is `?branch=`, and this panel
    # is built around it. Asserted through the branch fallback notice, which is the panel's own
    # statement of which branch it settled on: anchoring on a run of another branch must not move it.
    # @intent: {"entity": "TestRun", "action": "hold trajectory branch", "behavior": "anchoring on a feature-branch run leaves the suite trajectory drawing main, not feature/x", "layer": "request"}
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

  # ⭐ The state the controller's own wiring comment names — the anchored run "from behind its bound
  # entirely" — and the one the caption promised a marked row for. `Repository#recent_test_runs` is
  # capped at ten rows, so a resolved ask on an older run renders a page where every panel above is
  # correctly re-anchored and NOTHING in this list is marked. A caption gated on the raw ask sends
  # that reader hunting for a mark that was never rendered, which is the least useful sentence the
  # page could give them and the one they used to get.
  describe "an anchored run behind the Recent runs bound" do
    # Eleven runs, and the ask names the eldest. Backdated explicitly rather than left to insertion
    # order, because the bound is applied to an ordering by `created_at` and eleven rows written in
    # one example land microseconds apart.
    def eleven_run_history
      eldest = ingest_run(commit_sha: "0ldest00cafe0001", at: 11.hours.ago,
                          specs: [spec_in("spec/models/order_spec.rb", 1)])
      10.times do |i|
        ingest_run(commit_sha: format("newer%02dcafe00001", i), at: (10 - i).hours.ago,
                   specs: [spec_in("spec/requests/checkout_spec.rb", 4)])
      end

      eldest
    end

    # The ask IS honoured — this is not a fallback — and the panel simply cannot show it.
    # @intent: {"entity": "TestRun", "action": "anchor beyond list bound", "behavior": "asking for the eldest of eleven runs re-anchors the Overview while Recent runs keeps its 10 rows and marks none", "layer": "request"}
    it "anchors every panel on the named run and marks no row" do
      eldest = eleven_run_history

      get repository_path(repository, commit_sha: eldest.commit_sha)

      expect(panel_text("overview")).to include("Measured on #{eldest.commit_sha.first(7)}")
      expect(panel("recent-runs").all("tbody tr").size).to eq(10)
      expect(marked_row_positions).to be_empty
    end

    # The caption for that reader: which run holds the page, and that it is not one of these rows.
    # Both halves matter — dropping the sentence entirely would leave them reading ten unmarked rows
    # under a page anchored somewhere else, with the Overview's disclosure the only clue.
    # @intent: {"entity": "TestRun", "action": "say anchor off-list", "behavior": "the caption names the anchored sha, says it is not among the most recent runs listed here and never promises a marked row", "layer": "request"}
    it "says the anchored run is not among the rows rather than promising a marked one" do
      eldest = eleven_run_history

      get repository_path(repository, commit_sha: eldest.commit_sha)

      expect(recent_runs_caption).to include("anchored on #{eldest.commit_sha.first(7)}")
      expect(recent_runs_caption).to include("not among the most recent runs listed here")
      expect(recent_runs_caption).not_to include("the marked row here")
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

    # @intent: {"entity": "TestRun", "action": "match api resolved anchor", "behavior": "the API reports run_anchor resolved true with the older sha and the page Overview measures that same run", "layer": "request"}
    it "names the same run as the API's run_anchor for a sha that resolves" do
      older, = two_run_history

      anchor = api_run_anchor(older.commit_sha)
      get repository_path(repository, commit_sha: older.commit_sha)

      expect(anchor).to include("resolved" => true, "commit_sha" => older.commit_sha)
      expect(panel_text("overview")).to include("Measured on #{anchor["commit_sha"].first(7)}")
    end

    # @intent: {"entity": "TestRun", "action": "match api fallback anchor", "behavior": "for an unresolvable sha the API reports resolved false with the requested sha and the web page measures and discloses the same fallback run", "layer": "request"}
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
  # @intent: {"entity": "TestRun", "action": "serve anchor to viewer", "behavior": "a view-only member gets 200, sees the older run linked in Recent runs and the Overview measuring that run", "layer": "request"}
  it "offers the run anchor to a view-only member, and the anchor answers them" do
    older, = two_run_history
    member = sign_in_via_github(uid: "9999", info: { nickname: "hubot" })
    create_membership(repository: repository, user: member)

    get repository_path(repository, commit_sha: older.commit_sha)

    expect(response).to have_http_status(:ok)
    expect(panel("recent-runs").all("a").map(&:text)).to include(older.commit_sha.first(7))
    expect(panel_text("overview")).to include("Measured on #{older.commit_sha.first(7)}")
  end

  # ⭐ SPGD-816. The page's half of the retention disclosure. It belongs in THIS file rather than in
  # any panel's for the reason stated at the top: this is not a fact about the Overview panel, it is
  # a fact about the RUN every panel is describing — and `?commit_sha=` is how a reader reaches a run
  # far enough back for it to be true. `RequestedCommitShaParam` names "a pruned run" among the
  # ordinary ways to arrive here.
  #
  # The sentence is asserted by its own id (`#observations-aged-out`) AND by its wording, because
  # the two can fail apart: an element that renders in the wrong state is a false claim, and the
  # right state with the wrong words ("these rows have been deleted") is a false claim too — and
  # that second one is wrong on exactly the population `Ingest::QuietBucketPruner` exists for.
  describe "a run whose per-example observations have aged out" do
    # `api_key` and the anchor read are declared locally rather than reached for, exactly as the
    # delivery-health and parity blocks above declare their own: they are siblings, so nothing
    # leaks between them.
    let(:api_key) { repository.api_keys.create! }

    def api_run_anchor(sha)
      get "/api/v1/repository", params: { commit_sha: sha },
                                headers: { "Authorization" => "Bearer #{api_key.raw_token}" }

      response.parsed_body["run_anchor"]
    end

    def aged_out_notice = page.all("#observations-aged-out").first&.text&.squish

    # ⚠️ A FLAT CLAIM OF EMPTINESS — the assertion the copy must never make, expressed as the CLAIM
    # rather than as a list of words to avoid.
    #
    # The distinction this regex draws is the whole correctness argument of the sentence, so it is
    # worth stating precisely. "...the panels below HAVE NOTHING LEFT to read" asserts a row count.
    # "...may have LITTLE OR NOTHING LEFT to show" asserts the rule and hedges the rows. Both
    # contain the word "nothing", which is why a guard written against vocabulary either lets the
    # false sentence through (the original `/deleted|removed/` guard did exactly that) or fails the
    # true one. What separates them is whether the emptiness is asserted FLATLY, so that is what is
    # matched: `have nothing left` and not `have little or nothing left`.
    def flat_emptiness_claim
      /(have|has) nothing left|nothing to (read|show)|(are|is) empty|deleted|removed|no longer exist/i
    end

    # `BRANCH_RETENTION_RUNS` runs plus one, so the oldest is strictly past its branch's boundary —
    # the pruner's own strict `<`. Stubbed rather than ingesting sixty runs, and the stub is what
    # keeps this example about the RULE rather than about a number.
    def history_past_the_boundary
      stub_const("SpecObservation::BRANCH_RETENTION_RUNS", 3)
      start = 6.hours.ago
      oldest = ingest_run(commit_sha: "0ldest00cafe0001", at: start,
                          specs: [spec_in("spec/models/order_spec.rb", 1)])
      newer = (0...3).map do |i|
        ingest_run(commit_sha: "newer00cafe000#{i}", at: start + ((i + 1) * 30).minutes,
                   specs: [spec_in("spec/requests/checkout_spec.rb", i + 2)])
      end

      [oldest, newer.last]
    end

    # @intent: {"entity": "TestRun", "action": "disclose retention aging", "behavior": "a past-boundary anchored run gets a notice saying aged out of the retention window of its branch's most recent runs, hedged as may have little or nothing left to show, with no flat emptiness claim and the Overview still Measured on its sha", "layer": "request"}
    it "says so on the anchored run, and says it as retention rather than as an empty suite" do
      oldest, = history_past_the_boundary

      get repository_path(repository, commit_sha: oldest.commit_sha)

      expect(response).to have_http_status(:ok)
      expect(aged_out_notice).to include("aged out of the retention window")
      # The bound is named, so a reader can place the run against the rule rather than reading a
      # bare "aged out" — the same reason the endpoint publishes `retention_runs`. Per BRANCH, and
      # the wording has to say so: the constant is a per-branch bound and a sentence implying a
      # repository-wide one would misdescribe the rule.
      expect(aged_out_notice).to include("most recent runs of its branch")
      # ⚠️ The CLAIM that must not appear, which is a different assertion from a list of words to
      # avoid. A vocabulary guard pins spellings and lets the claim through in a synonym: the first
      # version of this sentence said the panels below "have nothing left to read", which asserts
      # a row count exactly as "deleted" does and sailed straight through a /deleted|removed/ check.
      # So the guard is written against the ASSERTION — any flat claim that there is nothing there —
      # rather than against the vocabulary that happened to carry it once.
      #
      # `QuietBucketPruner` is opportunistic and names its own PERMANENTLY unreachable remainder, so
      # a past-boundary run may still physically hold rows; the example below renders that state and
      # is the one that makes this guard mean something rather than merely read well.
      expect(aged_out_notice).not_to match(flat_emptiness_claim)
      # And what it must say INSTEAD: hedged over both states, because both are real. A run whose
      # rows a prune has emptied and a run holding the remainder get the same sentence, and it is
      # true of each.
      expect(aged_out_notice).to include("may have little or nothing left to show")
      # And it does not walk back the counts the run's own row still supports. This is the
      # conflation the whole ticket is about: the run measured a suite and still says so.
      expect(panel_text("overview")).to include("Measured on #{oldest.commit_sha.first(7)}")
    end

    # ⭐⭐ THE POPULATION THE SENTENCE IS MOST EASILY WRONG ABOUT, and until this example existed it
    # was rendered nowhere in the suite.
    #
    # Every other example in this block builds its history through `ingest_run`, which invokes
    # `Ingest::ObservationPruner` on the ingesting branch and really does empty the older runs' rows.
    # So the fixture could only ever produce the DRAINED case — and a sentence claiming the panels
    # below are empty is true of the drained case, which is precisely why the first version of this
    # copy shipped saying exactly that and no example objected.
    #
    # `Ingest::QuietBucketPruner:47-57` names the other case and names it as PERMANENT — "out of
    # reach PERMANENTLY, not until it grows". A merged `feature/*` branch that never ingests again
    # sits past its boundary holding its rows, and nothing is coming to delete them. That is a
    # steady state, so the page has to be true on it, not eventually true.
    #
    # Built DIRECTLY rather than through `ingest_run` for that exact reason: ingest would prune the
    # state under test out of existence. This is the deliberate exception to the file's header rule
    # — the rows are written in the shape `Ingest::ObservationRecorder` writes (see
    # `spec/models/slowest_tests_spec.rb`), and `spec/models/test_run_spec.rb:512` builds runs the
    # same way for the same reason.
    # @intent: {"entity": "TestRun", "action": "avoid false emptiness claim", "behavior": "a past-boundary run still holding one observation renders the slowest-examples panel while the aged-out notice stays hedged and makes no flat claim of emptiness", "layer": "request"}
    it "does not tell the reader the panels are empty while a panel is rendering rows" do
      stub_const("SpecObservation::BRANCH_RETENTION_RUNS", 3)
      # A quiet bucket: four runs on a branch that has stopped ingesting, so the oldest is strictly
      # past the boundary. Nothing prunes it, because nothing ingests here again.
      quiet = (0...4).map do |index|
        create_test_run(repository: repository, branch: "feature/checkout", total_specs_count: 1,
                        commit_sha: "quiet00cafe000#{index}", created_at: (10 - index).hours.ago)
      end
      # The OLDEST of the four, which is the one strictly past a boundary of 3. `quiet.first` is
      # backdated furthest (`(10 - index).hours.ago` counts DOWN toward the present, so index 0 is
      # the eldest) — taking `.last` here picks the newest run and asserts nothing.
      stranded = quiet.first
      # The remainder: the past-boundary run STILL HOLDS its row. This is the assertion the drained
      # fixture cannot make, and the whole point of the example.
      stranded.spec_observations.create!(
        repository: repository, file_path: "spec/models/order_spec.rb",
        spec_file_path: "spec/models/order_spec.rb", line_number: 1, name: "Order totals the lines",
        duration_seconds: 12.5, outcome: "passed", status: "unannotated",
        example_id: "./spec/models/order_spec.rb[1:1]"
      )

      expect(stranded.observations_retained?).to be(false)
      expect(stranded.spec_observations.count).to eq(1)

      get repository_path(repository, commit_sha: stranded.commit_sha)

      expect(response).to have_http_status(:ok)
      # The disclosure still appears — the RULE no longer covers this run, which is true however
      # many rows happen to survive. The predicate is not what is under test here; the copy is.
      expect(aged_out_notice).to include("aged out of the retention window")
      # ⛔ THE SELF-CONTRADICTION. The panel below is rendering a populated ranking, so any flat
      # claim of emptiness above it is a false sentence sitting directly on top of its own
      # counter-example. This is the assertion the vocabulary guard could not make.
      expect(panel_text("slowest-examples")).to include("slowest test of the run named above")
      expect(aged_out_notice).not_to match(flat_emptiness_claim)
      # Hedged, and therefore true in BOTH states rather than in the one the other fixtures build.
      expect(aged_out_notice).to include("may have little or nothing left to show")
    end

    # The other side of the branch, and the half that makes the example above mean anything: the
    # sentence is absent on a run inside the window. An element that renders unconditionally would
    # satisfy every assertion above.
    # @intent: {"entity": "TestRun", "action": "stay silent inside window", "behavior": "anchoring on the newest run inside the retention window renders no aged-out notice at all", "layer": "request"}
    it "says nothing at all on a run still inside the retention window" do
      _oldest, newest = history_past_the_boundary

      get repository_path(repository, commit_sha: newest.commit_sha)

      expect(aged_out_notice).to be_nil
    end

    # A default (unparameterised) page on an ordinary repository is untouched — no repository is
    # near the real bound, and the sentence must not appear on one that is not.
    # @intent: {"entity": "TestRun", "action": "stay silent by default", "behavior": "a default page on an ordinary repository renders no aged-out notice while the real bound exceeds its two runs", "layer": "request"}
    it "says nothing on a default page at the real retention bound" do
      two_run_history

      get repository_path(repository)

      expect(SpecObservation::BRANCH_RETENTION_RUNS).to be > 2
      expect(aged_out_notice).to be_nil
    end

    # ⭐ The page and the endpoint read the SAME predicate, so they cannot disagree about a run —
    # the property the ticket asks for, asserted as an agreement rather than as two separate
    # renderings that happen to match today.
    # @intent: {"entity": "TestRun", "action": "agree with api retention", "behavior": "the API reports observations_retained false for the oldest run and true for the newest, and the page shows the notice exactly on the run where it is false", "layer": "request"}
    it "agrees with the API's run_anchor about whether the run's observations are retained" do
      oldest, newest = history_past_the_boundary

      expect(api_run_anchor(oldest.commit_sha)).to include("observations_retained" => false)
      expect(api_run_anchor(newest.commit_sha)).to include("observations_retained" => true)

      get repository_path(repository, commit_sha: oldest.commit_sha)
      expect(aged_out_notice).to be_present

      get repository_path(repository, commit_sha: newest.commit_sha)
      expect(aged_out_notice).to be_nil
    end
  end
end
