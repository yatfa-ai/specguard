# frozen_string_literal: true

require "rails_helper"

RSpec.describe Repository do
  # `count_queries` comes from spec/support/query_capture.rb, included into every example group.
  # Counting queries is how three separate criteria on this model are stated —
  # `previous_test_run_on_branch` costs one, `suite_size_trajectory` costs one for a whole series.

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

  describe "#github_blob_url" do
    # The one seam every "go and look" link on the dashboard composes through. `#github_url` names
    # the repository; this names a LINE, which is the grain every per-example surface prints and
    # until now could not open.
    it "composes a line-anchored blob URL at the ref it was given" do
      repository = create_repository(github_full_name: "acme/billing-service")

      expect(repository.github_blob_url("spec/models/order_spec.rb", 30, "feedfacecafe0001"))
        .to eq("https://github.com/acme/billing-service/blob/feedfacecafe0001/spec/models/order_spec.rb#L30")
    end

    # The ref is the CALLER's, and there is no default — a coordinate is only true against the tree
    # it was recorded from (`file_path`/`line_number` are a last known path, not an identity), so
    # pinning to a sha and pinning to `main` are different links and the caller has to say which.
    it "pins to whatever ref the caller names rather than to a branch of its own" do
      repository = create_repository(github_full_name: "acme/billing-service")

      expect(repository.github_blob_url("spec/models/order_spec.rb", 30, "0ff10e"))
        .to include("/blob/0ff10e/")
      expect(repository.github_blob_url("spec/models/order_spec.rb", 30, "main"))
        .to include("/blob/main/")
    end

    # Escaped SEGMENT-WISE: the separators are structure and everything else in a segment is not.
    # A whole-string `url_encode` would collapse the path into one escaped filename GitHub cannot
    # resolve, and no escaping at all would let a `#` in a filename terminate the path and swallow
    # the line anchor.
    it "escapes each path segment without escaping the separators" do
      repository = create_repository(github_full_name: "acme/billing-service")

      url = repository.github_blob_url("spec/models/order #2_spec.rb", 7, "abc123")

      expect(url).to eq("https://github.com/acme/billing-service/blob/abc123/spec/models/order%20%232_spec.rb#L7")
    end

    # The same rule on the ref, for the same reason: a sha needs no escaping, but a ref is a
    # caller's string and a branch name legitimately carries slashes that must stay separators.
    it "keeps the slashes in a branch-shaped ref" do
      repository = create_repository(github_full_name: "acme/billing-service")

      expect(repository.github_blob_url("spec/models/order_spec.rb", 3, "feature/deep links"))
        .to include("/blob/feature/deep%20links/spec/models/order_spec.rb#L3")
    end

    # It COMPOSES and asks GitHub nothing — no probe, no existence check, and so no query and no
    # network call on a hundred-row worklist. An unpushed sha or a path deleted since answers 404,
    # which is GitHub telling the truth rather than something to guard here.
    it "issues no query" do
      repository = create_repository(github_full_name: "acme/billing-service")

      expect(count_queries { repository.github_blob_url("spec/models/order_spec.rb", 1, "abc") }).to eq(0)
    end
  end

  describe "#github_commit_url" do
    # The third peer beside `#github_url` and `#github_blob_url`. Those answer "which repository"
    # and "which line"; this answers WHICH CHANGE — the question a panel that prints a sha leaves
    # the reader holding, and the one the product could not open at all before this method.
    it "composes a commit URL at the ref it was given" do
      repository = create_repository(github_full_name: "acme/billing-service")

      expect(repository.github_commit_url("feedfacecafe0001"))
        .to eq("https://github.com/acme/billing-service/commit/feedfacecafe0001")
    end

    # A COMMIT, never a range: it describes the ref it is handed and says nothing about what came
    # before it. A `/compare/` link would need a second ref that only row adjacency could supply,
    # and row adjacency is not commit adjacency — naming the wrong range is worse than naming none.
    it "links one commit rather than a range" do
      repository = create_repository(github_full_name: "acme/billing-service")

      url = repository.github_commit_url("abc123")

      expect(url).to include("/commit/abc123")
      expect(url).not_to include("compare")
      expect(url).not_to include("...")
    end

    # The ref is the CALLER's and there is no default, on the same rule `#github_blob_url` states:
    # a per-row caller must be able to pin each row to its own sha, so two refs must give two URLs.
    it "pins to whatever ref the caller names" do
      repository = create_repository(github_full_name: "acme/billing-service")

      expect(repository.github_commit_url("0ff10e")).to end_with("/commit/0ff10e")
      expect(repository.github_commit_url("main")).to end_with("/commit/main")
    end

    # The same segment-wise rule as the ref above, for the same reason: a sha needs no escaping at
    # all, but a ref is a caller's string and a branch name legitimately carries slashes that must
    # survive as structure rather than be flattened into one unresolvable segment.
    it "keeps the slashes in a branch-shaped ref while escaping the rest" do
      repository = create_repository(github_full_name: "acme/billing-service")

      expect(repository.github_commit_url("feature/deep links"))
        .to eq("https://github.com/acme/billing-service/commit/feature/deep%20links")
    end

    # It COMPOSES and asks GitHub nothing — no probe, no existence check, so no query even when a
    # panel calls it once per row. An unpushed sha answers 404, which is GitHub telling the truth.
    it "issues no query" do
      repository = create_repository(github_full_name: "acme/billing-service")

      expect(count_queries { repository.github_commit_url("abc") }).to eq(0)
    end
  end

  describe "#latest_test_run" do
    # The anchor every suite figure on the Overview panel and the API's `latest_run` block is read
    # off, so what "latest" means is pinned here directly rather than inferred through a figure
    # derived from it. `nil` — no run at all — is load-bearing and means *never ingested*; the
    # callers draw the "never reported" vs "reported and found nothing" distinction on it.
    it "returns the newest run rather than an earlier one" do
      repository = create_repository
      repository.test_runs.create!(commit_sha: "old", total_specs_count: 10,
                                   annotated_specs_count: 1, created_at: 1.day.ago)
      newest = repository.test_runs.create!(commit_sha: "new", total_specs_count: 4,
                                            annotated_specs_count: 3)

      expect(repository.latest_test_run).to eq(newest)
    end

    it "breaks a same-instant tie on id so the reading is deterministic" do
      repository = create_repository
      at = 1.hour.ago
      repository.test_runs.create!(commit_sha: "first", total_specs_count: 4,
                                   annotated_specs_count: 1, created_at: at)
      second = repository.test_runs.create!(commit_sha: "second", total_specs_count: 4,
                                            annotated_specs_count: 3, created_at: at)

      expect(repository.latest_test_run).to eq(second)
    end

    it "ignores another repository's runs" do
      repository = create_repository
      other = create_repository(user: create_user(github_uid: "2002", github_handle: "hubot"),
                                github_full_name: "acme/ledger")
      other.test_runs.create!(commit_sha: "abc123", total_specs_count: 4, annotated_specs_count: 4)

      expect(repository.latest_test_run).to be_nil
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
      expect(repository.latest_test_run.annotated_specs_count).to eq(5000)
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

    # `branch:` — the predicate that has to live INSIDE this query rather than be applied to its
    # result. Bounding first and filtering afterwards is what makes a branch's history unreachable:
    # the limit is spent on whatever CI happened to run.
    describe "branch:" do
      # Six `main` runs, then six `feature/x` runs, read at `limit: 3`. The three newest runs
      # repository-wide are all `feature/x`, so filtering the unfiltered result at this limit
      # returns nothing at all — and the correct answer is three `main` rows. A fixture whose
      # branches interleaved would pass under either implementation.
      def starved_repository
        repository = create_repository
        6.times { |i| repository.test_runs.create!(commit_sha: "main#{i}", branch: "main", created_at: (20 - i).hours.ago) }
        6.times { |i| repository.test_runs.create!(commit_sha: "feat#{i}", branch: "feature/x", created_at: (6 - i).hours.ago) }
        repository
      end

      it "applies the bound to the branch's own rows, not to a window filtered afterwards" do
        repository = starved_repository

        # The starvation, stated: the unfiltered window at this bound holds no `main` row.
        expect(repository.recent_test_runs(limit: 3).map(&:branch)).to eq(%w[feature/x feature/x feature/x])
        expect(repository.recent_test_runs(limit: 3, branch: "main").map(&:commit_sha))
          .to eq(%w[main5 main4 main3])
      end

      it "keeps the created_at/id tie-break inside the narrowed window" do
        repository = create_repository
        at = 1.hour.ago
        repository.test_runs.create!(commit_sha: "first", branch: "main", created_at: at)
        repository.test_runs.create!(commit_sha: "second", branch: "main", created_at: at)
        repository.test_runs.create!(commit_sha: "other", branch: "feature/x", created_at: at)

        expect(repository.recent_test_runs(branch: "main").map(&:commit_sha)).to eq(%w[second first])
      end

      it "returns nothing for a branch that never ran, rather than falling back to the whole history" do
        repository = starved_repository

        expect(repository.recent_test_runs(branch: "release/nope")).to be_empty
      end

      # The guard the API's own `.presence` makes unreachable from that direction, asserted here
      # because this is a public model method and `RepositoriesController` calls it too. `nil` and
      # `""` both mean "no filter" — never `WHERE branch = ''`, which matches nothing and would
      # turn an empty string into an unknown-branch answer.
      it "treats nil and a blank string alike as no filter" do
        repository = starved_repository

        expect(repository.recent_test_runs(limit: 12, branch: nil).length).to eq(12)
        expect(repository.recent_test_runs(limit: 12, branch: "").length).to eq(12)
        expect(repository.recent_test_runs(limit: 12, branch: "   ").length).to eq(12)
      end

      # The trap `#previous_test_run_on_branch` and `#suite_size_trajectory` already guard, reached
      # through a new door. `branch` is nullable and `Ingest::Payload` writes `.presence`, so
      # anonymous runs are an ordinary live state — and `WHERE branch IS NULL` would pool every one
      # of them, from every branch and every machine, into a single fictional history. A blank
      # argument must return the anonymous rows AS PART OF the unfiltered history and never as a
      # scoped series of their own.
      it "never selects the anonymous runs as a branch of their own" do
        repository = create_repository
        3.times { |i| repository.test_runs.create!(commit_sha: "anon#{i}", branch: nil) }
        repository.test_runs.create!(commit_sha: "named", branch: "main")

        # Blank means "no filter": every row, anonymous ones included.
        expect(repository.recent_test_runs(branch: "").length).to eq(4)
        expect(repository.recent_test_runs(branch: nil).map(&:branch)).to include(nil)
        # And no argument reaches a NULL match: the named branch returns its own row alone.
        expect(repository.recent_test_runs(branch: "main").map(&:commit_sha)).to eq(%w[named])
      end
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

      # The SECOND count, and a genuinely different question from the first. `SuiteTrajectory`'s
      # runtime line plots `duration_seconds`, which is the MAX over the shards that REPORTED — so
      # its denominator is this number and never `shard_count`, and a run whose two slowest shards
      # were cancelled is not a faster build. `test_run_shards.duration_seconds` is nullable and
      # `Ingest::Payload` accepts nil explicitly, so the gap below is an ordinary live state.
      #
      # `COUNT(duration_seconds)` and not `COUNT(*)`: the whole point is that the two disagree on
      # exactly the rows this guard exists for, and a subquery that counted rows would prime `4`
      # here and leave the chart drawing the speed-up it draws today.
      it "primes how many of each run's shards reported a duration, which is not how many it has" do
        repository = create_repository
        full = run(repository, "fulltmd", at: 2.days.ago)
        partial = run(repository, "partial", at: 1.day.ago)
        4.times { |i| full.test_run_shards.create!(shard_id: i.to_s, total_specs_count: 10, duration_seconds: 60.0) }
        4.times do |i|
          partial.test_run_shards.create!(shard_id: i.to_s, total_specs_count: 10,
                                          duration_seconds: (i < 2 ? 30.0 : nil))
        end

        series = repository.suite_size_trajectory(repository.latest_test_run)

        # Same shard count on both — which is every question `assembled_like?` is able to ask.
        expect(count_queries { expect(series.map(&:shard_count)).to eq([4, 4]) }).to eq(0)
        # And a different timing denominator, which is the one it cannot.
        expect(count_queries { expect(series.map(&:timed_shard_count)).to eq([4, 2]) }).to eq(0)
      end

      # The unsharded corpus reaches the timing seam too, and its answer there is a really-counted
      # `0` rather than a nil — `TestRun#preload_timed_shard_count` documents the `.to_i` for
      # exactly this. `SuiteTrajectory`'s guard is `0 == 0` on those rows, so a nil leaking through
      # would turn a no-op into a comparison against nothing.
      it "primes a really-counted zero for a run that recorded no shards" do
        repository = create_repository
        run(repository, "plain0")

        series = repository.suite_size_trajectory(repository.latest_test_run)

        expect(count_queries { expect(series.map(&:timed_shard_count)).to eq([0]) }).to eq(0)
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
        # BOTH counts, and this is the assertion that pins "zero ADDED queries" for the timing
        # denominator specifically. `timed_shard_count` routes through the same per-instance `pick`
        # `shard_count` does, so a runtime guard that added the predicate without the second column
        # in the SELECT would leave the number above at 1 and turn this one into 10 — the N+1 that
        # ships green, since a fixture of one run cannot see it.
        expect(count_queries { series.each(&:timed_shard_count) }).to eq(0)
      end
    end
  end

  describe "#latest_test_run_on_branch" do
    def run(repository, commit, branch: "main", total: 100, at: 1.hour.ago)
      repository.test_runs.create!(commit_sha: commit, branch: branch, total_specs_count: total,
                                   created_at: at)
    end

    it "answers with the newest run on that branch, not the newest run in the repository" do
      repository = create_repository
      run(repository, "trunk0", at: 2.days.ago)
      run(repository, "trunk1", at: 1.day.ago)
      run(repository, "featur", branch: "feature/x", at: 1.minute.ago)

      expect(repository.latest_test_run_on_branch("main").commit_sha).to eq("trunk1")
      expect(repository.latest_test_run.commit_sha).to eq("featur")
    end

    # The same ordering key every other reader of this history sorts by, tie-break included — so
    # "the newest run on main" names the same row here as it does on the Overview.
    it "breaks a same-instant tie by id, the way the rest of this history is ordered" do
      repository = create_repository
      at = 1.hour.ago
      run(repository, "tied_a", at: at)
      run(repository, "tied_b", at: at)

      expect(repository.latest_test_run_on_branch("main").commit_sha).to eq("tied_b")
    end

    it "ignores another repository's branch of the same name" do
      repository = create_repository
      other = create_repository(user: create_user(github_uid: "2002", github_handle: "hubot"),
                                github_full_name: "acme/ledger")
      run(other, "notmin")

      expect(repository.latest_test_run_on_branch("main")).to be_nil
    end

    it "has no run for a branch it has never seen" do
      repository = create_repository
      run(repository, "trunk0")

      expect(repository.latest_test_run_on_branch("feature/deleted")).to be_nil
    end

    # A blank branch is not a branch, for the reason `previous_test_run_on_branch` states at length:
    # `WHERE branch IS NULL` would pool every anonymous run from every branch and every machine.
    # Answered without a query, so a caller that falls back pays nothing for the fallback.
    it "refuses a blank branch outright, and asks the database nothing" do
      repository = create_repository
      repository.test_runs.create!(commit_sha: "anon00", branch: nil, total_specs_count: 100)

      expect(count_queries { expect(repository.latest_test_run_on_branch(nil)).to be_nil }).to eq(0)
      expect(count_queries { expect(repository.latest_test_run_on_branch("")).to be_nil }).to eq(0)
    end
  end

  describe "#latest_test_run_for_commit" do
    def run(repository, commit, branch: "main", total: 100, at: 1.hour.ago)
      repository.test_runs.create!(commit_sha: commit, branch: branch, total_specs_count: total,
                                   created_at: at)
    end

    it "answers with the run on that sha, not the newest run in the repository" do
      repository = create_repository
      run(repository, "older0", at: 2.days.ago)
      run(repository, "middle", at: 1.day.ago)
      run(repository, "newest", at: 1.minute.ago)

      expect(repository.latest_test_run_for_commit("older0").commit_sha).to eq("older0")
      expect(repository.latest_test_run.commit_sha).to eq("newest")
    end

    # A sha is NOT unique in `test_runs` — the only unique index is
    # `(repository_id, ci_run_id) WHERE ci_run_id IS NOT NULL` — so a CI re-run of one commit is a
    # second row and "the run for this sha" has more than one answer. The NEWEST is the answer, on
    # the ordering every other reader of this history sorts by.
    it "answers with the newest of several runs on one sha" do
      repository = create_repository
      run(repository, "rerun0", at: 2.days.ago, total: 10)
      run(repository, "rerun0", at: 1.minute.ago, total: 20)

      expect(repository.latest_test_run_for_commit("rerun0").total_specs_count).to eq(20)
    end

    # The same tie-break the two siblings use, and the half a `created_at`-only ordering would leave
    # to the database's discretion: two runs of one sha ingested in the same instant are exactly what
    # a re-run under a parallel CI matrix produces.
    it "breaks a same-instant tie by id, the way the rest of this history is ordered" do
      repository = create_repository
      at = 1.hour.ago
      first = run(repository, "tied00", at: at, total: 10)
      second = run(repository, "tied00", at: at, total: 20)

      expect(second.id).to be > first.id
      expect(repository.latest_test_run_for_commit("tied00").total_specs_count).to eq(20)
    end

    it "ignores another repository's run on the same sha" do
      repository = create_repository
      other = create_repository(user: create_user(github_uid: "2003", github_handle: "octo"),
                                github_full_name: "acme/ledger")
      run(other, "shared")

      expect(repository.latest_test_run_for_commit("shared")).to be_nil
    end

    # An unrecognised sha is an ordinary thing for a reader to arrive with — a stale bookmark, a
    # pruned run, a commit whose CI never reported — and it is the caller's job to fall back, which
    # `Api::V1::RepositoriesController#latest_test_run` does while disclosing it on `run_anchor`.
    it "has no run for a sha it has never seen" do
      repository = create_repository
      run(repository, "trunk0")

      expect(repository.latest_test_run_for_commit("deadbe")).to be_nil
    end

    # A blank sha is not a sha. `commit_sha` is NOT NULL and `TestRun` validates its presence, so
    # `WHERE commit_sha = ''` is a guaranteed-empty read — answered without a query at all, so a
    # caller holding an empty `?commit_sha=` pays nothing for the fallback.
    it "refuses a blank sha outright, and asks the database nothing" do
      repository = create_repository
      run(repository, "trunk0")

      expect(count_queries { expect(repository.latest_test_run_for_commit(nil)).to be_nil }).to eq(0)
      expect(count_queries { expect(repository.latest_test_run_for_commit("")).to be_nil }).to eq(0)
    end
  end

  describe "#branch_histories" do
    def run(repository, commit, branch: "main", total: 100, at: 1.hour.ago)
      repository.test_runs.create!(commit_sha: commit, branch: branch, total_specs_count: total,
                                   created_at: at)
    end

    it "names every branch that has runs, with how many each has" do
      repository = create_repository
      run(repository, "trunk0", at: 3.days.ago)
      run(repository, "trunk1", at: 2.days.ago)
      run(repository, "featur", branch: "feature/x", at: 1.day.ago)

      expect(repository.branch_histories.map { |branch| [branch.name, branch.run_count] })
        .to eq([["main", 2], ["feature/x", 1]])
    end

    # Most history first, so a caller showing only the head of the list shows the branch a reader is
    # most likely looking for. Alphabetical would put `main` behind a dozen `feature/*` branches and
    # a truncated list would be a list with the trunk missing.
    it "orders by how much history each branch holds" do
      repository = create_repository
      run(repository, "sideaa", branch: "aaa-first-alphabetically", at: 1.minute.ago)
      3.times { |i| run(repository, "trunk#{i}", at: (5 - i).days.ago) }
      2.times { |i| run(repository, "relea#{i}", branch: "release", at: (3 - i).days.ago) }

      expect(repository.branch_histories.map(&:name)).to eq(%w[main release aaa-first-alphabetically])
    end

    # Ties go to the branch pushed to most recently — two idle branches with one run each are not
    # equally interesting, and the order has to be stable either way.
    it "breaks a tie on how recently the branch was pushed to" do
      repository = create_repository
      run(repository, "stale0", branch: "feature/stale", at: 10.days.ago)
      run(repository, "fresh0", branch: "feature/fresh", at: 1.minute.ago)

      expect(repository.branch_histories.map(&:name)).to eq(["feature/fresh", "feature/stale"])
    end

    # An anonymous run names no branch, so there is no branch here to offer. Pooling them under
    # `branch IS NULL` is the failure the panel's "No branch to plot a history on" state exists to
    # refuse — and a selector offering that pool would be a way to ask for it.
    it "offers nothing for the runs that named no branch" do
      repository = create_repository
      repository.test_runs.create!(commit_sha: "anon00", branch: nil, total_specs_count: 100)
      repository.test_runs.create!(commit_sha: "anon01", branch: nil, total_specs_count: 100)

      expect(repository.branch_histories).to eq([])
    end

    it "ignores another repository's branches" do
      repository = create_repository
      other = create_repository(user: create_user(github_uid: "2002", github_handle: "hubot"),
                                github_full_name: "acme/ledger")
      run(other, "notmin", branch: "not-mine")
      run(repository, "mine00")

      expect(repository.branch_histories.map(&:name)).to eq(["main"])
    end

    # The count STOPS at the trajectory window rather than reaching the end of the history: past
    # that point it answers no question this panel asks, and counting it is the O(history) scan the
    # whole method exists to avoid. `capped?` carries the fact that it stopped, so a caller words it
    # "30+" instead of publishing the figure the query happened to stop at.
    it "caps the count at the trajectory window and says that it did" do
      repository = create_repository
      (Repository::TRAJECTORY_LIMIT + 5).times { |i| run(repository, "sha#{i}", at: (60 - i).days.ago) }
      run(repository, "featur", branch: "feature/x", at: 1.minute.ago)

      histories = repository.branch_histories.index_by(&:name)

      expect(histories["main"].run_count).to eq(Repository::TRAJECTORY_LIMIT)
      expect(histories["main"]).to be_capped
      expect(histories["feature/x"].run_count).to eq(1)
      expect(histories["feature/x"]).not_to be_capped
    end

    # Exactly at the window is a count that finished, not one that stopped — the off-by-one that
    # would have every trunk on the platform wearing a "30+" it never earned.
    it "does not call a history that ends exactly at the window capped" do
      repository = create_repository
      Repository::TRAJECTORY_LIMIT.times { |i| run(repository, "sha#{i}", at: (60 - i).days.ago) }

      expect(repository.branch_histories.first.run_count).to eq(Repository::TRAJECTORY_LIMIT)
      expect(repository.branch_histories.first).not_to be_capped
    end

    it "honours a caller's own bounds" do
      repository = create_repository
      5.times { |i| run(repository, "trunk#{i}", at: (10 - i).days.ago) }
      run(repository, "featur", branch: "feature/x", at: 1.minute.ago)

      expect(repository.branch_histories(runs: 2).first.run_count).to eq(2)
      # WHICH branch survives the bound, not merely how many do. The walk is ALPHABETICAL, so the
      # survivor here is `feature/x` and not the trunk with five times its history — and a size-only
      # assertion cannot tell those apart, which is the whole difference the ordering is about.
      expect(repository.branch_histories(branches: 1).map(&:name)).to eq(["feature/x"])
    end

    # The reason the walk's bound sits two orders of magnitude above what any list displays. The
    # walk asks the index for the next branch BY NAME, so a bound near the display size hands the
    # history sort an alphabetical prefix — and on this shape, which is the one the whole feature
    # was written for, `main` sorts behind every `feature/*` and is not in it. The panel would then
    # offer eight unrelated one-run branches on the page whose entire reason for existing is that
    # `main` holds the history.
    it "reaches a branch that sorts alphabetically behind far more branches than a list would show" do
      repository = create_repository
      60.times { |i| run(repository, "side#{i}", branch: "feature/#{i.to_s.rjust(3, "0")}", at: (40 - i).days.ago) }
      5.times { |i| run(repository, "trunk#{i}", at: (10 - i).days.ago) }

      histories = repository.branch_histories

      expect(histories.size).to eq(61)
      expect(histories.first).to have_attributes(name: "main", run_count: 5)
    end

    # Past that bound the cut IS alphabetical, so the one branch a caller cannot afford to lose is
    # named rather than hoped for. The page pins the branch it is DRAWING: a selector rendered
    # without the option it is currently on has lost the reader it was rendered for.
    it "offers a pinned branch the walk stopped before reaching" do
      repository = create_repository
      3.times { |i| run(repository, "side#{i}", branch: "feature/#{i}", at: (9 - i).days.ago) }
      run(repository, "trunk0", at: 1.day.ago)

      expect(repository.branch_histories(branches: 2).map(&:name)).not_to include("main")
      expect(repository.branch_histories(branches: 2, pinned: ["main"]))
        .to include(have_attributes(name: "main", run_count: 1))
    end

    # A pin keeps a branch in the list; it is never a way to put one there. An unrecognised
    # `?branch=` reaches this as a pin, and a list of the branches that HAVE runs must not answer it
    # with one that has none — that would be a selectable choice leading to an empty chart.
    it "does not invent a pinned branch that has no runs" do
      repository = create_repository
      run(repository, "trunk0")

      expect(repository.branch_histories(pinned: ["feature/gone", nil]).map(&:name)).to eq(["main"])
    end

    it "does not offer a pinned branch the walk found anyway twice" do
      repository = create_repository
      run(repository, "trunk0", at: 2.days.ago)
      run(repository, "trunk1", at: 1.day.ago)

      expect(repository.branch_histories(pinned: %w[main main]).map { |b| [b.name, b.run_count] })
        .to eq([["main", 2]])
    end

    it "has nothing to offer a repository CI has never reported to" do
      expect(create_repository.branch_histories).to eq([])
    end

    # == The whole point of the query's shape
    #
    # One query, and one that walks the branch index rather than reading the history: a
    # `SELECT DISTINCT branch` visits every row of a 40,000-run repository, which is the same
    # O(history) scan `#suite_size_trajectory` documents for refusing one panel higher up. Counted
    # here rather than only through the page, for the reason the trajectory's own budget block
    # gives: a render-versus-render difference has a control walking the same code path.
    #
    # The cost is asserted as UNCHANGED across two axes that pull in different directions — more
    # runs per branch (which the capped count must not follow) and more branches (which the walk
    # must not turn into a query each).
    describe "what it costs to ask" do
      it "is one query, whatever the history behind it" do
        repository = create_repository
        3.times { |i| run(repository, "sha#{i}", at: (5 - i).days.ago) }

        expect(count_queries { repository.branch_histories }).to eq(1)

        60.times { |i| run(repository, "more#{i}", at: (100 - i).days.ago) }
        10.times { |i| run(repository, "side#{i}", branch: "feature/#{i}", at: 1.day.ago) }

        histories = nil
        expect(count_queries { histories = repository.branch_histories }).to eq(1)
        expect(histories.size).to eq(11)
        expect(histories.first.run_count).to eq(Repository::TRAJECTORY_LIMIT)

        # A pinned branch is a second arm of the SAME query, never a lookup of its own — the page
        # pins on every render, so a pin that cost a query would be a query added to every render.
        expect(count_queries { repository.branch_histories(pinned: ["main", "feature/3"]) }).to eq(1)
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
