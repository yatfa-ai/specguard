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

  helper_method :organizations, :organization, :already_registered?

  def new
    @full_names = []
  end

  def create
    # Normalised and de-duplicated up front, so the batch this action reasons about — what it
    # refuses as oversized, and what the re-rendered picker shows as ticked — is the batch
    # `BulkRegistration` would actually run. See `BulkRegistration.normalized_names`.
    @full_names = BulkRegistration.normalized_names(submitted_full_names)

    return render_refusal(nothing_selected_message) if @full_names.empty?
    return render_refusal(too_many_message) if @full_names.length > BulkRegistration::MAX_BATCH

    @result = BulkRegistration.call(user: current_user, full_names: @full_names)
    render :create
  end

  private

  # Every organization this viewer can register something from, derived from the listing rather than
  # from GitHub's org endpoints — see `GithubOrganizations` for why, and what that costs.
  def organizations
    @organizations ||= GithubOrganizations.from(github_listing)
  end

  # The organization being picked from, or `nil` when none has been chosen yet — which is also the
  # answer for a login this viewer cannot register from. A stale bookmark, a renamed organization
  # and a typed query string are ordinary ways to arrive here, and all three land on the chooser
  # rather than on an error page.
  def organization
    return @organization if defined?(@organization)

    @organization = GithubOrganizations.find(github_listing, params[:organization])
  end

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
        names = Array(organization&.administered).map { |repo| repo.full_name.downcase }

        if names.empty?
          Set.new
        else
          Repository.where("LOWER(repositories.github_full_name) IN (?)", names)
                    .pluck(:github_full_name).map(&:downcase).to_set
        end
      end
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
  # single refused registration does — see `GithubRepositoryListing#github_authorization_needed?`,
  # which asks this of whichever controller it is mixed into.
  def github_verdict = @result
end
