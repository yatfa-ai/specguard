# frozen_string_literal: true

require "digest"

# Turns a string into an embedding vector. Nothing in the application calls it yet — see the
# *Overview & Architecture* article for what is actually wired. It exists for the duplicate-
# detection engine that is meant to rest on it: ingestion would embed "{entity} {action} {behavior}"
# for every intent, and a lookup would embed the text it is asking about and compare.
#
# ## Contract
#
#   EmbeddingGenerator.call(text) # => Array<Float>, exactly DIMENSIONS long
#
# Anything that goes wrong with the provider — transport error, HTTP error, malformed body, a
# vector of the wrong size, a non-finite element — surfaces as EmbeddingGenerator::Error. Callers
# (the ingestion job, IntentChecker) rescue one class and never see a Faraday or OpenAI exception.
#
# ## Swapping the provider
#
# `EmbeddingGenerator` is the interface; `LocalProvider` is merely the default implementation.
# Point it at any object answering `.call(text)`:
#
#   EmbeddingGenerator.provider = EmbeddingGenerator::OpenAIProvider
#   EmbeddingGenerator.provider = nil   # back to the default
#
# Callers are unaffected — they only ever say `EmbeddingGenerator.call(text)`. This is the seam the
# suite uses to install a deterministic stub (spec/support/embedding_generator.rb).
#
# The guarantees above hold *across* the seam: width validation, error wrapping and `configured?`
# live on this class, not in any provider, so swapping the provider cannot void them.
#
# ## Which provider is the default, and why
#
# `LocalProvider` — in-process Ruby feature hashing, no credentials, no network, nothing to host.
# **Owner decision, 2026-08-08: SpecGuard does not pay for embeddings.** `OpenAIProvider` stays as
# the interface's other implementation and is installed explicitly by whoever wants to pay for it:
#
#   EmbeddingGenerator.provider = EmbeddingGenerator::OpenAIProvider   # in an initializer
#
# The trade is stated on LocalProvider: it measures *lexical* overlap, not meaning. Read that
# before relying on a similarity score for anything user-facing.
#
# ## Credentials
#
# Only `OpenAIProvider` needs any. ENV first, encrypted credentials second, and a PLACEHOLDER when
# neither is set — the same shape as SpecGuard::GithubOauth (config/initializers/omniauth.rb), for
# the same reason: the app boots and the suite runs green with no embedding API key present.
# `configured?` reports the truth so callers can say so rather than dead-ending. Nothing here talks
# to the network until `.call`, and with the default provider nothing talks to it at all.
#
#   export OPENAI_API_KEY=sk-...
#
# or via `bin/rails credentials:edit`:
#
#   openai:
#     api_key: sk-...
class EmbeddingGenerator
  Error = Class.new(StandardError)

  # Fixed by the `spec_intents.embedding` column and its HNSW index (db/schema.rb). Changing it is
  # a migration plus a re-embed of every row, never a config change.
  DIMENSIONS = 1536

  class << self
    attr_writer :provider

    # Resolved on every call rather than memoized, so a reload in development never leaves a
    # stale autoloaded class behind.
    def provider
      @provider || LocalProvider
    end

    # The guarantees in the contract above belong to the *interface*, not to any one provider —
    # DIMENSIONS is fixed by the column, so validating inside OpenAIProvider would have guarded
    # only against a misbehaving OpenAI and not against a misbehaving provider.
    def call(text)
      validate(provider.call(text))
    rescue Error
      raise # already ours: keep the provider's more specific message.
    rescue StandardError => e
      raise Error, "embedding provider failed: #{e.message}"
    end

    # Delegated, so a provider needing no credentials at all (a local Ollama embedder) reports the
    # truth instead of OpenAI's answer. A provider that does not implement the predicate has
    # nothing to configure, so it is ready by definition.
    def configured?
      provider.respond_to?(:configured?) ? provider.configured? : true
    end

    private

    def validate(vector)
      unless vector.is_a?(Array)
        raise Error, "embedding provider returned no vector (got #{vector.class})"
      end

      unless vector.size == DIMENSIONS
        raise Error, "embedding provider returned #{vector.size} dimensions, expected #{DIMENSIONS}"
      end

      vector.map do |value|
        Float(value).tap do |float|
          # pgvector rejects these at INSERT ("NaN not allowed in vector"), so without this the
          # failure would surface in slice 3 as ActiveRecord::StatementInvalid — the one remaining
          # way for something to go wrong and not arrive as an Error.
          unless float.finite?
            raise Error, "embedding provider returned a non-finite value (#{float})"
          end
        end
      end
    rescue ArgumentError, TypeError => e
      raise Error, "embedding provider returned a non-numeric vector: #{e.message}"
    end
  end

  # The default provider: feature hashing, in-process, in pure Ruby. No API key, no network call,
  # no model to host, no per-embedding cost. Ported from the same approach yatfa has run in
  # production; the shape below is that algorithm, not a novel one.
  #
  # ## How a string becomes 1536 floats
  #
  #   1. Downcase and split into alphanumeric word tokens, then rejoin with single spaces. This
  #      drops punctuation and collapses whitespace, so "Order#checkout" and "Order  checkout"
  #      embed identically.
  #   2. Take two kinds of feature from that: the words themselves, and every 3-character n-gram of
  #      the rejoined string. N-grams are what make the vector tolerate a suffix, a plural or a
  #      typo — "expired" and "expires" share four of their five trigrams.
  #   3. SHA-256 each feature. The first 8 bytes pick the dimension it lands in; a *different* 4
  #      bytes pick a signed weight, so index and weight are independent rather than two views of
  #      the same number.
  #   4. Accumulate — several features legitimately land in the same dimension (see the collision
  #      audit below) and their weights sum.
  #   5. L2-normalise, so pgvector's `<=>` cosine operator ranks sensibly and every vector is
  #      directly comparable to every other.
  #
  # Signed weights are the load-bearing part of step 3: with random signs, two colliding features
  # cancel as often as they reinforce, so a collision perturbs an inner product instead of
  # inflating it. Weights that were all positive would make every collision a false match.
  #
  # ## Determinism
  #
  # Same text in, same vector out. Nothing here reads a seed, a clock or a random source: the vector
  # is a pure function of the string, so it is byte-identical across examples, processes, restarts
  # and machines running the same platform. That is what lets the identity half of the product work
  # at all — an unchanged test name embeds to an unchanged vector between two runs a week apart.
  #
  # The claim stops at the platform boundary, and deliberately. Every step up to the weight is exact
  # integer work — SHA-256, byte slicing, modulo — but `Math.sin` delegates to the host's libm, and
  # glibc, musl and Darwin are not guaranteed to agree in the last ULP for the same double. So a
  # change of C library or CPU architecture (a base image moving from glibc to musl, say) may perturb
  # the low bits of a weight even though the algorithm is unchanged. Within one deployment platform
  # the output is exact and reproducible; *across* platforms, treat it as reproducible to within
  # floating-point rounding rather than bit-for-bit.
  #
  # One deviation from a literal reading of the reference, and the reason for it: the weight is
  # `sin` of a hash-derived *phase in [0, 2π)*, not `sin` of the raw hash. `Math.sin` of a number
  # the size of a SHA-256 digest is not portable — argument reduction that far out is
  # libm-specific, and a 256-bit integer does not survive `to_f` at all (it is `Infinity`). Keeping
  # the argument inside one period preserves the property that matters — a deterministic,
  # pseudo-random, signed weight per feature — and makes it computable at all, to within the
  # platform bound stated above.
  #
  # ## What this measures, and what it does not
  #
  # **Lexical overlap, not meaning.** Two tests whose names share vocabulary or character n-grams
  # match; two tests describing the same behaviour in entirely different words do not. "rejects
  # checkout on an expired card" and "rejects checkout when the card is expired" cluster. "returns
  # 402 payment required" and "rejects the transaction" do not. This is a property of the engine,
  # not a defect in it, and it lands differently on the product's two halves: test *identity*
  # (same name → same vector) is served exactly, while duplicate *clustering* only ever sees the
  # duplicates that were phrased alike. Do not read a cosine from this provider as a claim about
  # semantics.
  #
  # ## Collisions
  #
  # 1536 buckets is a small target for an unbounded feature space, so distinct features do land on
  # the same dimension. `script/embedding_collision_audit.rb` measures what that costs at this
  # product's scale — 20,000 real RSpec example names from a single codebase — printing the corpus
  # it used, the method and the result; ticket SPGD-252 records the run it was measured on. Read
  # that result before choosing any similarity threshold; it is the evidence a threshold should be
  # picked from, and the script re-derives it on whatever corpus you point it at.
  class LocalProvider
    NGRAM_SIZE = 3

    # The hash-to-phase resolution: 2**32 distinct weights per feature, taken from bytes 8..11 of
    # the digest.
    PHASE_STEPS = 2**32
    PHASE_STEP_RADIANS = (2 * Math::PI) / PHASE_STEPS

    WORD = /[[:alnum:]]+/

    class << self
      def call(text)
        new(text).call
      end

      # Nothing to configure — that is the entire point of this provider. Stated rather than
      # inherited from the interface's default so that "needs no credentials" is legible here,
      # where someone comparing the two providers is looking.
      def configured?
        true
      end
    end

    def initialize(text)
      @text = text.to_s
    end

    # Returns the raw vector. Width and element types are the interface's business
    # (EmbeddingGenerator.validate) so that every provider is held to them, not just this one.
    def call
      vector = Array.new(DIMENSIONS, 0.0)

      features.each do |feature|
        index, phase = Digest::SHA256.digest(feature).unpack("Q>N")
        vector[index % DIMENSIONS] += Math.sin(phase * PHASE_STEP_RADIANS)
      end

      unit_normalise(vector)
    end

    # The features this text hashes into: its words, then its 3-character n-grams, namespaced
    # apart so the word "the" and the trigram "the" are not the same feature counted twice.
    #
    # Public because `script/embedding_collision_audit.rb` measures the *shipped* tokenisation
    # rather than a second copy of it that could quietly drift from this one. Nothing in the
    # request path calls it.
    def features
      words.map { |word| "w:#{word}" } + ngrams.map { |ngram| "g:#{ngram}" }
    end

    private

    def words
      @text.downcase.scan(WORD)
    end

    def ngrams
      subject = words.join(" ")
      return [] if subject.length < NGRAM_SIZE

      (0..subject.length - NGRAM_SIZE).map { |offset| subject[offset, NGRAM_SIZE] }
    end

    # A text with no alphanumeric content has no features and so no direction to point in. Zero is
    # the honest answer: it is finite, it is the right width, and pgvector's cosine operator
    # returns NaN distance against it rather than a confident wrong neighbour.
    def unit_normalise(vector)
      magnitude = Math.sqrt(vector.sum { |value| value * value })
      return vector if magnitude.zero?

      vector.map { |value| value / magnitude }
    end
  end

  # The other implementation: OpenAI's embeddings endpoint. Costs money and requires a key, so it
  # is not the default — install it explicitly (see "Which provider is the default" above).
  class OpenAIProvider
    PLACEHOLDER = "specguard-embeddings-not-configured"
    DEFAULT_MODEL = "text-embedding-3-small" # 1536 dimensions — matches EmbeddingGenerator::DIMENSIONS

    class << self
      def call(text)
        new(text).call
      end

      def api_key
        ENV["OPENAI_API_KEY"].presence || credential(:api_key) || PLACEHOLDER
      end

      def model
        ENV["SPECGUARD_EMBEDDING_MODEL"].presence || DEFAULT_MODEL
      end

      def configured?
        api_key != PLACEHOLDER
      end

      private

      def credential(key)
        Rails.application.credentials.dig(:openai, key).presence
      rescue StandardError
        nil
      end
    end

    def initialize(text)
      @text = text
    end

    # Returns the raw vector. Width and element types are the interface's business
    # (EmbeddingGenerator.validate) so that every provider is held to them, not just this one.
    def call
      unless self.class.configured?
        raise Error, "embedding provider is not configured — set OPENAI_API_KEY (or credentials openai.api_key)"
      end

      fetch
    end

    private

    def fetch
      response = client.embeddings(parameters: { model: self.class.model, input: @text })
      response.dig("data", 0, "embedding")
    rescue Faraday::Error, ::OpenAI::Error => e
      # A narrower rescue than the interface's, kept for the better message. Deliberately not
      # re-raising the transport exception: callers rescue EmbeddingGenerator::Error.
      raise Error, "embedding provider failed: #{e.message}"
    end

    def client
      ::OpenAI::Client.new(access_token: self.class.api_key)
    end
  end
end
