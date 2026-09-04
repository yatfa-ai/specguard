# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Repository registration and API keys", type: :request do
  before { @user = sign_in_via_github }

  # The rendered copy as a reader sees it, with the ERB's own line breaks and indentation
  # collapsed — the examples below are about sentences, and a sentence assembled across two ERB
  # tags is one sentence on the page whatever the source did with whitespace.
  def page_text = Capybara.string(response.body).text.gsub(/\s+/, " ")

  # @intent: {"entity": "Repository", "action": "register repository", "behavior": "a signed-in user posting a valid org/repo name creates exactly one Repository owned by that user and redirects to its show page", "layer": "request"}
  it "registers a GitHub repository for the signed-in user" do
    expect {
      post repositories_path, params: { repository: { github_full_name: "acme/billing-service" } }
    }.to change(Repository, :count).by(1)

    repository = Repository.last
    expect(repository.user).to eq(@user)
    expect(response).to redirect_to(repository_path(repository))
  end

  # @intent: {"entity": "Repository", "action": "reject malformed name", "behavior": "posting github_full_name nonsense answers 422 unprocessable content and re-renders the form with the message must look like org/repo", "layer": "request"}
  it "re-renders the form when the name is not org/repo" do
    post repositories_path, params: { repository: { github_full_name: "nonsense" } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("must look like org/repo")
  end

  # @intent: {"entity": "ApiKey", "action": "reveal token once", "behavior": "the reveal page shows the raw sgk_ token whose digest is what was stored, a plain reload never shows it again, and the persistent panel keeps only the agent prompt naming the CI secret SPECGUARD_API_KEY", "layer": "request"}
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

    # ...but what the key is *for* must survive the flash, naming the secret and never a value.
    # The persistent panel cannot inline a token — only a digest is stored — so what it carries is
    # the same agent prompt with the CI secret's NAME where the reveal put the credential itself.
    expect(response.body).to include("Wire this repository up")
    expect(response.body).to include("read it from the CI secret named SPECGUARD_API_KEY")
    expect(response.body).not_to match(/sgk_[A-Za-z0-9_-]{20,}/)
  end

  # @intent: {"entity": "ApiKey", "action": "hand over curl", "behavior": "at the reveal moment the page includes a complete curl with the real Bearer token inlined, an agent prompt carrying the token and the integration guide URL, and copy saying the check is a connectivity check and not the integration", "layer": "request"}
  it "hands back a ready-to-run curl carrying the just-minted token" do
    repository = register_repository

    post repository_api_keys_path(repository)
    follow_redirect!

    raw_token = response.body[/sgk_[A-Za-z0-9_-]{20,}/]
    expect(raw_token).to be_present
    # The whole point: at the reveal moment the command is complete, so there is nothing for the
    # user to substitute while the only copy of the secret is on screen.
    expect(response.body).to include(%(curl -H "Authorization: Bearer #{raw_token}" #{api_v1_repository_url}))

    # ...and it really is the credential — the same value the API will accept, not a look-alike.
    expect(ApiKey.last.token_digest).to eq(ApiKey.digest(raw_token))

    # ...and the curl is no longer presented AS the integration. That is what the prompt beside it
    # is for, and at the reveal moment it too is complete: the real token is inlined, so it works
    # exactly as pasted. Both halves are asserted, because a prompt that lost the credential would
    # still contain every other line of this block.
    expect(response.body).to include("Wire the repository up")
    expect(response.body).to include("Read #{integration_guide_url}")
    expect(response.body).to include("API key:     #{raw_token}")
    expect(response.body).to include("Store it as a CI secret named SPECGUARD_API_KEY")

    # And the auth check says what it is, so a reader who runs it and gets a 200 does not conclude
    # the project is wired up.
    expect(page_text).to include("This is a connectivity check and not the integration")
  end

  # What replaced "Connect this repository". The panel that stood here taught the READ endpoint —
  # `GET /api/v1/repository` under the heading "Endpoint", and a curl against it under "Try it" —
  # which sends SpecGuard nothing. A reader who followed it got a 200 and no telemetry, and nothing
  # on the page mentioned the write endpoint, the client gem, the linter or the annotation protocol.
  #
  # The negatives are as load-bearing as the positives: this example fails if the auth-check curl
  # comes back to this surface wearing new copy.
  # @intent: {"entity": "ApiKey", "action": "render agent prompt", "behavior": "a repository with an existing CI key renders the Wire this repository up prompt naming the repo, the integration guide URL and the SPECGUARD_API_KEY secret, with no auth-check curl and no Connect this repository copy", "layer": "request"}
  it "hands over a copy-paste agent prompt, not an auth-check curl, with no flash present" do
    repository = create_repository(user: @user)
    repository.api_keys.create!(name: "CI")

    get repository_path(repository)

    expect(response.body).to include("Wire this repository up")
    # The three things the guide cannot know and this panel must therefore say.
    expect(response.body).to include("Repository:  #{repository.github_full_name}")
    expect(response.body).to include("Read #{integration_guide_url}")
    expect(response.body).to include("read it from the CI secret named SPECGUARD_API_KEY")

    expect(response.body).not_to include("Connect this repository")
    expect(response.body).not_to include(%(curl -H "Authorization: Bearer &lt;token&gt;" #{api_v1_repository_url}))
  end

  # The guide is the whole of the documentation this panel delegates to, so the pointer to it has to
  # be there for a reader who is not handing anything to an agent — including one who cannot mint a
  # credential and therefore never sees the prompt at all.
  # @intent: {"entity": "Repository", "action": "link integration guide", "behavior": "the show page includes a link to the integration guide path both for a repository holding a CI key and for one with none", "layer": "request"}
  it "links to the integration guide whether or not the repository has a key" do
    with_key = create_repository(user: @user, github_full_name: "acme/with-key")
    with_key.api_keys.create!(name: "CI")
    without_key = create_repository(user: @user, github_full_name: "acme/without-key")

    get repository_path(with_key)
    expect(response.body).to include(%(href="#{integration_guide_path}"))

    get repository_path(without_key)
    expect(response.body).to include(%(href="#{integration_guide_path}"))
  end

  # @intent: {"entity": "Repository", "action": "point at key minting", "behavior": "when the repository has no keys the show page keeps the Wire this repository up panel, drops the read-it-from-the-secret line, and adds This repository has no API key yet with a Mint a key link anchored to the api-keys panel", "layer": "request"}
  it "points at minting a key instead of a prompt for a credential that does not exist when the repository has none" do
    repository = create_repository(user: @user)

    get repository_path(repository)

    # A prompt telling an agent to read a CI secret nobody has created is an instruction whose only
    # possible outcome is a 401. The pointer to minting one is what this branch owes the reader.
    expect(repository.api_keys).to be_empty
    expect(response.body).to include("Wire this repository up")
    expect(response.body).not_to include("read it from the CI secret named SPECGUARD_API_KEY")

    # The opening sentence is shared with the branch a member without `keys.manage` gets, so it
    # cannot tell the two apart on its own. What this branch owes the reader is the POINTER — the
    # ticket's "the guidance directs them to mint a key first" — so pin that sentence itself.
    expect(page_text).to include("This repository has no API key yet")
    expect(page_text).to include("Mint a key in API keys below")

    # ...and the pointer has to point somewhere: #api-keys is the id of the keys panel below, which
    # is gated on the same `keys.manage` this branch is, so the link never dangles for its reader.
    expect(response.body).to include(%(<a href="#api-keys"))
    expect(response.body).to include(%(id="api-keys"))
  end

  # @intent: {"entity": "Repository", "action": "name whom to ask", "behavior": "a member who cannot mint keys sees This repository has no API key yet plus a sentence asking the owner by display name to mint one, and no Mint a key link", "layer": "request"}
  it "tells a member who cannot mint keys who to ask for one" do
    owner = create_user(github_uid: "8008", github_handle: "octo-owner")
    repository = create_repository(user: owner)
    create_membership(repository: repository, user: @user)

    get repository_path(repository)

    # The handle alone proves nothing here: the Overview panel renders an "Owner" row for view
    # members too, so `include("octo-owner")` passes even if this branch never names anyone. Pin
    # the sentence, which puts the handle in the one position that means "ask THIS person".
    expect(page_text).to include("This repository has no API key yet")
    expect(page_text).to include("Ask #{owner.display_name} to mint one")

    # The other keyless branch's pointer is `keys.manage`-only — and it is positively asserted in
    # the owner example above, so this negative is load-bearing: it fails if the two branches
    # collapse into one, rather than passing because neither says anything.
    expect(response.body).not_to include("Mint a key in")
    expect(response.body).not_to include(%(<a href="#api-keys"))
  end

  # @intent: {"entity": "ApiKey", "action": "report not connected", "behavior": "with keys present but no last_used_at anywhere the show page reads Not connected yet and never Last request", "layer": "request"}
  it "reports 'not connected' while no API key has ever been used" do
    repository = create_repository(user: @user)
    repository.api_keys.create!(name: "CI")

    get repository_path(repository)

    expect(repository.api_keys.maximum(:last_used_at)).to be_nil
    expect(response.body).to include("Not connected yet")
    expect(response.body).not_to include("Last request")
  end

  # @intent: {"entity": "ApiKey", "action": "report last request", "behavior": "once any key has been used the page matches Last request some time ago and no longer reads Not connected yet", "layer": "request"}
  it "reports the last request once any API key has been used" do
    repository = create_repository(user: @user)
    repository.api_keys.create!(name: "Idle")
    repository.api_keys.create!(name: "CI").touch_last_used!

    get repository_path(repository)

    expect(response.body).to match(/Last request .+ ago\./)
    expect(response.body).not_to include("Not connected yet")
  end

  # A rotation retires a token with no grace window and deliberately leaves `last_used_at` standing
  # (SPGD-352 — it is the key's history). Until the replacement reaches the CI secrets store every
  # delivery 401s, and a 401 resolves no repository and writes no row, so nothing in the rejection
  # figures can see it. This stat can, because it need not observe the 401: it owns the row and
  # stamped the instant the token was retired.
  describe "the connection indicator after a rotation" do
    def connect_panel = Capybara.string(response.body).find("#connection-indicator")

    # Collapsed for the reason the rejected-deliveries spec states: these sentences are assembled
    # across several ERB lines, so an assertion against a literal space would pin the indentation.
    def connect_text = connect_panel.text.squish

    let(:repository) { create_repository(user: @user) }

    # @intent: {"entity": "ApiKey", "action": "stop claiming connected", "behavior": "after a regeneration with no further authenticated request the connection indicator drops Connected and loses its success tone", "layer": "request"}
    it "stops reading Connected while the replacement has not authenticated" do
      key = repository.api_keys.create!(name: "CI")
      key.touch_last_used!

      key.regenerate!
      get repository_path(repository)

      # The defect verbatim: before this, exactly here, the page said "Connected" in success tone
      # with a hint dating a token that had stopped existing.
      expect(key.reload).to be_rotated_and_unused
      expect(connect_text).not_to include("Connected")
      expect(connect_panel).to have_no_css(".text-app-success")
    end

    # @intent: {"entity": "ApiKey", "action": "name rotation remedy", "behavior": "a stranded key renders Key rotated, not yet in use, says the replacement token has not reached CI, and names in the singular that nothing has authenticated since the key was regenerated", "layer": "request"}
    it "names the rotation and the remedy, rather than only withholding the good news" do
      repository.api_keys.create!(name: "CI").tap(&:touch_last_used!).regenerate!

      get repository_path(repository)

      # A stat that went quiet would leave the reader with a pipeline failing for a reason nothing
      # on the page names. The remedy is off this page — a secret in another system — so the copy
      # has to say which one.
      expect(connect_text).to include("Key rotated, not yet in use")
      expect(connect_text).to match(/replacement token has not reached CI/i)
      # The SINGULAR shape, and the control for the multi-key example below: with one stranded key
      # the sentence names that key's own rotation, and an implementation stuck on the plural
      # branch would report "1 keys" here.
      expect(connect_text).to include("Nothing has authenticated since the key was regenerated")
    end

    # @intent: {"entity": "ApiKey", "action": "date oldest rotation", "behavior": "with two stranded keys the indicator reads 2 keys have been regenerated and dates the oldest rotation via time_ago_in_words, never the less-than-a-minute age of the newest one", "layer": "request"}
    it "dates the OLDEST rotation, and says how many, once more than one key is stranded" do
      # The fixture that tells the candidate aggregates apart. On a one-key set `max`, `min` and
      # `first` are indistinguishable, so every example above is blind to the choice.
      #
      # It also fixes what the sentence may claim. Each stranded key satisfies the rule against its
      # OWN rotation, so the only thing true of all of them is that none has authenticated since it
      # was regenerated — "nothing has authenticated since <newest rotation>" is true but is the
      # most reassuring true reading available, and "<oldest rotation>" in that same sentence is
      # false outright. Hence a sentence that changes shape with the set.
      #
      # Created nightly-FIRST deliberately: `show` orders the collection `created_at: :desc`, so
      # unsorted `.first` would be the main key's one-minute-old rotation and the last assertion
      # here catches a dropped `.sort` as well as a `max`.
      nightly = repository.api_keys.create!(name: "Nightly")
      nightly.touch_last_used!
      nightly.regenerate!
      nightly.update_columns(last_used_at: 6.days.ago, rotated_at: 5.days.ago)

      main = repository.api_keys.create!(name: "Main")
      main.touch_last_used!
      main.regenerate!

      get repository_path(repository)

      # Both really are stranded — asserted through the seam, so this cannot pass on a fixture
      # where only one of them reached the state the copy is describing.
      expect(repository.api_keys.reload).to all(be_rotated_and_unused)
      expect(connect_text).to include("2 keys have been regenerated")
      # Against the seam's own figure rather than a literal date, so this pins the SOURCE.
      expect(connect_text).to include(
        "the oldest was regenerated " \
        "#{ActionController::Base.helpers.time_ago_in_words(nightly.reload.rotated_at)} ago"
      )
      # The reading `max` produced: a reader with a five-day-dead nightly pipeline told the event
      # was a minute old.
      expect(connect_text).not_to include("less than a minute ago")
    end

    # @intent: {"entity": "ApiKey", "action": "recover connected reading", "behavior": "the first authenticated request after a rotation restores Connected with the success tone and drops the Key rotated branch", "layer": "request"}
    it "reads Connected again on the first request that authenticates with the replacement" do
      key = repository.api_keys.create!(name: "CI")
      key.touch_last_used!
      key.regenerate!

      key.touch_last_used!
      get repository_path(repository)

      # One request, no window to expire and no threshold to cross — the same recovery rule
      # `RejectedIngests#refusing?` follows.
      expect(key.reload).not_to be_rotated_and_unused
      expect(connect_text).to include("Connected")
      expect(connect_text).not_to include("Key rotated")
      expect(connect_panel).to have_css(".text-app-success")
    end

    # @intent: {"entity": "ApiKey", "action": "leave unrotated unchanged", "behavior": "keys used but never rotated still read Connected in success tone with no Key rotated wording", "layer": "request"}
    it "leaves a repository whose keys have never been rotated exactly as it was" do
      # The control for all three examples above. Same page, same success tone, and it is what
      # catches an implementation that reports the rotated state over keys nobody has touched.
      repository.api_keys.create!(name: "CI").touch_last_used!

      get repository_path(repository)

      expect(connect_text).to include("Connected")
      expect(connect_text).not_to include("Key rotated")
      expect(connect_panel).to have_css(".text-app-success")
    end

    # @intent: {"entity": "ApiKey", "action": "date surviving key", "behavior": "with one live and one stranded key the panel reads Connected and dates Last request from the live key's own last_used_at rather than the stranded key's fresher timestamp", "layer": "request"}
    it "reports an age belonging to a key that still exists, not the newest age on the table" do
      # The mixed table, and the case a whole-repository maximum gets wrong on its own: the FRESHEST
      # `last_used_at` here belongs to the stranded key. A stat reading the maximum would render
      # "Connected" — correctly, since one key does work — over a hint dating the retired token.
      live = repository.api_keys.create!(name: "Live")
      live.update_columns(last_used_at: 3.days.ago)
      stranded = repository.api_keys.create!(name: "Stranded")
      stranded.touch_last_used!
      stranded.regenerate!

      get repository_path(repository)

      expect(connect_text).to include("Connected")
      # Asserted as the age of the live key rather than as a literal, so this pins the SOURCE of the
      # figure and not a phrasing.
      expect(connect_text).to include(
        "Last request #{ActionController::Base.helpers.time_ago_in_words(live.reload.last_used_at)} ago"
      )
      expect(connect_text).not_to include("Last request less than a minute ago")
    end

    # @intent: {"entity": "ApiKey", "action": "prefer refusal wording", "behavior": "a refused POST to the ingest API followed by a rotation renders Deliveries refused ahead of any Key rotated sentence", "layer": "request"}
    it "keeps a refused delivery ahead of the rotation, being the more specific state" do
      key = repository.api_keys.create!(name: "CI")
      post "/api/v1/ingest",
           params: { specs: [] }.to_json,
           headers: { "Content-Type" => "application/json",
                      "Authorization" => "Bearer #{key.raw_token}" }
      key.regenerate!

      get repository_path(repository)

      # Both are true of this repository, and the branch order decides which is reported. A refusal
      # is a pipeline doing work and having it thrown away; a rotation is work not started yet.
      expect(key.reload).to be_rotated_and_unused
      expect(connect_text).to include("Deliveries refused")
      expect(connect_text).not_to include("Key rotated")
    end

    # @intent: {"entity": "ApiKey", "action": "keep not-connected wording", "behavior": "a key rotated before ever being used still reads Not connected yet rather than borrowing the Key rotated branch", "layer": "request"}
    it "still reads 'not connected yet' when the only key was rotated before ever being used" do
      # Rotated-and-unused is true of this key, and the stat must NOT borrow the rotation branch for
      # it: nothing has ever authenticated here, which is a different sentence and the honest one.
      repository.api_keys.create!(name: "CI").regenerate!

      get repository_path(repository)

      expect(connect_text).to include("Not connected yet")
      expect(connect_text).not_to include("Key rotated")
    end
  end

  # SPGD-804 made revocation a retirement, and the retirement is what makes this state observable:
  # the row survives with `revoked_at` stamped, a refused presentation of the dead token stamps
  # `last_refused_at` on it, and the page can name the fix instead of reading "Not connected yet"
  # in neutral tone over a pipeline that is 401ing right now. Every fixture walks the REAL path —
  # revoke, present the dead token at the API (which stamps through the actual failure path), then
  # render the page — because a hand-written `last_refused_at` would leave these examples
  # asserting against a state no production code path produces.
  describe "the connection indicator after a revocation" do
    def connect_panel = Capybara.string(response.body).find("#connection-indicator")

    def connect_text = connect_panel.text.squish

    let(:repository) { create_repository(user: @user) }

    # Present the dead token so the platform records the refusal the page reports. Returns nothing;
    # the stamp is the effect.
    def present_revoked_token(token)
      get "/api/v1/repository", headers: { "Authorization" => "Bearer #{token}" }
      expect(response).to have_http_status(:unauthorized)
    end

    # @intent: {"entity": "ApiKey", "action": "name the revocation remedy", "behavior": "with every key revoked and the dead token still being presented, the indicator reads Revoked key still presented, dates the revocation and the last refusal, and names the fix — never Not connected yet", "layer": "request"}
    it "names the revoked key and the fix instead of reading 'Not connected yet'" do
      key = repository.api_keys.create!(name: "CI")
      key.touch_last_used! # months of history, as the ticket's premise describes
      revoked_token = key.raw_token
      key.revoke!
      present_revoked_token(revoked_token)

      get repository_path(repository)

      expect(connect_text).to include("Revoked key still presented")
      expect(connect_text).to match(/A key you revoked .+ ago is still being presented/i)
      expect(connect_text).to match(/last seen .+ ago/i)
      expect(connect_text).to include("Update the secret wherever it is stored")
      expect(connect_text).not_to include("Not connected yet")
      # `:error`, on the refusing state's own rule — work is being destroyed, not merely absent.
      expect(connect_panel).to have_css(".text-app-error")
    end

    # The honest bound: a revoked key the platform never saw presented again is NOT the state —
    # nothing is synthesized. CI having gone quiet on top of the revocation falls to the
    # not-connected branch, whose note must not claim a repository that was never wired up.
    # @intent: {"entity": "ApiKey", "action": "not invent a presentation", "behavior": "a revoked key never presented again keeps Not connected yet with the no-active-key note rather than the revoked-presentation state", "layer": "request"}
    it "does not invent a presentation for a key revoked and never presented again" do
      repository.api_keys.create!(name: "CI").revoke!

      get repository_path(repository)

      expect(connect_text).to include("Not connected yet")
      expect(connect_text).to include("No active API key has been used")
      expect(connect_text).not_to include("Revoked key still presented")
    end

    # The ordering rule, exercised against the state the old order would report: a live key works,
    # but a revoked token is still arriving from somewhere — that stale credential is the exact
    # finding, and "Connected" would bury it.
    # @intent: {"entity": "ApiKey", "action": "rank revoked over connected", "behavior": "with one live working key and one presented revoked key the indicator reports the revoked state and never Connected", "layer": "request"}
    it "reports the presented revocation ahead of Connected, being the more specific state" do
      keeper = repository.api_keys.create!(name: "Prod")
      keeper.touch_last_used!
      stale = repository.api_keys.create!(name: "Old CI")
      stale_token = stale.raw_token
      stale.revoke!
      present_revoked_token(stale_token)

      get repository_path(repository)

      expect(keeper.reload).not_to be_revoked
      expect(connect_text).to include("Revoked key still presented")
      expect(connect_text).not_to include("Connected")
    end

    # Refusals on record predate the revocation problem and describe a pipeline that was at least
    # getting in; a pipeline presenting a revoked token cannot complete a delivery at all. The
    # revoked state is the newer, stronger fact, and the page must not send the owner to debug
    # payloads while every request is dying at the door.
    # @intent: {"entity": "ApiKey", "action": "rank revoked over refused", "behavior": "a refused delivery on record followed by a presented revocation renders the revoked state and never Deliveries refused", "layer": "request"}
    it "keeps the presented revocation ahead of the refused deliveries" do
      key = repository.api_keys.create!(name: "CI")
      post "/api/v1/ingest",
           params: { specs: [] }.to_json,
           headers: { "Content-Type" => "application/json",
                      "Authorization" => "Bearer #{key.raw_token}" }
      revoked_token = key.raw_token
      key.revoke!
      present_revoked_token(revoked_token)

      get repository_path(repository)

      expect(connect_text).to include("Revoked key still presented")
      expect(connect_text).not_to include("Deliveries refused")
    end

    # The plural shape, on the rotation branch's own rule: count the keys, date the OLDEST
    # revocation (the only date true of all of them at once), and report the freshest refusal.
    # @intent: {"entity": "ApiKey", "action": "date oldest revocation", "behavior": "with two presented revoked keys the indicator reads 2 keys you revoked, dates the oldest revocation and reports the freshest refusal", "layer": "request"}
    it "counts the keys and dates the oldest revocation once more than one is presented" do
      nightly = repository.api_keys.create!(name: "Nightly")
      nightly.revoke!
      nightly.update_columns(revoked_at: 5.days.ago, last_refused_at: 2.days.ago)
      main = repository.api_keys.create!(name: "Main")
      main.revoke!
      main.update_columns(revoked_at: 1.minute.ago, last_refused_at: 30.seconds.ago)
      # Both were "presented": the stamps are hand-placed here only to fix the AGES the assertions
      # name, which the real failure path would write at Time.current. (The presentation path
      # itself is exercised end to end in the examples above.)

      get repository_path(repository)

      expect(connect_text).to include("2 keys you revoked are still being presented")
      expect(connect_text).to include(
        "the first was revoked " \
        "#{ActionController::Base.helpers.time_ago_in_words(nightly.reload.revoked_at)} ago"
      )
      expect(connect_text).to include(
        "the latest attempt was seen " \
        "#{ActionController::Base.helpers.time_ago_in_words(main.reload.last_refused_at)} ago"
      )
      # The oldest, not the newest: a reader with a five-day-dead pipeline must not be told the
      # revocation was a minute ago.
      expect(connect_text).not_to include("the first was revoked less than a minute ago")
    end

    # The keys table and the wire-up panel read the LIVE half of the partition. A revoked row must
    # not render a second Revoke button, and the panel must not point CI at a credential that no
    # longer authenticates — while the page as a whole still names what happened.
    # @intent: {"entity": "ApiKey", "action": "gate the table on live keys", "behavior": "a revoked key renders no row in the keys table, the wire-up panel falls to its mint-a-key branch, and the count badge never appears", "layer": "request"}
    it "lists only live keys in the table while the header reports the revocation" do
      key = repository.api_keys.create!(name: "CI")
      revoked_token = key.raw_token
      key.revoke!
      present_revoked_token(revoked_token)

      get repository_path(repository)

      # The header names the revocation (the state the examples above pin); what must NOT happen
      # is the revoked row rendering in the table below it, offering a second Revoke on a key that
      # is already retired.
      expect(connect_text).to include("Revoked key still presented")
      expect(response.body).not_to include(key.token_hint)
      expect(response.body).to include("This repository has no API key yet")
    end
  end

  # @intent: {"entity": "ApiKey", "action": "offer name field", "behavior": "the keys panel posts an api_key name input and renders a Created column for each key row", "layer": "request"}
  it "offers a name field when minting a key, and shows when each key was created" do
    repository = register_repository
    repository.api_keys.create!(name: "Staging")

    get repository_path(repository)

    # The control must actually post a name — a bare button is what made every key identical.
    expect(response.body).to include('name="api_key[name]"')
    expect(response.body).to include("Created")
  end

  # @intent: {"entity": "ApiKey", "action": "name key from field", "behavior": "posting api_key name Staging creates exactly one key named Staging and the redirected page shows the name", "layer": "request"}
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

  # @intent: {"entity": "ApiKey", "action": "default blank name", "behavior": "posting an empty name still creates the key with the default name Default CI Key", "layer": "request"}
  it "falls back to the default name when the name field is left blank" do
    repository = register_repository

    post repository_api_keys_path(repository), params: { api_key: { name: "" } }

    expect(ApiKey.last.name).to eq("Default CI Key")
  end

  # @intent: {"entity": "ApiKey", "action": "default missing params", "behavior": "posting to the keys endpoint with no params at all creates the key with the default name Default CI Key", "layer": "request"}
  it "falls back to the default name when no params are sent at all" do
    repository = register_repository

    post repository_api_keys_path(repository)

    expect(ApiKey.last.name).to eq("Default CI Key")
  end

  # @intent: {"entity": "ApiKey", "action": "revoke key", "behavior": "the delete retires exactly one ApiKey row — the row survives with revoked_at stamped, so the count is unchanged and the live count drops by one", "layer": "request"}
  it "revokes an API key" do
    repository = register_repository
    post repository_api_keys_path(repository)
    api_key = ApiKey.last

    # A retirement since SPGD-804: the row is retained and stamped, which is what makes a revoked
    # token reportable; what the delete removes is the key's ability to authenticate.
    expect {
      delete repository_api_key_path(repository, api_key)
    }.not_to change(ApiKey, :count)

    expect(api_key.reload.revoked_at).to be_present
    expect(repository.api_keys.live.count).to eq(0)
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

    # @intent: {"entity": "ApiKey", "action": "attribute minted key", "behavior": "posting a mint records the signed-in user as created_by_user on the new ApiKey row", "layer": "request"}
    it "attributes a newly minted key to the signed-in user" do
      repository = register_repository

      post repository_api_keys_path(repository), params: { api_key: { name: "Staging" } }

      # Revoking is a hard delete with no audit row, so attribution recorded here is the only
      # attribution there will ever be.
      expect(ApiKey.last.created_by_user).to eq(@user)
    end

    # @intent: {"entity": "ApiKey", "action": "name colleague minter", "behavior": "on the owner's page the row for a key minted by a keys.manage member shows that member's handle rather than the signed-in user's", "layer": "request"}
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

    # @intent: {"entity": "ApiKey", "action": "fall back to unknown", "behavior": "a key with no recorded creator renders 200 with its row reading Unknown beside the Revoke control", "layer": "request"}
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

      # @intent: {"entity": "ApiKey", "action": "mark ex-colleague key", "behavior": "a key minted by a member whose membership was later destroyed still names the handle and adds no longer has access to the attribution", "layer": "request"}
      it "names the ex-colleague and marks the key their revoked access left behind" do
        repository = create_repository(user: @user)
        revoked_colleague(repository, handle: "revoked-dev", uid: "5005", key_name: "Their CI")

        get repository_path(repository)

        # The handle still has to be there — the marker is added to the attribution, not swapped
        # in for it. Without the handle the owner cannot tell *whose* key they are about to revoke.
        expect(api_key_row("Their CI")).to have_text("revoked-dev")
        expect(api_key_row("Their CI")).to have_text("no longer has access")
      end

      # @intent: {"entity": "ApiKey", "action": "skip false markers", "behavior": "owner, current-member and unattributed keys render no no-longer-has-access marker, the unattributed one reading Unknown", "layer": "request"}
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

      # @intent: {"entity": "ApiKey", "action": "batch membership lookup", "behavior": "adding a second distinct creator and three more key rows leaves the page's query count equal to the baseline, so the membership question is asked once for the whole table", "layer": "request"}
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

    # @intent: {"entity": "ApiKey", "action": "add creator column", "behavior": "the header row is exactly Name, Key, Created by, Created, Last used and the blank revoke column, and each row still shows its token hint", "layer": "request"}
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

  # @intent: {"entity": "Repository", "action": "hide foreign repository", "behavior": "requesting another user's repository answers 404 not found", "layer": "request"}
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

    # ⭐ THIS EXAMPLE USED TO PIN THE CLAIM SPGD-711 CORRECTED, and it is kept pointed at the same
    # run so the correction is legible as one. Three specs, two annotated, no per-example rows.
    #
    # The panel used to render `3 - 2` as "Not visible to SpecGuard 1" and say "SpecGuard cannot see
    # the other 1 test." It cannot know that. The counters carry a `status` and nothing about a
    # description, and whether SpecGuard can READ a test is a question only the rows can answer — so
    # on a run that stored none, the panel now declines to answer it and says so.
    #
    # What it still prints, unchanged and in the same words: the suite size, the @intent count and
    # the ratio. Those are the counters' own facts and are the one thing this change was required to
    # leave answering exactly as it did.
    # @intent: {"entity": "TestRun", "action": "show suite figures", "behavior": "a 3-example run with 2 annotated prints Tests in suite 3, Carrying an @intent 2 and the 66.7 percent share, and no longer claims Not visible to SpecGuard or to see the other test", "layer": "request"}
    it "shows the suite denominator and the @intent share, and no longer guesses what it cannot see" do
      repository = create_repository(user: @user)
      repository.test_runs.create!(commit_sha: "feedfacecafe0001", branch: "main",
                                   total_specs_count: 3, annotated_specs_count: 2)

      get repository_path(repository)

      panel = overview_panel
      # The denominator, which was stored and API-returned but rendered nowhere before this.
      expect(panel).to have_text("Tests in suite 3", normalize_ws: true)
      expect(panel).to have_text("Carrying an @intent 2", normalize_ws: true)
      # ...and the ratio never appears without the denominator it was computed over.
      expect(panel).to have_text("66.7% — 2 of 3 tests carry an @intent.", normalize_ws: true)
      # The claim it can no longer make about this run, and the honest replacement.
      expect(panel).to have_no_text("Not visible to SpecGuard")
      expect(panel).to have_no_text("SpecGuard cannot see the other")
      expect(panel).to have_text("nothing here to say how much of the rest it can make out — not " \
                                 "that it can make out none of it", normalize_ws: true)
    end

    # ⭐ THE SAME RUN WITH ITS PER-EXAMPLE ROWS, which is where the three readings can be told apart
    # — and where the sentence the panel used to print is finally true of something.
    #
    # Four rows: one annotated, two whose descriptions derive, one that reads as nothing. The
    # subtraction the panel used to render would have called all three of the last ones invisible.
    # @intent: {"entity": "TestRun", "action": "split reading kinds", "behavior": "from four recorded rows the panel prints Carrying an @intent 1, Read from the description 2 and Not readable by SpecGuard 1, says it reads 3 and cannot read the remaining 1, and keeps the adoption share at 25.0 percent", "layer": "request"}
    it "names what it read from the descriptions, and reserves 'cannot read' for what it could not" do
      repository = create_repository(user: @user, github_full_name: "acme/readable-suite")
      Ingest::RunRecorder.record(
        repository,
        { commit_sha: "feedfacecafe0711", branch: "main", total_specs_count: 4,
          annotated_specs_count: 1, duration_seconds: 60.0 },
        specs: [annotated_spec(file_path: "spec/models/invoice_spec.rb", line_number: 4),
                unannotated_spec(file_path: "spec/models/order_spec.rb", line_number: 9,
                                 name: "Order#settle clears the outstanding balance"),
                unannotated_spec(file_path: "spec/models/refund_spec.rb", line_number: 12,
                                 name: "Refund#issue returns the money to the payer"),
                unannotated_spec(file_path: "spec/requests/checkout_spec.rb", line_number: 3,
                                 name: "Checkout rejects an expired card")].map(&:deep_stringify_keys)
      )

      get repository_path(repository)

      panel = overview_panel
      expect(panel).to have_text("Carrying an @intent 1", normalize_ws: true)
      expect(panel).to have_text("Read from the description 2", normalize_ws: true)
      expect(panel).to have_text("Not readable by SpecGuard 1", normalize_ws: true)
      # The sentence, with its denominator taken from the rows rather than from the counters — and
      # with what a derived reading LACKS said in the same breath, because the honest version of
      # "derived" is the one that does not sell it as an annotation.
      expect(panel).to have_text("SpecGuard reads 3 — the annotated ones and 2 more from the " \
                                 "test's own description — and cannot read the remaining 1",
                                 normalize_ws: true)
      expect(panel).to have_text("it carries no preconditions", normalize_ws: true)
      # ⭐ AND THE ADOPTION METRIC IS UNMOVED. Three of four examples are READ; one of four carries an
      # @intent. A change that let the second figure drift toward the first would have redefined the
      # product's own coverage metric, which is the one thing this correction may not do.
      expect(panel).to have_text("25.0% — 1 of 4 tests carry an @intent.", normalize_ws: true)
    end

    # ⭐ THE DESTINATION, AND THE SENTENCE THAT MAY NOT DESCRIBE AN EMPTY SET.
    #
    # Every other branch of this paragraph discloses what a derived reading COSTS — no preconditions,
    # a layer inferred from the directory — because every other branch has derived readings to
    # qualify. On a fully-authored suite there are none: "and the rest from the test's own
    # description" would name an empty set, and the caveat behind it would warn the reader about the
    # weakness of a reading nothing on the page rests on. The panel branches on `recorded?` and on
    # `unreadable?` with exactly this care; this is the third state it was missing.
    # @intent: {"entity": "TestRun", "action": "skip derived wording", "behavior": "a fully annotated 2-example run says every one of the 2 carries an @intent, prints 100.0 percent, and renders neither the description-derived clause nor the no-preconditions caveat", "layer": "request"}
    it "says nothing about derived readings on a suite that has none" do
      repository = create_repository(user: @user, github_full_name: "acme/fully-annotated")
      Ingest::RunRecorder.record(
        repository,
        { commit_sha: "feedfacecafe0712", branch: "main", total_specs_count: 2,
          annotated_specs_count: 2, duration_seconds: 12.0 },
        specs: [annotated_spec(file_path: "spec/models/invoice_spec.rb", line_number: 4),
                annotated_spec(file_path: "spec/models/invoice_spec.rb", line_number: 9)]
          .map(&:deep_stringify_keys)
      )

      get repository_path(repository)

      panel = overview_panel
      expect(panel).to have_text("Every one of the 2 examples this run recorded carries an @intent " \
                                 "its author wrote", normalize_ws: true)
      # The two clauses that may not appear over a suite with nothing derived in it: the empty set,
      # and the warning about a reading that is not on this page.
      expect(panel).to have_no_text("the rest from the test's own description")
      expect(panel).to have_no_text("it carries no preconditions")
      # And the state above it is still stated in full, so this is a shorter sentence rather than a
      # quieter one.
      expect(panel).to have_text("100.0% — 2 of 2 tests carry an @intent.", normalize_ws: true)
    end

    # The middle branch, which had no example of its own either: derived readings and NO unreadable
    # population. The "cannot read the remaining N" sentence may not be rendered at N = 0 — that is
    # what `IntentReadings#unreadable?` exists for — and the derived caveat still must be, because
    # here there IS something derived to qualify.
    # @intent: {"entity": "TestRun", "action": "qualify derived readings", "behavior": "with one annotated and one derived example the panel keeps the derived caveat and the no-preconditions note, never prints cannot read the remaining, and holds the share at 50.0 percent", "layer": "request"}
    it "qualifies its derived readings on a suite with no unreadable examples" do
      repository = create_repository(user: @user, github_full_name: "acme/all-derived")
      Ingest::RunRecorder.record(
        repository,
        { commit_sha: "feedfacecafe0713", branch: "main", total_specs_count: 2,
          annotated_specs_count: 1, duration_seconds: 12.0 },
        specs: [annotated_spec(file_path: "spec/models/invoice_spec.rb", line_number: 4),
                unannotated_spec(file_path: "spec/models/order_spec.rb", line_number: 9,
                                 name: "Order#settle clears the outstanding balance")]
          .map(&:deep_stringify_keys)
      )

      get repository_path(repository)

      panel = overview_panel
      expect(panel).to have_text("the rest from the test's own description", normalize_ws: true)
      expect(panel).to have_text("it carries no preconditions", normalize_ws: true)
      expect(panel).to have_no_text("cannot read the remaining")
      # Unmoved, on the run where a derived reading is half the suite — the figure a reader asks
      # "how much of this suite has a human-written intent" of.
      expect(panel).to have_text("50.0% — 1 of 2 tests carry an @intent.", normalize_ws: true)
    end


    # ⭐ THE FIFTH STATE, AND THE ONE THE TICKET IS MOST ABOUT: rows recorded, NOTHING derived, and
    # an unreadable population. It reached the `unreadable?` arm — the one arm written on the
    # assumption that there is a derived population to describe — and so the suite SpecGuard can
    # read none of was handed "SpecGuard reads 0 — the annotated ones and 0 more from the test's own
    # description", plus a caveat about the weakness of an inference that was never made. Both are
    # the objections the fully-authored branch below already writes out for itself; this is the arm
    # they had not been applied to.
    #
    # It is not an exotic run. Derivation is deliberately narrow — `Entity#action` or `Entity.action`
    # plus a behavior — so a suite written with string `describe`s throughout derives NOTHING, run
    # wide, and that repository is exactly the "genuinely unreadable" population the ticket names and
    # requires be "reported plainly as such".
    # @intent: {"entity": "TestRun", "action": "report unreadable suite", "behavior": "when nothing derived the panel says SpecGuard cannot read 2, every one of them that carries no @intent, drops every derived-reading clause, and still prints the 0.0 percent share from the run's counters", "layer": "request"}
    it "reports an unreadable suite plainly when nothing derived at all" do
      repository = create_repository(user: @user, github_full_name: "acme/prose-described")
      Ingest::RunRecorder.record(
        repository,
        { commit_sha: "feedfacecafe0714", branch: "main", total_specs_count: 2,
          annotated_specs_count: 0, duration_seconds: 12.0 },
        specs: [unannotated_spec(file_path: "spec/requests/registration_spec.rb", line_number: 4,
                                 name: "user registration sends a welcome email"),
                unannotated_spec(file_path: "spec/requests/registration_spec.rb", line_number: 9,
                                 name: "user registration rejects a duplicate handle")]
          .map(&:deep_stringify_keys)
      )

      get repository_path(repository)

      panel = overview_panel
      expect(panel).to have_text("SpecGuard cannot read 2 — every one of them that carries no " \
                                 "@intent", normalize_ws: true)
      expect(panel).to have_text("do not give it an entity, an action and a behavior",
                                 normalize_ws: true)
      # ⭐ ASSERTED CLAUSE BY CLAUSE rather than against the whole sentence: one `have_no_text` over
      # the paragraph would go green again on any caption that merely reworded it. Each of these is a
      # claim the old arm made about an empty set.
      expect(panel).to have_no_text("more from the test's own description")
      expect(panel).to have_no_text("it carries no preconditions")
      expect(panel).to have_no_text("layer is inferred from the directory")
      # And the guard that this state sits next to: a run whose scanner fell over lands NEAR here,
      # and must still lead with the @intent share off the run's own counters.
      expect(panel).to have_text("0.0% — 0 of 2 tests carry an @intent.", normalize_ws: true)
      expect(panel).to have_text("Read from the description 0", normalize_ws: true)
    end

    # The same arm with an AUTHORED population in it, which is where a sentence written only for the
    # all-dark run above would give itself away: `unreadable` here is 1 of 2, not all of it, so
    # "every one of them that carries no @intent" has to be a narrowing rather than a synonym for
    # the whole run. Same arm, both sub-cases, so nothing about the wording can be true by accident.
    # @intent: {"entity": "TestRun", "action": "narrow unreadable claim", "behavior": "with one annotated and one unreadable row the panel reads Of the 2 examples this run recorded, SpecGuard cannot read 1, drops the derived clauses, and keeps the share at 50.0 percent", "layer": "request"}
    it "narrows the unreadable claim to the unannotated rows when some carry an @intent" do
      repository = create_repository(user: @user, github_full_name: "acme/half-authored-dark")
      Ingest::RunRecorder.record(
        repository,
        { commit_sha: "feedfacecafe0715", branch: "main", total_specs_count: 2,
          annotated_specs_count: 1, duration_seconds: 12.0 },
        specs: [annotated_spec(file_path: "spec/models/invoice_spec.rb", line_number: 4),
                unannotated_spec(file_path: "spec/requests/registration_spec.rb", line_number: 9,
                                 name: "user registration sends a welcome email")]
          .map(&:deep_stringify_keys)
      )

      get repository_path(repository)

      panel = overview_panel
      expect(panel).to have_text("Of the 2 examples this run recorded, SpecGuard cannot read 1",
                                 normalize_ws: true)
      expect(panel).to have_no_text("more from the test's own description")
      expect(panel).to have_no_text("it carries no preconditions")
      expect(panel).to have_text("50.0% — 1 of 2 tests carry an @intent.", normalize_ws: true)
    end

    # @intent: {"entity": "TestRun", "action": "expose meter counts", "behavior": "the meter element carries aria-valuenow 2.0 and aria-valuemax 3.0, the real counts, rather than a percentage against 100", "layer": "request"}
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

    # @intent: {"entity": "TestRun", "action": "name measured run", "behavior": "the panel states Measured on feedfac (release/2.1), naming the shortened sha and the branch of the run behind the figures", "layer": "request"}
    it "names the run the figures were measured on" do
      repository = create_repository(user: @user)
      repository.test_runs.create!(commit_sha: "feedfacecafe0003", branch: "release/2.1",
                                   total_specs_count: 3, annotated_specs_count: 2)

      get repository_path(repository)

      # A stale run is a stale denominator, so the reader has to be able to see which run it is.
      expect(overview_panel).to have_text("Measured on feedfac (release/2.1)", normalize_ws: true)
    end

    # @intent: {"entity": "TestRun", "action": "read newest run", "behavior": "with an old 100-test run and a newer 3-test run the panel prints Tests in suite 3 and not 100", "layer": "request"}
    it "reads the newest run, not the first one ingested" do
      repository = create_repository(user: @user)
      repository.test_runs.create!(commit_sha: "0ld", total_specs_count: 100, annotated_specs_count: 1)
      repository.test_runs.create!(commit_sha: "new", total_specs_count: 3, annotated_specs_count: 2)

      get repository_path(repository)

      expect(overview_panel).to have_text("Tests in suite 3", normalize_ws: true)
      expect(overview_panel).not_to have_text("Tests in suite 100", normalize_ws: true)
    end

    # @intent: {"entity": "TestRun", "action": "render empty state", "behavior": "a repository with no runs shows No CI run has reported yet with no percent figure and no meter element", "layer": "request"}
    it "shows an empty state — never 0% — for a repository whose CI has never reported" do
      repository = create_repository(user: @user)

      get repository_path(repository)

      panel = overview_panel
      expect(panel).to have_text("No CI run has reported yet", normalize_ws: true)
      # The defect this replaces: never-ingested rendered byte-identically to measured-zero.
      expect(panel).to have_no_text("0%", normalize_ws: true)
      expect(panel).to have_no_css("[role='meter']")
    end

    # @intent: {"entity": "TestRun", "action": "distinguish measured zero", "behavior": "a run of 3 specs with none annotated prints 0.0 percent, 0 of 3, with the nothing-here-to-say caveat rather than the never-reported empty state", "layer": "request"}
    it "distinguishes a run that measured zero annotations from one that never happened" do
      repository = create_repository(user: @user)
      repository.test_runs.create!(commit_sha: "feedfacecafe0004", total_specs_count: 3,
                                   annotated_specs_count: 0)

      get repository_path(repository)

      panel = overview_panel
      # This repository genuinely has 0% — and says so with its denominator attached.
      expect(panel).to have_text("0.0% — 0 of 3 tests carry an @intent.", normalize_ws: true)
      # It says nothing about what it can READ of the other three, because this run stored no
      # per-example rows and the counters do not carry a description. Before SPGD-711 the panel
      # asserted it could see none of them, which was a claim it had no evidence for either way.
      expect(panel).to have_text("nothing here to say how much of the rest it can make out",
                                 normalize_ws: true)
      expect(panel).to have_no_text("No CI run has reported yet", normalize_ws: true)
    end

    # @intent: {"entity": "TestRun", "action": "word empty test run", "behavior": "a run reporting zero specs says reported no tests at all, suppresses the percent figure and the meter, and still prints Tests in suite 0", "layer": "request"}
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

    # @intent: {"entity": "TestRun", "action": "label searchable intents", "behavior": "the figure reads Searchable intents 0 with its not-a-count-of-tests note, and the old Spec intents label is gone", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "render wall clock", "behavior": "372.4 seconds renders as Total runtime 6m 12s in a non-muted span and never as 372.4s", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "word unreported timing", "behavior": "a nil duration renders Total runtime not reported in muted styling, never as 0.0s or 0s", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "print measured zero", "behavior": "a genuinely measured 0.0 renders Total runtime 0.0s styled as a measurement, not the not-reported wording", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "render timing without tests", "behavior": "a run with zero specs and 92 seconds still prints Total runtime 1m 32s while the meter and any percent figure stay suppressed", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "omit timing figure", "behavior": "a never-ingested repository renders no Total runtime text at all", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "name wall clock", "behavior": "the 4-shard fixture prints Wall clock (slowest of 4 shards) 1m 14s beside Machine time (all 4 added up) 4m 14s, with no Total runtime label and the machine figure un-muted", "layer": "request"}
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

      # @intent: {"entity": "TestRun", "action": "state shard assembly", "behavior": "the panel says Assembled from 4 shard reports, notes they are not necessarily 4 distinct CI jobs, and carries both the suite-cost and slowest-single-shard claims", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "floor partial timing", "behavior": "one silent shard yields Machine time (3 of 4 added up) at least 2m 15s and Wall clock (slowest of the 3 that reported) 1m, with prose naming the 1 silent shard in the singular", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "pluralize silent shards", "behavior": "two silent shards yield Machine time (2 of 4 added up) at least 1m 45s, Wall clock (slowest of the 2 that reported) 1m, and prose saying 2 silent shards", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "word singular coverage", "behavior": "exactly one timed shard of two yields Wall clock (slowest of the 1 that reported) 1m 30s, Machine time (1 of 2 added up) at least 1m 30s, and prose saying 1 silent shard", "layer": "request"}
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

      # @intent: {"entity": "TestRun", "action": "report absent timing", "behavior": "no shard reporting a timing prints both figures as not reported in muted styling, says the run's cost is unknown rather than zero, and never prints at least or 0.0s", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "print zero machine time", "behavior": "two shards measuring 0.0 seconds print Machine time (all 2 added up) 0.0s as a real measurement, not the not-reported wording", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "render one-shard plainly", "behavior": "a single 372.4-second shard renders Total runtime 6m 12s with no Machine time, Wall clock or Assembled from wording", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "render unsharded plainly", "behavior": "a run with no shard rows renders Total runtime 6m 12s with no Machine time or Assembled from wording", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "decompose canonical run", "behavior": "on the 61/58.5/74.25/60 fixture the decomposition names The slowest was shard 3 at 1m 14s, the 1m 3s floor nothing can go under, and 10.8s or 14.6 percent of the wait coming from the split", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "list shard distribution", "behavior": "the list renders all four shards slowest-first with duration, test count and quotient each, from shard 3 1m 14s 5,000 tests 14.9ms/test down to shard 2 58.5s 11.7ms/test", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "resolve per-test unit", "behavior": "the per-test figure renders as 14.9ms/test and never as 0.0s, which the shared seconds formatter would round it to", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "scale per-test unit", "behavior": "with 8 tests per shard the rows read 9.3s/test down to 7.3s/test rather than thousands of milliseconds", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "word zero-count shard", "behavior": "a timed shard holding zero specs reads no tests reported with no quotient and no 0 tests, while its neighbours keep their 5,000 tests and ms-per-test figures", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "attribute excess to split", "behavior": "the page never says slowest test, slow tests or which tests, because every figure is about shards and the split rather than individual tests", "layer": "request"}
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
        # @intent: {"entity": "TestRun", "action": "name per-test cause", "behavior": "on equal 5,000-count shards the cause says the counts are within 0.0 percent while per-test costs spread 24.8 percent from 11.7ms/test to 14.9ms/test, so closing the gap takes a duration-weighed split", "layer": "request"}
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
        # @intent: {"entity": "TestRun", "action": "name count cause", "behavior": "with counts spreading 23.1 percent and costs within 3.3 percent, the cause says the split came from how many tests each shard got and that re-dividing is what moves the number", "layer": "request"}
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
        # @intent: {"entity": "TestRun", "action": "name both causes", "behavior": "with counts spreading 52.2 percent and per-test costs 23.5 percent, the cause says both halves moved and closing the whole gap takes a split that weighs recorded durations", "layer": "request"}
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
        # @intent: {"entity": "TestRun", "action": "claim no cause", "behavior": "a 5.7 percent imbalance whose counts and costs each sit within 4.0 percent still states the imbalance but says no cause is named for it here, and neither cause sentence appears", "layer": "request"}
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
        # @intent: {"entity": "TestRun", "action": "withhold per-test comparison", "behavior": "one shard reporting no tests makes the cause say the question is not answerable on these rows and is withheld rather than taken over the shards that did report, quoting no spread figure at all", "layer": "request"}
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
        # @intent: {"entity": "TestRun", "action": "call shard a partition", "behavior": "the cause says a shard is an arbitrary slice of the suite rather than a directory, and the page never mentions directories or which files", "layer": "request"}
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
        # @intent: {"entity": "TestRun", "action": "skip cause on balance", "behavior": "four evenly matched 60-second shards read No shard stood out, render no cause element, and still list all four distribution rows", "layer": "request"}
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
        # @intent: {"entity": "TestRun", "action": "gate cause on decomposition", "behavior": "a run whose decomposition is withheld for an untimed shard renders no cause element either", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "withhold decomposition", "behavior": "an untimed shard removes both decomposition elements and prints the sentence saying a partial machine time would bias the floor and overstate the gap, so both are withheld", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "withhold mid-delivery", "behavior": "while only two of four shards have landed the decomposition is withheld, the suite counter reads 10,000, and the partial 6.6s and 8.9 percent figures appear nowhere", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "note arriving reports", "behavior": "a pending note says a shard report arrived in the last 15 minutes so more may still be coming, and that spreading their machine time across their own count would park the floor wherever the run has reached", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "decompose after settling", "behavior": "the same two shard rows, quiet for 16 minutes, decompose again naming The slowest was shard 3 at 1m 14s, with no pending note", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "render no decomposition", "behavior": "a run where not one shard reported a timing renders neither decomposition element and no slowest-was sentence", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "name unnamed shard", "behavior": "a shard whose client sent no shard_id is called an unnamed shard in both the decomposition and the list, and the positional index it would have carried appears nowhere", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "read balanced zero", "behavior": "four 63.4-second shards read No shard stood out with 0.0s over that floor and 0.0 percent of the wait, hedged as a statement about the reports on record and never that the wait is the suite's own length", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "not deny concealed runaway", "behavior": "the canonical run minus its 74.25s runaway still decomposes as No shard stood out with 1.2s over that floor and 1.9 percent of the wait, while every sentence stays about the reports on record and never claims the wait is the suite's own length", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "ignore sub-second gap", "behavior": "a 0.3s gap that is 21.4 percent of a 1.4s wait reads evenly matched rather than a finding", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "ignore tiny share", "behavior": "a 3.0s gap that is 0.5 percent of a ten-minute wait reads evenly matched rather than a finding", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "flag material gap", "behavior": "a gap clearing both floors is named as such, with 15.0s of the wait at 18.8 percent coming from how the suite was divided across shards", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "verdict at printed precision", "behavior": "excesses of 0.98s and 1.02s raw both print 1.0s and both take the finding verdict, rather than straddling the one-second floor on opposite sides", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "skip degenerate runs", "behavior": "a one-shard run and a no-shard run render neither decomposition element nor any slowest-shard sentence, only Total runtime 6m 12s", "layer": "request"}
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

      # @intent: {"entity": "TestRun", "action": "bound shard queries", "behavior": "the page issues the same number of test_run_shards queries for a 40-shard run as for a 3-shard one, and at most three in absolute terms", "layer": "request"}
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
      # RECOUNTED AT 19 by SPGD-344, which added the "Descriptions this run recorded more than once"
      # panel: TWO further reads of `spec_observations`. The first groups the same run's rows by
      # DESCRIPTION — a grain no read on this page could reach, because the only two `GROUP BY name`
      # reads in the application are narrowed to failures and therefore see nothing on a green run.
      # The second counts the rows carrying no description at all, and it is a second round trip
      # rather than a window on the first because the first excludes those rows in its WHERE clause:
      # a window over it could never have counted what it dropped. It is also the panel's Vacuous
      # Green gate — a run that wrote no rows and a run whose every description is unique return the
      # identical empty ranking, and only a row count tells them apart. Both are issued on this
      # fixture for the same reason the four above are: the run recorded no examples, both come back
      # empty and the panel renders nothing. Its own N+1 guard — the failure an absolute count here
      # cannot tell from an ordinary widening — is the equality across two suite sizes in
      # spec/requests/repository_repeated_descriptions_spec.rb.
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
      # RECOUNTED AT 20 by SPGD-563, which added the "Rejected deliveries" panel: ONE further read,
      # and the first on this page that is not of `spec_observations` — the newest
      # `ingest_rejections` rows of this repository, bounded by the panel's limit. SPGD-601 made
      # that query ask for ONE row more than the panel renders, so the extra row can answer
      # "is there more history than this page shows" without a second count; the LIMIT value moved
      # and the number of round trips did not, which is the property this budget pins.
      #
      # Unlike the six reads above, this one is NOT issued because an empty aggregate comes back
      # empty on this fixture. It is issued because the panel is deliberately ungated: a repository
      # that has never had a run accepted is the case where every delivery it made was refused,
      # which is exactly when the list matters, so it cannot be hidden behind `@latest_test_run`
      # the way the per-example panels are. The query runs on every render of this page and is
      # meant to.
      #
      # It needs no companion N+1 guard of the kind the panels above point at, and the reason is
      # structural rather than a measurement: the rows are materialised with `.to_a` under a LIMIT,
      # and every cell the panel renders (`occurred_at`, `reasons`, `reported_client`) is a column
      # on the row. The view touches no association, so there is no per-row question for a second
      # round trip to answer — which is also why this stays one query whether the repository has
      # one refusal or the fifty the retention rule bounds it to.
      #
      # RECOUNTED AT 19 by SPGD-614, and DOWNWARDS, which is the direction that needs the louder
      # note: a budget that falls silently is how a page loses a query it was supposed to issue.
      # The Connection stat now needs a SECOND figure beside "when did this repository last reach
      # the API" — the same maximum restricted to keys still carrying the token that stamped them,
      # since a rotated key's use belongs to a credential that no longer exists — and one loaded
      # key collection answers both, so two claims about one set of rows cannot disagree and cost
      # one query between them instead of one each.
      #
      # The arithmetic on THIS fixture, which registers no keys, since -1 is a net and reading it
      # as a single dropped query is how the next recount goes wrong: TWO round trips went away
      # (`api_keys.maximum(:last_used_at)`, and the `SELECT 1` that `has_api_keys` cost on an
      # unloaded relation) and ONE arrived (the key collection itself, which this page did not load
      # at all when there was no table to render). On a repository that HAS keys the same change
      # reads -2, because the collection was being loaded for the table regardless. Neither figure
      # includes the `created_by_user` preload: that is bought inside the `keys.manage` gate only,
      # and the example below is what holds it there.
      #
      # RECOUNTED AT 20 by SPGD-649, which added the "Where the unannotated tests are" panel: ONE
      # further read of `spec_observations`, the same run's rows grouped by AREA on the ANNOTATION
      # axis. Not derivable from the by-duration rollup SPGD-292 counted above, which groups the
      # identical population: that one ranks by wall clock and its coverage figure is TIMING
      # coverage, so an area of four hundred fast unannotated examples heads this list and sits
      # nowhere near the head of that one. One grouped aggregate carrying its own `COUNT(*) OVER ()`,
      # so the caption's population figure rides back with the rows rather than costing a second
      # round trip — see `UnannotatedDirectories`.
      #
      # Issued on this fixture for the reason the `spec_observations` reads above are: the run
      # recorded no examples, the aggregate comes back empty, and the panel renders its
      # "no per-example detail" state rather than a ranking. It is gated on `@latest_test_run` like
      # every other per-example panel, so the count on a never-ingested repository is unchanged —
      # the half this fixture cannot see, pinned in
      # spec/requests/repository_unannotated_directories_spec.rb, which also carries the panel's own
      # N+1 guard: the equality across two suite sizes that an absolute count here cannot tell from
      # an ordinary widening.
      # @intent: {"entity": "TestRun", "action": "pin page query budget", "behavior": "the second render of the show page issues exactly 22 queries and genuinely renders four distribution rows of 5,000 tests", "layer": "request"}
      it "issues exactly the queries the page issued before the shard counts were read" do
        repository = create_repository(user: @user)
        sharded_run(repository, [61.0, 58.5, 74.25, 60.0], commit_sha: "feedfacecafe0068")

        # Warm the schema/statement caches first: the count is of the SECOND render, so
        # first-request-only work cannot land in it.
        get repository_path(repository)

        # 22 rather than the 20 this budget carried at the merge base, and it is TWO independent
        # +1s that happened to land in the same rebaseline rather than one recount done twice.
        # Keeping both paragraphs is deliberate: each names a different read, and a merge that kept
        # only one would leave the surviving comment silently accounting for a query it does not
        # describe.
        #
        # +1 from SPGD-816: `run_anchor`'s retention disclosure adds exactly ONE indexed read to
        # the page — `TestRun#observations_retained?` picks the anchored run's branch boundary off
        # `index_test_runs_on_repository_id_and_branch_and_created_at`. ONE for the whole page, not
        # one per row, and that is the property worth stating: the boundary is evaluated for the
        # ANCHORED RUN only and no panel row asks it anything, so this number does not move with
        # the suite, the window, or the run count. The invariance examples that pin it live beside
        # the window budgets in spec/requests/api/v1/repository_latest_run_spec.rb.
        #
        # +1 from SPGD-711: `TestRun#intent_readings` is one aggregate over the latest run's rows,
        # served on every page load because the Overview's reading rows and the sentence beside
        # them both read it. Memoized on the run, so it is one query and not one per reader.
        #
        # Rebaselined by two rather than carved out, because this is an ABSOLUTE page budget:
        # hiding a real new query behind a filter would be the regression this count exists to
        # catch.
        expect(count_all_queries { get repository_path(repository) }).to eq(22)
        # And the page really did render the thing being counted — an absolute count is satisfied
        # by a page that renders nothing at all.
        expect(distribution.all("li").size).to eq(4)
        expect(distribution).to have_text("5,000 tests", normalize_ws: true)
      end

      # THE SAME BUDGET FOR THE OTHER VIEWER CLASS, and the reason it needs its own example: the
      # count above is the OWNER's, and from the key load onwards the two paths differ.
      #
      # The keys table names the creator of every row, so `show` preloads `created_by_user` — but
      # that table is a `keys.manage` surface end to end, and a view-only member renders none of
      # it. When SPGD-614 moved the key collection to `.to_a` (the Connection stat needs the rows
      # themselves, not an aggregate over them), the preload came along and was issued for that
      # member and thrown away: a join bought for a render that cannot read it, on the page whose
      # stated rule is that credential metadata is gated. It was SILENT, and the silence is the
      # point — the member's page total was 12 before and 12 after, because the load displaced two
      # other round trips by exactly the amount the preload cost. An absolute count is built to
      # accept that, so a total cannot be what guards this.
      #
      # Asserted as the SHAPE of the preload instead. Two DISTINCT creators make it unambiguous: a
      # preload for them is one `IN (...)`, and no other users read on this page produces that —
      # the session and owner lookups are both `id = $1 LIMIT $2`. A total could not tell "the
      # preload is gone" from "something unrelated got cheaper"; this can.
      #
      # Both viewers are exercised in the one example, and both renders asserted, so neither half
      # can pass on a page that happened to load no keys at all.
      # @intent: {"entity": "ApiKey", "action": "gate creator preload", "behavior": "the owner's render buys exactly one IN-clause users preload for two distinct key creators, while a view member's render shows no keys table and buys none", "layer": "request"}
      it "does not buy the key-creator preload for a viewer who cannot see the keys table" do
        repository = create_repository(user: @user)
        repository.api_keys.create!(name: "CI", created_by_user: @user)
        repository.api_keys.create!(
          name: "Nightly",
          created_by_user: create_user(github_uid: "8801", github_handle: "colleague")
        )
        preloads = ->(statements) { statements.count { |sql| sql.include?(" IN (") } }

        get repository_path(repository)
        manager_reads = queries_against('"users"') { get repository_path(repository) }

        # The control. The gated table renders here, it names two different creators, and without
        # the preload that is one user query per row — so this half must see it bought.
        expect(response.body).to include("api-keys")
        expect(preloads.call(manager_reads)).to eq(1)

        member = create_user(github_uid: "9990", github_handle: "viewer")
        create_membership(repository: repository, user: member)
        sign_in_via_github(uid: "9990")

        get repository_path(repository)
        member_reads = queries_against('"users"') { get repository_path(repository) }

        expect(response.body).not_to include("api-keys")
        expect(preloads.call(member_reads)).to eq(0)
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

    # @intent: {"entity": "TestRun", "action": "stay visible to member", "behavior": "a view member still sees Carrying an @intent 2 on the overview while the api-keys table is absent from their page", "layer": "request"}
    it "stays visible to a member who cannot manage keys" do
      owner = create_user(github_uid: "7007", github_handle: "repo-owner")
      repository = create_repository(user: owner, github_full_name: "acme/shared-service")
      create_membership(repository: repository, user: @user)
      repository.test_runs.create!(commit_sha: "feedfacecafe0007", total_specs_count: 3,
                                   annotated_specs_count: 2)

      get repository_path(repository)

      # Suite coverage is the same class of information as the connection-health stat: a `view`
      # member needs it, and none of it is credential metadata.
      expect(overview_panel).to have_text("Carrying an @intent 2", normalize_ws: true)
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

    # `page_text` — the rendered copy with the ERB's whitespace collapsed — is defined once at the
    # top of this file; these examples are about sentences on the card, and use it unchanged.

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

    # @intent: {"entity": "TestRun", "action": "show ingested size", "behavior": "the index card prints 12,431 tests from the latest run and never the old N-intents badge", "layer": "request"}
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
    # @intent: {"entity": "TestRun", "action": "read newest run", "behavior": "with runs of 100 and 3 tests the card prints 3 tests and not 100", "layer": "request"}
    it "reads the newest run, not the first one ingested" do
      repository = create_repository(user: @user)
      create_test_run(repository: repository, commit_sha: "0ld", total_specs_count: 100)
      create_test_run(repository: repository, commit_sha: "new", total_specs_count: 3)

      get repositories_path

      expect(response.body).to include("3 tests")
      expect(response.body).not_to include("100 tests")
    end

    # @intent: {"entity": "TestRun", "action": "word never-ingested card", "behavior": "a repository with no runs prints No runs yet and never 0 tests", "layer": "request"}
    it "says a never-ingested repository has no runs, rather than showing it as an empty suite" do
      create_repository(user: @user)

      get repositories_path

      expect(response.body).to include("No runs yet")
      # `0 tests` would make "CI has never reported" byte-identical to "the suite is empty".
      expect(response.body).not_to include("0 tests")
    end

    # @intent: {"entity": "TestRun", "action": "batch latest-run loads", "behavior": "three cards load their latest runs from exactly one test_runs SELECT, no spec_intents query runs at all, and the page prints 11 tests", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "state reading age", "behavior": "the card reads Ingested 5 months ago on main beside its 12,431 tests figure", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "word absent branch", "behavior": "a run reporting no branch reads Ingested about 2 hours ago, branch not reported rather than a truncated sentence", "layer": "request"}
      it "says a branch was not reported rather than leaving it blank" do
        repository = create_repository(user: @user)
        create_test_run(repository: repository, commit_sha: "feedfacecafe0202",
                        total_specs_count: 88, branch: nil, created_at: 2.hours.ago)

        get repositories_path

        expect(page_text).to include("Ingested about 2 hours ago, branch not reported.")
      end

      # The half-delivered run: four shards' worth of suite, two of them recorded. The card prints
      # 10,000 and must say what those 10,000 cover.
      # @intent: {"entity": "TestRun", "action": "state shard coverage", "behavior": "a half-delivered two-shard run prints 10,000 tests and says it was assembled from 2 shard reports whose count that covers, in the exact words of the shared delivery-note helper", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "skip whole-run note", "behavior": "an unsharded run prints no composition wording at all, neither reported-in-one-piece nor assembled-from", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "state one-shard coverage", "behavior": "a one-shard run still gets its basis line saying assembled from 1 shard report and that the count covers that report, matching the Recent-runs helper", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "state no basis", "behavior": "a never-ingested card prints No runs yet and no Ingested line at all", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "batch shard question", "behavior": "four sharded cards, then eight, each print assembled from 4 shard reports and Machine time (all 4 added up) 4m 14s while a single test_run_shards aggregate serves the whole grid at either size", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "print cost rows", "behavior": "the card prints Wall clock (slowest of 4 shards) 1m 14s and Machine time (all 4 added up) 4m 14s with no Total runtime label, its markup matching the shared cost-rows seam", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "state partial coverage", "behavior": "one silent shard makes the card read Wall clock (slowest of the 3 that reported) 1m 1s and Machine time (3 of 4 added up) at least 3m", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "print plain duration", "behavior": "an unsharded 45.0-second run prints exactly one row, Total runtime 45.0s, with no Wall clock or Machine time wording", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "share cost wording", "behavior": "the card's two cost rows, Wall clock (slowest of 4 shards) and Machine time (all 4 added up), also appear verbatim on the show page the card links to", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "word unreported cost", "behavior": "a run that sent no timing prints Total runtime not reported and never 0.0s", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "word sharded absence", "behavior": "four shards with no timings print Machine time (0 of 4 added up) not reported, never 0.0s, from one shard query for the page", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "print measured zero", "behavior": "two shards genuinely measuring 0.0 print Machine time (all 2 added up) 0.0s rather than the not-reported wording", "layer": "request"}
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
      # @intent: {"entity": "TestRun", "action": "state no cost", "behavior": "a never-ingested card prints No runs yet and none of Total runtime, Wall clock or Machine time", "layer": "request"}
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

  # `RejectedIngests#refusing?` — "the last delivery this repository is known to have completed was
  # refused" — rendered on the grid that draws N repositories side by side. It had lived on
  # repositories#show alone, so the one surface built for comparison was the one surface that could
  # not say which of the listed pipelines was having its work thrown away.
  #
  # Two readings were reachable without it, and the first is the worse one. A repository being
  # refused with no accepted run EVER has no `TestRun` row, so the grid drew it through the `run.nil?`
  # branch — a neutral "No runs yet", byte-identical to a repository nobody has wired CI to, over
  # the state the model itself calls "the most refusing state there is". And a repository that
  # ingested cleanly for months and is now refusing everything kept printing its last accepted
  # figure with nothing marking the silence as a refusal rather than a quiet week.
  describe "the refusal marker on the repositories index" do
    # A refused delivery, stated directly.
    #
    # The panel specs on `show` build theirs with a real POST, and say why: the defect THAT surface
    # exists for is an ordering one inside `authenticate_api_key!` — the key is stamped on the way
    # IN, so a refused delivery records a use — and a hand-built row would skip the stamp and leave
    # those examples asserting against a state the production path cannot reach.
    #
    # Nothing this grid renders reads that column. The card compares one refusal's `occurred_at`
    # against its newest run's `created_at`, and both sides are stated here, so the fixture is
    # faithful rather than merely convenient. The last example in this block drives the whole real
    # path anyway — POST, refusal, grid — which is what pins this shortcut against the producer
    # instead of leaving the two trusted separately.
    def refuse(repository, at: Time.current)
      IngestRejection.create!(repository: repository, occurred_at: at,
                              details: ["commit_sha can't be blank"], total_reasons_count: 1)
    end

    # The wording, READ FROM THE SEAM both surfaces render rather than typed out here.
    #
    # This is the rule the cost rows above are already held to, and the reason is the same: a
    # literal spelled out in the spec is agreement that merely HOLDS TODAY. Rename the badge and
    # update the indicator's own literals, and an assertion against a copy here would still pass
    # against a card rendering the old word — the grid and the page it links to wording one
    # repository's refusal two ways, with nothing in the suite able to see it. Asserting the card's
    # markup against the seam's output makes the card, not a copy of it, the thing under test.
    def refusal_label = ApplicationController.helpers.refused_deliveries_label

    # Criterion 1, and the ordering that IS the rule: this compares two recorded facts rather than
    # asking whether a refusal is recent, so the newest thing that happened decides.
    # @intent: {"entity": "IngestRejection", "action": "mark refusing repository", "behavior": "a refusal ten minutes after the newest accepted run draws the refused-deliveries label and note beside the still-printed 900 tests figure", "layer": "request"}
    it "marks a repository whose newest refusal lands after its newest accepted run" do
      repository = create_repository(user: @user)
      create_test_run(repository: repository, commit_sha: "cafe0001", total_specs_count: 900,
                      created_at: 2.hours.ago)
      refuse(repository, at: 10.minutes.ago)

      get repositories_path

      expect(page_text).to include(refusal_label)
      # The card still states what it last managed to ingest — the marker is added beside the
      # figure, not in place of it. A reader needs both: the suite is 900 tests, and that number is
      # no longer being kept current.
      expect(response.body).to include("900 tests")
      expect(page_text).to include(
        ApplicationController.helpers.refused_deliveries_note(repository.ingest_rejections.first.occurred_at)
      )
    end

    # The other half of criterion 1. A repository that hit a bad payload and has ingested cleanly
    # since is healthy again, with no window to expire and no threshold anybody had to pick.
    # @intent: {"entity": "IngestRejection", "action": "mark nothing when recovered", "behavior": "an accepted run landing on top of a three-day-old refusal leaves the card unmarked, still printing its 12 tests figure", "layer": "request"}
    it "marks nothing when the newest accepted run is on top of the refusal" do
      repository = create_repository(user: @user)
      refuse(repository, at: 3.days.ago)
      create_test_run(repository: repository, commit_sha: "cafe0002", total_specs_count: 12,
                      created_at: 1.hour.ago)

      get repositories_path

      expect(page_text).not_to include(refusal_label)
      expect(response.body).to include("12 tests")
    end

    # CRITERION 2 — the case the grid got outright wrong, and the reason this is not only a badge.
    #
    # Both repositories here have no `TestRun` at all, so both reach the same `run.nil?` branch. One
    # has never been wired to CI and one is having every delivery thrown away, and before this they
    # rendered the identical neutral "No runs yet". The assertion is not merely that the refusing
    # card gained a marker: it is that the two cards no longer read the same, which is the actual
    # defect.
    # @intent: {"entity": "IngestRejection", "action": "tell apart never-wired", "behavior": "the refusing card with no accepted run reads No runs accepted while the never-wired one keeps No runs yet, and only the refusing card carries the label", "layer": "request"}
    it "tells a never-wired repository apart from one whose every delivery is refused" do
      never_wired = create_repository(user: @user, github_full_name: "acme/never-wired")
      refused = create_repository(user: @user, github_full_name: "acme/refused")
      refuse(refused, at: 5.minutes.ago)

      get repositories_path

      cards = Capybara.string(response.body)
      never_wired_card = cards.find_link(href: repository_path(never_wired))
      refused_card = cards.find_link(href: repository_path(refused))

      expect(refused_card.text).to include(refusal_label)
      expect(never_wired_card.text).not_to include(refusal_label)

      # ...and the neutral badge does not stay on the refusing card wearing the meaning it has on
      # the other one. "No runs yet" says nothing has been sent; this repository is sending, and
      # nothing is being KEPT.
      expect(never_wired_card.text).to include("No runs yet")
      expect(refused_card.text).not_to include("No runs yet")
      expect(refused_card.text).to include("No runs accepted")
    end

    # CRITERION 4 — the guard this preload exists to satisfy, in the shape the sibling guards above
    # use. There is no absolute page budget on this page (the `count_queries` budgets in this file
    # wrap `get repository_path(...)`, i.e. SHOW), so the instrument is the per-table one.
    #
    # Every card here is refusing, which is the difference between this and a green-for-the-wrong-
    # reason guard: a budget whose page never renders the read it is guarding passes trivially. The
    # marker count is asserted first, so the page provably ASKED before the count says how often.
    # @intent: {"entity": "IngestRejection", "action": "batch refusal question", "behavior": "three refusing cards, then six, all render the label while a single ingest_rejections aggregate serves the whole grid at either size", "layer": "request"}
    it "asks the refusal question once for the whole grid, however long the list is" do
      %w[acme/one acme/two acme/three].each_with_index do |full_name, index|
        repository = create_repository(user: @user, github_full_name: full_name)
        create_test_run(repository: repository, commit_sha: "cafe030#{index}",
                        total_specs_count: 10, created_at: 2.days.ago)
        refuse(repository, at: 1.hour.ago)
      end

      rejection_queries = queries_against("ingest_rejections") { get repositories_path }

      expect(response).to have_http_status(:ok)
      # Every card really did render the verdict, so every card really did ask.
      expect(page_text.scan(refusal_label).size).to eq(3)
      # One grouped aggregate for the whole page — three cards must not cost three SELECTs.
      expect(rejection_queries.size).to eq(1)

      # And the count is a bound rather than a coincidence of this fixture's size: double the grid,
      # and the same single aggregate answers all six cards. An absolute number asserted at one N
      # is satisfied by a page whose cost is N/2.
      %w[acme/four acme/five acme/six].each_with_index do |full_name, index|
        repository = create_repository(user: @user, github_full_name: full_name)
        create_test_run(repository: repository, commit_sha: "cafe040#{index}",
                        total_specs_count: 10, created_at: 2.days.ago)
        refuse(repository, at: 1.hour.ago)
      end

      doubled = queries_against("ingest_rejections") { get repositories_path }

      expect(page_text.scan(refusal_label).size).to eq(6)
      expect(doubled.size).to eq(1)
    end

    # CRITERION 5. One query is not on its own the same claim as a bounded one: a single SELECT
    # that read the whole table would satisfy the count above and get slower for every refusal
    # anybody's CI has ever suffered.
    #
    # ⚠️ ASSERTED ON THE STATEMENT, NOT ON `rows_touched`, and the reason is worth keeping. The
    # `EXPLAIN (ANALYZE)` reading is the sharper instrument in principle and it is the WRONG one
    # here: at fixture scale this table holds twenty-odd rows, and Postgres correctly picks a Seq
    # Scan over an index for that, so the plan reports every row as "Rows Removed by Filter" and the
    # measurement reads 21 for a query whose WHERE clause names exactly one repository. That is the
    # planner's choice at a size no deployment has, not a scoping defect — and an example that
    # "fixed" it by seeding enough rows to flip the plan would be pinning a cost-model threshold.
    #
    # What criterion 5 actually claims is about the READ: it is restricted to the ids already on
    # this page. That is a property of the statement, and the statement is what this reads —
    # captured off the wire by the shared subscriber rather than copied from the controller, so a
    # read that stopped being narrowed cannot pass by agreeing with a hand-written duplicate.
    # `index_ingest_rejections_on_repository_and_recency` is what serves it once the table is big
    # enough for the planner to prefer an index; the guard here is that there is something to serve.
    # @intent: {"entity": "IngestRejection", "action": "scope refusal read", "behavior": "the grid's rejection SELECT is narrowed by repository_id IN to exactly the viewer's two repositories, including the one with no refusals, and never reads a stranger's repository", "layer": "request"}
    it "reads only the repositories on this page, never the whole table" do
      mine = create_repository(user: @user, github_full_name: "acme/mine")
      also_mine = create_repository(user: @user, github_full_name: "acme/also-mine")
      refuse(mine, at: 1.hour.ago)

      stranger = create_user(github_uid: "7777", github_handle: "stranger")
      other = create_repository(user: stranger, github_full_name: "other/theirs")
      20.times { |index| refuse(other, at: (index + 1).minutes.ago) }

      sql = captured_sql("ingest_rejections") { get repositories_path }

      expect(page_text).to include(refusal_label)
      # Narrowed by repository at all — the shape a global aggregate would not have.
      expect(sql).to match(/WHERE .*"repository_id" IN /)

      # ...and narrowed to exactly the ids this page is rendering. Read as a SET, deliberately: the
      # ids arrive in the page's own `github_full_name` order, so pinning the sequence would assert
      # the grid's sort order from inside a scoping guard and break on a rename that reorders the
      # cards. What criterion 5 claims is WHICH ids are in the read, not in what order.
      scoped_ids = sql[/IN \(([^)]*)\)/, 1].split(",").map { |id| id.strip.to_i }
      # Both of this viewer's repositories, INCLUDING the one with no refusals: the scope is the
      # page, not the subset that happens to have rows.
      expect(scoped_ids).to match_array([mine.id, also_mine.id])
      # And the repository this viewer cannot see is absent from the read entirely. A global
      # aggregate would answer this page correctly today and read every refusal in the deployment
      # to do it.
      expect(scoped_ids).not_to include(other.id)
    end

    # CRITERION 6 — the marker is purely additive for the population that is not refusing. This is
    # the whole non-refusing grid asserted at once: no marker, no note, and nothing about the words
    # the cards already printed has moved.
    # @intent: {"entity": "IngestRejection", "action": "leave non-refusing unchanged", "behavior": "a card with no refusals still prints 4,321 tests and Ingested less than a minute ago on main, with no label, no refusal note and no No runs accepted", "layer": "request"}
    it "leaves a repository with no refusals rendering exactly what it rendered before" do
      repository = create_repository(user: @user)
      create_test_run(repository: repository, commit_sha: "cafe0005", total_specs_count: 4_321,
                      branch: "main")

      get repositories_path

      expect(response.body).to include("4,321 tests")
      expect(page_text).to include("Ingested less than a minute ago on main")
      expect(page_text).not_to include(refusal_label)
      expect(page_text).not_to include("the key works, the payload did not")
      expect(page_text).not_to include("No runs accepted")
    end

    # CRITERION 7. The seam is what stops the grid and the page it links to wording one
    # repository's refusal two different ways, and the assertion has to be able to SEE that — so it
    # renders both surfaces for the same repository and holds each to the seam's output rather than
    # to a literal typed twice here.
    #
    # A literal would pass on a rename that moved only one of them, which is the exact failure the
    # seam exists to make impossible.
    # @intent: {"entity": "IngestRejection", "action": "share refusal wording", "behavior": "the card and the show page's connection indicator both carry the label and the refused-deliveries note, each rendered from the same helpers", "layer": "request"}
    it "words the card and the page it links to from one seam" do
      repository = create_repository(user: @user)
      refuse(repository, at: 20.minutes.ago)

      get repositories_path
      card_text = page_text

      get repository_path(repository)
      indicator_text = Capybara.string(response.body).find("#connection-indicator").text.squish

      expect(card_text).to include(refusal_label)
      expect(indicator_text).to include(refusal_label)
      # ...and the sentence under it, which carries the one thing a reader who has just seen a green
      # "Connected" needs told — that the credential is fine and the payload was not.
      note = ApplicationController.helpers.refused_deliveries_note(
        repository.ingest_rejections.first.occurred_at
      )
      expect(card_text).to include(note)
      expect(indicator_text).to include(note)
    end

    # CRITERION 8. `IngestRejection::REPOSITORY_RETENTION_ROWS` bounds the table, so a repository
    # that was refused and then went silent long enough loses the rows — and the model's documented
    # reading is that the verdict "is reporting what it can still see". The grid inherits that by
    # knowing nothing about it: no rows, no key in the grouped MAX, no marker.
    #
    # Asserted with NO accepted run, which is the strict case: this repository is not non-refusing
    # because something was ingested on top, it is non-refusing because there is no longer any
    # evidence of refusal. No new retention rule is introduced here or in the code under it.
    # @intent: {"entity": "IngestRejection", "action": "age out refusals", "behavior": "once the retained refusal rows are deleted the card drops the label and falls back to No runs yet rather than No runs accepted", "layer": "request"}
    it "reads as non-refusing once its refusals have aged out of the retained window" do
      repository = create_repository(user: @user)
      refuse(repository, at: 1.hour.ago)

      get repositories_path
      expect(page_text).to include(refusal_label)

      # What retention does, at the point it has done it.
      repository.ingest_rejections.delete_all

      get repositories_path

      expect(page_text).not_to include(refusal_label)
      # ...and the card falls back to the neutral state, not to the refusing variant of it.
      expect(page_text).to include("No runs yet")
      expect(page_text).not_to include("No runs accepted")
    end

    # The fixture in this block states its rows directly, so this is the example that pins it
    # against the thing that actually writes them: a real POST that authenticates and is then
    # refused for its payload, straight through to the marker on the grid.
    #
    # It also re-establishes, at this surface, the ordering fact the whole feature rests on —
    # `authenticate_api_key!` stamps the key on the way IN, so this refused delivery DID record a
    # use. That is why the card cannot read this signal off the credential, and why the refusal has
    # to be carried beside the rows instead.
    # @intent: {"entity": "IngestRejection", "action": "mark real refusal", "behavior": "a real authenticated POST to the ingest API that fails its payload leaves one rejection row, stamps the key's last_used_at, and the grid shows the label with No runs accepted", "layer": "request"}
    it "marks a card from a delivery the real endpoint refused" do
      repository = create_repository(user: @user)
      key = repository.api_keys.create!(name: "CI")

      post "/api/v1/ingest",
           params: { specs: [] }.to_json,
           headers: { "Content-Type" => "application/json",
                      "Authorization" => "Bearer #{key.raw_token}" }

      expect(repository.ingest_rejections.count).to eq(1)
      # The delivery authenticated. A card reading `last_used_at` would call this pipeline healthy.
      expect(key.reload.last_used_at).to be_present

      get repositories_path

      expect(page_text).to include(refusal_label)
      expect(page_text).to include("No runs accepted")
    end
  end

  # The rotated-but-unused state — the connection indicator on `show` words it "Key rotated, not
  # yet in use" — rendered on the grid beside the refusal marker the block above ships. It had
  # lived on repositories#show alone, so the reader who had just rotated keys — the one most likely
  # to hold several at once — had to open every card's page one at a time to learn which of their
  # pipelines was holding a replacement token that never reached CI.
  #
  # The card TRIGGERS the way `show` does. On `show` this state is branch 3 of an exclusive chain —
  # not refusing, `@last_api_request_at` present, `@last_live_api_request_at` blank — i.e. something
  # authenticated and every token that ever did has since been rotated away, so CI is presenting a
  # credential that no longer exists. `ApiKey#rotated_and_unused?` is the predicate that state is
  # DERIVED from (the model's own word), not the state itself: keyed on it per key, the card would
  # contradict `show` on a repository whose live key keeps CI connected (the stranded key beside it
  # holds nothing back) and on a key rotated before it ever authenticated (nothing was ever routed
  # through it, so no replacement is hanging) — the two cases pinned below as rendering nothing.
  # The chain's refusing conjunct is carried by the card's ORDER — refusal first, both shown — not
  # by suppression.
  #
  # The card carries the BADGE and a count-free age sentence, and nothing else. The count-free
  # shape is this grid's own rule: the key count is credential information here
  # (`key_count_visible?` gates the key badge on the very same card), so the indicator's plural —
  # "N keys have been regenerated…" — cannot travel, and N behind an ungated badge would smuggle
  # the gated figure in through the wording. The state itself is ungated by an existing argued
  # decision — the indicator is, and this is the same class of signal, no key name and no hint.
  #
  # The wording is NOT typed onto the card. It lives in `rotated_key_label` /
  # `rotated_key_note` / `rotated_keys_note` in ApplicationHelper, beside the refusal pair, and
  # both surfaces render through it — the same seam rule the refusal block above is held to, and
  # the reason the extraction is part of this work rather than a copy.
  describe "the rotation marker on the repositories index" do
    # The wording, READ FROM THE SEAM both surfaces render rather than typed out here — the rule
    # `refusal_label` in the block above is held to, for the same reason: a literal copied into a
    # spec is agreement that merely HOLDS TODAY.
    def rotated_label = ApplicationController.helpers.rotated_key_label

    # The one card a claim is about, found by its link — the same per-card scoping the refusal
    # block uses, because page-level assertions cannot tell one card's marker from another's.
    def card_for(repository)
      Capybara.string(response.body).find_link(href: repository_path(repository))
    end

    def card_text(repository) = card_for(repository).text.gsub(/\s+/, " ")

    # A stranded key: minted, used once by the old token, then regenerated — and nothing has
    # authenticated with the replacement since. `update_columns` backdates the fixture the same way
    # the `show` indicator specs do.
    def strand_key(repository, name, used_at: 1.hour.ago, rotated_at: 30.minutes.ago)
      key = repository.api_keys.create!(name: name)
      key.touch_last_used!
      key.regenerate!
      key.update_columns(last_used_at: used_at, rotated_at: rotated_at)
      key
    end

    # Criterion 1, and the oldest date the sentence is held to. The fixture tells the candidate
    # aggregates apart the same way `show`'s own example does: on a one-key set `min`, `max` and
    # `first` are indistinguishable, so two strands with different `rotated_at` are the minimum
    # that can catch a newest-dated sentence — the reading that would tell a five-day-dead
    # pipeline its event was a minute old.
    # @intent: {"entity": "ApiKey", "action": "mark stranded rotation", "behavior": "a repository with two stranded keys draws the Key rotated, not yet in use badge and dates the card sentence from the OLDEST stranded rotated_at, read from the shared note seam", "layer": "request"}
    it "marks a repository with a stranded key and dates the sentence from the oldest rotation" do
      repository = create_repository(user: @user, github_full_name: "acme/nightlies")
      nightly = strand_key(repository, "Nightly", used_at: 6.days.ago, rotated_at: 5.days.ago)
      strand_key(repository, "Main")

      get repositories_path

      expect(page_text).to include(rotated_label)
      # Against the seam's own figure rather than a literal date, so this pins the SOURCE.
      expect(page_text).to include(
        ApplicationController.helpers.rotated_key_note(nightly.reload.rotated_at)
      )
      # The reading a newest-dated sentence would produce on this very fixture.
      expect(page_text).not_to include("less than a minute ago")
    end

    # Criterion 2, and it is a credential rule, not a style one. The viewer here is the OWNER, so
    # the key-count badge above the marker legitimately reads "3 keys" — the assertion is scoped to
    # the ROTATION COPY, which must carry neither that figure nor any other count, and no key name:
    # the card renders exactly the ungated class the connection indicator established, or it hands
    # a `view`-only reader credential metadata the page it links to gates.
    # @intent: {"entity": "ApiKey", "action": "keep count off card", "behavior": "with three stranded keys named Nightly Main and Deploy the rotation paragraph carries no digit at all, the count-bearing 3-keys wording never renders, and no key name appears on the card", "layer": "request"}
    it "carries no key count and no key name in the card's rotation copy" do
      repository = create_repository(user: @user, github_full_name: "acme/three-strands")
      %w[Nightly Main Deploy].each { |name| strand_key(repository, name) }

      get repositories_path

      text = card_text(repository)
      expect(text).to include(rotated_label)
      # The indicator's count-bearing variant must not travel to the grid.
      expect(text).not_to include("3 keys have been regenerated")
      # ...and no key name either — these names exist only behind `keys.manage` on `show`.
      expect(text).not_to include("Nightly")
      expect(text).not_to include("Deploy")
      # The count-free sentence is asserted on ITS OWN paragraph, not on the card: the owner's key
      # badge two rows up is allowed to say "3 keys", and the marker must not need it to be absent.
      # The digit test is the BARE figure (`\b3\b`), not any digit at all — the sentence carries an
      # age, and "30 minutes" is a measurement, not a count of keys.
      rotation_paragraph = card_for(repository).find("p", text: "The oldest key was regenerated")
      expect(rotation_paragraph.text).not_to match(/\b3\b/)
      expect(rotation_paragraph.text).not_to include("keys have been regenerated")
    end

    # Criterion 3, and the ordering IS the rule: a refusing pipeline is the worse fact —
    # deliveries thrown away beats a rotation that never landed — so a card holding both shows
    # both, refusal first. The same precedence the connection indicator settles on `show`.
    # @intent: {"entity": "ApiKey", "action": "order refusal first", "behavior": "a card carrying both a live refusal and a stranded rotation renders both labels with Deliveries refused appearing before Key rotated, not yet in use", "layer": "request"}
    it "renders a card with both facts with the refusal first and the rotation beneath it" do
      repository = create_repository(user: @user, github_full_name: "acme/both-facts")
      strand_key(repository, "CI", used_at: 3.days.ago, rotated_at: 2.days.ago)
      create_test_run(repository: repository, commit_sha: "cafe0501", total_specs_count: 10,
                      created_at: 2.days.ago)
      IngestRejection.create!(repository: repository, occurred_at: 1.hour.ago,
                              details: ["commit_sha can't be blank"], total_reasons_count: 1)

      get repositories_path

      text = card_text(repository)
      expect(text).to include(ApplicationController.helpers.refused_deliveries_label)
      expect(text).to include(rotated_label)
      # Both, and in this order: refusal first, rotation second.
      expect(text.index(ApplicationController.helpers.refused_deliveries_label))
        .to be < text.index(rotated_label)
    end

    # Criterion 4 — purely additive for the population without a stranded key, asserted through
    # the seam both ways: no badge and no note sentence, while the card keeps printing what it
    # printed before. The "1 key" figure doubles as the guard that the consolidated read the
    # marker rides still answers the count badge exactly as the grouped COUNT it replaced did.
    # @intent: {"entity": "ApiKey", "action": "leave unstranded unchanged", "behavior": "a repository whose key is used and never rotated prints its 1 key badge and No runs yet with no Key rotated label and no oldest-key sentence", "layer": "request"}
    it "leaves a repository with no stranded key rendering exactly what it rendered before" do
      repository = create_repository(user: @user, github_full_name: "acme/plain")
      repository.api_keys.create!(name: "CI").touch_last_used!

      get repositories_path

      expect(page_text).not_to include(rotated_label)
      expect(page_text).not_to include("The oldest key was regenerated")
      expect(page_text).to include("1 key")
      expect(page_text).to include("No runs yet")
    end

    # Amended criterion 5 — the case the per-key predicate would badge and `show` does not. A key
    # rotated before it ever authenticated has a nil `last_used_at`, so NOTHING has ever
    # authenticated for this repository at all: `show` falls past the rotated branch to "Not
    # connected yet" — an ordinary starting condition, not work being lost — and the card must read
    # the same. "The replacement token has not reached CI" would assert a pipeline that never
    # existed: no token was ever routed through this key, so no replacement is hanging and the
    # reader did not just break anything. The row still answers `rotated_and_unused?` true — the
    # model calls the nil limb the state at its purest — which is exactly why this example exists:
    # it is the proof the card's trigger is the chain-equivalent aggregate and not that predicate.
    # Asserted both as absence and as byte-identity with a never-wired card, with only the names
    # stripped — the amended AC5's own standard.
    # @intent: {"entity": "ApiKey", "action": "skip never-authenticated", "behavior": "a key rotated before ever being used draws no Key rotated label and no note, its card byte-identical to a never-wired card's, and show's indicator reads Not connected yet for the same repository", "layer": "request"}
    it "does not mark a key that was rotated before it ever authenticated" do
      rotated_never_authed = create_repository(user: @user, github_full_name: "acme/never-authed")
      key = rotated_never_authed.api_keys.create!(name: "CI")
      key.regenerate!
      never_wired = create_repository(user: @user, github_full_name: "acme/never-wired")
      never_wired.api_keys.create!(name: "CI")

      get repositories_path

      # The row is everything the old per-key trigger asked for — and the card still renders
      # nothing, because the aggregate does not fire.
      expect(key.reload).to be_rotated_and_unused
      expect(page_text).not_to include(rotated_label)
      expect(page_text).not_to include("replacement token has not reached CI")
      # Byte-identical to the card beside it that was never wired at all, once the one word that
      # must differ is stripped: both count the same one live key (a rotation does not revoke),
      # both say "No runs yet", neither prints a marker.
      expect(card_text(rotated_never_authed).sub("acme/never-authed", ""))
        .to eq(card_text(never_wired).sub("acme/never-wired", ""))

      # The surface it must agree with, on the same repository at the same instant.
      get repository_path(rotated_never_authed)
      indicator_text = Capybara.string(response.body).find("#connection-indicator").text.squish
      expect(indicator_text).to include("Not connected yet")
      expect(indicator_text).not_to include(rotated_label)
    end

    # The other divergence the per-key trigger shipped: a repository whose live key authenticated
    # an hour ago and whose OTHER key is stranded is CONNECTED. CI is flowing on the credential it
    # carries, the stranded key's replacement is not the token the pipeline uses, and `show` says
    # so in success tone — a warning here would be a false alarm on a healthy repository, on the
    # very page the reader is comparing cards across. The aggregate reads it the way `show` does:
    # the live key keeps the live figure present, so the rotated branch never fires. Pinned
    # against `show`'s own verdict, since surface agreement is the point of the resolution.
    # @intent: {"entity": "ApiKey", "action": "skip connected with strand", "behavior": "a repository with one live authenticated key and one stranded key draws no Key rotated label on the card while show's indicator still reads Connected — the two surfaces agree", "layer": "request"}
    it "does not mark a repository whose live key keeps it connected beside a stranded one" do
      repository = create_repository(user: @user, github_full_name: "acme/still-connected")
      repository.api_keys.create!(name: "Live").touch_last_used!
      strand_key(repository, "Old", used_at: 6.days.ago, rotated_at: 5.days.ago)

      get repositories_path

      expect(page_text).not_to include(rotated_label)
      expect(page_text).not_to include("replacement token has not reached CI")

      # The surface it must agree with, saying the opposite of a warning.
      get repository_path(repository)
      indicator_text = Capybara.string(response.body).find("#connection-indicator").text.squish
      expect(indicator_text).to include("Connected")
      expect(indicator_text).not_to include(rotated_label)
    end

    # The retirement split, carried over from `show`'s own rule: a key that was rotated and THEN
    # revoked is both, the revocation is the newer and stronger fact, and the rotated state must
    # not fire for it. The read is off the live partition the key count already uses — which is
    # also why a dropped `.live` scope would break this example and not merely change a flavour.
    # @intent: {"entity": "ApiKey", "action": "skip revoked strand", "behavior": "a key that was stranded and then revoked draws no Key rotated marker on the card, the revocation being the stronger fact", "layer": "request"}
    it "does not mark a key that was rotated and then revoked" do
      repository = create_repository(user: @user, github_full_name: "acme/retired")
      key = strand_key(repository, "CI")
      key.revoke!

      get repositories_path

      expect(key.reload).to be_revoked
      expect(page_text).not_to include(rotated_label)
      expect(page_text).not_to include("replacement token has not reached CI")
    end

    # Criterion 6, at the surface level the seam exists for: the card and the page it links to
    # word the state from ONE helper, so a rename cannot move one and strand the other. Each
    # surface is held to its own seam's output — the indicator keeps the count-bearing note, the
    # card the count-free one — rather than to literals typed twice here.
    # @intent: {"entity": "ApiKey", "action": "share rotation wording", "behavior": "the card and the show page's connection indicator both carry the Key rotated label from the same helper, each rendering its own note seam's output", "layer": "request"}
    it "words the card and the page it links to from one seam" do
      repository = create_repository(user: @user, github_full_name: "acme/shared-words")
      strand_key(repository, "CI")

      get repositories_path
      grid_text = page_text

      get repository_path(repository)
      indicator_text = Capybara.string(response.body).find("#connection-indicator").text.squish

      key = repository.api_keys.live.first.reload
      expect(grid_text).to include(rotated_label)
      expect(indicator_text).to include(rotated_label)
      # Each surface its own variant, and each asserted against the seam and not a literal.
      expect(grid_text).to include(
        ApplicationController.helpers.rotated_key_note(key.rotated_at)
      )
      expect(indicator_text).to include(
        ApplicationController.helpers.rotated_keys_note(1, key.rotated_at)
      )
    end

    # Criterion 7 — the guard the neighbouring budgets exist in the shape of: every SELECT the
    # index issues against `api_keys`, so a per-card read shows up as N of them rather than as a
    # passing test. Every card here is stranded, which is the difference between this and a
    # green-for-the-wrong-reason guard: a budget whose page never renders the read it is guarding
    # passes trivially. The quoted table spelling is deliberate — `user_api_keys` exists, and the
    # bare substring would count its statements against this budget.
    #
    # ONE read serves both facts the card draws from `api_keys` — the count badge and this marker —
    # because the rotation state is derived in Ruby from the rows the count used to take as a
    # grouped COUNT. Doubling the grid proves the 1 is a bound and not a coincidence of the
    # fixture's size.
    # @intent: {"entity": "ApiKey", "action": "batch key reads", "behavior": "three stranded cards, then six, all render the label while a single api_keys SELECT serves the whole grid at either size", "layer": "request"}
    it "asks the api_keys question once for the whole grid, however long the list is" do
      %w[acme/one acme/two acme/three].each do |full_name|
        strand_key(create_repository(user: @user, github_full_name: full_name), "CI")
      end

      key_queries = queries_against('"api_keys"') { get repositories_path }

      expect(response).to have_http_status(:ok)
      # Every card really did render the marker, so every card really did ask.
      expect(page_text.scan(rotated_label).size).to eq(3)
      # One row read for the whole page — three cards must not cost three SELECTs.
      expect(key_queries.size).to eq(1)

      %w[acme/four acme/five acme/six].each do |full_name|
        strand_key(create_repository(user: @user, github_full_name: full_name), "CI")
      end

      doubled = queries_against('"api_keys"') { get repositories_path }

      expect(page_text.scan(rotated_label).size).to eq(6)
      expect(doubled.size).to eq(1)
    end

    # The read is narrowed to the ids already on this page — a property of the STATEMENT, captured
    # off the wire rather than copied from the controller. These rows carry `token_digest`, so
    # "reads every key in the deployment to answer about four" would be a privacy boundary crossed
    # and not merely a slow query; the stranger's rows stay out of the read entirely.
    # @intent: {"entity": "ApiKey", "action": "scope key read", "behavior": "the grid's api_keys SELECT is narrowed by repository_id IN to exactly the viewer's two repositories and never reads a stranger's", "layer": "request"}
    it "reads only the repositories on this page, never the whole table" do
      mine = create_repository(user: @user, github_full_name: "acme/mine")
      strand_key(mine, "CI")
      also_mine = create_repository(user: @user, github_full_name: "acme/also-mine")

      stranger = create_user(github_uid: "7777", github_handle: "stranger")
      other = create_repository(user: stranger, github_full_name: "other/theirs")
      5.times { |index| strand_key(other, "CI", rotated_at: (index + 1).minutes.ago) }

      sql = captured_sql('"api_keys"') { get repositories_path }

      expect(page_text).to include(rotated_label)
      # Narrowed by repository at all — the shape a global read would not have.
      expect(sql).to match(/WHERE .*"repository_id" IN /)

      scoped_ids = sql[/IN \(([^)]*)\)/, 1].split(",").map { |id| id.strip.to_i }
      # Both of this viewer's repositories, INCLUDING the one with no keys: the scope is the page,
      # not the subset that happens to have rows.
      expect(scoped_ids).to match_array([mine.id, also_mine.id])
      expect(scoped_ids).not_to include(other.id)
    end
  end

  # SPGD-947 — the connection chain's TOP state carried onto the grid, through the same
  # ApplicationHelper seam the refusal and rotation markers already render from. The chain's own
  # prose ranks this rung above both, and it is the worst collapse the card could carry: every
  # existing signal reads the live partition (the key count, the rotation marker) or is fed by a
  # recorder a dead token can never reach (the refusal marker — a revoked token 401s at
  # `authenticate_api_key!` before any controller runs, so no IngestRejection row is ever written
  # for its presentation), and the key badge's live-only row set excludes the revoked rows in
  # every figure it prints. A revoked-and-presented repository therefore rendered byte-identically,
  # in neutral tone, to one nobody ever wired CI to.
  describe "the revoked-key marker on the repositories index" do
    # The wording, READ FROM THE SEAM both surfaces render rather than typed out here — the rule
    # `rotated_label` in the block above is held to, for the same reason: a literal copied into a
    # spec is agreement that merely HOLDS TODAY.
    def revoked_label = ApplicationController.helpers.revoked_key_label

    # The one card a claim is about, found by its link — the same per-card scoping the refusal and
    # rotation blocks use, because page-level assertions cannot tell one card's marker from
    # another's.
    def card_for(repository)
      Capybara.string(response.body).find_link(href: repository_path(repository))
    end

    def card_text(repository) = card_for(repository).text.gsub(/\s+/, " ")

    # A presented revoked key: minted, revoked, and the dead token presented at the API so the
    # REAL failure path stamps `last_refused_at` — the fixture discipline the `show` indicator
    # specs state in full ("a hand-written `last_refused_at` would leave these examples asserting
    # against a state no production code path produces"). `revoked_at` may be backdated BEFORE the
    # presentation, the same way the show specs fix the ages their date assertions name; the
    # refusal stamp itself stays on the real path. Returns the reloaded row.
    def present_revoked_key(repository, name, revoked_at: nil)
      key = repository.api_keys.create!(name: name)
      token = key.raw_token
      key.revoke!
      key.update_columns(revoked_at: revoked_at) if revoked_at

      get "/api/v1/repository", headers: { "Authorization" => "Bearer #{token}" }
      expect(response).to have_http_status(:unauthorized)

      key.reload
    end

    # A stranded key: minted, used once by the old token, then regenerated — and nothing has
    # authenticated with the replacement since. The rotation block's own helper, mirrored here so
    # this describe stays self-contained.
    def strand_key(repository, name, used_at: 1.hour.ago, rotated_at: 30.minutes.ago)
      key = repository.api_keys.create!(name: name)
      key.touch_last_used!
      key.regenerate!
      key.update_columns(last_used_at: used_at, rotated_at: rotated_at)
      key
    end

    # Criterion 1, and the oldest date the sentence is held to. The fixture tells the candidate
    # aggregates apart the same way the show indicator's plural example and the rotation block's
    # oldest-dated example do: on a one-key set min and max are indistinguishable, so two
    # presentations with different `revoked_at` are the minimum that can catch a newest-dated
    # sentence — the reading that would tell a five-day-dead pipeline its revocation was a minute
    # old.
    # @intent: {"entity": "ApiKey", "action": "mark presented revocation", "behavior": "a repository with two presented revoked keys draws the Revoked key still presented badge in error tone and dates the card sentence from the OLDEST revoked_at and the newest last_refused_at, read from the shared note seam", "layer": "request"}
    it "marks a repository with a presented revoked key and dates the sentence from the oldest revocation" do
      repository = create_repository(user: @user, github_full_name: "acme/offboarded")
      nightly = present_revoked_key(repository, "Nightly", revoked_at: 5.days.ago)
      present_revoked_key(repository, "Main")

      get repositories_path

      expect(page_text).to include(revoked_label)
      # `:error`, on the refusing state's own rule — work is being destroyed, not merely absent.
      expect(card_for(repository)).to have_css(".text-app-error", text: revoked_label)
      # Against the seam's own figure rather than a literal date, so this pins the SOURCE: the
      # oldest revocation (not the minute-old one beside it) and the real failure path's refusal
      # stamp — the freshest presentation, since the card's sentence dates the NEWEST of those.
      expect(page_text).to include(
        ApplicationController.helpers.revoked_key_note(
          nightly.revoked_at, nightly.last_refused_at
        )
      )
      # The reading a newest-dated sentence would produce on this very fixture.
      expect(page_text).not_to include("you revoked less than a minute ago")
    end

    # Criterion 2, and the ordering IS the rule: the chain's own prose ranks this state above
    # REFUSING, and the card states precedence as layout, the same way the
    # refusal-above-rotation rule beneath it is stated. A card carrying all three facts shows all
    # three, worst first — the revoked state suppresses neither, exactly as the refusal
    # suppresses neither the rotation nor the run badge.
    # @intent: {"entity": "ApiKey", "action": "order revoked first", "behavior": "a card carrying a presented revocation, a live refusal and a stranded rotation renders all three labels with Revoked key still presented appearing before Deliveries refused and before Key rotated, not yet in use", "layer": "request"}
    it "renders the revoked badge above the refusal and rotation markers on a card holding all three" do
      repository = create_repository(user: @user, github_full_name: "acme/all-three")
      strand_key(repository, "CI", used_at: 3.days.ago, rotated_at: 2.days.ago)
      create_test_run(repository: repository, commit_sha: "cafe0901", total_specs_count: 10,
                      created_at: 2.days.ago)
      IngestRejection.create!(repository: repository, occurred_at: 1.hour.ago,
                              details: ["commit_sha can't be blank"], total_reasons_count: 1)
      present_revoked_key(repository, "Old CI")

      get repositories_path

      text = card_text(repository)
      revoked_at_index = text.index(revoked_label)
      refusal_at_index = text.index(ApplicationController.helpers.refused_deliveries_label)
      rotated_at_index = text.index(ApplicationController.helpers.rotated_key_label)
      expect(revoked_at_index).to be_present
      expect(refusal_at_index).to be_present
      expect(rotated_at_index).to be_present
      expect(revoked_at_index).to be < refusal_at_index
      expect(revoked_at_index).to be < rotated_at_index
    end

    # Criterion 3, and it is a credential rule, not a style one — the identical rule the rotation
    # copy is held to. The viewer here is the OWNER, so the key-count badge legitimately reads
    # "0 keys"; the assertion is scoped to the REVOKED COPY, which must carry neither a count nor
    # any key name. The indicator's own plural branch prints "3 keys you revoked" on this very
    # fixture (pinned on `show`), so the card must render the singular's generalization or it
    # smuggles the gated figure through the wording.
    # @intent: {"entity": "ApiKey", "action": "keep count off card", "behavior": "with three presented revoked keys named Nightly Main and Deploy the revoked paragraph carries no digit at all, the count-bearing 3-keys wording never renders, and no key name appears on the card", "layer": "request"}
    it "carries no key count and no key name in the card's revoked copy" do
      repository = create_repository(user: @user, github_full_name: "acme/three-revoked")
      %w[Nightly Main Deploy].each { |name| present_revoked_key(repository, name) }

      get repositories_path

      text = card_text(repository)
      expect(text).to include(revoked_label)
      # The indicator's count-bearing variant must not travel to the grid.
      expect(text).not_to include("3 keys you revoked")
      # ...and no key name either — these names exist only behind `keys.manage` on `show`.
      expect(text).not_to include("Nightly")
      expect(text).not_to include("Deploy")
      # The count-free sentence is asserted on ITS OWN paragraph, not on the card: the card holds
      # other figures (the suite badge, the key badge), and the marker must not need them absent.
      # The digit test is the BARE figure (`\b3\b`), not any digit at all — the sentence carries an
      # age, and "a minute" is a measurement, not a count of keys.
      revoked_paragraph = card_for(repository).find("p", text: "still being presented")
      expect(revoked_paragraph.text).not_to match(/\b3\b/)
      expect(revoked_paragraph.text).not_to include("keys you revoked")
    end

    # Criterion 4, at the surface level the seam exists for: the card and the page it links to
    # word the state from ONE helper, so a rename cannot move one and strand the other. Each
    # surface is held to its own seam's output — the indicator keeps the count-bearing note, the
    # card the count-free one — rather than to literals typed twice here. The same example the
    # rotation block carries for its own pair.
    # @intent: {"entity": "ApiKey", "action": "share revoked wording", "behavior": "the card and the show page's connection indicator both carry the Revoked key still presented label from the same helper, each rendering its own note seam's output", "layer": "request"}
    it "words the card and the page it links to from one seam" do
      repository = create_repository(user: @user, github_full_name: "acme/shared-revoked")
      key = present_revoked_key(repository, "CI")

      get repositories_path
      grid_text = page_text

      get repository_path(repository)
      indicator_text = Capybara.string(response.body).find("#connection-indicator").text.squish

      expect(grid_text).to include(revoked_label)
      expect(indicator_text).to include(revoked_label)
      # Each surface its own variant, and each asserted against the seam and not a literal.
      expect(grid_text).to include(
        ApplicationController.helpers.revoked_key_note(key.revoked_at, key.last_refused_at)
      )
      expect(indicator_text).to include(
        ApplicationController.helpers.revoked_keys_note(1, key.revoked_at, key.last_refused_at)
      )
    end

    # Criterion 5, in the shape the rotation block's own guard uses: every SELECT the index issues
    # against `api_keys`, on a grid whose markers actually render — a budget whose page never
    # renders the read it guards passes trivially. Every card here is revoked-and-presented, so
    # the read is carrying the widened partition and not merely the live one the old guard
    # exercised. Doubling the grid proves the 1 is a bound and not a coincidence of the fixture's
    # size.
    # @intent: {"entity": "ApiKey", "action": "batch key reads", "behavior": "three revoked-presented cards then six all render the revoked label while a single api_keys SELECT serves the whole grid at either size", "layer": "request"}
    it "asks the api_keys question once for the whole grid, however long the list is" do
      %w[acme/one acme/two acme/three].each do |full_name|
        present_revoked_key(create_repository(user: @user, github_full_name: full_name), "CI")
      end

      key_queries = queries_against('"api_keys"') { get repositories_path }

      expect(response).to have_http_status(:ok)
      # Every card really did render the marker, so every card really did ask.
      expect(page_text.scan(revoked_label).size).to eq(3)
      # One row read for the whole page — three cards must not cost three SELECTs.
      expect(key_queries.size).to eq(1)

      %w[acme/four acme/five acme/six].each do |full_name|
        present_revoked_key(create_repository(user: @user, github_full_name: full_name), "CI")
      end

      doubled = queries_against('"api_keys"') { get repositories_path }

      expect(page_text.scan(revoked_label).size).to eq(6)
      expect(doubled.size).to eq(1)
    end

    # Criterion 6 — the older signals must not change meaning because the read beneath them
    # widened. A rotated-then-revoked-then-presented key belongs to the revoked state, on the rule
    # `show`'s own rotation split states: the revocation is the newer and stronger fact. The
    # before/after readings bracket the whole collapse this ticket closes: before the revocation
    # the card renders the rotation marker over a 1-key badge; after it, every existing signal
    # goes quiet (the live-only row set excludes the key from both) and the card reads as a
    # repository nobody ever wired CI to; the presentation is what turns it back into a finding —
    # the revoked marker, the count still live-only at 0, and no rotation marker.
    # @intent: {"entity": "ApiKey", "action": "keep live partition", "behavior": "a stranded key renders the rotation marker over a 1-key badge until it is revoked and presented, then switches to the revoked marker over a 0-keys badge with no rotation marker", "layer": "request"}
    it "moves a rotated-then-revoked key out of the count and the rotation marker into the revoked state" do
      repository = create_repository(user: @user, github_full_name: "acme/retired-presented")
      key = strand_key(repository, "CI")
      token = key.raw_token

      get repositories_path
      # The pre-revocation reading, so the change this example claims is really observed.
      expect(card_text(repository)).to include(ApplicationController.helpers.rotated_key_label)
      expect(card_text(repository)).to include("1 key")
      expect(card_text(repository)).not_to include(revoked_label)

      key.revoke!

      get "/api/v1/repository", headers: { "Authorization" => "Bearer #{token}" }
      expect(response).to have_http_status(:unauthorized)

      get repositories_path

      text = card_text(repository)
      expect(text).to include(revoked_label)
      expect(text).to include("0 keys")
      expect(text).not_to include(ApplicationController.helpers.rotated_key_label)
    end

    # Criterion 7, and it is the honest bound the indicator's head comment states verbatim: a key
    # revoked and never presented again is not a finding, and nothing may be synthesized for it.
    # The card correctly stays quiet about the state — the only visible change is the count, which
    # reads the live partition.
    # @intent: {"entity": "ApiKey", "action": "not invent a presentation", "behavior": "a key revoked and never presented again produces no revoked marker on the card and no revoked sentence, while the key badge still drops to 0 keys", "layer": "request"}
    it "marks nothing for a key revoked and never presented again" do
      repository = create_repository(user: @user, github_full_name: "acme/quietly-retired")
      repository.api_keys.create!(name: "CI").revoke!

      get repositories_path

      text = card_text(repository)
      expect(text).not_to include(revoked_label)
      expect(text).not_to include("still being presented")
      expect(text).to include("0 keys")
    end
  end

  # SPGD-836 — registration access, stated on the page both return journeys land on.
  #
  # The gap these pin: `InstallationRepositories::MESSAGES[:not_granted]` refuses an `sgu_`
  # registration by naming a fix ("reconnect GitHub in a browser"), and for the account it fires on
  # the product offered that fix on no page. `/repositories` is where both ways back into the
  # browser land — `SessionsController#post_authorization_path` and
  # `GithubInstallationsController#destination` each fall back to `repositories_path` — and it said
  # nothing about GitHub connection state.
  #
  # ## The population, and why it is invisible to every existing gate
  #
  # This reader's App is installed and their session holds a live token. Only the SNAPSHOT is
  # missing or aged out (`GithubRegistrationGrant::MAX_AGE` is seven days). So
  # `github_authorization_needed?` is false in all three of its limbs and `github_installation_needed?`
  # is false too — both existing controls are correctly absent, which is precisely why a THIRD state
  # had to be read rather than an existing one reused.
  #
  # ## TWO STORIES, and the examples are split on that line rather than sharing one assertion
  #
  # `GrantVerifier` merges absent and stale into one verdict, correctly: it is answering "may this
  # request register?" and the answer is no either way. A landing page is not a refusal, and to a
  # READER the two are different facts — one snapshot AGED OUT, the other has NEVER BEEN TAKEN and
  # will be taken for free on the reader's next click. The `:never_taken` reader is not an edge
  # case: a grant is minted nowhere but a picker render, so EVERY newly-connected account is in that
  # state on its first visit, and the callback lands them precisely here.
  #
  # An earlier draft of this slice told both of them the same thing, and every example it carried
  # asserted on `lapsed_state` alone — the one sentence true of both — so nothing could see that the
  # prose composed AROUND it said "again" twice to somebody for whom nothing had happened yet. The
  # examples below therefore assert on the TITLE and the TAIL, which are the halves that differ.
  describe "registration access on the repositories index" do
    # The rendered state sentence, READ FROM THE SEAM rather than typed out here — the rule this
    # file already holds the refusal marker and the cost rows to, for the reason stated at
    # `refusal_label`: a literal copied into a spec is agreement that merely HOLDS TODAY, and would
    # go on passing against a page rendering the old words.
    def lapsed_state = ApplicationController.helpers.github_registration_lapsed_state

    # The panel itself and not the whole page, because the claims below are about what THIS panel
    # says: a bare `page_text` assertion on a word as ordinary as "again" would be answered by any
    # other sentence on the index. Identified by the one sentence both branches share. `nil` when no
    # panel rendered, which is what the silence examples assert.
    def registration_panel
      Capybara.string(response.body)
              .all(".rounded-md.border")
              .map { |node| node.text.gsub(/\s+/, " ").strip }
              .find { |text| text.include?(lapsed_state) }
    end

    # The App configured is the ordinary case and the one every example here is about. It is NOT the
    # default in this suite, and the unconfigured case has its own examples at the bottom — where
    # the point is that nothing renders at all.
    before { allow(SpecGuard::GithubApp).to receive_messages(configured?: true, slug: "specguard") }

    # Criterion 1, for the reader the ticket describes: a snapshot was taken and has aged out.
    # Registering nothing and opening no picker IS the criterion — the state is legible from the
    # landing page alone.
    describe "when the grant has aged out" do
      before do
        create_registration_grant(user: @user,
                                  captured_at: GithubRegistrationGrant::MAX_AGE.ago - 1.hour)
      end

      # @intent: {"entity": "GithubRegistrationGrant", "action": "say recheck needed", "behavior": "an aged-out grant renders the panel with the shared lapsed state and needs to check your GitHub permissions again", "layer": "request"}
      it "says the permissions need checking again" do
        get repositories_path

        expect(registration_panel).to include(lapsed_state)
        expect(registration_panel).to include("needs to check your GitHub permissions again")
      end

      # Criterion 2 — the existing action, reached through the existing helper. No new route was
      # minted, so this asserts against the ROUTE HELPER rather than a path spelled out here.
      # @intent: {"entity": "GithubRegistrationGrant", "action": "offer authorize action", "behavior": "the panel links the existing installation authorize path and offers a Reconnect to GitHub control", "layer": "request"}
      it "offers the existing authorize action as the fix" do
        get repositories_path

        expect(response.body).to include(github_installation_authorize_path)
        expect(registration_panel).to include("Reconnect to GitHub")
      end

      # ⚠ THE HALF THAT MAKES THE FIX A FIX, and the one deviation from the ticket's own build note.
      #
      # `github_authorize_button` defaults `return_to:` to `request.fullpath`, and the ticket read
      # that default as already correct here. It is not: a grant is taken in EXACTLY ONE place —
      # `GithubRepositoryListing#github_sources`, the sole `GithubRegistrationGrant.capture` site —
      # and this page deliberately never touches it. So a reconnect returning to `/repositories`
      # would hand back a credential the session already had, change nothing, and land the reader on
      # the same banner offering the same button.
      #
      # Driven to the OUTCOME rather than asserted as a `return_to=` string, because the claim is
      # that the grant stops being stale — a spec reading only the query parameter would pass
      # against a destination that repairs nothing.
      # @intent: {"entity": "GithubRegistrationGrant", "action": "end at grant retake", "behavior": "the reconnect carries return_to pointing at the new-repository picker, visiting that picker flips the grant from stale to fresh, and the panel then renders nothing", "layer": "request"}
      it "ends the reconnect journey where the grant is actually retaken" do
        stub_github(repos: [github_repo("acme/billing-service")])
        grant = GithubRegistrationGrant.find_by(user_id: @user.id)

        get repositories_path
        expect(response.body).to include(CGI.escapeHTML("return_to=#{CGI.escape(new_repository_path)}"))

        expect { get new_repository_path }.to change { grant.reload.stale? }.from(true).to(false)

        # And the page they were sent from now says nothing, because the state genuinely resolved.
        get repositories_path
        expect(registration_panel).to be_nil
      end
    end

    # ⚠ THE REGRESSION GUARD FOR THE DEFECT THIS ROUND EXISTS TO FIX — THE TOKEN AXIS.
    #
    # Every example in this describe until now signed in through `sign_in_via_github` with its
    # default `authorize: true`, so all of them sat on ONE side of an axis nothing here asserted on.
    # That is the same shape of blindness twice running: last round the invisible axis was `lapsed`
    # vs `never_taken`, and the examples asserted on the sentence common to both; this round it is
    # `token` vs `no token`, and the branch promised something only a token-holder can do.
    #
    # ## What was false, and why the suite could not see it
    #
    # A grant is minted in exactly one place, a picker render — and that render mints NOTHING
    # without a credential. `InstallationRepositories.sources` answers a blank token with
    # `error: :not_authorized`; `Sources#complete?` is `!truncated && error.nil?` and so is false;
    # and `GithubRegistrationGrant.capture` opens `return nil unless sources.complete?`. So the old
    # `:never_taken` copy — "open Register a repository once and SpecGuard will take one" — sent
    # this reader to a picker that mints nothing, asks them to reconnect, and returns them to the
    # identical panel. A LOOP, and the copy told them there was nothing else to do.
    #
    # The state is ordinary, not an edge case: a user-to-server token is short-lived and lives only
    # in the session (`GithubUserSession`), so this is where a returning reader starts every new
    # browser session — App installed, nothing to read it with.
    #
    # These examples drive the JOURNEY to its OUTCOME rather than reading the panel's words, because
    # the defect was precisely a true-looking sentence with a false destination.
    describe "when the session holds no GitHub credential" do
      # The real state, produced by the real path: re-signing in with `authorize: false` records the
      # installation WITHOUT the credential, which is what the helper's own comment advertises. Same
      # user throughout — this is one person's second browser session, not a second account.
      before { @user = sign_in_via_github(authorize: false) }

      # @intent: {"entity": "GithubRegistrationGrant", "action": "skip picker advice", "behavior": "a session holding no GitHub credential renders the lapsed panel saying Reconnect GitHub and never tells the reader to open Register a repository", "layer": "request"}
      it "does not tell a reader with no credential to go and open the picker" do
        get repositories_path

        expect(registration_panel).to include(lapsed_state)
        expect(registration_panel).to include("Reconnect GitHub")
        expect(registration_panel).not_to include("Open Register a repository")
      end

      # THE LOOP ITSELF, CLOSED — the example the old branch could not have passed. Following the
      # instruction now ends with a grant, where before the panel redrew unchanged forever.
      #
      # Driven to the OUTCOME rather than read off the button, and the journey is driven in its two
      # real halves: the reconnect restores the CREDENTIAL, and the picker it returns to is where
      # the SNAPSHOT is taken. `return_to` is asserted because it is what joins them — a reconnect
      # landing back here would restore the credential and mint nothing, which is the same loop one
      # step further along.
      # @intent: {"entity": "GithubRegistrationGrant", "action": "offer minting fix", "behavior": "following the reconnect restores the credential, the return_to picker mints the account's first grant, and the panel disappears on the next render", "layer": "request"}
      it "offers a fix that actually mints the grant" do
        stub_github(repos: [github_repo("acme/billing-service")])
        get repositories_path

        expect(response.body).to include(github_installation_authorize_path)
        expect(registration_panel).to include("Reconnect to GitHub")
        expect(response.body).to include(CGI.escapeHTML("return_to=#{CGI.escape(new_repository_path)}"))

        authorize_github_app

        expect { get new_repository_path }
          .to change { GithubRegistrationGrant.find_by(user_id: @user.id) }.from(nil)

        # ⚠ RE-STUBBED DELIBERATELY. `authorize_github_app` restores `configured?` to its real value
        # in an `ensure` block, and in this environment that is FALSE — which suppresses the whole
        # panel. Without this line the assertion below would pass because no panel can render at
        # all, rather than because the state resolved: a vacuous green dressed as the real one.
        allow(SpecGuard::GithubApp).to receive_messages(configured?: true, slug: "specguard")

        get repositories_path
        expect(registration_panel).to be_nil
      end

      # The counterfactual that gives the example above its teeth: BEFORE the credential comes
      # back, opening the picker mints nothing however many times it is opened. This is the dead end
      # the old copy walked the reader into, pinned so it cannot be re-introduced as advice.
      # @intent: {"entity": "GithubRegistrationGrant", "action": "refuse picker resolution", "behavior": "opening the picker three times before the credential returns mints no grant at all, which is why the picker is not offered as the fix", "layer": "request"}
      it "cannot be resolved by opening the picker, which is why it is not offered" do
        stub_github(repos: [github_repo("acme/billing-service")])

        expect { 3.times { get new_repository_path } }
          .not_to change { GithubRegistrationGrant.find_by(user_id: @user.id) }.from(nil)
      end

      # ⚠ THE SECOND FALSE CLAUSE, which was on the OTHER branch and is fixed by the same split.
      # `:lapsed` reassures the reader that "registering here in the browser is unaffected". For a
      # credential-less reader that is untrue — the picker offers them a reconnect, not a
      # repository — and before this split a lapsed grant plus a dead session rendered exactly that
      # sentence. Routing on the credential FIRST is what makes the reassurance true where it is
      # still said.
      # @intent: {"entity": "GithubRegistrationGrant", "action": "drop false reassurance", "behavior": "a lapsed grant plus a credential-less session renders Reconnect GitHub and never the browser-is-unaffected promise", "layer": "request"}
      it "does not promise the browser path is unaffected when it is not" do
        create_registration_grant(user: @user,
                                  captured_at: GithubRegistrationGrant::MAX_AGE.ago - 1.hour)

        get repositories_path

        expect(registration_panel).not_to include("browser is unaffected")
        expect(registration_panel).to include("Reconnect GitHub")
      end

      # Criterion 5 for this population too. The credential is read from the SIGNED SESSION —
      # `github_user_token`, not `github_authorization_needed?`, whose `GithubRepositoryListing`
      # override would force `github_sources` and both call GitHub and repair the grant.
      # @intent: {"entity": "GithubRegistrationGrant", "action": "add no round trip", "behavior": "the panel renders for a credential-less reader while the stubbed GitHub client records zero calls to repositories", "layer": "request"}
      it "adds no GitHub round trip" do
        fake = stub_github(repos: [github_repo("acme/billing-service")])

        get repositories_path

        expect(registration_panel).to be_present
        expect(fake.calls_to(:repositories)).to eq(0)
      end
    end

    # ⚠ THE REGRESSION GUARD FOR THE DEFECT THIS ROUND EXISTS TO FIX — THE INSTALLATION AXIS.
    #
    # Third round, third invisible axis, and the worst of the three outcomes. Round 1's axis was
    # `lapsed` vs `never_taken`; round 2's was `token` vs `no token`; this one is `installed` vs
    # `not installed`. Each time the branch made a promise that was true for the population the
    # examples exercised and false for the one they did not.
    #
    # ## What was false, and why it is worse than the previous two
    #
    # `:session_expired` correctly requires `github_installed?`, so a reader with NO installation
    # fell through to `:never_taken` — on BOTH sides of the token axis. That branch told them to open
    # the picker and promised "registering here in the browser works now". The picker offers this
    # reader no repository at all; it asks them to connect the App.
    #
    # Then the part that weighs heaviest. `InstallationRepositories.sources` answers a user with no
    # installations with `blank_sources(installed: false)` — NO error and NOT truncated — so
    # `Sources#complete?` is TRUE and `capture` writes an EMPTY BUT FRESH grant. Opening the picker
    # therefore made `grant.nil? || grant.stale?` false, the panel DISAPPEARED, and
    # `POST /api/v1/repositories` went on refusing with `:not_in_installation` — a refusal no branch
    # here describes. Rounds 1 and 2 produced a LOOP, which is recoverable because the panel stays
    # and the picker offers its own escape. This produced a FALSE ALL-CLEAR: the reader followed the
    # instruction, the warning vanished, and nothing on the page would ever tell them again.
    #
    # The population is in scope by construction, not an edge imported to make a point. Criterion 1
    # is "grant is absent or stale" and theirs is absent; `GithubInstallationsController#callback`
    # records nothing when a user cancels out of GitHub's picker (its own comment names that case),
    # `require_authentication` lands anyone installing from the App's listing here, and this is every
    # brand-new signup's first page.
    #
    # ## Why the previous round's examples could not see it
    #
    # This describe already set the population up correctly. Its two examples asserted that the
    # reconnect was absent — true, and equally true of the WRONG branch — and that the picker minted
    # a grant, which PINNED THE EXACT MECHANISM THAT PRODUCES THE FALSE ALL-CLEAR AS THOUGH IT WERE
    # THE FIX. Neither read the branch's own promise or asked what the API said afterwards. So these
    # drive to the OUTCOME, and the first one drives the whole journey the old copy prescribed.
    describe "when no installation has been connected at all" do
      # Re-signing in clears the session credential (`SessionsController` resets the session on the
      # way IN, per `GithubUserSession`), but `installation: false` only declines to record a NEW
      # row — the one the outer sign-in already wrote survives, and `github_installed?` would still
      # be true. Removing it is what actually produces "no installation", and asserting that here
      # keeps the example honest about which state it is really in.
      before do
        @user = sign_in_via_github(authorize: false, installation: false)
        @user.github_installations.destroy_all
        expect(@user.reload.github_installed?).to be(false)
      end

      # ⭐ THE COUNTERFACTUAL — drive to the outcome and ask the page again after a picker visit.
      #
      # It opens the picker once — the OLD branch's prescription — and then asks the page again.
      # The claim is not about wording: it is that the state remains OBSERVABLE on the page built
      # to render it. Since #808 the picker visit does not even MINT a grant in this state:
      # `GithubRegistrationGrant.capture` refuses when the person holds no installation rows,
      # precisely so a fresh-but-empty grant cannot flip the verdict to a false
      # `:not_in_installation`. So the hazard this example pins is now the ABSENCE of a grant —
      # asserted as the fact it is, and the panel must still name the true state.
      # @intent: {"entity": "GithubRegistrationGrant", "action": "persist state after picker", "behavior": "with no installation connected a picker visit mints no grant, the panel still renders naming not installed on any of your GitHub accounts, and the verifier still answers not_granted", "layer": "request"}
      it "keeps saying so after a picker visit, which does not mint a grant" do
        stub_github(repos: [github_repo("acme/billing-service")])

        get repositories_path
        expect(registration_panel).to be_present

        # The picker visit: it reads the sources (the lazy capture point) and GitHub answers,
        # but no grant may be built from "no installation" — absence is not an answer.
        get new_repository_path
        expect(GithubRegistrationGrant.find_by(user_id: @user.id)).to be_nil

        # ...and the page must NOT read the state as resolved, because the API has not resolved.
        get repositories_path
        expect(registration_panel).to be_present
        expect(registration_panel).to include("not installed on any of your GitHub accounts")

        # The ground truth the panel is answerable to: still refused — and refused as
        # :not_granted ("SpecGuard has no current record…"), the nil-grant reading, rather than
        # either of the answers a minted grant could have produced.
        verdict = RepositoryRegistration::GrantVerifier.new(grant: nil)
                                                       .verdict_for("acme/billing-service")
        expect(verdict.status).to eq(:not_granted)
      end

      # The two promises the old copy made to this reader, asserted as the falsehoods they were.
      # `page_text` for the picker claim rather than `registration_panel`, because the sentence must
      # be absent from the panel AND not reintroduced anywhere else on the page.
      # @intent: {"entity": "GithubRegistrationGrant", "action": "promise nothing falsely", "behavior": "the panel offers none of the old promises, not registering here in the browser works now, not SpecGuard will take one, and not One more step", "layer": "request"}
      it "promises neither a snapshot nor a working browser registration" do
        get repositories_path

        expect(registration_panel).not_to include("registering here in the browser works now")
        expect(registration_panel).not_to include("SpecGuard will take one")
        expect(registration_panel).not_to include("One more step")
      end

      # Criterion 2 for this population: the missing thing is the INSTALLATION, so the control is
      # the install action and not the reconnect — a credential would read an installation that does
      # not exist. Both asserted against ROUTE HELPERS, so no new route can satisfy this.
      # @intent: {"entity": "GithubRegistrationGrant", "action": "offer install action", "behavior": "the panel links the existing install path with Connect repositories on GitHub, and neither the authorize path nor any Reconnect wording appears", "layer": "request"}
      it "offers the existing install action and not the reconnect" do
        get repositories_path

        expect(response.body).to include(github_installation_path)
        expect(registration_panel).to include("Connect repositories on GitHub")
        expect(response.body).not_to include(github_installation_authorize_path)
        expect(registration_panel).not_to include("Reconnect GitHub to finish")
      end

      # Criterion 5 for this population too — the whole story is read from `github_installed?`, one
      # `EXISTS` against our own table, and no listing helper is reached on this path.
      # @intent: {"entity": "GithubRegistrationGrant", "action": "add no round trip", "behavior": "the panel renders for an uninstalled reader while the stubbed client records zero repositories calls, the state being read from the local installation rows", "layer": "request"}
      it "adds no GitHub round trip" do
        fake = stub_github(repos: [github_repo("acme/billing-service")])

        get repositories_path

        expect(registration_panel).to be_present
        expect(fake.calls_to(:repositories)).to eq(0)
      end
    end

    # ⚠ THE REGRESSION GUARD FOR THE DEFECT THE PREVIOUS ROUND EXISTED TO FIX.
    #
    # A grant is minted only on a picker render — not at sign-in and not by the App callback, which
    # is the deliberate decision at `github_repository_listing.rb:43-49`. So this is the state of
    # somebody who connected the App ONE REDIRECT AGO, and of every fully-onboarded account on its
    # first visit. The earlier draft told them, directly beneath "Connected acme.", that SpecGuard
    # needed to check their permissions AGAIN and would refuse UNTIL IT IS TAKEN AGAIN. Both are
    # false: nothing has been taken, so nothing can have expired.
    describe "when no grant has ever been taken" do
      # @intent: {"entity": "GithubRegistrationGrant", "action": "claim nothing expired", "behavior": "with no grant ever taken the panel shows the shared lapsed state but never the word again", "layer": "request"}
      it "does not claim anything expired or needs re-checking" do
        expect(GithubRegistrationGrant.find_by(user_id: @user.id)).to be_nil

        get repositories_path

        expect(registration_panel).to include(lapsed_state)
        expect(registration_panel).not_to include("again")
      end

      # ⚠ AND THE CONSEQUENCE THAT WEIGHS HEAVIEST: for this reader the reconnect is not merely
      # mis-worded, it is WORSE than what the page already had. They hold a live token; nothing
      # about their credential is missing, and the only thing needed is that somebody calls
      # `github_sources`. "Reconnect to GitHub" would send them out to github.com and back — while
      # "Register a repository", already in this page's header, reaches the same picker with no
      # external round trip at all. Offering it would talk them out of a one-hop fix into a
      # three-hop one.
      # @intent: {"entity": "GithubRegistrationGrant", "action": "skip reconnect offer", "behavior": "the page renders no authorize path and no Reconnect to GitHub, because the picker already in the header is the shorter fix", "layer": "request"}
      it "offers no external reconnect round trip" do
        get repositories_path

        expect(response.body).not_to include(github_installation_authorize_path)
        expect(registration_panel).not_to include("Reconnect to GitHub")
      end

      # @intent: {"entity": "GithubRegistrationGrant", "action": "point at picker", "behavior": "the panel says Register a repository, the control the page header already offers", "layer": "request"}
      it "points at the picker the page already offers" do
        get repositories_path

        expect(registration_panel).to include("Register a repository")
      end

      # The promise that copy makes, driven to its outcome: opening the picker once really is the
      # whole fix. Without this the sentence above would be an unverified instruction.
      # @intent: {"entity": "GithubRegistrationGrant", "action": "resolve via picker", "behavior": "opening the picker once mints the account's first grant and the panel renders nothing on the next visit", "layer": "request"}
      it "is resolved by opening that picker once" do
        stub_github(repos: [github_repo("acme/billing-service")])

        expect { get new_repository_path }
          .to change { GithubRegistrationGrant.find_by(user_id: @user.id) }.from(nil)

        get repositories_path
        expect(registration_panel).to be_nil
      end
    end

    # The bound itself, from the inside — a grant one hour short of MAX_AGE still redeems, so it
    # must not be drawn as lapsed. Without this the examples above would pass just as happily
    # against a page that showed the panel to everybody.
    describe "when the grant is current" do
      before { create_registration_grant(user: @user) }

      # @intent: {"entity": "GithubRegistrationGrant", "action": "silence current grant", "behavior": "a grant inside the age bound renders no panel at all", "layer": "request"}
      it "says nothing to a person whose grant is inside the bound" do
        get repositories_path

        expect(registration_panel).to be_nil
      end

      # Criterion 4, stated as the absence of the CONTROL and not only of the sentence. A
      # current-grant reader's page is unchanged, which means no button either — asserting the
      # sentence alone would let a stray reconnect button survive on every render.
      # @intent: {"entity": "GithubRegistrationGrant", "action": "offer no new chrome", "behavior": "a current-grant reader sees neither the lapsed sentence nor the authorize path anywhere on the page", "layer": "request"}
      it "offers a person with a current grant no new chrome" do
        get repositories_path

        expect(page_text).not_to include(lapsed_state)
        expect(response.body).not_to include(github_installation_authorize_path)
      end
    end

    # ⚠ THE SECOND DEFECT THIS REWORK FIXES: an alert rendered INSIDE an alert.
    #
    # `github_authorize_button` returns `github_app_unconfigured_notice` — itself a rendered
    # `UI::AlertComponent` — when the App is unconfigured, and the earlier draft invoked it inside
    # the panel's own alert. That produced a warning panel bordered inside a warning panel, with a
    # reader-facing sentence wrapped around an operator-facing one. The three pre-existing call
    # sites never hit it: `_form.html.erb` and `bulk_registrations/new.html.erb` both render the
    # button inside an `EmptyStateComponent`.
    #
    # It escaped the suite entirely because `configured?` is FALSE by default in this environment
    # and every example above stubs it true. So these two do not stub it — which is the only reason
    # they can see this at all.
    describe "when the GitHub App is not configured" do
      before { allow(SpecGuard::GithubApp).to receive(:configured?).and_call_original }

      # @intent: {"entity": "GithubRegistrationGrant", "action": "render nothing unconfigured", "behavior": "with the GitHub App unconfigured the index renders no lapsed-state sentence at all, there being no control to offer", "layer": "request"}
      it "renders no panel, because there is no control to offer anyone" do
        expect(SpecGuard::GithubApp).not_to be_configured

        get repositories_path

        expect(page_text).not_to include(lapsed_state)
      end

      # The specific shape of the breakage, pinned rather than left to the assertion above: the
      # operator notice must not appear WRAPPED IN the reader's panel. It has its own home on the
      # connect paths, where an operator meets it without a reader-facing sentence around it.
      # @intent: {"entity": "GithubRegistrationGrant", "action": "avoid nested notice", "behavior": "the operator-facing unconfigured-app sentence never appears on the reader's page, so it cannot nest inside a reader-facing alert", "layer": "request"}
      it "does not nest the operator notice inside a reader-facing alert" do
        get repositories_path

        expect(page_text).not_to include("The SpecGuard GitHub App is not configured")
      end
    end

    # Criterion 5 — the load-bearing one, and the reason this page reads the GRANT and not the
    # LISTING. `RepositoriesController` already includes `GithubRepositoryListing`, so every listing
    # helper is in scope on this action and reaching for the obvious-looking one would both add a
    # GitHub round trip to the most-visited page in the product AND silently repair the grant,
    # making the very state under test unobservable on the page that renders it.
    #
    # Asserted for ALL FOUR populations — never-taken, session-expired, lapsed and current — per the
    # `repository_github_verification_spec.rb:232` precedent: a zero that only holds for one of them
    # would miss exactly the branches this adds. The session-expired one is pinned in its own
    # describe above, beside the rest of that branch's claims.
    describe "its cost" do
      # @intent: {"entity": "GithubRegistrationGrant", "action": "add no round trip", "behavior": "a reader who has never had a grant still gets the panel while the stubbed client records zero repositories calls", "layer": "request"}
      it "adds no GitHub round trip for a reader who has never had a grant" do
        fake = stub_github(repos: [github_repo("acme/billing-service")])

        get repositories_path

        expect(registration_panel).to be_present
        expect(fake.calls_to(:repositories)).to eq(0)
      end

      # @intent: {"entity": "GithubRegistrationGrant", "action": "add no round trip", "behavior": "a lapsed-grant reader gets the panel while the stubbed client records zero repositories calls", "layer": "request"}
      it "adds no GitHub round trip for a lapsed-grant reader" do
        create_registration_grant(user: @user,
                                  captured_at: GithubRegistrationGrant::MAX_AGE.ago - 1.hour)
        fake = stub_github(repos: [github_repo("acme/billing-service")])

        get repositories_path

        expect(registration_panel).to be_present
        expect(fake.calls_to(:repositories)).to eq(0)
      end

      # @intent: {"entity": "GithubRegistrationGrant", "action": "add no round trip", "behavior": "a current-grant reader's render makes zero repositories calls to the stubbed client", "layer": "request"}
      it "adds no GitHub round trip for a current-grant reader" do
        create_registration_grant(user: @user)
        fake = stub_github(repos: [github_repo("acme/billing-service")])

        get repositories_path

        expect(fake.calls_to(:repositories)).to eq(0)
      end

      # The other half of "no round trip", and NOT a restatement of it: the round-trip examples
      # above would still pass if the render had repaired the grant from some other reading. The
      # state a reader is shown must survive being looked at — a page that healed the grant as a
      # side effect of rendering it would show the panel once and never again, with nothing else in
      # the suite able to see it.
      # @intent: {"entity": "GithubRegistrationGrant", "action": "not repair on render", "behavior": "rendering the index twice creates no grant rows and the panel stays present, so the state survives being looked at", "layer": "request"}
      it "does not repair the grant as a side effect of rendering it" do
        stub_github(repos: [github_repo("acme/billing-service")])

        expect { 2.times { get repositories_path } }.not_to change(GithubRegistrationGrant, :count)
        expect(registration_panel).to be_present
      end
    end

    # Criterion 3 — the wording, pinned to the constant from BOTH directions so the browser sentence
    # and the API's 400 cannot drift apart.
    #
    # Substring alone is too weak a claim to leave alone: it would hold for a helper that returned
    # the WHOLE fragment, which on this page would tell a signed-in reader looking at a browser that
    # their repository "cannot be registered from an API key" and then instruct them to sign in to
    # SpecGuard in a browser. Both of those clauses are about the surface the refusal arrived on, so
    # the second and third expectations pin that the slice is the STATE half and nothing else.
    describe "its wording" do
      # @intent: {"entity": "GithubRegistrationGrant", "action": "read wording from constant", "behavior": "the API's not_granted message in InstallationRepositories MESSAGES includes the helper's lapsed-state wording, so the browser sentence and the 400 cannot drift", "layer": "request"}
      it "is read from InstallationRepositories::MESSAGES rather than written again" do
        expect(InstallationRepositories::MESSAGES[:not_granted]).to include(lapsed_state)
      end

      # @intent: {"entity": "GithubRegistrationGrant", "action": "carry browser-true half", "behavior": "the lapsed-state slice mentions neither API key nor browser, dropping the halves only true of the API surface", "layer": "request"}
      it "carries only the half that is true of a browser reader" do
        expect(lapsed_state).not_to include("API key")
        expect(lapsed_state).not_to include("browser")
      end

      # The shared sentence has to be true of BOTH populations, which is what lets one slice serve
      # two branches: "no current record" is a statement about what SpecGuard holds, and it is
      # equally true of a snapshot that expired and one that was never taken. Anything stronger
      # would be a lie to one of them — which is the whole reason the prose AROUND it is split.
      # @intent: {"entity": "GithubRegistrationGrant", "action": "state shared fact", "behavior": "the lapsed-state sentence includes no current record, true of both an expired and a never-taken snapshot, and never the word again", "layer": "request"}
      it "states the shared fact both surfaces and both readers are about" do
        expect(lapsed_state).to include("no current record")
        expect(lapsed_state).not_to include("again")
      end
    end

    # Criterion 6, and the invariant the whole slice rests on: the grant still has exactly one mint
    # point. A second capture site is the failure mode this design exists to avoid, and it is the
    # kind that is invisible in behaviour — the page would work, and the mechanism's stated cost
    # ("adds ZERO GitHub round trips") would quietly stop being true.
    #
    # Comment lines are stripped before counting, and that is a correction rather than a loophole.
    # The criterion is written as a verbatim `git grep`, which this tree also satisfies — but a grep
    # counts PROSE, so writing the method's own name in a comment explaining why it must not be
    # called a second time would fail this example while adding no call site at all. (That is not
    # hypothetical: the first draft of this slice did exactly that, twice.) What must stay at one is
    # the number of places that CALL it, so that is what is counted.
    # @intent: {"entity": "GithubRegistrationGrant", "action": "keep one capture site", "behavior": "scanning app and lib for non-comment calls to GithubRegistrationGrant.capture finds exactly one site, the one passing sources", "layer": "request"}
    it "leaves the grant with exactly one capture call site" do
      sites = Dir.glob(Rails.root.join("{app,lib}/**/*.rb")).flat_map do |path|
        File.readlines(path)
            .reject { |line| line.strip.start_with?("#") }
            .grep(/GithubRegistrationGrant\.capture/)
      end

      expect(sites.size).to eq(1)
      expect(sites.first).to include("sources: sources")
    end
  end

  # SPGD-802 — narrowing controls on the repositories index: `?q=`, `?role=`, `?sort=stale`.
  #
  # One "Register several" gesture can put a hundred repositories on an account
  # (`BulkRegistration::MAX_BATCH`), and until these parameters the page that received them read NO
  # parameter at all — a card grid whose only two header controls both made the list longer. The
  # three asks compose (`?q=api&role=shared&sort=stale`), and the URL is their only carrier: no
  # session state, no form state, nothing a colleague receiving a pasted link does not also receive.
  #
  # ## The guards, and why the malformed coverage lives in shared examples
  #
  # Each parameter is read through its own `Requested*Param` concern — `requested_search_param.rb`,
  # `requested_role_param.rb`, `requested_sort_param.rb` — on the same two-line shape every sibling
  # uses (`is_a?(String)` first, `.presence` second, memoised with `defined?`). The non-String
  # shapes are pinned once per parameter in `spec/support/shared_examples/malformed_{search,role,sort}_param.rb`
  # and hosted below, rather than re-listed here: that is the idiom the sibling parameters already
  # follow, and a second idiom for the same hazard is a place for the two to drift.
  #
  # ## What the guards are FOR here
  #
  # `?q[]=` reaches an `ILIKE`, and an Array would not raise — it would answer a question nobody
  # asked, under a search box echoing an ask nobody made. The hosts below assert the NO-ASK answer
  # specifically (every card, default order), never a bare 200, for the reason each shared example's
  # own doc comment carries: a guard that swallowed every value would also answer 200 on every
  # shape, and only the positive-path example beside the host separates the two.
  describe "narrowing the repositories index" do
    # Cards are links, so the SEQUENCE the page renders is read straight off their hrefs — which
    # is what the ordering examples are about, not merely which cards are present. The repository
    # links are the only `a[href]` on the page matching `/repositories/<digits>`, so the nav and
    # the header buttons cannot perturb the order this reads.
    def rendered_card_paths
      Capybara.string(response.body).find_all("a").map { |a| a[:href] }
             .select { |href| href.match?(%r{/repositories/\d+\z}) }
    end

    describe "?q= — finding one repository by part of its name" do
      it "matches a case-insensitive substring of the full name" do
        create_repository(user: @user, github_full_name: "acme/billing-service")
        create_repository(user: @user, github_full_name: "acme/ledger")

        get repositories_path, params: { q: "BILLING" }

        expect(response).to have_http_status(:ok)
        expect(page_text).to include("acme/billing-service")
        expect(page_text).not_to include("acme/ledger")
      end

      # The `_` and `%` a reader can legitimately type are TEXT in a repository name (`org/my_repo`
      # is an ordinary slug), so an unescaped `ILIKE` would widen "my_repo" to match `myxrepo` —
      # answering a substring ask with a pattern match. `sanitize_sql_like` escapes them, and this
      # is the example that keeps it true: drop the escape and this goes red without anything
      # raising anywhere else in the suite.
      it "treats a typed underscore as text, not as a single-character wildcard" do
        create_repository(user: @user, github_full_name: "acme/my_repo")
        create_repository(user: @user, github_full_name: "acme/myxrepo")

        get repositories_path, params: { q: "my_repo" }

        expect(page_text).to include("acme/my_repo")
        expect(page_text).not_to include("acme/myxrepo")
      end

      # The narrowing must happen IN SQL INSIDE `Repository.accessible_by`, never as a post-load
      # filter — this is the security claim of the parameter, and it is a property of the
      # STATEMENT. Captured off the wire (`captured_sql`, the shared subscriber) rather than
      # re-spelled here, so a read that stopped being in-scope cannot pass by agreeing with a
      # hand-written duplicate: the accessibility union and the `ILIKE` must be predicates of ONE
      # WHERE on ONE read of `repositories`.
      #
      # The first statement captured is the view's `any?` EXISTS, and that is fine for the claim:
      # the EXISTS carries the accessibility union AND the `ILIKE` in the same WHERE, which is
      # exactly the property being pinned — the database, not Ruby, is doing the narrowing.
      it "narrows inside the accessible scope in SQL, not as a post-load filter" do
        create_repository(user: @user, github_full_name: "acme/billing-service")

        sql = captured_sql('FROM "repositories"') { get repositories_path, params: { q: "billing" } }

        expect(page_text).to include("acme/billing-service")
        expect(sql).to match(/ILIKE/)
        # ...and the accessibility union is still in the SAME statement: the search did not become
        # a second pass over a set that had already been resolved, which is where a post-load
        # filter would show up as two friendly-looking queries.
        expect(sql).to match(/"user_id" = /)
        expect(sql).to match(/IN \(SELECT "repository_memberships"/)
      end

      # The other half of being in-scope: a repository the viewer cannot see must never ENTER the
      # relation, so a name search cannot be turned into an existence probe. `page_text` rather
      # than `response.body`, deliberately — the search field legitimately echoes the ask as an
      # input VALUE, and an attribute is not a disclosure; a rendered NAME would be.
      it "cannot be used to probe for a repository the viewer cannot see" do
        stranger = create_user(github_uid: "7777", github_handle: "stranger")
        create_repository(user: stranger, github_full_name: "other/secret-api")
        create_repository(user: @user, github_full_name: "acme/billing-service")

        get repositories_path, params: { q: "secret-api" }

        expect(response).to have_http_status(:ok)
        # A filtered-empty answer, worded for this reader — never the stranger's repository, and
        # never an error that would distinguish "matched nothing" from "does not exist".
        expect(page_text).not_to include("other/secret-api")
        expect(page_text).not_to include("stranger")
        expect(page_text).to include("No repositories match")
      end

      # The positive path beside the malformed host below: `?q=<text>` IS honoured, which is what
      # separates a working guard from one that swallows every shape — including the shapes the
      # host asserts are no-asks.
      it "is honoured as a narrowing ask, not merely tolerated" do
        create_repository(user: @user, github_full_name: "acme/billing-service")
        create_repository(user: @user, github_full_name: "acme/ledger")

        get repositories_path, params: { q: "ledger" }

        expect(rendered_card_paths).to eq([repository_path(Repository.find_by(github_full_name: "acme/ledger"))])
      end

      describe "a search parameter that is not a search string" do
        def expect_search_param_treated_as_no_ask(query)
          create_repository(user: @user, github_full_name: "acme/one")
          create_repository(user: @user, github_full_name: "acme/two")

          get repositories_path, params: query

          expect(response).to have_http_status(:ok)
          # The no-ask answer specifically: every card, in the default order.
          expect(rendered_card_paths).to eq(
            [repository_path(Repository.find_by(github_full_name: "acme/one")),
             repository_path(Repository.find_by(github_full_name: "acme/two"))]
          )
        end

        it_behaves_like "a surface that treats a malformed search parameter as no ask"
      end
    end

    describe "?role= — what you own versus what was shared" do
      # One of each population, so every example below proves the LINE rather than a presence:
      # an ask honoured shows its side and hides the other, an ask ignored shows both. `let!`
      # because the read happens in the request, not in an expression that would force the `let`.
      let!(:owned) { create_repository(user: @user, github_full_name: "acmine/owned") }
      let!(:shared) do
        colleague = create_user(github_uid: "8888", github_handle: "colleague")
        repository = create_repository(user: colleague, github_full_name: "other/shared")
        create_membership(repository: repository, user: @user)
        repository
      end

      it "narrows to what was shared with the viewer" do
        get repositories_path, params: { role: "shared" }

        expect(rendered_card_paths).to eq([repository_path(shared)])
      end

      it "narrows to what the viewer owns" do
        get repositories_path, params: { role: "owned" }

        expect(rendered_card_paths).to eq([repository_path(owned)])
      end

      # `shared` is the COMPLEMENT WITHIN the accessible set — not a second reading of the
      # membership table — so the two asks must partition the unparameterised page exactly, with
      # no repository on both sides and none dropped between them. That partition is what makes
      # the badge's distinction safe to hand a filter on.
      it "partitions the page exactly between the two asks" do
        get repositories_path, params: { role: "shared" }
        shared_side = rendered_card_paths

        get repositories_path, params: { role: "owned" }
        owned_side = rendered_card_paths

        get repositories_path
        whole_page = rendered_card_paths

        expect((shared_side + owned_side).sort).to eq(whole_page.sort)
        expect(shared_side & owned_side).to be_empty
      end

      describe "a role parameter that names no ownership state" do
        def expect_role_param_treated_as_no_ask(query)
          get repositories_path, params: query

          expect(response).to have_http_status(:ok)
          # The no-ask answer specifically: BOTH populations, which is what distinguishes a
          # clamped read from one that silently narrowed to either side.
          expect(rendered_card_paths).to contain_exactly(repository_path(owned), repository_path(shared))
        end

        it_behaves_like "a surface that treats a non-owned-or-shared role parameter as no ask"
      end
    end

    describe "?sort=stale — ordering by last-ingested recency" do
      it "puts never-ingested first and the most recently ingested last" do
        never = create_repository(user: @user, github_full_name: "acme/never-wired")
        oldest = create_repository(user: @user, github_full_name: "acme/oldest")
        newest = create_repository(user: @user, github_full_name: "acme/newest")
        create_test_run(repository: oldest, commit_sha: "cafe0301", total_specs_count: 10,
                        created_at: 3.months.ago)
        create_test_run(repository: newest, commit_sha: "cafe0302", total_specs_count: 10,
                        created_at: 1.hour.ago)

        get repositories_path, params: { sort: "stale" }

        expect(rendered_card_paths).to eq(
          [repository_path(never), repository_path(oldest), repository_path(newest)]
        )
      end

      # A shareable URL is a deterministic one: two readers pasting the same link must see the
      # same cards in the same order, and `sort_by` does not promise stability on its own — the
      # name tie-break does. Same-input ties here, so the order this asserts is entirely the
      # tie-break's.
      it "breaks equal-recency ties on the name so the sequence is deterministic" do
        create_repository(user: @user, github_full_name: "acme/zebra")
        create_repository(user: @user, github_full_name: "acme/alpha")

        get repositories_path, params: { sort: "stale" }

        expect(rendered_card_paths).to eq(
          [repository_path(Repository.find_by(github_full_name: "acme/alpha")),
           repository_path(Repository.find_by(github_full_name: "acme/zebra"))]
        )
      end

      describe "a sort parameter that names no ordering" do
        # Recency and name DISAGREE about the order here, so a clamped read and an honoured one
        # render different sequences: this is what lets the no-ask assertion say "name order" and
        # mean it.
        def expect_sort_param_treated_as_no_ask(query)
          stale = create_repository(user: @user, github_full_name: "acme/stale")
          fresh = create_repository(user: @user, github_full_name: "acme/fresh")
          create_test_run(repository: fresh, commit_sha: "cafe0401", total_specs_count: 10,
                          created_at: 1.hour.ago)

          get repositories_path, params: query

          expect(response).to have_http_status(:ok)
          expect(rendered_card_paths).to eq([repository_path(fresh), repository_path(stale)])
        end

        it_behaves_like "a surface that treats a non-stale sort parameter as no ask"
      end
    end

    describe "the three asks together" do
      it "compose — search, ownership and order in one URL" do
        colleague = create_user(github_uid: "8888", github_handle: "colleague")
        fresh_shared = create_repository(user: colleague, github_full_name: "acme/api-shared")
        create_membership(repository: fresh_shared, user: @user)
        stale_shared = create_repository(user: colleague, github_full_name: "acme/api-legacy")
        create_membership(repository: stale_shared, user: @user)
        other_shared = create_repository(user: colleague, github_full_name: "acme/web-shop")
        create_membership(repository: other_shared, user: @user)
        create_repository(user: @user, github_full_name: "acme/api-owned")
        create_test_run(repository: fresh_shared, commit_sha: "cafe0501", total_specs_count: 10,
                        created_at: 1.hour.ago)

        get repositories_path, params: { q: "api", role: "shared", sort: "stale" }

        # The never-ingested shared api match first, the ingested one last; the owned api match
        # and the shared non-match are both gone.
        expect(rendered_card_paths).to eq(
          [repository_path(stale_shared), repository_path(fresh_shared)]
        )
      end

      # The URL is the only carrier, so a pasted link must open the same way for a colleague who
      # holds access to what it matches — the filter carries no state of the first reader's
      # session. Signed in as the second identity through the same callback a browser would use.
      it "opens the same way for a colleague the match was shared with" do
        repository = create_repository(user: @user, github_full_name: "acme/api-service")
        create_repository(user: @user, github_full_name: "acme/web-shop")
        colleague = sign_in_via_github(uid: "9999", info: { nickname: "hubot" })
        create_membership(repository: repository, user: colleague)

        get repositories_path, params: { q: "api" }

        expect(rendered_card_paths).to eq([repository_path(repository)])
      end
    end

    describe "what the unparameterised page renders" do
      it "keeps every card in name order, exactly as before" do
        create_repository(user: @user, github_full_name: "acme/zebra")
        create_repository(user: @user, github_full_name: "acme/alpha")
        create_repository(user: @user, github_full_name: "acme/midway")

        get repositories_path

        expect(rendered_card_paths).to eq(
          [repository_path(Repository.find_by(github_full_name: "acme/alpha")),
           repository_path(Repository.find_by(github_full_name: "acme/midway")),
           repository_path(Repository.find_by(github_full_name: "acme/zebra"))]
        )
      end

      # The narrowing controls render whenever the account holds at least one repository, ON THE
      # UNPARAMETERISED PAGE INCLUDED — a settled choice this pins from the empty side: an account
      # with nothing to narrow must not be offered the controls, which is the boundary that makes
      # "whenever it holds one" a claim rather than a decoration.
      it "offers the controls to an account that holds a repository, unfiltered page included" do
        create_repository(user: @user, github_full_name: "acme/billing-service")

        get repositories_path

        expect(response).to have_http_status(:ok)
        expect(page_text).to include("acme/billing-service")
        expect(response.body).to include(%(name="q"))
        expect(response.body).to include(%(name="role"))
        expect(response.body).to include(%(name="sort"))
      end

      it "offers no controls to an account that holds nothing" do
        get repositories_path

        expect(response.body).not_to include(%(name="q"))
        expect(response.body).not_to include(%(name="role"))
        expect(response.body).not_to include(%(name="sort"))
      end
    end

    describe "narrowing to nothing" do
      it "names the ask and offers the way back, rather than the registration invitation" do
        create_repository(user: @user, github_full_name: "acme/billing-service")

        get repositories_path, params: { q: "ledger" }

        expect(page_text).to include(%(No repositories match “ledger”))
        # The sentence that is true of an empty account is FALSE for this reader — they hold a
        # repository; the search matched none of them.
        expect(page_text).not_to include("No repositories yet")
        expect(page_text).not_to include("Register a GitHub repository to start collecting")
        # The way back, in one gesture — and the controls stay on the page, because the reader
        # holding a query that matched nothing is the one who most needs them.
        expect(page_text).to include("Show all repositories")
        expect(response.body).to include(%(name="q"))
      end

      it "names the ownership ask when the search is empty" do
        create_repository(user: @user, github_full_name: "acmine/only-registered")

        get repositories_path, params: { role: "shared" }

        expect(page_text).to include("No repositories have been shared with you")
        expect(page_text).not_to include("No repositories yet")
      end

      # `?sort=` cannot empty the set — it reorders — so an empty page under a bare sort is an
      # empty ACCOUNT and must keep the registration invitation. This is the boundary
      # `index_narrowing_asked?` draws by excluding `?sort=`, and the reason it is drawn there.
      it "keeps the registration invitation for an empty account under a bare sort ask" do
        get repositories_path, params: { sort: "stale" }

        expect(page_text).to include("No repositories yet")
        expect(page_text).not_to include("No repositories match")
      end
    end

    describe "its cost" do
      # `count_queries` from spec/support/query_capture.rb — the same instrument the SHOW budgets
      # in this file use. The claim is the ticket's own: a filtered grid of N cards costs the SAME
      # number of queries as an unfiltered grid of N cards. Every repository here matches the
      # search, so both pages render the same N cards and the comparison is N against N — the
      # narrowing is the only difference between the two reads.
      #
      # The stale sort is compared with `<=` and not `==`, and the reason is worth keeping: sorting
      # the loaded set in the controller RETIRES the view's `any?` EXISTS (the Array answers it in
      # memory), so a stale-sorted page can honestly cost one FEWER round trip. "Never more" is
      # the budget the narrowing owes; equality is what the pure narrowing (`?q=` + `?role=`,
      # relation untouched) owes.
      it "costs a filtered grid the same as the unfiltered grid" do
        %w[acme/one acme/two acme/three].each_with_index do |full_name, index|
          create_test_run(repository: create_repository(user: @user, github_full_name: full_name),
                          commit_sha: "cafe060#{index}", total_specs_count: 10 + index,
                          created_at: (index + 1).days.ago)
        end

        unfiltered = count_queries { get repositories_path }
        expect(page_text).to include("acme/three")

        narrowed = count_queries { get repositories_path, params: { q: "acme", role: "owned" } }
        reordered = count_queries { get repositories_path, params: { q: "acme", role: "owned", sort: "stale" } }

        # Same N cards — the narrowed set is the whole set here, so the counts differ by the
        # narrowing alone and nothing else.
        expect(page_text).to include("acme/one")
        expect(page_text).to include("acme/three")
        expect(narrowed).to eq(unfiltered)
        expect(reordered).to be <= unfiltered
      end

      # The per-table half, on the same instrument the sibling index guards use
      # (`queries_against`): one DISTINCT ON for the whole grid stays one under narrowing, and
      # under the stale sort too — wherever in the request the load happens.
      it "keeps the grid's run read at one query, narrowed and reordered" do
        %w[acme/one acme/two acme/three].each_with_index do |full_name, index|
          create_test_run(repository: create_repository(user: @user, github_full_name: full_name),
                          commit_sha: "cafe070#{index}", total_specs_count: 10,
                          created_at: (index + 1).days.ago)
        end

        narrowed = queries_against("test_runs") { get repositories_path, params: { q: "acme" } }
        reordered = queries_against("test_runs") { get repositories_path, params: { sort: "stale" } }

        expect(page_text.scan(/10 tests/).size).to eq(3)
        expect(narrowed.size).to eq(1)
        expect(reordered.size).to eq(1)
      end
    end
  end

  describe "renaming a repository" do
    # @intent: {"entity": "Repository", "action": "rename preserving data", "behavior": "patching a corrected org/repo name redirects to the show page, updates github_full_name, and leaves the key, run and spec-intent rows all intact", "layer": "request"}
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

    # @intent: {"entity": "Repository", "action": "normalize pasted URL", "behavior": "patching a full github.com URL stores the normalized acme/renamed name and derives the display name renamed, so GitHub is asked only about the normalized form", "layer": "request"}
    it "re-derives the display name and normalizes a pasted GitHub URL" do
      # The NORMALIZED name is what gets verified against the installation, which is the point of
      # the pairing here: GitHub is asked about `acme/renamed`, never about the pasted URL.
      stub_github(repos: [github_repo("acme/renamed")])
      repository = create_repository(user: @user, github_full_name: "acme/old-name")

      patch repository_path(repository),
            params: { repository: { github_full_name: "https://github.com/acme/renamed.git" } }

      expect(repository.reload.github_full_name).to eq("acme/renamed")
      expect(repository.name).to eq("renamed")
    end

    # @intent: {"entity": "Repository", "action": "reject invalid rename", "behavior": "patching nonsense answers 422 with the must look like org/repo message, leaves the stored name unchanged, and still identifies the record by its stored name in the form", "layer": "request"}
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

    # @intent: {"entity": "Repository", "action": "reject taken name", "behavior": "patching a name another user already owns answers 422 rather than raising, and leaves the stored name unchanged", "layer": "request"}
    it "rejects a name already taken by another user rather than raising" do
      create_repository(user: create_user(github_uid: "9999", github_handle: "someone-else"),
                        github_full_name: "other/repo")
      repository = create_repository(user: @user)

      patch repository_path(repository), params: { repository: { github_full_name: "other/repo" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(repository.reload.github_full_name).to eq("acme/billing-service")
    end

    # @intent: {"entity": "Repository", "action": "accept no-op rename", "behavior": "patching the unchanged name redirects to the show page with no Renamed flash", "layer": "request"}
    it "accepts a save that leaves the name unchanged" do
      repository = create_repository(user: @user)

      patch repository_path(repository), params: { repository: { github_full_name: "acme/billing-service" } }

      expect(response).to redirect_to(repository_path(repository))
      expect(flash[:notice]).not_to include("Renamed")
    end

    # @intent: {"entity": "Repository", "action": "confirm rename in flash", "behavior": "an actual rename sets the notice to exactly Renamed to acme/billing-service.", "layer": "request"}
    it "confirms the rename in the flash when the name actually changed" do
      repository = create_repository(user: @user, github_full_name: "acme/billing-servce")

      patch repository_path(repository), params: { repository: { github_full_name: "acme/billing-service" } }

      expect(flash[:notice]).to eq("Renamed to acme/billing-service.")
    end

    # @intent: {"entity": "Repository", "action": "link rename form", "behavior": "the repository page includes a link to the rename form's edit path", "layer": "request"}
    it "links to the rename form from the repository page" do
      repository = create_repository(user: @user)

      get repository_path(repository)

      expect(response.body).to include(edit_repository_path(repository))
    end

    # @intent: {"entity": "Repository", "action": "render rename form", "behavior": "the edit path answers 200 and renders a github_full_name input", "layer": "request"}
    it "renders the rename form" do
      repository = create_repository(user: @user)

      get edit_repository_path(repository)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('name="repository[github_full_name]"')
    end

    # @intent: {"entity": "Repository", "action": "refuse foreign rename", "behavior": "both patching and viewing the rename form of another user's repository answer 404 and leave its name untouched", "layer": "request"}
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
