# frozen_string_literal: true

# Installs the **shipped** embedding provider for one example group, because identity resolution
# cannot be tested against the suite's default stub.
#
# `spec/support/embedding_generator.rb` installs `DeterministicEmbeddingGenerator` for every
# example, and its own header says what it is: *"Values are pseudo-random, so two different strings
# are near-orthogonal regardless of how similar they read — this stub models identity, not
# meaning."* Under it, `"rejects an expired card"` and `"rejects an expired card "` are two
# unrelated vectors. A resolution spec written against that stub would pass or fail for reasons that
# have nothing to do with the logic under test: the ten-line-shift case would still resolve (same
# string, same seed, cosine 1.0), but every "close but not the same" and "similar but different"
# assertion would be measuring the stub's randomness instead of the threshold.
#
# So these groups run `EmbeddingGenerator::LocalProvider` — production's default, installed through
# the same public swap seam, in-process, deterministic, no credentials and no network. The
# similarity numbers below are then the real ones, and `SpecIdentity::MATCH_SIMILARITY` is being
# asserted against the vectors it was chosen from rather than against a fixture of them.
#
#   RSpec.describe Ingest::IdentityResolver do
#     include_context "with lexical embeddings"
#     …
#   end
RSpec.shared_context "with lexical embeddings" do
  before { EmbeddingGenerator.provider = EmbeddingGenerator::LocalProvider }
  # No `after`: spec/support/embedding_generator.rb already resets the provider to nil after every
  # example, and a second reset here would be a copy of that rule rather than a reliance on it.
end
