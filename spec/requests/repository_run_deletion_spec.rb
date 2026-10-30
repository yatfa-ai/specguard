# frozen_string_literal: true

require "rails_helper"

# SPGD-812: deleting ONE run from the "Recent runs" panel. Until this action existed a junk row
# (a cancelled job's half-sized shard row) was permanent — the only way to remove it was to
# destroy the whole repository.
#
# What these examples hold down is that the delete is surgical and honest: exactly the named row
# and its per-run children go, the durable things it pointed at (intents, identities) survive
# nullified, nothing of any other run or repository is touched, and the refusal shapes match the
# repository-delete path — a non-member learns nothing (404), a member without `repo.delete`
# gets the 403 every other `:repo_delete` gate gives.
RSpec.describe "Deleting a test run", type: :request do
  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }

  def create_observation(test_run, shard: nil)
    test_run.spec_observations.create!(
      repository: test_run.repository,
      file_path: "spec/models/invoice_spec.rb",
      line_number: 12,
      status: "annotated"
    ).tap { |o| o.update!(test_run_shard: shard) if shard }
  end

  describe "the delete itself" do
    # @intent: {"entity": "TestRun", "action": "delete one run", "behavior": "the delete removes exactly the named run, redirects to the repository page, and the flash names Deleted run a1b2c3d (main)", "layer": "request"}
    it "removes exactly that run and redirects to the repository page, naming sha and branch" do
      run = create_test_run(repository: repository, commit_sha: "a1b2c3d4e5f6", branch: "main")

      delete repository_run_path(repository, run)

      expect(response).to redirect_to(repository_path(repository))
      expect { run.reload }.to raise_error(ActiveRecord::RecordNotFound)
      follow_redirect!
      expect(response.body).to include("Deleted run a1b2c3d (main)")
    end

    # @intent: {"entity": "TestRun", "action": "word absent branch", "behavior": "deleting a run that reported no branch confirms with Deleted run a1b2c3d (branch not reported) rather than an empty paren", "layer": "request"}
    it "says 'branch not reported' rather than a blank when the run reported no branch" do
      run = create_test_run(repository: repository, commit_sha: "a1b2c3d4e5f6", branch: nil)

      delete repository_run_path(repository, run)
      follow_redirect!

      expect(response.body).to include("Deleted run a1b2c3d (branch not reported)")
    end

    # @intent: {"entity": "TestRun", "action": "nullify durable rows", "behavior": "the delete destroys the shard and the observation but leaves the spec intent and the last-seen identity alive with their run foreign keys nulled", "layer": "request"}
    it "deletes shards and observations but nullifies intents and last-seen identities" do
      run = create_test_run(repository: repository, ci_run_id: "ci-1")
      shard = run.test_run_shards.create!(shard_id: "1", total_specs_count: 5)
      observation = create_observation(run, shard: shard)
      intent = run.repository.spec_intents.create!(
        file_path: "spec/models/invoice_spec.rb", line_number: 12, entity: "Invoice",
        action: "finalize", behavior: "locks the line items", layer: "unit", test_run: run
      )
      identity = create_spec_identity(repository: repository)
      identity.update!(last_seen_test_run: run)

      delete repository_run_path(repository, run)

      expect(TestRunShard.exists?(shard.id)).to be false
      expect(SpecObservation.exists?(observation.id)).to be false
      # Durable rows survive, nullified — the cascade `TestRun` declares is the whole argument.
      expect(SpecIntent.exists?(intent.id)).to be true
      expect(intent.reload.test_run_id).to be_nil
      expect(SpecIdentity.exists?(identity.id)).to be true
      expect(identity.reload.last_seen_test_run_id).to be_nil
    end

    # @intent: {"entity": "TestRun", "action": "touch only that run", "behavior": "deleting one run leaves the repository's other run and another repository's run intact, the repository keeping exactly one run", "layer": "request"}
    it "touches no other run of the repository and no row of another repository" do
      other_repository = create_repository(user: @user, github_full_name: "acme/other")
      other_repo_run = create_test_run(repository: other_repository)
      other_run = create_test_run(repository: repository, commit_sha: "0f0f0f0f0f0f")
      victim = create_test_run(repository: repository)

      delete repository_run_path(repository, victim)

      expect(TestRun.exists?(other_run.id)).to be true
      expect(TestRun.exists?(other_repo_run.id)).to be true
      expect(repository.test_runs.count).to eq(1)
    end

    # @intent: {"entity": "TestRun", "action": "advance latest run", "behavior": "deleting the newest run moves latest_test_run to the remaining older run under the shared created_at ordering", "layer": "request"}
    it "advances latest_test_run to the next-newest run by the shared ordering, tie-break included" do
      oldest = create_test_run(repository: repository, created_at: 2.days.ago)
      newest = create_test_run(repository: repository, created_at: 1.day.ago)

      delete repository_run_path(repository, newest)

      expect(repository.reload.latest_test_run.id).to eq(oldest.id)
    end

    # @intent: {"entity": "TestRun", "action": "fall back to empty", "behavior": "deleting the only run leaves latest_test_run nil and the redirected page showing No runs yet", "layer": "request"}
    it "falls back to the no-run empty state when the deleted run was the only one" do
      run = create_test_run(repository: repository)

      delete repository_run_path(repository, run)
      follow_redirect!

      expect(repository.reload.latest_test_run).to be_nil
      expect(response.body).to include("Nothing has been reported yet")
    end
  end

  # SPGD-1474 (rework): deleting a run changes the stored near-duplicates census's inputs — it
  # can move `repository.latest_test_run` (the run every weight figure is weighed on) and it
  # destroys the per-example observations the figures join through — so the delete requests the
  # census refresh exactly as the ingest path does. These examples hold the scenario the round-2
  # review reproduced: a junk run (the same near-duplicate pair re-reported at inflated
  # durations) becomes the weighed run, the delete removes it, and the stored census must
  # re-weigh on the surviving run — never keep stamping a run that no longer exists, which on a
  # quiet repository would last indefinitely and send a client following `weighed_run_id` to a
  # 404.
  #
  # ⭐ THE PROVIDER IS LEXICAL HERE, on this file family's own rule (see
  # `near_duplicate_clusters_spec.rb`): the suite-wide stub makes two differently-worded texts
  # near-orthogonal however alike they read, so without a stand-in that puts the pair below on a
  # cosine above the floor, the cluster whose weights move would not exist and these assertions
  # would pass over an empty census.
  describe "the stored near-duplicates census it invalidates" do
    include_context "with lexical embeddings"

    let(:expired) { "Checkout rejects an expired card" }
    let(:outright) { "Checkout rejects an expired card outright" }

    # Ingests the checkout pair through the real pipeline — rows and identities come off
    # `Ingest::Payload`, never hand-written, the rule the near-duplicates request spec states —
    # and stores its census through `refresh!`, the compute-and-store unit the census job runs.
    # The fixture side stays OFF `request_refresh!`/the job on purpose: it leaves the job queue
    # empty when the delete fires below, so the delete's OWN enqueue is assertable in isolation.
    def ingest_pair(commit_sha:, duration:)
      payload = Ingest::Payload.new(
        { "commit_sha" => commit_sha, "branch" => "main", "duration_seconds" => 60.0,
          "specs" => [
            unannotated_spec(file_path: "spec/models/checkout_spec.rb", line_number: 3,
                             id: "./spec/models/checkout_spec.rb[1:1]", name: expired,
                             duration: duration),
            unannotated_spec(file_path: "spec/models/checkout_spec.rb", line_number: 9,
                             id: "./spec/models/checkout_spec.rb[2:1]", name: outright,
                             duration: duration * 2)
          ].map(&:deep_stringify_keys) }
      )
      raise "ingest fixture is not a valid payload: #{payload.errors.inspect}" unless payload.valid?

      run = Ingest::RunRecorder.record(repository, payload.test_run_attributes, specs: payload.specs)
      Ingest::IdentityResolver.resolve(run)
      NearDuplicateCensus.refresh!(repository)
      run
    end

    # @intent: {"entity": "TestRun", "action": "re-weigh the census on delete", "behavior": "deleting the weighed run schedules the census job, and draining it re-weighs the stored census onto the surviving run with figures equal to the live computation", "layer": "request"}
    it "re-weighs the stored census onto the surviving run when the weighed run is deleted" do
      good_run = ingest_pair(commit_sha: "feedfacecafe0001", duration: 0.2)
      junk_run = ingest_pair(commit_sha: "feedfacecafe0002", duration: 9.0)
      expect(NearDuplicateCensus.find_by!(repository_id: repository.id).weighed_run_id)
        .to eq(junk_run.id)

      # The delete itself schedules the recompute — the assertion that keeps this behaviour from
      # degrading into "some later ingest happens to heal it".
      expect { delete repository_run_path(repository, junk_run) }
        .to have_enqueued_job(Ingest::NearDuplicateCensusJob).with(repository.id)

      # ...and the job, run the way the worker would run it, moves the stored census onto the
      # surviving run and back onto figures a live computation returns.
      Ingest::NearDuplicateCensusJob.perform_now(repository.id)

      stored = NearDuplicateCensus.find_by!(repository_id: repository.id)
      live = NearDuplicateClusters.for(repository)

      expect(TestRun.exists?(junk_run.id)).to be false
      # A stamp naming a deleted run would send a client following it to the runs API to a 404.
      expect(stored.weighed_run_id).to eq(good_run.id)
      expect(stored.payload).to include(
        "cluster_count" => live.cluster_count,
        "clustered_example_count" => live.clustered_example_count,
        "identity_count" => live.identity_count
      )
      stored_cluster = stored.payload["clusters"].sole
      live_cluster = live.clusters.sole
      expect(stored_cluster["member_count"]).to eq(live_cluster.member_count)
      expect(stored_cluster["total_seconds"]).to eq(live_cluster.total_seconds)
      # ...and the surviving run's weights are the small ones: the junk run's inflated figures
      # are gone from the stored artifact, not just from the live computation.
      expect(stored_cluster["total_seconds"]).to be_within(0.0001).of(0.6)
    end

    # Deleting the ONLY run leaves the census weighed on nothing: `latest_test_run` is nil, the
    # live computation answers with no run, and the stored artifact must carry that shape — the
    # nil weighed run, not a stamp naming a run that no longer exists. The cluster itself
    # SURVIVES (the identities do — nullified, not destroyed — and they still read alike), but
    # every weight figure in it goes unobserved: with no run there is no observation to weigh
    # through, so `example_count` is 0, `total_seconds` is nil and `unobserved_members` states
    # it. The population figures keep reporting the identities too: "no run observes them now",
    # never "no identities exist".
    # @intent: {"entity": "TestRun", "action": "re-weigh census on nothing", "behavior": "deleting the only run re-weighs the stored census onto nothing - nil weighed_run_id, the cluster kept but unobserved - matching the live computation over the same run-less inputs", "layer": "request"}
    it "re-weighs the stored census on nothing when the deleted run was the only one" do
      only_run = ingest_pair(commit_sha: "feedfacecafe0001", duration: 0.2)
      expect(NearDuplicateCensus.find_by!(repository_id: repository.id).weighed_run_id)
        .to eq(only_run.id)

      delete repository_run_path(repository, only_run)
      Ingest::NearDuplicateCensusJob.perform_now(repository.id)

      stored = NearDuplicateCensus.find_by!(repository_id: repository.id)
      live = NearDuplicateClusters.for(repository)

      expect(stored.weighed_run_id).to be_nil
      expect(stored.payload["identity_count"])
        .to eq(live.identity_count).and eq(2)
      # The cluster survives, weighed on nothing: the stored figures are the live computation's
      # over the same run-less inputs — unobserved members, no wall clock, and the stamp of that
      # fact on the cluster.
      stored_cluster = stored.payload["clusters"].sole
      live_cluster = live.clusters.sole
      expect(stored_cluster["member_count"]).to eq(live_cluster.member_count).and eq(2)
      expect(stored_cluster["example_count"]).to eq(live_cluster.example_count).and eq(0)
      expect(stored_cluster["total_seconds"]).to be_nil
      expect(stored_cluster["unobserved_members"]).to be(true)
    end
  end

  # SPGD-1958: the newest run is the one every panel anchors on, so deleting it re-anchors the
  # page. The confirm and the notice say so for that row only; every other row reads as before.
  describe "when the run is the repository's newest" do
    let!(:older) { create_test_run(repository: repository, commit_sha: "0ld0ld0ld0ld", branch: "main", created_at: 2.days.ago) }
    let!(:newest) { create_test_run(repository: repository, commit_sha: "a1b2c3d4e5f6", branch: "main", created_at: 1.day.ago) }

    def confirm_for(sha)
      CGI.unescapeHTML(response.body[/data-turbo-confirm="([^"]*#{sha[0, 7]}[^"]*)"/, 1].to_s)
    end

    # @intent: {"entity": "TestRun", "action": "disclose newest in confirm", "behavior": "the Delete confirm of the repository's newest run says it is the newest run and that the previous run becomes the one every panel reads, while an older row's confirm carries no such clause", "layer": "request"}
    it "adds the newest-run clause to the newest row's confirm only" do
      get repository_path(repository)

      expect(confirm_for("a1b2c3d")).to include("This is the repository's newest run")
      expect(confirm_for("a1b2c3d")).to include("cannot be undone")
      expect(confirm_for("0ld0ld0")).not_to include("newest run")
      expect(confirm_for("0ld0ld0")).to end_with("and it cannot be undone.")
    end

    # @intent: {"entity": "TestRun", "action": "disclose only run in confirm", "behavior": "the Delete confirm of a repository's sole run says it is the only run and that the page goes empty, claims no previous run, and still says it cannot be undone", "layer": "request"}
    it "names the sole run as the only run, with no previous-run claim, in its confirm" do
      older.destroy!

      get repository_path(repository)

      expect(confirm_for("a1b2c3d")).to include("This is the repository's only run — deleting it leaves the page empty until CI reports again.")
      expect(confirm_for("a1b2c3d")).not_to include("previous run")
      expect(confirm_for("a1b2c3d")).to include("cannot be undone")
    end

    # @intent: {"entity": "TestRun", "action": "disclose newest under an anchored page", "behavior": "when the page is anchored on an older run with ?run=, the newest-run clause stays on the repository's newest row's confirm and the anchored older row's confirm does not claim it", "layer": "request"}
    it "marks the repository's newest run, not the anchored one, when the page is anchored with ?run=" do
      get repository_path(repository, run: older.id)

      expect(confirm_for("a1b2c3d")).to include("This is the repository's newest run")
      expect(confirm_for("0ld0ld0")).not_to include("newest run")
    end

    # @intent: {"entity": "TestRun", "action": "withhold newest outside the window", "behavior": "when a runs_branch narrowing excludes the repository's newest run, no listed row's confirm carries the newest-run clause", "layer": "request"}
    it "gives no row the newest-run clause when a runs_branch narrowing excludes the newest run" do
      create_test_run(repository: repository, commit_sha: "feat0001feat", branch: "feature/x", created_at: 1.hour.ago)

      get repository_path(repository, runs_branch: "main")

      panel = Nokogiri::HTML(response.body).at_css("#recent-runs")
      listed = panel.css("form[data-turbo-confirm]").map { |f| f["data-turbo-confirm"] }

      # Both main rows are listed (so the assertion is not vacuous), and neither claims the clause.
      expect(listed.size).to eq(2)
      expect(listed).to all(include("cannot be undone"))
      expect(listed.grep(/newest run/)).to be_empty
    end

    # @intent: {"entity": "TestRun", "action": "name successor in notice", "behavior": "deleting the newest run flashes the surviving run's sha and branch as the one the page now reads", "layer": "request"}
    it "names the successor run in the notice" do
      delete repository_run_path(repository, newest)
      follow_redirect!

      expect(response.body).to include("Deleted run a1b2c3d (main) and its shards and observations.")
      expect(response.body).to include("It was the repository&#39;s newest run, so the page now reads 0ld0ld0 (main).")
    end

    # @intent: {"entity": "TestRun", "action": "name successor on another branch", "behavior": "the notice names a successor that sits on a different branch by that branch", "layer": "request"}
    it "names a successor on a different branch" do
      older.update!(branch: "release")

      delete repository_run_path(repository, newest)
      follow_redirect!

      expect(response.body).to include("the page now reads 0ld0ld0 (release).")
    end

    # @intent: {"entity": "TestRun", "action": "name successor without branch", "behavior": "the notice words a successor that reported no branch as branch not reported", "layer": "request"}
    it "says 'branch not reported' for a successor with no branch" do
      older.update!(branch: nil)

      delete repository_run_path(repository, newest)
      follow_redirect!

      expect(response.body).to include("the page now reads 0ld0ld0 (branch not reported).")
    end

    # @intent: {"entity": "TestRun", "action": "disclose empty page", "behavior": "deleting the only run says no runs remain and the page will read empty until CI reports again", "layer": "request"}
    it "says no runs remain when the deleted run was the only one" do
      older.destroy!

      delete repository_run_path(repository, newest)
      follow_redirect!

      expect(response.body).to include("No runs remain — the page will read empty until CI reports again.")
      expect(response.body).not_to include("the page now reads")
    end

    # @intent: {"entity": "TestRun", "action": "keep notice for older row", "behavior": "deleting a run that is not the newest flashes exactly Deleted run 0ld0ld0 (main) and its shards and observations. with no newest-run clause", "layer": "request"}
    it "leaves a non-newest row's notice exactly as it was" do
      delete repository_run_path(repository, older)

      expect(flash[:notice]).to eq("Deleted run 0ld0ld0 (main) and its shards and observations.")
    end

    # @intent: {"entity": "TestRun", "action": "bound successor read", "behavior": "deleting a non-newest run issues no successor query while deleting the newest issues exactly one", "layer": "request"}
    it "reads the successor only when the deleted row was the newest" do
      successor_read = /"test_runs"\."id" != /

      non_newest = queries_against(successor_read) { delete repository_run_path(repository, older) }
      newest_read = queries_against(successor_read) { delete repository_run_path(repository, newest) }

      expect(non_newest).to be_empty
      expect(newest_read.size).to eq(1)
    end
  end

  describe "who may fire it" do
    # @intent: {"entity": "TestRun", "action": "refuse without permission", "behavior": "a member holding view and keys.manage but not repo.delete gets 403 and the run survives", "layer": "request"}
    it "refuses a member without repo.delete with 403, and the run survives" do
      member = create_user(github_uid: "2002", github_handle: "collaborator")
      create_membership(repository: repository, user: member,
                        permissions: [RepositoryMembership::VIEW, RepositoryMembership::KEYS_MANAGE])
      run = create_test_run(repository: repository)
      sign_in_via_github(uid: "2002", info: { nickname: "collaborator" })

      delete repository_run_path(repository, run)

      expect(response).to have_http_status(:forbidden)
      expect(TestRun.exists?(run.id)).to be true
    end

    # @intent: {"entity": "TestRun", "action": "hide from non-member", "behavior": "a non-member gets 404 rather than 403 so the repository's existence stays hidden, and the run survives", "layer": "request"}
    it "404s a non-member rather than 403ing, so the repository's existence stays hidden" do
      stranger = create_user(github_uid: "3003", github_handle: "stranger")
      run = create_test_run(repository: repository)
      sign_in_via_github(uid: "3003", info: { nickname: "stranger" })

      delete repository_run_path(repository, run)

      expect(response).to have_http_status(:not_found)
      expect(TestRun.exists?(run.id)).to be true
    end
  end

  describe "the run id is scoped through the repository" do
    # @intent: {"entity": "TestRun", "action": "scope the run id", "behavior": "naming another repository's run in this route changes no TestRun count, answers 404, and leaves both runs surviving", "layer": "request"}
    it "cannot delete another repository's run through this route" do
      other_repository = create_repository(user: @user, github_full_name: "acme/other")
      foreign_run = create_test_run(repository: other_repository)
      own_run = create_test_run(repository: repository)

      expect do
        delete repository_run_path(repository, foreign_run)
      end.not_to change(TestRun, :count)

      expect(response).to have_http_status(:not_found)
      expect(TestRun.exists?(foreign_run.id)).to be true
      expect(TestRun.exists?(own_run.id)).to be true
    end
  end

  # SPGD-1916: the "Recent runs" panel can be widened with `?runs=`, and the Delete in a widened
  # panel carries that ask through the redirect so removing a row does not collapse the window.
  describe "the asked runs window" do
    let(:max_runs) { RequestedRunsParam::MAX_RUNS }

    def seed_runs(count)
      count.times { |i| repository.test_runs.create!(commit_sha: format("win%04d", i), branch: "main", created_at: i.minutes.ago) }
    end

    # @intent: {"entity": "RunsController", "action": "carry the asked window", "behavior": "deleting with runs=25 redirects to the repository page with runs=25 and the followed page still lists more than the default window with the newest N of M caption reflecting one fewer run", "layer": "request"}
    it "redirects back to the asked window and the followed page keeps it" do
      seed_runs(30)
      victim = repository.test_runs.order(:created_at).first

      delete repository_run_path(repository, victim), params: { runs: "25" }

      expect(response).to redirect_to(repository_path(repository, runs: 25))
      follow_redirect!
      page = Capybara.string(response.body)
      expect(page.find("#recent-runs table").all("tbody tr").size).to eq(25)
      expect(page.find("#recent-runs-window")).to have_text("Showing the newest 25 of 29 runs.")
    end

    # @intent: {"entity": "RecentRunsPanel", "action": "carry the window in the delete form", "behavior": "a widened panel's Delete forms each carry a hidden runs field with the asked value, and the default panel's forms carry none", "layer": "request"}
    it "renders the ask in the Delete form only when the panel was widened" do
      seed_runs(12)

      get repository_path(repository)
      expect(Capybara.string(response.body)).to have_no_css("#recent-runs form input[name='runs']")

      get repository_path(repository, runs: 12)
      inputs = Capybara.string(response.body).all("#recent-runs form input[name='runs']", visible: :all)
      expect(inputs.size).to eq(12)
      expect(inputs.map { |i| i[:value] }.uniq).to eq(["12"])
    end

    # @intent: {"entity": "RunsController", "action": "clamp the asked window", "behavior": "deleting with runs=9999 redirects with the ceiling value rather than the raw ask", "layer": "request"}
    it "clamps an oversized ask to the ceiling" do
      run = create_test_run(repository: repository)

      delete repository_run_path(repository, run), params: { runs: "9999" }

      expect(response).to redirect_to(repository_path(repository, runs: max_runs))
    end

    [
      ["an array", "runs[]=x"],
      ["a negative integer", "runs=-3"],
      ["a blank string", "runs="],
      ["zero", "runs=0"]
    ].each do |shape, query|
      # @intent: {"entity": "RunsController", "action": "ignore a hostile runs ask", "behavior": "a runs parameter that is not a positive integer string redirects to the bare repository path exactly as a delete with no ask", "layer": "request"}
      it "redirects to the bare repository path when runs arrives as #{shape}" do
        run = create_test_run(repository: repository)

        delete "#{repository_run_path(repository, run)}?#{query}"

        expect(response).to redirect_to(repository_path(repository))
        expect(response.location).not_to include("runs")
      end
    end

    # @intent: {"entity": "RunsController", "action": "scope the run id with a window ask", "behavior": "naming another repository's run alongside a runs ask still answers 404 and deletes nothing", "layer": "request"}
    it "still 404s a cross-repository run id when a window is asked" do
      other_repository = create_repository(user: @user, github_full_name: "acme/other")
      foreign_run = create_test_run(repository: other_repository)

      expect do
        delete repository_run_path(repository, foreign_run), params: { runs: "25" }
      end.not_to change(TestRun, :count)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "the keyset cursor on the delete round trip" do
    let(:max_runs) { RequestedRunsParam::MAX_RUNS }

    def seed_runs(count)
      Array.new(count) { |i| create_test_run(repository: repository, commit_sha: format("pgd%04d", i), branch: "main", created_at: (i + 1).minutes.ago) }
    end

    def page_two_href
      get repository_path(repository, runs: max_runs)
      Capybara.string(response.body).find_link("Older runs")[:href].split("#").first
    end

    # @intent: {"entity": "RecentRunsPanel", "action": "carry the cursor in the delete form", "behavior": "every Delete form on a paged page carries a hidden runs_before field with the asked cursor, and the newest page at the ceiling carries none", "layer": "request"}
    it "renders the cursor in the Delete form only on a paged panel" do
      runs = seed_runs(55)
      get page_two_href
      cursor_id = runs[49].id

      inputs = Capybara.string(response.body).all("#recent-runs form input[name='runs_before']", visible: :all)
      expect(inputs.size).to eq(5)
      expect(inputs.map { |i| i[:value] }.uniq).to eq([cursor_id.to_s])

      get repository_path(repository, runs: max_runs)
      expect(Capybara.string(response.body)).to have_no_css("#recent-runs form input[name='runs_before']")
    end

    # @intent: {"entity": "RunsController", "action": "carry the asked cursor", "behavior": "deleting a non-cursor row from a paged page redirects with runs and runs_before, and the followed page still reads Runs older than the newest 50 runs with the deleted row gone", "layer": "request"}
    it "redirects back to the paged window and the followed page keeps it" do
      runs = seed_runs(55)
      cursor_id = runs[49].id
      victim = runs[52]

      delete repository_run_path(repository, victim), params: { runs: "50", runs_before: cursor_id }

      expect(response).to redirect_to(repository_path(repository, runs: 50, runs_before: cursor_id))
      follow_redirect!
      page = Capybara.string(response.body)
      expect(page.find("#recent-runs table").all("tbody tr").size).to eq(4)
      expect(page.find("#recent-runs-window")).to have_text("Runs older than the newest 50 runs.")
      expect(page.find("#recent-runs")).to have_no_text(victim.commit_sha)
    end

    # @intent: {"entity": "RunsController", "action": "drop the cursor when the deleted row is the cursor", "behavior": "deleting the row the carried cursor names redirects with runs but without runs_before, and the followed page is the newest window rather than a page into the void", "layer": "request"}
    it "drops the cursor when the deleted row is the row the cursor names" do
      runs = seed_runs(55)
      cursor_row = runs[49]

      delete repository_run_path(repository, cursor_row), params: { runs: "50", runs_before: cursor_row.id }

      expect(response).to redirect_to(repository_path(repository, runs: 50))
      expect(response.location).not_to include("runs_before")
      follow_redirect!
      page = Capybara.string(response.body)
      expect(page.find("#recent-runs-window")).to have_text("Showing the newest 50 of 54 runs.")
      expect(page.find_link("Older runs")[:href]).to include("runs_before=#{runs[50].id}")
    end

    [
      ["an array", "runs_before[]=5"],
      ["a negative integer", "runs_before=-3"],
      ["a blank string", "runs_before="],
      ["a string carrying a NUL", "runs_before=5%006"]
    ].each do |shape, query|
      # @intent: {"entity": "RunsController", "action": "ignore a hostile runs_before ask", "behavior": "a runs_before parameter that is not a plain positive integer string redirects without any runs_before bytes, exactly as a delete with no cursor ask", "layer": "request"}
      it "redirects without cursor bytes when runs_before arrives as #{shape}" do
        run = create_test_run(repository: repository)

        delete "#{repository_run_path(repository, run)}?#{query}"

        expect(response).to redirect_to(repository_path(repository))
        expect(response.location).not_to include("runs_before")
      end
    end

    # @intent: {"entity": "RunsController", "action": "round-trip a dead cursor", "behavior": "a well-formed runs_before id matching no row is carried through the redirect, and the followed page answers with the plain default newest window and no cursor bytes on its links", "layer": "request"}
    it "round-trips a well-formed unknown cursor, which the followed page answers with the default window" do
      seed_runs(25)
      victim = repository.test_runs.order(:created_at).last

      delete repository_run_path(repository, victim), params: { runs: "50", runs_before: 9_000_000_000_000 }

      expect(response).to redirect_to(repository_path(repository, runs: 50, runs_before: 9_000_000_000_000))
      follow_redirect!
      page = Capybara.string(response.body)
      # The carried widening is honoured; the dead cursor falls back to the NEWEST window, so
      # every run is listed and no window caption applies.
      expect(page.find("#recent-runs table").all("tbody tr").size).to eq(24)
      expect(page).to have_no_css("#recent-runs-window")
      hrefs = page.all("a[href*='commit_sha=']", visible: :all, minimum: 1).map { |a| a[:href] }
      expect(hrefs).to all(satisfy { |href| !href.include?("runs_before") })
    end
  end

  describe "the run, sha and comparison anchors on the delete round trip" do
    def page = Capybara.string(response.body)

    # `nil` rather than a raise when the page said nothing about its anchor, so a no-ask example
    # can assert the ABSENCE — the same helper `repository_run_anchor_spec.rb` defines for the
    # same element.
    def anchor_notice = page.all("#run-anchor-notice").first&.text&.squish

    def recent_runs_caption = page.find("#recent-runs-basis").text.squish

    # Runs for the comparison example, written through the recorder the What-changed panels read
    # through — the rule `repository_compare_to_baseline_spec.rb` states for the same panels.
    def ingest_run(commit_sha:, branch:, at:, total: 3)
      specs = Array.new(total) { |i| unannotated_spec(file_path: "spec/models/a_spec.rb", line_number: i + 1, duration: 1.0) }
      run = Ingest::RunRecorder.record(
        repository,
        { commit_sha: commit_sha, branch: branch, total_specs_count: total,
          annotated_specs_count: 0, duration_seconds: 60.0 },
        specs: specs.map(&:deep_stringify_keys)
      )
      run.update!(created_at: at)
      run
    end

    # @intent: {"entity": "RunsController", "action": "carry the run anchor", "behavior": "deleting a row the run ask does not name redirects with the runs and run params, and the followed page still reads the anchored run with its anchor notice", "layer": "request"}
    it "carries a run ask the deleted row does not name, and the followed page still reads it" do
      anchored = create_test_run(repository: repository, commit_sha: "anch0000000001", branch: "main", created_at: 3.days.ago)
      victim = create_test_run(repository: repository, commit_sha: "vict0000000001", branch: "main", created_at: 1.hour.ago)

      delete repository_run_path(repository, victim), params: { runs: "25", run: anchored.id }

      expect(response).to redirect_to(repository_path(repository, runs: 25, run: anchored.id))
      follow_redirect!
      expect(page.find(".rc-run").text.squish).to include("Reading run #{anchored.commit_sha.first(7)}")
      expect(anchor_notice).to include("run ##{anchored.id}")
    end

    # @intent: {"entity": "RunsController", "action": "drop the run anchor on its own row", "behavior": "deleting the row the run ask names redirects to the bare repository path with no run bytes, the notice still names the deleted run, and the followed page reads the surviving newest run with no anchor notice", "layer": "request"}
    it "drops the run anchor when the deleted row is the one the anchor names" do
      anchored = create_test_run(repository: repository, commit_sha: "anch0000000001", branch: "main", created_at: 2.days.ago)
      survivor = create_test_run(repository: repository, commit_sha: "surb0000000001", branch: "main", created_at: 1.hour.ago)

      delete repository_run_path(repository, anchored), params: { run: anchored.id }

      expect(response).to redirect_to(repository_path(repository))
      expect(response.location).not_to include("run=")
      expect(flash[:notice]).to include("Deleted run #{anchored.commit_sha.first(7)} (main)")
      follow_redirect!
      expect(page.find(".rc-run").text.squish).to include("Reading run #{survivor.commit_sha.first(7)}")
      expect(anchor_notice).to be_nil
    end

    # @intent: {"entity": "RunsController", "action": "carry the sha anchor", "behavior": "deleting from a commit_sha-anchored page with no run ask redirects with the sha param, and the followed page still reads the anchored run", "layer": "request"}
    it "carries a sha ask when no run ask exists" do
      anchored = create_test_run(repository: repository, commit_sha: "anch0000000001", branch: "main", created_at: 2.days.ago)
      victim = create_test_run(repository: repository, commit_sha: "vict0000000001", branch: "main", created_at: 1.hour.ago)

      delete repository_run_path(repository, victim), params: { commit_sha: anchored.commit_sha }

      expect(response).to redirect_to(repository_path(repository, commit_sha: anchored.commit_sha))
      follow_redirect!
      expect(page.find(".rc-run").text.squish).to include("Reading run #{anchored.commit_sha.first(7)}")
      expect(anchor_notice).to include("This page is anchored on #{anchored.commit_sha.first(7)}")
    end

    # @intent: {"entity": "RunsController", "action": "prefer the run anchor", "behavior": "a delete carrying both run and commit_sha redirects with the run and no commit_sha bytes, matching the read side's run-over-sha precedence", "layer": "request"}
    it "carries the run ask and leaves no sha bytes when both arrive" do
      anchored = create_test_run(repository: repository, commit_sha: "anch0000000001", branch: "main", created_at: 2.days.ago)
      victim = create_test_run(repository: repository, commit_sha: "vict0000000001", branch: "main", created_at: 1.hour.ago)

      delete repository_run_path(repository, victim), params: { run: anchored.id, commit_sha: anchored.commit_sha }

      expect(response).to redirect_to(repository_path(repository, run: anchored.id))
      expect(response.location).not_to include("commit_sha=")
    end

    # The precedence rule's second half: the run ask still wins when it DIES — the deleted row was
    # the one it named — and the sha does not resurrect. An id ask names its row completely.
    # @intent: {"entity": "RunsController", "action": "never resurrect the sha", "behavior": "deleting the row the run ask names while a sha ask also rides redirects to the bare repository path with neither anchor's bytes", "layer": "request"}
    it "does not resurrect the sha ask when the deleted row was the run ask's row" do
      anchored = create_test_run(repository: repository, commit_sha: "anch0000000001", branch: "main", created_at: 2.days.ago)
      survivor = create_test_run(repository: repository, commit_sha: "surb0000000001", branch: "main", created_at: 1.hour.ago)

      delete repository_run_path(repository, anchored), params: { run: anchored.id, commit_sha: anchored.commit_sha }

      expect(response).to redirect_to(repository_path(repository))
      expect(response.location).not_to include("run=")
      expect(response.location).not_to include("commit_sha=")
      expect(TestRun.exists?(survivor.id)).to be true
    end

    # @intent: {"entity": "RunsController", "action": "carry the comparison ask", "behavior": "deleting from a compare_to=main page redirects with compare_to=main, and the followed page still names the asked branch as its What-changed basis", "layer": "request"}
    it "carries the comparison ask, and the followed page keeps measuring against the asked branch" do
      ingest_run(commit_sha: "main0000000001", branch: "main", at: 3.days.ago)
      survivor = ingest_run(commit_sha: "feat0000000001", branch: "feature", at: 2.days.ago)
      victim = ingest_run(commit_sha: "feat0000000002", branch: "feature", at: 1.hour.ago)

      delete repository_run_path(repository, victim), params: { compare_to: "main" }

      expect(response).to redirect_to(repository_path(repository, compare_to: "main"))
      follow_redirect!
      expect(TestRun.exists?(survivor.id)).to be true
      expect(recent_runs_caption).to include("by your ask — against the newest run on main")
      expect(page.find("#changes .rc-section-head p").text.squish).to include("a different branch, asked for")
    end

    # @intent: {"entity": "RunsController", "action": "carry run and comparison together", "behavior": "a delete carrying both run and compare_to redirects with both params", "layer": "request"}
    it "carries the run anchor and the comparison ask together" do
      anchored = create_test_run(repository: repository, commit_sha: "anch0000000001", branch: "main", created_at: 3.days.ago)
      victim = create_test_run(repository: repository, commit_sha: "vict0000000001", branch: "main", created_at: 1.hour.ago)

      delete repository_run_path(repository, victim), params: { run: anchored.id, compare_to: "main" }

      expect(response).to redirect_to(repository_path(repository, run: anchored.id, compare_to: "main"))
    end

    # @intent: {"entity": "RunsController", "action": "round-trip a dead run anchor", "behavior": "a well-formed run id matching no row is carried through the redirect, and the followed page answers with the newest run, a fallback notice naming the ask, and no anchored caption in the Recent runs panel", "layer": "request"}
    it "round-trips a well-formed unknown run id, which the followed page answers with the default window" do
      survivor = create_test_run(repository: repository, commit_sha: "solo0000000001", branch: "main", created_at: 1.hour.ago)
      victim = create_test_run(repository: repository, commit_sha: "vict0000000001", branch: "main", created_at: 30.minutes.ago)

      delete repository_run_path(repository, victim), params: { run: 424_242 }

      expect(response).to redirect_to(repository_path(repository, run: 424_242))
      follow_redirect!
      expect(page.find(".rc-run").text.squish).to include("Reading run #{survivor.commit_sha.first(7)}")
      expect(anchor_notice).to include("no run for run #424242")
      # The panel makes no second statement about an anchor that resolved to nothing — the
      # Overview's fallback sentence already named it.
      expect(recent_runs_caption).not_to include("This page is anchored")
    end

    # @intent: {"entity": "RunsController", "action": "keep no-ask redirect identical", "behavior": "a delete with no asks redirects byte-identically to the bare repository URL with no query string", "layer": "request"}
    it "keeps a no-ask delete byte-identical to the bare repository path" do
      run = create_test_run(repository: repository, commit_sha: "solo0000000001", branch: "main")

      delete repository_run_path(repository, run)

      expect(response.location).to eq(repository_url(repository))
      expect(response.location).not_to include("?")
    end

    # @intent: {"entity": "RecentRunsPanel", "action": "omit anchor bytes from a no-ask form", "behavior": "a no-ask page's Delete forms carry no hidden run, commit_sha or compare_to inputs", "layer": "request"}
    it "renders no anchor bytes in a no-ask Delete form" do
      create_test_run(repository: repository, commit_sha: "anch0000000001", branch: "main")

      get repository_path(repository)
      body = Capybara.string(response.body)
      expect(body).to have_no_css("#recent-runs form input[name='run']")
      expect(body).to have_no_css("#recent-runs form input[name='commit_sha']")
      expect(body).to have_no_css("#recent-runs form input[name='compare_to']")
    end

    # @intent: {"entity": "RecentRunsPanel", "action": "carry the asked anchors in the form", "behavior": "a sha-anchored page's Delete forms each carry the asked commit_sha value, an id-anchored page's forms carry the asked run id and no sha bytes, and a run-plus-comparison page's forms carry both asks", "layer": "request"}
    it "renders the asked anchors in the Delete forms" do
      anchored = create_test_run(repository: repository, commit_sha: "anch0000000001", branch: "main", created_at: 2.hours.ago)
      other = create_test_run(repository: repository, commit_sha: "othr0000000001", branch: "main", created_at: 1.hour.ago)

      get repository_path(repository, commit_sha: anchored.commit_sha)
      sha_inputs = Capybara.string(response.body).all("#recent-runs form input[name='commit_sha']", visible: :all)
      expect(sha_inputs.size).to eq(2)
      expect(sha_inputs.map { |i| i[:value] }.uniq).to eq([anchored.commit_sha])

      get repository_path(repository, run: anchored.id)
      body = Capybara.string(response.body)
      run_inputs = body.all("#recent-runs form input[name='run']", visible: :all)
      expect(run_inputs.size).to eq(2)
      expect(run_inputs.map { |i| i[:value] }.uniq).to eq([anchored.id.to_s])
      expect(body).to have_no_css("#recent-runs form input[name='commit_sha']")

      feat = create_test_run(repository: repository, commit_sha: "feat0000000001", branch: "feature", created_at: 30.minutes.ago)
      get repository_path(repository, run: feat.id, compare_to: "main")
      body = Capybara.string(response.body)
      expect(body.all("#recent-runs form input[name='run']", visible: :all).map { |i| i[:value] }.uniq).to eq([feat.id.to_s])
      expect(body.all("#recent-runs form input[name='compare_to']", visible: :all).map { |i| i[:value] }.uniq).to eq(["main"])
    end

    # The shapes a `?run=` query string can legally parse into that are not a run id are listed
    # ONCE in `spec/support/shared_examples/malformed_run_id_param.rb`, against the guard they all
    # land on (`RequestedRunIdParam#requested_run_id`). What is local to this surface is how the
    # delete says it dropped the ask: the bare repository redirect, with no `run` bytes — the same
    # answer a delete with no ask gives, and the SPGD-1916 precedent's own shape.
    describe "a run-id parameter that is not a run id" do
      def expect_run_param_treated_as_no_ask(query)
        run = create_test_run(repository: repository)

        delete repository_run_path(repository, run), params: query

        expect(response).to redirect_to(repository_path(repository))
        expect(response.location).not_to include("run=")
      end

      it_behaves_like "a surface that treats a malformed run-id parameter as no ask"
    end

    describe "a commit-sha parameter that is not a sha" do
      def expect_commit_sha_param_treated_as_no_ask(query)
        run = create_test_run(repository: repository)

        delete repository_run_path(repository, run), params: query

        expect(response).to redirect_to(repository_path(repository))
        expect(response.location).not_to include("commit_sha=")
      end

      it_behaves_like "a surface that treats a malformed commit-sha parameter as no ask"
    end

    describe "a compare_to parameter that is not a branch" do
      def expect_compare_to_param_treated_as_no_ask(query)
        run = create_test_run(repository: repository)

        delete repository_run_path(repository, run), params: query

        expect(response).to redirect_to(repository_path(repository))
        expect(response.location).not_to include("compare_to=")
      end

      it_behaves_like "a surface that treats a malformed compare_to parameter as no ask"
    end
  end

  describe "the control" do
    # @intent: {"entity": "TestRun", "action": "render delete control", "behavior": "a viewer with repo_delete sees a Delete button whose dialog names removing the run's shards and per-example observations and that it cannot be undone", "layer": "request"}
    it "renders a Delete button with a dialog naming the consequence, for a viewer with repo_delete" do
      create_test_run(repository: repository, commit_sha: "a1b2c3d4e5f6")

      get repository_path(repository)

      expect(response.body).to include("Delete")
      expect(response.body).to include("its shards and its per-example observations")
      expect(response.body).to include("cannot be undone")
    end

    # @intent: {"entity": "TestRun", "action": "omit delete control", "behavior": "a viewer lacking repo_delete gets neither the Delete button nor the cannot-be-undone dialog text anywhere on the page", "layer": "request"}
    it "renders no Delete control at all for a viewer lacking repo_delete" do
      member = create_user(github_uid: "2002", github_handle: "collaborator")
      create_membership(repository: repository, user: member)
      create_test_run(repository: repository)
      sign_in_via_github(uid: "2002", info: { nickname: "collaborator" })

      get repository_path(repository)

      # The whole control, button and dialog sentence, is absent — not disabled, not present with
      # a different label. An affordance that can only ever produce a 403 is not rendered.
      expect(response.body).not_to include(">Delete<")
      expect(response.body).not_to include("cannot be undone")
    end
  end
end
