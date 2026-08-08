# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Repository registration and API keys", type: :request do
  before { @user = sign_in_via_github }

  it "registers a GitHub repository for the signed-in user" do
    expect {
      post repositories_path, params: { repository: { github_full_name: "acme/billing-service" } }
    }.to change(Repository, :count).by(1)

    repository = Repository.last
    expect(repository.user).to eq(@user)
    expect(response).to redirect_to(repository_path(repository))
  end

  it "re-renders the form when the name is not org/repo" do
    post repositories_path, params: { repository: { github_full_name: "nonsense" } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("must look like org/repo")
  end

  it "shows a newly created API key exactly once" do
    repository = register_repository

    post repository_api_keys_path(repository)
    follow_redirect!

    raw_token = response.body[/sgk_[A-Za-z0-9_-]{20,}/]
    expect(raw_token).to be_present
    # The value shown is the real credential, and the digest of it is what was stored.
    expect(ApiKey.last.token_digest).to eq(ApiKey.digest(raw_token))
    expect(response.body).not_to include(ApiKey.last.token_digest)

    # A plain reload must not show it again — the value only ever lived in the flash.
    get repository_path(repository)
    expect(response.body).not_to include(raw_token)

    # ...but what the key is *for* must survive the flash, with a placeholder, never a secret.
    expect(response.body).to include("Connect this repository")
    expect(response.body).to include("&lt;token&gt;")
    expect(response.body).not_to match(/sgk_[A-Za-z0-9_-]{20,}/)
  end

  it "shows the endpoint and a copyable curl snippet with no flash present" do
    repository = create_repository(user: @user)

    get repository_path(repository)

    expect(response.body).to include("Connect this repository")
    expect(response.body).to include("GET #{api_v1_repository_url}")
    expect(response.body).to include(%(curl -H "Authorization: Bearer &lt;token&gt;" #{api_v1_repository_url}))
  end

  it "reports 'not connected' while no API key has ever been used" do
    repository = create_repository(user: @user)
    repository.api_keys.create!(name: "CI")

    get repository_path(repository)

    expect(repository.api_keys.maximum(:last_used_at)).to be_nil
    expect(response.body).to include("Not connected yet")
    expect(response.body).not_to include("Last request")
  end

  it "reports the last request once any API key has been used" do
    repository = create_repository(user: @user)
    repository.api_keys.create!(name: "Idle")
    repository.api_keys.create!(name: "CI").touch_last_used!

    get repository_path(repository)

    expect(response.body).to match(/Last request .+ ago\./)
    expect(response.body).not_to include("Not connected yet")
  end

  it "offers a name field when minting a key, and shows when each key was created" do
    repository = register_repository
    repository.api_keys.create!(name: "Staging")

    get repository_path(repository)

    # The control must actually post a name — a bare button is what made every key identical.
    expect(response.body).to include('name="api_key[name]"')
    expect(response.body).to include("Created")
  end

  it "names a new API key from the form field" do
    repository = register_repository

    expect {
      post repository_api_keys_path(repository), params: { api_key: { name: "Staging" } }
    }.to change(ApiKey, :count).by(1)

    expect(ApiKey.last.name).to eq("Staging")

    # The chosen name is what makes the key distinguishable in the list and in the revoke confirm.
    follow_redirect!
    expect(response.body).to include("Staging")
  end

  it "falls back to the default name when the name field is left blank" do
    repository = register_repository

    post repository_api_keys_path(repository), params: { api_key: { name: "" } }

    expect(ApiKey.last.name).to eq("Default CI Key")
  end

  it "falls back to the default name when no params are sent at all" do
    repository = register_repository

    post repository_api_keys_path(repository)

    expect(ApiKey.last.name).to eq("Default CI Key")
  end

  it "revokes an API key" do
    repository = register_repository
    post repository_api_keys_path(repository)
    api_key = ApiKey.last

    expect {
      delete repository_api_key_path(repository, api_key)
    }.to change(ApiKey, :count).by(-1)
  end

  describe "recording who minted a key" do
    # These read the parsed DOM rather than the raw body, because both of the obvious
    # whole-document assertions are unsound on this page:
    #
    #   * `include(@user.display_name)` is satisfied by the topbar, which prints
    #     `current_user.display_name` on every page (layouts/_topbar.html.erb:13) — so it passes
    #     with the creator cell deleted.
    #   * `include("Created")` is satisfied by the "Created by" header — so it passes with the
    #     pre-existing timestamp column deleted.
    #
    # Scoping to the key's own row and to the header cells makes both assertions load-bearing.
    # Scoped to `#api-keys` because this page now renders a second table (Recent runs) — a bare
    # `find("table")` would raise Capybara::Ambiguous. The `id` is the API-keys panel's own
    # deep-link anchor (repositories/show.html.erb), not something added for this finder.
    def api_keys_table = Capybara.string(response.body).find("#api-keys table")

    def api_key_headers = api_keys_table.all("thead th").map(&:text)

    def api_key_row(name) = api_keys_table.find("tbody tr", text: name)

    it "attributes a newly minted key to the signed-in user" do
      repository = register_repository

      post repository_api_keys_path(repository), params: { api_key: { name: "Staging" } }

      # Revoking is a hard delete with no audit row, so attribution recorded here is the only
      # attribution there will ever be.
      expect(ApiKey.last.created_by_user).to eq(@user)
    end

    it "names the colleague who minted a key on the owner's page" do
      # The scenario this slice exists for: a collaborator holding `keys.manage` mints a Bearer
      # credential on someone else's repository, and the owner has to be able to tell which key
      # is theirs before revoking anything.
      repository = create_repository(user: @user)
      colleague = create_user(github_uid: "4004", github_handle: "departing-dev")
      create_membership(repository: repository, user: colleague,
                        permissions: [RepositoryMembership::VIEW, RepositoryMembership::KEYS_MANAGE])
      repository.api_keys.create!(name: "Shared CI", created_by_user: colleague)

      get repository_path(repository)

      # Deliberately *not* the signed-in user's own handle — that one is in the topbar regardless.
      expect(api_key_row("Shared CI")).to have_text("departing-dev")
    end

    it "renders a fallback for a key with no recorded creator" do
      repository = create_repository(user: @user)
      repository.api_keys.create!(name: "Legacy CI")

      get repository_path(repository)

      expect(response).to have_http_status(:ok)
      # The rest of the row must be unaffected by the missing attribution.
      expect(api_key_row("Legacy CI")).to have_text("Unknown").and have_text("Revoke")
    end

    # The marker for a creator who no longer holds access. Its own describe rather than more
    # examples above, because every one of these needs the same two-people-and-a-revocation setup.
    describe "a key whose creator has since lost access" do
      # `count_queries` comes from spec/support/query_capture.rb: schema reads and cached repeats
      # are excluded, so "no per-row query" is asserted rather than eyeballed.

      # A colleague who minted a key and whose membership was then destroyed — reachable on main
      # today: MembershipsController#destroy touches no api_keys row, so the key outlives the
      # access it was minted under.
      def revoked_colleague(repository, handle:, uid:, key_name:)
        colleague = create_user(github_uid: uid, github_handle: handle)
        membership = create_membership(repository: repository, user: colleague,
                                       permissions: [RepositoryMembership::VIEW,
                                                     RepositoryMembership::KEYS_MANAGE])
        repository.api_keys.create!(name: key_name, created_by_user: colleague)
        membership.destroy!
        colleague
      end

      it "names the ex-colleague and marks the key their revoked access left behind" do
        repository = create_repository(user: @user)
        revoked_colleague(repository, handle: "revoked-dev", uid: "5005", key_name: "Their CI")

        get repository_path(repository)

        # The handle still has to be there — the marker is added to the attribution, not swapped
        # in for it. Without the handle the owner cannot tell *whose* key they are about to revoke.
        expect(api_key_row("Their CI")).to have_text("revoked-dev")
        expect(api_key_row("Their CI")).to have_text("no longer has access")
      end

      it "marks neither the owner's key, a current member's key, nor an unattributed one" do
        repository = create_repository(user: @user)
        current = create_user(github_uid: "6006", github_handle: "current-dev")
        create_membership(repository: repository, user: current,
                          permissions: [RepositoryMembership::VIEW, RepositoryMembership::KEYS_MANAGE])
        repository.api_keys.create!(name: "Owner CI", created_by_user: @user)
        repository.api_keys.create!(name: "Member CI", created_by_user: current)
        repository.api_keys.create!(name: "Legacy CI")

        get repository_path(repository)

        # Four creator states, and they must stay four. The owner holds access implicitly and has
        # no membership row, so reading the marker off "has a membership" alone would mark them.
        expect(api_key_row("Owner CI")).to have_no_text("no longer has access")
        expect(api_key_row("Member CI")).to have_no_text("no longer has access")
        # A NULL creator is a legacy key or a deleted account, never an ex-member — saying they
        # were revoked would be the page asserting something it does not know.
        expect(api_key_row("Legacy CI")).to have_text("Unknown")
        expect(api_key_row("Legacy CI")).to have_no_text("no longer has access")
      end

      it "asks about membership once for the whole table, not once per key" do
        repository = create_repository(user: @user)
        revoked_colleague(repository, handle: "revoked-dev", uid: "5005", key_name: "Their CI")

        get repository_path(repository)
        baseline = count_queries { get repository_path(repository) }

        # Distinct creators as well as more rows: a per-row membership lookup would grow with
        # either, and one that memoized per user would still grow with the second person.
        revoked_colleague(repository, handle: "other-dev", uid: "5006", key_name: "Other CI")
        3.times { |i| repository.api_keys.create!(name: "Owner CI #{i}", created_by_user: @user) }

        expect(count_queries { get repository_path(repository) }).to eq(baseline)
        expect(api_key_row("Other CI")).to have_text("no longer has access")
      end
    end

    it "adds the creator column without disturbing the existing key columns" do
      repository = create_repository(user: @user)
      repository.api_keys.create!(name: "CI", created_by_user: @user).touch_last_used!

      get repository_path(repository)

      # Exact and ordered, so "Created by" cannot stand in for "Created". The trailing "" is the
      # Revoke button's unlabelled column.
      expect(api_key_headers).to eq(["Name", "Key", "Created by", "Created", "Last used", ""])
      expect(api_key_row("CI")).to have_text(ApiKey.last.token_hint)
    end
  end

  it "does not expose another user's repository" do
    other = create_repository(user: create_user(github_uid: "9999", github_handle: "someone-else"),
                              github_full_name: "other/repo")

    get repository_path(other)

    expect(response).to have_http_status(:not_found)
  end

  describe "the Overview panel's suite figures" do
    # Scoped to the panel rather than the whole document, because the page is full of numbers and
    # prose that would satisfy a bare `response.body` match. `#overview` is the panel's own id.
    def overview_panel = Capybara.string(response.body).find("#overview")

    # A sharded run, written directly. The suite's own canonical fixture one layer up —
    # `spec/requests/api/v1/ingest_spec.rb` builds a 4-shard, 20,000-example run and pins its MAX
    # at 74.25s — produces exactly these rows through the recorder; the recorder is exercised
    # there, and the question here is only what the Overview does with what it left behind.
    #
    # One helper for every describe in this panel, hoisted here rather than copied into each: two
    # byte-identical definitions of the same fixture drift, and the shard timestamps below are
    # precisely the sort of detail that would end up set in one copy and not the other.
    #
    # `names:` overrides the shard_ids for the examples that need an unnamed slice. Defaulted to
    # nil so the `(index + 1).to_s` numbering the pinned expectations depend on is untouched.
    #
    # `last_shard_arrived_ago` backdates the shard rows' `updated_at`, which is what
    # `TestRun#shard_delivery_settled?` reads. The default puts every fixture in the ordinary
    # settled state a reader looks at long after CI finished; the in-flight examples pass a fresh
    # one deliberately, and are the only place the distinction is the subject.
    # `spec_counts` sizes each shard independently, defaulting to the even 5,000 every existing
    # expectation was written against. It is a parameter and not a constant because the two causes
    # of a duration spread are only separable by it: with every shard the same size a long shard is
    # long because its tests are dear, and only a fixture that can make the counts UNEVEN can drive
    # the other branch. A helper that hard-coded 5,000 would leave that branch unreachable —
    # green by fixture rather than by behaviour.
    def sharded_run(repository, durations, commit_sha:, names: nil, spec_counts: nil,
                    last_shard_arrived_ago: 1.hour)
      # The parent's counts are DERIVED from the shards written below, never asserted beside them.
      # `Ingest::RunRecorder#recompute_totals` re-derives them as the SUM over the rows recorded so
      # far, after every ingest — so a two-shard run's parent reads 10,000 and not 20,000, and a
      # fixture that hard-coded the full-suite figure would build a row the producer cannot (the
      # SPGD-91 shape). That matters most in the examples whose whole subject is what a
      # half-delivered run looks like: they would have rendered a "Tests in suite 20,000" no
      # half-delivered run ever shows. A 4-shard fixture is unaffected — 5000 x 4 is the 20,000
      # the pinned expectations already depend on.
      sizes = spec_counts || Array.new(durations.length, 5000)
      run = repository.test_runs.create!(commit_sha: commit_sha, ci_run_id: "gha-#{commit_sha}",
                                         total_specs_count: sizes.sum,
                                         annotated_specs_count: sizes.sum / 4,
                                         duration_seconds: durations.compact.max)
      durations.each_with_index do |seconds, index|
        run.test_run_shards.create!(shard_id: names ? names[index] : (index + 1).to_s,
                                    total_specs_count: sizes[index],
                                    annotated_specs_count: sizes[index] / 4, duration_seconds: seconds)
      end
      run.test_run_shards.update_all(updated_at: last_shard_arrived_ago.ago)
      run
    end

    it "shows the suite denominator and the tests SpecGuard cannot see" do
      repository = create_repository(user: @user)
      # 3 specs, 2 annotated — so 1 test is invisible to SpecGuard, and 66.7% is the ratio.
      repository.test_runs.create!(commit_sha: "feedfacecafe0001", branch: "main",
                                   total_specs_count: 3, annotated_specs_count: 2)

      get repository_path(repository)

      panel = overview_panel
      # The denominator, which was stored and API-returned but rendered nowhere before this.
      expect(panel).to have_text("Tests in suite 3", normalize_ws: true)
      expect(panel).to have_text("Carrying an @intent 2", normalize_ws: true)
      # The number the whole panel exists for: what SpecGuard *cannot* see.
      expect(panel).to have_text("Not visible to SpecGuard 1", normalize_ws: true)
      # ...and the ratio never appears without the denominator it was computed over.
      expect(panel).to have_text("66.7% — 2 of 3 tests carry an @intent.", normalize_ws: true)
      expect(panel).to have_text("SpecGuard cannot see the other 1 test.", normalize_ws: true)
    end

    it "puts the real counts into the meter's accessible markup, not (ratio, 100)" do
      repository = create_repository(user: @user)
      repository.test_runs.create!(commit_sha: "feedfacecafe0002", total_specs_count: 3,
                                   annotated_specs_count: 2)

      get repository_path(repository)

      # `aria-valuemax="100"` would mean the component was handed the percentage and the suite size
      # never reached the accessibility tree — the same omission, one layer down.
      meter = overview_panel.find("[role='meter']")
      expect(meter["aria-valuemax"]).to eq("3.0")
      expect(meter["aria-valuenow"]).to eq("2.0")
    end

    it "names the run the figures were measured on" do
      repository = create_repository(user: @user)
      repository.test_runs.create!(commit_sha: "feedfacecafe0003", branch: "release/2.1",
                                   total_specs_count: 3, annotated_specs_count: 2)

      get repository_path(repository)

      # A stale run is a stale denominator, so the reader has to be able to see which run it is.
      expect(overview_panel).to have_text("Measured on feedfac (release/2.1)", normalize_ws: true)
    end

    it "reads the newest run, not the first one ingested" do
      repository = create_repository(user: @user)
      repository.test_runs.create!(commit_sha: "0ld", total_specs_count: 100, annotated_specs_count: 1)
      repository.test_runs.create!(commit_sha: "new", total_specs_count: 3, annotated_specs_count: 2)

      get repository_path(repository)

      expect(overview_panel).to have_text("Tests in suite 3", normalize_ws: true)
      expect(overview_panel).not_to have_text("Tests in suite 100", normalize_ws: true)
    end

    it "shows an empty state — never 0% — for a repository whose CI has never reported" do
      repository = create_repository(user: @user)

      get repository_path(repository)

      panel = overview_panel
      expect(panel).to have_text("No CI run has reported yet", normalize_ws: true)
      # The defect this replaces: never-ingested rendered byte-identically to measured-zero.
      expect(panel).to have_no_text("0%", normalize_ws: true)
      expect(panel).to have_no_css("[role='meter']")
    end

    it "distinguishes a run that measured zero annotations from one that never happened" do
      repository = create_repository(user: @user)
      repository.test_runs.create!(commit_sha: "feedfacecafe0004", total_specs_count: 3,
                                   annotated_specs_count: 0)

      get repository_path(repository)

      panel = overview_panel
      # This repository genuinely has 0% — and says so with its denominator attached.
      expect(panel).to have_text("0.0% — 0 of 3 tests carry an @intent.", normalize_ws: true)
      expect(panel).to have_text("SpecGuard cannot see the other 3 tests.", normalize_ws: true)
      expect(panel).to have_no_text("No CI run has reported yet", normalize_ws: true)
    end

    it "says so when the run itself reported no tests, rather than showing a vacuous 0%" do
      repository = create_repository(user: @user)
      repository.test_runs.create!(commit_sha: "feedfacecafe0005", total_specs_count: 0,
                                   annotated_specs_count: 0)

      get repository_path(repository)

      # 0/0 divides into a tidy 0% that reads exactly like "a suite with no annotations", so the
      # meter is suppressed here the same way it is for a never-ingested repo — asserting the
      # absence, not just the presence of the sentence that explains it.
      panel = overview_panel
      expect(panel).to have_text("reported no tests at all", normalize_ws: true)
      expect(panel).to have_no_text("0%", normalize_ws: true)
      expect(panel).to have_no_css("[role='meter']")
      # ...while the counts themselves still render: "the run measured nothing" is a fact worth
      # stating, and it is not the same as "no run has reported".
      expect(panel).to have_text("Tests in suite 0", normalize_ws: true)
      expect(panel).to have_no_text("No CI run has reported yet", normalize_ws: true)
    end

    it "labels the spec-intent count as a search index, not as a share of the suite" do
      repository = create_repository(user: @user)
      repository.test_runs.create!(commit_sha: "feedfacecafe0006", total_specs_count: 3,
                                   annotated_specs_count: 2)

      get repository_path(repository)

      # Ingestion writes no spec_intents row yet, so this is structurally 0 — and a bare
      # "Spec intents: 0" sitting above "Annotated: 66.7%" was two contradictory descriptions of
      # the same suite.
      panel = overview_panel
      expect(panel).to have_text("Searchable intents 0", normalize_ws: true)
      expect(panel).to have_text("not a count of tests in the suite", normalize_ws: true)
      expect(panel).to have_no_text("Spec intents", normalize_ws: true)
    end

    # What the suite *costs*, which the panel stated the size of and never the price of. The
    # column has been on the page since the Recent-runs table shipped; what is new is that it is
    # a labelled header figure here, which is a separate surface.
    describe "the latest run's total runtime" do
      it "renders the wall clock as a labelled figure, in a form a reader can read" do
        repository = create_repository(user: @user)
        repository.test_runs.create!(commit_sha: "feedfacecafe0008", total_specs_count: 3,
                                     annotated_specs_count: 2, duration_seconds: 372.4)

        get repository_path(repository)

        panel = overview_panel
        expect(panel).to have_text("Total runtime 6m 12s", normalize_ws: true)
        # A true number is not automatically a legible one: nobody reads `372.4s` as six minutes.
        expect(panel).to have_no_text("372.4s", normalize_ws: true)
        # The other half of the seam is the TREATMENT, and this is the side of it that says "this
        # is a measurement". `text-app-muted` is how this page styles an absent fact, so a
        # reported wall clock wearing it would read as an omission. Asserted positively — a bare
        # `have_no_css(".text-app-muted")` would also pass with the figure deleted outright.
        expect(panel).to have_css("dd span:not(.text-app-muted)", text: "6m 12s")
      end

      # The panel's signature refusal, applied to this column: rendering `0.0s` would make "the
      # client sent no timing" byte-identical to "the run took no time".
      it "says the timing was not reported rather than showing it as 0.0s" do
        repository = create_repository(user: @user)
        repository.test_runs.create!(commit_sha: "feedfacecafe0009", total_specs_count: 3,
                                     annotated_specs_count: 2, duration_seconds: nil)

        get repository_path(repository)

        panel = overview_panel
        # Label-scoped, not a bare "not reported": the wording is shared with other absent facts
        # on this page, and a bare match would pass with the runtime figure deleted entirely.
        expect(panel).to have_text("Total runtime not reported", normalize_ws: true)
        expect(panel).to have_no_text("Total runtime 0.0s", normalize_ws: true)
        expect(panel).to have_no_text("Total runtime 0s", normalize_ws: true)
        # The wording alone does not carry the distinction — the muted tone is the other half of
        # it, and this panel's whole job is styling an absent fact as absent rather than printing
        # it as a number. Pinned here because the helper is now the single treatment authority for
        # BOTH surfaces that render this column: one unnoticed edit desaturates them together.
        expect(panel).to have_css("dd span.text-app-muted", text: "not reported")
      end

      # A measured zero is a measurement. The distinction only exists if both sides of it render.
      it "prints a run that genuinely measured zero seconds as zero" do
        repository = create_repository(user: @user)
        repository.test_runs.create!(commit_sha: "feedfacecafe0010", total_specs_count: 3,
                                     annotated_specs_count: 2, duration_seconds: 0.0)

        get repository_path(repository)

        expect(overview_panel).to have_text("Total runtime 0.0s", normalize_ws: true)
        expect(overview_panel).to have_no_text("Total runtime not reported", normalize_ws: true)
        # And it is styled as a measurement, not as an absence. This is the example where the
        # treatment carries the most: `0.0s` muted would read as "nothing was reported" to a
        # reader who takes the tone at its word, which is precisely the conflation being refused.
        expect(overview_panel).to have_css("dd span:not(.text-app-muted)", text: "0.0s")
      end

      # The meter and the ratio are suppressed for a run that reported no tests, because 0/0 has
      # no share. Wall clock is not a share: a run that measured nothing still took time, so the
      # runtime figure must NOT be gated on the same condition.
      it "still renders for a run that reported no tests at all" do
        repository = create_repository(user: @user)
        repository.test_runs.create!(commit_sha: "feedfacecafe0011", total_specs_count: 0,
                                     annotated_specs_count: 0, duration_seconds: 92.0)

        get repository_path(repository)

        panel = overview_panel
        expect(panel).to have_text("Total runtime 1m 32s", normalize_ws: true)
        # ...without disturbing the suppression that example above pins.
        expect(panel).to have_text("Tests in suite 0", normalize_ws: true)
        expect(panel).to have_no_text("0%", normalize_ws: true)
        expect(panel).to have_no_css("[role='meter']")
      end

      # The empty state stays a pure empty state: a repository whose CI has never reported has no
      # run to have taken time, so there is no runtime figure to label — not one reading zero,
      # and not one reading "not reported" either.
      it "renders no runtime figure at all for a repository whose CI has never reported" do
        repository = create_repository(user: @user)

        get repository_path(repository)

        expect(overview_panel).to have_no_text("Total runtime", normalize_ws: true)
      end
    end

    # A sharded run's wall clock is a MAX and its cost is a SUM, and they are not the same number.
    # `Ingest::RunRecorder` derives the MAX deliberately — it is what an operator's CI dashboard
    # shows — so nothing here changes it. What is pinned is that the panel stops calling it a
    # total, and starts saying how many parts the run came in.
    describe "the latest run's shard composition" do
      # The defect, stated as an expectation: MAX 74.25s under the label "Total runtime" was a
      # 3.4× understatement of the only cost figure on the page.
      it "names the wall clock as the slowest shard and prints the machine time beside it" do
        repository = create_repository(user: @user)
        sharded_run(repository, [61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0020")

        get repository_path(repository)

        panel = overview_panel
        expect(panel).to have_text("Wall clock (slowest of 4 shards) 1m 14s", normalize_ws: true)
        expect(panel).to have_text("Machine time (all 4 added up) 4m 14s", normalize_ws: true)
        # The label the figure used to wear is what made it wrong. It must be gone, not merely
        # joined by a second row — "Total runtime 1m 14s" beside "Machine time 4m 14s" is two
        # contradictory descriptions of the same run.
        expect(panel).to have_no_text("Total runtime", normalize_ws: true)
        # And the machine time is styled as the measurement it is, not as an absent fact.
        expect(panel).to have_css("dd span:not(.text-app-muted)", text: "4m 14s")
      end

      it "states that the run was assembled from shards, and how many" do
        repository = create_repository(user: @user)
        sharded_run(repository, [61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0021")

        get repository_path(repository)

        panel = overview_panel
        expect(panel).to have_text("Assembled from 4 shard reports", normalize_ws: true)
        # Counted as rows, and worded as rows. The unique index that deduplicates a redelivered
        # shard is partial (`WHERE shard_id IS NOT NULL`), so an unnamed shard contributes one row
        # per delivery — a shard count is not a count of distinct CI jobs and must not claim to be.
        expect(panel).to have_text("not necessarily 4 distinct CI jobs", normalize_ws: true)
        # The whole sentence, not a fragment of it. This is the one branch entitled to say the
        # figure is what the suite cost, and asserting only the phrase "added together" would pass
        # just as happily if the claim were emitted unconditionally — which is how it shipped
        # beside a floor once already.
        expect(panel).to have_text(
          "The machine time is those 4 added together, which is what the suite cost.",
          normalize_ws: true
        )
        # Same rule for the wall clock's own claim: it belongs to this branch and only this one,
        # where every shard reported and "the slowest single shard" is therefore the slowest shard
        # there was.
        expect(panel).to have_text(
          "The wall clock is the slowest single shard, which is what a reader waited through.",
          normalize_ws: true
        )
      end

      # `test_run_shards.duration_seconds` is nullable and `Ingest::Payload` accepts nil
      # explicitly, so a silent shard is an ordinary state. A SUM that skips it and prints the
      # remainder as a total is a confident number over a sliver — the exact thing this panel
      # refuses everywhere else.
      it "says the machine time is a floor when a shard reported no timing" do
        repository = create_repository(user: @user)
        sharded_run(repository, [60.0, 30.0, nil, 45.0], commit_sha: "feedfacecafe0022")

        get repository_path(repository)

        panel = overview_panel
        # The LABEL carries the denominator, because a label is the most prominent claim a number
        # wears. "all 4 added up" over a SUM of three is this ticket's own defect one level down:
        # a coverage asserted in the loudest place on the row and retracted in the quietest.
        expect(panel).to have_text("Machine time (3 of 4 added up) at least 2m 15s", normalize_ws: true)
        expect(panel).to have_no_text("all 4 added up", normalize_ws: true)
        expect(panel).to have_no_text("Machine time (3 of 4 added up) 2m 15s", normalize_ws: true)
        # The wall clock's label carries its denominator too, and its denominator is 3 — the MAX is
        # over the shards that reported, and the silent one may well have been the slowest, since a
        # cancelled or timed-out job usually is. "slowest of 4 shards" over a MAX of three is the
        # row below's overclaim moved one row up.
        expect(panel).to have_text("Wall clock (slowest of the 3 that reported) 1m", normalize_ws: true)
        expect(panel).to have_no_text("slowest of 4 shards", normalize_ws: true)
        # And the prose says the figure is partial ONCE, in the branch that is true — it must not
        # also assert the complete claim, in this or any other wording.
        expect(panel).to have_text(
          "Only 3 of them reported a timing, so both figures above cover just that much: the wall " \
          "clock is the slowest that reported rather than the slowest overall, and the machine " \
          "time is a floor rather than a total — the real cost is higher by however long the 1 " \
          "silent shard took.",
          normalize_ws: true
        )
        expect(panel).to have_no_text("which is what the suite cost", normalize_ws: true)
        expect(panel).to have_no_text("the slowest single shard", normalize_ws: true)
        # `pluralize` inflects the noun and nothing around it, so the singular reading is the one
        # that breaks — and one silent shard, a cancelled or timed-out CI job, is the likeliest
        # way this branch is ever reached.
        expect(panel).to have_no_text("silent shards", normalize_ws: true)
        # An incomplete measurement is still a measurement — muting it would file it under
        # "nothing was reported", which is the state one example below.
        expect(panel).to have_css("dd span:not(.text-app-muted)", text: "at least 2m 15s")
      end

      # The plural side of the same branch, which nothing exercised before: `pluralize` exists only
      # to handle plurality, and a branch whose sole example supplies 1 tests the inflection it
      # never performs.
      it "words the shortfall in the plural when more than one shard reported no timing" do
        repository = create_repository(user: @user)
        sharded_run(repository, [60.0, nil, nil, 45.0], commit_sha: "feedfacecafe0027")

        get repository_path(repository)

        panel = overview_panel
        expect(panel).to have_text("Machine time (2 of 4 added up) at least 1m 45s", normalize_ws: true)
        expect(panel).to have_text("Wall clock (slowest of the 2 that reported) 1m", normalize_ws: true)
        expect(panel).to have_text(
          "Only 2 of them reported a timing, so both figures above cover just that much: the wall " \
          "clock is the slowest that reported rather than the slowest overall, and the machine " \
          "time is a floor rather than a total — the real cost is higher by however long the 2 " \
          "silent shards took.",
          normalize_ws: true
        )
        expect(panel).to have_no_text("which is what the suite cost", normalize_ws: true)
        expect(panel).to have_no_text("the slowest single shard", normalize_ws: true)
      end

      # The OTHER count in that same sentence, and the reading neither example above reaches: two
      # shards with one silent puts `timed_shards` at 1. Both quantities on this branch are counts
      # that words have to agree with, so both need a singular example — the first round of this
      # panel shipped "those shard took" and the second shipped "adds up those 1", each because
      # only the plural reading of one of them was ever rendered.
      it "reads correctly when exactly one shard reported a timing" do
        repository = create_repository(user: @user)
        sharded_run(repository, [90.0, nil], commit_sha: "feedfacecafe0028")

        get repository_path(repository)

        panel = overview_panel
        expect(panel).to have_text("Wall clock (slowest of the 1 that reported) 1m 30s", normalize_ws: true)
        expect(panel).to have_text("Machine time (1 of 2 added up) at least 1m 30s", normalize_ws: true)
        expect(panel).to have_text(
          "Only 1 of them reported a timing, so both figures above cover just that much: the wall " \
          "clock is the slowest that reported rather than the slowest overall, and the machine " \
          "time is a floor rather than a total — the real cost is higher by however long the 1 " \
          "silent shard took.",
          normalize_ws: true
        )
        expect(panel).to have_no_text("all 2 added up", normalize_ws: true)
        expect(panel).to have_no_text("slowest of 2 shards", normalize_ws: true)
        expect(panel).to have_no_text("which is what the suite cost", normalize_ws: true)
        expect(panel).to have_no_text("silent shards", normalize_ws: true)
      end

      it "reports no machine time at all when not one shard reported a timing" do
        repository = create_repository(user: @user)
        sharded_run(repository, [nil, nil, nil, nil], commit_sha: "feedfacecafe0023")

        get repository_path(repository)

        panel = overview_panel
        expect(panel).to have_text("Machine time (0 of 4 added up) not reported", normalize_ws: true)
        # The wall clock is in the same state and says so. A label reading "slowest of 4 shards"
        # over a figure the very same row prints as "not reported" describes a number that is not
        # there.
        expect(panel).to have_text("Wall clock (0 of 4 reported) not reported", normalize_ws: true)
        expect(panel).to have_no_text("slowest of 4 shards", normalize_ws: true)
        # Never `0.0s`: four shards that added up to nothing and four shards that said nothing are
        # different runs, and SQL's SUM over an all-null column returns NULL precisely so they stay
        # different here.
        expect(panel).to have_no_text("Machine time (0 of 4 added up) 0.0s", normalize_ws: true)
        expect(panel).to have_no_text("at least", normalize_ws: true)
        expect(panel).to have_no_text("all 4 added up", normalize_ws: true)
        expect(panel).to have_text(
          "Not one of them reported a timing, so there is neither a wall clock nor a machine " \
          "time to show — this run's cost is unknown, not zero.",
          normalize_ws: true
        )
        expect(panel).to have_no_text("which is what the suite cost", normalize_ws: true)
        # The sentence stating what the wall clock IS must not survive into a branch where the page
        # printed no wall clock at all — that is a confident claim over an absent number, which is
        # the whole defect this panel exists to retire.
        expect(panel).to have_no_text("the slowest single shard", normalize_ws: true)
        expect(panel).to have_css("dd span.text-app-muted", text: "not reported")
      end

      # A measured zero is a measurement here too, and `0.0.present?` being false is how the
      # blank-check version of this would get it wrong.
      it "prints a machine time that genuinely measured zero as zero" do
        repository = create_repository(user: @user)
        sharded_run(repository, [0.0, 0.0], commit_sha: "feedfacecafe0024")

        get repository_path(repository)

        panel = overview_panel
        # "all 2" is earned here — both shards reported, so the label's coverage claim is true.
        expect(panel).to have_text("Machine time (all 2 added up) 0.0s", normalize_ws: true)
        expect(panel).to have_no_text("Machine time (all 2 added up) not reported", normalize_ws: true)
        expect(panel).to have_css("dd span:not(.text-app-muted)", text: "0.0s")
      end

      # The other side of the branch, and the one the whole existing corpus takes. A single shard's
      # MAX *is* its SUM, so there is no composition to disambiguate and nothing to disambiguate it
      # with — the second figure would be the first figure printed twice under a heavier label.
      it "renders a one-shard run exactly as an unsharded run" do
        repository = create_repository(user: @user)
        sharded_run(repository, [372.4], commit_sha: "feedfacecafe0025")

        get repository_path(repository)

        panel = overview_panel
        expect(panel).to have_text("Total runtime 6m 12s", normalize_ws: true)
        expect(panel).to have_no_text("Machine time", normalize_ws: true)
        expect(panel).to have_no_text("Wall clock", normalize_ws: true)
        expect(panel).to have_no_text("Assembled from", normalize_ws: true)
      end

      # And a run with no shard rows at all — every run whose client named no `ci_run_id`, which
      # is every laptop `bundle exec rspec` and the entire corpus predating sharding.
      it "renders a run with no shard rows exactly as before" do
        repository = create_repository(user: @user)
        repository.test_runs.create!(commit_sha: "feedfacecafe0026", total_specs_count: 3,
                                     annotated_specs_count: 2, duration_seconds: 372.4)

        get repository_path(repository)

        panel = overview_panel
        expect(panel).to have_text("Total runtime 6m 12s", normalize_ws: true)
        expect(panel).to have_no_text("Machine time", normalize_ws: true)
        expect(panel).to have_no_text("Assembled from", normalize_ws: true)
      end
    end

    # The panel could name the slowest shard, say how far ahead of an even split the run finished,
    # and show the spread — from rows it already stores — and said none of it. So two runs that are
    # opposite operational facts rendered byte-identically: four shards at 63.4s each and three at
    # ~60s beside a runaway at 74.25s are both 253.75s of machine time and both print one MAX and
    # one SUM. Only the second has anything to fix.
    #
    # ELEMENT-scoped throughout, never panel-scoped. The panel already carries several sentences
    # about shards and timings that share vocabulary with these, so a `have_text` against the whole
    # panel would go green off the wrong paragraph with the deciding branch deleted — the trap
    # `spec/requests/repository_suite_growth_spec.rb:30-34` documents from a verified mutation.
    describe "the latest run's wall-clock decomposition" do
      def decomposition = overview_panel.find("#wall-clock-decomposition")
      def distribution = overview_panel.find("#shard-distribution")

      # The project's canonical fixture, the same durations `spec/requests/api/v1/ingest_spec.rb`
      # builds. Its arithmetic: SUM 253.75, spread across 4 shards 63.4375 (`1m 3s`), MAX 74.25
      # (`1m 14s`), so 10.8125s — 14.6% of the wait — bought nothing. Every one of those facts is
      # derivable from the stored rows and none of them had a surface.
      it "names the slowest shard, the floor, and the excess on the canonical fixture" do
        repository = create_repository(user: @user)
        sharded_run(repository, [61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0030")

        get repository_path(repository)

        # The shard the headline MAX came from, finally identified — and named by the `shard_id`
        # its own client sent, which is the only name anyone can act on.
        expect(decomposition).to have_text("The slowest was shard 3, at 1m 14s.", normalize_ws: true)
        # The floor, worded as a bound and never as a target. A split achieving it is not claimed
        # to exist — tests are not arbitrarily divisible — only that none can beat it.
        expect(decomposition).to have_text(
          "Those 4 shards hold 4m 14s of machine time between them, so 1m 3s is the shortest wall " \
          "clock any arrangement of them could have produced",
          normalize_ws: true
        )
        expect(decomposition).to have_text("a floor nothing can go under", normalize_ws: true)
        # The whole point: how much of the 1m 14s wait was the suite and how much was the split.
        expect(decomposition).to have_text(
          "This run waited 1m 14s: 10.8s of that, 14.6% of the wait, came from how the suite was " \
          "divided across shards rather than from the suite itself.",
          normalize_ws: true
        )
        # A shard that ran 10.8s past the floor did stand out, and the balanced branch's opener
        # must not be reachable from here.
        expect(decomposition).to have_no_text("No shard stood out", normalize_ws: true)
      end

      # A single ratio flattens shapes that are not the same problem — three shards at a minute
      # beside one runaway, and four fanned evenly across thirty seconds, can share an excess. So
      # the distribution is shown, slowest first, which is also the order that puts the shard just
      # named at the head of the list.
      #
      # Each row also carries the DENOMINATOR its duration was measured over and the two divided.
      # Without them the list is four wall clocks and no way to tell a shard that ran long because
      # it held four times the tests from one that held the same tests four times dearer — two
      # opposite actions behind one identical display, which is exactly what this fixture is: every
      # shard holds 5,000, so the whole of this spread is in what the tests COST.
      it "shows every shard's duration, its test count and the two divided, slowest first" do
        repository = create_repository(user: @user)
        sharded_run(repository, [61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0031")

        get repository_path(repository)

        expect(distribution.all("li").map { |li| li.text(normalize_ws: true) })
          .to eq(["shard 3 1m 14s 5,000 tests 14.9ms/test",
                  "shard 1 1m 1s 5,000 tests 12.2ms/test",
                  "shard 4 1m 5,000 tests 12.0ms/test",
                  "shard 2 58.5s 5,000 tests 11.7ms/test"])
      end

      # The per-test figure is in MILLISECONDS and not in the panel's shared `humanized_seconds`,
      # which is the correct formatter for the three run-level figures that sit within a few lines
      # of each other and the wrong one here: this quantity is three orders of magnitude smaller,
      # and `74.25 / 5000` through that formatter renders `0.0s` — a computed zero, on the panel
      # whose rule is that a figure it cannot stand behind is withheld with its reason rather than
      # rounded away. Pinned as an absence so a later "share one formatter" tidy-up goes red.
      it "renders the per-test cost in a unit that resolves it rather than rounding it to zero" do
        repository = create_repository(user: @user)
        sharded_run(repository, [61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0050")

        get repository_path(repository)

        expect(distribution).to have_text("14.9ms/test", normalize_ws: true)
        expect(distribution).to have_no_text("0.0s/test", normalize_ws: true)
        expect(distribution).to have_no_text("0.0s", normalize_ws: true)
      end

      # A slow integration suite is seconds per example, not milliseconds, and the same formatter
      # has to stay legible there — 8 tests over 61s is 7.6s each, and `7625.0ms/test` is a number
      # a reader has to divide in their head to use. The other end of the same rule the example
      # above states.
      it "renders a seconds-per-test suite in seconds rather than in thousands of milliseconds" do
        repository = create_repository(user: @user)
        sharded_run(repository, [61.0, 58.5, 74.25, 60.0], spec_counts: [8, 8, 8, 8],
                                commit_sha: "feedfacecafe0051")

        get repository_path(repository)

        expect(distribution.all("li").map { |li| li.text(normalize_ws: true) })
          .to eq(["shard 3 1m 14s 8 tests 9.3s/test",
                  "shard 1 1m 1s 8 tests 7.6s/test",
                  "shard 4 1m 8 tests 7.5s/test",
                  "shard 2 58.5s 8 tests 7.3s/test"])
      end

      # `total_specs_count` is `null: false, default: 0`, so a shard that loaded no specs is a real
      # row with a real wall clock and NO DENOMINATOR. The list says so in words rather than
      # printing `0 tests 0.0ms/test`, which would read as "these tests are free" about a shard
      # that ran none — and the division that would produce it never happens.
      it "states a zero-count shard's absence rather than dividing by it" do
        repository = create_repository(user: @user)
        sharded_run(repository, [61.0, 58.5, 74.25, 60.0], spec_counts: [5000, 5000, 0, 5000],
                                commit_sha: "feedfacecafe0052")

        get repository_path(repository)

        rows = distribution.all("li").map { |li| li.text(normalize_ws: true) }
        expect(rows.first).to eq("shard 3 1m 14s no tests reported")
        # No quotient anywhere on that row, and no zero standing in for one.
        expect(rows.first).not_to include("/test")
        expect(rows.first).not_to include("0 tests")
        # The shards that DID report a size keep theirs — the absence is scoped to the row it is a
        # fact about and does not suppress its neighbours.
        expect(rows.drop(1)).to eq(["shard 1 1m 1s 5,000 tests 12.2ms/test",
                                    "shard 4 1m 5,000 tests 12.0ms/test",
                                    "shard 2 58.5s 5,000 tests 11.7ms/test"])
      end

      # Every figure here is a fact about SHARDS. No per-test duration exists anywhere in the
      # schema, so a reader who came away thinking this page had told them which *tests* are slow
      # would have been misled by wording alone — the one failure mode this slice can cause and
      # cannot detect from arithmetic.
      it "attributes the excess to the split and never to individual tests" do
        repository = create_repository(user: @user)
        sharded_run(repository, [61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0032")

        get repository_path(repository)

        panel = overview_panel
        expect(panel).to have_no_text("slowest test", normalize_ws: true)
        expect(panel).to have_no_text("slow tests", normalize_ws: true)
        expect(panel).to have_no_text("which tests", normalize_ws: true)
      end

      # WHICH of the two things the spread is, which is the half a reader can act on. A shard runs
      # long because it holds more tests than its siblings, or because it holds the same number of
      # individually dearer ones. `duration = count x cost per test`, so the durations alone print
      # identically in both cases and the panel advised the first in both until the counts were
      # read.
      #
      # What separates them is WHICH partitioner closes the gap, never whether re-dividing can.
      # Machine time is invariant under re-partitioning and the floor is `machine / shard_count`,
      # so a duration-weighted split reaches the floor in both cases; a split by count reaches it
      # only where the per-test costs are already even. The examples below pin that distinction
      # rather than a verdict on re-dividing, because an earlier round shipped "re-dividing the
      # suite moves the wait to another shard rather than removing it" in the cost-driven branch —
      # which the floor sentence this same panel prints on the same fixture ("1m 3s is the shortest
      # wall clock any arrangement of them could have produced") flatly contradicts. A guard that
      # quotes a sentence verbatim goes green on a wrong sentence just as readily as a right one,
      # so each branch below also asserts the false form is absent.
      #
      # ELEMENT-scoped on `#shard-imbalance-cause` throughout, for the reason this whole describe
      # block states: the panel carries several sentences sharing this vocabulary, and a
      # panel-scoped matcher would go green off a neighbouring paragraph with the deciding branch
      # deleted.
      describe "which of the two causes the spread is" do
        def cause = overview_panel.find("#shard-imbalance-cause")

        # The canonical fixture: every shard holds 5,000 tests, so NONE of its 14.6% imbalance is
        # an uneven count. 74.25s over 5,000 is 14.9ms a test against 11.7ms on the fastest shard —
        # the tests in that partition are individually dearer, so a count-based partitioner has
        # nothing left to even out and hands back the same four shards. It does NOT follow that the
        # 10.8s is lost: moving 727 of the dear shard's own tests onto its siblings lands all four
        # within 0.02s of the 63.4375s floor, which is what a duration-weighted split is for. The
        # panel said "how the suite was divided" and stopped.
        it "names the per-test cost when the shards hold equal numbers of tests" do
          repository = create_repository(user: @user)
          sharded_run(repository, [61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0060")

          get repository_path(repository)

          expect(cause).to have_text(
            "That did not come from how many tests each shard got — their counts are within 0.0% " \
            "of each other. Their per-test costs spread 24.8%, from 11.7ms/test to 14.9ms/test",
            normalize_ws: true
          )
          expect(cause).to have_text(
            "a split that divides the suite evenly by test count reproduces this gap however " \
            "often it re-runs. Closing it takes a split that weighs each test's recorded " \
            "duration, or cheaper tests in that partition.",
            normalize_ws: true
          )
          # The advice the panel used to give unconditionally must not be reachable here.
          expect(cause).to have_no_text("came from how many tests each shard got:", normalize_ws: true)
          expect(cause).to have_no_text("Re-dividing the suite across the same shards", normalize_ws: true)
          # Nor the advice an earlier round of THIS slice gave: the excess is recoverable, and the
          # decomposition two paragraphs up already tells the reader so.
          expect(cause).to have_no_text("rather than removing it", normalize_ws: true)
          expect(cause).to have_no_text("moves the wait to another shard", normalize_ws: true)
        end

        # The other cause, and the one the panel always assumed. Same 4 shards, same ~254s of
        # machine time, per-test costs within 3.3% of each other — and one shard holding 6,000
        # tests against 4,800 on the smallest. Here evening the COUNTS out is the fix: with the
        # per-test costs already level, a count-based partitioner reaches the floor on its own.
        it "names the split when the counts are uneven and the per-test costs are not" do
          repository = create_repository(user: @user)
          sharded_run(repository, [72.0, 61.0, 59.04, 62.0], spec_counts: [6000, 5000, 4800, 5000],
                                  commit_sha: "feedfacecafe0061")

          get repository_path(repository)

          expect(cause).to have_text(
            "That came from how many tests each shard got: their counts spread 23.1%, while every " \
            "shard's tests cost much the same each — within 3.3%, from 12.0ms/test to 12.4ms/test. " \
            "Re-dividing the suite across the same shards is what moves this number.",
            normalize_ws: true
          )
          expect(cause).to have_no_text("That did not come from how many tests", normalize_ws: true)
          expect(cause).to have_no_text("Both halves moved", normalize_ws: true)
        end

        # Both, which is a real shape and not a tie-break: one shard holding 8,000 tests that also
        # cost 15.0ms each against 12.0ms elsewhere. Naming only the larger of the two spreads
        # would send a reader to even out the counts of a suite whose tests are also unevenly
        # priced, and the second half of their problem would survive that fix — the 75s floor here
        # is reachable, but only by a split that weighs the durations.
        it "names both when both spreads clear the floor" do
          repository = create_repository(user: @user)
          sharded_run(repository, [120.0, 60.0, 60.0, 60.0], spec_counts: [8000, 5000, 5000, 5000],
                                  commit_sha: "feedfacecafe0062")

          get repository_path(repository)

          expect(cause).to have_text(
            "Both halves moved: these shards' test counts spread 52.2% and their per-test costs " \
            "spread 23.5%, from 12.0ms/test to 15.0ms/test. Evening the counts out addresses the " \
            "first and leaves the second, so it takes a split that weighs each test's recorded " \
            "duration — or cheaper tests in the dearest partition — to close the whole gap.",
            normalize_ws: true
          )
          # Same false claim as the branch above, in its softer form: the cost spread survives
          # re-division as a property of the TESTS, not as wait. The 45s excess over this
          # fixture's 75s floor is recoverable in full by a duration-weighted split.
          expect(cause).to have_no_text("leaves the other where it is", normalize_ws: true)
        end

        # NEITHER, which is reachable and is the branch a panel that always picked a winner would
        # get wrong. The two spreads COMPOUND — `duration = count x cost` — so a 4.0% count spread
        # over a 4.0% cost spread is a 5.7% imbalance that clears the materiality floor while
        # neither of its factors does. Claiming the larger of two immaterial figures as the cause
        # would be manufacturing a finding out of noise; the panel says it cannot attribute it.
        it "claims neither cause when neither spread clears the floor" do
          repository = create_repository(user: @user)
          sharded_run(repository, [67.6, 62.5, 62.5, 62.5], spec_counts: [5200, 5000, 5000, 5000],
                                  commit_sha: "feedfacecafe0063")

          get repository_path(repository)

          # The imbalance itself is still material and still stated — this is about its cause.
          expect(decomposition).to have_text("5.7% of the wait", normalize_ws: true)
          expect(cause).to have_text(
            "Neither half accounts for it on its own: these shards' test counts are within 4.0% " \
            "of each other and their per-test costs within 4.0%.",
            normalize_ws: true
          )
          expect(cause).to have_text("so no cause is named for it here", normalize_ws: true)
          expect(cause).to have_no_text("That came from how many tests", normalize_ws: true)
          expect(cause).to have_no_text("That did not come from how many tests", normalize_ws: true)
          expect(cause).to have_no_text("Both halves moved", normalize_ws: true)
        end

        # A shard with a wall clock and no denominator. `total_specs_count` is
        # `null: false, default: 0`, so this is an ordinary row rather than a fault — and taking
        # the per-test spread over the three shards that DID report would be a fact about a subset
        # wearing a sentence about the run. The comparison is withheld with its reason, the line
        # `TestRun#suite_size_measured?` draws for the run-level column.
        it "withholds the per-test comparison when a shard reported no tests, and says why" do
          repository = create_repository(user: @user)
          sharded_run(repository, [61.0, 58.5, 74.25, 60.0], spec_counts: [5000, 5000, 0, 5000],
                                  commit_sha: "feedfacecafe0064")

          get repository_path(repository)

          expect(cause).to have_text(
            "Whether that came from uneven test counts or from individually expensive tests is " \
            "not answerable on these rows: 1 of these 4 shards reported no tests at all, so there " \
            "is a wall clock there with no denominator to divide it by.",
            normalize_ws: true
          )
          expect(cause).to have_text(
            "withheld rather than taken over the shards that did report", normalize_ws: true
          )
          # No spread figure is quoted at all — not the count spread either, which IS computable
          # here. A sentence that led with "counts spread 30.8%" while declining the other half
          # would be the same lopsided advice this slice exists to stop.
          expect(cause).to have_no_text("%", normalize_ws: true)
          expect(cause).to have_no_text("ms/test", normalize_ws: true)
        end

        # The honest limitation, on the surface rather than left for a reader to discover.
        # RSpec/Knapsack partitions are arbitrary with respect to directories, so "this partition
        # is expensive per test" is a fact about the run's division and never about a code area.
        # SPGD-114's file-shaped aggregation is the ticket that could say the latter, and it has
        # not shipped; this panel must not read as though it had.
        it "says a shard is a partition and not a code area" do
          repository = create_repository(user: @user)
          sharded_run(repository, [61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0065")

          get repository_path(repository)

          expect(cause).to have_text(
            "A shard is an arbitrary slice of the suite rather than a directory, so this says " \
            "which partition of the run was expensive and not which code.",
            normalize_ws: true
          )
          panel = overview_panel
          expect(panel).to have_no_text("directory is", normalize_ws: true)
          expect(panel).to have_no_text("which files", normalize_ws: true)
        end

        # The balanced branch has no spread to attribute a cause to, and offering one there would
        # be answering a question the numbers did not raise — the discipline the balanced branch
        # already applies when it declines the operational claim about the run.
        it "names no cause on a run whose shards are evenly matched" do
          repository = create_repository(user: @user)
          sharded_run(repository, [60.0, 60.0, 60.0, 60.0], commit_sha: "feedfacecafe0066")

          get repository_path(repository)

          panel = overview_panel
          expect(decomposition).to have_text("No shard stood out", normalize_ws: true)
          expect(panel).to have_no_css("#shard-imbalance-cause")
          # The distribution itself still renders, counts and all: the list is a description and
          # not a finding, so it is not withheld with the sentence. Tied durations fall back to
          # `id: :asc`, which is the insertion order the fixture wrote them in.
          expect(distribution.all("li").map { |li| li.text(normalize_ws: true) })
            .to eq(["shard 1 1m 5,000 tests 12.0ms/test",
                    "shard 2 1m 5,000 tests 12.0ms/test",
                    "shard 3 1m 5,000 tests 12.0ms/test",
                    "shard 4 1m 5,000 tests 12.0ms/test"])
        end

        # The gate, restated for this paragraph. Every figure it prints is derived from the same
        # rows `#wall_clock_decomposable?` guards, so an undecomposable run must not acquire a
        # cause sentence where it has no decomposition to attribute.
        it "renders no cause sentence on a run the decomposition itself is withheld from" do
          repository = create_repository(user: @user)
          sharded_run(repository, [61.0, 58.5, nil, 60.0], commit_sha: "feedfacecafe0067")

          get repository_path(repository)

          expect(overview_panel).to have_no_css("#shard-imbalance-cause")
        end
      end

      # The gate. The floor divides the machine time by the shard COUNT, so a shard missing from
      # the numerator but present in the denominator drags the floor down and pushes the excess up
      # by the same amount — the branch where a fabricated finding is easiest to produce is the one
      # that must not produce one. `[61.0, 58.5, nil, 60.0]` is the shape the API spec already uses.
      it "withholds the decomposition entirely when a shard reported no timing" do
        repository = create_repository(user: @user)
        sharded_run(repository, [61.0, 58.5, nil, 60.0], commit_sha: "feedfacecafe0033")

        get repository_path(repository)

        panel = overview_panel
        expect(panel).to have_no_css("#wall-clock-decomposition")
        expect(panel).to have_no_css("#shard-distribution")
        # Not a silent absence. A reader looking at two rendered figures is owed the reason the
        # third fact is missing, and the reason is that the arithmetic would be biased rather than
        # merely uncertain.
        expect(panel).to have_text(
          "Which shard was slowest, and how much of the wait went to uneven splitting, cannot be " \
          "answered without every shard's timing: spreading a partial machine time across all 4 " \
          "would put the floor below where it belongs and overstate the gap by exactly the same " \
          "margin. Both are withheld rather than estimated.",
          normalize_ws: true
        )
        # And no fragment of the withheld claim leaks out in any other wording. Each negative is
        # narrow enough not to match the withholding sentence itself, which necessarily names the
        # same subjects in order to say it is not answering them — a bare "of the wait" here would
        # fail against the very sentence it is meant to be checking sits alone.
        expect(panel).to have_no_text("The slowest was", normalize_ws: true)
        expect(panel).to have_no_text("shortest wall clock", normalize_ws: true)
        expect(panel).to have_no_text("% of the wait", normalize_ws: true)
        expect(panel).to have_no_text("over that floor", normalize_ws: true)
      end

      # The OTHER incompleteness, and the one the timing gate above cannot see: not a recorded row
      # with a NULL duration, but a row that has not arrived yet. Every shard present has a timing,
      # so `some_shard_untimed?` waves the run straight through while the SUM and the shard count
      # are both still climbing.
      #
      # This is the ordinary state of every sharded run for the minutes its build takes —
      # `Repository#latest_test_run` picks the row up the instant the first shard lands — so the
      # panel renders half-delivered runs routinely rather than exceptionally.
      it "withholds the decomposition while shard reports are still arriving" do
        repository = create_repository(user: @user)
        # The canonical run, caught at the moment shards 1 and 3 have POSTed and 2 and 4 have not.
        sharded_run(repository, [61.0, 74.25], names: %w[1 3], commit_sha: "feedfacecafe0044",
                                last_shard_arrived_ago: 30.seconds)

        get repository_path(repository)

        panel = overview_panel
        expect(panel).to have_no_css("#wall-clock-decomposition")
        expect(panel).to have_no_css("#shard-distribution")
        # The parent's own count is half-sized here, because `recompute_totals` derives it from the
        # shards recorded so far and only two of the four have landed. Asserted so the fixture
        # cannot drift back to writing a full-suite 20,000 on a two-shard run — a row the producer
        # cannot build, in the one example whose subject is what a half-delivered run looks like.
        expect(panel).to have_text("Tests in suite 10,000", normalize_ws: true)
        # The figures a half-delivered run would otherwise have published: a floor of 1m 8s and an
        # excess of 6.6s / 8.9%, computed over two of the four shards this run is made of, clearing
        # the materiality bar and reading exactly like a settled page. The real answer is 10.8s and
        # 14.6% across four. Pinned as literals rather than only as an absent element, because the
        # element being gone is asserted above and the point here is the NUMBERS.
        expect(panel).to have_no_text("6.6s", normalize_ws: true)
        expect(panel).to have_no_text("8.9%", normalize_ws: true)
        expect(panel).to have_no_text("The slowest was", normalize_ws: true)
        expect(panel).to have_no_text("came from how the suite was divided", normalize_ws: true)
      end

      # Withheld, but not silently. A reader looking at two rendered figures and no third fact is
      # owed the difference between "we are still waiting" and "there is nothing here to say", and
      # nothing on this panel said the former before.
      it "says the reports are still arriving rather than leaving a silent gap" do
        repository = create_repository(user: @user)
        sharded_run(repository, [61.0, 74.25], names: %w[1 3], commit_sha: "feedfacecafe0045",
                                last_shard_arrived_ago: 30.seconds)

        get repository_path(repository)

        pending_note = overview_panel.find("#wall-clock-decomposition-pending")
        expect(pending_note).to have_text(
          "A shard report arrived in the last 15 minutes, so more may still be on their way",
          normalize_ws: true
        )
        # And it says WHY that matters, in terms of the arithmetic rather than as an apology: the
        # floor and the excess are both taken over the shard count, so a run mid-delivery divides
        # by wherever it has reached.
        expect(pending_note).to have_text(
          "spreading their machine time across their own count would put the floor wherever the " \
          "run happens to have reached",
          normalize_ws: true
        )
      end

      # The gate is a quiet period and not a permanent refusal: the same rows, once the reports
      # stop coming, decompose exactly as they always did. Pinned so a mutation that simply
      # withheld from every sharded run — which would satisfy every negative expectation above —
      # cannot pass.
      it "decomposes those same rows once the reports have stopped coming" do
        repository = create_repository(user: @user)
        sharded_run(repository, [61.0, 74.25], names: %w[1 3], commit_sha: "feedfacecafe0046",
                                last_shard_arrived_ago: 16.minutes)

        get repository_path(repository)

        expect(overview_panel).to have_no_css("#wall-clock-decomposition-pending")
        expect(decomposition).to have_text("The slowest was shard 3, at 1m 14s.", normalize_ws: true)
      end

      # The other silent shape: nothing reported at all. There is no wall clock and no machine time
      # on the page to decompose, so the existing sentence already says why and a second apology
      # would be noise — but the decomposition itself must still be absent.
      it "renders no decomposition when not one shard reported a timing" do
        repository = create_repository(user: @user)
        sharded_run(repository, [nil, nil, nil, nil], commit_sha: "feedfacecafe0034")

        get repository_path(repository)

        panel = overview_panel
        expect(panel).to have_no_css("#wall-clock-decomposition")
        expect(panel).to have_no_css("#shard-distribution")
        expect(panel).to have_no_text("The slowest was", normalize_ws: true)
      end

      # `shard_id` is nullable and a nil one is an ordinary state: a client that shards without
      # exposing an index the gem recognises sends nothing to tell its slices apart, and
      # `Ingest::RunRecorder#upsert_shard` records one row per delivery for it. Numbering those
      # rows by position would hand a reader a name their CI does not use — unactionable, and
      # pointing at a different slice on the next run.
      it "calls a shard that never named itself unnamed rather than giving it an index" do
        repository = create_repository(user: @user)
        sharded_run(repository, [61.0, 58.5, 74.25, 60.0], names: ["1", "2", nil, "4"],
                                commit_sha: "feedfacecafe0035")

        get repository_path(repository)

        expect(decomposition).to have_text("The slowest was an unnamed shard, at 1m 14s.", normalize_ws: true)
        expect(distribution.all("li").map { |li| li.text(normalize_ws: true) })
          .to eq(["an unnamed shard 1m 14s 5,000 tests 14.9ms/test",
                  "shard 1 1m 1s 5,000 tests 12.2ms/test",
                  "shard 4 1m 5,000 tests 12.0ms/test",
                  "shard 2 58.5s 5,000 tests 11.7ms/test"])
        # The index it would have been given had position been mistaken for identity.
        expect(overview_panel).to have_no_text("shard 3", normalize_ws: true)
      end

      # An evenly split run should read as evenly split. The excess is still stated — a measured
      # `0.0s` is a measurement, and muting it would file "we checked, and the split was fine"
      # under "we did not check" — but it is not dressed up as time anything could recover.
      it "reads a perfectly balanced run as balanced without hiding its zero" do
        repository = create_repository(user: @user)
        sharded_run(repository, [63.4, 63.4, 63.4, 63.4], commit_sha: "feedfacecafe0036")

        get repository_path(repository)

        expect(decomposition).to have_text("No shard stood out: the longest was shard 1, at 1m 3s.",
                                           normalize_ws: true)
        expect(decomposition).to have_text(
          "This run waited 1m 3s — 0.0s over that floor, 0.0% of the wait. The shards on record " \
          "are evenly matched, so nothing in what they reported reads as a cost of how the suite " \
          "was split. That is a statement about those reports rather than about the run: a slice " \
          "that never arrived leaves no trace in them, and a missing slice is likelier to be a " \
          "slow one than a fast one.",
          normalize_ws: true
        )
        # The claim this branch is NOT entitled to make. The settling gate is a clock proxy and
        # cannot establish that a run is whole, so "the wait is the suite's own length" — an
        # unconditional operational statement about the run — would be an affirmative denial of a
        # finding the page cannot rule out. Pinned as a literal so the stronger wording cannot
        # come back: the hedged sentence above satisfies `have_text` on its own, and a mutation
        # that reverted only the final clause would otherwise still pass everything else here.
        expect(decomposition).to have_no_text("the wait is the suite's own length", normalize_ws: true)
        expect(decomposition).to have_no_text("Its shards were evenly matched", normalize_ws: true)
        # The finding wording belongs to the other branch and must not be reachable from here —
        # and neither does calling one of four shards tied to the tenth "the slowest", which is
        # true of the maximum and misleading about the shard. A reader sent to look at shard 1
        # would find it identical to its three peers.
        expect(decomposition).to have_no_text("came from how the suite was divided", normalize_ws: true)
        expect(decomposition).to have_no_text("The slowest was", normalize_ws: true)
      end

      # **The concealed runaway.** The settling gate catches a run whose shards are still arriving;
      # it cannot catch a run whose last shard arrived after the quiet period expired. Three
      # ordinary routes reach that state — a straggler slower than the window, a CI-retried shard
      # landing late, and the abandoned-mid-delivery row, which is the straggler case made
      # permanent — and the shard it hides is preferentially the SLOWEST one, because the slowest
      # shard is the one still running when the others fall quiet. The correlation is adverse.
      #
      # This is the canonical `[61.0, 58.5, 74.25, 60.0]` run minus its 74.25s runaway, quiet long
      # enough to decompose. Over the three rows on record the excess is 1.2s / 1.9% — genuinely
      # immaterial, so `wall_clock_excess_material?` routes it to the balanced branch and cannot
      # help. A 14.6% finding has become no finding, and the ONLY defence left is the wording.
      #
      # So this example is not about the arithmetic being wrong. It is about the page declining to
      # turn a partial set of reports into an operational claim about the run.
      it "does not deny an imbalance it cannot see when the runaway shard never arrived" do
        repository = create_repository(user: @user)
        sharded_run(repository, [61.0, 58.5, 60.0], names: %w[1 2 4],
                                commit_sha: "feedfacecafe0049", last_shard_arrived_ago: 16.minutes)

        get repository_path(repository)

        # It does decompose — the gate is satisfied and withholding here would mean withholding
        # from every honest 3-shard matrix, which the settling comment rejects explicitly.
        expect(decomposition).to have_text("No shard stood out: the longest was shard 1, at 1m 1s.",
                                           normalize_ws: true)
        expect(decomposition).to have_text("1.2s over that floor, 1.9% of the wait",
                                           normalize_ws: true)
        # ...but every sentence it prints is about the reports it holds, and none of them tells the
        # reader this run was fine. The run was not fine: its real answer is 10.8s / 14.6%.
        expect(decomposition).to have_text("That is a statement about those reports rather than " \
                                           "about the run", normalize_ws: true)
        expect(decomposition).to have_no_text("the wait is the suite's own length", normalize_ws: true)
      end

      # Two independent floors, and this pins the ABSOLUTE one on its own: 0.3s over the floor is
      # 21.4% of a 1.4s wait, so a relative-only threshold would call it a finding. It is smaller
      # than the scheduling jitter between two runners starting the same suite — it is not a
      # property of the split at all.
      it "does not call a sub-second gap a finding however large its share" do
        repository = create_repository(user: @user)
        sharded_run(repository, [1.0, 1.0, 1.0, 1.4], commit_sha: "feedfacecafe0037")

        get repository_path(repository)

        expect(decomposition).to have_text("No shard stood out: the longest was shard 4, at 1.4s.",
                                           normalize_ws: true)
        expect(decomposition).to have_text("0.3s over that floor, 21.4% of the wait", normalize_ws: true)
        expect(decomposition).to have_text("The shards on record are evenly matched", normalize_ws: true)
        expect(decomposition).to have_no_text("came from how the suite was divided", normalize_ws: true)
      end

      # And the RELATIVE floor on its own, which the absolute one would miss: 3s clears a second
      # comfortably, but on a ten-minute wait it is 0.5% — inside the run-to-run variance of the
      # same suite on the same shards, so re-dividing them could not reliably recover it.
      it "does not call a fraction-of-a-percent gap a finding however many seconds it is" do
        repository = create_repository(user: @user)
        sharded_run(repository, [600.0, 600.0, 600.0, 604.0], commit_sha: "feedfacecafe0038")

        get repository_path(repository)

        expect(decomposition).to have_text("No shard stood out: the longest was shard 4, at 10m 4s.",
                                           normalize_ws: true)
        expect(decomposition).to have_text("3.0s over that floor, 0.5% of the wait", normalize_ws: true)
        expect(decomposition).to have_text("The shards on record are evenly matched", normalize_ws: true)
        expect(decomposition).to have_no_text("came from how the suite was divided", normalize_ws: true)
      end

      # Clearing exactly one floor is not enough, and clearing both is — the pair above proves each
      # threshold fires, this proves the conjunction is not vacuous.
      it "does call a gap that clears both floors a finding" do
        repository = create_repository(user: @user)
        sharded_run(repository, [60.0, 60.0, 60.0, 80.0], commit_sha: "feedfacecafe0039")

        get repository_path(repository)

        expect(decomposition).to have_text(
          "15.0s of that, 18.8% of the wait, came from how the suite was divided across shards",
          normalize_ws: true
        )
        expect(decomposition).to have_no_text("Its shards were evenly matched", normalize_ws: true)
      end

      # The materiality test judges both of its operands at the precision the reader sees them at.
      # It did not always: the percent was thresholded rounded and the seconds raw, so two runs
      # straddling the one-second floor printed the identical `1.0s` and received opposite
      # verdicts — the same figure meaning two things, which is this ticket's own defect one level
      # down. Both sides of the seam, asserted together, because either alone passes under the
      # rounding it is meant to be catching.
      it "gives two runs that print the same excess the same verdict" do
        just_under = create_repository(user: @user, github_full_name: "acme/just-under")
        sharded_run(just_under, [17.0, 18.96], commit_sha: "feedfacecafe0047")
        just_over = create_repository(user: @user, github_full_name: "acme/just-over")
        sharded_run(just_over, [17.0, 19.04], commit_sha: "feedfacecafe0048")

        # 0.98s raw and 1.02s raw. Both round to the 1.0s the page prints, and both are now on the
        # same side of the floor rather than one either side of it.
        [just_under, just_over].each do |repository|
          get repository_path(repository)

          expect(decomposition).to have_text("1.0s of that", normalize_ws: true)
          expect(decomposition).to have_text("came from how the suite was divided across shards",
                                             normalize_ws: true)
          expect(decomposition).to have_no_text("Its shards were evenly matched", normalize_ws: true)
        end
      end

      # A run with one shard has no composition to decompose — its MAX *is* its SUM and the floor
      # is the wait — and a run with no shard rows is the entire corpus that predates sharding.
      # Both keep the page they have always had, on the rule `multi_shard?` already enforces.
      it "adds nothing at all to a one-shard run or a run with no shards" do
        repository = create_repository(user: @user)
        sharded_run(repository, [372.4], commit_sha: "feedfacecafe0040")
        unsharded = create_repository(user: @user, github_full_name: "acme/laptop-suite")
        unsharded.test_runs.create!(commit_sha: "feedfacecafe0041", total_specs_count: 3,
                                    annotated_specs_count: 2, duration_seconds: 372.4)

        [repository, unsharded].each do |repo|
          get repository_path(repo)

          panel = overview_panel
          expect(panel).to have_no_css("#wall-clock-decomposition")
          expect(panel).to have_no_css("#shard-distribution")
          expect(panel).to have_no_text("The slowest was", normalize_ws: true)
          expect(panel).to have_text("Total runtime 6m 12s", normalize_ws: true)
        end
      end

      # Rendering per-shard rows is exactly the shape that becomes a query per shard, and a
      # 40-shard matrix is an ordinary CI configuration rather than a pathological one.
      # `queries_against` is the shared subscriber in `spec/support/query_capture.rb` — the same one
      # the index's per-card guard and the model's preload examples use, so the failure is a count
      # and not a timeout, and three guards on the same table cannot count it three different ways.

      it "costs the same number of shard queries at 40 shards as at 3" do
        small = create_repository(user: @user, github_full_name: "acme/three-way")
        sharded_run(small, Array.new(3) { |i| 60.0 + i }, commit_sha: "feedfacecafe0042")
        large = create_repository(user: @user, github_full_name: "acme/forty-way")
        sharded_run(large, Array.new(40) { |i| 60.0 + i }, commit_sha: "feedfacecafe0043")

        small_queries = queries_against("test_run_shards") { get repository_path(small) }
        large_queries = queries_against("test_run_shards") { get repository_path(large) }

        # Both pages decompose — the 40-shard one renders forty rows — and cost the same.
        expect(decomposition).to have_text("The slowest was shard 40", normalize_ws: true)
        expect(large_queries.size).to eq(small_queries.size)
        # An absolute ceiling too: equality alone would still hold if both pages regressed to a
        # fixed-but-wasteful number of passes over the same table.
        expect(large_queries.size).to be <= 3
      end

      # The page's WHOLE query count, as an absolute integer rather than as a comparison against
      # something else the same change could move.
      #
      # The two guards above bound the shard axis: equal at 3 and at 40, and at most three passes
      # over `test_run_shards`. Neither can see a query added anywhere ELSE on the page, and
      # neither can see a fourth pass over a different table — a relative guard is only ever as
      # wide as the thing it compares. SPGD-230 widened `TestRun#shard_durations` from two columns
      # to three, and the property that makes that free is that the third column rides a `pluck`
      # the page already issued rather than adding one. A number is the only form of that claim
      # that cannot drift.
      #
      # 13 on `origin/main` and 13 after — verified by running this example against the pre-change
      # `app/models/test_run.rb`, `app/views/repositories/show.html.erb`,
      # `app/helpers/repositories_helper.rb` and
      # `app/controllers/api/v1/repositories_controller.rb`, where it passes the count and fails
      # only on the rendered-output assertion below. Re-verified that way at each base this branch
      # has been rebuilt on — a7c7421, then a2ed333, then 632f692 after SPGD-232 and SPGD-237
      # landed on this page — so the number is a property of the change rather than of the base it
      # was first measured on. Recount it deliberately if it moves: a *lower* number is as much a
      # change to explain as a higher one, since it usually means a figure stopped being read
      # rather than that a query stopped being issued.
      #
      # RECOUNTED AT 15 by SPGD-266, which added the "Slowest tests" panel: two reads of
      # `spec_observations` for the whole page — one ranking and one aggregate, neither growing
      # with the size of the suite (see `SlowestExamples`). Both are issued on this fixture even
      # though its run recorded no examples and the panel therefore renders nothing, which is the
      # honest shape of the count: the page asks, finds nothing, and says nothing. The panel's own
      # guard against the N+1 shape — a `has_many` walked in the view — is an equality across two
      # suite sizes in spec/requests/repository_slowest_examples_spec.rb, since that is the failure
      # an absolute count here cannot distinguish from an ordinary widening.
      #
      # RECOUNTED AT 16 by SPGD-275, which added the "Heaviest spec files" panel: ONE further read
      # of `spec_observations` for the whole page — a single grouped aggregate rolling the run's
      # wall clock up by file, four columns in one pass rather than a SUM followed by a COUNT (see
      # `SpecFileDurations`). Issued on this fixture for the same reason the two above are: the run
      # recorded no examples, the aggregate comes back empty and the panel renders nothing. The
      # per-file panel's own N+1 guard — the failure an absolute count here cannot tell from an
      # ordinary widening — is the equality across two suite sizes in
      # spec/requests/repository_spec_file_durations_spec.rb.
      #
      # RECOUNTED AT 17 by SPGD-292, which added the "Heaviest spec directories" panel: ONE further
      # read of `spec_observations`, a second grouped aggregate taking the same run's rows up one
      # rung to the code area (see `SpecDirectoryDurations`). Not derivable from the by-file read
      # and therefore not free: a by-file top ten shows ten files, and a directory outweighing all
      # of them can have no row in it. Issued on this fixture for the same reason the three above
      # are — the run recorded no examples, the aggregate comes back empty and the panel renders
      # nothing. Its own N+1 guard is the equality across two suite sizes in
      # spec/requests/repository_spec_file_durations_spec.rb, alongside the by-file panel's.
      #
      # QUERY-CACHE HITS ARE COUNTED, unlike the panel's other budget guards. A repeated identical
      # SELECT inside one request costs no round trip and is invisible to a `payload[:cached]`
      # filter — which is exactly how a dropped `@shard_durations ||=` would slip through, and
      # every reader this slice added reads that tuple again. Stated as a rule and not as a tally
      # on purpose: an earlier draft counted the new readers here and got the number wrong on the
      # day it was written, because a rename in the same commit is indistinguishable from an
      # addition when you count the diff instead of the readers. A rule cannot rot on the next
      # widening. Counting the hits makes this a count of READS rather than of round trips, which
      # is the property that degrades when a widened tuple acquires callers.
      it "issues exactly the queries the page issued before the shard counts were read" do
        repository = create_repository(user: @user)
        sharded_run(repository, [61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0068")

        # Warm the schema/statement caches first: the count is of the SECOND render, so
        # first-request-only work cannot land in it.
        get repository_path(repository)

        expect(count_all_queries { get repository_path(repository) }).to eq(17)
        # And the page really did render the thing being counted — an absolute count is satisfied
        # by a page that renders nothing at all.
        expect(distribution.all("li").size).to eq(4)
        expect(distribution).to have_text("5,000 tests", normalize_ws: true)
      end

      # NOT `count_queries` from spec/support/query_capture.rb: this one keeps the `payload[:cached]`
      # repeats the shared helper drops, for the reason the example above gives.
      def count_all_queries
        count = 0
        subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
          count += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION])
        end
        yield
        count
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end
    end

    it "stays visible to a member who cannot manage keys" do
      owner = create_user(github_uid: "7007", github_handle: "repo-owner")
      repository = create_repository(user: owner, github_full_name: "acme/shared-service")
      create_membership(repository: repository, user: @user)
      repository.test_runs.create!(commit_sha: "feedfacecafe0007", total_specs_count: 3,
                                   annotated_specs_count: 2)

      get repository_path(repository)

      # Suite coverage is the same class of information as the connection-health stat: a `view`
      # member needs it, and none of it is credential metadata.
      expect(overview_panel).to have_text("Not visible to SpecGuard 1", normalize_ws: true)
      expect(response.body).not_to include("api-keys")
    end
  end

  # The card's only suite signal used to be `pluralize(repository.spec_intents.size, "intent")`, and
  # no production code path writes `spec_intents` — so it read `0 intents` for every repository in
  # every real deployment, including one whose CI had ingested forty-seven runs of a
  # twelve-thousand-test suite. These examples pin the replacement: a figure that comes from real
  # ingestion, an empty state that does not impersonate a measured zero, and a bounded query count
  # so the per-card COUNT this removed cannot quietly return as a per-card SELECT.
  describe "the suite size on the repositories index" do
    # `queries_against` — every SELECT the index issues against one table, so a per-card query shows
    # up as N of them rather than as a passing test — is the shared subscriber in
    # `spec/support/query_capture.rb`.

    # The rendered copy as a reader sees it, with the ERB's own line breaks and indentation
    # collapsed — the examples below are about sentences, and a sentence assembled across two ERB
    # tags is one sentence on the page whatever the source did with whitespace.
    def page_text = Capybara.string(response.body).text.gsub(/\s+/, " ")

    # The card's cost rows, asserted against `test_run_cost_rows` — the seam `show` renders too —
    # rather than only against literals spelled out here.
    #
    # The difference matters, and it is the ordinary next change on this code. Literals on both
    # surfaces are agreement that merely HOLDS: rename "Total runtime" on the panel, update the
    # panel's own literals, and the grid's literals still pass against a card that still renders the
    # old word — two surfaces wording one column two ways, with nothing in the suite able to see it.
    # Asserting the rendered rows against the seam's output makes the card's markup, not a copy of
    # it, the thing under test. Both figures come through with their treatment, so `response.body`
    # and not `page_text` for those.
    def expect_cost_rows_from_seam(run)
      rows = ApplicationController.helpers.test_run_cost_rows(run)

      rows.each do |label, figure|
        expect(page_text).to include("#{label} #{Capybara.string(figure.to_s).text}")
        expect(response.body).to include(figure.to_s)
      end
      rows
    end

    # A run assembled from `shards` parts, built the way ingestion builds one: the parent's count
    # is DERIVED as the SUM over the shard rows written below it, never asserted beside them —
    # `Ingest::RunRecorder#recompute_totals` re-derives it after every POST. A fixture that
    # hard-coded the whole-suite figure here would build a row the producer cannot, which is
    # exactly the state these examples exist to render.
    #
    # `durations` is per-shard and derives the parent's `duration_seconds` as the MAX over the
    # rows that reported, which is what `#recompute_totals` writes — so the two cost figures a card
    # prints stand in the real relationship (MAX under SUM) rather than in one a fixture invented,
    # and a shorter list than `shards` is the ordinary half-timed run. Defaulting to `[]` leaves
    # every run with no shard timing at all, which is what the composition examples were built on.
    def sharded_run(repository, shards:, per_shard: 5_000, durations: [], **attributes)
      run = create_test_run(repository: repository, ci_run_id: "gha-#{repository.id}",
                            total_specs_count: per_shard * shards,
                            duration_seconds: durations.compact.max, **attributes)
      shards.times do |index|
        run.test_run_shards.create!(shard_id: (index + 1).to_s, total_specs_count: per_shard,
                                    annotated_specs_count: 0, duration_seconds: durations[index])
      end
      run
    end

    it "shows the ingested suite size, delimited, in place of the intent count" do
      repository = create_repository(user: @user)
      create_test_run(repository: repository, commit_sha: "feedfacecafe0101",
                      total_specs_count: 12_431, annotated_specs_count: 118)

      get repositories_path

      expect(response.body).to include("12,431 tests")
      # The badge this replaces could only ever say `0`, whatever CI had reported.
      expect(response.body).not_to match(/\d+ intents?\b/)
    end

    # Both runs land in the same instant, so this also pins the id tie-break — the same one
    # `Repository#latest_test_run` uses, which is what keeps the card and `show` naming one run.
    it "reads the newest run, not the first one ingested" do
      repository = create_repository(user: @user)
      create_test_run(repository: repository, commit_sha: "0ld", total_specs_count: 100)
      create_test_run(repository: repository, commit_sha: "new", total_specs_count: 3)

      get repositories_path

      expect(response.body).to include("3 tests")
      expect(response.body).not_to include("100 tests")
    end

    it "says a never-ingested repository has no runs, rather than showing it as an empty suite" do
      create_repository(user: @user)

      get repositories_path

      expect(response.body).to include("No runs yet")
      # `0 tests` would make "CI has never reported" byte-identical to "the suite is empty".
      expect(response.body).not_to include("0 tests")
    end

    it "loads every card's latest run in one query, however long the list is" do
      ["acme/one", "acme/two", "acme/three"].each_with_index do |full_name, index|
        create_test_run(repository: create_repository(user: @user, github_full_name: full_name),
                        commit_sha: "cafe000#{index}", total_specs_count: 10 + index)
      end

      run_queries = queries_against("test_runs") { get repositories_path }
      intent_queries = queries_against("spec_intents") { get repositories_path }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("11 tests")
      # One DISTINCT ON for the whole page — three cards must not cost three SELECTs.
      expect(run_queries.size).to eq(1)
      # ...and the per-card COUNT it replaced is gone outright, not merely folded into a join.
      expect(intent_queries).to be_empty
    end

    # The card states the basis of the figure it prints, because the grid renders N repositories at
    # once and a size with no age or composition is two wrong readings away from the truth: a
    # five-month-dead repository looks identical to one that reported an hour ago, and a sharded run
    # mid-build sits at a quarter of its own suite size with nothing marking it. `show`, the Recent
    # runs table and GET /api/v1/repository all already carry this; the card was the one surface
    # that did not.
    describe "the basis of that figure" do
      it "says how old the reading is and which branch reported it" do
        repository = create_repository(user: @user)
        create_test_run(repository: repository, commit_sha: "feedfacecafe0201",
                        total_specs_count: 12_431, branch: "main",
                        created_at: 5.months.ago)

        get repositories_path

        expect(response.body).to include("12,431 tests")
        # Without the age, this card is byte-identical to one whose CI reported an hour ago.
        expect(page_text).to include("Ingested 5 months ago on main.")
      end

      # `branch` is nullable and Ingest::Payload accepts a body without it, so the absence is a
      # client omission and has to read as one — never as a shortened sentence that looks complete.
      # Same words `show` gives an absent branch.
      it "says a branch was not reported rather than leaving it blank" do
        repository = create_repository(user: @user)
        create_test_run(repository: repository, commit_sha: "feedfacecafe0202",
                        total_specs_count: 88, branch: nil, created_at: 2.hours.ago)

        get repositories_path

        expect(page_text).to include("Ingested about 2 hours ago, branch not reported.")
      end

      # The half-delivered run: four shards' worth of suite, two of them recorded. The card prints
      # 10,000 and must say what those 10,000 cover.
      it "states what a multi-shard figure covers, in TestRun#delivery_description's words" do
        repository = create_repository(user: @user)
        run = sharded_run(repository, shards: 2, commit_sha: "feedfacecafe0203", branch: "main")

        get repositories_path

        expect(response.body).to include("10,000 tests")
        expect(page_text).to include(
          "assembled from 2 shard reports — the count above covers those, " \
          "not necessarily the whole suite"
        )
        # The one wording, shared with the Recent-runs table on `show` — not a second one that can
        # drift away from it.
        expect(page_text).to include(ApplicationController.helpers.test_run_delivery_note(run))
      end

      # The unsharded corpus has no composition at all — it arrived whole in a single POST — and a
      # grid of cards each repeating "reported in one piece" would bury the one card that has
      # something to disclose. Zero is the exclusion `shard_count.positive?` makes, and the only
      # one.
      it "says nothing about composition for a run that arrived whole" do
        whole = create_repository(user: @user, github_full_name: "acme/laptop-run")
        create_test_run(repository: whole, commit_sha: "feedfacecafe0204", total_specs_count: 7)

        get repositories_path

        expect(page_text).not_to include("reported in one piece")
        expect(page_text).not_to include("assembled from")
      end

      # And the card that is NOT excluded. A one-shard run is a four-way split whose first POST has
      # landed — a quarter of its suite, printed in the same type as a whole one — so it gets a
      # basis line at all here, and that line discloses its coverage. `multi_shard?` printed
      # nothing whatsoever on this card while `SuiteTrajectory#withheld_part_way` withheld the very
      # same row for sitting at a fraction of its own suite.
      it "states what a one-shard figure covers, the card most understating its suite" do
        single = create_repository(user: @user, github_full_name: "acme/one-shard")
        run = sharded_run(single, shards: 1, commit_sha: "feedfacecafe0205")

        get repositories_path

        expect(page_text).to include(
          "assembled from 1 shard report — the count above covers that report, " \
          "not necessarily the whole suite"
        )
        # The one wording, shared with the Recent-runs table on `show`.
        expect(page_text).to include(ApplicationController.helpers.test_run_delivery_note(run))
      end

      # A never-ingested card has no basis to state, and a "never" beside "No runs yet" would be a
      # second rendering of the same absence.
      it "states no basis for a repository that has never ingested" do
        create_repository(user: @user)

        get repositories_path

        expect(response.body).to include("No runs yet")
        expect(page_text).not_to include("Ingested")
      end

      # THE guard the ticket exists to install. The example above filters on the string
      # "test_runs", which `test_run_shards` does not contain — so a per-card `shard_count` (a
      # memoized per-instance `pick`, one query per card) sails past it green. This is the sibling
      # that catches it: every card here has a sharded latest run, so every card would ask.
      #
      # Every card also prints a MACHINE TIME, which is a SUM over the same shard rows and reached
      # through the same `pick`. That figure is asserted here rather than left to the cost examples
      # below, because a budget guard whose page never renders the expensive read is green for the
      # wrong reason — the count is only a bound on what the page ASKS, and the two assertions
      # above it are what tie it to what the page SAYS.
      it "asks the shard question once for the whole grid, however long the list is" do
        %w[acme/one acme/two acme/three acme/four].each_with_index do |full_name, index|
          sharded_run(create_repository(user: @user, github_full_name: full_name),
                      shards: 4, commit_sha: "cafe010#{index}", branch: "main",
                      durations: [61.0, 58.5, 74.25, 60.0])
        end

        shard_queries = queries_against("test_run_shards") { get repositories_path }

        expect(response).to have_http_status(:ok)
        # Every card rendered its composition, so every card really did ask the question.
        expect(page_text.scan("assembled from 4 shard reports").size).to eq(4)
        # ...and every card summed its shards' durations, which is the read with no column of its
        # own on the rows the controller selected.
        expect(page_text.scan("Machine time (all 4 added up) 4m 14s").size).to eq(4)
        # One grouped aggregate for the whole page — four cards must not cost four SELECTs.
        expect(shard_queries.size).to eq(1)

        # And the count is a bound rather than a coincidence of this fixture's size: double the
        # grid, and the same single aggregate answers all sixteen shard rows' worth of questions.
        # An absolute number asserted at one N is satisfied by a page whose cost is N/4.
        %w[acme/five acme/six acme/seven acme/eight].each_with_index do |full_name, index|
          sharded_run(create_repository(user: @user, github_full_name: full_name),
                      shards: 4, commit_sha: "cafe020#{index}", branch: "main",
                      durations: [61.0, 58.5, 74.25, 60.0])
        end

        doubled = queries_against("test_run_shards") { get repositories_path }

        expect(page_text.scan("Machine time (all 4 added up) 4m 14s").size).to eq(8)
        expect(doubled.size).to eq(1)
      end
    end

    # The grid renders N suites at once and said nothing about what any of them COST — the one
    # question a reader with eight repositories brings to a list of them, and the one their CI bill
    # is denominated in. The wall clock was already on every card object (`DISTINCT ON … test_runs.*`)
    # and printing it alone would have understated every sharded suite by up to 3.4×, so the machine
    # time rides the grid's existing grouped aggregate rather than a `pick` per card.
    describe "what each of those runs cost" do
      # The canonical 4-shard fixture: a 1m 14s wait that burned 4m 14s of machine time. The whole
      # reason a card cannot print the MAX and call it a total.
      it "names the MAX as a wall clock and puts the machine time beside it" do
        repository = create_repository(user: @user)
        run = sharded_run(repository, shards: 4, commit_sha: "feedfacecafe0301", branch: "main",
                          durations: [61.0, 58.5, 74.25, 60.0])

        get repositories_path

        expect(page_text).to include("Wall clock (slowest of 4 shards) 1m 14s")
        expect(page_text).to include("Machine time (all 4 added up) 4m 14s")
        # The label this card may never wear over a MAX: 1m 14s is not what the suite cost.
        expect(page_text).not_to include("Total runtime")
        # And those two sentences are the seam's own output, not markup inlined here. The literals
        # above pin the WORDING; this pins that the card is not free to word it its own way.
        expect_cost_rows_from_seam(run)
      end

      # A shard went silent, so BOTH figures cover less than the run: the SUM is a floor and the MAX
      # is a maximum over a subset. Each says so through the model's own coverage vocabulary rather
      # than through a phrase re-derived on this card.
      it "states how many shards a partial cost figure covers" do
        repository = create_repository(user: @user)
        run = sharded_run(repository, shards: 4, commit_sha: "feedfacecafe0302", branch: "main",
                          durations: [61.0, 58.5, nil, 60.0])

        get repositories_path

        expect(page_text).to include("Wall clock (slowest of the 3 that reported) 1m 1s")
        # "at least" — a floor, and never rendered as the total it is not.
        expect(page_text).to include("Machine time (3 of 4 added up) at least 3m")
        expect(page_text).to include(run.machine_seconds_coverage)
      end

      # The unsharded corpus — every `bundle exec rspec` that named no `ci_run_id`. For it the MAX
      # and the SUM are the same number, so a second row would print one figure twice under two
      # labels, and a "slowest of 0 shards" would be a composition the run does not have.
      it "renders a plain duration, with no shard wording, for a run with no shard rows" do
        repository = create_repository(user: @user)
        run = create_test_run(repository: repository, commit_sha: "feedfacecafe0303",
                              total_specs_count: 7, duration_seconds: 45.0)

        get repositories_path

        expect(page_text).to include("Total runtime 45.0s")
        expect(page_text).not_to include("Wall clock")
        expect(page_text).not_to include("Machine time")
        # The one-row shape is the seam's decision, not this card's — so the card cannot start
        # splitting an unsharded run into two rows while the panel keeps giving it one.
        expect(expect_cost_rows_from_seam(run).size).to eq(1)
      end

      # The property the two surfaces have to hold jointly, and the one no pair of independently
      # asserted literals can: the card and the page it links to state a run's cost in the SAME
      # words. Both render `test_run_cost_rows`, so this is a fact about the code rather than about
      # two sets of strings that happen to match — rename a label and both surfaces move together,
      # while re-spelling either one inline reddens this example.
      #
      # A run with no predecessor on its branch, so the panel has no delta to decorate its figures
      # with and the two pages' sentences are comparable character for character. The decoration is
      # exactly what the seam's `wall_clock:` / `machine_time:` arguments exist to keep page-specific,
      # and `repository_runtime_change_spec` covers it where it applies.
      it "states a run's cost in the same words as the page the card links to" do
        repository = create_repository(user: @user)
        run = sharded_run(repository, shards: 4, commit_sha: "feedfacecafe0307", branch: "main",
                          durations: [61.0, 58.5, 74.25, 60.0])

        get repositories_path
        card_rows = expect_cost_rows_from_seam(run)

        get repository_path(repository)
        panel_text = page_text

        expect(card_rows.map(&:first)).to eq(["Wall clock (slowest of 4 shards)",
                                              "Machine time (all 4 added up)"])
        card_rows.each do |label, figure|
          expect(panel_text).to include("#{label} #{Capybara.string(figure.to_s).text}")
        end
      end

      # `Ingest::Payload#validate_duration_seconds` accepts nil explicitly, so "the client sent no
      # timing" is an ordinary state — and it has to read as an absence rather than as a suite that
      # cost nothing.
      it "words a run that reported no timing as an absence, never as a zero" do
        repository = create_repository(user: @user)
        create_test_run(repository: repository, commit_sha: "feedfacecafe0304", total_specs_count: 7)

        get repositories_path

        expect(page_text).to include("Total runtime not reported")
        expect(page_text).not_to include("0.0s")
      end

      # The other half of that distinction, and the one a `.to_i` anywhere on the priming path
      # would destroy: four shards recorded, not one of them timed. `machine_seconds` is nil — no
      # shard reported — and a primed `0` here would print a suite that cost nothing.
      #
      # The query count is asserted on THIS fixture and not only on the four-card guard above,
      # because nil is the value a truthiness memo cannot hold: `@machine_seconds ||= …` would
      # accept the primed nil and then re-ask for it on the first read, and a card whose shards
      # reported no timing is the only shape that exercises it. One SELECT covers the whole page.
      it "words a sharded run whose shards reported no timing as an absence too" do
        repository = create_repository(user: @user)
        sharded_run(repository, shards: 4, commit_sha: "feedfacecafe0305", branch: "main")

        shard_queries = queries_against("test_run_shards") { get repositories_path }

        expect(page_text).to include("Machine time (0 of 4 added up) not reported")
        expect(page_text).not_to include("0.0s")
        expect(shard_queries.size).to eq(1)
      end

      # And the state that absence is not: shards that really were measured and really did add up
      # to nothing. `machine_seconds_reported?` is a `nil?` check and not a `present?` one for
      # exactly this row, and the SUM must survive priming as the `0.0` it is.
      it "renders a genuinely measured zero as the measurement it is" do
        repository = create_repository(user: @user)
        sharded_run(repository, shards: 2, commit_sha: "feedfacecafe0306", branch: "main",
                    durations: [0.0, 0.0])

        get repositories_path

        expect(page_text).to include("Machine time (all 2 added up) 0.0s")
        expect(page_text).not_to include("Machine time (all 2 added up) not reported")
      end

      # A card with no run has no cost to state, on the same rule its missing basis line follows: a
      # "not reported" beside "No runs yet" would be a second rendering of one absence.
      it "states no cost for a repository that has never ingested" do
        create_repository(user: @user)

        get repositories_path

        expect(response.body).to include("No runs yet")
        expect(page_text).not_to include("Total runtime")
        expect(page_text).not_to include("Wall clock")
        expect(page_text).not_to include("Machine time")
      end
    end
  end

  describe "renaming a repository" do
    it "updates the name without touching keys, runs or intents" do
      repository = create_repository(user: @user, github_full_name: "acme/billing-servce")
      repository.api_keys.create!(name: "CI")
      repository.test_runs.create!(commit_sha: "a" * 40, branch: "main")
      create_spec_intent(repository: repository)

      patch repository_path(repository), params: { repository: { github_full_name: "acme/billing-service" } }

      expect(response).to redirect_to(repository_path(repository))
      expect(repository.reload.github_full_name).to eq("acme/billing-service")

      # The entire point of the feature: renaming keeps everything the Remove workaround destroys.
      expect(repository.api_keys.count).to eq(1)
      expect(repository.test_runs.count).to eq(1)
      expect(repository.spec_intents.count).to eq(1)
    end

    it "re-derives the display name and normalizes a pasted GitHub URL" do
      repository = create_repository(user: @user, github_full_name: "acme/old-name")

      patch repository_path(repository),
            params: { repository: { github_full_name: "https://github.com/acme/renamed.git" } }

      expect(repository.reload.github_full_name).to eq("acme/renamed")
      expect(repository.name).to eq("renamed")
    end

    it "re-renders the edit form when the new name is not org/repo" do
      repository = create_repository(user: @user)

      patch repository_path(repository), params: { repository: { github_full_name: "nonsense" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("must look like org/repo")
      expect(repository.reload.github_full_name).to eq("acme/billing-service")

      # The rejected input belongs in the form field only. The breadcrumb and title identify
      # the record, so they must still name the repository as it is actually stored.
      expect(response.body).to include("acme/billing-service")
    end

    it "rejects a name already taken by another user rather than raising" do
      create_repository(user: create_user(github_uid: "9999", github_handle: "someone-else"),
                        github_full_name: "other/repo")
      repository = create_repository(user: @user)

      patch repository_path(repository), params: { repository: { github_full_name: "other/repo" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(repository.reload.github_full_name).to eq("acme/billing-service")
    end

    it "accepts a save that leaves the name unchanged" do
      repository = create_repository(user: @user)

      patch repository_path(repository), params: { repository: { github_full_name: "acme/billing-service" } }

      expect(response).to redirect_to(repository_path(repository))
      expect(flash[:notice]).not_to include("Renamed")
    end

    it "confirms the rename in the flash when the name actually changed" do
      repository = create_repository(user: @user, github_full_name: "acme/billing-servce")

      patch repository_path(repository), params: { repository: { github_full_name: "acme/billing-service" } }

      expect(flash[:notice]).to eq("Renamed to acme/billing-service.")
    end

    it "links to the rename form from the repository page" do
      repository = create_repository(user: @user)

      get repository_path(repository)

      expect(response.body).to include(edit_repository_path(repository))
    end

    it "renders the rename form" do
      repository = create_repository(user: @user)

      get edit_repository_path(repository)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('name="repository[github_full_name]"')
    end

    it "does not let a user rename another user's repository" do
      other = create_repository(user: create_user(github_uid: "9999", github_handle: "someone-else"),
                                github_full_name: "other/repo")

      patch repository_path(other), params: { repository: { github_full_name: "acme/stolen" } }

      expect(response).to have_http_status(:not_found)
      expect(other.reload.github_full_name).to eq("other/repo")

      get edit_repository_path(other)
      expect(response).to have_http_status(:not_found)
    end
  end
end
