# frozen_string_literal: true

# Registering a whole GitHub organization's repositories in one action — SPGD-355.
#
# Its own controller rather than another action on `RepositoriesController`, because it is a
# different resource: `RepositoriesController` acts on ONE repository per request (`@repository`,
# `repository_params`, a redirect to its show page), and every one of those shapes is wrong for a
# batch that produces N rows and a summary. What the two genuinely share is the listing the picker
# is built from, and that is shared as `GithubRepositoryListing` rather than by co-locating them.
#
# ## Two GETs, one path
#
#   GET  /repositories/bulk                     choose an organization
#   GET  /repositories/bulk?organization=acme   choose which of its repositories
#   POST /repositories/bulk                     register them, and render what happened
#
# The organization lives in the query string rather than in a wizard's session state, so the second
# step is linkable, bookmarkable and re-runnable, and a reader who back-buttons out of it lands on
# the step before rather than on a half-filled form. There is nothing to remember between the two:
# both are rendered from the same listing.
#
# ## The result is rendered, not flashed
#
# `#create` renders its summary instead of redirecting. A batch's answer is one row per repository
# with a reason attached — up to `BulkRegistration::MAX_BATCH` of them — which is not something to
# put in a cookie, and reducing it to a one-line flash is exactly the dishonest "registered 20!"
# this ticket exists to avoid. The cost is that a refresh re-submits, and that is survivable
# precisely because the operation is idempotent by construction: everything registered the first
# time comes back as `already_registered` the second.
#
# That choice has a hard prerequisite: the picker form opts out of Turbo. Turbo Drive refuses a
# non-redirect response to a form submission, so rendering here is only reachable because
# `_picker.html.erb` says `turbo: false` — see the comment there. The two decisions are one
# decision, and changing either alone silently breaks the summary rather than failing loudly.
class BulkRegistrationsController < ApplicationController
  # The picker is built from the same listing the single-repository form uses, and says the same
  # things when it cannot be loaded.
  include GithubRepositoryListing

  before_action :require_authentication

  helper_method :organizations, :organization, :already_registered?, :submitted_organization

  def new
    # Normally empty — step two is a fresh list of unticked boxes. It is populated when the reader
    # arrived by pressing one of the summary's controls, which carry the batch back here so those
    # rows come back ticked: "Try these again" carries the names themselves as `github_full_names[]`,
    # and the three FIX buttons — the ones that take a trip to GitHub first — carry a HANDLE to a
    # selection held server-side, because a trip through GitHub's `state` has a byte budget a batch
    # does not fit in. See `GithubHelper#bulk_picker_return_to` and `PendingBulkSelection`.
    #
    # Both are normalised through the same class method `#create` uses, so a carried batch and a
    # submitted one are the same batch, and the picker's tick boxes never learn which of the two
    # they were ticked by.
    #
    # Nothing is trusted about these names, from either source: they only decide which of the rows
    # this page was going to render anyway start out ticked, and every one of them is re-verified
    # against GitHub when the form is submitted. A name that is not in the listing simply matches no
    # row. That is what makes a handle safe to hand out — the worst a redeemed selection can do is
    # pre-tick boxes — and it is why redemption needs no ownership check beyond the scope it is read
    # through. A handle belonging to somebody else, or one already expired, redeems nothing and the
    # reader lands on the right account with an unticked list.
    @full_names = BulkRegistration.normalized_names(submitted_full_names + redeemed_full_names)
  end

  def create
    # Normalised and de-duplicated up front, so the batch this action reasons about — what it
    # refuses as oversized, and what the re-rendered picker shows as ticked — is the batch
    # `BulkRegistration` would actually run. See `BulkRegistration.normalized_names`.
    @full_names = BulkRegistration.normalized_names(submitted_full_names)

    return render_refusal(nothing_selected_message) if @full_names.empty?
    return render_refusal(too_many_message) if @full_names.length > BulkRegistration::MAX_BATCH

    @result = BulkRegistration.call(user: current_user, user_token: github_user_token,
                                    full_names: @full_names)
    render :create
  end

  private

  # Every organization this viewer can register something from, derived from the listing rather than
  # from GitHub's org endpoints — see `GithubOrganizations` for why, and what that costs.
  #
  # Built from `github_visible_listing` rather than `github_listing`: the narrowed listing has
  # already dropped what this viewer cannot administer, and dropping it before grouping is what
  # leaves the page unable to say how much of an organization it is not showing. `GithubOrganizations`
  # applies the same bar itself, per organization, and keeps the difference.
  def organizations
    @organizations ||= GithubOrganizations.from(github_visible_listing)
  end

  # The organization being picked from, or `nil` when none has been chosen yet — which is also the
  # answer for a login this viewer cannot register from. A stale bookmark, a renamed organization
  # and a typed query string are ordinary ways to arrive here, and all three land on the chooser
  # rather than on an error page.
  def organization
    return @organization if defined?(@organization)

    @organization = GithubOrganizations.find(github_visible_listing, params[:organization])
  end

  # The account this submission came from, as the browser sent it, so the summary can offer a way
  # back to the picker for it. The picker posts it as `hidden_field_tag :organization` precisely so
  # the 422 refusal path can re-render step two rather than dropping the reader at the chooser; the
  # summary path is answering the same POST and the value is sitting in the same place.
  #
  # Deliberately the RAW param and not `#organization`, which resolves the login against
  # `github_visible_listing`. Resolving it here would cost a second full walk of the user's
  # installations — the create path has already read the listing once inside
  # `InstallationRepositories.verify_batch`, and a spec pins that a registration asks GitHub exactly
  # once. Nothing on the summary needs the resolved Org: this value only becomes a query parameter
  # on a link, and the GET that follows resolves it exactly as a typed or bookmarked one is. A login
  # this viewer cannot register from lands on the chooser there, which is already the answer for a
  # stale bookmark.
  #
  # Blank when the POST carried no organization — a submission that did not come from the picker —
  # and the summary then offers no retry rather than a link back to a nameless account.
  def submitted_organization = params[:organization].presence

  # Which of the organization's repositories are already registered here, so the picker can say so
  # rather than offer a tick box whose only possible outcome is "skipped".
  #
  # ONE query for the whole page — never a lookup per row. Answered as a Set of downcased names
  # because that is how the rows ask, and case-insensitively because that is how the uniqueness rule
  # this anticipates actually works: a repository registered as `Acme/API` is what refuses
  # `acme/api`.
  #
  # Deliberately GLOBAL rather than scoped to this user: `github_full_name` is unique across
  # SpecGuard, so a repository somebody else registered is one this user cannot register either, and
  # a picker that offered it would be offering a click that can only fail. This is the same fact the
  # single-repository form already surfaces through its uniqueness error.
  #
  # It is a display concession and not a gate. `BulkRegistration` re-checks at save time, which is
  # what makes a stale page or a concurrent batch a reported skip rather than an exception.
  def already_registered?(full_name)
    registered_names.include?(full_name.to_s.downcase)
  end

  def registered_names
    @registered_names ||=
      begin
        names = Array(organization&.repos).map { |repo| repo.full_name.downcase }

        if names.empty?
          Set.new
        else
          Repository.where("LOWER(repositories.github_full_name) IN (?)", names)
                    .pluck(:github_full_name).map(&:downcase).to_set
        end
      end
  end

  # The names a HANDLE redeems for, or none.
  #
  # `[]` for every way a handle can fail to name a live selection of this person's — absent,
  # unknown, expired, or belonging to somebody else — and the four are deliberately one answer,
  # because they are one state to the reader: the list comes back unticked, at the right account,
  # which is exactly what an over-bound batch delivered before handles existed. Degrading rather
  # than erroring is the point; a stale bookmark is an ordinary way to arrive here, and the two GETs
  # at the top of this file already answer a stale `organization` by landing on the chooser rather
  # than on an error page.
  #
  # Scoping is `PendingBulkSelection.redeem`'s, and it is a WHERE rather than a check applied to a
  # row already found — see the model. Nothing else about the handle is trusted: what it yields
  # decides which rows start ticked and nothing more, exactly as `submitted_full_names` does.
  def redeemed_full_names
    PendingBulkSelection.redeem(user: current_user, token: params[GithubHelper::SELECTION_PARAM])
  end

  # The submitted names, as strings, and nothing else.
  #
  # `params` here can be any shape a client cares to send — a Hash where an Array is expected, an
  # Array of Hashes, nested arrays — so this coerces rather than trusts. Non-scalar entries are
  # dropped rather than `to_s`-ed, because `{"a" => "b"}.to_s` is a String that would then be
  # reported as a repository name in the summary.
  #
  # Shape only. Normalising and de-duplicating the values is `BulkRegistration.normalized_names`'s
  # job, so the controller and the service cannot disagree about what the batch is.
  #
  # Nothing about the CONTENT is trusted either: these names are an assertion by the browser, and
  # `BulkRegistration` re-asks GitHub about every one of them.
  def submitted_full_names
    raw = params[:github_full_names]
    raw = raw.values if raw.respond_to?(:values) && !raw.is_a?(Array)

    Array(raw).grep(String)
  end

  def render_refusal(message)
    flash.now[:alert] = message
    render :new, status: :unprocessable_content
  end

  def nothing_selected_message
    "Select at least one repository to register."
  end

  def too_many_message
    "#{@full_names.length} repositories is more than one batch can register. Select at most " \
      "#{BulkRegistration::MAX_BATCH} at a time."
  end

  # A batch that skipped repositories for a missing or dead grant must offer the fix, exactly as a
  # single refused registration does — see `GithubRepositoryListing#github_installation_needed?`,
  # which asks this of whichever controller it is mixed into.
  def github_verdict = @result
end
