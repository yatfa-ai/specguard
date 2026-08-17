# frozen_string_literal: true

# Turns a string into an embedding vector. `Ingest::IdentityResolver` embeds the text standing for
# each test — an `@intent` declaration where there is one, the example's name where there is not —
# and `SpecIdentity` matches the result against the identities a repository already has.
#
# ## Contract
#
#   EmbeddingGenerator.call(text)        # => Array<Float>, exactly DIMENSIONS long
#   EmbeddingGenerator.embed_many(texts) # => Array<Array<Float>>, one per text, IN INPUT ORDER
#
# Anything that goes wrong with the provider — transport error, HTTP error, malformed body, a
# vector of the wrong size, a non-finite element — surfaces as EmbeddingGenerator::Error. Callers
# rescue one class and never see a Faraday exception.
#
# `.call` is the single-text entry point and `.embed_many` the batch one. They are two entry points
# to the same guarantees, not two behaviours: a text embedded through either arrives at the same
# vector, so batching is an I/O decision a caller may take without changing what it gets back.
#
# ## The provider
#
# **`VoyageProvider` is the only one, and there is no fallback.** `voyageai/voyage-4-lite` through
# OpenRouter, 1024 dimensions, over the network, for money. It replaced two implementations that
# used to sit here — in-process feature hashing, and OpenAI's endpoint — and the reason it replaced
# both is the same one: a second provider means vectors from two different functions of the text
# can reach one column, and no assertion anywhere catches a similarity computed across that seam.
# **Owner decision, 2026-08-17: one provider, one model, one width.**
#
# ## Swapping the provider
#
# `EmbeddingGenerator` is the interface; `VoyageProvider` is its implementation. Point it at any
# object answering `.call(text)`:
#
#   EmbeddingGenerator.provider = SomeOtherEmbedder
#   EmbeddingGenerator.provider = nil   # back to VoyageProvider
#
# This seam exists for the SUITE, not for a choice of vendor: `spec/support/embedding_generator.rb`
# installs a deterministic stub so that no spec reaches the network or needs a key. Production runs
# what this file ships and nothing else.
#
# `.call(text)` is the whole of what a provider must implement. `embed_many(texts)` is OPTIONAL: a
# provider that does not answer it is asked one text at a time and is none the wiser, which is what
# lets the batch entry point be a pure addition to an interface other people implement.
#
# The guarantees above hold *across* the seam: width validation, error wrapping and `configured?`
# live on this class, not in the provider, so swapping the provider cannot void them.
#
# ## Credentials
#
# ENV first, encrypted credentials second, and a PLACEHOLDER when neither is set — the same shape as
# SpecGuard::GithubOauth (config/initializers/omniauth.rb), for the same reason: the app boots and
# the suite runs green with no embedding API key present. `configured?` reports the truth so callers
# can say so rather than dead-ending. Nothing here talks to the network until `.call`.
#
#   export OPENROUTER_API_KEY=sk-or-v1-...
#
# or via `bin/rails credentials:edit`:
#
#   openrouter:
#     api_key: sk-or-v1-...
class EmbeddingGenerator
  Error = Class.new(StandardError)

  # `voyageai/voyage-4-lite`'s native width, and the width of every embedding column
  # (`halfvec(1024)`, db/schema.rb). Changing it is a migration plus a re-embed of every row, never
  # a config change.
  DIMENSIONS = 1024

  class << self
    attr_writer :provider

    # Resolved on every call rather than memoized, so a reload in development never leaves a
    # stale autoloaded class behind.
    def provider
      @provider || VoyageProvider
    end

    # The guarantees in the contract above belong to the *interface*, not to the provider —
    # DIMENSIONS is fixed by the column, so validating inside VoyageProvider would have guarded
    # only against a misbehaving vendor and not against a misbehaving provider.
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
    # The batch entry point, for the identity resolver: a page of changed tests is one provider
    # request instead of one per test. On a network provider that is the whole cost of a changed
    # 20,000-example suite, since every `.call` is an HTTPS round trip and a billed request.
    #
    # == The order is the contract
    #
    # Vectors come back positionally: `texts[i]` embedded to `vectors[i]`. Callers assign each
    # vector to the row whose text they contributed, so an order the provider merely happened to
    # preserve would attach the wrong history to the wrong test — silently, since every vector is a
    # perfectly valid vector. That is why the size check below is an error and not a truncation, and
    # why `VoyageProvider#fetch_many` sorts by the response's own `index` rather than trusting the
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
    # byte equality is treated as equivalence.
    #
    # ⚠️ `VoyageProvider` is that case — it sends the text as written — so **this answers `false` for
    # every pair of different strings in production**, and `Ingest::IdentityResolver#note_drift`, the
    # only caller, is inert. That is correct rather than merely tolerated: under a provider that does
    # not collapse punctuation, two spellings really are two different vectors and the drift really
    # is an edit. It is a live path only under a normalising provider, which this application no
    # longer ships.
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
    # Optional on the interface, with the CONSERVATIVE default. A provider that does not publish a
    # fingerprint gets **no caching at all**, not a default key: the two failure modes are not
    # comparable. No caching costs money and behaves exactly as this application did before the
    # cache existed. A guessed key — the class name, say — would be *wrong* the moment a provider
    # read a model from the environment, and the symptom is a vector from the previous model
    # silently attached to a test, which no assertion anywhere would catch. So the absence of an
    # answer is treated as a refusal, and refusal is free.
    #
    # ⚠️ **Computed on every call and never memoized**, for the same reason `.provider` is resolved
    # on every call. `VoyageProvider.model` reads `ENV["SPECGUARD_EMBEDDING_MODEL"]` each time it is
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

    # Delegated, so a provider needing no credentials at all reports the truth instead of
    # VoyageProvider's answer. A provider that does not implement the predicate has nothing to
    # configure, so it is ready by definition.
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
          # failure would surface as ActiveRecord::StatementInvalid — the one remaining way for
          # something to go wrong and not arrive as an Error.
          unless float.finite?
            raise Error, "embedding provider returned a non-finite value (#{float})"
          end
        end
      end
    rescue ArgumentError, TypeError => e
      raise Error, "embedding provider returned a non-numeric vector: #{e.message}"
    end
  end

  # The provider: `voyageai/voyage-4-lite`, reached through OpenRouter's OpenAI-compatible
  # `/v1/embeddings` endpoint.
  #
  # ## Why this model
  #
  # It returns 1024 dimensions natively — no `dimensions` parameter, no Matryoshka truncation, no
  # room for a deployment to ask for a width the column cannot hold. At $0.02 per million tokens a
  # full 20,000-example suite embeds for well under a cent, which is what makes a paid provider the
  # default at all.
  #
  # ## Why through OpenRouter rather than Voyage directly
  #
  # One account and one key for whatever this application ends up calling. The cost is that
  # OpenRouter does not list embedding models in its `/api/v1/models` catalogue, so the model name
  # below is not discoverable from the API and is pinned here instead — if it is ever retired, this
  # provider starts raising rather than quietly falling back to something of a different width.
  # There is no fallback by design; see the class-level note above.
  #
  # ## HTTP client
  #
  # Faraday directly. The request is one JSON POST and one JSON response, which is not enough to
  # justify a vendor SDK, and the SDK this used to hold was OpenAI's — a dependency named for a
  # vendor this application no longer calls.
  class VoyageProvider
    PLACEHOLDER = "specguard-embeddings-not-configured"
    DEFAULT_MODEL = "voyageai/voyage-4-lite" # 1024 dimensions — matches EmbeddingGenerator::DIMENSIONS
    ENDPOINT = "https://openrouter.ai/api/v1/embeddings"
    # Long enough for a full page of texts in one request, short enough that a hung upstream fails
    # the job rather than holding a Solid Queue worker for the rest of the day.
    TIMEOUT_SECONDS = 60
    OPEN_TIMEOUT_SECONDS = 10

    class << self
      def call(text)
        new(text).call
      end

      # The one place batching is worth implementing: the endpoint takes an ARRAY of inputs in a
      # single request natively, so a page of 500 changed tests is one HTTPS round trip and one
      # billed request rather than 500 of each.
      def embed_many(texts)
        new(texts).call_many
      end

      def api_key
        ENV["OPENROUTER_API_KEY"].presence || credential(:api_key) || PLACEHOLDER
      end

      def model
        ENV["SPECGUARD_EMBEDDING_MODEL"].presence || DEFAULT_MODEL
      end

      def configured?
        api_key != PLACEHOLDER
      end

      # What this provider's vectors are a function of: the gateway and the model, and nothing else.
      # Two models are different functions of the same text, so `SPECGUARD_EMBEDDING_MODEL` moving
      # must make every entry written under the old one unreadable — and does, because the key stops
      # matching. Read through `.model` rather than from the constant, so an environment override is
      # included; asked per call rather than memoized, because `.model` itself is (see
      # `EmbeddingGenerator.fingerprint`).
      #
      # **Not the API key**, deliberately. Two deployments holding different keys against the same
      # model get the same vectors for the same text, so including the key would partition the
      # cache by something that does not change its contents — and would write a credential-derived
      # value into a database column, which is a leak with no upside.
      #
      # Prefixed with the gateway so that a future provider defaulting to the same model name cannot
      # collide with this one's entries. It also retires every `openai:`-prefixed entry the previous
      # provider wrote, which is the correct outcome: those are 1536-wide vectors from a different
      # model and nothing may read them again.
      def fingerprint
        "openrouter:#{model}"
      end

      private

      def credential(key)
        Rails.application.credentials.dig(:openrouter, key).presence
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
    # (EmbeddingGenerator.validate) so that the provider is held to them rather than trusted on them.
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

      raise Error, "embedding provider is not configured — set OPENROUTER_API_KEY " \
                   "(or credentials openrouter.api_key)"
    end

    def fetch
      embeddings.dig("data", 0, "embedding")
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
    end

    # One POST, and every way it can fail arrives as an Error.
    #
    # The status check is explicit because Faraday does not raise on 4xx/5xx unless the
    # `raise_error` middleware is installed, and a 429 whose body has no `data` key would otherwise
    # surface as the interface's "returned no vector (got NilClass)" — true, but not the reason.
    # The upstream's own message is carried through instead, since a quota or a retired model is
    # something the operator has to read.
    def embeddings
      response = connection.post(ENDPOINT) do |request|
        request.body = { model: self.class.model, input: @input }
      end

      unless response.success?
        raise Error, "embedding provider failed: HTTP #{response.status} #{error_message(response)}"
      end

      response.body
    rescue Faraday::Error => e
      # A narrower rescue than the interface's, kept for the better message. Deliberately not
      # re-raising the transport exception: callers rescue EmbeddingGenerator::Error.
      raise Error, "embedding provider failed: #{e.message}"
    end

    # OpenRouter reports failures as `{"error": {"message": …}}`; a gateway between us and it may
    # answer with HTML instead, so the body is only read as a hash when it is one and the raw body
    # is the fallback rather than an exception on top of an exception.
    def error_message(response)
      body = response.body

      return body.dig("error", "message") || body.to_s if body.is_a?(Hash)

      body.to_s.truncate(200)
    end

    def connection
      Faraday.new do |faraday|
        faraday.request :json
        faraday.response :json
        faraday.headers["Authorization"] = "Bearer #{self.class.api_key}"
        faraday.options.timeout = TIMEOUT_SECONDS
        faraday.options.open_timeout = OPEN_TIMEOUT_SECONDS
      end
    end
  end
end
