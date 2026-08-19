# frozen_string_literal: true

# "May this user register this repository?", answered by asking GitHub, as that user, about that
# user's GitHub App installations.
#
#   InstallationRepositories.sources(user, user_token: token)          # => Sources, the picker's set
#   InstallationRepositories.verify(user: current_user, user_token: token,
#                                   full_name: "acme/billing-service")
#   InstallationRepositories.verify_batch(user: current_user, user_token: token, full_names: [...])
#
# ## Two conditions, and why one of them is not enough
#
# A repository is registerable when BOTH hold:
#
#   1. It is in one of this user's installations of the SpecGuard App. Only somebody who
#      administers a repository can install an App on it, so this is GitHub's statement that the
#      repository was deliberately handed to SpecGuard by SOMEBODY.
#   2. This user administers it — `permissions.admin` on GitHub's own description of the repository
#      TO THIS USER.
#
# An earlier version of this class asserted that (1) implies (2), and it does not. The person who
# reads an installation is not necessarily the person who created it: `GET /user/installations`
# reports every installation the caller has `:read` on, which a plain organization member gets from
# their membership alone. Under that reading an org member with view access to one repository could
# register all fifty in their employer's installation, including ones they cannot see on github.com
# — a wider gap than the OAuth path this slice replaced, where at least `permissions.admin` was
# read. Both conditions are now enforced, and neither is inferred from the other.
#
# Condition (1) is enforced by the ENDPOINT rather than by a check:
# `GET /user/installations/:id/repositories` is installation-scoped, so a repository nobody gave
# SpecGuard is simply not in the answer. Condition (2) is enforced by `Repo#admin?`, which that same
# response carries. One round trip settles both.
#
# ## The credential
#
# Everything here is read with the USER's own short-lived token, held in their session and passed
# in — never with an installation token, which speaks for the App and cannot tell one member of an
# organization from another. A caller with no token gets `:not_authorized` and an offer to fetch
# one, which is a redirect the user will usually not even see.
#
# ## Six verdicts
#
# `GithubOwnership` carried eight, because eight things could go wrong with an admin check over an
# OAuth `repo` grant. What survives is what a *user* can still distinguish and act on:
#
#   :verified             both conditions hold. The only pass.
#   :not_installed        this user has no installation of the App at all. Fixed by installing it,
#                         which is why it is the one status `install?` is true of — the form offers
#                         a button instead of a field.
#   :not_authorized       this session holds no usable credential for GitHub, or GitHub rejected the
#                         one it held. Fixed by authorizing again, which `authorize?` offers as a
#                         button; for somebody who has already authorized the App, GitHub renders
#                         nothing and the round trip is invisible.
#   :not_in_installation  the App is installed and this repository is not in what this user can see
#                         of it. This is the squatting refusal, and it is also GitHub's 404: a
#                         credential cannot see anything outside what it may reach, so "not
#                         selected", "not yours" and "does not exist" are one answer here rather
#                         than three. Fixed on GitHub, by selecting it — not by editing the field.
#   :not_administered     the repository IS in the installation and this user is not an
#                         administrator of it. Told apart from the one above deliberately: it is the
#                         ordinary position of an organization's non-admin members, and "it is not
#                         in the installation" would be a false statement to make to them.
#   :rate_limited         GitHub refused because the hourly budget is spent. The one refusal that
#                         genuinely clears by waiting, and it says so.
#   :unavailable          GitHub could not be reached, would not answer, or answered incompletely.
#                         Explicitly NOT a pass: an outage must fail closed, or the squatting gap
#                         reopens on every 500. An operator-side misconfiguration lands here too —
#                         it is nothing the user can act on, and the reason goes to the log rather
#                         than to the browser.
class InstallationRepositories
  # A verdict about one repository name.
  Verdict = Data.define(:status, :full_name, :message) do
    def verified? = status == :verified

    # The one status the user fixes by installing the App rather than by picking something else —
    # so a form can offer the install button instead of an error no field can resolve.
    #
    # Named `install?` rather than the `reauthorize?` it replaces because the gesture changed: there
    # is no OAuth scope to re-request, there is an App to install.
    def install? = status == :not_installed

    # The other status a button fixes, and a different button: nothing is wrong with the
    # installation, only with what this session is holding.
    def authorize? = status == :not_authorized
  end

  MESSAGES = {
    not_installed: "could not be verified — install the SpecGuard GitHub App on it first.",
    not_authorized: "could not be verified — SpecGuard needs your permission to ask GitHub about " \
                    "it again. Reconnect and try once more.",
    not_in_installation: "is not one of the repositories the SpecGuard GitHub App is installed on. " \
                         "Add it on GitHub, then pick it here.",
    not_administered: "cannot be registered by you — GitHub does not list you as an administrator " \
                      "of it. Ask an administrator of that repository to register it.",
    rate_limited: "could not be verified — GitHub's rate limit has been reached. Try again in a " \
                  "few minutes.",
    unavailable: "could not be verified — SpecGuard could not read your full repository list from " \
                 "GitHub. Try again shortly."
  }.freeze

  # Everything the user's installations could be read as, plus what stopped that being the whole
  # story. Both halves matter, and for the same reason: an ABSENT name means "GitHub says no" only
  # when the reading was complete. When it was cut short — by our own page walk, or by an
  # installation that would not answer — absence is our ignorance and must not be reported as
  # GitHub's refusal.
  #
  # `repos` holds everything this user can SEE across their installations, administered or not,
  # because those are two different refusals and the second cannot be worded without the
  # distinction. `registrable` is the subset a user may actually act on, and is what the picker is
  # built from.
  Sources = Data.define(:repos, :truncated, :error, :installed) do
    def truncated? = truncated
    def installed? = installed
    def complete? = !truncated && error.nil?

    # The repositories this user both reached and administers — the only ones registration will
    # accept, and so the only ones worth offering.
    def registrable = repos.select(&:admin?)

    # The picker's view of this: a plain `GithubApi::Listing`, so every view and helper that renders
    # a repository list keeps taking the one type regardless of how many installations fed it.
    def listing = GithubApi::Listing.new(repos: registrable, truncated: truncated)

    # The same type again, over EVERYTHING this user reached rather than only what they may
    # register. Not an alternative source for a picker — offering one of these is offering a click
    # that can only end in `:not_administered` — but the only thing that can account for the
    # difference between the two. A page that shows five of an organization's thirty repositories
    # and says nothing about the other twenty-five is indistinguishable, to its reader, from a page
    # that is broken.
    def visible_listing = GithubApi::Listing.new(repos: repos, truncated: truncated)

    # How many repositories this user can see across their installations but is not an
    # administrator of — the count the pages above word as a sentence. Zero for the ordinary case
    # of somebody who administers everything they were given.
    def withheld_count = repos.length - registrable.length
  end

  class << self
    # Every repository this user can reach across every installation they hold, merged and
    # de-duplicated, each carrying whether this user administers it.
    #
    # Never raises and never returns nil: a caller renders a picker, an explanation, an install
    # button or a reconnect button from this, and all four are ordinary outcomes rather than
    # exceptions.
    #
    # ## One failing installation does not sink the others
    #
    # A user can hold several installations, and they fail independently — a `NotFound` is what an
    # *uninstall* looks like from here, and it is the ordinary way one goes stale while the rest
    # keep working. So a failure is recorded rather than raised, and it changes exactly one thing:
    # what an absent name means. Repositories that were read are still offered and still
    # registerable, because their presence is GitHub's own answer and is not made less true by a
    # different installation being unreachable.
    def sources(user, user_token: nil)
      installations = installations_for(user)
      return blank_sources(installed: false) if installations.empty?
      return blank_sources(installed: true, error: :not_authorized) if user_token.blank?

      collect(installations, user_token)
    end

    # One name. Returns a `Verdict` and never raises.
    def verify(user:, full_name:, user_token: nil, sources: nil)
      verify_batch(user: user, full_names: [full_name], user_token: user_token, sources: sources).first ||
        verdict(:not_in_installation, full_name.to_s.strip)
    end

    # The same question asked of many names at once, for bulk registration — one `Verdict` per name,
    # in the order given.
    #
    # ## Why this is not `full_names.map { verify(...) }`
    #
    # It is the other way round: `verify` is this with one name. The answer is a set test over a
    # listing SpecGuard has to fetch either way, so asking about twenty names costs the same as
    # asking about one — where a per-name round trip would be twenty sequential calls before the
    # first row is saved, and a hundred-repository organization would be a request that times out
    # rather than a batch that is slow.
    #
    # This is re-asked at submit time and never trusted from the browser. The form's checkboxes are
    # client-controlled, so a submitted name GitHub does not report as administered by this user is
    # refused here whatever the page offered — which is what lets the bulk path reuse the listing
    # without reopening the squatting gap.
    #
    # ## When absence is not an answer
    #
    # `MAX_PAGES` bounds each installation's page walk, and an installation can fail while others
    # succeed. Either way a name can be absent from the merged set for a reason that is ours rather
    # than GitHub's, so absence is only reported as a refusal when the reading was COMPLETE.
    # Otherwise every undecided name gets the failure itself and nothing is registered.
    #
    # There is deliberately no per-name fallback that asks GitHub about the missing name directly.
    # It could only be asked of `GET /repos/:owner/:repo`, which is not installation-scoped: a user
    # token answers it for any repository that user can see, including ones nobody gave SpecGuard.
    # The fallback would therefore have admitted exactly what the rest of this class exists to
    # refuse, and its absence also removes what was a per-name-per-installation fan-out on a path a
    # signed-in user could reach by submitting a large batch during an outage.
    #
    # ## `sources:` — one read per request, not one per question
    #
    # A caller that has ALREADY read this user's installations in this request passes them in, and
    # the answer is decided from that rather than from a second identical page walk. That is the
    # refusal path in `RepositoriesController`: it verifies, the verdict is not `verified?`, and it
    # then re-renders the picker — which is built from the same listing. Fetching it twice would be
    # up to `MAX_PAGES` extra GitHub round trips on a path a signed-in user can hammer, for an
    # answer already in memory.
    #
    # It is a CACHE of this request's own live read, never a trust boundary: the sources a caller
    # may pass are the ones this class produced, moments ago, from GitHub. Nothing from the browser
    # reaches here, and a caller with nothing to pass gets a fresh read.
    def verify_batch(user:, full_names:, user_token: nil, sources: nil)
      names = Array(full_names).map { |name| name.to_s.strip }.reject(&:empty?)
      return [] if names.empty?

      # `self.` is not noise: `sources` is also the name of this method's parameter, and while Ruby
      # resolves the parenthesised call to the method regardless, a reader should not have to know
      # that rule to see which one is being called.
      sources ||= self.sources(user, user_token: user_token)
      return names.map { |name| verdict(:not_installed, name) } unless sources.installed?

      # Keyed case-insensitively because GitHub logins and repository names are, and a name may
      # arrive here having been round-tripped through a form.
      seen = sources.repos.index_by { |repo| repo.full_name.downcase }

      names.map { |name| name_verdict(name, seen, sources) }
    end

    private

    def blank_sources(installed:, error: nil)
      Sources.new(repos: [], truncated: false, error: error, installed: installed)
    end

    def installations_for(user)
      return [] if user.nil?

      user.github_installations.recent_first.to_a
    end

    def collect(installations, user_token)
      repos = []
      truncated = false
      error = nil

      installations.each do |installation|
        listing = read(installation, user_token)
        next error ||= listing if listing.is_a?(Symbol)

        repos.concat(listing.repos)
        truncated ||= listing.truncated?
      end

      Sources.new(repos: dedupe(repos), truncated: truncated, error: error, installed: true)
    end

    # One installation's repositories as this user sees them, or the verdict status its failure
    # becomes. A Symbol rather than a raise because the caller is merging several of these and one
    # failure must not decide the fate of the rest.
    #
    # A 404 is NOT a failure here, and that is the one case worth stating: it is what an uninstalled
    # installation — or one this user has lost access to — answers, and neither contains any
    # repository this user may register. That is a complete answer rather than a gap in our
    # knowledge, so it returns an empty listing, which lets an absent name be reported as GitHub's
    # refusal rather than as our own ignorance.
    def read(installation, user_token)
      client = GithubApi.for_user(user_token, installation)
      return :not_authorized if client.nil?

      client.repositories
    rescue GithubApi::NotFound
      GithubApi::Listing.new(repos: [], truncated: false)
    rescue GithubApi::Unauthorized
      # The token expired or was revoked mid-session. Distinct from an outage because the fix is a
      # thing the user can perform, and the page offers it as a button.
      :not_authorized
    rescue GithubApi::Error => e
      status_for(e, "installation #{installation.installation_id}")
    end

    # Two installations can legitimately contain the same repository — an organization installation
    # and a personal one both reaching a fork, say — and the picker must offer it once. Kept
    # ADMIN-FIRST so that where the two readings disagree the permissive one wins, which is correct:
    # they are two readings of the same user's access and the higher one is the one GitHub granted.
    def dedupe(repos)
      repos.sort_by { |repo| repo.admin? ? 0 : 1 }
           .uniq { |repo| repo.full_name.downcase }
           .sort_by { |repo| repo.full_name.downcase }
    end

    def name_verdict(name, seen, sources)
      repo = seen[name.downcase]

      return verdict(:verified, name) if repo&.admin?
      return verdict(:not_administered, name) if repo

      # Absent from a COMPLETE reading is GitHub's own answer. Absent from an incomplete one is our
      # page walk's or a broken installation's, and those must not read the same.
      return verdict(:not_in_installation, name) if sources.complete?

      verdict(sources.error || :unavailable, name)
    end

    # Which verdict a GitHub failure becomes, and what gets logged on the way.
    #
    # `NotFound` and `Unauthorized` never reach here: `read` answers both itself, because at it they
    # mean something ordinary and specific — an installation this user no longer reaches, and a
    # session credential that has run out. What does reach here carries something the log wants:
    # GitHub's own sentence, or an operator-side misconfiguration, and neither is the browser's
    # business.
    def status_for(error, subject)
      case error
      when GithubApi::Forbidden
        return :rate_limited if error.reason == :rate_limited

        Rails.logger.warn("[InstallationRepositories] #{subject}: #{error.class}(#{error.reason}): #{error.message}")
        :unavailable
      else
        Rails.logger.warn("[InstallationRepositories] #{subject}: #{error.class}: #{error.message}")
        :unavailable
      end
    end

    def verdict(status, full_name)
      Verdict.new(status: status, full_name: full_name, message: MESSAGES[status])
    end
  end
end
