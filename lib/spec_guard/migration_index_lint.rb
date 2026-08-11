# frozen_string_literal: true

require "prism"
require "pathname"

module SpecGuard
  # Guards the convention `AddBranchHistoryIndexToTestRuns` stated and nothing enforced:
  #
  # > `algorithm: :concurrently` so the build takes no write lock on a table ingestion writes to on
  # > every CI run. Requires `disable_ddl_transaction!`.
  #
  # == Why a concurrent build, and why `disable_ddl_transaction!` comes with it
  #
  # A plain `CREATE INDEX` takes a `SHARE` lock on the table for the whole build. `SHARE` conflicts
  # with `ROW EXCLUSIVE`, which is the lock every `INSERT`/`UPDATE`/`DELETE` takes — so for as long
  # as the index is building, **every writer blocks**. Reads are unaffected, which is exactly what
  # makes this hazard quiet: a staging check and a smoke test both pass while the only thing that
  # would have noticed is a production writer that was not running.
  #
  # `CREATE INDEX CONCURRENTLY` trades that for two table passes and the possibility of leaving an
  # `INVALID` index behind on failure, and in exchange never blocks a writer. Postgres refuses to
  # run it inside a transaction block, and Rails wraps every migration in one — hence
  # `disable_ddl_transaction!`. The two are a **pair**: `algorithm: :concurrently` without it does
  # not degrade to a slow-but-correct build, it raises
  # `ActiveRecord::StatementInvalid: PG::ActiveSqlTransaction` at migrate time. This lint therefore
  # checks both halves, and the missing-`disable_ddl_transaction!` half is checked on **every**
  # table rather than only the hot ones, because there it is not a lock-duration judgement call but
  # a migration that cannot run at all.
  #
  # == Which tables the rule is about, and why those
  #
  # See {GUARDED_TABLES}. The set is deliberately small and reasoned rather than "every table":
  # a concurrent build costs two passes and forfeits the transaction, which is a bad trade for a
  # table no one is writing to during a deploy. What earns a table a place is **being written on
  # the ingest path**, because that is the path that is live while a migration runs.
  #
  # == Why an allowlist of filenames rather than a version floor
  #
  # `strong_migrations` would spell the grandfathering as `start_after = 20260811150000` — one
  # integer, and `db/schema.rb`'s current `version:` at that. It is accurate and it is invisible:
  # silencing a *new* failure is then a one-character edit that reads as a routine version bump in
  # a diff, and it silences every check below it rather than the one offender it was reached for.
  # {GRANDFATHERED} instead names each merged file and states what it did, so that (a) the
  # inventory is legible to the next reader and (b) adding to it is a visible, reviewable claim
  # with a reason attached. The three entries are merged history the guard deliberately does not
  # re-litigate: their locks are already paid, and dropping and rebuilding a live index to correct
  # its build *history* would take another lock to buy nothing.
  #
  # == Why an index on a table created in the same migration is exempt
  #
  # {#offenses} skips any index whose table is `create_table`-d in the same file. A table that did
  # not exist when the migration started has no writers to block, so the lock is uncontended by
  # construction and a concurrent build would be pure cost. This is not a loophole for the hazard:
  # `spec_observations` and `test_runs` both already exist, so nothing can reach it by declaring
  # them again.
  #
  # == What this lint does NOT reach
  #
  # A guard is only as wide as its selector, so the bounds are stated rather than left to be
  # discovered:
  #
  # * **Index removal.** `remove_index` takes a brief `ACCESS EXCLUSIVE` lock and also has a
  #   `algorithm: :concurrently` form. It is not checked — the lock is held for the drop, not for a
  #   full table pass, so it is a different (and much smaller) hazard than the one this exists for.
  # * **Tables outside {GUARDED_TABLES}.** `spec_identities` is the next plausible entry — it is
  #   also written on the ingest path — and is out of scope here only because it is written once
  #   per *distinct* test text rather than once per example. Add it, with its reason, when that
  #   stops being true.
  # * **Non-literal table names.** A table computed at runtime cannot be matched against
  #   {GUARDED_TABLES} by reading the source. Rather than pass such a call silently, the lint
  #   reports it as `:unresolved` — "could not check" is a distinct answer from "checked and
  #   clean", and only one of them is allowed to be green.
  class MigrationIndexLint
    MIGRATION_GLOB = "db/migrate/*.rb"

    # Table => why it is hot enough to be worth two table passes.
    GUARDED_TABLES = {
      "spec_observations" =>
        "written on every ingest by Ingest::ObservationRecorder#record, as a single bulk " \
        "SpecObservation.upsert_all — 20,000 rows per run at the design point, retained across " \
        "SpecObservation::BRANCH_RETENTION_RUNS runs per branch",
      "test_runs" =>
        "written on every ingest — one row per CI run, and the table every branch-scoped read " \
        "joins back to"
    }.freeze

    # Merged migrations that predate the guard. Filename => what it did and why it stands.
    #
    # Everything here is at or below `db/schema.rb`'s `version: 2026_08_11_150000`. The list is
    # closed: it is history, so it can only ever shrink.
    GRANDFATHERED = {
      "20260807010000_add_ci_run_id_to_test_runs.rb" =>
        "plain add_index on test_runs, merged 2026-08-07 before the convention was stated",
      "20260811120000_create_spec_identities.rb" =>
        "add_reference :spec_observations, :spec_identity — Rails indexes a reference by " \
        "default, so this built an index on the hot table without ever naming one",
      "20260811140000_add_embed_failure_to_spec_observations.rb" =>
        "plain add_index on spec_observations (index_spec_observations_on_embed_backlog)",
      "20260811150000_add_unattempted_embed_index_to_spec_observations.rb" =>
        "plain add_index on spec_observations " \
        "(index_spec_observations_on_unattempted_embed_backlog)"
    }.freeze

    CONCURRENT_FIX =
      "add `algorithm: :concurrently` to the call and `disable_ddl_transaction!` to the class body"

    Offense = Struct.new(:kind, :path, :line_number, :detail, :fix, keyword_init: true) do
      def to_s = "#{path}:#{line_number}  #{detail}\n      fix: #{fix}"
    end

    # One index-creating construct found in one migration, before it is judged.
    Build = Struct.new(:table, :line_number, :concurrent, :source, keyword_init: true) do
      def concurrent? = concurrent
    end

    def initialize(root: Dir.pwd)
      @root = Pathname.new(root)
    end

    attr_reader :root

    def migration_files
      Pathname.glob(root.join(MIGRATION_GLOB)).sort
    end

    # The grandfathered ones are deliberately not read, so the report must not claim them as
    # checked — "N migrations checked, clean" over a set that silently excluded the only
    # offenders is the shape of a gate that reports success for work it did not do.
    def checked_files
      migration_files.reject { |path| GRANDFATHERED.key?(path.basename.to_s) }
    end

    def offenses
      @offenses ||= checked_files.flat_map { |path| self.class.scan(path.read, path: relative(path)) }
    end

    def clean? = offenses.empty?

    def report
      if clean?
        exempt = migration_files.size - checked_files.size
        return "Migration index lint: #{checked_files.size} migration(s) checked, " \
               "#{exempt} grandfathered, clean."
      end

      lines = ["Migration index lint — #{offenses.size} offender(s):", ""]
      offenses.each { |offense| lines << "  #{offense}" << "" }
      lines << "Why: a plain CREATE INDEX holds a lock that blocks every writer for the whole"
      lines << "build. See lib/spec_guard/migration_index_lint.rb for the full reasoning, and"
      lines << "db/migrate/20260807120000_add_branch_history_index_to_test_runs.rb for the form."
      lines.join("\n")
    end

    # Analyses ONE migration's source. Exposed on the class so the guard spec can exercise it
    # against sources that do not exist on disk — a guard that has only ever been run against a
    # clean tree has never been shown to be able to fail.
    def self.scan(source, path: "(inline)")
      result = Prism.parse(source)

      unless result.success?
        return [Offense.new(
          kind: :unparsable, path: path, line_number: 1,
          detail: "could not be parsed, so its index builds could not be checked",
          fix: "fix the syntax error; a migration this lint cannot read is not a migration it passed"
        )]
      end

      Scanner.new(result.value).offenses(path)
    end

    private

    def relative(path) = path.relative_path_from(root).to_s

    # Walks one migration's AST collecting every construct that ends in a `CREATE INDEX`, then
    # judges them together — `create_table` may appear after the index that references it.
    class Scanner
      INDEX_SQL = /CREATE\s+INDEX/i
      CONCURRENT_SQL = /CREATE\s+INDEX\s+CONCURRENTLY/i
      SQL_TABLE = /\bON\s+(?:ONLY\s+)?"?([a-z_][a-z0-9_$]*)"?/i

      def initialize(program)
        @created_tables = []
        @builds = []
        @unresolved = []
        @disable_ddl_transaction = false
        walk(program, nil)
      end

      def offenses(path)
        found = []

        @builds.each do |build|
          next if @created_tables.include?(build.table)
          next unless GUARDED_TABLES.key?(build.table)
          next if build.concurrent?

          found << Offense.new(
            kind: :non_concurrent, path: path, line_number: build.line_number,
            detail: "`#{build.source}` builds an index on `#{build.table}` with a plain " \
                    "CREATE INDEX, which blocks every writer for the duration of the build " \
                    "(#{GUARDED_TABLES.fetch(build.table)})",
            fix: CONCURRENT_FIX
          )
        end

        # Checked on every table, not just the hot ones: this one does not run at all.
        if @builds.any?(&:concurrent?) && !@disable_ddl_transaction
          found << Offense.new(
            kind: :missing_disable_ddl_transaction, path: path,
            line_number: @builds.find(&:concurrent?).line_number,
            detail: "builds an index with `algorithm: :concurrently` but the class does not " \
                    "declare `disable_ddl_transaction!`, so Postgres will refuse it at migrate " \
                    "time (PG::ActiveSqlTransaction)",
            fix: "add `disable_ddl_transaction!` to the class body"
          )
        end

        @unresolved.each do |(line_number, source)|
          found << Offense.new(
            kind: :unresolved, path: path, line_number: line_number,
            detail: "`#{source}` creates an index on a table this lint cannot read from the " \
                    "source, so it could not be checked against the guarded tables",
            fix: "name the table with a literal symbol or string, or teach " \
                 "lib/spec_guard/migration_index_lint.rb to read this form"
          )
        end

        found.sort_by { |offense| [offense.line_number, offense.kind.to_s] }
      end

      private

      def walk(node, table_context)
        if node.is_a?(Prism::CallNode)
          case node.name
          when :disable_ddl_transaction!
            @disable_ddl_transaction = true
          when :create_table
            table = literal(positional(node).first)
            @created_tables << table if table
            return walk_children(node, table)
          when :create_join_table
            # The created table is NEITHER argument — Rails joins them, so reading the first one
            # would file `spec_observations` as "created here" for a
            # `create_join_table :spec_observations, :tags`, and exempt every real index on the hot
            # table in that migration.
            table = join_table_name(node)
            @created_tables << table if table
            return walk_children(node, table)
          when :change_table
            return walk_children(node, literal(positional(node).first))
          when :add_index
            record_index(node, literal(positional(node).first))
          when :index
            record_index(node, table_context) if node.receiver
          when :add_reference, :add_belongs_to
            record_reference(node, literal(positional(node).first))
          when :references, :belongs_to
            record_reference(node, table_context) if node.receiver
          when :execute
            record_execute(node)
          end
        end

        walk_children(node, table_context)
      end

      def walk_children(node, table_context)
        node.compact_child_nodes.each { |child| walk(child, table_context) }
        nil
      end

      def record_index(node, table)
        return unresolved(node) if table.nil?

        add(table, node, concurrent: concurrent_option?(options(node)["algorithm"]))
      end

      # `add_reference` / `t.references` build an index unless told not to — the default is
      # `index: true`, which is why an index can land on a hot table without the word "index"
      # appearing anywhere in the migration.
      def record_reference(node, table)
        index = options(node)["index"]
        return if index.is_a?(Prism::FalseNode)
        return unresolved(node) if table.nil?

        concurrent =
          index.is_a?(Prism::HashNode) &&
          concurrent_option?(hash_options(index)["algorithm"])

        add(table, node, concurrent: concurrent)
      end

      def record_execute(node)
        sql = positional(node).filter_map { |argument| string_content(argument) }.join(" ")
        return unless sql.match?(INDEX_SQL)

        table = sql[SQL_TABLE, 1]
        return unresolved(node) if table.nil?

        add(table, node, concurrent: sql.match?(CONCURRENT_SQL))
      end

      def add(table, node, concurrent:)
        @builds << Build.new(
          table: table, line_number: node.location.start_line,
          concurrent: concurrent, source: signature(node)
        )
      end

      def unresolved(node) = @unresolved << [node.location.start_line, signature(node)]

      # `create_join_table :a, :b` creates `a_b` — the two names sorted and joined, unless
      # `table_name:` overrides it.
      def join_table_name(node)
        explicit = literal(options(node)["table_name"])
        return explicit if explicit

        names = positional(node).first(2).map { |argument| literal(argument) }
        names.sort.join("_") if names.size == 2 && names.none?(&:nil?)
      end

      # The call as written, first line only — enough to point at without reprinting the options.
      def signature(node) = node.slice.lines.first.strip.delete_suffix(",")

      def positional(node)
        (node.arguments&.arguments || []).reject { |argument| hash_node?(argument) }
      end

      def options(node)
        last = (node.arguments&.arguments || []).last
        hash_node?(last) ? hash_options(last) : {}
      end

      def hash_options(hash)
        hash.elements.each_with_object({}) do |element, memo|
          next unless element.is_a?(Prism::AssocNode)

          key = literal(element.key)
          memo[key] = element.value if key
        end
      end

      def hash_node?(node) = node.is_a?(Prism::KeywordHashNode) || node.is_a?(Prism::HashNode)

      def concurrent_option?(node) = literal(node) == "concurrently"

      def literal(node)
        case node
        when Prism::SymbolNode, Prism::StringNode then node.unescaped
        end
      end

      # Reads a heredoc or plain string, including the literal parts of an interpolated one — the
      # table name in a `CREATE INDEX` is a literal even when the predicate around it is not.
      def string_content(node)
        case node
        when Prism::SymbolNode, Prism::StringNode
          node.unescaped
        when Prism::InterpolatedStringNode
          # Prism models both `"a#{b}c"` and adjacent-literal concatenation as this node; the
          # interpolated parts are simply not string content and drop out.
          node.parts.filter_map { |part| string_content(part) }.join(" ")
        end
      end
    end
  end
end
