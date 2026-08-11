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

  # Archiving is an offboarding control, and a control that only bites the next time somebody
  # chooses to sign in is one they simply outlast. Both halves are asserted: the door, and the
  # session already on the other side of it.
  describe "an archived user" do
    it "is refused at the callback, and is not reactivated by it" do
      user = sign_in_via_github
      delete sign_out_path
      user.update!(archived_at: Time.current)
      archived_at = user.reload.archived_at

      expect { sign_in_via_github }.not_to change(User, :count)

      # No session was established.
      expect(session[:user_id]).to be_nil
      expect(response).to redirect_to(root_path)
      follow_redirect!
      expect(response.body).to include("has been archived")

      # And the callback did not undo the archiving — otherwise an archived person offboards
      # themselves back in by visiting this URL, and the control means nothing.
      expect(user.reload.archived_at).to eq(archived_at)
      expect(user).to be_archived

      # Still refused on the way to any signed-in page.
      get repositories_path
      expect(response).to redirect_to(root_path)
    end

    # The identity upsert stays a pure upsert: it still refreshes the row it resolved. That is
    # deliberate (the row was already theirs and the refresh grants nothing), and pinned here so it
    # reads as a decision rather than as a leak someone should "fix".
    it "still has its identity row refreshed by the refused attempt" do
      user = sign_in_via_github
      user.update!(archived_at: Time.current)

      sign_in_via_github(info: { nickname: "octocat-renamed" })

      expect(user.reload.github_handle).to eq("octocat-renamed")
      expect(user).to be_archived
    end

    it "stops authenticating with the session it was already holding" do
      user = sign_in_via_github

      get repositories_path
      expect(response).to have_http_status(:ok)

      user.update!(archived_at: Time.current)

      # Same session, no new request to the callback — the live session simply stops working.
      get repositories_path
      expect(response).to redirect_to(root_path)
      follow_redirect!
      expect(response.body).to include("Sign in with GitHub to continue")
    end
  end
end
