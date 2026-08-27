# frozen_string_literal: true

# The GitHub App installation affordance, in one place because it is asked for from three different
# situations that all resolve the same way: the user has never installed the App, they installed it
# and the repository they want is not in it, or a registration came back needing an installation
# rather than a different pick.
module GithubHelper
  # The most bytes a `return_to` path may be before its repository names are dropped.
  #
  # Everything a `return_to` carries rides out through GitHub's `state` parameter, which is part of
  # a URL on github.com — so the bound is not ours to set and not one we can raise. Derived:
  #
  #   * budget the whole outbound GitHub URL under 2,000 bytes (the conservative de-facto ceiling
  #     across user agents and proxies);
  #   * `GITHUB_HOST` + `/login/oauth/authorize?client_id=…&state=` is 93 bytes of that, leaving
  #     ~1,900 for the escaped state. That term is deployment-dependent: it is measured here with
  #     the 35-character `PLACEHOLDER` client_id, and a shorter real one only buys slack (a 20-
  #     character client_id makes the prefix 78);
  #   * `URI.encode_www_form` escapes these paths at 1.193x, so ~1,900 escaped is ~1,590 RAW.
  #
  # 1,500 keeps a margin under that and is the constant below.
  #
  # Measured against what this helper emits, with 25-character names (`acmecorp/repository-00001`),
  # via `bulk_repositories_path` + `SpecGuard::GithubApp.authorization_url`:
  #
  #   names |   raw |  escaped
  #       1 |    88 |      106
  #      28 | 1,492 |    1,780   <- last size that carries names
  #      29 | 1,544 |    1,842   <- first size that drops them
  #     100 | 5,236 |    6,244   <- MAX_BATCH, comfortably over
  #
  # So the drop below is reached by ordinary batches rather than being theoretical, and `organization`
  # alone is 36 raw / 44 escaped. Across the whole legal range of 1..MAX_BATCH the worst outbound
  # GitHub URL this produces is 1,873 bytes — inside the 2,000 budget at every size.
  MAX_RETURN_TO_BYTES = 1_500

  # The query parameter a pending selection's handle rides back on. Named for what it IS to the
  # receiving page rather than for the row behind it: `BulkRegistrationsController#new` redeems it
  # into the same `@full_names` seam the `github_full_names[]` carry already populates, and the
  # picker's tick boxes never learn which of the two they were ticked by.
  SELECTION_PARAM = :selection

  # The bulk picker, with the batch that was just refused already selected.
  #
  # This is what the summary's three FIX buttons hand to `return_to:`, so that pressing the button
  # which actually resolves the refusal costs the reader no more than pressing the one beside it
  # that merely re-submits. Before this they carried a bare path: a reader whose batch was skipped
  # for a dead credential saw "Reconnect to GitHub" (the correct fix, which discarded every tick)
  # next to "Try these again" (which preserved all N ticks and fixed nothing), and had to press the
  # one that worked and then re-pick N repositories by hand.
  #
  # ## A HANDLE, not the list — and that is what makes the promise true at every size
  #
  # Everything here rides out through GitHub's `state`, so the byte bound above applies to whatever
  # this emits. Putting the NAMES in the path met that bound at 28 of the 100 sizes the product
  # accepts, and above 28 the whole list was dropped: a reader who ticked thirty, was refused,
  # pressed the button that fixes it and came back landed on an unticked list and re-picked thirty
  # by hand. The bound is not ours to raise, so the remedy is to stop measuring a batch against it.
  #
  # `PendingBulkSelection.capture` persists the selection and returns a ~22-byte handle. The path is
  # then `organization` + handle — about 51 bytes at ONE name and about 51 bytes at MAX_BATCH,
  # because it no longer carries a thing that grows. So the all-or-nothing drop below is no longer
  # reachable from this leg at any legal size, and a caller may say "already selected" without
  # asking how many.
  #
  # ## Two rules, and both are about what the reader can trust
  #
  # `organization` is carried whenever there is one and is never dropped. It is 44 escaped bytes for
  # the whole path and it alone is the difference between landing on the right picker and landing on
  # the account chooser — so it outranks the names. Blank means the POST did not come from the
  # picker and there is no account to name, and then this emits the bare path exactly as before: an
  # `organization=` with nothing after it would send the reader somewhere no worse but no better,
  # while claiming to know something we do not.
  #
  # Over the bound the names are dropped ENTIRELY rather than truncated, and that is deliberate. A
  # picker that comes back partially ticked is WORSE than one that comes back unticked, because the
  # reader submits believing it complete and silently loses the remainder without ever being told a
  # list was shortened. Degraded to the account alone is still strictly better than what this
  # replaced — right account, right list, ticks lost — and it is honest about it.
  #
  # ## `user:` is optional, and its absence is a live path rather than a courtesy
  #
  # A handle has to be scoped to somebody to be redeemable, so a caller with nobody to scope it to
  # cannot have one. That is not the only way to arrive at the URL carry, though, and the others are
  # ordinary: `capture` answers `nil` for an empty name list, and answers `nil` rather than raising
  # when the write does not land — a summary is a page that has already got what it came for, and a
  # database that will not take a row is not a reason to fail the render. Every one of those falls
  # through to the bounded name carry below, which still delivers the ticks at the 28 sizes it fits
  # and still degrades honestly above them. The old behaviour is the floor, not the ceiling.
  def bulk_picker_return_to(organization:, full_names: [], user: nil)
    return bulk_repositories_path if organization.blank?

    names = Array(full_names)
    handle = PendingBulkSelection.capture(user: user, organization: organization, full_names: names)
    return bulk_repositories_path(organization: organization, SELECTION_PARAM => handle.token) if handle

    carried = bulk_repositories_path(organization: organization, github_full_names: names)
    return carried if carried.bytesize <= MAX_RETURN_TO_BYTES

    bulk_repositories_path(organization: organization)
  end

  # Did a selection actually survive the trip out? Asked of what `bulk_picker_return_to` EMITTED,
  # never of the batch that went into it.
  #
  # This exists because a caller may want to say "and they will come back already selected", and
  # that sentence is not always true. The method above has ways of returning a path that carries no
  # selection — a blank `organization` yields the bare picker path, and an over-bound name list with
  # no handle behind it is dropped entirely — and a reader promised ticks who arrives at an unticked
  # list pays exactly the cost the promise told them they would not. So the promise is made
  # conditional on the answer.
  #
  # ONE predicate rather than one per reason, because the reasons are one state to the READER:
  # whatever the cause, the list comes back unticked and the sentence must not claim otherwise. The
  # same holds on the true side, and that is why this asks about EITHER carry: a handle and a name
  # list deliver the identical thing to the reader — a ticked picker — and a predicate that knew
  # only about names would call a handle-carrying path unticked and withdraw a sentence that is
  # true. What it must never do is answer from the batch that went IN, which is the one reading that
  # can promise ticks a path cannot deliver.
  #
  # It PARSES rather than re-deriving: it does not know `MAX_RETURN_TO_BYTES`, does not measure a
  # path, does not ask whether an organization was present, and does not resolve the handle. Those
  # rules stay in exactly one place, and this reads their result — so a change to the bound moves
  # the sentence with it and the two cannot drift into disagreeing on the same page.
  #
  # Not resolving the handle is deliberate rather than lazy. This answers "did the path carry a
  # selection", which is a question about the PATH; whether that selection still redeems is a
  # question about the far side of a trip that has not happened yet, and a page that answered it
  # here would be answering it an unknown number of minutes early. A handle that expires mid-trip
  # degrades on arrival to the right account and an unticked list — the same place every other
  # failure lands.
  def bulk_picker_carries_names?(return_to)
    query = URI.parse(return_to.to_s).query
    return false if query.blank?

    parsed = Rack::Utils.parse_nested_query(query)
    parsed["github_full_names"].present? || parsed[SELECTION_PARAM.to_s].present?
  end

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

  # What to say when there is no repository list to show at all, said once for the two pages that
  # have to say it (the single-repository form, the bulk picker).
  #
  # Two different reasons land here and they must not read the same: GitHub being down is
  # waitable, GitHub *refusing* is not. `github_listing_error_message` is nil only for the
  # genuine outage, which is the one case "try again shortly" is true of.
  #
  # No arguments, and that is a fact about the seam rather than a convenience. Everything this
  # branches on is `github_listing_error_message`, a `helper_method` declared on
  # `GithubRepositoryListing`, which both controller trees that render this include — which is why
  # the two copies this replaces were byte-identical rather than merely similar, and why one
  # definition can serve both without a caller passing anything down.
  #
  # The outage sentence is composed as one String rather than assembled across ERB lines, for the
  # reason `withheld_repositories_sentence` states in full: a sentence broken over template lines
  # carries a newline inside itself, which reads fine in a browser and is invisible to anything
  # matching on the text.
  def github_listing_unavailable_alert
    if github_listing_error_message
      render UI::AlertComponent.new(tone: :warning, title: "GitHub refused the request") do
        github_listing_error_message
      end
    else
      render UI::AlertComponent.new(tone: :warning, title: "GitHub is not answering right now") do
        "Your repository list could not be loaded, so there is nothing to pick from yet. " \
          "Try again shortly."
      end
    end
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
  #
  # ## `closing:` — the one clause that cannot be true on every page that shows this
  #
  # The account-naming sentences above are facts about GitHub and read identically wherever they
  # appear. The clause that FOLLOWS them is not: "Anything shown here can still be registered" is
  # an offer, and an EMPTY page is showing nothing to make it about. That page is now the sharpest
  # place this notice appears — a 404'd installation contributes no registrable repositories, so it
  # is most likely to be the reason the page is empty at all — and telling a reader with nothing in
  # front of them that what is in front of them is registerable is the kind of sentence that makes
  # them stop believing the rest of the panel.
  #
  # So the closing clause is selected rather than hardcoded, and it is selected HERE rather than
  # passed in as a string, which is the whole reason this helper exists: five call sites each
  # writing their own version is five chances to word the same fact differently. `:short_list` is
  # the default and is byte-for-byte what this method always emitted, so the two call sites that
  # render a picker are unchanged. `:empty_state` is what the branches with nothing to show pass.
  def unreadable_accounts_sentence(outcomes, missing:, closing: :short_list)
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

    sentences << unreadable_accounts_closing(closing, missing: missing, unread: unread)

    sentences.join(" ")
  end

  private

  # The clause that closes `unreadable_accounts_sentence`, chosen by what the page around it is
  # actually showing. Both forms say the same two things — WHAT is missing, and what the reader can
  # still do — and they differ only because the answer to the second is different when the page is
  # empty.
  #
  # `:short_list` is the picker's: something WAS read, it is on the page, and it is registerable.
  #
  # `:empty_state` is for the branches that render no list at all. It must not close with "anything
  # shown here can still be registered", which is a claim about a page that is showing nothing —
  # and on the sole-installation 404 it is worse than merely vacuous, because the panel it sits in
  # is already offering to fix an installation GitHub says is gone. Instead it says the plainest
  # true thing: the account may be the whole reason this page is empty, so the emptiness is not
  # necessarily the settled answer it looks like.
  #
  # Anything else raises rather than silently falling through to the short-list wording, which
  # would put the false sentence back on an empty page by typo.
  def unreadable_accounts_closing(closing, missing:, unread:)
    account_phrase = unread.one? ? "that account" : "those accounts"

    case closing
    when :short_list
      "#{missing} connected through #{account_phrase} are missing from this list. " \
        "Anything shown here can still be registered."
    when :empty_state
      "#{missing} connected through #{account_phrase} could not be listed, so this page may be " \
        "empty for that reason rather than because there is nothing to register."
    else
      raise ArgumentError, "unknown closing #{closing.inspect}"
    end
  end

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
