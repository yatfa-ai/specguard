# frozen_string_literal: true

require "rails_helper"

RSpec.describe Repository do
  # Shared by every budget example below. Counting queries is how three separate criteria on this
  # model are stated — `previous_test_run_on_branch` costs one, `suite_size_trajectory` costs one
  # for a whole series — so it is defined once rather than re-spelled per block.
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

  it "requires an org/repo shaped full name" do
    repository = create_user.repositories.new(github_full_name: "not-a-full-name")

    expect(repository).not_to be_valid
    expect(repository.errors[:github_full_name]).to include("must look like org/repo")
  end

  it "derives the short name from the full name" do
    expect(create_repository(github_full_name: "acme/billing-service").name).to eq("billing-service")
  end

  it "normalizes a pasted GitHub URL down to org/repo" do
    repository = create_repository(github_full_name: "https://github.com/acme/billing-service.git")

    expect(repository.github_full_name).to eq("acme/billing-service")
  end

  it "registers a given GitHub repository at most once" do
    create_repository(github_full_name: "acme/billing-service")
    duplicate = create_user(github_uid: "2002", github_handle: "hubot")
                .repositories.new(github_full_name: "acme/billing-service")

    expect(duplicate).not_to be_valid
  end

  describe "#annotated_ratio" do
    # Sourced from the latest TestRun's counters, not from `spec_intents`. Real ingestion persists
    # only annotated intents — the four intent columns are NOT NULL, so an unannotated spec is not
    # a row that can exist — which means counting rows here could only ever return 100%.
    it "reports the annotated share of the most recent run" do
      repository = create_repository
      repository.test_runs.create!(commit_sha: "abc123", total_specs_count: 3,
                                   annotated_specs_count: 2)

      expect(repository.annotated_ratio).to eq(66.7)
    end

    it "is not pinned to 100% by the intents ingestion actually persists" do
      repository = create_repository
      repository.test_runs.create!(commit_sha: "abc123", total_specs_count: 3,
                                   annotated_specs_count: 2)
      # Exactly what /ingest writes for that run once slice 3 lands: the two annotated specs, and
      # nothing at all for the third.
      create_spec_intent(repository: repository, line_number: 1)
      create_spec_intent(repository: repository, line_number: 2)

      expect(repository.spec_intents.count).to eq(2)
      expect(repository.annotated_ratio).to eq(66.7)
    end

    it "supersedes an older run rather than averaging over history" do
      repository = create_repository
      repository.test_runs.create!(commit_sha: "old", total_specs_count: 10,
                                   annotated_specs_count: 1, created_at: 1.day.ago)
      repository.test_runs.create!(commit_sha: "new", total_specs_count: 4,
                                   annotated_specs_count: 3)

      expect(repository.annotated_ratio).to eq(75.0)
    end

    it "breaks a same-instant tie on id so the reading is deterministic" do
      repository = create_repository
      at = 1.hour.ago
      repository.test_runs.create!(commit_sha: "first", total_specs_count: 4,
                                   annotated_specs_count: 1, created_at: at)
      repository.test_runs.create!(commit_sha: "second", total_specs_count: 4,
                                   annotated_specs_count: 3, created_at: at)

      expect(repository.annotated_ratio).to eq(75.0)
    end

    it "ignores another repository's runs" do
      repository = create_repository
      other = create_repository(user: create_user(github_uid: "2002", github_handle: "hubot"),
                                github_full_name: "acme/ledger")
      other.test_runs.create!(commit_sha: "abc123", total_specs_count: 4, annotated_specs_count: 4)

      expect(repository.annotated_ratio).to eq(0.0)
    end

    it "is 0.0 for a repository that has never ingested a run" do
      repository = create_repository

      expect(repository.annotated_ratio).to eq(0.0)
      expect(repository.annotated_ratio).to be_a(Float)
    end

    # The sharded case, read from this end. A sharded run used to land as one row per shard, so
    # `latest_test_run` picked whichever shard finished last — and shard completion order is not
    # stable, which made the headline move without the suite changing. Accumulation leaves one row
    # per run, so there is nothing left to pick between.
    it "reads a sharded run's accumulated row rather than one shard's slice of it" do
      repository = create_repository
      run = repository.test_runs.create!(commit_sha: "deadbee", ci_run_id: "gha-42",
                                         total_specs_count: 4900, annotated_specs_count: 500)
      TestRun.update_counters(run.id, total_specs_count: 15_100, annotated_specs_count: 4500)

      expect(repository.latest_test_run).to eq(run)
      expect(repository.latest_test_run.total_specs_count).to eq(20_000)
      expect(repository.annotated_ratio).to eq(25.0)
    end
  end

  describe "#recent_test_runs" do
    it "returns the newest runs first" do
      repository = create_repository
      repository.test_runs.create!(commit_sha: "oldest", created_at: 2.days.ago)
      repository.test_runs.create!(commit_sha: "middle", created_at: 1.day.ago)
      repository.test_runs.create!(commit_sha: "newest", created_at: 1.hour.ago)

      expect(repository.recent_test_runs.map(&:commit_sha)).to eq(%w[newest middle oldest])
    end

    it "breaks a same-instant tie on id, matching #latest_test_run" do
      # The Overview panel names `latest_test_run` and this panel's top row names the same run.
      # If the two orderings disagreed — and the id tie-break is the only thing that decides a
      # same-instant pair — the page would print two different commits for one run.
      repository = create_repository
      at = 1.hour.ago
      repository.test_runs.create!(commit_sha: "first", created_at: at)
      repository.test_runs.create!(commit_sha: "second", created_at: at)

      expect(repository.recent_test_runs.first).to eq(repository.latest_test_run)
      expect(repository.recent_test_runs.map(&:commit_sha)).to eq(%w[second first])
    end

    it "honours the limit, defaulting to ten" do
      repository = create_repository
      12.times { |i| repository.test_runs.create!(commit_sha: "sha#{i}", created_at: i.hours.ago) }

      expect(repository.recent_test_runs.count).to eq(10)
      expect(repository.recent_test_runs(limit: 3).map(&:commit_sha)).to eq(%w[sha0 sha1 sha2])
    end

    it "ignores another repository's runs" do
      repository = create_repository
      other = create_repository(user: create_user(github_uid: "2002", github_handle: "hubot"),
                                github_full_name: "acme/ledger")
      other.test_runs.create!(commit_sha: "not-mine")

      expect(repository.recent_test_runs).to be_empty
    end
  end

  describe "#previous_test_run_on_branch" do
    it "returns the newest earlier run on the same branch" do
      repository = create_repository
      repository.test_runs.create!(commit_sha: "oldest", branch: "main", created_at: 3.days.ago)
      repository.test_runs.create!(commit_sha: "middle", branch: "main", created_at: 2.days.ago)
      latest = repository.test_runs.create!(commit_sha: "latest", branch: "main", created_at: 1.day.ago)

      expect(repository.previous_test_run_on_branch(latest).commit_sha).to eq("middle")
    end

    it "excludes the run it was asked about" do
      repository = create_repository
      only = repository.test_runs.create!(commit_sha: "only", branch: "main")

      expect(repository.previous_test_run_on_branch(only)).to be_nil
    end

    # The whole reason this method exists. `test_runs` is one interleaved history across every
    # branch — the "Recent runs" panel lists it that way — so the row immediately before the latest
    # is routinely a different branch, and a delta taken against it reports a change no commit made.
    it "does not reach across to a run on another branch" do
      repository = create_repository
      repository.test_runs.create!(commit_sha: "trunk", branch: "main", total_specs_count: 1000,
                                   created_at: 2.days.ago)
      feature = repository.test_runs.create!(commit_sha: "featur", branch: "feature/x",
                                             total_specs_count: 20, created_at: 1.day.ago)

      expect(repository.previous_test_run_on_branch(feature)).to be_nil
    end

    # `Ingest::Payload` writes `branch` through `.presence` and accepts a body without one, so this
    # is a live state. Matching `branch IS NULL` would pool every anonymous run from every branch
    # and every machine into one fictional history — "SpecGuard does not know where this came from"
    # is not a branch two runs can share.
    it "declines to compare runs that named no branch" do
      repository = create_repository
      repository.test_runs.create!(commit_sha: "anon01", branch: nil, created_at: 2.days.ago)
      anonymous = repository.test_runs.create!(commit_sha: "anon02", branch: nil, created_at: 1.day.ago)

      expect(repository.previous_test_run_on_branch(anonymous)).to be_nil
    end

    it "is nil for a repository that has never ingested a run" do
      expect(create_repository.previous_test_run_on_branch(nil)).to be_nil
    end

    # The same tie-break `latest_test_run` and `recent_test_runs` share. Both halves of it are
    # pinned, and they fail to different mutations — verified, because the obvious single example
    # pins neither on its own. Asked about the LATEST run, a bare `id != run.id` happens to return
    # the right row, so only the `created_at` half is under test here; the example below asks about
    # a run that is not the latest, which is where a set-exclusion and a strict ordering diverge.
    it "breaks a same-instant tie on id, matching #latest_test_run" do
      repository = create_repository
      at = 1.hour.ago
      repository.test_runs.create!(commit_sha: "older0", branch: "main", created_at: 2.hours.ago)
      repository.test_runs.create!(commit_sha: "first0", branch: "main", created_at: at)
      second = repository.test_runs.create!(commit_sha: "second", branch: "main", created_at: at)

      expect(repository.latest_test_run).to eq(second)
      # `created_at <` alone would skip the twin entirely and answer "older0".
      expect(repository.previous_test_run_on_branch(second).commit_sha).to eq("first0")
    end

    # "Previous" is strictly EARLIER in the ordering, not merely "some other run". Asked about the
    # older twin, a `WHERE id != run.id` would answer with `second` — a run ingested *after* it —
    # and report the suite's growth backwards. Nothing on the page asks this today (the controller
    # only ever passes the latest run), so this is the example that holds the contract while that
    # remains true.
    it "returns a strictly earlier run, never the newer half of a same-instant pair" do
      repository = create_repository
      at = 1.hour.ago
      repository.test_runs.create!(commit_sha: "older0", branch: "main", created_at: 2.hours.ago)
      first = repository.test_runs.create!(commit_sha: "first0", branch: "main", created_at: at)
      repository.test_runs.create!(commit_sha: "second", branch: "main", created_at: at)

      expect(repository.previous_test_run_on_branch(first).commit_sha).to eq("older0")
    end

    # The ORDER BY's half of the same tie-break, which the two examples above cannot reach: they
    # leave only one candidate at the tied instant, so the sort never has to choose. With three
    # runs at one instant the sort does choose, and `created_at: :desc` alone leaves that choice
    # UNSPECIFIED — Postgres returns the lowest id here, which is the oldest of the three and two
    # rows away from the one the Recent-runs table prints directly beneath the latest.
    it "orders the tied candidates by id too, not only the boundary" do
      repository = create_repository
      at = 1.hour.ago
      repository.test_runs.create!(commit_sha: "tie_a", branch: "main", created_at: at)
      repository.test_runs.create!(commit_sha: "tie_b", branch: "main", created_at: at)
      newest = repository.test_runs.create!(commit_sha: "tie_c", branch: "main", created_at: at)

      expect(repository.latest_test_run).to eq(newest)
      expect(repository.previous_test_run_on_branch(newest).commit_sha).to eq("tie_b")
      expect(repository.recent_test_runs.second.commit_sha).to eq("tie_b")
    end

    it "ignores another repository's runs on the same branch" do
      repository = create_repository
      other = create_repository(user: create_user(github_uid: "2002", github_handle: "hubot"),
                                github_full_name: "acme/ledger")
      other.test_runs.create!(commit_sha: "foreig", branch: "main", created_at: 2.days.ago)
      mine = repository.test_runs.create!(commit_sha: "mine00", branch: "main", created_at: 1.day.ago)

      expect(repository.previous_test_run_on_branch(mine)).to be_nil
    end

    # Criterion 6, measured HERE rather than only through the page. The request-level version of
    # this measures a whole render against another whole render, and a control that walks the same
    # code path is contaminated by any mutation that inflates both sides equally — verified: an
    # implementation that ignores its argument and re-reads `latest_test_run` costs one extra query
    # in *both* the with-comparison and the no-comparison renders, so their difference is still 1
    # and a page-level assertion stays green. This counts the method itself, where there is nothing
    # else in the block to hide behind.
    describe "what it costs to ask" do
      it "is one query when there is a branch to look along" do
        repository = create_repository
        repository.test_runs.create!(commit_sha: "before", branch: "main", created_at: 2.days.ago)
        latest = repository.test_runs.create!(commit_sha: "latest", branch: "main", created_at: 1.day.ago)

        # One. Not one plus a re-read of the run the caller already handed over.
        expect(count_queries { repository.previous_test_run_on_branch(latest) }).to eq(1)
      end

      it "is no query at all when there is nothing to compare" do
        repository = create_repository
        anonymous = repository.test_runs.create!(commit_sha: "anon00", branch: nil)

        # The guard returns before touching the database, so a repository whose CI sends no branch
        # pays nothing for a comparison it will never be shown.
        expect(count_queries { repository.previous_test_run_on_branch(anonymous) }).to eq(0)
        expect(count_queries { repository.previous_test_run_on_branch(nil) }).to eq(0)
      end
    end
  end

  describe "#suite_size_trajectory" do
    def run(repository, commit, branch: "main", total: 100, at: 1.hour.ago)
      repository.test_runs.create!(commit_sha: commit, branch: branch, total_specs_count: total,
                                   created_at: at)
    end

    it "returns the branch's runs oldest first, so the series reads left to right" do
      repository = create_repository
      run(repository, "oldest", at: 3.days.ago)
      run(repository, "middle", at: 2.days.ago)
      latest = run(repository, "newest", at: 1.day.ago)

      expect(repository.suite_size_trajectory(latest).map(&:commit_sha)).to eq(%w[oldest middle newest])
    end

    # The anchor is the newest point of its own trajectory, which is the only reason this is `<=`
    # where `previous_test_run_on_branch` is `<`. Everything else about the comparison is identical.
    it "includes the run it is anchored on" do
      repository = create_repository
      latest = run(repository, "anchor")

      expect(repository.suite_size_trajectory(latest).map(&:commit_sha)).to eq(%w[anchor])
    end

    it "never reaches forward past the run it was anchored on" do
      repository = create_repository
      anchor = run(repository, "anchor", at: 2.days.ago)
      run(repository, "later0", at: 1.day.ago)

      expect(repository.suite_size_trajectory(anchor).map(&:commit_sha)).to eq(%w[anchor])
    end

    # The whole reason it is branch-scoped, and the reason the "Recent runs" panel disclaims being
    # a series: `test_runs` is one interleaved history, so a line drawn across it would join a trunk
    # run to a feature branch's and call the gap growth.
    it "ignores other branches" do
      repository = create_repository
      run(repository, "trunk0", branch: "main", at: 2.days.ago)
      run(repository, "featur", branch: "feature/x", at: 1.day.ago)
      latest = run(repository, "trunk1", branch: "main", at: 1.hour.ago)

      expect(repository.suite_size_trajectory(latest).map(&:commit_sha)).to eq(%w[trunk0 trunk1])
    end

    it "ignores another repository's runs on a branch of the same name" do
      repository = create_repository
      other = create_repository(user: create_user(github_uid: "2002", github_handle: "hubot"),
                                github_full_name: "acme/ledger")
      run(other, "notmine", at: 2.days.ago)
      latest = run(repository, "mine00", at: 1.day.ago)

      expect(repository.suite_size_trajectory(latest).map(&:commit_sha)).to eq(%w[mine00])
    end

    # `Ingest::Payload` writes `branch` through `.presence`, so an anonymous run is an ordinary live
    # state. Pooling every one of them under `branch IS NULL` would draw one line through runs from
    # every branch and every machine.
    it "has no series for a run that named no branch, and asks nothing of the database" do
      repository = create_repository
      anonymous = run(repository, "anon00", branch: nil)

      expect(count_queries { expect(repository.suite_size_trajectory(anonymous)).to eq([]) }).to eq(0)
      expect(count_queries { expect(repository.suite_size_trajectory(nil)).to eq([]) }).to eq(0)
    end

    # DESC + LIMIT then reversed: the bound has to keep the NEWEST thirty and hand them back
    # oldest-first. An implementation that ordered ascending and limited would return the oldest
    # thirty — a chart of ancient history that stops before the run the page is about.
    it "keeps the newest runs when the history is longer than the bound" do
      repository = create_repository
      40.times { |i| run(repository, "sha#{i.to_s.rjust(2, "0")}", at: (40 - i).days.ago) }
      latest = repository.latest_test_run

      series = repository.suite_size_trajectory(latest)

      expect(series.size).to eq(Repository::TRAJECTORY_LIMIT)
      expect(series.first.commit_sha).to eq("sha10")
      expect(series.last.commit_sha).to eq("sha39")
    end

    it "honours a caller's own bound" do
      repository = create_repository
      5.times { |i| run(repository, "sha#{i}", at: (5 - i).days.ago) }

      series = repository.suite_size_trajectory(repository.latest_test_run, limit: 2)

      expect(series.map(&:commit_sha)).to eq(%w[sha3 sha4])
    end

    # The tie-break, which is the half of the ordering a bare `created_at` comparison loses. A
    # series is where it does the most damage: a reversed same-instant pair draws the suite jumping
    # up and back down between two runs ingested in the same second.
    it "orders a same-instant pair by id, the same way every other reader of this history does" do
      repository = create_repository
      at = 1.hour.ago
      run(repository, "tied_a", total: 10, at: at)
      run(repository, "tied_b", total: 12, at: at)
      latest = repository.latest_test_run

      expect(latest.commit_sha).to eq("tied_b")
      expect(repository.suite_size_trajectory(latest).map(&:commit_sha)).to eq(%w[tied_a tied_b])
    end

    describe "the shard count each point carries" do
      # Every point has to answer `assembled_like?` before it may be plotted, and that routes
      # through a memoized per-INSTANCE `pick`. Primed from the same query, it costs nothing.
      it "primes every row, including the unsharded corpus" do
        repository = create_repository
        run(repository, "plain0", at: 2.days.ago)
        sharded = run(repository, "sharded", at: 1.day.ago)
        3.times { |i| sharded.test_run_shards.create!(shard_id: i.to_s, total_specs_count: 10) }

        series = repository.suite_size_trajectory(repository.latest_test_run)

        expect(count_queries { expect(series.map(&:shard_count)).to eq([0, 3]) }).to eq(0)
      end

      it "does not let one run's shards inflate another's count" do
        repository = create_repository
        first = run(repository, "first0", at: 2.days.ago)
        second = run(repository, "second", at: 1.day.ago)
        4.times { |i| first.test_run_shards.create!(shard_id: i.to_s, total_specs_count: 10) }
        second.test_run_shards.create!(shard_id: "0", total_specs_count: 10)

        expect(repository.suite_size_trajectory(repository.latest_test_run).map(&:shard_count))
          .to eq([4, 1])
      end

      # The shard count rides along as a correlated scalar subquery, which returns 0 for a run that
      # recorded no shard rows — so the entire unsharded corpus stays in its own history. The
      # `LEFT JOIN … GROUP BY` this was NOT written as would preserve them too; an INNER join would
      # silently delete every one of them from the chart. Named precisely because the construct is
      # the thing under test: `Repository#suite_size_trajectory` explains at length why the join was
      # rejected (it aggregates the whole branch before the LIMIT, so it cannot walk the ordering
      # index — ~12ms on a 40,000-run branch versus ~0.05ms), and a "simplification" toward it would
      # leave this example green while restoring the plan.
      it "does not drop a run that recorded no shards at all" do
        repository = create_repository
        run(repository, "plain0", at: 2.days.ago)
        sharded = run(repository, "sharded", at: 1.day.ago)
        sharded.test_run_shards.create!(shard_id: "0", total_specs_count: 10)

        expect(repository.suite_size_trajectory(repository.latest_test_run).map(&:commit_sha))
          .to eq(%w[plain0 sharded])
      end
    end

    # Criterion: the panel adds ONE query. Asserted HERE rather than only through the page, for the
    # reason spec/requests/repository_suite_growth_spec.rb states about its own budget examples: a
    # render-versus-render difference has a control that walks the same code path, so an
    # implementation which inflated both sides equally would leave the difference intact. This
    # counts the method itself, where there is nothing else in the block to hide behind.
    describe "what it costs to ask" do
      it "is one query for the whole series, shard counts included" do
        repository = create_repository
        3.times { |i| run(repository, "sha#{i}", at: (3 - i).days.ago) }
        latest = repository.latest_test_run

        expect(count_queries { repository.suite_size_trajectory(latest) }).to eq(1)
      end

      # The N+1 that would otherwise ship green: `shard_count` is one `pick` per instance, so the
      # cost would be invisible until a repository's history became sharded — which is exactly the
      # history this panel exists to be careful about.
      it "stays one query as the history grows and its runs become sharded" do
        repository = create_repository
        3.times { |i| run(repository, "sha#{i}", at: (20 - i).days.ago) }
        early = repository.latest_test_run
        expect(count_queries { repository.suite_size_trajectory(early) }).to eq(1)

        10.times do |i|
          sharded = run(repository, "shard#{i}", at: (10 - i).days.ago)
          4.times { |s| sharded.test_run_shards.create!(shard_id: s.to_s, total_specs_count: 25) }
        end
        latest = repository.latest_test_run

        series = nil
        expect(count_queries { series = repository.suite_size_trajectory(latest) }).to eq(1)
        # ...and reading the primed counts afterwards asks nothing either, which is the half a bare
        # query count around the loader would miss.
        expect(count_queries { series.each(&:shard_count) }).to eq(0)
      end
    end
  end

  it "takes its api keys, runs and intents with it when destroyed" do
    repository = create_repository
    repository.api_keys.create!
    create_spec_intent(repository: repository)

    expect { repository.destroy! }.to change(ApiKey, :count).by(-1).and change(SpecIntent, :count).by(-1)
  end
end
