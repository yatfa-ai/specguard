# frozen_string_literal: true

# A human, identified by their GitHub OAuth identity. `github_uid` is the stable key — a user may
# rename their GitHub handle and must still resolve to the same row.
class User < ApplicationRecord
  has_many :repositories, dependent: :destroy
  # Both sides of the membership declare `dependent: :destroy`; dropping either one leaves the
  # foreign key to fail on destroy.
  has_many :repository_memberships, dependent: :destroy
  # Repositories shared *with* this user — deliberately separate from `repositories`, which stays
  # "repositories this user owns" and is what RepositoriesController#index still lists.
  has_many :member_repositories, through: :repository_memberships, source: :repository

  validates :github_uid, presence: true, uniqueness: true
  validates :github_handle, presence: true

  # Upsert from an OmniAuth::AuthHash (or anything that quacks like one).
  def self.from_github_omniauth(auth)
    info = auth["info"] || {}

    find_or_initialize_by(github_uid: auth["uid"].to_s).tap do |user|
      user.github_handle = info["nickname"].presence || info["name"].presence || auth["uid"].to_s
      user.email = info["email"]
      user.avatar_url = info["image"]
      user.save!
    end
  end

  def display_name = github_handle
end
