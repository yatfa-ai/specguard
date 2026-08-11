# frozen_string_literal: true

require "rails_helper"
require "spec_guard/migration_index_lint"
require "tmpdir"

# The guard for the convention `AddBranchHistoryIndexToTestRuns` stated and nothing enforced —
# `algorithm: :concurrently` on an index built against a table ingestion writes to on every run.
#
# Its reasoning lives in `lib/spec_guard/migration_index_lint.rb`; this file is where it runs. It
# sits in `spec/migrations/` rather than beside the other lints in `spec/lib/spec_guard/` because
# this is where someone editing `db/migrate/` will look for it.
#
# == Why a spec rather than the `strong_migrations` gem
#
# `strong_migrations` checks at **migrate time**, and nothing in this repository's gate runs a
# migration in the configuration that matters. `bin/ci` runs `bin/setup`, whose `db:prepare` loads
# `db/schema.rb` on a fresh database and never executes a migration's Ruby at all; and
# `maintain_test_schema!` in `spec/rails_helper.rb` does the same for the suite. So a gem-based
# check would fire only for a developer who happens to hold a pre-existing database — the author,
# once — and would be silent for every reviewer and every container. This repository has no
# test-running CI workflow (`.github/workflows/` holds only the manual release job), which makes
# `bundle exec rspec` the whole of the automated gate. The defect this exists for got through **two
# code reviews**, so reaching the reviewer is the requirement, not a nicety.
#
# == The falsifier examples below are the point
#
# A guard run only against a clean tree has never been shown to be *able* to fail. `the rules`
# feeds the lint sources that do not exist on disk, one per way an index can reach a table, so
# every branch of the detector is witnessed going red — and the ones that should stay green
# (a concurrent build, a brand-new table, an untracked table) are witnessed staying green.
RSpec.describe SpecGuard::MigrationIndexLint do
  # `db/schema.rb`'s own `version:` — the last merged migration. Read from the file rather than
  # retyped, so the claim "the grandfather list is merged history" cannot drift away from the
  # schema it is asserted against. A `let` rather than a constant: a constant assigned inside this
  # block would land on `Object` and be visible to every other spec in the suite.
  let(:schema_version) do
    Rails.root.join("db/schema.rb").read[/define\(version:\s*([\d_]+)\)/, 1].delete("_").to_i
  end

  describe "the live db/migrate tree" do
    subject(:lint) { described_class.new(root: Rails.root) }

    # Upstream of the guard: a glob that matched nothing would report "clean" just as loudly.
    it "actually reads every migration in db/migrate" do
      on_disk = Rails.root.glob("db/migrate/*.rb").map { |path| path.basename.to_s }

      expect(on_disk).not_to be_empty
      expect(lint.migration_files.map { |path| path.basename.to_s }).to match_array(on_disk)
    end

    it "builds no index on a hot table without `algorithm: :concurrently`" do
      expect(lint.offenses).to be_empty, -> { lint.report }
      expect(lint).to be_clean
    end

    it "names the tables the rule is about, with the reason each one earns it" do
      expect(described_class::GUARDED_TABLES.keys).to contain_exactly("spec_observations", "test_runs")
      expect(described_class::GUARDED_TABLES.values).to all(be_present)
    end
  end

  # The allowlist is the whole of AC-2: merged history is not re-litigated, and the exemption is
  # named rather than spelled as an opaque version floor.
  describe "the grandfathered migrations" do
    subject(:grandfathered) { described_class::GRANDFATHERED }

    it "names only files that are still on disk" do
      grandfathered.each_key do |basename|
        expect(Rails.root.join("db/migrate", basename)).to exist
      end
    end

    # The pin is on the ALLOWLIST's ceiling, not on `db/schema.rb`'s `version:`. Pinning the schema
    # version would have made this example fail on the next legitimate migration anyone writes —
    # a guard that goes red for the change it is supposed to permit. What is actually frozen here
    # is that the exemption stops at 20260811150000, the last merged migration at the time the
    # guard landed and `db/schema.rb`'s version then: everything at or below it is history the
    # guard deliberately does not re-litigate, and nothing above it is exempt from anything.
    it "stops at the last migration merged before the guard, and never reaches past it" do
      expect(grandfathered.keys.map { |basename| basename[/\A\d+/].to_i }.max)
        .to eq(20_260_811_150_000)
      expect(grandfathered.keys.map { |basename| basename[/\A\d+/].to_i }.max)
        .to be <= schema_version
    end

    # Load-bearing in both directions. A dead entry (the migration was rewritten to build
    # concurrently) is an exemption still standing over nothing, and this is what makes removing it
    # compulsory rather than optional.
    it "names only files that would otherwise fail, and each with a stated reason" do
      grandfathered.each do |basename, reason|
        source = Rails.root.join("db/migrate", basename).read
        offenses = described_class.scan(source, path: basename)

        expect(offenses).not_to be_empty,
                                "#{basename} no longer fails the lint — drop it from GRANDFATHERED"
        expect(reason).to be_present
      end
    end

    it "exempts nothing that is not merged history" do
      merged = Rails.root.glob("db/migrate/*.rb").map { |path| path.basename.to_s }

      expect(grandfathered.keys - merged).to be_empty
    end
  end

  describe "the rules" do
    def offenses_for(source) = described_class.scan(source, path: "db/migrate/20260812000000_probe.rb")

    def migration(body, disable_ddl: false)
      <<~RUBY
        class Probe < ActiveRecord::Migration[8.1]
          #{"disable_ddl_transaction!" if disable_ddl}
          def change
        #{body.gsub(/^/, "    ")}
          end
        end
      RUBY
    end

    describe "add_index" do
      it "flags a plain build on a guarded table" do
        offenses = offenses_for(migration("add_index :spec_observations, %i[repository_id name]"))

        expect(offenses.map(&:kind)).to eq([:non_concurrent])
        expect(offenses.first.detail).to include("spec_observations", "blocks every writer")
        expect(offenses.first.fix).to include("algorithm: :concurrently", "disable_ddl_transaction!")
      end

      it "accepts a concurrent build that also disables the DDL transaction" do
        source = migration(
          "add_index :spec_observations, %i[repository_id name], algorithm: :concurrently",
          disable_ddl: true
        )

        expect(offenses_for(source)).to be_empty
      end

      it "reads a multi-line call, where the option sits three lines below the table" do
        source = migration(<<~RUBY, disable_ddl: true)
          add_index :spec_observations, %i[repository_id created_at id],
                    where: "spec_identity_id IS NULL",
                    name: "index_spec_observations_on_probe",
                    algorithm: :concurrently
        RUBY

        expect(offenses_for(source)).to be_empty
      end

      it "reads a table named with a string as well as a symbol" do
        expect(offenses_for(migration(%(add_index "test_runs", :branch))).map(&:kind))
          .to eq([:non_concurrent])
      end

      it "ignores a table the rule is not about" do
        expect(offenses_for(migration("add_index :users, :github_handle"))).to be_empty
      end
    end

    # The way an index reached `spec_observations` in `CreateSpecIdentities` without the word
    # "index" appearing in the migration at all: `add_reference` indexes by default.
    describe "add_reference" do
      it "flags the index Rails adds by default" do
        offenses = offenses_for(migration("add_reference :spec_observations, :spec_identity, null: true"))

        expect(offenses.map(&:kind)).to eq([:non_concurrent])
        expect(offenses.first.detail).to include("add_reference :spec_observations")
      end

      it "accepts one that asks for no index" do
        expect(offenses_for(migration("add_reference :spec_observations, :probe, index: false")))
          .to be_empty
      end

      it "accepts one that asks for a concurrent index" do
        source = migration(
          "add_reference :spec_observations, :probe, index: { algorithm: :concurrently }",
          disable_ddl: true
        )

        expect(offenses_for(source)).to be_empty
      end
    end

    describe "change_table" do
      it "flags a `t.index` on a guarded table, where the table name is on the block's line" do
        source = migration(<<~RUBY)
          change_table :spec_observations do |t|
            t.index %i[repository_id outcome]
          end
        RUBY

        offenses = offenses_for(source)

        expect(offenses.map(&:kind)).to eq([:non_concurrent])
        expect(offenses.first.detail).to include("spec_observations")
      end

      it "flags a `t.references` on a guarded table" do
        source = migration(<<~RUBY)
          change_table :spec_observations do |t|
            t.references :probe
          end
        RUBY

        expect(offenses_for(source).map(&:kind)).to eq([:non_concurrent])
      end
    end

    # `CreateSpecIntents` and `CreateSpecIdentities` both build their vector indexes this way,
    # because `add_index` cannot express an `ivfflat`/`hnsw` operator class. It is the form a
    # future vector index on `spec_observations` would arrive in.
    describe "raw SQL" do
      it "flags a CREATE INDEX in an executed heredoc" do
        source = migration(<<~'RUBY')
          execute <<~SQL
            CREATE INDEX index_spec_observations_on_embedding
            ON spec_observations USING hnsw (embedding vector_cosine_ops)
          SQL
        RUBY

        expect(offenses_for(source).map(&:kind)).to eq([:non_concurrent])
      end

      it "accepts CREATE INDEX CONCURRENTLY" do
        source = migration(<<~'RUBY', disable_ddl: true)
          execute <<~SQL
            CREATE INDEX CONCURRENTLY index_spec_observations_on_embedding
            ON spec_observations USING hnsw (embedding vector_cosine_ops)
          SQL
        RUBY

        expect(offenses_for(source)).to be_empty
      end

      it "ignores an execute that is not building an index" do
        expect(offenses_for(migration(%(execute "ANALYZE spec_observations")))).to be_empty
      end
    end

    # A table that did not exist when the migration started has no writers to block, so requiring a
    # concurrent build there would be pure cost. `CreateSpecObservations` builds five indexes on
    # `spec_observations` under this exemption.
    describe "the same-migration create_table exemption" do
      it "accepts an index on a table this migration creates" do
        source = migration(<<~RUBY)
          create_table :spec_observations do |t|
            t.string :name
          end

          add_index :spec_observations, :name
        RUBY

        expect(offenses_for(source)).to be_empty
      end

      it "applies even when create_table appears after the index" do
        source = migration(<<~RUBY)
          add_index :spec_observations, :name

          create_table :spec_observations do |t|
            t.string :name
          end
        RUBY

        expect(offenses_for(source)).to be_empty
      end

      # `create_join_table :spec_observations, :tags` creates `spec_observations_tags`, not
      # `spec_observations`. Reading the first argument as the created table would have exempted
      # every real index on the hot table in the same migration.
      it "does not treat a create_join_table argument as a table that was created" do
        source = migration(<<~RUBY)
          create_join_table :spec_observations, :tags

          add_index :spec_observations, :name
        RUBY

        expect(offenses_for(source).map(&:kind)).to eq([:non_concurrent])
      end

      it "still exempts the join table itself" do
        source = migration(<<~RUBY)
          create_join_table :spec_observations, :tags

          add_index :spec_observations_tags, :tag_id
        RUBY

        expect(offenses_for(source)).to be_empty
      end
    end

    # Not a lock-duration judgement call: Postgres refuses CREATE INDEX CONCURRENTLY inside a
    # transaction block, so this migration raises rather than running slowly. Checked on every
    # table, hot or not.
    describe "the disable_ddl_transaction! pairing" do
      it "flags a concurrent build in a migration that does not disable the DDL transaction" do
        source = migration("add_index :spec_observations, :name, algorithm: :concurrently")

        expect(offenses_for(source).map(&:kind)).to include(:missing_disable_ddl_transaction)
      end

      it "flags it on an unguarded table too" do
        source = migration("add_index :users, :github_handle, algorithm: :concurrently")

        expect(offenses_for(source).map(&:kind)).to eq([:missing_disable_ddl_transaction])
      end
    end

    # "Could not check" is a distinct answer from "checked and clean", and only one of them is
    # allowed to be green.
    describe "when it cannot read the source" do
      it "reports a table name it cannot resolve rather than passing it" do
        source = migration(<<~RUBY)
          hot_tables.each { |table| add_index table, :repository_id }
        RUBY

        offenses = offenses_for(source)

        expect(offenses.map(&:kind)).to eq([:unresolved])
        expect(offenses.first.fix).to include("literal symbol or string")
      end

      it "reports a migration it cannot parse rather than passing it" do
        offenses = offenses_for("class Probe < ActiveRecord::Migration[8.1]\n  def change\n")

        expect(offenses.map(&:kind)).to eq([:unparsable])
      end
    end
  end

  describe "#report" do
    def report_for(source, basename)
      Dir.mktmpdir do |dir|
        migrations = File.join(dir, "db/migrate")
        FileUtils.mkdir_p(migrations)
        File.write(File.join(migrations, basename), source)

        described_class.new(root: dir).report
      end
    end

    # Deliberately not run against the live tree: this example is about `report`'s clean branch,
    # and sourcing it from `db/migrate` would make it a second, noisier copy of the live-tree guard
    # that fails alongside it for the same one defect.
    it "says what it checked when it is clean, rather than saying nothing" do
      report = report_for(<<~RUBY, "20260812000000_add_probe_index_to_spec_observations.rb")
        class AddProbeIndexToSpecObservations < ActiveRecord::Migration[8.1]
          disable_ddl_transaction!

          def change
            add_index :spec_observations, :name, algorithm: :concurrently
          end
        end
      RUBY

      expect(report).to include("1 migration(s) checked", "0 grandfathered", "clean")
    end

    it "counts the grandfathered migrations as exempt rather than as checked" do
      report = described_class.new(root: Rails.root).report

      expect(report).to include(
        "#{described_class::GRANDFATHERED.size} grandfathered",
        "#{Rails.root.glob('db/migrate/*.rb').size - described_class::GRANDFATHERED.size} " \
        "migration(s) checked"
      )
    end

    it "points at the offending line, the reason and the fix when it is not" do
      report = report_for(<<~RUBY, "20260812000000_add_probe_index_to_spec_observations.rb")
        class AddProbeIndexToSpecObservations < ActiveRecord::Migration[8.1]
          def change
            add_index :spec_observations, :name
          end
        end
      RUBY

      expect(report).to include(
        "20260812000000_add_probe_index_to_spec_observations.rb:3",
        "algorithm: :concurrently",
        "disable_ddl_transaction!",
        "20260807120000_add_branch_history_index_to_test_runs.rb"
      )
    end
  end
end
