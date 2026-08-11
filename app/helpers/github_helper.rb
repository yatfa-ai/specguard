# frozen_string_literal: true

# The GitHub authorization affordance, in one place because it is asked for from three different
# situations that all resolve the same way: the user has never granted repository access, their
# token stopped working, or a verification came back needing a grant rather than an edit.
module GithubHelper
  # POSTs to the OmniAuth request phase with the broader scope in the query string —
  # omniauth-github promotes a request-phase `scope` parameter over the provider's configured one
  # (OmniAuth::Strategies::GitHub#authorize_params), which is what makes incremental authorization
  # possible without mounting a second provider.
  #
  # `origin` is OmniAuth's own return-to mechanism: it is stashed during the request phase and read
  # back in `SessionsController#create`, so the user lands where they were rather than on the
  # dashboard. It is validated there, not here — a helper that builds the link is not the place
  # that has to be right about an open redirect.
  def github_repository_authorization_path(origin: nil)
    github_auth_path(scope: SpecGuard::GithubOauth::REPOSITORY_SCOPE, origin: origin || request.fullpath)
  end

  # `turbo: false` is load-bearing, for the reason pages/home.html.erb states in full at the
  # sign-in button: OmniAuth answers this POST with a 302 to github.com, Turbo drives `button_to`
  # through `fetch`, and a `fetch` cannot follow a cross-origin redirect — the click silently does
  # nothing. A native browser POST follows it normally.
  def github_authorize_button(label = "Connect GitHub repositories", origin: nil, variant: :primary)
    button_to label, github_repository_authorization_path(origin: origin),
              form: { data: { turbo: false } },
              class: UI::ButtonComponent.classes(variant: variant)
  end

  # What the app is about to be able to read, said plainly at the moment it is asked for rather
  # than left to GitHub's consent screen to phrase. The scope is broad and pretending otherwise
  # would be the wrong trade to hide.
  def github_authorization_disclosure
    "SpecGuard will ask GitHub for access to your repositories. It reads two things: the list of " \
      "repositories you can pick from, and whether you administer the one you pick. It stores " \
      "nothing from GitHub beyond the org/repo you register, and you can revoke the access at any " \
      "time from your GitHub settings."
  end

  # What the picker offers: the repositories GitHub says this user administers, and nothing else.
  #
  # Non-admin repositories are withheld rather than listed-and-rejected. A user can see plenty of
  # repositories they cannot administer — every public repo they have ever collaborated on — and
  # offering one as a choice would be offering a click that can only end in a 422. The count of
  # what was withheld is reported in the hint, so the list is short without being mysterious.
  #
  # A persisted name is prepended when GitHub's list does not contain it, which is the rename
  # form's case: a repository registered before verification existed, or one past the listing cap,
  # must still be representable by the control that shows the current value. It is a *display*
  # concession only — submitting it unchanged writes nothing, and submitting it as a change is
  # verified like any other value.
  def repository_choices(listing, repository)
    administered = administered_repos(listing)
    choices = administered.map { |repo| [repository_choice_label(repo), repo.full_name] }

    current = repository.persisted? ? repository.github_full_name_was : nil
    return choices if current.blank? || administered.any? { |repo| repo.full_name == current }

    choices.unshift([current, current])
  end

  # Beneath the field, because each of these changes what an *absent* repository means, and a
  # picker that silently omits things is a picker people stop trusting.
  def repository_picker_hint(listing)
    sentences = ["Only repositories you administer on GitHub can be registered."]

    withheld = listing.repos.length - administered_repos(listing).length
    if withheld.positive?
      sentences << "#{pluralize(withheld, 'repository', plural: 'repositories')} you do not " \
                   "administer #{withheld == 1 ? 'is' : 'are'} not listed."
    end

    if listing.truncated?
      sentences << "Showing the first #{GithubApi::MAX_PAGES * GithubApi::PER_PAGE} repositories " \
                   "GitHub returned."
    end

    sentences.join(" ")
  end

  private

  def administered_repos(listing)
    @administered_repos ||= {}
    @administered_repos[listing] ||= listing.repos.select(&:admin?).sort_by { |repo| repo.full_name.downcase }
  end

  # `private` and `archived` change what registering the repository will *mean* — a private one is
  # why the broad scope was needed, and an archived one will never push another CI run — so they
  # are on the option itself rather than discoverable only after registering.
  def repository_choice_label(repo)
    notes = []
    notes << "private" if repo.private?
    notes << "archived" if repo.archived?

    notes.any? ? "#{repo.full_name} · #{notes.join(', ')}" : repo.full_name
  end
end
