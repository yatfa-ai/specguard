# frozen_string_literal: true

require "rails_helper"

# The verdict card's "needs you" half on repositories#show — `.rc-verdict-lead`'s title, dot and
# attention list. The card's right half (the three suite figures) is pinned from
# spec/requests/repositories_spec.rb; this file exists because the left half answers a different
# question — "does anything need a person?" — and no example anywhere reached it: six conditional
# items, a title built from them (`Nothing needs you` / `N thing(s) need(s) you`), a dot tone
# derived from the items (`err` beats `warn` beats `ok`), and one `Open →` link per item. The
# conditions themselves are tested one layer down by their own producers' specs; what only these
# examples can pin is the verdict card's decision to SURFACE each one, the figure it names, the
# section it sends the reader to, and the tone it assigns.
#
# Its own file, for the same reason the sibling panel specs took theirs: the Overview file is
# edited by sibling slices, and every example here needs the same run-fixture scaffolding.
RSpec.describe "Repository verdict attention list", type: :request do
  before { @user = sign_in_via_github }

  # The card's left half, and nothing else on the page — the title, its dot and the list. Scoping
  # here rather than to the whole card keeps a figure that moves between halves from satisfying a
  # claim about the attention list, and keeps the right half's own assertions from drifting here.
  def lead = Capybara.string(response.body).find("#summary .rc-verdict-lead")

  def title = lead.find(".rc-verdict-title")

  def title_text = title.text.gsub(/\s+/, " ").strip

  # The tone token off the title's own dot — the `err`/`warn`/`ok` word the template derives from
  # the items, read as the one class that carries it.
  def title_dot = title.first(".rc-dot")[:class].split.grep(/\Arc-dot-/).first

  # Whether the list rendered at all: "Nothing needs you" must mean NO list, not an empty one.
  def attn?
    lead.has_css?(".rc-attn")
  end

  # One item as a reader meets it: the tone of its dot, the figure-and-sentence body, and the
  # section the `Open →` link targets. Whitespace-collapsed, because the count and the sentence
  # are assembled across two ERB tags.
  def attn_items
    lead.all(".rc-attn li").map do |li|
      link = li.find("a")
      _dot, body, = link.all("span")
      { dot: link.first(".rc-dot")[:class].split.grep(/\Arc-dot-/).first,
        text: body.text.gsub(/\s+/, " ").strip, href: link[:href] }
    end
  end

  # --- fixtures -------------------------------------------------------------------------------

  # One example on the wire. `name:` is passed at every call site: whether a description DERIVES
  # (the `Entity#action behavior` shape) or reads as unreadable is read off it at render time, so
  # the names below are load-bearing fixtures, not labels.
  def example_spec(name:, outcome: "passed", duration: 1.0, line_number: 1,
                   file_path: "spec/models/user_spec.rb")
    unannotated_spec(file_path: file_path, line_number: line_number, duration: duration,
                     outcome: outcome, name: name)
  end

  # One ingested run, through the producer. Resolution is opt-in because only the unstable item
  # groups on the durable identity; the other fixtures never read it and do not pay for it.
  # `at:` backdates the run the way spec/requests/repository_unstable_tests_spec.rb's fixture
  # does, so a multi-run window orders the way CI produced it.
  def ingest(repository, specs, commit_sha: "feedfacecafe0001", at: nil, resolve: false)
    run = Ingest::RunRecorder.record(
      repository,
      { commit_sha: commit_sha, branch: "main", total_specs_count: specs.size,
        annotated_specs_count: 0, duration_seconds: 60.0 },
      specs: specs.map(&:deep_stringify_keys)
    )
    TestRun.where(id: run.id).update_all(created_at: at) if at
    Ingest::IdentityResolver.resolve(run) if resolve
    run
  end

  # One shard delivery, through the producer — the shape spec/requests/repository_runtime_change_spec.rb's
  # `ingest_shard` uses — carrying its own per-example rows, the way a real CI matrix's shard does.
  def post_shard(repository, commit_sha:, duration:, specs:, shard_index:)
    Ingest::RunRecorder.record(
      repository,
      { commit_sha: commit_sha, branch: "main", ci_run_id: "gha-#{commit_sha}",
        total_specs_count: specs.size, annotated_specs_count: 0, duration_seconds: duration },
      shard_id: shard_index.to_s,
      specs: specs.map(&:deep_stringify_keys)
    )
  end

  # A sharded, settled run: every shard timed, the last one arrived longer ago than the settling
  # period, so `wall_clock_decomposable?` answers on it. `specs_per_shard` is one array of wire
  # specs per shard, so a sharded run can carry outcomes and readings too.
  def sharded_run(repository, durations, specs_per_shard:, commit_sha:, at: nil, resolve: false)
    run = nil
    durations.each_with_index do |seconds, index|
      run = post_shard(repository, commit_sha: commit_sha, duration: seconds,
                       specs: specs_per_shard[index], shard_index: index + 1)
    end
    TestRun.where(id: run.id).update_all(created_at: at) if at
    Ingest::IdentityResolver.resolve(run) if resolve
    run.test_run_shards.update_all(updated_at: 1.hour.ago)
    repository.test_runs.find_by!(ci_run_id: "gha-#{commit_sha}")
  end

  # A refusal, stated directly on the pattern spec/requests/repositories_spec.rb's `refuse`
  # helper: the verdict card reads the retained window's TOTAL, not how the row was written, and
  # no assertion here turns on the key stamp the real 400 path leaves behind.
  def refuse(repository)
    IngestRejection.create!(repository: repository, occurred_at: Time.current,
                            details: ["commit_sha can't be blank"], total_reasons_count: 1)
  end

  # The revocation half of the connection indicator's fixture — present the dead token so the
  # platform records the refusal the page reports (the 401 failure path stamps `last_refused_at`).
  def present_revoked_token(token)
    get "/api/v1/repository", headers: { "Authorization" => "Bearer #{token}" }
    expect(response).to have_http_status(:unauthorized)
  end

  # The description shapes, shared because a run's readability depends on them and a second
  # spelling would silently move a fixture between the `derived` and `unreadable` populations.
  def deriving_name = "Order#settle clears the outstanding balance"

  def flaky_name = "Invoice#finalize locks the line items once approved"

  # A run with one passing, readable example — the healthy card: nothing fires.
  def quiet_repository
    repository = create_repository(user: @user, github_full_name: "acme/quiet")
    ingest(repository, [example_spec(name: deriving_name, line_number: 1)])
    repository
  end

  def presented_revoked_repository
    repository = create_repository(user: @user, github_full_name: "acme/dead-token")
    ingest(repository, [example_spec(name: deriving_name, line_number: 1)])
    key = repository.api_keys.create!(name: "Leaked CI")
    revoked_token = key.raw_token
    key.revoke!
    present_revoked_token(revoked_token)
    repository
  end

  def refusing_repository
    repository = create_repository(user: @user, github_full_name: "acme/refusing")
    ingest(repository, [example_spec(name: deriving_name, line_number: 1)])
    2.times { refuse(repository) }
    repository
  end

  def failing_run_repository
    repository = create_repository(user: @user, github_full_name: "acme/failing-run")
    ingest(repository, [example_spec(name: "Ledger#rebuild walks every entry in order",
                                     outcome: "failed", line_number: 1),
                        example_spec(name: deriving_name, outcome: "passed", line_number: 2)])
    repository
  end

  # Two runs on one branch whose outcomes flip for one test — the minimum window the unstable item
  # reads: `UnstableTests#comparable?` needs two runs reporting outcomes, the flip gives it a row,
  # and both descriptions derive so the unreadable item stays out of the way.
  def flip_repository
    repository = create_repository(user: @user, github_full_name: "acme/outcome-flip")
    ingest(repository, [example_spec(name: flaky_name, outcome: "failed", line_number: 1)],
           commit_sha: "flipold0000001", at: 2.hours.ago, resolve: true)
    ingest(repository, [example_spec(name: flaky_name, outcome: "passed", line_number: 1)],
           commit_sha: "flipnew0000002", at: 1.hour.ago, resolve: true)
    repository
  end

  def unreadable_repository
    repository = create_repository(user: @user, github_full_name: "acme/unreadable")
    ingest(repository, [example_spec(name: "Checkout rejects an expired card", line_number: 1),
                        example_spec(name: "Renderer bleeds memory under load", line_number: 2)])
    repository
  end

  # [60, 60, 60, 80] is the material twin of repositories_spec.rb's `[1.0, 1.0, 1.0, 1.4]`: 15s of
  # excess over the balanced floor is 18.8% of the wait, clearing both materiality floors.
  def materially_imbalanced_repository
    repository = create_repository(user: @user, github_full_name: "acme/shard-skew")
    sharded_run(repository, [60.0, 60.0, 60.0, 80.0],
                specs_per_shard: 4.times.map { |i| [example_spec(name: deriving_name, line_number: i + 1)] },
                commit_sha: "skewsha0000001")
    repository
  end

  describe "a run with nothing to flag" do
    # @intent: {"entity": "GET /repositories/:id", "action": "render quiet verdict", "behavior": "a healthy run reads Nothing needs you under the ok dot with no attention list at all", "layer": "request"}
    it "reads Nothing needs you under the ok dot, with no attention list" do
      repository = quiet_repository

      get repository_path(repository)

      expect(title_text).to eq("Nothing needs you")
      expect(title_dot).to eq("rc-dot-ok")
      expect(attn?).to be(false)
      expect(attn_items).to eq([])
    end
  end

  describe "one item per condition" do
    # @intent: {"entity": "GET /repositories/:id", "action": "surface presented revoked key", "behavior": "a revoked key presented since the revocation renders the item 1 revoked key still presented linking to the delivery section under the err tone", "layer": "request"}
    it "surfaces a revoked key still being presented, toward the delivery section" do
      repository = presented_revoked_repository

      get repository_path(repository)

      expect(attn_items).to eq([
        { dot: "rc-dot-err", text: "1 revoked key still presented", href: "#delivery" }
      ])
      expect(title_dot).to eq("rc-dot-err")
    end

    # The count is the retained window's TOTAL — both refusals the window holds — not the length
    # of anything the card lists, which is nothing: the list is the count alone.
    # @intent: {"entity": "GET /repositories/:id", "action": "surface refused ingests", "behavior": "two refusals newer than the newest accepted run render the item 2 rejected ingests since the last accepted run linking to the delivery section under the err tone", "layer": "request"}
    it "surfaces the refusals since the last accepted run, counted from the retained window" do
      repository = refusing_repository

      get repository_path(repository)

      expect(attn_items).to eq([
        { dot: "rc-dot-err", text: "2 rejected ingests since the last accepted run", href: "#delivery" }
      ])
      expect(title_dot).to eq("rc-dot-err")
    end

    # @intent: {"entity": "GET /repositories/:id", "action": "surface failed examples", "behavior": "a run whose ranked examples report one failure renders the item 1 failed in this run linking to the slow section under the err tone", "layer": "request"}
    it "surfaces the run's failures, toward the slow section" do
      repository = failing_run_repository

      get repository_path(repository)

      expect(attn_items).to eq([
        { dot: "rc-dot-err", text: "1 failed in this run", href: "#slow" }
      ])
      expect(title_dot).to eq("rc-dot-err")
    end

    # @intent: {"entity": "GET /repositories/:id", "action": "surface unstable tests", "behavior": "two runs on one branch whose outcomes flip for one test render the item 1 tests changed outcome in this window linking to the unstable section under the warn tone", "layer": "request"}
    it "surfaces tests whose outcome changed across the window, toward the unstable section" do
      repository = flip_repository

      get repository_path(repository)

      expect(attn_items).to eq([
        { dot: "rc-dot-warn", text: "1 tests changed outcome in this window", href: "#unstable" }
      ])
      # The single-item title grammar, on a warn: one thing, needs.
      expect(title_text).to eq("1 thing needs you")
      expect(title_dot).to eq("rc-dot-warn")
    end

    # @intent: {"entity": "GET /repositories/:id", "action": "surface unreadable tests", "behavior": "a run carrying two unreadable examples renders the item 2 tests SpecGuard cannot read linking to the annotations section under the warn tone", "layer": "request"}
    it "surfaces the tests SpecGuard cannot read, toward the annotations section" do
      repository = unreadable_repository

      get repository_path(repository)

      expect(attn_items).to eq([
        { dot: "rc-dot-warn", text: "2 tests SpecGuard cannot read", href: "#annotations" }
      ])
      expect(title_dot).to eq("rc-dot-warn")
    end

    # The count here is the PERCENT STRING the shard decomposition already renders — 15s of excess
    # over the balanced floor, 18.8% of the wait — and not an Integer, so the card prints it
    # undelimited exactly as the panel below spells it.
    # @intent: {"entity": "GET /repositories/:id", "action": "surface shard imbalance", "behavior": "a settled sharded run whose wait is 18.8 percent over the balanced floor renders the item 18.8% of the wait comes from how shards were split linking to the slow section under the warn tone", "layer": "request"}
    it "surfaces a material shard imbalance as the percent of the wait, toward the slow section" do
      repository = materially_imbalanced_repository

      get repository_path(repository)

      expect(attn_items).to eq([
        { dot: "rc-dot-warn", text: "18.8% of the wait comes from how shards were split", href: "#slow" }
      ])
      expect(title_dot).to eq("rc-dot-warn")
    end

    # The negative twin, on the fixture repositories_spec.rb already shows reads 21.4%: the share
    # clears the percent floor alone, so the item turning on the share alone — or on either floor
    # alone — is exactly the mutation this example exists to catch.
    # @intent: {"entity": "GET /repositories/:id", "action": "withhold immaterial imbalance", "behavior": "a settled sharded run 0.3s and 21.4 percent over the balanced floor renders no attention item", "layer": "request"}
    it "withholds the shard item when the excess misses a materiality floor, however large its share" do
      repository = create_repository(user: @user, github_full_name: "acme/shard-tight")
      sharded_run(repository, [1.0, 1.0, 1.0, 1.4],
                  specs_per_shard: 4.times.map { |i| [example_spec(name: deriving_name, line_number: i + 1)] },
                  commit_sha: "tightsha000001")

      get repository_path(repository)

      expect(attn?).to be(false)
      expect(title_text).to eq("Nothing needs you")
    end
  end

  describe "composition and order" do
    # @intent: {"entity": "GET /repositories/:id", "action": "compose err and warn", "behavior": "an err item and a warn item together read 2 things need you under the err dot, err first, each item keeping its own tone", "layer": "request"}
    it "reads 2 things need you with the err tone winning, and keeps each item's own tone" do
      repository = flip_repository
      key = repository.api_keys.create!(name: "Leaked CI")
      revoked_token = key.raw_token
      key.revoke!
      present_revoked_token(revoked_token)

      get repository_path(repository)

      expect(title_text).to eq("2 things need you")
      expect(title_dot).to eq("rc-dot-err")
      expect(attn_items).to eq([
        { dot: "rc-dot-err", text: "1 revoked key still presented", href: "#delivery" },
        { dot: "rc-dot-warn", text: "1 tests changed outcome in this window", href: "#unstable" }
      ])
    end

    # The full list, all six conditions firing on one page: the order is the source order the
    # verdict builds, err items first then warns in their own order, and every anchor is the
    # section that holds that condition — not whichever anchor is nearest.
    # @intent: {"entity": "GET /repositories/:id", "action": "order attention items", "behavior": "all six conditions firing render six items in the order revoked, refused, failed, unstable, unreadable then shard skew with the title 6 things need you under the err dot", "layer": "request"}
    it "renders all six items in the verdict's source order when everything fires" do
      repository = create_repository(user: @user, github_full_name: "acme/verdict-all")

      key = repository.api_keys.create!(name: "Leaked CI")
      revoked_token = key.raw_token
      key.revoke!

      # Run 1, sharded like run 2 so the pair stays assembled the same way: the flaky test fails.
      sharded_run(repository, [60.0, 60.0, 60.0, 70.0],
                  specs_per_shard: [
                    [example_spec(name: flaky_name, outcome: "failed", line_number: 1)],
                    [example_spec(name: deriving_name, line_number: 2)],
                    [example_spec(name: deriving_name, line_number: 3)],
                    [example_spec(name: deriving_name, line_number: 4)]
                  ],
                  commit_sha: "allold00000001", at: 2.hours.ago, resolve: true)

      # Run 2, the newest: the flaky test passes, one example fails, two stay unreadable.
      sharded_run(repository, [60.0, 60.0, 60.0, 80.0],
                  specs_per_shard: [
                    [example_spec(name: flaky_name, outcome: "passed", line_number: 1),
                     example_spec(name: "Ledger#rebuild walks every entry in order",
                                  outcome: "failed", line_number: 5),
                     example_spec(name: "Checkout rejects an expired card", line_number: 6),
                     example_spec(name: "Renderer bleeds memory under load", line_number: 7)],
                    [example_spec(name: deriving_name, line_number: 8)],
                    [example_spec(name: deriving_name, line_number: 9)],
                    [example_spec(name: deriving_name, line_number: 10)]
                  ],
                  commit_sha: "allnew00000002", at: 1.hour.ago, resolve: true)

      # Item 2: a refusal newer than the newest accepted run. One, so the item's count is the
      # window's total and nothing else about this page moves.
      refuse(repository)

      # Item 1: the dead token presented after the revocation.
      present_revoked_token(revoked_token)

      get repository_path(repository)

      expect(title_text).to eq("6 things need you")
      expect(title_dot).to eq("rc-dot-err")
      expect(attn_items).to eq([
        { dot: "rc-dot-err", text: "1 revoked key still presented", href: "#delivery" },
        { dot: "rc-dot-err", text: "1 rejected ingests since the last accepted run", href: "#delivery" },
        { dot: "rc-dot-err", text: "1 failed in this run", href: "#slow" },
        { dot: "rc-dot-warn", text: "1 tests changed outcome in this window", href: "#unstable" },
        { dot: "rc-dot-warn", text: "2 tests SpecGuard cannot read", href: "#annotations" },
        { dot: "rc-dot-warn", text: "18.8% of the wait comes from how shards were split", href: "#slow" }
      ])
    end
  end

  describe "count formatting" do
    # `number_with_delimiter` is the Integer branch's job: a four-figure failure count prints with
    # its comma, while the shard item's count is a String and prints verbatim — the pair in one
    # page, because the branch the Integer examples above cannot reach (their counts are all
    # single digits) is exactly the one a suite big enough to care about will hit.
    # @intent: {"entity": "GET /repositories/:id", "action": "delimit integer counts", "behavior": "a run with 1234 failed examples prints the count as 1,234 while the shard item prints 18.8% undelimited", "layer": "request"}
    it "delimits an Integer count and prints the percent string verbatim" do
      repository = create_repository(user: @user, github_full_name: "acme/big-failure")

      failures = 1_234.times.map { |i| example_spec(name: deriving_name, outcome: "failed", line_number: i + 1) }
      sharded_run(repository, [60.0, 60.0, 60.0, 80.0],
                  specs_per_shard: [
                    [example_spec(name: deriving_name, outcome: "passed", line_number: 2_000)],
                    [example_spec(name: deriving_name, outcome: "passed", line_number: 2_001)],
                    [example_spec(name: deriving_name, outcome: "passed", line_number: 2_002)],
                    failures
                  ],
                  commit_sha: "bigfailsha0001")

      get repository_path(repository)

      expect(attn_items.map { |item| item[:text] }).to eq([
        "1,234 failed in this run",
        "18.8% of the wait comes from how shards were split"
      ])
    end
  end
end
