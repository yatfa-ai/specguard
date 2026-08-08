# frozen_string_literal: true

require "rails_helper"

# The runtime change on the Overview panel — the suite's *cost* read off two rows of `test_runs`
# rather than one, which is the question a large suite is actually managed by. The panel has
# differenced the suite's SIZE since spec/requests/repository_suite_growth_spec.rb; it served the
# cost as a bare level, so a reader could see the suite grew by 47 tests and could not see whether
# it got slower.
#
# Its own file rather than more examples in the growth one, for the reason that file gives for
# itself: the fixtures here are about DURATIONS and about how many shards reported one, which is a
# different setup from "two counts on a branch", and the two guards are deliberately not the same
# guard.
#
# == Why the sharded runs are built by driving the recorder
#
# The same reason the growth file states, and one more that is specific to this slice. A run's
# `duration_seconds` is not written by the client on a sharded run — `Ingest::RunRecorder#recompute_totals`
# re-derives it as the MAX over the shard rows after every POST, and `timed_shard_count` is
# `COUNT(duration_seconds)` over those same rows. A fixture that wrote `test_runs.duration_seconds`
# by hand and left `test_run_shards` empty would hold a run whose wall clock and whose denominator
# disagree in a way no real run can, and every example over it would be green against a page that
# never sees that shape.
RSpec.describe "Repository runtime change", type: :request do
  before { @user = sign_in_via_github }

  def overview_panel = Capybara.string(response.body).find("#overview")

  # ELEMENT-scoped, never panel-scoped, on the rule the growth file documents from a verified
  # mutation: four states here produce a no-delta panel and they share vocabulary ("no timing",
  # "wall clock"), so a panel-level `have_text` passes for the wrong state with the deciding check
  # deleted.
  def runtime_delta = overview_panel.find("#runtime-delta")

  def machine_time_delta = overview_panel.find("#machine-time-delta")

  def runtime_basis = overview_panel.find("#runtime-basis")

  # The cells themselves, so "the delta rendered" can never be satisfied by the figure having
  # drifted into some other row of the def list. Matched on the label's PREFIX because the two
  # sharded labels carry their own coverage in parentheses — "Wall clock (slowest of 4 shards)".
  def cost_cell(label)
    overview_panel.find(:xpath, ".//dt[starts-with(normalize-space(), '#{label}')]/following-sibling::dd[1]")
  end

  def unsharded_run(repository, commit_sha:, total:, duration:, created_at:, branch: "main")
    repository.test_runs.create!(commit_sha: commit_sha, branch: branch, total_specs_count: total,
                                annotated_specs_count: total / 10, duration_seconds: duration,
                                created_at: created_at)
  end

  # One shard of one run, through the producer. `duration` is passed straight through and `nil` is
  # an ordinary value for it — `Ingest::Payload` accepts a shard that reported no timing, which is
  # what a cancelled or timed-out CI job leaves behind and what every mismatched-denominator
  # fixture below is built out of.
  def ingest_shard(repository, ci_run_id:, shard_id:, total:, commit_sha:, duration:, branch: "main")
    Ingest::RunRecorder.record(
      repository,
      { commit_sha: commit_sha, branch: branch, ci_run_id: ci_run_id,
        total_specs_count: total, annotated_specs_count: total / 4, duration_seconds: duration },
      shard_id: shard_id
    )
  end

  # A sharded run of `durations.size` shards, each carrying `per_shard` examples and the timing at
  # its own position. `nil` there is a shard that went silent.
  def sharded_run(repository, commit_sha:, durations:, per_shard: 5_000)
    durations.each_with_index do |duration, i|
      ingest_shard(repository, ci_run_id: "gha-#{commit_sha}", shard_id: i.to_s,
                   total: per_shard, commit_sha: commit_sha, duration: duration)
    end
    repository.test_runs.find_by!(ci_run_id: "gha-#{commit_sha}")
  end

  # 8m 30s against 1m 0s. Deliberately a delta that crosses the minute the formatter changes shape
  # at, so criterion 8 has something to bite on: the level and the change are both h/m/s here, and
  # a second formatter would show up as `450.0s` sitting beside `8m 30s` in one cell.
  def got_slower(repository)
    unsharded_run(repository, commit_sha: "a1b2c3d4e5f6", total: 1_000, duration: 60.0,
                  created_at: 3.hours.ago)
    unsharded_run(repository, commit_sha: "fedcba987654", total: 1_000, duration: 510.0,
                  created_at: 1.minute.ago)
  end

  it "reports the runtime change in the same cell as the runtime it changed" do
    repository = create_repository(user: @user)
    got_slower(repository)

    get repository_path(repository)

    expect(response).to have_http_status(:ok)
    expect(runtime_delta.text).to eq("+7m 30s")
    # The level and the change are one statement, not two figures a reader has to relate — and
    # both are printed by `TestRun.humanized_seconds`. `450.0s` here would be criterion 8 broken.
    expect(cost_cell("Total runtime").text).to eq("8m 30s +7m 30s")
  end

  it "names the run the change is measured against, and its age" do
    repository = create_repository(user: @user)
    got_slower(repository)

    get repository_path(repository)

    expect(runtime_basis).to have_text("The total runtime is measured against a1b2c3d",
                                       normalize_ws: true)
    expect(runtime_basis).to have_text("the previous run on main", normalize_ws: true)
    expect(runtime_basis).to have_text("about 3 hours ago", normalize_ws: true)
    # No shard clause on the unsharded corpus: there is no composition to state, and "both timed 0
    # of their 0 shards" describes two runs that lost all their telemetry.
    expect(runtime_basis).to have_no_text("timed the same number of shards", normalize_ws: true)
  end

  # The whole point of a signed figure. `400` beside a wall clock reads as a second, smaller
  # duration, not as four hundred seconds saved.
  it "renders a speed-up signed, never as an unsigned magnitude" do
    repository = create_repository(user: @user)
    unsharded_run(repository, commit_sha: "beforespeedup", total: 1_000, duration: 90.0,
                  created_at: 2.hours.ago)
    unsharded_run(repository, commit_sha: "afterspeedup0", total: 1_000, duration: 65.5,
                  created_at: 1.minute.ago)

    get repository_path(repository)

    # A true minus (U+2212), the character the size delta one row up already uses.
    expect(runtime_delta.text).to eq("−24.5s")
    expect(runtime_delta.text).not_to eq("24.5s")
    expect(runtime_delta.text).not_to eq("-24.5s")
    expect(cost_cell("Total runtime").text).to eq("1m 6s −24.5s")
  end

  # Criterion 4. "Compared, and it did not move" is a real answer, and a suite that held its
  # runtime steady across a change is precisely the thing a reader wants confirmed.
  it "says the runtime did not move rather than falling silent" do
    repository = create_repository(user: @user)
    unsharded_run(repository, commit_sha: "steadytime01", total: 1_000, duration: 120.0,
                  created_at: 2.hours.ago)
    unsharded_run(repository, commit_sha: "steadytime02", total: 1_100, duration: 120.0,
                  created_at: 1.minute.ago)

    get repository_path(repository)

    expect(runtime_delta.text).to eq("±0")
    expect(runtime_basis).to have_text("measured against steadyt", normalize_ws: true)
  end

  # `duration_reported?` is `!duration_seconds.nil?`, so a run that genuinely measured nothing in
  # no time at all HAS a measurement. A `present?` check would re-file it as "no timing sent" and
  # the page would withhold a change it can stand behind.
  it "differences a measured 0.0 rather than reading it as no timing" do
    repository = create_repository(user: @user)
    unsharded_run(repository, commit_sha: "measuredzero", total: 0, duration: 0.0,
                  created_at: 2.hours.ago)
    unsharded_run(repository, commit_sha: "thenrealtime", total: 4, duration: 12.5,
                  created_at: 1.minute.ago)

    get repository_path(repository)

    expect(runtime_delta.text).to eq("+12.5s")
  end

  describe "when one side never reported a timing" do
    it "withholds the change when the previous run reported none, and says which side" do
      repository = create_repository(user: @user)
      unsharded_run(repository, commit_sha: "notimingprev", total: 1_000, duration: nil,
                    created_at: 2.hours.ago)
      unsharded_run(repository, commit_sha: "hastiming001", total: 1_000, duration: 300.0,
                    created_at: 1.minute.ago)

      get repository_path(repository)

      # `+5m 0s` here would charge one commit for the whole wall clock because the run before it
      # sent no timing — the runtime's version of the "whole suite as growth" defect.
      expect(overview_panel).to have_no_css("#runtime-delta")
      expect(cost_cell("Total runtime").text).to eq("5m")
      expect(runtime_basis).to have_text("previous run on main (notimin) reported no timing",
                                         normalize_ws: true)
      # The other side's wording, which must not stand in for this one: this run reported 300s.
      expect(runtime_basis).to have_no_text("This run reported no timing", normalize_ws: true)
    end

    it "withholds the change when this run reported none, and says which side" do
      repository = create_repository(user: @user)
      unsharded_run(repository, commit_sha: "hastiming002", total: 1_000, duration: 300.0,
                    created_at: 2.hours.ago)
      unsharded_run(repository, commit_sha: "notimingnow0", total: 1_000, duration: nil,
                    created_at: 1.minute.ago)

      get repository_path(repository)

      expect(overview_panel).to have_no_css("#runtime-delta")
      # The level is still the muted "not reported" it always was — an absent fact styled as
      # absent, never a runtime of zero with a change hung off it.
      expect(cost_cell("Total runtime").text).to eq("not reported")
      expect(runtime_basis).to have_text("This run reported no timing at all", normalize_ws: true)
      expect(runtime_basis).to have_no_text("reported no timing, so there is nothing to measure",
                                            normalize_ws: true)
    end
  end

  # == The condition the suite-size delta has no equivalent of
  #
  # `assembled_like?` compares `shard_count`, which is the right denominator for a SUM of counts
  # and the wrong one for a MAX of durations: `duration_seconds` is the maximum over the shards
  # that REPORTED, so its denominator is `timed_shard_count`. Two runs can be assembled identically
  # — same shard count, same suite size, size delta rendering happily — and have wall clocks that
  # are not comparable at all.
  describe "when the two wall clocks were measured over different denominators" do
    # `Api::V1::RepositoriesController` names this exact trap: four timed shards against four
    # shards whose slowest two were cancelled, reporting a speed-up produced entirely by telemetry
    # loss. Here that is 150s → 45s, a 70% "improvement" nobody made.
    def telemetry_loss(repository)
      sharded_run(repository, commit_sha: "alltimed0001", durations: [150.0, 150.0, 150.0, 150.0])
      sharded_run(repository, commit_sha: "twowentquiet", durations: [45.0, 45.0, nil, nil])
    end

    it "withholds the change rather than reporting a speed-up made of missing telemetry" do
      repository = create_repository(user: @user)
      telemetry_loss(repository)

      get repository_path(repository)

      expect(overview_panel).to have_no_css("#runtime-delta")
      expect(overview_panel).to have_no_css("#machine-time-delta")
      expect(cost_cell("Wall clock").text).to eq("45.0s")
      expect(overview_panel).to have_no_text("−1m 45s", normalize_ws: true)
    end

    it "names both denominators when it declines to compare them" do
      repository = create_repository(user: @user)
      telemetry_loss(repository)

      get repository_path(repository)

      expect(runtime_basis).to have_text("This run timed 2 of its 4 shards", normalize_ws: true)
      expect(runtime_basis).to have_text("alltime timed 4 of its 4", normalize_ws: true)
      expect(runtime_basis).to have_text("measured over different denominators", normalize_ws: true)
      # Not one of the other three no-change wordings standing in for this one.
      expect(runtime_basis).to have_no_text("This run reported no timing", normalize_ws: true)
      expect(runtime_basis).to have_no_text("is measured against", normalize_ws: true)
    end

    # Criterion 5, from the surface rather than from the other file staying green. The two guards
    # are independent: these runs ARE the same kind of size measurement — four shards each, 20,000
    # examples each — so the size delta is exactly what it always was while the runtime is withheld.
    it "leaves the suite-size delta rendering, because that guard is a different question" do
      repository = create_repository(user: @user)
      telemetry_loss(repository)

      get repository_path(repository)

      expect(overview_panel.find("#suite-size-delta").text).to eq("±0")
      expect(overview_panel.find("#suite-size-basis")).to have_text("Suite size is measured against",
                                                                   normalize_ws: true)
    end
  end

  describe "on a run assembled from more than one shard" do
    # The case worth putting a second figure on the page for: the split got wider, so the wall
    # clock went UP while the machine time went DOWN. One signed number could not say this, and
    # calling the machine time "slower" would be the wrong word in both halves.
    def rebalanced(repository)
      sharded_run(repository, commit_sha: "evensplit001", durations: [60.0, 60.0, 60.0, 60.0])
      sharded_run(repository, commit_sha: "widersplit02", durations: [75.0, 50.0, 50.0, 50.0])
    end

    it "puts a change beside the wall clock and beside the machine time" do
      repository = create_repository(user: @user)
      rebalanced(repository)

      get repository_path(repository)

      expect(runtime_delta.text).to eq("+15.0s")
      expect(machine_time_delta.text).to eq("−15.0s")
      expect(cost_cell("Wall clock").text).to eq("1m 15s +15.0s")
      expect(cost_cell("Machine time").text).to eq("3m 45s −15.0s")
    end

    it "states that both figures share the basis, and what the two runs timed" do
      repository = create_repository(user: @user)
      rebalanced(repository)

      get repository_path(repository)

      expect(runtime_basis).to have_text("The wall clock is measured against evenspl",
                                         normalize_ws: true)
      expect(runtime_basis).to have_text("and so is the machine time", normalize_ws: true)
      expect(runtime_basis).to have_text("both of these timed 4 of their 4 shards",
                                         normalize_ws: true)
    end

    # The unsharded row is labelled "Total runtime" and the sharded one "Wall clock". They are one
    # column under two labels, and the basis line has to point at the row that is actually there.
    it "names the row it is the basis for" do
      repository = create_repository(user: @user)
      rebalanced(repository)

      get repository_path(repository)

      expect(runtime_basis).to have_no_text("The total runtime", normalize_ws: true)
    end
  end

  # The states that are not about the runtime at all — no candidate row, or two runs that arrived
  # in different numbers of pieces. Both withhold the size AND the runtime for one reason, and that
  # reason is already stated in full on `#suite-size-basis`. A second paragraph repeating it would
  # be two explanations for one absence.
  describe "when there is nothing about the runtime to explain" do
    it "says nothing where the branch's first run already explains itself" do
      repository = create_repository(user: @user)
      unsharded_run(repository, commit_sha: "firstonbranch", total: 42, duration: 30.0,
                    created_at: 1.minute.ago)

      get repository_path(repository)

      expect(overview_panel).to have_no_css("#runtime-delta")
      expect(overview_panel).to have_no_css("#runtime-basis")
      expect(overview_panel.find("#suite-size-basis")).to have_text("No earlier run on main",
                                                                   normalize_ws: true)
    end

    it "says nothing where the two runs arrived in different numbers of pieces" do
      repository = create_repository(user: @user)
      sharded_run(repository, commit_sha: "fourshards01", durations: [60.0, 60.0, 60.0, 60.0])
      ingest_shard(repository, ci_run_id: "gha-inflight", shard_id: "0", total: 5_000,
                   commit_sha: "oneshardsofar", duration: 61.0)

      get repository_path(repository)

      expect(overview_panel).to have_no_css("#runtime-delta")
      expect(overview_panel).to have_no_css("#runtime-basis")
      expect(overview_panel.find("#suite-size-basis")).to have_text("not measuring the same thing",
                                                                    normalize_ws: true)
    end

    # The never-ingested empty state renders no cost row at all, so neither element can exist.
    it "leaves the never-ingested empty state alone" do
      repository = create_repository(user: @user)

      get repository_path(repository)

      expect(overview_panel).to have_text("No CI run has reported yet", normalize_ws: true)
      expect(overview_panel).to have_no_css("#runtime-delta")
      expect(overview_panel).to have_no_css("#runtime-basis")
    end
  end

  # The visible figure is a sign glyph and a duration doing a sentence's work, and neither half
  # survives being read aloud: the `dd` announces as "8m 30s +7m 30s" with nothing tying the second
  # figure to the first, and U+2212 — chosen precisely because it is not a hyphen — is announced
  # inconsistently across screen readers.
  describe "what the figures read as aloud" do
    it "spells out a slower wall clock" do
      repository = create_repository(user: @user)
      got_slower(repository)

      get repository_path(repository)

      expect(runtime_delta["aria-label"]).to eq("7m 30s slower than the previous run on this branch")
    end

    it "spells out a faster wall clock" do
      repository = create_repository(user: @user)
      unsharded_run(repository, commit_sha: "wasslower001", total: 1_000, duration: 90.0,
                    created_at: 2.hours.ago)
      unsharded_run(repository, commit_sha: "nowfaster001", total: 1_000, duration: 65.5,
                    created_at: 1.minute.ago)

      get repository_path(repository)

      expect(runtime_delta["aria-label"]).to eq("24.5s faster than the previous run on this branch")
    end

    it "says a runtime that did not move did not move" do
      repository = create_repository(user: @user)
      unsharded_run(repository, commit_sha: "steadyaria11", total: 1_000, duration: 120.0,
                    created_at: 2.hours.ago)
      unsharded_run(repository, commit_sha: "steadyaria12", total: 1_000, duration: 120.0,
                    created_at: 1.minute.ago)

      get repository_path(repository)

      expect(runtime_delta["aria-label"]).to eq("wall clock unchanged since the previous run on this branch")
    end

    # Machine time is what the suite COST, not how long anyone waited. "Slower" would describe a
    # split that got wider — more machine time, less wall clock — with the wrong word twice.
    it "spells out machine time as more and less, never as slower and faster" do
      repository = create_repository(user: @user)
      sharded_run(repository, commit_sha: "cheapsplit01", durations: [60.0, 60.0, 60.0, 60.0])
      sharded_run(repository, commit_sha: "dearersplit1", durations: [75.0, 50.0, 50.0, 50.0])

      get repository_path(repository)

      expect(machine_time_delta["aria-label"])
        .to eq("15.0s less machine time than the previous run on this branch")
      expect(machine_time_delta["aria-label"]).not_to include("faster")
    end
  end

  # Criterion 6. Every predicate the runtime guard reads — `timed_shard_count`,
  # `machine_seconds` — comes out of `TestRun#shard_totals`, which is one memoized aggregate per
  # instance and has already been taken for both rows by the time the guard runs: for the latest
  # run by the cost rows' own `shard_count`, and for the previous run by `assembled_like?`. So the
  # comparison is free, and this is where that is held.
  #
  # The absolute page count is not asserted here, for the reason the growth file gives: a
  # page-versus-page difference has a control that walks the same code path. What these examples
  # hold is that the runtime comparison adds no work — it costs the same whether it renders a
  # change or withholds one, and the same on a sharded pair as on an unsharded one.
  describe "what the comparison costs the page" do
    def count_queries
      count = 0
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
        count += 1 unless payload[:cached] || payload[:name].in?(["SCHEMA", "TRANSACTION"])
      end
      yield
      count
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it "costs the same whether it renders the change or withholds it" do
      withheld = create_repository(user: @user, github_full_name: "acme/withheld")
      sharded_run(withheld, commit_sha: "wallclock001", durations: [150.0, 150.0, 150.0, 150.0])
      sharded_run(withheld, commit_sha: "wentquiet001", durations: [45.0, 45.0, nil, nil])

      rendered = create_repository(user: @user, github_full_name: "acme/rendered")
      sharded_run(rendered, commit_sha: "wallclock002", durations: [150.0, 150.0, 150.0, 150.0])
      sharded_run(rendered, commit_sha: "stilltimed01", durations: [45.0, 45.0, 45.0, 45.0])

      get repository_path(withheld)
      get repository_path(rendered)

      baseline = count_queries { get repository_path(withheld) }
      expect(overview_panel).to have_no_css("#runtime-delta")

      # Two identically-shaped repositories, four shards a run in both. The only difference is
      # whether two shards reported a timing — so a guard that took its own read of either run's
      # shards would show up as a difference here.
      expect(count_queries { get repository_path(rendered) }).to eq(baseline)
      expect(runtime_delta.text).to eq("−1m 45s")
    end

    it "costs no more on a sharded pair than the page already paid for its shard aggregates" do
      unsharded = create_repository(user: @user, github_full_name: "acme/unsharded")
      got_slower(unsharded)

      get repository_path(unsharded)
      baseline = count_queries { get repository_path(unsharded) }
      expect(runtime_delta.text).to eq("+7m 30s")

      sharded = create_repository(user: @user, github_full_name: "acme/sharded")
      sharded_run(sharded, commit_sha: "shardedpair1", durations: [60.0, 60.0, 60.0, 60.0])
      sharded_run(sharded, commit_sha: "shardedpair2", durations: [75.0, 50.0, 50.0, 50.0])

      get repository_path(sharded)

      # The sharded page renders a machine-time delta the unsharded one has no row for, and reads
      # `timed_shard_count` and `machine_seconds` off BOTH runs to do it. All four come out of the
      # two aggregates the page was already taking, so the count does not move.
      expect(count_queries { get repository_path(sharded) }).to eq(baseline)
      expect(machine_time_delta.text).to eq("−15.0s")
    end
  end

  # Suite telemetry, not credential metadata — the same class of fact as the runtime it modifies,
  # so it sits outside the `keys.manage` gate exactly as the size delta does.
  it "is visible to a member with only 'view'" do
    repository = create_repository(user: @user)
    got_slower(repository)
    member = sign_in_via_github(uid: "9999")
    create_membership(repository: repository, user: member, permissions: %w[view])

    get repository_path(repository)

    expect(response).to have_http_status(:ok)
    expect(runtime_delta.text).to eq("+7m 30s")
  end
end
