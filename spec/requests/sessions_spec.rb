# frozen_string_literal: true

require "rails_helper"

RSpec.describe "GitHub sign-in", type: :request do
  it "signs a new user in and lands them on their repositories" do
    expect { sign_in_via_github }.to change(User, :count).by(1)

    expect(response).to redirect_to(repositories_path)
    follow_redirect!
    expect(response.body).to include("octocat")
  end

  it "reuses the existing user on a second sign-in" do
    sign_in_via_github

    expect { sign_in_via_github }.not_to change(User, :count)
  end

  # `github_handle` carries no uniqueness constraint on purpose: a recycled GitHub handle can
  # legitimately collide with an existing row's, and a constraint would turn that into a 500 in the
  # sign-in path for the innocent second person. Ambiguity is reported by `User.resolve_by_handle`.
  it "signs a second user in when their handle collides with an existing row's" do
    sign_in_via_github(uid: "1001", info: { nickname: "octocat" })

    expect { sign_in_via_github(uid: "2002", info: { nickname: "octocat" }) }.to change(User, :count).by(1)

    expect(response).to redirect_to(repositories_path)
    expect(User.where(github_handle: "octocat").pluck(:github_uid)).to contain_exactly("1001", "2002")
    expect(User.resolve_by_handle("octocat")).to be_ambiguous
  end

  it "signs the user out again" do
    sign_in_via_github

    delete sign_out_path
    expect(response).to redirect_to(root_path)

    get repositories_path
    expect(response).to redirect_to(root_path)
  end

  it "sends a signed-out visitor away from the dashboard" do
    get repositories_path

    expect(response).to redirect_to(root_path)
  end

  it "reports a provider failure instead of raising" do
    get "/auth/failure", params: { message: "invalid_credentials" }

    expect(response).to redirect_to(root_path)
    follow_redirect!
    expect(response.body).to include("invalid_credentials")
  end
end
