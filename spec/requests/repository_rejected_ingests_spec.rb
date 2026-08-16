# frozen_string_literal: true

require "rails_helper"

# The "Rejected deliveries" panel on repositories#show, and the "Connection" stat it corrects.
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

  def visit_repository = get repository_path(repository)

  def panel = Capybara.string(response.body).find("#rejected-ingests")
  def connect_panel = Capybara.string(response.body).find("#connect")

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
    it "lists the refusal with when it happened" do
      expect(panel).to have_text("ago")
    end

    it "names the reason verbatim, as the endpoint gave it" do
      expect(panel_text).to include(IngestRejection.last.details.first)
    end

    it "names the client that reported, which is what makes a version floor diagnosable" do
      expect(panel_text).to include("specguard-rspec/0.3.1")
    end

    # The honesty bound: the panel must not imply it can see failed AUTHENTICATIONS, because a 401
    # resolves no repository and writes no row.
    it "says an empty panel is not evidence that no request was rejected for its key" do
      expect(panel_text).to include("401")
    end

    # It is not a retry queue, and the copy has to say so.
    it "says the refused runs were not stored and cannot be recovered here" do
      expect(panel_text).to match(/not stored/i)
    end

    # Success criterion 7 — the defect itself. Before this, exactly here, the page said
    # "Connected" in success tone over a pipeline throwing every run away.
    describe "the Connection stat" do
      it "does not read Connected" do
        expect(connect_text).not_to include("Connected")
      end

      it "reports that deliveries are being refused" do
        expect(connect_text).to include("Deliveries refused")
      end

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

    it "reads Connected again" do
      expect(connect_text).to include("Connected")
      expect(connect_text).not_to include("Deliveries refused")
    end

    # The refusal still happened, and the panel is a history rather than a live alarm — so the row
    # stays listed even though the stat has recovered. The two are answering different questions.
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

    it "still renders the panel, with an empty state" do
      expect(panel_text).to include("No rejected deliveries")
    end

    # Scoped to what the table can actually see. An empty state claiming "everything is fine" would
    # replace the false Connected this slice removed with a quieter false claim of its own.
    it "scopes the good news to the payload family it can see" do
      expect(panel_text).to match(/refused for its payload/i)
    end

    it "leaves the Connection stat reading Connected" do
      expect(connect_text).to include("Connected")
    end
  end

  # Success criterion 8. The old sentence was true for 401 and false for 400; the correction has to
  # keep the first half true rather than drop the distinction.
  describe "the Connect panel's explanation of what records a use" do
    before do
      refuse_a_delivery
      visit_repository
    end

    it "no longer claims a rejected request never records a use" do
      expect(connect_text).not_to match(/never records a use/i)
    end

    it "still says a 401 records no use" do
      expect(connect_text).to match(/401.*records no use at all/im)
    end

    it "says a 400 does record one, so a recent use is not proof a run was stored" do
      expect(connect_text).to match(/does.*record a use/im)
      expect(connect_text).to include("400")
    end
  end

  # The claim the page's query budget in spec/requests/repositories_spec.rb makes on this panel's
  # behalf: it is ONE read, and it stays one read as the list fills up. An absolute count there
  # cannot tell a structural N+1 from an ordinary widening, so the guard is the equality across two
  # very different row counts — the shape the sibling panels' guards use.
  #
  # `queries_against` rather than a page budget, so this counts reads of THIS table and is
  # unaffected by any panel added beside it later.
  describe "what the panel costs" do
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
    it "renders the capped window it read" do
      (IngestRejection::PANEL_LIMIT + 2).times { refuse_a_delivery }
      visit_repository

      expect(panel.all("tbody tr").size).to eq(IngestRejection::PANEL_LIMIT)
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

    it "caps the reasons listed for one delivery" do
      refuse_a_large_delivery
      visit_repository

      expect(IngestRejection.last.total_reasons_count).to eq(120)
      expect(panel.all("li").size).to eq(IngestRejection::RETAINED_REASONS_PER_ROW)
    end

    # The cap is disclosed rather than quietly applied, and the number it discloses IS the
    # diagnosis: "and 100 more" says the whole suite was refused, which is a different fix from one
    # malformed spec.
    it "says how many reasons it is not showing" do
      refuse_a_large_delivery
      visit_repository

      expect(panel_text).to include("and 100 more")
    end

    it "explains the per-delivery cap in the panel's basis line" do
      refuse_a_large_delivery
      visit_repository

      expect(panel_text).to match(/at most #{IngestRejection::RETAINED_REASONS_PER_ROW} are kept per delivery/i)
    end

    # The invariance that makes this a bound rather than a smaller number: a suite seven times the
    # size renders exactly the same DOM. Without it, "20 `<li>`" could just be what this fixture
    # happens to produce.
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

    it "sees the refusals" do
      expect(panel_text).to include("specguard-rspec/0.3.1")
    end
  end
end
