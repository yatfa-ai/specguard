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
# ordering of buckets, and the honest nils of the two constructors that make no claim about a
# window.
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
    # @intent: { entity: "RejectedIngests", action: "order buckets", behavior: "buckets are ordered largest first with ties alphabetical and the unreported bucket last among equal counts", layer: "unit" }
    it "orders buckets largest first, ties alphabetical, with the unreported bucket last" do
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
    # The pass-through the panel depends on, and the shape of a caller that handed nothing in:
    # `nil`, not an empty summary that would read as "zero refusals" — a fact the object was never
    # given.
    # @intent: { entity: "RejectedIngests", action: "carry handed-in window", behavior: "for returns the window it was handed and answers nil for one when it was handed none", layer: "unit" }
    it "answers the window it was handed, and nil when handed none" do
      window = RejectedIngests::RetainedWindow.for(repository)

      handed = RejectedIngests.for(repository, last_accepted_run_at: nil, retained_window: window)
      bare = RejectedIngests.for(repository, last_accepted_run_at: nil)

      expect(handed.retained_window).to equal(window)
      expect(bare.retained_window).to be_nil
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
