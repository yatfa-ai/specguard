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
    # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "enumerate db/migrate", behavior: "the guard scans exactly the migration files present on disk, so an empty glob cannot masquerade as a clean tree", layer: "unit" }
    it "actually reads every migration in db/migrate" do
      on_disk = Rails.root.glob("db/migrate/*.rb").map { |path| path.basename.to_s }

      expect(on_disk).not_to be_empty
      expect(lint.migration_files.map { |path| path.basename.to_s }).to match_array(on_disk)
    end

    # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "lint the live db/migrate tree", behavior: "the real migration tree produces no offenses, so the guarded hot tables are only ever indexed concurrently", layer: "unit" }
    it "builds no index on a hot table without `algorithm: :concurrently`" do
      expect(lint.offenses).to be_empty, -> { lint.report }
      expect(lint).to be_clean
    end

    # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "declare GUARDED_TABLES", behavior: "the guarded set is exactly the two ingestion-written tables, each carrying a stated reason", layer: "unit" }
    it "names the tables the rule is about, with the reason each one earns it" do
      expect(described_class::GUARDED_TABLES.keys).to contain_exactly("spec_observations", "test_runs")
      expect(described_class::GUARDED_TABLES.values).to all(be_present)
    end
  end

  # The allowlist is the whole of AC-2: merged history is not re-litigated, and the exemption is
  # named rather than spelled as an opaque version floor.
  describe "the grandfathered migrations" do
    subject(:grandfathered) { described_class::GRANDFATHERED }

    # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "declare GRANDFATHERED allowlist", behavior: "every allowlisted migration file still exists under db/migrate", layer: "unit" }
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
    # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "bound the grandfathered exemption", behavior: "the exemption ceiling is the last pre-guard merged migration and never covers anything newer than the schema version", layer: "unit" }
    it "stops at the last migration merged before the guard, and never reaches past it" do
      expect(grandfathered.keys.map { |basename| basename[/\A\d+/].to_i }.max)
        .to eq(20_260_811_150_000)
      expect(grandfathered.keys.map { |basename| basename[/\A\d+/].to_i }.max)
        .to be <= schema_version
    end

    # Load-bearing in both directions. A dead entry (the migration was rewritten to build
    # concurrently) is an exemption still standing over nothing, and this is what makes removing it
    # compulsory rather than optional.
    # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "validate the grandfathered entries", behavior: "each allowlisted file still offends the lint when scanned, so no dead exemption survives and every entry states why", layer: "unit" }
    it "names only files that would otherwise fail, and each with a stated reason" do
      grandfathered.each do |basename, reason|
        source = Rails.root.join("db/migrate", basename).read
        offenses = described_class.scan(source, path: basename)

        expect(offenses).not_to be_empty,
                                "#{basename} no longer fails the lint — drop it from GRANDFATHERED"
        expect(reason).to be_present
      end
    end

    # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "validate the grandfathered entries", behavior: "the allowlist contains no filename absent from the merged migration set", layer: "unit" }
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
      # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "scan an add_index call", behavior: "a non-concurrent index build on a guarded table is reported with detail naming the table and a fix naming both required changes", layer: "unit" }
      it "flags a plain build on a guarded table" do
        offenses = offenses_for(migration("add_index :spec_observations, %i[repository_id name]"))

        expect(offenses.map(&:kind)).to eq([:non_concurrent])
        expect(offenses.first.detail).to include("spec_observations", "blocks every writer")
        expect(offenses.first.fix).to include("algorithm: :concurrently", "disable_ddl_transaction!")
      end

      # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "scan an add_index call", behavior: "algorithm concurrently paired with disable_ddl_transaction! yields no offense", layer: "unit" }
      it "accepts a concurrent build that also disables the DDL transaction" do
        source = migration(
          "add_index :spec_observations, %i[repository_id name], algorithm: :concurrently",
          disable_ddl: true
        )

        expect(offenses_for(source)).to be_empty
      end

      # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "scan a multi-line add_index", behavior: "the parser follows arguments across lines so a trailing algorithm option on line four still satisfies the rule", layer: "unit" }
      it "reads a multi-line call, where the option sits three lines below the table" do
        source = migration(<<~RUBY, disable_ddl: true)
          add_index :spec_observations, %i[repository_id created_at id],
                    where: "spec_identity_id IS NULL",
                    name: "index_spec_observations_on_probe",
                    algorithm: :concurrently
        RUBY

        expect(offenses_for(source)).to be_empty
      end

      # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "scan an add_index call", behavior: "string-named tables are recognized by the detector the same as symbol-named ones", layer: "unit" }
      it "reads a table named with a string as well as a symbol" do
        expect(offenses_for(migration(%(add_index "test_runs", :branch))).map(&:kind))
          .to eq([:non_concurrent])
      end

      # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "scan an add_index call", behavior: "index builds on tables outside the guarded set are left alone", layer: "unit" }
      it "ignores a table the rule is not about" do
        expect(offenses_for(migration("add_index :users, :github_handle"))).to be_empty
      end
    end

    # The way an index reached `spec_observations` in `CreateSpecIdentities` without the word
    # "index" appearing in the migration at all: `add_reference` indexes by default.
    describe "add_reference" do
      # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "scan an add_reference call", behavior: "the implicit index a default add_reference creates on a guarded table is flagged even with no add_index present", layer: "unit" }
      it "flags the index Rails adds by default" do
        offenses = offenses_for(migration("add_reference :spec_observations, :spec_identity, null: true"))

        expect(offenses.map(&:kind)).to eq([:non_concurrent])
        expect(offenses.first.detail).to include("add_reference :spec_observations")
      end

      # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "scan an add_reference call", behavior: "index: false produces no offense because no index is built", layer: "unit" }
      it "accepts one that asks for no index" do
        expect(offenses_for(migration("add_reference :spec_observations, :probe, index: false")))
          .to be_empty
      end

      # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "scan an add_reference call", behavior: "a reference whose index option specifies algorithm concurrently is accepted when the DDL transaction is disabled", layer: "unit" }
      it "accepts one that asks for a concurrent index" do
        source = migration(
          "add_reference :spec_observations, :probe, index: { algorithm: :concurrently }",
          disable_ddl: true
        )

        expect(offenses_for(source)).to be_empty
      end
    end

    describe "change_table" do
      # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "scan a change_table block", behavior: "an index declared inside change_table inherits the guarded table from the block line and is flagged", layer: "unit" }
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

      # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "scan a change_table block", behavior: "a reference added inside change_table on a guarded table is flagged for its default index", layer: "unit" }
      it "flags a `t.references` on a guarded table" do
        source = migration(<<~RUBY)
          change_table :spec_observations do |t|
            t.references :probe
          end
        RUBY

        expect(offenses_for(source).map(&:kind)).to eq([:non_concurrent])
      end

      # `index` is an ordinary Ruby method — Array, String and Enumerable all answer to it — and
      # this repository writes data-touching migrations that call it
      # (20260806090000_normalize_and_index_user_github_handles.rb). Reading every `.index` with a
      # receiver as a table definition reddened the suite on migrations that build no index at all,
      # and told the author to "name the table with a literal symbol or string" when there was no
      # table to name. An unactionable failure on unrelated code is how a guard gets routed around.
      # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "scan unrelated .index calls", behavior: "a receiver-bearing .index such as Array lookup raises no false offense", layer: "unit" }
      it "does not read `Array#index` as an index build" do
        source = migration(<<~RUBY)
          names = %w[a b]
          pos = names.index("a")
        RUBY

        expect(offenses_for(source)).to be_empty
      end

      # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "scan unrelated .index calls", behavior: "index calls on locals inside a change_table block are ignored unless the receiver is the block parameter", layer: "unit" }
      it "does not read `.index` on a local that is not the block parameter as an index build" do
        source = migration(<<~RUBY)
          change_table :spec_observations do |t|
            haystack = %w[a b]
            haystack.index("a")
          end
        RUBY

        expect(offenses_for(source)).to be_empty
      end
    end

    # `CreateSpecIntents` and `CreateSpecIdentities` both build their vector indexes this way,
    # because `add_index` cannot express an `ivfflat`/`hnsw` operator class. It is the form a
    # future vector index on `spec_observations` would arrive in.
    #
    # Which is why the spelling matters as much as the construct. `execute <<~SQL.squish` is 4 of
    # the 5 `execute` calls in db/migrate and is how the repository's only vector index is built;
    # an earlier version of this arm read only the outermost node, saw a method call rather than a
    # heredoc, and answered "" — so the SQL never reached the CREATE INDEX test and the call was
    # dropped before it was judged. The falsifier witnessed the branch going red on bare `<<~SQL`,
    # a spelling this codebase mostly does not use, and never on the one it does. Each spelling
    # below is therefore exercised in BOTH directions: red on the plain build, green on the
    # concurrent one, so neither a silent drop nor a blanket flag can pass.
    describe "raw SQL" do
      # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "scan executed SQL heredocs", behavior: "a plain CREATE INDEX handed to execute via heredoc on a guarded table is reported as non-concurrent", layer: "unit" }
      it "flags a CREATE INDEX in an executed heredoc" do
        source = migration(<<~'RUBY')
          execute <<~SQL
            CREATE INDEX index_spec_observations_on_embedding
            ON spec_observations USING hnsw (embedding vector_cosine_ops)
          SQL
        RUBY

        expect(offenses_for(source).map(&:kind)).to eq([:non_concurrent])
      end

      # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "scan executed SQL heredocs", behavior: "the concurrent spelling of the raw SQL build yields no offense", layer: "unit" }
      it "accepts CREATE INDEX CONCURRENTLY" do
        source = migration(<<~'RUBY', disable_ddl: true)
          execute <<~SQL
            CREATE INDEX CONCURRENTLY index_spec_observations_on_embedding
            ON spec_observations USING hnsw (embedding vector_cosine_ops)
          SQL
        RUBY

        expect(offenses_for(source)).to be_empty
      end

      # The exact shape of db/migrate/20260811120000_create_spec_identities.rb:124.
      # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "scan executed SQL heredocs", behavior: "the .squish-wrapped heredoc form actually used in db/migrate still reaches the CREATE INDEX test and is flagged when plain", layer: "unit" }
      it "flags a heredoc behind `.squish`, the spelling this repository actually writes" do
        source = migration(<<~'RUBY')
          execute <<~SQL.squish
            CREATE INDEX index_spec_observations_on_embedding
            ON spec_observations USING hnsw (embedding vector_cosine_ops)
          SQL
        RUBY

        expect(offenses_for(source).map(&:kind)).to eq([:non_concurrent])
      end

      # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "scan executed SQL heredocs", behavior: "a .squish heredoc bearing CREATE INDEX CONCURRENTLY produces no offense", layer: "unit" }
      it "accepts the concurrent form of that same spelling" do
        source = migration(<<~'RUBY', disable_ddl: true)
          execute <<~SQL.squish
            CREATE INDEX CONCURRENTLY index_spec_observations_on_embedding
            ON spec_observations USING hnsw (embedding vector_cosine_ops)
          SQL
        RUBY

        expect(offenses_for(source)).to be_empty
      end

      # `.squish` behind a `reversible` block — how CreateSpecIdentities wraps it, so that the
      # index has a `direction.down`. Two block frames deep from the migration body.
      # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "scan nested execute calls", behavior: "raw SQL two block frames deep inside reversible is still found and flagged when non-concurrent", layer: "unit" }
      it "flags one nested inside reversible/direction.up" do
        source = migration(<<~'RUBY')
          reversible do |direction|
            direction.up do
              execute <<~SQL.squish
                CREATE INDEX index_spec_observations_on_embedding
                ON spec_observations USING hnsw (embedding vector_cosine_ops)
              SQL
            end
          end
        RUBY

        expect(offenses_for(source).map(&:kind)).to eq([:non_concurrent])
      end

      # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "scan executed SQL strings", behavior: "CREATE INDEX passed as a squished string literal to execute is detected", layer: "unit" }
      it "flags a plain string behind a method call too" do
        source = migration(%(execute "CREATE INDEX idx ON spec_observations (name)".squish))

        expect(offenses_for(source).map(&:kind)).to eq([:non_concurrent])
      end

      # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "scan executed SQL", behavior: "non-index SQL such as ANALYZE raises no offense", layer: "unit" }
      it "ignores an execute that is not building an index" do
        expect(offenses_for(migration(%(execute "ANALYZE spec_observations")))).to be_empty
      end

      # The failure mode this arm is most prone to: an argument it cannot read looks like empty
      # SQL, and empty SQL contains no CREATE INDEX. "I read it and there is no index here" and "I
      # could not read it" must not both be green.
      # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "scan an unreadable execute argument", behavior: "a dynamic SQL argument is reported as unresolved with a fix demanding a literal, never silently treated as clean", layer: "unit" }
      it "reports an execute whose SQL it cannot read rather than passing it" do
        offenses = offenses_for(migration("execute build_index_sql"))

        expect(offenses.map(&:kind)).to eq([:unresolved])
        expect(offenses.first.detail).to include("could not be checked for a CREATE INDEX")
        expect(offenses.first.fix).to include("literal string or heredoc")
      end
    end

    # A table that did not exist when the migration started has no writers to block, so requiring a
    # concurrent build there would be pure cost. `CreateSpecObservations` builds five indexes on
    # `spec_observations` under this exemption.
    describe "the same-migration create_table exemption" do
      # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "apply the same-migration create_table exemption", behavior: "a plain index on a table created earlier in the same migration is exempt because the table had no writers", layer: "unit" }
      it "accepts an index on a table this migration creates" do
        source = migration(<<~RUBY)
          create_table :spec_observations do |t|
            t.string :name
          end

          add_index :spec_observations, :name
        RUBY

        expect(offenses_for(source)).to be_empty
      end

      # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "apply the same-migration create_table exemption", behavior: "the exemption is file-wide regardless of statement order between create_table and add_index", layer: "unit" }
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
      # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "apply the same-migration create_table exemption", behavior: "create_join_table exempts only the generated join-table name, so an index on the hot base table is still flagged", layer: "unit" }
      it "does not treat a create_join_table argument as a table that was created" do
        source = migration(<<~RUBY)
          create_join_table :spec_observations, :tags

          add_index :spec_observations, :name
        RUBY

        expect(offenses_for(source).map(&:kind)).to eq([:non_concurrent])
      end

      # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "apply the same-migration create_table exemption", behavior: "an index on the join table create_join_table actually creates is exempt", layer: "unit" }
      it "still exempts the join table itself" do
        source = migration(<<~RUBY)
          create_join_table :spec_observations, :tags

          add_index :spec_observations_tags, :tag_id
        RUBY

        expect(offenses_for(source)).to be_empty
      end

      # The exemption rests on "this table did not exist, so it has no writers". `if_not_exists:`
      # is precisely the case where it may well have existed — and an existing hot table has
      # writers — so it does not get the file-wide form. Nobody writes this by accident, but the
      # lint is the durable record of the reasoning, so the exemption has to actually mean what it
      # says rather than be a sentence that is nearly true.
      # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "apply the same-migration create_table exemption", behavior: "a conditional create_table denies the file-wide exemption because the hot table may pre-exist with writers", layer: "unit" }
      it "does not let `create_table if_not_exists:` exempt the rest of the migration" do
        source = migration(<<~RUBY)
          create_table :spec_observations, if_not_exists: true do |t|
            t.string :name
          end

          add_index :spec_observations, :name
        RUBY

        expect(offenses_for(source).map(&:kind)).to eq([:non_concurrent])
      end

      # The other half: indexes inside that block run only on the branch where the table was in
      # fact just created, so they keep the exemption. Flagging them would be a false positive.
      # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "apply the same-migration create_table exemption", behavior: "indexes declared inside the if_not_exists block keep the exemption since they run only on the freshly-created branch", layer: "unit" }
      it "still exempts the indexes inside that block" do
        source = migration(<<~RUBY)
          create_table :spec_observations, if_not_exists: true do |t|
            t.string :name
            t.index :name
          end
        RUBY

        expect(offenses_for(source)).to be_empty
      end

      # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "apply the same-migration create_table exemption", behavior: "an explicit false restores the file-wide exemption because the table is guaranteed new", layer: "unit" }
      it "keeps the file-wide exemption for an explicit `if_not_exists: false`" do
        source = migration(<<~RUBY)
          create_table :spec_observations, if_not_exists: false do |t|
            t.string :name
          end

          add_index :spec_observations, :name
        RUBY

        expect(offenses_for(source)).to be_empty
      end
    end

    # Not a lock-duration judgement call: Postgres refuses CREATE INDEX CONCURRENTLY inside a
    # transaction block, so this migration raises rather than running slowly. Checked on every
    # table, hot or not.
    describe "the disable_ddl_transaction! pairing" do
      # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "check disable_ddl_transaction pairing", behavior: "a concurrent build lacking disable_ddl_transaction! is reported because Postgres would raise inside the transaction", layer: "unit" }
      it "flags a concurrent build in a migration that does not disable the DDL transaction" do
        source = migration("add_index :spec_observations, :name, algorithm: :concurrently")

        expect(offenses_for(source).map(&:kind)).to include(:missing_disable_ddl_transaction)
      end

      # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "check disable_ddl_transaction pairing", behavior: "the pairing check applies to every table, not only guarded ones", layer: "unit" }
      it "flags it on an unguarded table too" do
        source = migration("add_index :users, :github_handle, algorithm: :concurrently")

        expect(offenses_for(source).map(&:kind)).to eq([:missing_disable_ddl_transaction])
      end
    end

    # "Could not check" is a distinct answer from "checked and clean", and only one of them is
    # allowed to be green.
    describe "when it cannot read the source" do
      # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "scan a dynamic table argument", behavior: "a non-literal table name yields an unresolved offense demanding a literal rather than a pass", layer: "unit" }
      it "reports a table name it cannot resolve rather than passing it" do
        source = migration(<<~RUBY)
          hot_tables.each { |table| add_index table, :repository_id }
        RUBY

        offenses = offenses_for(source)

        expect(offenses.map(&:kind)).to eq([:unresolved])
        expect(offenses.first.fix).to include("literal symbol or string")
      end

      # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "parse a malformed migration", behavior: "unparsable source is reported as such instead of counting as checked and clean", layer: "unit" }
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
    # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "render the report for a clean tree", behavior: "a clean run states the migrations checked and grandfathered count so silence cannot be mistaken for coverage", layer: "unit" }
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

    # Asserts the exemption ARITHMETIC directly rather than by reading a clean tree's report. The
    # earlier spelling of this example matched the grandfathered count inside the live tree's
    # report string, which meant one real offense anywhere in db/migrate reddened this example too
    # — a second, noisier failure, about counts, for a defect that has nothing to do with counts.
    # That is exactly what the neighbouring example's comment rejects. `checked_files` answers the
    # question ("is the exempt set excluded from the checked set?") without depending on whether
    # what remains happens to be clean.
    # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "compute checked_files", behavior: "the exempt set is excluded from the checked set and the sizes reconcile with the on-disk migration count", layer: "unit" }
    it "counts the grandfathered migrations as exempt rather than as checked" do
      lint = described_class.new(root: Rails.root)
      checked = lint.checked_files.map { |path| path.basename.to_s }

      expect(described_class::GRANDFATHERED).not_to be_empty
      expect(checked).not_to include(*described_class::GRANDFATHERED.keys)
      expect(checked.size)
        .to eq(Rails.root.glob("db/migrate/*.rb").size - described_class::GRANDFATHERED.size)
    end

    # @intent: { entity: "SpecGuard::MigrationIndexLint", action: "render the report for an offending tree", behavior: "an offense report names the file and line, the concurrency fix, and a real-world precedent migration", layer: "unit" }
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
