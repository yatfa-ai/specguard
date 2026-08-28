# frozen_string_literal: true

require "rails_helper"

# Locks in the two queue decisions this slice made deliberately, so a later generator run or a
# copied-in default cannot quietly undo them.
RSpec.describe "Queue configuration" do
  describe "the test adapter" do
    # @intent: { entity: "ActiveJob test adapter", action: "configure adapter", behavior: "the suite-wide queue adapter is :test so enqueue assertions need no worker", layer: "unit" }
    it "is :test, so specs can assert enqueueing without a running worker" do
      expect(Rails.application.config.active_job.queue_adapter).to eq(:test)
      expect(ActiveJob::Base.queue_adapter).to be_a(ActiveJob::QueueAdapters::TestAdapter)
    end

    # @intent: { entity: "ActiveJob test adapter", action: "support matcher", behavior: "have_enqueued_job matches a perform_later job with its argument under the configured adapter", layer: "unit" }
    it "makes have_enqueued_job work — the matcher slice 2 needs for POST /api/v1/ingest" do
      stub_const("EnqueueProbeJob", Class.new(ApplicationJob) { def perform(_arg); end })

      expect { EnqueueProbeJob.perform_later("intent") }
        .to have_enqueued_job(EnqueueProbeJob).with("intent")
    end

    # @intent: { entity: "ActiveJob test adapter", action: "record not run", behavior: "perform_later records the job without executing it inline during a spec", layer: "unit" }
    it "records rather than runs, so no job executes inline during a spec" do
      ran = false
      stub_const("SideEffectProbeJob", Class.new(ApplicationJob) do
        define_method(:perform) { ran = true }
      end)

      SideEffectProbeJob.perform_later

      expect(ran).to be(false)
    end
  end

  describe "the database topology" do
    # @intent: { entity: "database topology", action: "place queue tables", behavior: "Solid Queue tables live in the primary database reachable on the base connection", layer: "unit" }
    it "puts Solid Queue's tables in the primary database" do
      # The chosen topology, asserted rather than described: a single database, no `queue:` entry,
      # no config.solid_queue.connects_to. If someone later adopts the multi-database layout, this
      # fails and they have to update config/database.yml in all three environments on purpose.
      expect(ActiveRecord::Base.connection.table_exists?("solid_queue_jobs")).to be(true)
      expect(ActiveRecord::Base.connection.table_exists?("solid_queue_ready_executions")).to be(true)
    end

    # @intent: { entity: "database topology", action: "keep single schema", behavior: "no queue_schema.rb exists and db/schema.rb itself declares the queue tables", layer: "unit" }
    it "keeps the queue schema out of a second schema file" do
      expect(Rails.root.join("db/queue_schema.rb")).not_to exist
      expect(Rails.root.join("db/schema.rb").read).to include("solid_queue_jobs")
    end

    # @intent: { entity: "database topology", action: "preserve vector schema", behavior: "the pgvector extension, halfvec column and its indexes survive untouched in db/schema.rb", layer: "unit" }
    it "leaves the pgvector schema intact — the queue install must not have disturbed it" do
      schema = Rails.root.join("db/schema.rb").read

      expect(schema).to include('enable_extension "vector"')
      expect(schema).to include('t.halfvec "embedding", limit: 1024')
      expect(schema).to include('name: "index_spec_intents_on_embedding", opclass: :halfvec_cosine_ops, using: :hnsw')
      expect(schema).to include('name: "index_spec_intents_on_location", unique: true')
    end
  end

  describe "the worker entrypoint" do
    # @intent: { entity: "worker entrypoint", action: "ship bin/jobs", behavior: "bin/jobs is executable and Procfile.dev starts it as the jobs process", layer: "unit" }
    it "ships an executable bin/jobs that bin/dev starts" do
      expect(Rails.root.join("bin/jobs")).to be_executable
      expect(Rails.root.join("Procfile.dev").read).to include("jobs: bin/jobs")
    end
  end
end
