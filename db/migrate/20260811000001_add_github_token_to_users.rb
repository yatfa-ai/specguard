# frozen_string_literal: true

# The OAuth access token was previously discarded the instant sign-in finished (SessionsController
# read `omniauth.auth`, kept `uid`/`info`, and dropped `credentials` on the floor). Nothing in the
# app could ask GitHub a question on the user's behalf, which is why repository registration was a
# free-text slug field with no ownership check behind it.
#
# `github_access_token` is `text` rather than `string` because it does not store the token: it
# stores Active Record Encryption's envelope around it (ciphertext plus headers as JSON), which is
# several times the plaintext length and has no useful bound. See `User.encrypts`.
#
# `github_token_scopes` holds what GitHub actually granted, verbatim from the token response's
# `scope` field, and is deliberately NOT encrypted — it is the question "may we call the repos
# API yet", asked on the registration path, and it names no secret. Storing it is what makes
# incremental authorization possible: sign-in stays at the minimal scope and the broader scope is
# requested only when the user first registers a repository.
class AddGithubTokenToUsers < ActiveRecord::Migration[8.1]
  def change
    change_table :users, bulk: true do |t|
      t.text :github_access_token
      t.string :github_token_scopes
      t.datetime :github_token_updated_at
    end
  end
end
