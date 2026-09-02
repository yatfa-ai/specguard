# frozen_string_literal: true

require "rails_helper"

RSpec.describe "GitHub sign-in", type: :request do
  # @intent: {"entity": "Session", "action": "sign in new user", "behavior": "completing the GitHub callback without an installation creates exactly one User row, redirects to /repositories, and the followed page includes the octocat handle", "layer": "request"}
  it "signs a new user in and lands them on their repositories" do
    # `installation: false` because this example is about the SIGN-IN response. Connecting an
    # installation drives the App's callback afterwards, which would leave `response` on the page
    # that redirect landed on — and signing in connects nothing anyway, which is the point.
    expect { sign_in_via_github(installation: false) }.to change(User, :count).by(1)

    expect(response).to redirect_to(repositories_path)
    follow_redirect!
    expect(response.body).to include("octocat")
  end

  # @intent: {"entity": "Session", "action": "reuse existing user", "behavior": "a second GitHub callback for the same identity leaves User.count unchanged instead of creating a duplicate row", "layer": "request"}
  it "reuses the existing user on a second sign-in" do
    sign_in_via_github

    expect { sign_in_via_github }.not_to change(User, :count)
  end

  # `github_handle` carries no uniqueness constraint on purpose: a recycled GitHub handle can
  # legitimately collide with an existing row's, and a constraint would turn that into a 500 in the
  # sign-in path for the innocent second person. Ambiguity is reported by `User.resolve_by_handle`.
  # @intent: {"entity": "Session", "action": "sign in colliding handle", "behavior": "a second uid also nicknamed octocat creates its own User row and redirects to /repositories, both uids 1001 and 2002 hold the handle, and resolve_by_handle reports it ambiguous", "layer": "request"}
  it "signs a second user in when their handle collides with an existing row's" do
    sign_in_via_github(uid: "1001", info: { nickname: "octocat" }, installation: false)

    expect do
      sign_in_via_github(uid: "2002", info: { nickname: "octocat" }, installation: false)
    end.to change(User, :count).by(1)

    expect(response).to redirect_to(repositories_path)
    expect(User.where(github_handle: "octocat").pluck(:github_uid)).to contain_exactly("1001", "2002")
    expect(User.resolve_by_handle("octocat")).to be_ambiguous
  end

  # @intent: {"entity": "Session", "action": "sign out", "behavior": "DELETE /sign_out redirects to the root path and a follow-up GET /repositories redirects there too instead of rendering the dashboard", "layer": "request"}
  it "signs the user out again" do
    sign_in_via_github

    delete sign_out_path
    expect(response).to redirect_to(root_path)

    get repositories_path
    expect(response).to redirect_to(root_path)
  end

  # @intent: {"entity": "Session", "action": "refuse signed-out dashboard", "behavior": "a signed-out GET /repositories redirects to the root path rather than rendering the dashboard", "layer": "request"}
  it "sends a signed-out visitor away from the dashboard" do
    get repositories_path

    expect(response).to redirect_to(root_path)
  end

  # @intent: {"entity": "Session", "action": "report provider failure", "behavior": "GET /auth/failure with message invalid_credentials redirects to the root path and the followed page shows the invalid_credentials message instead of raising", "layer": "request"}
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
    # @intent: {"entity": "Session", "action": "refuse archived user", "behavior": "an archived account attempting the callback creates no User row, leaves session user_id nil, redirects to root with a page saying has been archived, keeps archived_at unchanged, and a later GET /repositories still redirects to root", "layer": "request"}
    it "is refused at the callback, and is not reactivated by it" do
      user = sign_in_via_github(installation: false)
      delete sign_out_path
      user.update!(archived_at: Time.current)
      archived_at = user.reload.archived_at

      expect { sign_in_via_github(installation: false) }.not_to change(User, :count)

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

    # SPGD-853 gave this state a second way of being reached: the person closing their own
    # account from `/account`. The refusal cannot tell a self-closure from a console archive,
    # so its alert answers both — and THIS is the pin that keeps it answering the self-closed
    # reader first. The previous copy's only guidance ("contact whoever administers your
    # SpecGuard instance") named an authority the product has never had, and was written when
    # the console was the only way in; without this assertion a future copy edit could quietly
    # reintroduce it as the whole answer.
    # @intent: { entity: "Session", action: "disclose one-way closure at refusal", behavior: "the refused callback's alert tells a self-closed person that closure cannot be undone from within SpecGuard and keeps the operator pointer only for the unexpected case", layer: "request" }
    it "tells a person who closed their own account the truth about recovery" do
      user = sign_in_via_github(installation: false)
      delete sign_out_path
      user.update!(archived_at: Time.current)

      sign_in_via_github(installation: false)
      follow_redirect!

      expect(response.body).to include("has been archived")
      expect(response.body).to include("If you closed it yourself, closure cannot be undone " \
                                       "from within SpecGuard")
      expect(response.body).not_to include("If this is unexpected")
    end

    # The identity upsert stays a pure upsert: it still refreshes the row it resolved. That is
    # deliberate (the row was already theirs and the refresh grants nothing), and pinned here so it
    # reads as a decision rather than as a leak someone should "fix".
    # @intent: {"entity": "Session", "action": "refresh archived identity", "behavior": "the refused callback still upserts the identity, renaming the archived user handle to octocat-renamed while the account stays archived", "layer": "request"}
    it "still has its identity row refreshed by the refused attempt" do
      user = sign_in_via_github
      user.update!(archived_at: Time.current)

      sign_in_via_github(info: { nickname: "octocat-renamed" })

      expect(user.reload.github_handle).to eq("octocat-renamed")
      expect(user).to be_archived
    end

    # @intent: {"entity": "Session", "action": "revoke live session", "behavior": "a session that already rendered GET /repositories 200 starts redirecting to root with a Sign in with GitHub to continue prompt once its user is archived, with no new callback request", "layer": "request"}
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
