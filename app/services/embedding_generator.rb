# frozen_string_literal: true

# Turns a string into an embedding vector. The whole duplicate-detection engine rests on this:
# ingestion embeds "{entity} {action} {behavior}" for every intent, and a lookup embeds the text it
# is asking about and compares. (Both of those callers are still unbuilt — see the *Overview &
# Architecture* article for what is actually wired.)
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
# `EmbeddingGenerator` is the interface; `OpenAIProvider` is merely the default implementation.
# Point it at any object answering `.call(text)`:
#
#   EmbeddingGenerator.provider = MyLocalOllamaEmbedder
#   EmbeddingGenerator.provider = nil   # back to the default
#
# Callers are unaffected — they only ever say `EmbeddingGenerator.call(text)`. This is the seam the
# suite uses to install a deterministic stub (spec/support/embedding_generator.rb).
#
# The guarantees above hold *across* the seam: width validation, error wrapping and `configured?`
# live on this class, not in any provider, so swapping the provider cannot void them.
#
# ## Credentials
#
# ENV first, encrypted credentials second, and a PLACEHOLDER when neither is set — the same shape
# as SpecGuard::GithubOauth (config/initializers/omniauth.rb), for the same reason: the app boots
# and the suite runs green with no embedding API key present. `configured?` reports the truth so
# callers can say so rather than dead-ending. Nothing here talks to the network until `.call`.
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
      @provider || OpenAIProvider
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

  # The default provider: OpenAI's embeddings endpoint.
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
