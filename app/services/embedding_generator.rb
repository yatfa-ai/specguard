# frozen_string_literal: true

require "digest"

# Turns a string into an embedding vector. Nothing in the application calls it yet — see the
# *Overview & Architecture* article for what is actually wired. It exists for the duplicate-
# detection engine that is meant to rest on it: ingestion would embed "{entity} {action} {behavior}"
# for every intent, and a lookup would embed the text it is asking about and compare.
#
# ## Contract
#
#   EmbeddingGenerator.call(text)        # => Array<Float>, exactly DIMENSIONS long
#   EmbeddingGenerator.embed_many(texts) # => Array<Array<Float>>, one per text, IN INPUT ORDER
#
# Anything that goes wrong with the provider — transport error, HTTP error, malformed body, a
# vector of the wrong size, a non-finite element — surfaces as EmbeddingGenerator::Error. Callers
# (the ingestion job, IntentChecker) rescue one class and never see a Faraday or OpenAI exception.
#
# `.call` is the single-text entry point and `.embed_many` the batch one. They are two entry points
# to the same guarantees, not two behaviours: a text embedded through either arrives at the same
# vector, so batching is an I/O decision a caller may take without changing what it gets back.
#
# ## Swapping the provider
#
# `EmbeddingGenerator` is the interface; `LocalProvider` is merely the default implementation.
# Point it at any object answering `.call(text)`:
#
#   EmbeddingGenerator.provider = EmbeddingGenerator::OpenAIProvider
#   EmbeddingGenerator.provider = nil   # back to the default
#
# `.call(text)` is the whole of what a provider must implement. `embed_many(texts)` is OPTIONAL: a
# provider that does not answer it is asked one text at a time and is none the wiser, which is what
# lets the batch entry point be a pure addition to an interface other people implement. Overriding
# it is worth it only where a batch costs less than the sum of its parts — that is one HTTP request
# instead of N for `OpenAIProvider`, and nothing at all for an in-process embedder like
# `LocalProvider`, whose N calls ARE the cheapest available shape.
#
# Callers are unaffected — they only ever say `EmbeddingGenerator.call(text)` or, for a page of
# them, `EmbeddingGenerator.embed_many(texts)`. This is the seam the suite uses to install a
# deterministic stub (spec/support/embedding_generator.rb).
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

    # @param texts [Array<String>] the texts to embed
    # @return [Array<Array<Float>>] one validated vector per text, **in input order** and of the
    #   same length as `texts`.
    # @raise [Error] if the batch could not be embedded — the same one class {.call} raises.
    #
    # The batch entry point, added for the identity resolver: a page of changed tests is one
    # provider request instead of one per test. It buys nothing on the default provider (hashing in
    # this process, N times, is already the cheapest shape) and it is the whole cost of a changed
    # 20,000-example suite on `OpenAIProvider`, which pays an HTTPS round trip per `.call`.
    #
    # == The order is the contract
    #
    # Vectors come back positionally: `texts[i]` embedded to `vectors[i]`. Callers assign each
    # vector to the row whose text they contributed, so an order the provider merely happened to
    # preserve would attach the wrong history to the wrong test — silently, since every vector is a
    # perfectly valid vector. That is why the size check below is an error and not a truncation, and
    # why `OpenAIProvider#fetch_many` sorts by the response's own `index` rather than trusting the
    # order the array arrived in.
    #
    # == Failure is all-or-nothing HERE, and per-row one level up
    #
    # This raises for the batch rather than returning nils for the inputs that failed, because a
    # provider that failed the request has not told us WHICH input it failed on — one bad text and
    # a dropped connection arrive identically. Callers that need per-row containment fall back to
    # `.call` per text on this error and let each text fail on its own (see
    # `Ingest::IdentityResolver#embed_page`, which is what keeps SPGD-367's "one unembeddable
    # example does not abandon the other 19,999" true through a batch).
    def embed_many(texts)
      texts = Array(texts)
      return [] if texts.empty?
      # One text at a time, through {.call} rather than through the provider — so a provider with no
      # batch of its own is held to exactly the guarantees it is held to everywhere else, and so a
      # caller that has stubbed `.call` still sees its stub. Already validated, so it returns here.
      return texts.map { |text| call(text) } unless provider.respond_to?(:embed_many)

      validate_all(provider.embed_many(texts), texts.size)
    rescue Error
      raise # already ours: keep the provider's more specific message.
    rescue StandardError => e
      raise Error, "embedding provider failed: #{e.message}"
    end

    # @return [Boolean] whether these two texts are the SAME INPUT as far as the current provider is
    #   concerned — different bytes that it reduces to one identical vector.
    #
    # **Not a similarity question and deliberately not answerable by one.** `Ingest::IdentityResolver`
    # needs to tell "this description gained a comma" apart from "this description was edited", and a
    # cosine cannot: the first is exactly 1.0 in theory and a float comparison against 1.0 in
    # practice, while the second lands wherever it lands. The provider knows which of its inputs
    # collapse together because it is the thing that collapses them, so it is asked rather than
    # inferred from a distance.
    #
    # Optional on the interface, and the default is the CONSERVATIVE one: a provider that does not
    # publish a normalisation makes no promise that two different strings embed alike, so nothing but
    # byte equality is treated as equivalence. `OpenAIProvider` is that case — it sends the text as
    # written — and a caller acting on a `false` here does exactly what it did before this method
    # existed. Only `LocalProvider`, which really does drop punctuation and collapse whitespace
    # (see its `.normalize`), can answer `true` for two different strings.
    def equivalent?(one, other)
      return true if one == other
      return false unless provider.respond_to?(:normalize)

      provider.normalize(one) == provider.normalize(other)
    end

    # @return [String, nil] a value that changes whenever the vectors this generator produces would
    #   change, or nil when the current provider will not say.
    #
    # **The cache key's first half**, and the reason `EmbeddingCacheEntry` can be deployment-global
    # without ever serving a wrong vector. A cached vector is only reusable if the thing that would
    # produce it again is the same thing; this is the provider's own claim about what "the same
    # thing" means for it.
    #
    # Optional on the interface, with the CONSERVATIVE default — the shape `#equivalent?` and
    # `#configured?` above use. A provider that does not publish a fingerprint gets **no caching at
    # all**, not a default key: the two failure modes are not comparable. No caching costs money and
    # behaves exactly as this application did before the cache existed. A guessed key — the class
    # name, say — would be *wrong* the moment a provider read a model from the environment, and the
    # symptom is a vector from the previous model silently attached to a test, which no assertion
    # anywhere would catch. So the absence of an answer is treated as a refusal, and refusal is
    # free.
    #
    # ⚠️ **Computed on every call and never memoized**, for the same reason `.provider` is resolved
    # on every call. `OpenAIProvider.model` reads `ENV["SPECGUARD_EMBEDDING_MODEL"]` each time it is
    # asked, so a fingerprint captured once at boot would keep naming the model the process started
    # with and would go on authorising cache hits from it after the deployment had moved. This is a
    # correctness requirement, not a style preference: a memoized fingerprint is exactly the
    # "unreadable rather than stale" guarantee inverted.
    #
    # `presence` so that a provider answering `""` is treated as having refused rather than as
    # having a key that every other empty-string provider would share.
    #
    # **It must never carry the credential.** The value is written to a database column, is
    # deployment-global, and identifies a *configuration*, not an authorisation — two deployments
    # with different API keys and the same model produce identical vectors and should share entries.
    def fingerprint
      return nil unless provider.respond_to?(:fingerprint)

      provider.fingerprint.presence
    end

    # Delegated, so a provider needing no credentials at all (a local Ollama embedder) reports the
    # truth instead of OpenAI's answer. A provider that does not implement the predicate has
    # nothing to configure, so it is ready by definition.
    def configured?
      provider.respond_to?(:configured?) ? provider.configured? : true
    end

    private

    # The width and finiteness of every vector, plus the one guarantee a batch adds to a single
    # embed: that there is exactly one vector per input. A short array is refused rather than
    # zipped, because zipping it would hand the caller a nil for a text the provider never answered
    # about — and, worse, would slide every vector after the missing one onto the wrong text.
    def validate_all(vectors, expected)
      unless vectors.is_a?(Array)
        raise Error, "embedding provider returned no vectors (got #{vectors.class})"
      end

      unless vectors.size == expected
        raise Error, "embedding provider returned #{vectors.size} vectors for #{expected} texts"
      end

      vectors.map { |vector| validate(vector) }
    end

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

      # The form step 1 above reduces a text to, and therefore the ONLY thing the vector is a
      # function of: `#features` reads its words and its n-grams off this string and nothing else
      # touches `@text`. So two texts with the same normalised form embed identically — not
      # approximately, not at cosine 1.0 within tolerance, but to the same array of floats.
      #
      # Public because that equality is a fact callers need and cannot safely re-derive:
      # `EmbeddingGenerator.equivalent?` is the interface-level question and this is this provider's
      # answer to it. A second copy of the tokenisation elsewhere would drift from this one and the
      # symptom would be an identity quietly re-pointed at text that does not embed the same.
      def normalize(text)
        text.to_s.downcase.scan(WORD).join(" ")
      end

      # Nothing to configure — that is the entire point of this provider. Stated rather than
      # inherited from the interface's default so that "needs no credentials" is legible here,
      # where someone comparing the two providers is looking.
      def configured?
        true
      end

      # **No `fingerprint`, and its absence is the decision.** `EmbeddingGenerator.fingerprint`
      # reads a provider that does not publish one as a refusal to be cached, which is the right
      # answer for this one: the vector is a hash computed in this process, so a cache hit would
      # replace arithmetic with a database round trip and a table write. It would be slower than
      # the thing it is caching, and it would fill a deployment-global table with entries that can
      # never repay their own storage.
      #
      # It is stated as a comment rather than a method because there is no method to write — but it
      # is stated, because "the default provider is uncached" looks like an oversight otherwise,
      # and because it is what keeps this application's shipped behaviour byte-identical to what it
      # was before the cache existed. `OpenAIProvider`, where a repeat embed is a billed HTTPS
      # round trip, is the case the cache exists for and the one that publishes a key.
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
      normalized.split(" ")
    end

    def ngrams
      return [] if normalized.length < NGRAM_SIZE

      (0..normalized.length - NGRAM_SIZE).map { |offset| normalized[offset, NGRAM_SIZE] }
    end

    # Both feature kinds are read off the SAME normalised string rather than each re-deriving it,
    # which is what makes `.normalize` the whole of what this vector depends on rather than a third
    # spelling of the tokenisation that happens to agree with the other two today.
    def normalized
      @normalized ||= self.class.normalize(@text)
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

      # The one place batching is worth implementing: OpenAI's embeddings endpoint takes an ARRAY of
      # inputs in a single request natively, so a page of 500 changed tests is one HTTPS round trip
      # and one billed request rather than 500 of each. `ruby-openai` forwards the parameters hash
      # verbatim, so this is the same call with a different `input`.
      def embed_many(texts)
        new(texts).call_many
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

      # What this provider's vectors are a function of: the vendor and the model, and nothing else.
      # `text-embedding-3-small` and `text-embedding-3-large` are different functions of the same
      # text, so `SPECGUARD_EMBEDDING_MODEL` moving must make every entry written under the old one
      # unreadable — and does, because the key stops matching. Read through `.model` rather than
      # from the constant, so an environment override is included; asked per call rather than
      # memoized, because `.model` itself is (see `EmbeddingGenerator.fingerprint`).
      #
      # **Not the API key**, deliberately. Two deployments holding different keys against the same
      # model get the same vectors for the same text, so including the key would partition the
      # cache by something that does not change its contents — and would write a credential-derived
      # value into a database column, which is a leak with no upside. `PLACEHOLDER` is likewise not
      # consulted: an unconfigured provider raises at `#call` long before anything is cached, so
      # there is nothing to protect against here.
      #
      # Prefixed with the vendor so that a future provider defaulting to the same model name cannot
      # collide with this one's entries.
      def fingerprint
        "openai:#{model}"
      end

      private

      def credential(key)
        Rails.application.credentials.dig(:openai, key).presence
      rescue StandardError
        nil
      end
    end

    # @param input [String, Array<String>] one text for {#call}, a page of them for {#call_many}.
    #   Named for what the endpoint calls it, because it is passed straight through as that
    #   parameter and the endpoint accepts either shape.
    def initialize(input)
      @input = input
    end

    # Returns the raw vector. Width and element types are the interface's business
    # (EmbeddingGenerator.validate) so that every provider is held to them, not just this one.
    def call
      require_configuration

      fetch
    end

    # Returns the raw vectors, one per input text, in input order. Same request, same rescue, same
    # division of labour with the interface — only the response is read as a page rather than as a
    # single row.
    def call_many
      require_configuration

      fetch_many
    end

    private

    def require_configuration
      return if self.class.configured?

      raise Error, "embedding provider is not configured — set OPENAI_API_KEY (or credentials openai.api_key)"
    end

    def fetch
      embeddings.dig("data", 0, "embedding")
    rescue Faraday::Error, ::OpenAI::Error => e
      # A narrower rescue than the interface's, kept for the better message. Deliberately not
      # re-raising the transport exception: callers rescue EmbeddingGenerator::Error.
      raise Error, "embedding provider failed: #{e.message}"
    end

    # **Sorted by the response's own `index`, not read in arrival order.** The endpoint documents
    # that each element of `data` carries the position of the input it answers, and the interface's
    # order contract is the thing a caller cannot check for itself — a mis-ordered page would attach
    # every test's history to its neighbour and every vector would still validate. Sorting by the
    # field that states the answer costs one pass and makes the guarantee ours rather than the
    # vendor's. `each_with_index` supplies the fallback key, so a body that omits `index` degrades to
    # arrival order rather than collapsing every element onto the same sort key.
    def fetch_many
      rows = embeddings["data"]
      return rows unless rows.is_a?(Array)

      rows.each_with_index.sort_by { |row, position| row["index"] || position }
          .map { |row, _position| row["embedding"] }
    rescue Faraday::Error, ::OpenAI::Error => e
      raise Error, "embedding provider failed: #{e.message}"
    end

    def embeddings
      client.embeddings(parameters: { model: self.class.model, input: @input })
    end

    def client
      ::OpenAI::Client.new(access_token: self.class.api_key)
    end
  end
end
