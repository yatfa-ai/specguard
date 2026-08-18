# frozen_string_literal: true

# "May this user register this repository?", answered by GitHub App installation membership.
#
#   InstallationRepositories.sources(user)                            # => Sources, the picker's set
#   InstallationRepositories.verify(user: current_user, full_name: "acme/billing-service")
#   InstallationRepositories.verify_batch(user: current_user, full_names: [...])
#
# ## Why membership, and why that is the whole check
#
# Only somebody who administers a repository can install a GitHub App on it, and only somebody who
# administers it can add it to an existing installation. So a repository's presence in this user's
# installation IS GitHub's statement that this user administers it. There is no permission field to
# read and no second question to ask.
#
# That replaces `GithubOwnership`, which asked GitHub for `permissions.admin` off
# `GET /repos/:owner/:repo` and needed the OAuth `repo` scope — read and write on every repository
# the user could reach — in order to read one boolean. The check is now strictly narrower in what it
# requires and strictly stronger in what it proves: the old one admitted any repository the user
# happened to administer, where this admits only the ones somebody deliberately handed over.
#
# ## Five verdicts, not eight
#
# `GithubOwnership` carried eight, because eight things could go wrong with an admin check over a
# user token: a missing grant, a too-narrow grant, a revoked token, an SSO-blocked organization, a
# visible-but-not-administered repository, an invisible one, a rate limit, an outage. Most of those
# are properties of a user token and do not exist here. What survives is what a *user* can still
# distinguish and act on:
#
#   :verified             the repository is in this user's installation. The only pass.
#   :not_installed        this user has not installed the App. Fixed by installing it, which is why
#                         it is the one status `install?` is true of — the form offers a button
#                         instead of a field.
#   :not_in_installation  the App is installed and this repository is not in it. This is the
#                         squatting refusal, and it is also GitHub's 404: an installation credential
#                         cannot see anything outside its own installation, so "not selected",
#                         "not yours" and "does not exist" are one answer here rather than three.
#                         Fixed on GitHub, by selecting it — not by editing the field.
#   :rate_limited         GitHub refused because the installation's hourly budget is spent. The one
#                         refusal that genuinely clears by waiting, and it says so.
#   :unavailable          GitHub could not be reached, would not answer, or rejected the App's own
#                         credentials. Explicitly NOT a pass: an outage must fail closed, or the
#                         squatting gap reopens on every 500. An operator-side misconfiguration
#                         lands here too — it is nothing the user can act on, and the reason goes to
#                         the log rather than to the browser.
class InstallationRepositories
  # A verdict about one repository name.
  Verdict = Data.define(:status, :full_name, :message) do
    def verified? = status == :verified

    # The one status the user fixes by installing the App rather than by picking something else —
    # so a form can offer the install button instead of an error no field can resolve.
    #
    # Named `install?` rather than the `reauthorize?` it replaces because the gesture changed: there
    # is no authorization to repeat, there is an App to install.
    def install? = status == :not_installed
  end

  MESSAGES = {
    not_installed: "could not be verified — install the SpecGuard GitHub App on it first.",
    not_in_installation: "is not one of the repositories the SpecGuard GitHub App is installed on. " \
                         "Add it on GitHub, then pick it here.",
    rate_limited: "could not be verified — GitHub's rate limit for this installation has been " \
                  "reached. Try again in a few minutes.",
    unavailable: "could not be verified — GitHub did not answer. Try again shortly."
  }.freeze

  # Everything the user's installations could be read as, plus what stopped that being the whole
  # story. Both halves matter, and for the same reason: an ABSENT name means "GitHub says no" only
  # when the reading was complete. When it was cut short — by our own page walk, or by an
  # installation that would not answer — absence is our ignorance and must not be reported as
  # GitHub's refusal.
  Sources = Data.define(:repos, :truncated, :error, :installed) do
    def truncated? = truncated
    def installed? = installed
    def complete? = !truncated && error.nil?

    # The picker's view of this: a plain `GithubApi::Listing`, so every view and helper that renders
    # a repository list keeps taking the one type regardless of how many installations fed it.
    def listing = GithubApi::Listing.new(repos: repos, truncated: truncated)
  end

  class << self
    # Every repository across every installation this user has, merged and de-duplicated.
    #
    # Never raises and never returns nil: a caller renders a picker, an explanation, or an install
    # button from this, and all three are ordinary outcomes rather than exceptions.
    #
    # ## One failing installation does not sink the others
    #
    # A user can hold several installations, and they fail independently — a `NotFound` is what an
    # *uninstall* looks like from here, and it is the ordinary way one goes stale while the rest
    # keep working. So a failure is recorded rather than raised, and it changes exactly one thing:
    # what an absent name means. Repositories that were read are still offered and still
    # registerable, because their presence is GitHub's own answer and is not made less true by a
    # different installation being unreachable.
    def sources(user)
      installations = installations_for(user)
      return Sources.new(repos: [], truncated: false, error: nil, installed: false) if installations.empty?

      repos = []
      truncated = false
      error = nil

      installations.each do |installation|
        listing = read(installation)
        next error ||= listing if listing.is_a?(Symbol)

        repos.concat(listing.repos)
        truncated ||= listing.truncated?
      end

      Sources.new(repos: dedupe(repos), truncated: truncated, error: error, installed: true)
    end

    # One name. Returns a `Verdict` and never raises.
    def verify(user:, full_name:, sources: nil)
      verify_batch(user: user, full_names: [full_name], sources: sources).first ||
        verdict(:not_in_installation, full_name.to_s.strip)
    end

    # The same question asked of many names at once, for bulk registration — one `Verdict` per name,
    # in the order given.
    #
    # ## Why this is not `full_names.map { verify(...) }`
    #
    # It is the other way round: `verify` is this with one name. Membership is a set test over a
    # listing SpecGuard has to fetch either way, so asking about twenty names costs the same as
    # asking about one — where a per-name round trip would be twenty sequential calls before the
    # first row is saved, and a hundred-repository organization would be a request that times out
    # rather than a batch that is slow.
    #
    # This is re-asked at submit time and never trusted from the browser. The form's checkboxes are
    # client-controlled, so a submitted name GitHub does not report in the installation is refused
    # here whatever the page offered — which is what lets the bulk path reuse the listing without
    # reopening the squatting gap.
    #
    # ## When absence is not an answer
    #
    # `MAX_PAGES` bounds each installation's page walk, and an installation can fail while others
    # succeed. Either way a name can be absent from the merged set for a reason that is ours rather
    # than GitHub's, so absence is only reported as `:not_in_installation` when the reading was
    # complete. Otherwise the name is asked about individually — which is bounded per call by
    # `BulkRegistration::MAX_BATCH`, exactly so this fallback cannot become an unbounded fan-out.
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
    def verify_batch(user:, full_names:, sources: nil)
      names = Array(full_names).map { |name| name.to_s.strip }.reject(&:empty?)
      return [] if names.empty?

      # `self.` is not noise: `sources` is also the name of this method's parameter, and while Ruby
      # resolves the parenthesised call to the method regardless, a reader should not have to know
      # that rule to see which one is being called.
      sources ||= self.sources(user)
      return names.map { |name| verdict(:not_installed, name) } unless sources.installed?

      # Keyed case-insensitively because GitHub logins and repository names are, and a name may
      # arrive here having been round-tripped through a form.
      present = sources.repos.map { |repo| repo.full_name.downcase }.to_set

      names.map { |name| name_verdict(user, name, present, sources) }
    end

    private

    def installations_for(user)
      return [] if user.nil?

      user.github_installations.recent_first.to_a
    end

    # One installation's repositories, or the verdict status its failure becomes. A Symbol rather
    # than a raise because the caller is merging several of these and one failure must not decide
    # the fate of the rest.
    #
    # A 404 is NOT a failure here, and that is the one case worth stating: it is what an
    # uninstalled installation answers, and an installation that no longer exists contains no
    # repositories. That is a complete answer rather than a gap in our knowledge, so it returns an
    # empty listing — which lets an absent name be reported as GitHub's refusal instead of sending
    # every name in the batch on a per-name round trip to the same 404.
    def read(installation)
      client = GithubApi.for_installation(installation)
      return :unavailable if client.nil?

      client.repositories
    rescue GithubApi::NotFound
      GithubApi::Listing.new(repos: [], truncated: false)
    rescue GithubApi::Error => e
      status_for(e, "installation #{installation.installation_id}")
    end

    # Two installations can legitimately contain the same repository — an organization installation
    # and a personal one both reaching a fork, say — and the picker must offer it once.
    def dedupe(repos)
      repos.uniq { |repo| repo.full_name.downcase }.sort_by { |repo| repo.full_name.downcase }
    end

    def name_verdict(user, name, present, sources)
      return verdict(:verified, name) if present.include?(name.downcase)

      # Absent from a COMPLETE reading is GitHub's own answer. Absent from an incomplete one is our
      # page walk's or a broken installation's, and those must not read the same.
      return verdict(:not_in_installation, name) if sources.complete?

      ask_individually(user, name, sources)
    end

    # Absent from an incomplete listing, so GitHub is asked about this one name directly — in each
    # installation, because the repository need only be in one of them.
    #
    # Falls back to the recorded failure rather than to `:not_in_installation` when nothing answers:
    # an installation that would not list its repositories will not answer about one of them either,
    # and reporting that as "GitHub says this is not yours" would be inventing a refusal.
    def ask_individually(user, name, sources)
      failure = nil

      installations_for(user).each do |installation|
        client = GithubApi.for_installation(installation)
        next if client.nil?

        begin
          client.repository(name)
          return verdict(:verified, name)
        rescue GithubApi::NotFound
          next
        rescue GithubApi::Error => e
          failure ||= status_for(e, name)
        end
      end

      verdict(failure || sources.error || :not_in_installation, name)
    end

    # Which verdict a GitHub failure becomes, and what gets logged on the way.
    #
    # `NotFound` never reaches here: both callers answer it themselves, because at each of them it
    # means something ordinary and specific — an uninstalled installation in `read`, a repository
    # this installation does not cover in `ask_individually` — rather than a failure. What does
    # reach here carries something the log wants: GitHub's own sentence, or an operator-side
    # misconfiguration naming which credential is wrong, and neither is the browser's business.
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
