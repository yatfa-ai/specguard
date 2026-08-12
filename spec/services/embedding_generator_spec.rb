# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmbeddingGenerator do
  # Swap the whole ENV key rather than stubbing ENV#[] — a `with`-constrained partial double on ENV
  # breaks every other ENV read in the stack.
  def with_api_key(value)
    original = ENV["OPENAI_API_KEY"]
    ENV["OPENAI_API_KEY"] = value
    yield
  ensure
    ENV["OPENAI_API_KEY"] = original
  end

  describe ".call" do
    it "returns a vector of exactly 1536 floats" do
      vector = described_class.call("Order checkout returns 402 payment required on expired card")

      expect(vector).to be_an(Array)
      expect(vector.size).to eq(1536)
      expect(vector).to all(be_a(Float))
    end

    it "pins DIMENSIONS to the spec_intents.embedding column width" do
      # Not a tautology: the column and its HNSW index are 1536-wide, so a change here without a
      # migration would fail at INSERT time instead of here.
      expect(described_class::DIMENSIONS).to eq(1536)
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
            EmbeddingGenerator::LocalProvider.call(text)
          end
        end
      end

      if batching
        provider.define_singleton_method(:embed_many) do |texts|
          @batches = (@batches || 0) + 1
          texts.map { |text| EmbeddingGenerator::LocalProvider.call(text) }
        end
      end

      described_class.provider = provider
    end

    let(:texts) do
      ["Order#checkout rejects an expired card",
       "User#save refuses a duplicate email",
       "Cart#add appends the item to the cart"]
    end

    before { described_class.provider = described_class::LocalProvider }

    it "returns one vector per text, in input order" do
      # **The order IS the contract.** Callers assign vectors positionally, so a page returned in
      # any other order attaches one test's history to another test — silently, because every
      # vector is a perfectly valid vector. Asserted against `.call` of the SAME text rather than
      # against a fixture, so it is the interface's own answer that has to line up.
      expect(described_class.embed_many(texts)).to eq(texts.map { |text| described_class.call(text) })
    end

    it "is exactly a map of .call for a provider that has no batch of its own" do
      # The default implementation, stated as an equivalence rather than as an implementation
      # detail: a provider written before this entry point existed answers a batch correctly and
      # without knowing anything about it.
      install_counting_provider

      vectors = described_class.embed_many(texts)

      expect(described_class.provider.texts).to eq(texts)
      expect(vectors).to eq(texts.map { |text| described_class::LocalProvider.call(text) })
    end

    it "asks a batching provider ONCE for the whole page, and never per text" do
      # The win itself, for the only provider shape where it is a win: one request, not three.
      install_counting_provider(batching: true)

      described_class.embed_many(texts)

      expect(described_class.provider.batches).to eq(1)
      expect(described_class.provider.texts).to be_nil
    end

    it "asks the provider nothing at all for an empty page" do
      # The ordinary case for the resolver — a re-ingest whose every text is already held asks for
      # nothing — and an empty request is still a billed round trip.
      install_counting_provider(batching: true)

      expect(described_class.embed_many([])).to eq([])
      expect(described_class.provider.batches).to be_nil
      expect(described_class.provider.texts).to be_nil
    end

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

    it "validates EVERY vector of the page, not merely the first" do
      install { |texts| texts.each_with_index.map { |_text, index| Array.new(index.zero? ? 1536 : 3072, 0.5) } }

      expect { described_class.embed_many(%w[a b]) }
        .to raise_error(described_class::Error, /returned 3072 dimensions, expected 1536/)
    end

    it "refuses a page with fewer vectors than texts, rather than zipping a nil onto a text" do
      # The failure a batch adds and a single embed cannot have. A short array is not merely a
      # missing answer for the LAST text — the caller pairs positionally, so every vector after the
      # gap lands on the wrong text, and every one of them validates.
      install { |texts| texts.take(1).map { Array.new(1536, 0.5) } }

      expect { described_class.embed_many(%w[a b c]) }
        .to raise_error(described_class::Error, "embedding provider returned 1 vectors for 3 texts")
    end

    it "refuses a page with more vectors than texts, which is the same mis-pairing" do
      install { |texts| (texts + ["extra"]).map { Array.new(1536, 0.5) } }

      expect { described_class.embed_many(%w[a b]) }
        .to raise_error(described_class::Error, "embedding provider returned 3 vectors for 2 texts")
    end

    it "refuses a non-Array page" do
      install { |_texts| nil }

      expect { described_class.embed_many(%w[a b]) }
        .to raise_error(described_class::Error, /returned no vectors \(got NilClass\)/)
    end

    it "wraps a batching provider's transport exception rather than leaking it" do
      install { |_texts| raise Faraday::ConnectionFailed, "econnrefused" }

      expect { described_class.embed_many(%w[a b]) }
        .to raise_error(described_class::Error, /embedding provider failed: econnrefused/)
    end

    it "lets a batching provider's own Error through unwrapped" do
      install { |_texts| raise EmbeddingGenerator::Error, "provider is not configured" }

      expect { described_class.embed_many(%w[a b]) }
        .to raise_error(described_class::Error, "provider is not configured")
    end

    it "returns floats even when a batching provider hands back integers" do
      install { |texts| texts.map { Array.new(1536, 1) } }

      expect(described_class.embed_many(%w[a b]).flatten).to all(be_a(Float))
    end
  end

  describe "swappability" do
    it "routes calls to any object answering .call(text), leaving callers untouched" do
      alternative = Class.new do
        def self.call(text)
          Array.new(EmbeddingGenerator::DIMENSIONS) { text.length.to_f }
        end
      end

      described_class.provider = alternative

      # The caller says exactly what it always says; only the provider changed.
      expect(described_class.call("abcd")).to eq(Array.new(1536) { 4.0 })
    end

    it "falls back to the local provider when nothing is installed" do
      described_class.provider = nil

      expect(described_class.provider).to eq(described_class::LocalProvider)
    end

    it "does not memoize the default, so a reloaded class is never left stale" do
      described_class.provider = nil

      described_class.provider

      expect(described_class.instance_variable_get(:@provider)).to be_nil
    end
  end

  # The guarantees the class documents belong to the interface, not to OpenAIProvider. Installing a
  # misbehaving provider is the only way to prove that — a well-behaved one passes either way.
  describe "guarantees that survive the swap" do
    def install(&body)
      described_class.provider = Class.new { define_singleton_method(:call, &body) }
    end

    it "rejects a swapped provider's wrong-width vector — 3072 would corrupt the HNSW index" do
      install { |_text| Array.new(3072) { 0.5 } }

      expect { described_class.call("x") }
        .to raise_error(described_class::Error, /returned 3072 dimensions, expected 1536/)
    end

    it "rejects a swapped provider's non-Array return" do
      install { |_text| nil }

      expect { described_class.call("x") }.to raise_error(described_class::Error, /returned no vector/)
    end

    it "rejects a swapped provider's non-numeric vector" do
      install { |_text| Array.new(1536, "nope") }

      expect { described_class.call("x") }.to raise_error(described_class::Error, /non-numeric/)
    end

    # Float(Float::NAN) succeeds, so NaN clears the Array, width and numeric checks. pgvector does
    # not accept it ("NaN not allowed in vector"), so without this guard the failure would land in
    # the ingestion job as ActiveRecord::StatementInvalid instead of as an Error.
    it "rejects a swapped provider's NaN vector, which pgvector would refuse at INSERT" do
      install { |_text| Array.new(1536) { Float::NAN } }

      expect { described_class.call("x") }
        .to raise_error(described_class::Error, /non-finite value/)
    end

    it "rejects a swapped provider's infinite vector" do
      install { |_text| [ Float::INFINITY ] + Array.new(1535, 0.5) }

      expect { described_class.call("x") }
        .to raise_error(described_class::Error, /non-finite value/)
    end

    it "wraps a swapped provider's transport exception rather than leaking it" do
      install { |_text| raise Faraday::ConnectionFailed, "econnrefused" }

      expect { described_class.call("x") }
        .to raise_error(described_class::Error, /embedding provider failed: econnrefused/)
    end

    it "wraps any exception class, not just the ones the default provider knows about" do
      install { |_text| raise KeyError, "no such key" }

      expect { described_class.call("x") }.to raise_error(described_class::Error, /no such key/)
    end

    it "lets a provider's own Error through unwrapped, keeping its more specific message" do
      install { |_text| raise EmbeddingGenerator::Error, "provider is not configured" }

      expect { described_class.call("x") }
        .to raise_error(described_class::Error, "provider is not configured")
    end

    it "returns floats even when a swapped provider hands back integers" do
      install { |_text| Array.new(1536, 1) }

      expect(described_class.call("x")).to all(be_a(Float))
    end

    it "asks the installed provider whether it is configured, not OpenAI" do
      # A local embedder that needs no key at all must not report false just because OPENAI_API_KEY
      # is unset — slice 3's job and IntentChecker guard on this predicate.
      keyless = Class.new do
        def self.call(text) = Array.new(EmbeddingGenerator::DIMENSIONS, 0.0)
      end
      described_class.provider = keyless

      with_api_key(nil) { expect(described_class).to be_configured }
    end

    it "reports not-configured when the installed provider says so" do
      unconfigured = Class.new do
        def self.call(text) = Array.new(EmbeddingGenerator::DIMENSIONS, 0.0)
        def self.configured? = false
      end
      described_class.provider = unconfigured

      with_api_key("sk-set-but-irrelevant") { expect(described_class).not_to be_configured }
    end
  end

  # The provider that ships as the default: in-process feature hashing, no key, no network, no
  # cost. Exercised through the interface (`described_class.call`) wherever the assertion is about
  # the production path, because that is what every caller will actually reach.
  describe "the local provider (the default)" do
    before { described_class.provider = described_class::LocalProvider }

    def cosine(one, two)
      one.each_with_index.sum { |value, index| value * two[index] }
    end

    def magnitude(vector)
      Math.sqrt(vector.sum { |value| value * value })
    end

    describe "the vector it produces" do
      it "is 1536 floats wide, matching the spec_intents.embedding column" do
        vector = described_class.call("Order checkout returns 402 payment required on expired card")

        expect(vector.size).to eq(described_class::DIMENSIONS)
        expect(vector).to all(be_a(Float))
      end

      it "is unit-normalised, so pgvector's cosine operator ranks it against any other vector" do
        vector = described_class.call("Repository#annotated_ratio counts only annotated intents")

        expect(magnitude(vector)).to be_within(1e-12).of(1.0)
      end

      it "is sparse — a short name touches far fewer than 1536 dimensions" do
        # Not a curiosity: it is why the collision audit's inverted-index sweep is tractable, and
        # why collisions are possible at all. A ~60-character name yields ~70 features.
        vector = described_class.call("rejects checkout on an expired card")

        expect(vector.count { |value| value != 0.0 }).to be_between(1, 100)
      end

      it "stays a unit vector when a text has far more features than there are dimensions" do
        # 1536 buckets, thousands of features: every dimension is hit many times and the weights
        # sum. The result must still be normalised, still finite, still the right width.
        vector = described_class.call(("the quick brown fox jumps over the lazy dog " * 200))

        expect(vector.size).to eq(1536)
        expect(vector).to all(be_finite)
        expect(magnitude(vector)).to be_within(1e-12).of(1.0)
      end
    end

    describe "determinism" do
      it "returns a byte-identical vector for the same text, pinned by checksum" do
        # A golden checksum rather than a re-run comparison: this pins the mapping across runs and
        # processes ON THIS PLATFORM, which is what the identity half of the product rests on.
        #
        # What it does NOT pin is cross-platform bit-equality. Everything up to the weight is exact
        # integer work, but `Math.sin` delegates to the host libm and glibc/musl/Darwin may differ
        # in the last ULP. So read a failure in the order: if the C library or CPU architecture
        # changed (a new base image), suspect a benign rounding difference and confirm by checking
        # whether the vectors differ only in their low bits. Otherwise the mapping itself changed —
        # the embedding of every stored intent has silently moved and every row needs re-embedding.
        # In neither case is this a spec to "just update" to whatever the new value happens to be.
        vector = described_class.call("Order checkout returns 402 payment required on expired card")

        expect(Digest::SHA256.hexdigest(vector.pack("E*")))
          .to eq("4497315d864dba8b2f3426861dc0e7dc8d590968879901a1d315f33f65f376a4")
      end

      it "produces the same vector in a fresh process with a scrubbed environment" do
        # The in-process checksum above cannot see a hidden dependency on process state (a seed, a
        # hash-randomisation salt, an ENV var). This can: a separate Ruby, no Rails, no ENV.
        script = <<~RUBY
          require "digest"
          require "#{Rails.root.join('app/services/embedding_generator')}"
          vector = EmbeddingGenerator::LocalProvider.call(ARGV[0])
          print Digest::SHA256.hexdigest(vector.pack("E*"))
        RUBY

        checksum = IO.popen(
          { "OPENAI_API_KEY" => nil, "RUBYOPT" => nil },
          [ RbConfig.ruby, "-e", script, "Order checkout returns 402 payment required on expired card" ],
          unsetenv_others: true, &:read
        )

        expect($?).to be_success
        expect(checksum).to eq("4497315d864dba8b2f3426861dc0e7dc8d590968879901a1d315f33f65f376a4")
      end

      it "gives different text a different vector" do
        expect(described_class.call("charges the card")).not_to eq(described_class.call("refunds the card"))
      end
    end

    describe "costing nothing and reaching nothing" do
      it "reports itself configured with no API key anywhere" do
        allow(Rails.application.credentials).to receive(:dig).with(:openai, :api_key).and_return(nil)

        with_api_key(nil) do
          expect(described_class).to be_configured
          expect(described_class.call("no key needed").size).to eq(1536)
        end
      end

      it "never builds an HTTP client" do
        allow(OpenAI::Client).to receive(:new)

        described_class.call("Order checkout")

        expect(OpenAI::Client).not_to have_received(:new)
      end
    end

    describe "what it actually measures" do
      let(:expired_card) { described_class.call("rejects checkout on an expired card") }

      it "clusters two names that share vocabulary" do
        restated = described_class.call("rejects checkout when the card is expired")

        expect(cosine(expired_card, restated)).to be > 0.5
      end

      it "tolerates a changed suffix, because n-grams overlap where words do not" do
        # "expired"/"expires" share no word feature at all; they share four of their five trigrams.
        expect(cosine(expired_card, described_class.call("rejects checkout on a card that expires")))
          .to be > 0.3
      end

      it "ignores punctuation and repeated whitespace" do
        expect(described_class.call("Order#checkout")).to eq(described_class.call("  order   CHECKOUT!  "))
      end

      # The documented limitation, asserted rather than merely written down. This is lexical
      # similarity: two names for the same behaviour that share no vocabulary are near-orthogonal,
      # exactly as if they were unrelated. Duplicate detection built on this provider sees only the
      # duplicates that were phrased alike. See the LocalProvider class documentation.
      it "does NOT match the same behaviour described in different words" do
        payment_required = described_class.call("returns 402 payment required")
        rejection = described_class.call("declines the purchase")

        expect(cosine(payment_required, rejection)).to be < 0.1
      end

      it "gives unrelated names a low similarity" do
        expect(cosine(expired_card, described_class.call("paginates the audit log"))).to be < 0.2
      end
    end

    describe "text with nothing in it" do
      # No alphanumeric content means no features and so no direction. Zero is the honest answer,
      # and it must still clear the interface's width and finiteness validation rather than
      # blowing up somewhere downstream.
      it "returns a finite zero vector of the right width for punctuation-only text" do
        vector = described_class.call("--- !!! ---")

        expect(vector.size).to eq(1536)
        expect(vector).to all(eq(0.0))
      end

      it "returns a zero vector for an empty string rather than raising" do
        expect(described_class.call("")).to eq(Array.new(1536, 0.0))
      end

      it "accepts a nil the same way, since callers build text by interpolation" do
        expect(described_class.call(nil)).to eq(Array.new(1536, 0.0))
      end
    end

    # `.normalize` is published so that `Ingest::IdentityResolver` can tell a description that
    # gained a comma apart from one that was edited. These examples pin it as what the VECTOR
    # depends on rather than as a string utility — a normalisation that agreed with `#call` about
    # everything except one character would be worse than none, because the resolver would re-point
    # an identity at text that does not embed the same.
    describe ".normalize" do
      it "reduces punctuation, case and runs of whitespace to one canonical form" do
        expect(described_class::LocalProvider.normalize("Order#checkout   rejects  an Expired card!"))
          .to eq("order checkout rejects an expired card")
      end

      it "has nothing to say about text with no alphanumeric content, exactly as the vector does" do
        expect(described_class::LocalProvider.normalize("--- !!! ---")).to eq("")
        expect(described_class::LocalProvider.normalize(nil)).to eq("")
      end

      it "agrees with the vector: same normalised form means the same 1536 floats" do
        # The property the resolver acts on, asserted as an equality of VECTORS and not of strings.
        one = "Order#checkout rejects an expired card"
        other = "Order  checkout   rejects an expired card!"

        expect(described_class::LocalProvider.normalize(one))
          .to eq(described_class::LocalProvider.normalize(other))
        expect(described_class.call(one)).to eq(described_class.call(other))
      end

      it "does not collapse a real edit, so the vectors differ too" do
        one = "Order#checkout rejects an expired card"
        other = "Order#checkout rejects an expired cards"

        expect(described_class::LocalProvider.normalize(one))
          .not_to eq(described_class::LocalProvider.normalize(other))
        expect(described_class.call(one)).not_to eq(described_class.call(other))
      end
    end
  end

  # The interface-level question, which is deliberately not "are these similar": callers need to know
  # which inputs the installed provider collapses onto ONE vector, and only the provider can say.
  describe ".equivalent?" do
    it "is true for two spellings the shipped provider reduces to one vector" do
      described_class.provider = described_class::LocalProvider

      expect(described_class.equivalent?("Order#checkout rejects an expired card",
                                         "Order  checkout   rejects an expired card!")).to be(true)
    end

    it "is false for an edit, however small, that the provider does not collapse" do
      described_class.provider = described_class::LocalProvider

      expect(described_class.equivalent?("rejects an expired card",
                                         "rejects an expired cards")).to be(false)
    end

    it "answers false for a provider that publishes no normalisation, rather than guessing" do
      # The conservative default, and the one that matters in production: `OpenAIProvider` sends the
      # text as written, so two different strings really are two different vectors and nothing may
      # be treated as the same input. A caller acting on this `false` does what it did before the
      # predicate existed.
      described_class.provider = described_class::OpenAIProvider

      expect(described_class.equivalent?("Order#checkout", "Order  checkout")).to be(false)
    end

    it "is true for byte-identical text whatever the provider is, without asking it" do
      described_class.provider = Class.new do
        def self.call(_text) = Array.new(EmbeddingGenerator::DIMENSIONS, 0.0)
        def self.normalize(_text) = raise("must not be asked")
      end

      expect(described_class.equivalent?("x", "x")).to be(true)
    end
  end

  describe "configuration" do
    # OpenAIProvider is no longer the default — the suite installs the deterministic stub for every
    # example, and these are about the paid provider, so install it explicitly.
    before { described_class.provider = described_class::OpenAIProvider }

    it "reads the API key from ENV first" do
      with_api_key("sk-from-env") do
        expect(described_class::OpenAIProvider.api_key).to eq("sk-from-env")
        expect(described_class).to be_configured
      end
    end

    it "falls back to encrypted credentials when ENV is unset" do
      allow(Rails.application.credentials).to receive(:dig).with(:openai, :api_key).and_return("sk-from-credentials")

      with_api_key(nil) do
        expect(described_class::OpenAIProvider.api_key).to eq("sk-from-credentials")
        expect(described_class).to be_configured
      end
    end

    it "reports not-configured with neither set, rather than raising at load time" do
      allow(Rails.application.credentials).to receive(:dig).with(:openai, :api_key).and_return(nil)

      with_api_key(nil) do
        expect(described_class::OpenAIProvider.api_key).to eq(described_class::OpenAIProvider::PLACEHOLDER)
        expect(described_class).not_to be_configured
      end
    end

    it "defaults to text-embedding-3-small, the 1536-dimension model" do
      expect(described_class::OpenAIProvider::DEFAULT_MODEL).to eq("text-embedding-3-small")
      expect(described_class::OpenAIProvider.model).to eq("text-embedding-3-small")
    end
  end

  describe "the OpenAI provider" do
    let(:client) { instance_double(OpenAI::Client) }

    around do |example|
      with_api_key("sk-test") { example.run }
    end

    before do
      # Exercise the real production path — the interface with OpenAIProvider installed — rather
      # than reaching past the seam to OpenAIProvider.call.
      described_class.provider = described_class::OpenAIProvider
      allow(OpenAI::Client).to receive(:new).and_return(client)
    end

    def expect_error(matching)
      expect { described_class.call("some text") }
        .to raise_error(described_class::Error, matching)
    end

    it "converts a transport error rather than leaking Faraday's" do
      allow(client).to receive(:embeddings).and_raise(Faraday::ConnectionFailed, "econnrefused")

      expect_error(/embedding provider failed/)
    end

    it "converts an OpenAI error rather than leaking the vendor's" do
      allow(client).to receive(:embeddings).and_raise(OpenAI::Error, "rate limited")

      expect_error(/rate limited/)
    end

    it "rejects a body with no vector in it" do
      allow(client).to receive(:embeddings).and_return({ "error" => "nope" })

      expect_error(/returned no vector/)
    end

    it "rejects a vector of the wrong width — a silent 3072 would corrupt the index" do
      allow(client).to receive(:embeddings).and_return({ "data" => [ { "embedding" => Array.new(3072, 0.1) } ] })

      expect_error(/returned 3072 dimensions, expected 1536/)
    end

    it "rejects a non-numeric vector" do
      allow(client).to receive(:embeddings).and_return({ "data" => [ { "embedding" => Array.new(1536, "nope") } ] })

      expect_error(/non-numeric/)
    end

    it "refuses to call the provider at all when no API key is configured" do
      allow(Rails.application.credentials).to receive(:dig).with(:openai, :api_key).and_return(nil)
      allow(client).to receive(:embeddings)

      with_api_key(nil) { expect_error(/not configured/) }

      # Not merely "it raised" — it never built a client or issued a request.
      expect(OpenAI::Client).not_to have_received(:new)
      expect(client).not_to have_received(:embeddings)
    end

    it "returns the vector unchanged on the happy path" do
      embedding = Array.new(1536) { |i| i / 1536.0 }
      allow(client).to receive(:embeddings).and_return({ "data" => [ { "embedding" => embedding } ] })

      expect(described_class.call("some text")).to eq(embedding)
    end

    it "sends the configured model and the caller's text" do
      allow(client).to receive(:embeddings).and_return({ "data" => [ { "embedding" => Array.new(1536, 0.0) } ] })

      described_class.call("Order checkout")

      expect(client).to have_received(:embeddings)
        .with(parameters: { model: "text-embedding-3-small", input: "Order checkout" })
    end

    # The reason the batch entry point exists at all: this is the provider that pays an HTTPS round
    # trip — and a bill — per `.call`, and the endpoint has always taken the whole array.
    describe "embedding a whole page at once" do
      let(:texts) { ["Order checkout", "User save", "Cart add"] }

      # One row of the response body per text, with the `index` the endpoint documents, each vector
      # distinguishable from its neighbours so a mis-pairing cannot look like a pass.
      def body(order = (0...texts.size).to_a)
        { "data" => order.map { |index| { "index" => index, "embedding" => Array.new(1536, index + 1.0) } } }
      end

      it "issues ONE request carrying the array of inputs, not one request per text" do
        # The 20,000 → ~40 round trips this slice is for, asserted as the request count and the
        # `input` shape together: a loop that happened to send an array of one would pass either
        # half alone.
        allow(client).to receive(:embeddings).and_return(body)

        described_class.embed_many(texts)

        expect(client).to have_received(:embeddings)
          .with(parameters: { model: "text-embedding-3-small", input: texts }).once
      end

      it "returns the vectors in input order" do
        allow(client).to receive(:embeddings).and_return(body)

        expect(described_class.embed_many(texts)).to eq([1.0, 2.0, 3.0].map { |value| Array.new(1536, value) })
      end

      it "orders by the response's own index rather than trusting the order it arrived in" do
        # **Asserted, not assumed** — the interface's order contract is the one thing a caller
        # cannot check for itself, and a shuffled page would hand every test its neighbour's
        # history while every vector still validated. The endpoint states each row's position; this
        # reads it.
        allow(client).to receive(:embeddings).and_return(body([2, 0, 1]))

        expect(described_class.embed_many(texts)).to eq([1.0, 2.0, 3.0].map { |value| Array.new(1536, value) })
      end

      it "falls back to arrival order when a body carries no index at all" do
        # Degrades to the order the array came in rather than collapsing every row onto one sort
        # key, which is what a bare `row["index"] || 0` would do.
        allow(client).to receive(:embeddings)
          .and_return({ "data" => [1.0, 2.0].map { |value| { "embedding" => Array.new(1536, value) } } })

        expect(described_class.embed_many(%w[a b])).to eq([1.0, 2.0].map { |value| Array.new(1536, value) })
      end

      it "converts a transport error rather than leaking Faraday's" do
        allow(client).to receive(:embeddings).and_raise(Faraday::ConnectionFailed, "econnrefused")

        expect { described_class.embed_many(texts) }
          .to raise_error(described_class::Error, /embedding provider failed/)
      end

      it "rejects a body with no page in it" do
        allow(client).to receive(:embeddings).and_return({ "error" => "nope" })

        expect { described_class.embed_many(texts) }
          .to raise_error(described_class::Error, /returned no vectors/)
      end

      it "rejects a page that answers about fewer texts than it was asked" do
        allow(client).to receive(:embeddings).and_return(body([0, 1]))

        expect { described_class.embed_many(texts) }
          .to raise_error(described_class::Error, "embedding provider returned 2 vectors for 3 texts")
      end

      it "refuses to call the provider at all when no API key is configured" do
        allow(Rails.application.credentials).to receive(:dig).with(:openai, :api_key).and_return(nil)
        allow(client).to receive(:embeddings)

        with_api_key(nil) do
          expect { described_class.embed_many(texts) }
            .to raise_error(described_class::Error, /not configured/)
        end

        expect(OpenAI::Client).not_to have_received(:new)
        expect(client).not_to have_received(:embeddings)
      end
    end
  end
end
