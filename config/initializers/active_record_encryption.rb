# frozen_string_literal: true

# Keys for Active Record Encryption, which in this app protects exactly one column:
# `users.github_access_token` (see the User model). That token can read the repository metadata of
# whoever granted it, so it is not something to leave in plaintext in a database dump.
#
# Resolution order — the same shape, and for the same reason, as `SpecGuard::GithubOauth`
# (config/initializers/omniauth.rb) and `EmbeddingGenerator`: ENV first, encrypted credentials
# second, and a deterministic fallback when neither is set, so the app boots and the suite runs
# green on a fresh checkout with nothing configured.
#
#   export ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=...
#   export ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=...
#   export ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=...
#
# or via `bin/rails credentials:edit`:
#
#   active_record_encryption:
#     primary_key: ...
#     deterministic_key: ...
#     key_derivation_salt: ...
#
# (`bin/rails db:encryption:init` prints a ready-made block.)
#
# ## About the fallback
#
# The fallback derives the three keys from `secret_key_base`, which is already the app's root
# secret and is already required to be set and stable in production. That makes the fallback
# *correct* rather than merely convenient: it is not a hardcoded key, it is not shared between two
# installations, and it rotates only when the root secret does.
#
# What it does mean is that rotating `secret_key_base` renders every stored token undecryptable.
# That is a survivable outcome by design and not a data-loss event — the token is a cache of an
# authorization the user can re-grant, `User#github_access_token` returns nil rather than raising
# when the envelope will not open, and the registration flow then walks the user through
# authorizing again. Set the three keys explicitly if you would rather decouple the two.
module SpecGuard
  module EncryptionKeys
    class << self
      def primary_key = resolve(:primary_key)
      def deterministic_key = resolve(:deterministic_key)
      def key_derivation_salt = resolve(:key_derivation_salt)

      private

      def resolve(key)
        ENV["ACTIVE_RECORD_ENCRYPTION_#{key.to_s.upcase}"].presence || credential(key) || derived(key)
      end

      def credential(key)
        Rails.application.credentials.dig(:active_record_encryption, key).presence
      rescue StandardError
        nil
      end

      # `generate_key` returns raw bytes; Active Record Encryption stores and compares these as
      # strings, so they are hex-encoded rather than handed over with arbitrary binary in them.
      def derived(key)
        generator = ActiveSupport::KeyGenerator.new(Rails.application.secret_key_base, hash_digest_class: OpenSSL::Digest::SHA256)
        generator.generate_key("specguard/active_record_encryption/#{key}", 32).unpack1("H*")
      end
    end
  end
end

Rails.application.config.active_record.encryption.primary_key = SpecGuard::EncryptionKeys.primary_key
Rails.application.config.active_record.encryption.deterministic_key = SpecGuard::EncryptionKeys.deterministic_key
Rails.application.config.active_record.encryption.key_derivation_salt = SpecGuard::EncryptionKeys.key_derivation_salt

# The token column is written by the OAuth callback and read by the GitHub client. Nothing queries
# *by* it, and nothing needs to — so it is non-deterministically encrypted (a fresh IV per write),
# which is the stronger of the two modes. This setting only decides what an unqualified
# `encrypts` means; it is stated here so the choice is visible rather than inherited.
Rails.application.config.active_record.encryption.support_unencrypted_data = false
