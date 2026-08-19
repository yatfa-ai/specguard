# frozen_string_literal: true

# WHAT GITHUB SAID ABOUT ONE PERSON'S REPOSITORIES, WHILE A BROWSER SESSION STILL HELD THE TOKEN
# THAT COULD ASK.
#
# Registration has always been gated on GitHub's answer to "may this person register this
# repository?", and that answer is only obtainable with a user-to-server token — which lives in the
# session and nowhere else (`GithubUserSession`). An agent holding an `sgu_` API key has no session
# and therefore no way to ask. This table is the snapshot taken at the one moment somebody CAN ask,
# so the answer can be redeemed later by a request that cannot.
#
# ## One row per user, replaced wholesale
#
# The unique index on `user_id` is the schema half of that rule. The grant is a statement about a
# PERSON's GitHub access — not about a key — because a key's reach is deliberately its holder's
# reach, and a per-key snapshot would both narrow that and let one person accumulate three
# divergent grants across three keys. Every refresh REPLACES both arrays; nothing is merged in,
# because a merge would accumulate repositories the person has since lost admin on, which is the
# exact failure the ownership gate exists to prevent.
#
# ## Two arrays, and only one of them grants anything
#
# `registrable_full_names` is `InstallationRepositories::Sources#registrable` — the repositories
# GitHub reports this person as an ADMINISTRATOR of. It is the whole of what permits a
# registration.
#
# `visible_full_names` is `Sources#repos` — everything they can see across their installations,
# administered or not. It permits NOTHING. It exists so that a refusal can be worded correctly:
# "you are not an administrator of it" and "it is not in the installation" are different sentences
# with different fixes, and the web path tells them apart because it has the live listing in hand.
# Without this column the redeemed path would have to collapse both into the second, which is a
# false statement to make to the ordinary non-admin member of an organization.
#
# Both are stored DOWNCASED, because GitHub logins and repository names are compared
# case-insensitively everywhere else this question is asked (`InstallationRepositories.verify_batch`
# keys on `full_name.downcase`).
#
# ## `captured_at` is not `updated_at`
#
# It is the age the redemption bound is measured against, and it must move only when a reading was
# actually taken and accepted. `updated_at` moves on any write to the row; this moves when GitHub
# was asked and answered COMPLETELY. An incomplete reading leaves both the arrays and this stamp
# exactly as they were — see `GithubRegistrationGrant.capture`.
class CreateGithubRegistrationGrants < ActiveRecord::Migration[8.1]
  def change
    create_table :github_registration_grants do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }

      t.jsonb :registrable_full_names, null: false, default: []
      t.jsonb :visible_full_names, null: false, default: []

      # No default: a row that exists without a stamp would be a grant of unknown age, and the
      # staleness bound could not be applied to it.
      t.datetime :captured_at, null: false

      t.timestamps
    end
  end
end
