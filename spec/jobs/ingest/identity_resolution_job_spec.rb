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
end
