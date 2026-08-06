# frozen_string_literal: true

module MembershipsHelper
  # The copy in the revoke confirm dialog.
  #
  # Revoking a membership deliberately does not touch the API keys that member minted (see
  # `User has_many :created_api_keys, dependent: :nullify`), so when there are any, the dialog has
  # to name that consequence *before* the click rather than let the owner discover it later. A
  # member who minted nothing keeps the original one-sentence question verbatim — a dialog that
  # mentions keys that do not exist is noise, and would train the owner to skim it.
  #
  # The counterpart after the click is `MembershipsController#revoke_notice`; keep the two honest
  # about the same number.
  def revoke_confirmation(repository, handle, keys_minted)
    question = "Revoke #{handle}'s access to #{repository.github_full_name}?"
    return question if keys_minted.zero?

    "#{question} The #{pluralize(keys_minted, "API key")} they minted will keep authenticating " \
      "until you revoke #{keys_minted == 1 ? "it" : "them"}."
  end
end
