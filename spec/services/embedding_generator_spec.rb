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

    it "falls back to the OpenAI provider when nothing is installed" do
      described_class.provider = nil

      expect(described_class.provider).to eq(described_class::OpenAIProvider)
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

  describe "configuration" do
    # The suite installs the deterministic stub for every example; these are about the default
    # provider, so put it back.
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

  describe "the default provider" do
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
  end
end
