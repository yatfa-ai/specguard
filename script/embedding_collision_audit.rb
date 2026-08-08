# frozen_string_literal: true

# Measures what feature hashing costs EmbeddingGenerator::LocalProvider at this product's scale.
#
# ## The question
#
# LocalProvider hashes an unbounded feature space (every word and every 3-character n-gram it ever
# sees) into 1536 buckets. Distinct features therefore land in the same dimension and their weights
# sum. SpecGuard's target is 20,000 tests in a *single* repository — one codebase's vocabulary,
# which is far denser and more self-similar than a corpus drawn from many. Whether the resulting
# false-match rate is acceptable there is an empirical question, and this script is the answer's
# method.
#
# ## The method
#
# For every one of the ~200,000,000 pairs in the corpus — a full census, not a sample — compute two
# cosine similarities:
#
#   * **hashed** — the vector `EmbeddingGenerator.call` actually returns: 1536 dimensions, with
#     collisions.
#   * **exact** — the same features with the same signed weights, but each feature keeps a
#     dimension of its own in an unbounded space. This is what the algorithm *intends* to measure.
#     It is collision-free by construction, so it is the ground truth for this comparison.
#
# The difference between the two is caused by hashing and by nothing else. Both use identical
# tokenisation and identical weights, drawn from LocalProvider itself rather than reimplemented
# here, so a change to the provider changes both sides together.
#
# A pair is a **false match at threshold t** when `hashed >= t` and `exact < t`: hashing alone
# flipped the verdict from "not the same test" to "the same test". The converse — `exact >= t` and
# `hashed < t` — is a **missed match**, counted too, because collisions can destroy a similarity as
# easily as they can invent one.
#
# Deliberately *not* used as ground truth: human judgement about which test names "mean" the same
# thing. LocalProvider does not claim to measure meaning (see its own documentation), so scoring it
# against meaning would measure the algorithm's known lexical limitation rather than the hashing
# question this script exists to answer.
#
# ## Running it
#
# No Rails, no database, no API key, no network:
#
#     ruby script/embedding_collision_audit.rb /path/to/some/repo
#
# It walks the given paths for `*_spec.rb`, statically extracts every RSpec example's full name
# (the `describe` / `context` / `it` chain, joined the way RSpec joins it), deduplicates, samples
# down to SIZE by an even stride over the sorted list, and reports. Use a real suite: synthetic test
# names are more distinguishable from one another than real ones, which cluster heavily around one
# domain vocabulary, and would flatter the result.
#
#     SIZE=20000 ruby script/embedding_collision_audit.rb ../discourse/spec ../discourse/plugins
#
# Environment:
#
#     SIZE        corpus size (default 20000)
#     WORKERS     forked processes for the pair sweep (default: processor count)
#     THRESHOLDS  comma-separated cosine thresholds to report (default 0.95,0.88,0.80,0.75)
#
# The corpus, the commit it was taken from, and the numbers this printed are recorded in
# docs/embedding-collision-audit.md.

require "digest"
require "etc"
require "json"
require "prism"
# Standalone under plain `ruby`, but this file is also required by its spec, where Zeitwerk has
# already autoloaded the service and requiring it again would define the constant behind Zeitwerk's
# back.
require_relative "../app/services/embedding_generator" unless defined?(EmbeddingGenerator)

module EmbeddingCollisionAudit
  SIZE = Integer(ENV.fetch("SIZE", 20_000))
  WORKERS = Integer(ENV.fetch("WORKERS", Etc.nprocessors))
  THRESHOLDS = ENV.fetch("THRESHOLDS", "0.95,0.88,0.80,0.75").split(",").map { |t| Float(t) }

  # Buckets for the signed error (hashed - exact). Fine near zero, where almost every pair lands.
  ERROR_BINS = [ 0.001, 0.005, 0.01, 0.05, 0.1, 0.2, 0.4, 0.8 ].freeze

  # How many worked examples of the worst false matches to print. Bounded so the output stays
  # readable; the counts above them are the finding, these are only there to make it concrete.
  EXAMPLES = 15

  # A pair only reaches the worked-examples list if hashing overstated its similarity by this much.
  OVERSTATEMENT_FLOOR = 0.2

  # Below this, the collision-free algorithm considers a pair barely related at all — so a false
  # match under it is hashing inventing a resemblance rather than nudging a near-miss over the line.
  UNRELATED = 0.3

  # Statically extracts RSpec example full names from spec files.
  #
  # Static parsing rather than `rspec --dry-run` on purpose: it needs neither the target project's
  # gems nor its database, so the corpus is reproducible from a bare `git clone` of any suite.
  #
  # What it deliberately skips, and why the skips are counted and reported: an example whose
  # description is interpolated (`it "handles #{mode}"`) has no single static name, and one with no
  # description at all (`it { is_expected.to be_valid }`) has no name until RSpec generates one from
  # the matcher at runtime. Including either would mean inventing corpus text, which is the one
  # thing this measurement must not do.
  class Corpus
    GROUP_METHODS = %i[describe context feature example_group xdescribe xcontext fdescribe fcontext
                       shared_examples shared_examples_for shared_context].freeze
    EXAMPLE_METHODS = %i[it specify example scenario its xit xspecify xexample fit fspecify
                         fexample].freeze

    # RSpec joins a child description onto its parent with a space, except when the child starts
    # with one of these — so `describe Post` + `describe "#save"` is "Post#save", not "Post #save".
    GLUED = /\A(#|\.|::)/

    attr_reader :names, :skipped_dynamic, :skipped_anonymous, :files

    def initialize(paths)
      @paths = paths
      @names = []
      @skipped_dynamic = 0
      @skipped_anonymous = 0
      @files = 0
    end

    def extract
      spec_files.each do |path|
        @files += 1
        walk(Prism.parse_file(path.to_s).value, [])
      rescue StandardError => e
        warn "  skipped #{path}: #{e.class}: #{e.message}"
      end
      self
    end

    private

    def spec_files
      @paths.flat_map { |path| Dir.glob(File.join(path, "**", "*_spec.rb")) }.sort
    end

    def walk(node, trail)
      return unless node.is_a?(Prism::Node)

      if node.is_a?(Prism::CallNode)
        name = node.name
        if GROUP_METHODS.include?(name) && node.block
          description = description_of(node)
          walk(node.block.body, description ? trail + [ description ] : trail)
          return
        elsif EXAMPLE_METHODS.include?(name)
          record(trail, node)
          return
        end
      end

      node.compact_child_nodes.each { |child| walk(child, trail) }
    end

    def record(trail, node)
      # `example.metadata` inside an example is a call named `example` with neither a block nor an
      # argument — not an example, and not a skip worth counting either.
      return if node.block.nil? && node.arguments.nil?

      description = description_of(node)
      return if description.nil?

      @names << join(trail + [ description ])
    end

    # nil means "no static name", and the two reasons are counted apart so the report can say which
    # it was.
    def description_of(node)
      argument = node.arguments&.arguments&.first

      case argument
      when Prism::StringNode           then argument.unescaped
      when Prism::SymbolNode           then argument.unescaped
      when Prism::ConstantReadNode     then argument.name.to_s
      when Prism::ConstantPathNode     then argument.slice
      when Prism::InterpolatedStringNode then (@skipped_dynamic += 1) && nil
      when nil                         then (@skipped_anonymous += 1) && nil
      else                                  (@skipped_dynamic += 1) && nil
      end
    end

    def join(parts)
      parts.reduce("") do |full, part|
        next part if full.empty?

        part.match?(GLUED) ? "#{full}#{part}" : "#{full} #{part}"
      end
    end
  end

  # A corpus name in both representations at once. The features and their weights come from
  # LocalProvider, not from a copy of it, so hashed and exact can never drift apart.
  #
  #   hashed — index = SHA-256 bytes 0..7 mod 1536, exactly what production stores.
  #   exact  — index = the feature string itself, in a space with no ceiling and so no collisions.
  #
  # Both are stored sparsely and unit-normalised, which is what makes a 200M-pair census tractable
  # in plain Ruby: a name touches ~40 of 1536 hashed dimensions and ~70 exact ones, so a dot product
  # is a walk over a short posting list, not over 1536 slots.
  Document = Struct.new(:name, :hashed_ids, :hashed_weights, :exact_ids, :exact_weights)

  class Vectoriser
    attr_reader :feature_count

    def initialize
      @feature_ids = {}
    end

    def call(name)
      hashed = Hash.new(0.0)
      exact = Hash.new(0.0)

      # Reaching through the provider's own tokeniser and weighting is the point: this measures the
      # shipped algorithm, not a second implementation of it that could quietly disagree with it.
      EmbeddingGenerator::LocalProvider.new(name).features.each do |feature|
        index, phase = Digest::SHA256.digest(feature).unpack("Q>N")
        weight = Math.sin(phase * EmbeddingGenerator::LocalProvider::PHASE_STEP_RADIANS)

        hashed[index % EmbeddingGenerator::DIMENSIONS] += weight
        exact[intern(feature)] += weight
      end

      hashed_ids, hashed_weights = normalise(hashed)
      exact_ids, exact_weights = normalise(exact)
      Document.new(name, hashed_ids, hashed_weights, exact_ids, exact_weights)
    end

    def feature_count = @feature_ids.size

    private

    def intern(feature)
      @feature_ids[feature] ||= @feature_ids.size
    end

    def normalise(accumulator)
      magnitude = Math.sqrt(accumulator.each_value.sum { |weight| weight * weight })
      return [ [], [] ] if magnitude.zero?

      [ accumulator.keys, accumulator.values.map { |weight| weight / magnitude } ]
    end
  end

  # The census. Every pair, both similarities, no sampling.
  #
  # For each query document i, both similarity vectors against every j are built by walking i's
  # non-zero dimensions and adding each one's contribution to the documents that share it, using an
  # inverted index. That is O(nnz(i) x postings) rather than O(n x 1536), which is what turns an
  # otherwise impossible amount of arithmetic into a few minutes across forked workers.
  class Sweep
    def initialize(documents, thresholds)
      @documents = documents
      @thresholds = thresholds
      @hashed_index = build_index(:hashed_ids, :hashed_weights)
      @exact_index = build_index(:exact_ids, :exact_weights)
    end

    def run(workers:)
      slices = (0...@documents.size).group_by { |i| i % workers }.values
      merge(slices.map { |slice| fork_worker(slice) }.map { |io| JSON.parse(io.read, symbolize_names: true) })
    end

    private

    def build_index(ids_field, weights_field)
      index = Hash.new { |hash, key| hash[key] = [ [], [] ] }
      @documents.each_with_index do |document, doc_id|
        document[ids_field].each_with_index do |dimension, position|
          slot = index[dimension]
          slot[0] << doc_id
          slot[1] << document[weights_field][position]
        end
      end
      index
    end

    def fork_worker(slice)
      reader, writer = IO.pipe
      Process.fork do
        reader.close
        writer.write(JSON.generate(tally(slice)))
        writer.close
        exit!(0)
      end
      writer.close
      reader
    end

    def tally(slice)
      count = @documents.size
      hashed_scores = Array.new(count, 0.0)
      exact_scores = Array.new(count, 0.0)
      result = blank_tally

      slice.each do |i|
        accumulate(@hashed_index, @documents[i], :hashed_ids, :hashed_weights, hashed_scores)
        accumulate(@exact_index, @documents[i], :exact_ids, :exact_weights, exact_scores)

        ((i + 1)...count).each do |j|
          score(result, i, j, hashed_scores[j], exact_scores[j])
        end

        reset(@hashed_index, @documents[i], :hashed_ids, hashed_scores)
        reset(@exact_index, @documents[i], :exact_ids, exact_scores)
      end

      result[:worst] = result[:worst].sort_by { |entry| -entry[:gap] }.first(EXAMPLES)
      result
    end

    def accumulate(index, document, ids_field, weights_field, scores)
      document[ids_field].each_with_index do |dimension, position|
        weight = document[weights_field][position]
        doc_ids, weights = index[dimension]
        doc_ids.each_with_index { |doc_id, k| scores[doc_id] += weight * weights[k] }
      end
    end

    # Zeroing only the entries this query touched, rather than refilling a 20,000-slot array, is
    # the difference between the sweep taking minutes and taking hours.
    def reset(index, document, ids_field, scores)
      document[ids_field].each do |dimension|
        index[dimension][0].each { |doc_id| scores[doc_id] = 0.0 }
      end
    end

    def blank_tally
      {
        pairs: 0,
        error_sum: 0.0,
        error_bins: Array.new(ERROR_BINS.size + 1, 0),
        thresholds: @thresholds.to_h { |t| [ t.to_s.to_sym, { hashed: 0, exact: 0, false_match: 0, missed: 0, unrelated_false_match: 0 } ] },
        worst: []
      }
    end

    def score(result, i, j, hashed, exact)
      result[:pairs] += 1
      error = hashed - exact
      magnitude = error.abs
      result[:error_sum] += magnitude
      result[:error_bins][ERROR_BINS.index { |edge| magnitude < edge } || ERROR_BINS.size] += 1

      @thresholds.each do |threshold|
        bucket = result[:thresholds][threshold.to_s.to_sym]
        hashed_matches = hashed >= threshold
        exact_matches = exact >= threshold

        bucket[:hashed] += 1 if hashed_matches
        bucket[:exact] += 1 if exact_matches

        if hashed_matches && !exact_matches
          bucket[:false_match] += 1
          bucket[:unrelated_false_match] += 1 if exact < UNRELATED
        elsif exact_matches && !hashed_matches
          bucket[:missed] += 1
        end
      end

      return unless error > OVERSTATEMENT_FLOOR

      result[:worst] << { gap: error.round(4), hashed: hashed.round(4), exact: exact.round(4),
                          a: @documents[i].name, b: @documents[j].name }
    end

    def merge(tallies)
      merged = blank_tally
      tallies.each do |tally|
        merged[:pairs] += tally[:pairs]
        merged[:error_sum] += tally[:error_sum]
        tally[:error_bins].each_with_index { |n, k| merged[:error_bins][k] += n }
        tally[:thresholds].each do |key, bucket|
          bucket.each { |field, n| merged[:thresholds][key][field] += n }
        end
        merged[:worst].concat(tally[:worst])
      end
      merged[:worst] = merged[:worst].sort_by { |entry| -entry[:gap] }.first(EXAMPLES)
      merged
    end
  end

  class << self
    def run(paths)
      abort(usage) if paths.empty?

      corpus = report_corpus(paths)
      documents = report_vectors(corpus)
      report_sweep(documents)
    end

    private

    def usage
      "usage: [SIZE=20000] ruby script/embedding_collision_audit.rb PATH [PATH...]\n" \
      "  PATH: a directory to walk for *_spec.rb (e.g. a checked-out repo's spec/)"
    end

    def report_corpus(paths)
      puts "Corpus"
      puts "  paths: #{paths.join(' ')}"
      extracted = Corpus.new(paths).extract
      unique = extracted.names.uniq

      puts "  spec files scanned:        #{extracted.files}"
      puts "  example names extracted:   #{extracted.names.size}"
      puts "  skipped, interpolated:     #{extracted.skipped_dynamic}"
      puts "  skipped, no description:   #{extracted.skipped_anonymous}"
      puts "  exact duplicate names:     #{extracted.names.size - unique.size}"

      sampled = sample(unique.sort, SIZE)
      lengths = sampled.map(&:length)
      puts "  corpus size:               #{sampled.size}"
      puts "  name length min/mean/max:  #{lengths.min}/#{(lengths.sum / lengths.size.to_f).round(1)}/#{lengths.max}"
      puts
      abort "corpus too small: wanted #{SIZE}, got #{sampled.size}" if sampled.size < SIZE
      sampled
    end

    # An even stride over the sorted list rather than a random sample: reproducible without a seed,
    # and it spreads the corpus across the whole suite instead of favouring whichever directories
    # sort first.
    def sample(names, size)
      return names if names.size <= size

      stride = names.size.to_f / size
      Array.new(size) { |k| names[(k * stride).floor] }
    end

    def report_vectors(corpus)
      vectoriser = Vectoriser.new
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      documents = corpus.map { |name| vectoriser.call(name) }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      hashed_nnz = documents.sum { |d| d.hashed_ids.size } / documents.size.to_f
      exact_nnz = documents.sum { |d| d.exact_ids.size } / documents.size.to_f

      puts "Vectors"
      puts "  embedded in:                    #{elapsed.round(1)}s (#{(corpus.size / elapsed).round} names/s)"
      puts "  distinct features in corpus:    #{vectoriser.feature_count}"
      puts "  ...hashed into:                 #{EmbeddingGenerator::DIMENSIONS} dimensions"
      puts "  crowding (features/dimension):  #{(vectoriser.feature_count / EmbeddingGenerator::DIMENSIONS.to_f).round(1)}x"
      puts "  mean non-zero dims, hashed:     #{hashed_nnz.round(1)}"
      puts "  mean non-zero dims, exact:      #{exact_nnz.round(1)}"
      puts "  features lost to within-name collisions: #{(100 * (1 - hashed_nnz / exact_nnz)).round(2)}%"
      puts
      documents
    end

    def report_sweep(documents)
      puts "Pair census (#{WORKERS} workers)"
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = Sweep.new(documents, THRESHOLDS).run(workers: WORKERS)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      pairs = result[:pairs]

      puts "  pairs compared:  #{pairs} (in #{elapsed.round(1)}s)"
      puts "  mean |hashed - exact| cosine error: #{(result[:error_sum] / pairs).round(6)}"
      puts
      puts "  distribution of |hashed - exact|"
      edges = ERROR_BINS.map { |edge| "< #{edge}" } + [ ">= #{ERROR_BINS.last}" ]
      edges.each_with_index do |label, k|
        count = result[:error_bins][k]
        puts format("    %-10s %14d  %8.4f%%", label, count, 100.0 * count / pairs)
      end
      puts
      puts "  at each threshold t, over #{pairs} pairs"
      puts format("    %-8s %12s %12s %12s %14s %12s", "t", "hashed>=t", "exact>=t", "FALSE", "FALSE&exact<#{UNRELATED}", "MISSED")
      THRESHOLDS.each do |threshold|
        bucket = result[:thresholds][threshold.to_s.to_sym]
        puts format("    %-8s %12d %12d %12d %14d %12d",
                    threshold, bucket[:hashed], bucket[:exact], bucket[:false_match],
                    bucket[:unrelated_false_match], bucket[:missed])
      end
      puts
      THRESHOLDS.each do |threshold|
        bucket = result[:thresholds][threshold.to_s.to_sym]
        rate = bucket[:false_match].to_f / pairs
        per_test = bucket[:false_match] * 2.0 / documents.size
        puts format("    t=%s: false-match rate %.3e (1 in %s) — %.2f spurious neighbours per test",
                    threshold, rate, rate.zero? ? "-" : (1 / rate).round.to_s, per_test)
      end
      puts
      puts "  worst overstatements (hashed - exact), if any"
      if result[:worst].empty?
        puts "    none: no pair anywhere in the census was overstated by more than 0.2"
      else
        result[:worst].each do |entry|
          puts format("    +%.4f  hashed %.4f / exact %.4f", entry[:gap], entry[:hashed], entry[:exact])
          puts "      A: #{entry[:a]}"
          puts "      B: #{entry[:b]}"
        end
      end
    end
  end
end

EmbeddingCollisionAudit.run(ARGV) if $PROGRAM_NAME == __FILE__
