# frozen_string_literal: true

require "rails_helper"

# The "Rejected deliveries" panel on repositories#show, and the connection indicator it corrects.
#
# Its own file, for the reason the sibling panel specs state for themselves: the Overview/API-keys
# file is edited by other slices, and every example here needs the same refused-delivery fixture.
#
# The rows are written by the real path — a POST that authenticates and is then refused — rather
# than inserted by hand, because the defect this panel exists for is precisely an ORDERING one
# (`authenticate_api_key!` stamps the key before the payload is looked at). A hand-built
# `IngestRejection` would skip the stamp, and every example about the stat would then be asserting
# against a state the production path cannot produce.
RSpec.describe "Repository rejected deliveries", type: :request do
  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }
  let(:api_key) { repository.api_keys.create! }

  # A delivery that authenticates and is refused for its payload: no `commit_sha`.
  def refuse_a_delivery(user_agent: "specguard-rspec/0.3.1")
    post "/api/v1/ingest",
         params: { specs: [] }.to_json,
         headers: { "Content-Type" => "application/json",
                    "User-Agent" => user_agent,
                    "Authorization" => "Bearer #{api_key.raw_token}" }
  end

  def accept_a_delivery
    post "/api/v1/ingest",
         params: ingest_payload.to_json,
         headers: { "Content-Type" => "application/json",
                    "Authorization" => "Bearer #{api_key.raw_token}" }
  end

  # A delivery refused at the RACK BOUNDARY rather than by the controller: the body claims gzip and
  # is not gzip, so `GzipRequestBody` answers its own 400 and `IngestsController#create` never runs.
  # This is the family the panel could not see at all until the boundary seam existed.
  def refuse_a_delivery_at_the_boundary(user_agent: "specguard-rspec/0.3.1")
    post "/api/v1/ingest",
         params: "this is not gzip at all",
         headers: { "Content-Type" => "application/json",
                    "Content-Encoding" => "gzip",
                    "User-Agent" => user_agent,
                    "Authorization" => "Bearer #{api_key.raw_token}" }
  end

  def visit_repository = get repository_path(repository)

  def panel = Capybara.string(response.body).find("#rejected-ingests")
  def connect_panel = Capybara.string(response.body).find("#connection-indicator")

  # Whitespace-collapsed, because every sentence these examples read is assembled across several
  # ERB lines: a phrase that reads as one on the page is a phrase with a newline in the middle in
  # the source, and an assertion against a literal space would pin the indentation rather than the
  # copy.
  def panel_text = panel.text.squish
  def connect_text = connect_panel.text.squish

  describe "when deliveries have been refused" do
    before do
      refuse_a_delivery
      visit_repository
    end

    # Success criterion 5.
    # @intent: {"entity": "IngestRejection", "action": "list refusal with time", "behavior": "the panel renders the refused delivery's row with a relative timestamp ending in ago", "layer": "request"}
    it "lists the refusal with when it happened" do
      expect(panel).to have_text("ago")
    end

    # @intent: {"entity": "IngestRejection", "action": "quote refusal reason", "behavior": "the panel text includes the refusal's first detail string exactly as IngestRejection.last recorded it", "layer": "request"}
    it "names the reason verbatim, as the endpoint gave it" do
      expect(panel_text).to include(IngestRejection.last.details.first)
    end

    # @intent: {"entity": "IngestRejection", "action": "name reporting client", "behavior": "the panel includes the reporting client string specguard-rspec/0.3.1, the column that makes a version floor diagnosable", "layer": "request"}
    it "names the client that reported, which is what makes a version floor diagnosable" do
      expect(panel_text).to include("specguard-rspec/0.3.1")
    end

    # The honesty bound: the panel must not imply it can see failed AUTHENTICATIONS, because a 401
    # resolves no repository and writes no row.
    # @intent: {"entity": "IngestRejection", "action": "disclose 401 blind spot", "behavior": "the panel text mentions 401, telling the reader an empty panel is not evidence that no request was rejected for its key", "layer": "request"}
    it "says an empty panel is not evidence that no request was rejected for its key" do
      expect(panel_text).to include("401")
    end

    # It is not a retry queue, and the copy has to say so.
    # @intent: {"entity": "IngestRejection", "action": "disclaim recovery", "behavior": "the panel copy matches not stored, saying the refused runs cannot be recovered here", "layer": "request"}
    it "says the refused runs were not stored and cannot be recovered here" do
      expect(panel_text).to match(/not stored/i)
    end

    # Success criterion 7 — the defect itself. Before this, exactly here, the page said
    # "Connected" in success tone over a pipeline throwing every run away.
    describe "the connection indicator" do
      # @intent: {"entity": "IngestRejection", "action": "refuse success tone", "behavior": "over a pipeline refusing every payload delivery the connection indicator no longer reads Connected", "layer": "request"}
      it "does not read Connected" do
        expect(connect_text).not_to include("Connected")
      end

      # @intent: {"entity": "IngestRejection", "action": "announce refusals", "behavior": "the connection indicator reads Deliveries refused", "layer": "request"}
      it "reports that deliveries are being refused" do
        expect(connect_text).to include("Deliveries refused")
      end

      # @intent: {"entity": "IngestRejection", "action": "avoid success styling", "behavior": "the connection indicator renders without the text-app-success class", "layer": "request"}
      it "does not render in the success tone" do
        expect(connect_panel).to have_no_css(".text-app-success")
      end
    end
  end

  # The rule in `RejectedIngests#refusing?`: the verdict is an ORDERING between two recorded facts,
  # not a window in hours. A repository that hit a bad payload and has ingested cleanly since is
  # healthy again, with no threshold to pick and nothing to expire.
  describe "when a refusal was followed by an accepted run" do
    before do
      refuse_a_delivery
      accept_a_delivery
      visit_repository
    end

    # @intent: {"entity": "IngestRejection", "action": "recover after acceptance", "behavior": "once an accepted delivery follows the refusal the indicator reads Connected again with no mention of Deliveries refused", "layer": "request"}
    it "reads Connected again" do
      expect(connect_text).to include("Connected")
      expect(connect_text).not_to include("Deliveries refused")
    end

    # The refusal still happened, and the panel is a history rather than a live alarm — so the row
    # stays listed even though the stat has recovered. The two are answering different questions.
    # @intent: {"entity": "IngestRejection", "action": "keep refusal history", "behavior": "the earlier refusal stays listed in the panel with its client string even though the indicator has recovered", "layer": "request"}
    it "still lists the refusal that happened" do
      expect(panel_text).to include("specguard-rspec/0.3.1")
    end
  end

  describe "when an accepted run was followed by a refusal" do
    before do
      accept_a_delivery
      refuse_a_delivery
      visit_repository
    end

    # @intent: {"entity": "IngestRejection", "action": "report latest refusal", "behavior": "when the last completed delivery was the refused one the indicator reads Deliveries refused and not Connected", "layer": "request"}
    it "reports the refusal, because the last delivery to complete was thrown away" do
      expect(connect_text).to include("Deliveries refused")
      expect(connect_text).not_to include("Connected")
    end
  end

  # Success criterion 5's second half.
  describe "when nothing has ever been refused" do
    before do
      accept_a_delivery
      visit_repository
    end

    # @intent: {"entity": "IngestRejection", "action": "render empty state", "behavior": "with nothing ever refused the panel still renders, reading No rejected deliveries", "layer": "request"}
    it "still renders the panel, with an empty state" do
      expect(panel_text).to include("No rejected deliveries")
    end

    # Scoped to what the table can actually see. An empty state claiming "everything is fine" would
    # replace the false Connected this slice removed with a quieter false claim of its own.
    # @intent: {"entity": "IngestRejection", "action": "scope empty-state claim", "behavior": "the empty state matches refused for its payload, scoping its good news to the payload family the table can see", "layer": "request"}
    it "scopes the good news to the payload family it can see" do
      expect(panel_text).to match(/refused for its payload/i)
    end

    # @intent: {"entity": "IngestRejection", "action": "keep connected reading", "behavior": "the connection indicator still reads Connected when nothing was refused", "layer": "request"}
    it "leaves the connection indicator reading Connected" do
      expect(connect_text).to include("Connected")
    end
  end

  # WHAT USED TO BE HERE, and why its removal is a deliverable rather than a loss of coverage.
  #
  # Four examples pinned the Connect panel's prose explanation of what records a use: that a 401
  # records none, that a 400 does, and that a rotated key reads "not used since rotation" rather
  # than "never". Every sentence of it was true and every sentence of it was a manual, one panel
  # above the table it was describing — this file's own subject, "Rejected deliveries", which lists
  # each refusal with its reason and its time.
  #
  # SPGD-705 removed the prose and kept the behaviour. The distinctions it taught the reader to
  # derive are now surfaced directly instead of explained: the refusing state is its own branch of
  # the connection indicator (pinned above, and it is what the 401-vs-400 sentence existed to let a
  # reader work out for themselves), and the rotated state is its own branch too, pinned in
  # spec/requests/repositories_spec.rb with the copy that names the rotation and the remedy. So the
  # examples are deleted rather than rewritten: there is no prose left for them to assert against,
  # and the states they protected are asserted structurally somewhere better.

  # The claim the page's query budget in spec/requests/repositories_spec.rb makes on this panel's
  # behalf: it is ONE read, and it stays one read as the list fills up. An absolute count there
  # cannot tell a structural N+1 from an ordinary widening, so the guard is the equality across two
  # very different row counts — the shape the sibling panels' guards use.
  #
  # `queries_against` rather than a page budget, so this counts reads of THIS table and is
  # unaffected by any panel added beside it later.
  describe "what the panel costs" do
    # @intent: {"entity": "IngestRejection", "action": "read table once", "behavior": "the panel reads ingest_rejections exactly once whether one refusal or a full window beyond the panel limit is recorded", "layer": "request"}
    it "reads the table once, whether there is one refusal or a full window of them" do
      refuse_a_delivery
      one = queries_against("ingest_rejections") { visit_repository }

      (IngestRejection::PANEL_LIMIT + 2).times { refuse_a_delivery }
      many = queries_against("ingest_rejections") { visit_repository }

      expect(one.size).to eq(1)
      expect(many.size).to eq(one.size)
    end

    # And the page really did render the rows being counted — an equality above is satisfied by a
    # panel that renders nothing at all.
    # @intent: {"entity": "IngestRejection", "action": "render capped window", "behavior": "after more refusals than the limit the table renders exactly IngestRejection::PANEL_LIMIT rows", "layer": "request"}
    it "renders the capped window it read" do
      (IngestRejection::PANEL_LIMIT + 2).times { refuse_a_delivery }
      visit_repository

      expect(panel.all("tbody tr").size).to eq(IngestRejection::PANEL_LIMIT)
    end
  end

  # Whether the panel's basis line calls what it is showing "a recent window rather than the whole
  # history" — a claim about the POPULATION, and one it may only make when the panel's limit really
  # did leave a refusal off the page.
  #
  # The absent-sentence example is the defect. `RejectedIngests#bounded?` read
  # `rows.size >= PANEL_LIMIT`, and a full page is not evidence of a cut one: a repository refused
  # exactly ten times — its whole history, five times inside `REPOSITORY_RETENTION_ROWS` — was told
  # it was looking at a window. The present-sentence example is here because an absence assertion
  # alone is satisfied by a matcher that never matches anything.
  describe "the disclosure that the list is a window" do
    # @intent: {"entity": "IngestRejection", "action": "disclose window cut", "behavior": "when the limit really left a refusal off the page the table shows its capped rows and the panel text says recent window rather than the whole history", "layer": "request"}
    it "says so when the panel's limit really did leave a refusal off the page" do
      (IngestRejection::PANEL_LIMIT + 1).times { refuse_a_delivery }
      visit_repository

      expect(panel.all("tbody tr").size).to eq(IngestRejection::PANEL_LIMIT)
      expect(panel_text).to match(/recent window rather than the whole history/i)
    end

    # @intent: {"entity": "IngestRejection", "action": "deny window at exact fit", "behavior": "a history of exactly the panel limit refusals fills the page without the recent-window claim appearing", "layer": "request"}
    it "does not call a complete history a window when it fills the page exactly" do
      IngestRejection::PANEL_LIMIT.times { refuse_a_delivery }
      visit_repository

      expect(panel.all("tbody tr").size).to eq(IngestRejection::PANEL_LIMIT)
      expect(panel_text).not_to match(/recent window rather than the whole history/i)
    end
  end

  # The DOM this panel puts on the page is bounded by the RULE, not by what the client sent.
  #
  # This is the fence the first round did not have, and its absence is instructive: every example
  # in this file refused with `{ specs: [] }`, which produces exactly one reason, so `reasons.each`
  # had never rendered more than a single `<li>`. `Ingest::Payload` emits one error per invalid
  # spec, and the refusal this panel exists for — a version floor, an envelope skew — refuses EVERY
  # spec in the suite. The panel rendered fine on the fixture and would have collapsed on the case
  # it was designed for.
  #
  # Note what is measured. The query-count guard below is true and blind here: one query can return
  # twenty-five megabytes, so a count is the wrong instrument for a volume claim and these examples
  # count ELEMENTS and BYTES instead.
  describe "the size of what the panel renders" do
    # 30 malformed specs × 4 objections = 120 reasons in one delivery — the shape of a whole suite
    # refused at once, at a size an example can run. `file_path` is interpolated into every message,
    # so passing a long one is how an example reaches the OTHER axis of the bound. `user_agent`
    # defaults to the value every other example here relies on, and is a parameter so the worst-case
    # example can drive the row's second client-controlled column too.
    def refuse_a_large_delivery(specs: 30, file_path: nil, user_agent: "specguard-rspec/0.3.1")
      spec = file_path ? { file_path: file_path } : {}

      post "/api/v1/ingest",
           params: { commit_sha: "a" * 40, specs: Array.new(specs) { spec } }.to_json,
           headers: { "Content-Type" => "application/json",
                      "User-Agent" => user_agent,
                      "Authorization" => "Bearer #{api_key.raw_token}" }
    end

    # @intent: {"entity": "IngestRejection", "action": "cap reasons per delivery", "behavior": "a delivery refused with 120 reasons renders only IngestRejection::RETAINED_REASONS_PER_ROW list items", "layer": "request"}
    it "caps the reasons listed for one delivery" do
      refuse_a_large_delivery
      visit_repository

      expect(IngestRejection.last.total_reasons_count).to eq(120)
      expect(panel.all("li").size).to eq(IngestRejection::RETAINED_REASONS_PER_ROW)
    end

    # The cap is disclosed rather than quietly applied, and the number it discloses IS the
    # diagnosis: "and 100 more" says the whole suite was refused, which is a different fix from one
    # malformed spec.
    # @intent: {"entity": "IngestRejection", "action": "count hidden reasons", "behavior": "the row says and 100 more, disclosing how many reasons the per-delivery cap is hiding", "layer": "request"}
    it "says how many reasons it is not showing" do
      refuse_a_large_delivery
      visit_repository

      expect(panel_text).to include("and 100 more")
    end

    # @intent: {"entity": "IngestRejection", "action": "explain per-delivery cap", "behavior": "the basis line says at most the retained-reasons count are kept per delivery", "layer": "request"}
    it "explains the per-delivery cap in the panel's basis line" do
      refuse_a_large_delivery
      visit_repository

      expect(panel_text).to match(/at most #{IngestRejection::RETAINED_REASONS_PER_ROW} are kept per delivery/i)
    end

    # The invariance that makes this a bound rather than a smaller number: a suite seven times the
    # size renders exactly the same DOM. Without it, "20 `<li>`" could just be what this fixture
    # happens to produce.
    # @intent: {"entity": "IngestRejection", "action": "bound DOM across suite size", "behavior": "a suite of 200 malformed specs totalling 800 reasons renders the same retained-reasons count of list items as the 30-spec fixture's 120", "layer": "request"}
    it "renders the same DOM for a much larger suite" do
      refuse_a_large_delivery(specs: 200)
      visit_repository

      expect(IngestRejection.last.total_reasons_count).to eq(800)
      expect(panel.all("li").size).to eq(IngestRejection::RETAINED_REASONS_PER_ROW)
    end

    # Every bound at once — a full retained window, every row a whole suite refused, every reason
    # long enough to be cut by the length half, and every row's `user_agent` pathological too —
    # asserted in BYTES, because element counts do not catch a single enormous reason and the length
    # bound exists for exactly that. The header is driven here because the panel renders
    # `reported_client` verbatim once per row: without it this ceiling holds only because the
    # fixture happens to send a well-behaved client string.
    # @intent: {"entity": "IngestRejection", "action": "hold worst-case byte ceiling", "behavior": "a full window of whole-suite refusals with 5,000-character file paths and 100,000-character user agents keeps every stored reason within the length cap, renders the capped rows and list items, and holds the panel html under 200,000 bytes", "layer": "request"}
    it "keeps the whole panel under a stated ceiling in the worst case it exists for" do
      (IngestRejection::PANEL_LIMIT + 2).times do
        refuse_a_large_delivery(file_path: "x" * 5_000, user_agent: "u" * 100_000)
      end
      visit_repository

      expect(IngestRejection.last.details).to all(satisfy { |r| r.length <= IngestRejection::MAX_REASON_LENGTH })
      expect(panel.all("tbody tr").size).to eq(IngestRejection::PANEL_LIMIT)
      expect(panel.all("li").size)
        .to eq(IngestRejection::PANEL_LIMIT * IngestRejection::RETAINED_REASONS_PER_ROW)
      expect(panel.native.to_html.bytesize).to be < 200_000
    end
  end

  # Success criterion 6 — the observable end-to-end proof that a refusal decided ABOVE the
  # controller reaches the surfaces, not merely the table.
  #
  # This is the whole point of the seam rather than a restatement of the examples above. The row is
  # written by a middleware that answers its own 400 and never calls the app, so before it existed
  # this repository's page rendered "No rejected deliveries" — a positive claim, and a false one —
  # over a pipeline having every delivery thrown away. Both surfaces already read `RejectedIngests`,
  # so nothing here is new rendering: what is new is that there is now a row for them to read.
  describe "when the refusal was decided at the Rack boundary" do
    before { refuse_a_delivery_at_the_boundary }

    describe "on the repository page" do
      before { visit_repository }

      # @intent: {"entity": "IngestRejection", "action": "report boundary refusal", "behavior": "a delivery refused at the Rack boundary over a lying gzip header still turns the repository page's connection indicator to Deliveries refused", "layer": "request"}
      it "reports that deliveries are being refused" do
        expect(connect_text).to include("Deliveries refused")
      end

      # The exact falsehood this ticket removes.
      # @intent: {"entity": "IngestRejection", "action": "withdraw empty-state claim", "behavior": "the boundary-refused repository's page no longer claims No rejected deliveries", "layer": "request"}
      it "no longer claims there are no rejected deliveries" do
        expect(panel_text).not_to include("No rejected deliveries")
      end

      # Stored in the middleware's own words, never re-worded into a verdict — the same rule the
      # controller path is held to.
      # @intent: {"entity": "IngestRejection", "action": "quote middleware reason", "behavior": "the panel includes GzipRequestBody::CORRUPT_MESSAGE verbatim rather than a re-worded verdict", "layer": "request"}
      it "names the reason the middleware gave, verbatim" do
        expect(panel_text).to include(GzipRequestBody::CORRUPT_MESSAGE)
      end

      # The column that makes a VERSION FLOOR diagnosable, on the path where it matters most: a gem
      # gzipping at an installation older than `GzipRequestBody` is refused exactly here.
      # @intent: {"entity": "IngestRejection", "action": "name boundary client", "behavior": "the panel names the reporting client specguard-rspec/0.3.1 on the boundary path where an old gem version bites", "layer": "request"}
      it "names the client that reported" do
        expect(panel_text).to include("specguard-rspec/0.3.1")
      end
    end

    # The card grid reads the same verdict through a different query, so it is asserted separately
    # rather than assumed to follow from `show`.
    # @intent: {"entity": "IngestRejection", "action": "mark card grid", "behavior": "the repositories index body includes Deliveries refused and does not show the No runs yet placeholder for this repository", "layer": "request"}
    it "shows the refusal marker on the repositories card grid" do
      get repositories_path

      expect(response.body).to include("Deliveries refused")
      # The never-wired reading of a nil run, which this repository is NOT: deliveries are arriving
      # and being destroyed.
      expect(response.body).not_to include("No runs yet")
    end
  end

  # A repository the viewer can see but does not own reads the same panel — it is delivery
  # telemetry, not a credential surface, and it names no key.
  describe "a member who does not own the repository" do
    let(:owner) { create_user(github_uid: "3003", github_handle: "hubot") }
    let(:repository) { create_repository(user: owner, github_full_name: "acme/shared-service") }

    before do
      create_membership(repository: repository, user: @user)
      refuse_a_delivery
      visit_repository
    end

    # @intent: {"entity": "IngestRejection", "action": "share with non-owner member", "behavior": "a member who does not own the repository still sees the refusal listed with its client string", "layer": "request"}
    it "sees the refusals" do
      expect(panel_text).to include("specguard-rspec/0.3.1")
    end
  end
end
