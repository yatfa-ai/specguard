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

  # One POST is one shard, so an N-shard delivery enqueues N jobs over one run's rows and each
  # uncapped run-scoped resolve costs an embed + lookup + upsert per row the others have not yet
  # claimed. `limits_concurrency` collapses that to one job at a time per run.
  #
  # `config/environments/test.rb` pins this suite to ActiveJob's `:test` adapter — deliberately not
  # `:solid_queue` — so NO example here can exercise the blocking at runtime, and none should try to
  # manufacture one by swapping the adapter in. What is assertable is the configuration the Solid
  # Queue dispatcher reads, and it is enough: it catches every way this can be got wrong.
  describe "serializing one run's jobs" do
    let(:run) { record([unannotated_spec]) }

    it "admits one job at a time" do
      expect(described_class.concurrency_limit).to eq(1)
    end

    it "keys the limit on the run, so two jobs for the same run share a key" do
      expect(described_class.new(run.id).concurrency_key).to eq(described_class.new(run.id).concurrency_key)
    end

    # The other direction, and the one that matters: a constant key would satisfy the assertion above
    # while serializing identity resolution across every run in the deployment — every repository's
    # ingest queued behind every other's, a multi-tenant stall dressed as an optimisation.
    it "keys the limit on the run, so jobs for different runs do not share a key" do
      other = record([unannotated_spec(file_path: "spec/other_spec.rb", line_number: 9)])

      expect(described_class.new(run.id).concurrency_key).not_to eq(described_class.new(other.id).concurrency_key)
    end

    # `duration` is how long the dispatcher waits before assuming a semaphore holder died and
    # releasing a blocked job anyway. SolidQueue's 3-minute default is shorter than a design-point
    # resolve, so leaving it there would expire the semaphore mid-run and silently restore the
    # overlap — this slice voided with nothing turning red.
    it "holds the semaphore for longer than a resolve can take, not SolidQueue's 3-minute default" do
      expect(described_class.concurrency_duration).to be > SolidQueue.default_concurrency_control_period
      expect(described_class.concurrency_duration).to be >= 1.hour
    end

    # The one change here that can LOSE work. `:discard` would drop a shard's job outright, stranding
    # every row that shard delivered until some later ingest's cross-run sweep found them. The gem
    # sanitises this attribute (an unrecognised value silently becomes `:block`), so a genuine
    # `:discard` edit is caught by nothing else in the suite.
    it "blocks the jobs it holds back rather than discarding them" do
      expect(described_class.concurrency_on_conflict).to eq(:block)
    end
  end
end
