# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ingest::IdentityResolutionJob do
  include_context "with lexical embeddings"

  let(:repository) { create_repository }

  def record(specs)
    payload = Ingest::Payload.new(ingest_payload(specs: specs).deep_stringify_keys)
    Ingest::RunRecorder.record(repository, payload.test_run_attributes, specs: payload.specs)
  end

  it "resolves the run it was given" do
    run = record([unannotated_spec(name: "Cart adds an item to the cart")])

    described_class.perform_now(run.id)

    expect(run.spec_observations.sole.reload.spec_identity_id).to eq(repository.spec_identities.sole.id)
  end

  # Between the enqueue and the dequeue the repository may have been deleted, which takes its runs
  # with it. There is nothing to resolve and nothing to report, so this is not an error — and it is
  # asserted rather than left to a `retry_on` policy this slice deliberately does not set.
  it "is a no-op for a run that no longer exists" do
    run = record([unannotated_spec])
    id = run.id
    repository.destroy!

    expect { described_class.perform_now(id) }.not_to raise_error
  end

  it "hands the work to the resolver rather than reimplementing any of it" do
    run = record([unannotated_spec])
    allow(Ingest::IdentityResolver).to receive(:resolve)

    described_class.perform_now(run.id)

    expect(Ingest::IdentityResolver).to have_received(:resolve).with(run)
  end

  # The completion report is `Ingest::IdentityResolver`'s to word and its own spec is where the four
  # figures are pinned. What belongs HERE is the unit the report is per: one job, one line. Every
  # shard of a run enqueues a job for the run, so "per job" is the only reading of "one summary" a
  # reader can act on, and it is the job that has to demonstrate it.
  describe "the completion report" do
    def summaries
      lines = []
      allow(Rails.logger).to receive(:info) { |message| lines << message }
      yield
      lines.grep(/\[IdentityResolver\]/)
    end

    it "emits exactly one summary for the job, not one per row" do
      run = record([unannotated_spec(file_path: "spec/a_spec.rb", line_number: 1,
                                     name: "Cart adds an item to the cart"),
                    unannotated_spec(file_path: "spec/b_spec.rb", line_number: 2,
                                     name: "Invoice#finalize locks the line items"),
                    unannotated_spec(file_path: "spec/c_spec.rb", line_number: 3,
                                     name: "Order#checkout rejects an expired card")])

      lines = summaries { described_class.perform_now(run.id) }

      expect(lines.sole).to include("run=#{run.id}", "resolved=3")
    end

    # The job's own rule, kept: between the enqueue and the dequeue the repository may have been
    # deleted, and a run that no longer exists is *"nothing to resolve and nothing to report"*. The
    # second half of that sentence had no mechanism to be true or false of until now.
    it "reports nothing for a run that no longer exists" do
      run = record([unannotated_spec])
      id = run.id
      repository.destroy!

      expect(summaries { described_class.perform_now(id) }).to be_empty
    end
  end
end
