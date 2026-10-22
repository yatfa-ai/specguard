# frozen_string_literal: true

# The `name` (and the form root it nests under) of a key-mint request, read shape-safely.
#
# ONE MODULE, FOUR CONTROLLERS, TWO BASES — the argument `RequestedBranchParam` makes for itself.
# It is included into the three web mint forms (`ApiKeysController`, `UserApiKeysController`,
# `AgentApiKeysController`, all `ActionController::Base`) and the JSON mint
# (`Api::V1::UserRepositoryApiKeysController`, an `ActionController::API`). It reads `params` and
# nothing else, so the differing bases were never an obstacle to sharing it. Do not let it grow a
# reach that changes that.
#
# Two guards, because the unguarded reads fail in two different ways:
#
# `mint_form_root` — `params.dig(:api_key, :name)` on `api_key=x` raises a TypeError (a scalar
# does not answer `dig`), and `params.fetch(:agent_api_key, {}).permit(...)` on `agent_api_key=x`
# raises NoMethodError (a String does not answer `permit`); both surface as an HTML 500 on a form
# POST anyone can type. A root that is not `ActionController::Parameters` is treated as an absent
# root, which is the answer an omitted root already gets: an empty mint, which each controller
# answers with its own existing behavior (a default-named key for the two single-credential forms,
# the model's empty-grant refusal for the agent form).
#
# `mint_key_name` — a Hash or Array `name` (`name[a]=b`, `name[]=b`, or the same in a JSON body)
# is truthy and answers `.presence`, so it used to be stored as its Ruby inspect string
# (`{"a"=>"b"}`) and the API still answered 201. Anything that is not a String is treated as no
# ask and gets the default, the same answer an absent or blank name gets. A String — one carrying a
# NUL included — passes through unchanged, so the model's NUL and length validators (SPGD-1476,
# SPGD-1877) still answer with their own sentences rather than being pre-empted here.
module MintKeyNameParam
  extend ActiveSupport::Concern

  private

  # The form root under `key`, or an empty `ActionController::Parameters` when it is absent or not
  # a hash-shaped value.
  def mint_form_root(key)
    root = params[key]
    root.is_a?(ActionController::Parameters) ? root : ActionController::Parameters.new
  end

  # `raw` as the key's name, or `default` when it is blank or not a String.
  def mint_key_name(raw, default)
    raw.is_a?(String) ? raw.presence || default : default
  end
end
