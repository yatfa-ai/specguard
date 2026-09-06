# frozen_string_literal: true

require "rails_helper"

# `ApiKeyPartition` — the single-sourced live / revoked / stranded / presented-revoked split over a
# loaded set of `ApiKey` rows.
#
# The three surfaces it serves (repositories#show, the API's credential-health block and the
# repositories grid) pin their own ends at the request layer — the response bodies, the page
# budgets and the two chain/predicate divergence cases are held THERE, unmodified, because those
# specs assert OUTPUT. What lives here is what those paths cannot see: the partition's own
# semantics at the row grain (revocation outranking rotation, the predicate's two opposite nil
# limbs arriving in the right sets), the chain-equivalence of the grid's verdict, and the
# repo-wide property that the split is spelled at exactly one site — the guard that makes this
# seam a seam rather than a fourth copy with a class around it.
RSpec.describe ApiKeyPartition do
  let(:repository) { create_repository }

  def used_key(name, used_at:)
    key = repository.api_keys.create!(name: name)
    key.touch_last_used!
    key.update_columns(last_used_at: used_at)
    key
  end

  # The `strand_key` fixture the request specs use, at unit grain: used once by the old token,
  # then regenerated, with the stamps backdated so the ordering comparison is decided by data
  # rather than by test-execution timing.
  def stranded_key(name, used_at:, rotated_at:)
    key = repository.api_keys.create!(name: name)
    key.touch_last_used!
    key.regenerate!
    key.update_columns(last_used_at: used_at, rotated_at: rotated_at)
    key
  end

  def presented_revoked_key(name)
    key = repository.api_keys.create!(name: name)
    key.revoke!
    key.touch_last_refused!
    key
  end

  describe "the four-way split" do
    # @intent: { entity: "ApiKeyPartition", action: "split mixed population", behavior: "live, stranded, revoked and presented-revoked rows each land in their own side of one partition built from a single handed-in collection", layer: "unit" }
    it "puts each row on exactly one side and the stranded ones on the live side too" do
      live = used_key("Live", used_at: 1.hour.ago)
      stranded = stranded_key("Nightly", used_at: 6.days.ago, rotated_at: 5.days.ago)
      plain_revoked = repository.api_keys.create!(name: "Quiet").tap(&:revoke!)
      presented = presented_revoked_key("Loud")

      partition = described_class.for(repository.api_keys.to_a)

      expect(partition.live_rows).to contain_exactly(live, stranded)
      expect(partition.revoked_rows).to contain_exactly(plain_revoked, presented)
      expect(partition.stranded_rows).to contain_exactly(stranded)
      expect(partition.presented_revoked_rows).to contain_exactly(presented)
    end

    # The rule the credential-health spec pins at the response layer ("a rotated-then-revoked key
    # is revoked, not as stranded"), read at the grain that decides it: stranded_rows is selected
    # off the LIVE side, so the stronger fact wins by construction and not by a filter the caller
    # has to remember.
    # @intent: { entity: "ApiKeyPartition", action: "let revocation outrank rotation", behavior: "a key that was stranded and then revoked lands in revoked_rows and never in stranded_rows", layer: "unit" }
    it "keeps a rotated-then-revoked key off the stranded side" do
      key = stranded_key("CI", used_at: 6.days.ago, rotated_at: 5.days.ago)
      key.revoke!

      partition = described_class.for(repository.api_keys.to_a)

      expect(partition.revoked_rows).to contain_exactly(key)
      expect(partition.stranded_rows).to be_empty
    end

    # The predicate's purest state: `last_used_at` nil is rotated before it ever authenticated and
    # reads TRUE — the opposite of `rotated_at` nil — so the row is stranded even though nothing
    # about it can be dated from a use.
    # @intent: { entity: "ApiKeyPartition", action: "keep never-authenticated strand", behavior: "a key rotated before it ever authenticated sits in stranded_rows with rotated_at as its only stamp", layer: "unit" }
    it "strands a key rotated before it ever authenticated" do
      key = repository.api_keys.create!(name: "CI")
      key.regenerate!

      partition = described_class.for(repository.api_keys.to_a)

      expect(key.reload).to be_rotated_and_unused
      expect(partition.stranded_rows).to contain_exactly(key)
    end

    # @intent: { entity: "ApiKeyPartition", action: "require refusal stamp", behavior: "a revoked key carrying no last_refused_at stays out of presented_revoked_rows", layer: "unit" }
    it "keeps a revoked key with no observed presentation out of the presented-revoked side" do
      quiet = repository.api_keys.create!(name: "Quiet").tap(&:revoke!)

      partition = described_class.for(repository.api_keys.to_a)

      expect(partition.revoked_rows).to contain_exactly(quiet)
      expect(partition.presented_revoked_rows).to be_empty
    end
  end

  describe "the two timestamps" do
    # `show`'s rule, at the grain the request specs cannot isolate: a revoked row's `last_used_at`
    # is the history of a credential that no longer exists and must not answer the page's
    # "did anything authenticate" question even when it is the newest stamp in the set.
    # @intent: { entity: "ApiKeyPartition", action: "restrict last request to live", behavior: "last_api_request_at is the newest use across live rows, ignoring a revoked row's newer stamp", layer: "unit" }
    it "reads last_api_request_at off the live rows only" do
      live = used_key("Live", used_at: 1.hour.ago)
      key = used_key("Old", used_at: 5.minutes.ago)
      key.revoke!

      partition = described_class.for(repository.api_keys.to_a)

      # Against the reloaded stamp, not the in-memory one: the column is a PG timestamp, and a
      # raw `1.hour.ago` carries nanoseconds the store truncates.
      expect(partition.last_api_request_at).to eq(live.reload.last_used_at)
    end

    # The "Connected" figure's restriction: a stranded key's use belongs to a token that no longer
    # exists, so it dates nothing that is still connected — while last_api_request_at still sees
    # it, which is exactly the pair the indicator branches on.
    # @intent: { entity: "ApiKeyPartition", action: "restrict live figure to carrying keys", behavior: "last_live_api_request_at excludes the stranded rows' uses while last_api_request_at includes them", layer: "unit" }
    it "reads last_live_api_request_at off the rows whose use their token still describes" do
      live = used_key("Live", used_at: 1.hour.ago)
      stranded_key("Nightly", used_at: 6.days.ago, rotated_at: 5.days.ago)

      partition = described_class.for(repository.api_keys.to_a)

      expect(partition.last_api_request_at).to eq(live.reload.last_used_at)
      expect(partition.last_live_api_request_at).to eq(live.reload.last_used_at)
    end

    # @intent: { entity: "ApiKeyPartition", action: "blank live figure mid-window", behavior: "when every key that ever authenticated has been rotated away, last_live_api_request_at is nil while last_api_request_at is not", layer: "unit" }
    it "returns a nil last_live_api_request_at while a rotation is pending its replacement" do
      stranded_key("Nightly", used_at: 6.days.ago, rotated_at: 5.days.ago)

      partition = described_class.for(repository.api_keys.to_a)

      expect(partition.last_api_request_at).to be_present
      expect(partition.last_live_api_request_at).to be_nil
    end
  end

  describe "#stranded_rotation_time" do
    # The date the grid's sentence is held to: the OLDEST stranded rotation, on the rule that the
    # only date true of every stranded key at once is the oldest — the newest would date a
    # five-day-dead pipeline at one minute whenever a second key was rotated just now.
    # @intent: { entity: "ApiKeyPartition", action: "date verdict from oldest", behavior: "a repository whose every live key is stranded and whose last use predates every rotation returns the oldest stranded rotated_at", layer: "unit" }
    it "fires when every token that ever authenticated has been rotated away, dated from the oldest rotation" do
      nightly = stranded_key("Nightly", used_at: 6.days.ago, rotated_at: 5.days.ago)
      main = stranded_key("Main", used_at: 2.hours.ago, rotated_at: 1.hour.ago)

      partition = described_class.for(repository.api_keys.to_a)

      expect(partition.stranded_rotation_time).to eq(nightly.reload.rotated_at)
      expect(partition.stranded_rotation_time).to be < main.reload.rotated_at
    end

    # Divergence case pinned at repositories_spec's "live key beside a stranded one": the card and
    # `show` must agree that CI is CONNECTED, so the verdict stays nil however stranded the
    # neighbour is.
    # @intent: { entity: "ApiKeyPartition", action: "stay nil beside live key", behavior: "one live authenticated key beside a stranded one returns a nil stranded_rotation_time", layer: "unit" }
    it "does not fire while a live key keeps the repository connected beside a stranded one" do
      used_key("Live", used_at: 1.hour.ago)
      stranded_key("Old", used_at: 6.days.ago, rotated_at: 5.days.ago)

      partition = described_class.for(repository.api_keys.to_a)

      expect(partition.stranded_rotation_time).to be_nil
    end

    # Divergence case pinned at repositories_spec's "rotated before it ever authenticated": the row
    # is everything the per-key predicate asks for, and the verdict still stays nil — no token was
    # ever routed through it, so no replacement is hanging.
    # @intent: { entity: "ApiKeyPartition", action: "stay nil before first use", behavior: "a sole key rotated before it ever authenticated leaves stranded_rotation_time nil despite sitting in stranded_rows", layer: "unit" }
    it "does not fire for a key rotated before it ever authenticated, though the row is stranded" do
      key = repository.api_keys.create!(name: "CI")
      key.regenerate!

      partition = described_class.for(repository.api_keys.to_a)

      expect(partition.stranded_rows).to contain_exactly(key.reload)
      expect(partition.stranded_rotation_time).to be_nil
    end

    # @intent: { entity: "ApiKeyPartition", action: "stay nil without strand", behavior: "a repository with a live used key and no stranded key returns nil, and an empty partition answers nil everywhere", layer: "unit" }
    it "answers nil with nothing stranded and nil on an empty collection" do
      used_key("Live", used_at: 1.hour.ago)

      expect(described_class.for(repository.api_keys.to_a).stranded_rotation_time).to be_nil
      expect(described_class.for([]).stranded_rotation_time).to be_nil
    end
  end

  describe ".grouped_by_repository" do
    # The grid's shape: one loaded row set spanning N repositories comes back as one partition per
    # repository, each answering only about its own slice.
    # @intent: { entity: "ApiKeyPartition", action: "group page rows", behavior: "rows from two repositories produce two partitions keyed by repository_id, each holding only its own repository's rows", layer: "unit" }
    it "hands back one partition per repository over a single loaded row set" do
      other = create_repository(user: create_user(github_uid: "2002", github_handle: "colleague"),
                                github_full_name: "acme/other-service")
      here = used_key("Live", used_at: 1.hour.ago)
      there = other.api_keys.create!(name: "Theirs").tap do |key|
        key.revoke!
        key.touch_last_refused!
      end

      partitions = described_class.grouped_by_repository(repository.api_keys.to_a + other.api_keys.to_a)

      expect(partitions.keys).to contain_exactly(repository.id, other.id)
      expect(partitions[repository.id].live_rows).to eq([here])
      expect(partitions[other.id].presented_revoked_rows).to eq([there])
    end

    # A repository with no keys gets no entry — which is what both grid readers want: the count
    # defaults to 0 through its own `.to_i`, and a missing rotation time renders no marker.
    # @intent: { entity: "ApiKeyPartition", action: "omit keyless repositories", behavior: "grouped_by_repository has no entry for a repository with no handed-in rows, and an empty row set groups to an empty hash", layer: "unit" }
    it "gives a repository with no rows no entry at all" do
      expect(described_class.grouped_by_repository([])).to eq({})
      expect(described_class.grouped_by_repository(repository.api_keys.to_a)).to eq({})
    end
  end

  describe ".for" do
    # The contract that lets the grid hand in its live-only load and the other two surfaces hand in
    # everything: the split is over the collection GIVEN, never over the table.
    # @intent: { entity: "ApiKeyPartition", action: "split over handed rows", behavior: "a live-only collection partitions to live_rows as the whole of it with empty revoked sides, and an empty collection answers nil timestamps", layer: "unit" }
    it "splits over the collection it is handed and answers an empty collection honestly" do
      key = used_key("Live", used_at: 1.hour.ago)

      live_only = described_class.for([key])

      expect(live_only.live_rows).to eq([key])
      expect(live_only.revoked_rows).to be_empty
      expect(live_only.presented_revoked_rows).to be_empty
      expect(live_only.last_api_request_at).to eq(key.last_used_at)
      expect(live_only.last_live_api_request_at).to eq(key.last_used_at)

      empty = described_class.for([])
      expect(empty.last_api_request_at).to be_nil
      expect(empty.last_live_api_request_at).to be_nil
    end
  end

  # The invariant the whole ticket exists for, held AFTER the refactor rather than assumed: the
  # partition is spelled here and in `ApiKey` itself, and NOWHERE else. A fifth copy appearing at
  # any future call site is exactly the drift this seam exists to prevent, and it is invisible in
  # behaviour — every copy that agrees today keeps every page green — so it is asserted as a
  # property of the SOURCE.
  #
  # Comment lines are stripped before matching, on the precedent's own rule (the grant's one-capture-site
  # guard in spec/requests/repositories_spec.rb): the criterion is about call sites, and prose that
  # names an expression to explain why it must not be written again would fail a raw grep while
  # adding no copy at all. `ApiKey` itself is allowed because the predicates and scopes are the
  # rules this seam is BUILT from, not a re-derivation of them.
  describe "the single-source property" do
    expressions = [
      "reject(&:revoked?)",
      "select(&:revoked?)",
      "select(&:rotated_and_unused?)",
      "select(&:revoked_and_still_presented?)"
    ].freeze
    allowed = %w[app/models/api_key_partition.rb app/models/api_key.rb].freeze

    # @intent: { entity: "ApiKeyPartition", action: "keep one partition spelling", behavior: "scanning app and lib for the four partition expressions finds no call site outside the seam and ApiKey itself", layer: "unit" }
    it "leaves the partition spelled at no site beyond the seam and ApiKey" do
      offenders = Dir.glob(Rails.root.join("{app,lib}/**/*.rb")).filter_map do |path|
        relative = Pathname.new(path).relative_path_from(Rails.root).to_s
        next if allowed.include?(relative)

        lines = File.readlines(path).each_with_index.filter_map do |line, index|
          next if line.strip.start_with?("#")
          next unless expressions.any? { |expression| line.include?(expression) }

          "#{relative}:#{index + 1}"
        end

        lines.join(", ") if lines.any?
      end

      expect(offenders).to be_empty
    end
  end
end
