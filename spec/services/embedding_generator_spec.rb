# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmbeddingGenerator do
  # Swap the whole ENV key rather than stubbing ENV#[] — a `with`-constrained partial double on ENV
  # breaks every other ENV read in the stack.
  def with_api_key(value, &) = with_env("OPENROUTER_API_KEY", value, &)

  # The general form of the above, for the second key `VoyageProvider` reads. Same reasoning, and
  # the same restore-in-`ensure` so a raising example cannot leak the value into the next one.
  def with_env(key, value)
    original = ENV[key]
    ENV[key] = value
    yield
  ensure
    ENV[key] = original
  end

  describe ".call" do
    # @intent: { entity: "EmbeddingGenerator", action: "embed a single text", behavior: "one call returns an Array of 1024 Floats", layer: "unit" }
    it "returns a vector of exactly 1024 floats" do
      vector = described_class.call("Order checkout returns 402 payment required on expired card")

      expect(vector).to be_an(Array)
      expect(vector.size).to eq(1024)
      expect(vector).to all(be_a(Float))
    end

    # @intent: { entity: "EmbeddingGenerator", action: "declare DIMENSIONS", behavior: "the constant stays 1024 matching the halfvec(1024) column so width drift fails here rather than at INSERT", layer: "unit" }
    it "pins DIMENSIONS to the spec_intents.embedding column width" do
      # Not a tautology: the column and its HNSW index are `halfvec(1024)`, so a change here without
      # a migration would fail at INSERT time instead of here.
      expect(described_class::DIMENSIONS).to eq(1024)
      expect(described_class.call("anything").size).to eq(described_class::DIMENSIONS)
    end
  end

  # The batch entry point. What it exists for is one provider REQUEST per page of changed tests
  # rather than one per test — the last of `Ingest::IdentityResolver`'s per-row costs — so the
  # figure every example here is really about is how many times the provider was asked anything.
  describe ".embed_many" do
    # A provider that has no batch of its own, which is the ordinary case and the one the interface
    # has to carry for it. Counts BOTH shapes, so "asked once per text" and "asked once for the
    # page" are distinguishable rather than inferred from a single number.
    def install_counting_provider(batching: false)
      provider = Class.new do
        class << self
          attr_reader :texts, :batches

          def call(text)
            (@texts ||= []) << text
            LexicalEmbeddingProvider.call(text)
          end
        end
      end

      if batching
        provider.define_singleton_method(:embed_many) do |texts|
          @batches = (@batches || 0) + 1
          texts.map { |text| LexicalEmbeddingProvider.call(text) }
        end
      end

      described_class.provider = provider
    end

    let(:texts) do
      ["Order#checkout rejects an expired card",
       "User#save refuses a duplicate email",
       "Cart#add appends the item to the cart"]
    end

    # An in-process provider, so these examples are about the interface's dispatch and not about a
    # stubbed HTTP client. `LexicalEmbeddingProvider` is spec support (spec/support/lexical_embeddings.rb)
    # and is deliberately NOT what the application ships — see its header.
    before { described_class.provider = LexicalEmbeddingProvider }

    # @intent: { entity: "EmbeddingGenerator", action: "embed a page of texts", behavior: "one vector per text comes back in input order, positionally matching .call of each same text", layer: "unit" }
    it "returns one vector per text, in input order" do
      # **The order IS the contract.** Callers assign vectors positionally, so a page returned in
      # any other order attaches one test's history to another test — silently, because every
      # vector is a perfectly valid vector. Asserted against `.call` of the SAME text rather than
      # against a fixture, so it is the interface's own answer that has to line up.
      expect(described_class.embed_many(texts)).to eq(texts.map { |text| described_class.call(text) })
    end

    # @intent: { entity: "EmbeddingGenerator", action: "embed a page of texts", behavior: "a provider without embed_many is served by mapping .call across the texts, each text asked exactly once", layer: "unit" }
    it "is exactly a map of .call for a provider that has no batch of its own" do
      # The default implementation, stated as an equivalence rather than as an implementation
      # detail: a provider written before this entry point existed answers a batch correctly and
      # without knowing anything about it.
      install_counting_provider

      vectors = described_class.embed_many(texts)

      expect(described_class.provider.texts).to eq(texts)
      expect(vectors).to eq(texts.map { |text| LexicalEmbeddingProvider.call(text) })
    end

    # @intent: { entity: "EmbeddingGenerator", action: "embed a page of texts", behavior: "a batching provider receives a single embed_many call for the whole page and zero per-text calls", layer: "unit" }
    it "asks a batching provider ONCE for the whole page, and never per text" do
      # The win itself, for the only provider shape where it is a win: one request, not three.
      install_counting_provider(batching: true)

      described_class.embed_many(texts)

      expect(described_class.provider.batches).to eq(1)
      expect(described_class.provider.texts).to be_nil
    end

    # @intent: { entity: "EmbeddingGenerator", action: "embed an empty page", behavior: "an empty input returns an empty array without invoking the provider at all", layer: "unit" }
    it "asks the provider nothing at all for an empty page" do
      # The ordinary case for the resolver — a re-ingest whose every text is already held asks for
      # nothing — and an empty request is still a billed round trip.
      install_counting_provider(batching: true)

      expect(described_class.embed_many([])).to eq([])
      expect(described_class.provider.batches).to be_nil
      expect(described_class.provider.texts).to be_nil
    end

    # @intent: { entity: "EmbeddingGenerator", action: "embed a page of texts", behavior: "a stubbed failing .call still raises through the default batch path, so failure seams written against .call keep working", layer: "unit" }
    it "carries a stub of .call through the default path, so a caller's seam still holds" do
      # `Ingest::IdentityResolver`'s failure specs — and SPGD-367's containment — are expressed by
      # making `.call` fail. The default batch goes through `.call` and not past it to the provider,
      # so what fails for one text still fails for a page of them.
      allow(described_class).to receive(:call).and_raise(described_class::Error, "provider down")

      expect { described_class.embed_many(texts) }
        .to raise_error(described_class::Error, "provider down")
    end
  end

  # Everything the interface guarantees for one vector it guarantees for every vector of a page —
  # plus the one guarantee only a page can break: that there is exactly one vector per input.
  describe "guarantees that survive the swap, for a whole page at once" do
    def install(&body)
      described_class.provider = Class.new { define_singleton_method(:embed_many, &body) }
    end

    # @intent: { entity: "EmbeddingGenerator", action: "embed a page of texts", behavior: "a page whose second vector is the wrong width is rejected, not just its first", layer: "unit" }
    it "validates EVERY vector of the page, not merely the first" do
      install { |texts| texts.each_with_index.map { |_text, index| Array.new(index.zero? ? 1024 : 3072, 0.5) } }

      expect { described_class.embed_many(%w[a b]) }
        .to raise_error(described_class::Error, /returned 3072 dimensions, expected 1024/)
    end

    # @intent: { entity: "EmbeddingGenerator", action: "embed a page of texts", behavior: "a short page is refused with a count-mismatch error instead of mis-pairing vectors onto texts", layer: "unit" }
    it "refuses a page with fewer vectors than texts, rather than zipping a nil onto a text" do
      # The failure a batch adds and a single embed cannot have. A short array is not merely a
      # missing answer for the LAST text — the caller pairs positionally, so every vector after the
      # gap lands on the wrong text, and every one of them validates.
      install { |texts| texts.take(1).map { Array.new(1024, 0.5) } }

      expect { described_class.embed_many(%w[a b c]) }
        .to raise_error(described_class::Error, "embedding provider returned 1 vectors for 3 texts")
    end

    # @intent: { entity: "EmbeddingGenerator", action: "embed a page of texts", behavior: "an over-long page is refused by the same mis-pairing guard", layer: "unit" }
    it "refuses a page with more vectors than texts, which is the same mis-pairing" do
      install { |texts| (texts + ["extra"]).map { Array.new(1024, 0.5) } }

      expect { described_class.embed_many(%w[a b]) }
        .to raise_error(described_class::Error, "embedding provider returned 3 vectors for 2 texts")
    end

    # @intent: { entity: "EmbeddingGenerator", action: "embed a page of texts", behavior: "a NilClass batch result raises an Error naming what was actually received", layer: "unit" }
    it "refuses a non-Array page" do
      install { |_texts| nil }

      expect { described_class.embed_many(%w[a b]) }
        .to raise_error(described_class::Error, /returned no vectors \(got NilClass\)/)
    end

    # @intent: { entity: "EmbeddingGenerator", action: "embed a page of texts", behavior: "a Faraday connection failure inside a batch is wrapped as an EmbeddingGenerator::Error", layer: "unit" }
    it "wraps a batching provider's transport exception rather than leaking it" do
      install { |_texts| raise Faraday::ConnectionFailed, "econnrefused" }

      expect { described_class.embed_many(%w[a b]) }
        .to raise_error(described_class::Error, /embedding provider failed: econnrefused/)
    end

    # @intent: { entity: "EmbeddingGenerator", action: "embed a page of texts", behavior: "an EmbeddingGenerator::Error raised by the provider passes through with its own message", layer: "unit" }
    it "lets a batching provider's own Error through unwrapped" do
      install { |_texts| raise EmbeddingGenerator::Error, "provider is not configured" }

      expect { described_class.embed_many(%w[a b]) }
        .to raise_error(described_class::Error, "provider is not configured")
    end

    # @intent: { entity: "EmbeddingGenerator", action: "embed a page of texts", behavior: "integer components from a batch are coerced to Floats", layer: "unit" }
    it "returns floats even when a batching provider hands back integers" do
      install { |texts| texts.map { Array.new(1024, 1) } }

      expect(described_class.embed_many(%w[a b]).flatten).to all(be_a(Float))
    end
  end

  describe ".fingerprint" do
    # The cache key's first half — what makes `EmbeddingCacheEntry` safe to share across every
    # repository in a deployment. A cached vector is reusable only if the thing that would produce
    # it again is the same thing, and this is the provider's own claim about what that means.

    # @intent: { entity: "EmbeddingGenerator", action: "read the provider fingerprint", behavior: "a provider publishing no fingerprint gets nil, disabling the cache rather than guessing a key", layer: "unit" }
    it "returns nothing at all for a provider that does not publish one" do
      # **The conservative default, and the shape `.equivalent?` and `.configured?` already use.**
      # No caching is the right answer to "I do not know what I am": it costs money and behaves
      # exactly as this application did before the cache existed. A GUESSED key — the class name,
      # say — would be wrong the moment a provider read its model from the environment, and the
      # symptom is a vector from the previous model silently attached to a test, which no
      # assertion anywhere would catch. Refusal is free; a wrong key is not.
      described_class.provider = Class.new { def self.call(text) = [text.length.to_f] }

      expect(described_class.fingerprint).to be_nil
    end

    # @intent: { entity: "EmbeddingGenerator", action: "read the provider fingerprint", behavior: "an empty fingerprint string is treated as withheld, not as a key shared by every deployment", layer: "unit" }
    it "treats a blank answer as a refusal rather than as a key everyone shares" do
      described_class.provider = Class.new { def self.fingerprint = "" }

      expect(described_class.fingerprint).to be_nil
    end

    # @intent: { entity: "EmbeddingGenerator", action: "read the provider fingerprint", behavior: "a published fingerprint is returned verbatim", layer: "unit" }
    it "delegates to a provider that does publish one" do
      described_class.provider = Class.new { def self.fingerprint = "vendor:model-x" }

      expect(described_class.fingerprint).to eq("vendor:model-x")
    end

    # @intent: { entity: "EmbeddingGenerator", action: "read the provider fingerprint", behavior: "the fingerprint is read fresh on every call, so a provider that changes its answer changes the key immediately", layer: "unit" }
    it "asks the provider again on every call, so a moved model is never served from a stale key" do
      # ⚠️ Not a style preference. `VoyageProvider.model` reads `ENV["SPECGUARD_EMBEDDING_MODEL"]`
      # each time it is asked, so a fingerprint captured once at boot would go on naming the model
      # the process started with and would keep authorising cache hits from it after the
      # deployment had moved — which is the "unreadable rather than stale" guarantee inverted.
      provider = Class.new do
        class << self
          attr_accessor :current
          def fingerprint = current
        end
      end
      provider.current = "vendor:before"
      described_class.provider = provider

      expect(described_class.fingerprint).to eq("vendor:before")

      provider.current = "vendor:after"

      expect(described_class.fingerprint).to eq("vendor:after")
    end

    describe "VoyageProvider's answer" do
      # @intent: { entity: "EmbeddingGenerator::VoyageProvider", action: "read the provider fingerprint", behavior: "the key names the openrouter gateway plus the current model and changes when the model env var changes", layer: "unit" }
      it "names the gateway and the model, and moves when the model does" do
        # Two models are different functions of the same text, so a deployment that changes
        # `SPECGUARD_EMBEDDING_MODEL` must not read a single entry written under the old one.
        expect(described_class::VoyageProvider.fingerprint)
          .to eq("openrouter:#{described_class::VoyageProvider::DEFAULT_MODEL}")

        with_env("SPECGUARD_EMBEDDING_MODEL", "voyageai/voyage-4") do
          expect(described_class::VoyageProvider.fingerprint).to eq("openrouter:voyageai/voyage-4")
        end
      end

      # @intent: { entity: "EmbeddingGenerator::VoyageProvider", action: "read the provider fingerprint", behavior: "the prefix is openrouter:, which makes the pre-migration openai:-keyed 1536-wide cache entries permanently unreadable", layer: "unit" }
      it "retires every entry the previous OpenAI-keyed provider wrote" do
        # Not a cosmetic prefix. The entries this application wrote before 2026-08-17 are
        # 1536-wide vectors from `text-embedding-3-small`, stored under `openai:…`, and they are
        # now unreadable by the only key anything asks for — which is the correct outcome and the
        # reason no data migration was needed for the cache.
        expect(described_class::VoyageProvider.fingerprint).to start_with("openrouter:")
        expect(described_class::VoyageProvider.fingerprint).not_to start_with("openai:")
      end

      # @intent: { entity: "EmbeddingGenerator::VoyageProvider", action: "read the provider fingerprint", behavior: "the fingerprint excludes the credential entirely even with a key configured", layer: "unit" }
      it "never carries the API key" do
        # The value is written to a database column and is deployment-global. Two deployments
        # holding different keys against the same model produce the same vectors for the same text,
        # so including the key would partition the cache by something that does not change its
        # contents — and would write a credential-derived value into a column, which is a leak with
        # no upside.
        with_api_key("sk-or-v1-super-secret-value") do
          expect(described_class::VoyageProvider.fingerprint).not_to include("super-secret-value")
          expect(described_class::VoyageProvider.fingerprint).to eq("openrouter:voyageai/voyage-4-lite")
        end
      end
    end

    # @intent: { entity: "DeterministicEmbeddingGenerator", action: "withhold the fingerprint", behavior: "the deterministic stub does not respond to fingerprint, so no spec can populate the cache table", layer: "unit" }
    it "is withheld by the suite's stub, so no spec writes a cache entry" do
      # Stated as an assertion because the absence is the decision, not an oversight: every example
      # in this suite runs under `DeterministicEmbeddingGenerator`, and a stub that published a
      # fingerprint would have the resolver filling `embedding_cache_entries` with vectors no
      # deployment can ever use.
      expect(DeterministicEmbeddingGenerator).not_to respond_to(:fingerprint)
    end
  end

  describe "swappability" do
    # @intent: { entity: "EmbeddingGenerator", action: "swap the provider", behavior: "installing any object answering .call changes the returned vector while the caller's statement stays identical", layer: "unit" }
    it "routes calls to any object answering .call(text), leaving callers untouched" do
      alternative = Class.new do
        def self.call(text)
          Array.new(EmbeddingGenerator::DIMENSIONS) { text.length.to_f }
        end
      end

      described_class.provider = alternative

      # The caller says exactly what it always says; only the provider changed.
      expect(described_class.call("abcd")).to eq(Array.new(1024) { 4.0 })
    end

    # @intent: { entity: "EmbeddingGenerator", action: "swap the provider", behavior: "clearing the provider resolves back to the shipped VoyageProvider", layer: "unit" }
    it "falls back to the shipped Voyage provider when nothing is installed" do
      described_class.provider = nil

      expect(described_class.provider).to eq(described_class::VoyageProvider)
    end

    # @intent: { entity: "EmbeddingGenerator", action: "swap the provider", behavior: "VoyageProvider is the only callable provider constant, preventing two embedding functions reaching one column", layer: "unit" }
    it "ships exactly one provider, so no vector can arrive from a second function of the text" do
      # The 2026-08-17 decision, asserted rather than only written down: two providers in one
      # deployment means two different functions of the same text can reach one column, and a
      # cosine computed across that seam is wrong in a way nothing downstream can detect.
      providers = described_class.constants.select do |name|
        described_class.const_get(name).is_a?(Class) && described_class.const_get(name).respond_to?(:call)
      end

      expect(providers).to eq([:VoyageProvider])
    end

    # @intent: { entity: "EmbeddingGenerator", action: "swap the provider", behavior: "resolving the default leaves no cached instance variable behind", layer: "unit" }
    it "does not memoize the default, so a reloaded class is never left stale" do
      described_class.provider = nil

      described_class.provider

      expect(described_class.instance_variable_get(:@provider)).to be_nil
    end
  end

  # The guarantees the class documents belong to the interface, not to VoyageProvider. Installing a
  # misbehaving provider is the only way to prove that — a well-behaved one passes either way.
  describe "guarantees that survive the swap" do
    def install(&body)
      described_class.provider = Class.new { define_singleton_method(:call, &body) }
    end

    # @intent: { entity: "EmbeddingGenerator", action: "embed a single text", behavior: "a 3072-wide vector from a swapped provider is rejected with the widths named before it can reach the index", layer: "unit" }
    it "rejects a swapped provider's wrong-width vector — 3072 would corrupt the HNSW index" do
      install { |_text| Array.new(3072) { 0.5 } }

      expect { described_class.call("x") }
        .to raise_error(described_class::Error, /returned 3072 dimensions, expected 1024/)
    end

    # @intent: { entity: "EmbeddingGenerator", action: "embed a single text", behavior: "the legacy 1536 width is refused by the same guard as any other wrong width", layer: "unit" }
    it "rejects a 1536-wide vector, the width this application used to store" do
      # The specific regression the migration makes possible: a provider or a cache entry left over
      # from before 2026-08-17 answers a perfectly well-formed vector of the WRONG width, and
      # `halfvec(1024)` would refuse it at INSERT with a message about the column rather than about
      # the provider.
      install { |_text| Array.new(1536) { 0.5 } }

      expect { described_class.call("x") }
        .to raise_error(described_class::Error, /returned 1536 dimensions, expected 1024/)
    end

    # @intent: { entity: "EmbeddingGenerator", action: "embed a single text", behavior: "a nil return from a swapped provider raises an Error rather than a NoMethodError", layer: "unit" }
    it "rejects a swapped provider's non-Array return" do
      install { |_text| nil }

      expect { described_class.call("x") }.to raise_error(described_class::Error, /returned no vector/)
    end

    # @intent: { entity: "EmbeddingGenerator", action: "embed a single text", behavior: "string components inside a vector are rejected as non-numeric", layer: "unit" }
    it "rejects a swapped provider's non-numeric vector" do
      install { |_text| Array.new(1024, "nope") }

      expect { described_class.call("x") }.to raise_error(described_class::Error, /non-numeric/)
    end

    # Float(Float::NAN) succeeds, so NaN clears the Array, width and numeric checks. pgvector does
    # not accept it ("NaN not allowed in vector"), so without this guard the failure would land in
    # the ingestion job as ActiveRecord::StatementInvalid instead of as an Error.
    # @intent: { entity: "EmbeddingGenerator", action: "embed a single text", behavior: "NaN components are rejected up front with a non-finite error, ahead of the database's refusal", layer: "unit" }
    it "rejects a swapped provider's NaN vector, which pgvector would refuse at INSERT" do
      install { |_text| Array.new(1024) { Float::NAN } }

      expect { described_class.call("x") }
        .to raise_error(described_class::Error, /non-finite value/)
    end

    # @intent: { entity: "EmbeddingGenerator", action: "embed a single text", behavior: "infinite components are rejected by the same non-finite guard", layer: "unit" }
    it "rejects a swapped provider's infinite vector" do
      install { |_text| [ Float::INFINITY ] + Array.new(1023, 0.5) }

      expect { described_class.call("x") }
        .to raise_error(described_class::Error, /non-finite value/)
    end

    # @intent: { entity: "EmbeddingGenerator", action: "embed a single text", behavior: "a Faraday failure from a swapped provider is wrapped as an EmbeddingGenerator::Error", layer: "unit" }
    it "wraps a swapped provider's transport exception rather than leaking it" do
      install { |_text| raise Faraday::ConnectionFailed, "econnrefused" }

      expect { described_class.call("x") }
        .to raise_error(described_class::Error, /embedding provider failed: econnrefused/)
    end

    # @intent: { entity: "EmbeddingGenerator", action: "embed a single text", behavior: "even an unrelated KeyError is wrapped rather than escaping raw", layer: "unit" }
    it "wraps any exception class, not just the ones the shipped provider knows about" do
      install { |_text| raise KeyError, "no such key" }

      expect { described_class.call("x") }.to raise_error(described_class::Error, /no such key/)
    end

    # @intent: { entity: "EmbeddingGenerator", action: "embed a single text", behavior: "a provider's own EmbeddingGenerator::Error passes through with its specific message intact", layer: "unit" }
    it "lets a provider's own Error through unwrapped, keeping its more specific message" do
      install { |_text| raise EmbeddingGenerator::Error, "provider is not configured" }

      expect { described_class.call("x") }
        .to raise_error(described_class::Error, "provider is not configured")
    end

    # @intent: { entity: "EmbeddingGenerator", action: "embed a single text", behavior: "integer components from a swapped provider are coerced to Floats", layer: "unit" }
    it "returns floats even when a swapped provider hands back integers" do
      install { |_text| Array.new(1024, 1) }

      expect(described_class.call("x")).to all(be_a(Float))
    end

    # @intent: { entity: "EmbeddingGenerator", action: "check configuration", behavior: "configured? consults the installed provider so a keyless local embedder still reports true", layer: "unit" }
    it "asks the installed provider whether it is configured, not the shipped one" do
      # A local embedder that needs no key at all must not report false just because
      # OPENROUTER_API_KEY is unset — the resolution job guards on this predicate.
      keyless = Class.new do
        def self.call(text) = Array.new(EmbeddingGenerator::DIMENSIONS, 0.0)
      end
      described_class.provider = keyless

      with_api_key(nil) { expect(described_class).to be_configured }
    end

    # @intent: { entity: "EmbeddingGenerator", action: "check configuration", behavior: "a provider asserting it is unconfigured wins even with a key present in ENV", layer: "unit" }
    it "reports not-configured when the installed provider says so" do
      unconfigured = Class.new do
        def self.call(text) = Array.new(EmbeddingGenerator::DIMENSIONS, 0.0)
        def self.configured? = false
      end
      described_class.provider = unconfigured

      with_api_key("sk-or-v1-set-but-irrelevant") { expect(described_class).not_to be_configured }
    end
  end

  # The interface-level question, which is deliberately not "are these similar": callers need to know
  # which inputs the installed provider collapses onto ONE vector, and only the provider can say.
  describe ".equivalent?" do
    # @intent: { entity: "EmbeddingGenerator", action: "compare texts for equivalence", behavior: "two spellings a normalising provider collapses onto one vector read as equivalent", layer: "unit" }
    it "is true for two spellings a normalising provider reduces to one vector" do
      described_class.provider = LexicalEmbeddingProvider

      expect(described_class.equivalent?("Order#checkout rejects an expired card",
                                         "Order  checkout   rejects an expired card!")).to be(true)
    end

    # @intent: { entity: "EmbeddingGenerator", action: "compare texts for equivalence", behavior: "a one-word edit the provider does not collapse reads as not equivalent", layer: "unit" }
    it "is false for an edit, however small, that the provider does not collapse" do
      described_class.provider = LexicalEmbeddingProvider

      expect(described_class.equivalent?("rejects an expired card",
                                         "rejects an expired cards")).to be(false)
    end

    # @intent: { entity: "EmbeddingGenerator", action: "compare texts for equivalence", behavior: "a provider without .normalize answers false rather than guessing, leaving drift detection inert in production", layer: "unit" }
    it "answers false for a provider that publishes no normalisation, rather than guessing" do
      # **The production case, and the whole of it.** `VoyageProvider` sends the text as written and
      # publishes no `.normalize`, so two different strings really are two different vectors and
      # nothing may be treated as the same input. `Ingest::IdentityResolver#note_drift` — the only
      # caller — is therefore inert on a real deployment, which is correct rather than merely
      # tolerated: under this provider the drift really is an edit.
      described_class.provider = described_class::VoyageProvider

      expect(described_class.equivalent?("Order#checkout", "Order  checkout")).to be(false)
    end

    # @intent: { entity: "EmbeddingGenerator", action: "compare texts for equivalence", behavior: "identical strings are equivalent without consulting the provider at all", layer: "unit" }
    it "is true for byte-identical text whatever the provider is, without asking it" do
      described_class.provider = Class.new do
        def self.call(_text) = Array.new(EmbeddingGenerator::DIMENSIONS, 0.0)
        def self.normalize(_text) = raise("must not be asked")
      end

      expect(described_class.equivalent?("x", "x")).to be(true)
    end
  end

  describe "configuration" do
    # The suite installs the deterministic stub for every example, and these are about the shipped
    # provider, so install it explicitly.
    before { described_class.provider = described_class::VoyageProvider }

    # @intent: { entity: "EmbeddingGenerator::VoyageProvider", action: "resolve the API key", behavior: "an ENV key is returned and the generator reports configured", layer: "unit" }
    it "reads the API key from ENV first" do
      with_api_key("sk-or-v1-from-env") do
        expect(described_class::VoyageProvider.api_key).to eq("sk-or-v1-from-env")
        expect(described_class).to be_configured
      end
    end

    # @intent: { entity: "EmbeddingGenerator::VoyageProvider", action: "resolve the API key", behavior: "with ENV unset the key comes from the encrypted credentials store", layer: "unit" }
    it "falls back to encrypted credentials when ENV is unset" do
      allow(Rails.application.credentials)
        .to receive(:dig).with(:openrouter, :api_key).and_return("sk-or-v1-from-credentials")

      with_api_key(nil) do
        expect(described_class::VoyageProvider.api_key).to eq("sk-or-v1-from-credentials")
        expect(described_class).to be_configured
      end
    end

    # @intent: { entity: "EmbeddingGenerator::VoyageProvider", action: "resolve the API key", behavior: "with no key anywhere the placeholder is returned and configured? is false instead of raising", layer: "unit" }
    it "reports not-configured with neither set, rather than raising at load time" do
      allow(Rails.application.credentials).to receive(:dig).with(:openrouter, :api_key).and_return(nil)

      with_api_key(nil) do
        expect(described_class::VoyageProvider.api_key).to eq(described_class::VoyageProvider::PLACEHOLDER)
        expect(described_class).not_to be_configured
      end
    end

    # The third configuration state, and the only one that reaches `credential`'s rescue: the
    # credentials store is PRESENT but cannot be DECRYPTED — `config/credentials.yml.enc` exists
    # and RAILS_MASTER_KEY (or config/master.key) holds the WRONG key, the state a key rotated in
    # one place but not the other leaves behind. Only that state raises
    # ActiveSupport::MessageEncryptor::InvalidMessage.
    #
    # A MISSING key is a different state and does NOT arrive here — traced and probed against
    # activesupport 8.1.3.1 as installed, with this app's `require_master_key` false (it is set
    # nowhere in config/): EncryptedFile#key returns nil, #read raises MissingContentError, and
    # EncryptedConfiguration#read rescues that to "", so `dig` returns nil and never raises. That
    # is the state the "neither set" example above already pins, not this one. (Were
    # `require_master_key` true, the class would be MissingKeyError — a RuntimeError, still caught
    # by this rescue's StandardError, still not InvalidMessage.)
    #
    # == What the rescue actually buys, on each of the two surfaces
    #
    # Through the INTERFACE (`.call`, `.embed_many`) an escaping InvalidMessage would not go
    # unattributed: both re-wrap StandardError into EmbeddingGenerator::Error, and those are the
    # only two entry points that can REACH this provider path from ingest/identity_resolver.rb, so
    # its deliberately narrow `rescue EmbeddingGenerator::Error` still fires. The resolver has a
    # THIRD call — `EmbeddingGenerator.equivalent?` — which those two rescues do NOT wrap; it is
    # inert here because `equivalent?` returns early unless the provider publishes `.normalize`,
    # and `VoyageProvider` does not, so it never reaches `credential`.
    #
    # No retry re-fires on either surface, and this rescue is not what protects one: there is no
    # `retry_on` anywhere in this application, and three places document that the obvious one
    # *could not* fire if there were — identity_resolver.rb and identity_resolution_job.rb.
    # `#embed` consumes EmbeddingGenerator::Error at the single call site, so the retry lives in the
    # work list rather than in a job policy.
    #
    # What a regression costs THERE is the MESSAGE: the operator loses the actionable
    # "not configured — set OPENROUTER_API_KEY" and gets an opaque decryption string instead. That
    # is why the example below pins the message and not just the class — class alone would be a
    # vacuous green.
    #
    # On the PROVIDER surface (`VoyageProvider.api_key`, `configured?`) there is no such wrapper,
    # so an escaping InvalidMessage is raw: `configured?` raises instead of answering false. That
    # is the unattributable half, and it is what the first example below pins.
    # @intent: { entity: "EmbeddingGenerator::VoyageProvider", action: "resolve the API key", behavior: "an undecryptable credentials store still answers the placeholder key and configured? false instead of leaking the decryption error", layer: "unit" }
    it "reports not-configured when the credentials store cannot be decrypted, rather than leaking the decryption error" do
      allow(Rails.application.credentials)
        .to receive(:dig).with(:openrouter, :api_key).and_raise(ActiveSupport::MessageEncryptor::InvalidMessage)

      with_api_key(nil) do
        expect(described_class::VoyageProvider.api_key).to eq(described_class::VoyageProvider::PLACEHOLDER)
        expect(described_class).not_to be_configured
      end
    end

    # The operator-facing half of the same guarantee: not merely "no crash at load", but that the
    # failure arrives carrying the ACTIONABLE REMEDY. The class alone cannot carry that weight —
    # with the rescue deleted, `.call`'s own outer rescue re-wraps InvalidMessage and the raised
    # object is STILL an EmbeddingGenerator::Error, so `raise_error(Error)` on its own is a vacuous
    # green. The message is the only thing that separates "not configured — set OPENROUTER_API_KEY"
    # from "embedding provider failed: <decryption noise>", so the message is what is pinned.
    # @intent: { entity: "EmbeddingGenerator::VoyageProvider", action: "embed a single text", behavior: "calling through an undecryptable store raises an Error whose message names the OPENROUTER_API_KEY remedy", layer: "unit" }
    it "surfaces an undecryptable store as an actionable EmbeddingGenerator::Error naming OPENROUTER_API_KEY" do
      allow(Rails.application.credentials)
        .to receive(:dig).with(:openrouter, :api_key).and_raise(ActiveSupport::MessageEncryptor::InvalidMessage)

      with_api_key(nil) do
        expect { described_class.call("some text") }
          .to raise_error(described_class::Error, /not configured.*OPENROUTER_API_KEY/m)
      end
    end

    # ENV precedence is unaffected by the store's health — but pinning that by asserting the
    # RETURNED VALUE under a raising stub has no teeth, so this asserts the store is never
    # CONSULTED instead. `credential`'s own rescue erases the evidence: a raising stub is
    # indistinguishable from a nil-returning one by the time `api_key` answers, so it yields
    # "sk-or-v1-from-env" under EITHER ordering. The message expectation is what makes it a real
    # control on the precedence contract pinned at the top of this block.
    # @intent: { entity: "EmbeddingGenerator::VoyageProvider", action: "resolve the API key", behavior: "when ENV answers, the credentials store is never read at all", layer: "unit" }
    it "never consults the credentials store when ENV answers" do
      expect(Rails.application.credentials).not_to receive(:dig)

      with_api_key("sk-or-v1-from-env") do
        expect(described_class::VoyageProvider.api_key).to eq("sk-or-v1-from-env")
        expect(described_class).to be_configured
      end
    end

    # @intent: { entity: "EmbeddingGenerator::VoyageProvider", action: "resolve the model", behavior: "the model defaults to voyageai/voyage-4-lite, the 1024-wide model", layer: "unit" }
    it "defaults to voyage-4-lite, the 1024-dimension model" do
      expect(described_class::VoyageProvider::DEFAULT_MODEL).to eq("voyageai/voyage-4-lite")
      expect(described_class::VoyageProvider.model).to eq("voyageai/voyage-4-lite")
    end

    # @intent: { entity: "EmbeddingGenerator::VoyageProvider", action: "resolve the endpoint", behavior: "the endpoint is pinned to OpenRouter's OpenAI-compatible embeddings URL, undiscoverable from the vendor catalogue", layer: "unit" }
    it "posts to OpenRouter's OpenAI-compatible embeddings endpoint" do
      # Pinned because it is not discoverable: OpenRouter's `/api/v1/models` catalogue lists no
      # embedding models at all, so nothing about this URL or this model name can be checked
      # against the vendor at runtime.
      expect(described_class::VoyageProvider::ENDPOINT).to eq("https://openrouter.ai/api/v1/embeddings")
    end
  end

  describe "the Voyage provider" do
    let(:request) { Struct.new(:body).new }
    let(:connection) { instance_double(Faraday::Connection) }

    around do |example|
      with_api_key("sk-or-v1-test") { example.run }
    end

    before do
      # Exercise the real production path — the interface with VoyageProvider installed — rather
      # than reaching past the seam to VoyageProvider.call.
      described_class.provider = described_class::VoyageProvider
      allow(Faraday).to receive(:new).and_return(connection)
    end

    # The provider builds its request through a block, so the double has to yield one in order for
    # the body to be observable at all.
    def stub_post(status: 200, body: {})
      response = instance_double(Faraday::Response,
                                 success?: (200..299).cover?(status), status: status, body: body)
      allow(connection).to receive(:post) do |_url, &block|
        block&.call(request)
        response
      end
      response
    end

    def stub_raise(error, message)
      allow(connection).to receive(:post).and_raise(error, message)
    end

    def expect_error(matching)
      expect { described_class.call("some text") }
        .to raise_error(described_class::Error, matching)
    end

    # @intent: { entity: "EmbeddingGenerator::VoyageProvider", action: "embed a single text", behavior: "a Faraday connection failure is converted to an EmbeddingGenerator::Error", layer: "unit" }
    it "converts a transport error rather than leaking Faraday's" do
      stub_raise(Faraday::ConnectionFailed, "econnrefused")

      expect_error(/embedding provider failed/)
    end

    # @intent: { entity: "EmbeddingGenerator::VoyageProvider", action: "embed a single text", behavior: "a 429 response surfaces as an Error carrying the upstream message an operator can act on", layer: "unit" }
    it "converts an upstream HTTP failure, carrying the message the operator has to read" do
      # A 429 or a retired model is something an operator acts on, and the interface's
      # "returned no vector (got NilClass)" would be true but useless. Faraday does not raise on
      # 4xx without the `raise_error` middleware, so without the explicit status check this body
      # would fall through to the width validation.
      stub_post(status: 429, body: { "error" => { "message" => "rate limit exceeded" } })

      expect_error(/HTTP 429.*rate limit exceeded/)
    end

    # @intent: { entity: "EmbeddingGenerator::VoyageProvider", action: "embed a single text", behavior: "an HTML 502 body still produces a readable HTTP error naming the status and body", layer: "unit" }
    it "survives an error body that is not JSON at all, as a gateway's would not be" do
      stub_post(status: 502, body: "<html>Bad Gateway</html>")

      expect_error(/HTTP 502.*Bad Gateway/)
    end

    # @intent: { entity: "EmbeddingGenerator::VoyageProvider", action: "embed a single text", behavior: "a response with no embedding raises a no-vector error", layer: "unit" }
    it "rejects a body with no vector in it" do
      stub_post(body: { "error" => "nope" })

      expect_error(/returned no vector/)
    end

    # @intent: { entity: "EmbeddingGenerator::VoyageProvider", action: "embed a single text", behavior: "a 3072-wide response vector is rejected with the widths named before it reaches the index", layer: "unit" }
    it "rejects a vector of the wrong width — a silent 3072 would corrupt the index" do
      stub_post(body: { "data" => [ { "embedding" => Array.new(3072, 0.1) } ] })

      expect_error(/returned 3072 dimensions, expected 1024/)
    end

    # @intent: { entity: "EmbeddingGenerator::VoyageProvider", action: "embed a single text", behavior: "string components in the response embedding are rejected as non-numeric", layer: "unit" }
    it "rejects a non-numeric vector" do
      stub_post(body: { "data" => [ { "embedding" => Array.new(1024, "nope") } ] })

      expect_error(/non-numeric/)
    end

    # @intent: { entity: "EmbeddingGenerator::VoyageProvider", action: "embed a single text", behavior: "with no key configured the call raises before any connection is built or request issued", layer: "unit" }
    it "refuses to call the provider at all when no API key is configured" do
      allow(Rails.application.credentials).to receive(:dig).with(:openrouter, :api_key).and_return(nil)
      allow(connection).to receive(:post)

      with_api_key(nil) { expect_error(/not configured/) }

      # Not merely "it raised" — it never built a connection or issued a request.
      expect(Faraday).not_to have_received(:new)
      expect(connection).not_to have_received(:post)
    end

    # @intent: { entity: "EmbeddingGenerator::VoyageProvider", action: "embed a single text", behavior: "a well-formed response embedding is returned verbatim", layer: "unit" }
    it "returns the vector unchanged on the happy path" do
      embedding = Array.new(1024) { |i| i / 1024.0 }
      stub_post(body: { "data" => [ { "embedding" => embedding } ] })

      expect(described_class.call("some text")).to eq(embedding)
    end

    # @intent: { entity: "EmbeddingGenerator::VoyageProvider", action: "embed a single text", behavior: "the request body carries the configured model and the caller's text verbatim", layer: "unit" }
    it "sends the configured model and the caller's text" do
      stub_post(body: { "data" => [ { "embedding" => Array.new(1024, 0.0) } ] })

      described_class.call("Order checkout")

      expect(request.body).to eq({ model: "voyageai/voyage-4-lite", input: "Order checkout" })
    end

    # @intent: { entity: "EmbeddingGenerator::VoyageProvider", action: "embed a single text", behavior: "the built connection's Authorization header is the configured key as a bearer token", layer: "unit" }
    it "authenticates with the configured key as a bearer token" do
      # Asserted on the connection the provider builds rather than on the request, because that is
      # where the header is set — and because a provider that silently sent no credential would
      # otherwise only fail against the real endpoint.
      headers = {}
      faraday = double(request: nil, response: nil, headers: headers, options: Struct.new(:timeout, :open_timeout).new)
      allow(Faraday).to receive(:new) do |&block|
        block.call(faraday)
        connection
      end
      stub_post(body: { "data" => [ { "embedding" => Array.new(1024, 0.0) } ] })

      described_class.call("Order checkout")

      expect(headers["Authorization"]).to eq("Bearer sk-or-v1-test")
    end

    # The reason the batch entry point exists at all: this is a provider that pays an HTTPS round
    # trip — and a bill — per `.call`, and the endpoint has always taken the whole array.
    describe "embedding a whole page at once" do
      let(:texts) { ["Order checkout", "User save", "Cart add"] }

      # One row of the response body per text, with the `index` the endpoint documents, each vector
      # distinguishable from its neighbours so a mis-pairing cannot look like a pass.
      def body(order = (0...texts.size).to_a)
        { "data" => order.map { |index| { "index" => index, "embedding" => Array.new(1024, index + 1.0) } } }
      end

      # @intent: { entity: "EmbeddingGenerator::VoyageProvider", action: "embed a page of texts", behavior: "a page of texts produces exactly one POST whose input is the whole array", layer: "unit" }
      it "issues ONE request carrying the array of inputs, not one request per text" do
        # The 20,000 → ~40 round trips this slice is for, asserted as the request count and the
        # `input` shape together: a loop that happened to send an array of one would pass either
        # half alone.
        stub_post(body: body)

        described_class.embed_many(texts)

        expect(connection).to have_received(:post).once
        expect(request.body).to eq({ model: "voyageai/voyage-4-lite", input: texts })
      end

      # @intent: { entity: "EmbeddingGenerator::VoyageProvider", action: "embed a page of texts", behavior: "each vector comes back positioned to its own text", layer: "unit" }
      it "returns the vectors in input order" do
        stub_post(body: body)

        expect(described_class.embed_many(texts)).to eq([1.0, 2.0, 3.0].map { |value| Array.new(1024, value) })
      end

      # @intent: { entity: "EmbeddingGenerator::VoyageProvider", action: "embed a page of texts", behavior: "a shuffled response page is reordered by each row's documented index field", layer: "unit" }
      it "orders by the response's own index rather than trusting the order it arrived in" do
        # **Asserted, not assumed** — the interface's order contract is the one thing a caller
        # cannot check for itself, and a shuffled page would hand every test its neighbour's
        # history while every vector still validated. The endpoint states each row's position; this
        # reads it.
        stub_post(body: body([2, 0, 1]))

        expect(described_class.embed_many(texts)).to eq([1.0, 2.0, 3.0].map { |value| Array.new(1024, value) })
      end

      # @intent: { entity: "EmbeddingGenerator::VoyageProvider", action: "embed a page of texts", behavior: "rows without an index fall back to arrival order instead of collapsing onto one sort key", layer: "unit" }
      it "falls back to arrival order when a body carries no index at all" do
        # Degrades to the order the array came in rather than collapsing every row onto one sort
        # key, which is what a bare `row["index"] || 0` would do.
        stub_post(body: { "data" => [1.0, 2.0].map { |value| { "embedding" => Array.new(1024, value) } } })

        expect(described_class.embed_many(%w[a b])).to eq([1.0, 2.0].map { |value| Array.new(1024, value) })
      end

      # @intent: { entity: "EmbeddingGenerator::VoyageProvider", action: "embed a page of texts", behavior: "a transport failure during a batch is wrapped as an EmbeddingGenerator::Error", layer: "unit" }
      it "converts a transport error rather than leaking Faraday's" do
        stub_raise(Faraday::ConnectionFailed, "econnrefused")

        expect { described_class.embed_many(texts) }
          .to raise_error(described_class::Error, /embedding provider failed/)
      end

      # @intent: { entity: "EmbeddingGenerator::VoyageProvider", action: "embed a page of texts", behavior: "a body without a data array raises a no-vectors error", layer: "unit" }
      it "rejects a body with no page in it" do
        stub_post(body: { "error" => "nope" })

        expect { described_class.embed_many(texts) }
          .to raise_error(described_class::Error, /returned no vectors/)
      end

      # @intent: { entity: "EmbeddingGenerator::VoyageProvider", action: "embed a page of texts", behavior: "a short response page is refused with the vector-versus-text count mismatch", layer: "unit" }
      it "rejects a page that answers about fewer texts than it was asked" do
        stub_post(body: body([0, 1]))

        expect { described_class.embed_many(texts) }
          .to raise_error(described_class::Error, "embedding provider returned 2 vectors for 3 texts")
      end

      # @intent: { entity: "EmbeddingGenerator::VoyageProvider", action: "embed a page of texts", behavior: "an unconfigured key refuses the whole batch before any connection is built or request issued", layer: "unit" }
      it "refuses to call the provider at all when no API key is configured" do
        allow(Rails.application.credentials).to receive(:dig).with(:openrouter, :api_key).and_return(nil)
        allow(connection).to receive(:post)

        with_api_key(nil) do
          expect { described_class.embed_many(texts) }
            .to raise_error(described_class::Error, /not configured/)
        end

        expect(Faraday).not_to have_received(:new)
        expect(connection).not_to have_received(:post)
      end
    end
  end
end
