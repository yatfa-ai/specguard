# frozen_string_literal: true

# Making one repository's first-key mint fail, so the batch's per-candidate rescue is exercised
# rather than described — SPGD-806.
#
# `BulkRegistration#mint_first_key` rescues `StandardError` per candidate because a batch's contract
# is that it "is not a transaction and deliberately not an all-or-nothing": an unrescued `create!`
# would let one key failure destroy the other ninety-nine registrations. What that leaves behind is
# a candidate that is `:registered` with `api_key` nil — a state BOTH layers have to handle, which
# is why this lives in `spec/support` rather than inside one example group. The service spec asks
# what the outcome carries; the request spec asks what the PAGE does with a registered row that has
# no token, and that second question is the one `Result#any_revealed?` exists to answer.
#
# == Why the failure is made REAL rather than stubbed onto `save!`
#
# A `create!` on a record whose `name` is blank raises `ActiveRecord::RecordInvalid` through the
# real save path, so the rescue is reached exactly as it would be in production. Stubbing `save!` on
# `any_instance` cannot do that here: `and_wrap_original`'s `original.call` does not persist through
# an `any_instance` stub, so the OTHER repositories' keys would silently fail to be written too, and
# an example measuring "the batch survived" would pass while measuring nothing.
#
# == Why the stub is on the CLASS and keyed by repository
#
# `ApiKey.new` is the one seam every `api_keys.create!` in the batch passes through, and the built
# record already knows its own `repository` — so a single wrap can aim the failure at ONE name and
# leave the rest to save for real. That is what lets an example tell "the batch survived the
# failure" apart from "the batch stopped at it": a rescue that aborted the loop would still leave
# the rows before the failure registered, and would pass a weaker assertion.
module ApiKeyMintFailure
  # Break the mint for exactly these repositories, by full name. Every other repository in the batch
  # still gets a real, persisted key.
  def fail_the_mint_for(*full_names)
    targets = full_names.flatten

    allow(ApiKey).to receive(:new).and_wrap_original do |original, *args, &block|
      key = original.call(*args, &block)
      key.name = nil if targets.include?(key.repository&.github_full_name)
      key
    end
  end
end

RSpec.configure do |config|
  config.include ApiKeyMintFailure
end
