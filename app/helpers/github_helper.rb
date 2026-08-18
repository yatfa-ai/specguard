# frozen_string_literal: true

# The GitHub App installation affordance, in one place because it is asked for from three different
# situations that all resolve the same way: the user has never installed the App, they installed it
# and the repository they want is not in it, or a registration came back needing an installation
# rather than a different pick.
module GithubHelper
  # POSTs to the flow that sends the user to GitHub to install the App and choose repositories.
  #
  # POST rather than a link, and CSRF-protected as any other POST, so a third-party page cannot
  # bounce a signed-in user into an installation flow they did not ask for.
  #
  # `return_to` round-trips through GitHub's `state` parameter, so the user lands where they were
  # rather than on the dashboard. It is validated when it comes back, not here — a helper that
  # builds the button is not the place that has to be right about an open redirect.
  #
  # It falls back to `request.fullpath`, which is only right when the button is rendered by a GET
  # of the page you want to come back to. A caller rendering this inside a non-GET response — a 422
  # re-render, say — must pass it explicitly, or it will send the user back to a path that renders
  # nothing. See `repositories/_form`, which does.
  #
  # `turbo: false` is load-bearing, for the reason pages/home.html.erb states in full at the
  # sign-in button: the action answers with a 302 to github.com, Turbo drives `button_to` through
  # `fetch`, and a `fetch` cannot follow a cross-origin redirect — the click silently does nothing.
  # A native browser POST follows it normally.
  #
  # ## On an unconfigured instance this is the reason, not the button
  #
  # Development and test never have real App credentials, and an instance whose operator has not set
  # them yet is an ordinary state of the world rather than a bug. The button would still render, and
  # clicking it would bounce the reader to a github.com URL built from placeholders — a 404 on
  # somebody else's site with nothing here to explain it. `GithubInstallationsController` refuses the
  # POST for the same reason, so this is the affordance agreeing with the gate rather than a second
  # opinion about it: what a reader cannot do, they are told about instead of offered.
  #
  # One place rather than a branch at each of the three call sites, because three copies of "is the
  # App configured" is three chances for one of them to keep offering a button that cannot work.
  def github_install_button(label = "Connect repositories on GitHub", return_to: nil, variant: :primary)
    return github_app_unconfigured_notice unless SpecGuard::GithubApp.configured?

    button_to label, github_installation_path(return_to: return_to || request.fullpath),
              form: { data: { turbo: false } },
              class: UI::ButtonComponent.classes(variant: variant)
  end

  # Named in the same shape as the sign-in path's own unconfigured notice (pages/home.html.erb), so
  # an operator who has met one recognises the other. It names the variables rather than saying
  # "contact your administrator", because on this app the reader frequently IS the administrator.
  def github_app_unconfigured_notice
    render UI::AlertComponent.new(tone: :warning, title: "The SpecGuard GitHub App is not configured") do
      tag.span(safe_join([
        "Set ", tag.code("GITHUB_APP_ID"), ", ", tag.code("GITHUB_APP_SLUG"), ", ",
        tag.code("GITHUB_APP_PRIVATE_KEY"), ", ", tag.code("GITHUB_APP_CLIENT_ID"), " and ",
        tag.code("GITHUB_APP_CLIENT_SECRET"), " (or the ", tag.code("github_app"),
        " credentials) and restart the app. See ", tag.code("config/initializers/github_app.rb"), "."
      ]))
    end
  end

  # What is about to happen, said plainly at the moment it is offered rather than left to GitHub's
  # consent screen to phrase. The consent screen itself is GitHub's, rendered from the App's own
  # configuration; this is the sentence before it, not a copy of it.
  def github_installation_disclosure
    "SpecGuard connects repositories through a GitHub App. You choose which repositories it is " \
      "installed on, in GitHub's own picker, and it asks for read-only access to their metadata — " \
      "not their code. Only someone who administers a repository can install it, which is how " \
      "SpecGuard knows a repository is yours to register. You can change the selection or uninstall " \
      "it at any time from your GitHub settings."
  end

  # What the picker offers: exactly the repositories in the user's installation(s).
  #
  # There is no filtering left to do here, and its absence is the point of this slice. The old
  # picker withheld repositories the user could see but did not administer — a distinction the
  # OAuth listing forced on it, because `GET /user/repos` returned every repository the user had any
  # relationship with. An installation contains only what somebody who administers those
  # repositories deliberately selected, so everything in it is registerable and nothing is withheld.
  #
  # A persisted name is prepended when GitHub's list does not contain it, which is the rename form's
  # case: a repository registered before the installation changed, or one past the listing cap, must
  # still be representable by the control that shows the current value. It is a *display* concession
  # only — submitting it unchanged writes nothing, and submitting it as a change is verified like
  # any other value.
  def repository_choices(listing, repository)
    choices = listing.repos.map { |repo| [repository_choice_label(repo), repo.full_name] }

    current = repository.persisted? ? repository.github_full_name_was : nil
    return choices if current.blank? || listing.repos.any? { |repo| repo.full_name == current }

    choices.unshift([current, current])
  end

  # Beneath the field, because each of these changes what an *absent* repository means, and a picker
  # that silently omits things is a picker people stop trusting.
  def repository_picker_hint(listing)
    sentences = ["These are the repositories the SpecGuard GitHub App is installed on. " \
                 "Add more from your GitHub settings."]

    if listing.truncated?
      sentences << "Showing the first #{GithubApi::MAX_PAGES * GithubApi::PER_PAGE} repositories " \
                   "GitHub returned."
    end

    sentences.join(" ")
  end

  private

  # `private` and `archived` change what registering the repository will *mean* — an archived one
  # will never push another CI run — so they are on the option itself rather than discoverable only
  # after registering.
  def repository_choice_label(repo)
    notes = []
    notes << "private" if repo.private?
    notes << "archived" if repo.archived?

    notes.any? ? "#{repo.full_name} · #{notes.join(', ')}" : repo.full_name
  end
end
