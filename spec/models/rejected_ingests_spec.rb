# frozen_string_literal: true

require "rails_helper"

# `RejectedIngests`' retained-window summary — the part of the object whose rules the request
# specs cannot reach, because the fixtures they can build go through the recorder and the recorder
# folds blank away before anything is stored.
#
# The request side (spec/requests/repository_rejected_ingests_spec.rb) proves the panel RENDERS
# the window off real refusals; what lives here is what that path cannot produce: a stored `""`
# (the column is nullable and unconstrained, so a legacy or hand-written row can carry one, and
# the summary may not split what `IngestRejection#reported_client` folds), the deterministic
# ordering of buckets, and the LAZY LOAD of the window itself — the reader is what keeps the
# page's absolute query budget flat on a zero-refusal repository, and only counting queries
# around a bare constructor here can pin that.
RSpec.describe RejectedIngests do
  let(:repository) { create_repository }

  def retain(user_agent:)
    repository.ingest_rejections.create!(
      occurred_at: Time.current, details: ["nope"], total_reasons_count: 1, user_agent: user_agent
    )
  end

  describe "RetainedWindow" do
    # The fold the SQL GROUP BY cannot be trusted with: `reported_client` is `user_agent.presence`,
    # so NULL and "" are one bucket at the row grain, and a summary that split them would describe
    # a different population than the rows it sits above.
    # @intent: { entity: "RejectedIngests", action: "fold blank clients", behavior: "a stored NULL and a stored empty string land in one Not reported bucket whose count is their sum", layer: "unit" }
    it "folds a stored blank and a stored NULL into one bucket" do
      retain(user_agent: nil)
      retain(user_agent: "")
      retain(user_agent: "specguard-rspec/0.3.1")

      entries = RejectedIngests::RetainedWindow.for(repository).entries

      expect(entries).to contain_exactly(
        ["specguard-rspec/0.3.1", 1],
        [nil, 2]
      )
    end

    # Reading order is importance order, and ties are alphabetical so the render is deterministic
    # rather than index-order — a summary whose bucket order changed between renders would be a
    # second thing on this page free to disagree with itself.
    # @intent: { entity: "RejectedIngests", action: "order buckets", behavior: "buckets are ordered largest first with ties alphabetical among reported clients", layer: "unit" }
    it "orders buckets largest first, ties alphabetical among reported clients" do
      2.times { retain(user_agent: "specguard-rspec/0.3.1") }
      2.times { retain(user_agent: "specguard-rspec/0.2.9") }
      retain(user_agent: "specguard-rspec/0.1.0")

      entries = RejectedIngests::RetainedWindow.for(repository).entries

      expect(entries).to eq([
        ["specguard-rspec/0.2.9", 2],
        ["specguard-rspec/0.3.1", 2],
        ["specguard-rspec/0.1.0", 1]
      ])
    end

    # The tie the sort's own comment predicts: `nil.to_s` is "", which sorts BEFORE every reported
    # client string, so on equal counts the unreported bucket LEADS its tie group. Pinned because
    # an earlier title of the example above claimed the opposite ("unreported bucket last") and
    # passed — it contained no tie involving nil, so nothing was there to catch it.
    # @intent: { entity: "RejectedIngests", action: "order nil tie", behavior: "on equal counts the unreported bucket sorts before the reported client it ties with", layer: "unit" }
    it "leads a tie with the unreported bucket, whose nil label sorts by its empty string" do
      2.times { retain(user_agent: "specguard-rspec/0.3.1") }
      2.times { retain(user_agent: nil) }
      retain(user_agent: "specguard-rspec/0.1.0")

      entries = RejectedIngests::RetainedWindow.for(repository).entries

      expect(entries).to eq([
        [nil, 2],
        ["specguard-rspec/0.3.1", 2],
        ["specguard-rspec/0.1.0", 1]
      ])
    end

    # The population is the SUM of the buckets, never a second aggregate — the one-query property
    # the panel's cost guard depends on, and the reason the buckets summing to the total cannot rot.
    # @intent: { entity: "RejectedIngests", action: "sum window", behavior: "the total equals the sum of bucket counts across mixed and unreported clients", layer: "unit" }
    it "totals the window as the sum of its buckets" do
      3.times { retain(user_agent: "specguard-rspec/0.3.1") }
      retain(user_agent: nil)

      window = RejectedIngests::RetainedWindow.for(repository)

      expect(window.total).to eq(4)
      expect(window.entries.sum { |_client, count| count }).to eq(window.total)
    end

    # @intent: { entity: "RejectedIngests", action: "read empty window", behavior: "a repository with no refusals yields a zero total and no buckets", layer: "unit" }
    it "reads an empty window as zero buckets and a zero total" do
      window = RejectedIngests::RetainedWindow.for(repository)

      expect(window.entries).to eq([])
      expect(window.total).to eq(0)
    end
  end

  describe ".for" do
    # The laziness the page's absolute budget rests on: the peek in `.for` has already established
    # whether there is anything to summarize, so an object whose peek came back empty answers an
    # EMPTY summary — a true fact ("nothing peeked" proves the whole retained window is empty,
    # because the retention rule keeps fifty) — WITHOUT issuing the grouped read. Not a nil, which
    # would read as "no claim": this object CAN claim, and what it claims is zero.
    # @intent: { entity: "RejectedIngests", action: "summarize empty window free", behavior: "a for-built object over a repository with no refusals answers a zero-bucket window without querying ingest_rejections", layer: "unit" }
    it "answers an empty window without a query when the peek found nothing" do
      object = RejectedIngests.for(repository, last_accepted_run_at: nil)

      window = nil
      queries = queries_against("ingest_rejections") { window = object.retained_window }

      expect(queries).to be_empty
      expect(window.entries).to eq([])
      expect(window.total).to eq(0)
    end

    # And the paying side: exactly ONE grouped read when there is something to state, memoized —
    # a second reader of the same object is free.
    # @intent: { entity: "RejectedIngests", action: "load window once", behavior: "a for-built object over refusing rows reads ingest_rejections exactly once for the window and memoizes the summary", layer: "unit" }
    it "loads the window in one query when there is something to summarize, and memoizes it" do
      retain(user_agent: "specguard-rspec/0.3.1")
      object = RejectedIngests.for(repository, last_accepted_run_at: nil)

      window = nil
      queries = queries_against("ingest_rejections") { window = object.retained_window }
      second = object.retained_window

      expect(queries.size).to eq(1)
      expect(second).to equal(window)
      expect(window.total).to eq(1)
    end
  end

  describe ".verdict" do
    # The grid's constructor makes no claim about the window — one grouped read per card is the
    # N+1 the second constructor exists to avoid — and `nil` is the honest answer, same rule as
    # its empty `rows` and false `bounded?`.
    # @intent: { entity: "RejectedIngests", action: "leave grid windowless", behavior: "a verdict-built object answers nil for the retained window", layer: "unit" }
    it "answers nil for the retained window, which the grid never asks for" do
      verdict = RejectedIngests.verdict(last_rejection_at: Time.current, last_accepted_run_at: nil)

      expect(verdict.retained_window).to be_nil
    end
  end
end
