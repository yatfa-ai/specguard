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
        "Set ", tag.code("GITHUB_APP_SLUG"), ", ", tag.code("GITHUB_APP_CLIENT_ID"), " and ",
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
      "not their code. You can register the ones GitHub lists you as an administrator of. You can " \
      "change the selection or uninstall it at any time from your GitHub settings."
  end

  # The other button, for the other missing thing. The App is installed and this session simply has
  # no credential to read it with — so this asks GitHub for one and asks for nothing else. For
  # anyone who has authorized the App before, GitHub renders no screen: they leave and come back.
  #
  # Deliberately worded as reconnecting rather than as an error. Nothing is broken and nothing the
  # user did caused it; a session ended, which is the most ordinary thing that can happen to one.
  def github_authorize_button(label = "Reconnect to GitHub", return_to: nil, variant: :primary)
    return github_app_unconfigured_notice unless SpecGuard::GithubApp.configured?

    button_to label, github_installation_authorize_path(return_to: return_to || request.fullpath),
              form: { data: { turbo: false } },
              class: UI::ButtonComponent.classes(variant: variant)
  end

  # What the picker offers: exactly the repositories in the user's installation(s).
  #
  # There is no filtering left to do HERE, and that is a statement about this method rather than
  # about the policy: `InstallationRepositories::Sources#listing` has already dropped everything the
  # viewer does not administer, so a listing that reaches a view is registerable in full. Deciding
  # it there rather than here is what keeps the offered set and the accepted set the same object —
  # a picker that offers what the write will refuse is worse than no picker.
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
  #
  # `withheld:` is how many repositories this viewer can reach but is not an administrator of — the
  # ordinary position of every read-only member of every organization that installs the App, and the
  # single most likely reason a reader's repository is not in the list. Defaulted rather than
  # required only because a caller with no sources cannot know it; every real caller passes it.
  def repository_picker_hint(listing, withheld: 0)
    sentences = ["These are the repositories the SpecGuard GitHub App is installed on that GitHub " \
                 "lists you as an administrator of. Add more from your GitHub settings."]

    sentences << withheld_repositories_sentence(withheld)

    if listing.truncated?
      sentences << "Showing the first #{GithubApi::MAX_PAGES * GithubApi::PER_PAGE} repositories " \
                   "GitHub returned."
    end

    sentences.compact.join(" ")
  end

  # "3 connected repositories you do not administer are not listed." — the sentence that keeps a
  # short list from being a mysterious one, and `nil` when nothing was withheld.
  #
  # One definition for the four places that say it (the single-repository picker's hint and its
  # nothing-to-offer empty state, the organization card, the organization's repository list). It is
  # the same fact each time, and four copies is four chances for one of them to disagree about the
  # verb — which is exactly the kind of drift that makes a reader wonder whether they mean different
  # things.
  #
  # It says "connected" as well as "you do not administer" because BOTH conditions are load-bearing
  # and a reader who is told only one will fix the wrong thing: these are repositories already in
  # the installation, so installing the App again on them changes nothing, and the way to register
  # one is for somebody who administers it to do so.
  #
  # Composed as one String rather than assembled across ERB lines, deliberately: interpolating a
  # `pluralize` mid-sentence in a template puts a newline inside the sentence, which reads fine in a
  # browser and is invisible to anything matching on the text.
  def withheld_repositories_sentence(count)
    return nil unless count.to_i.positive?

    "#{pluralize(count, 'connected repository', plural: 'connected repositories')} you do not " \
      "administer #{count == 1 ? 'is' : 'are'} not listed."
  end

  # "SpecGuard could not read acme just now. Repositories connected through that account are
  # missing from this list. Anything shown here can still be registered." — the short-list notice,
  # with the account NAMED, and `nil` when nothing is missing.
  #
  # One definition for the two pages that show it (the single-repository picker, the organization
  # chooser), for the reason `withheld_repositories_sentence` states in full: it is the same fact
  # on both, and two copies is two chances for one to disagree about what it means. Before this
  # they both said "One of your GitHub App installations could not be read", which named nothing —
  # a user with `acme` and `globex` connected could not tell whether the one that failed was the
  # organization they came to register.
  #
  # `missing:` is the only thing the two pages differ on and is a plural noun beginning its own
  # sentence: the single-repository picker is missing REPOSITORIES, the bulk chooser can be missing
  # whole ACCOUNTS, which is the sharper version of the same warning. Everything else — which
  # accounts, which failure, what to do — is decided here.
  #
  # That second noun is ACCOUNTS and not ORGANIZATIONS because the bulk chooser groups every
  # namespace the viewer administers something in, personal ones included. It said "organizations"
  # while the chooser filtered to `owner_type == "Organization"`, and the noun was accurate then;
  # once the filter went, a solo developer whose chooser holds nothing but their own namespace was
  # being told that ORGANIZATIONS were missing from it. Withholding a true noun beats naming a
  # subset the page no longer shows.
  #
  # The two failures are worded apart because their fixes are different. An installation that would
  # not answer is a transient thing and may well answer on the next page load. An installation
  # GitHub reports as GONE will not come back on its own: an uninstall is the ordinary way one goes
  # stale, and reinstalling is done on GitHub. That second case is the one this page said NOTHING
  # about until now — a 404 contributes an empty listing and records no error by design, so there
  # was no error for a notice to key on and an entire account could leave the picker in silence.
  def unreadable_accounts_sentence(outcomes, missing:)
    unread = Array(outcomes).reject(&:read?)
    return nil if unread.empty?

    gone, failed = unread.partition(&:unreadable?)

    sentences = []

    if failed.any?
      sentences << "SpecGuard could not read #{failed.map(&:account).to_sentence} just now."
    end

    if gone.any?
      sentences << "GitHub no longer lists #{gone.map(&:account).to_sentence} as connected to " \
                   "SpecGuard — the App may have been uninstalled there, which is put right in " \
                   "your GitHub settings."
    end

    sentences << "#{missing} connected through #{unread.one? ? 'that account' : 'those accounts'} " \
                 "are missing from this list. Anything shown here can still be registered."

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
