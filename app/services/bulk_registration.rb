# frozen_string_literal: true

# Register many GitHub repositories in one action — SPGD-355's whole subject.
#
#   result = BulkRegistration.call(user: current_user, full_names: %w[acme/api acme/web])
#   result.registered  # => [Outcome, …]
#   result.skipped     # => [Outcome, …], each carrying WHY
#
# ## The contract: every repository answered for, none of them silently
#
# A batch is not a transaction and deliberately not an all-or-nothing. A user registering an
# organization's twenty repositories will routinely have three of them already registered and one
# they do not administer, and failing the whole action over that is refusing to do nineteen things
# because of one. So each repository is decided and saved independently, and the RESULT is the
# honest part: one `Outcome` per submitted name, every one of them either registered or skipped with
# the reason it was skipped. There is no bucket for "something went wrong" and nothing is dropped on
# the floor — a caller can always render a total that adds up.
#
# ## Ownership is verified here too, not inherited from the page
#
# The form's tick boxes are client-controlled, so the submitted names are an ASSERTION, not a fact.
# Every name goes through `InstallationRepositories` before it is saved, exactly as a single registration
# does through `RepositoriesController#save_with_verified_ownership`, and in the same order:
#
#   1. The record's own rules (`valid?`) — shape and uniqueness. A slug that is not `org/repo` never
#      becomes a GitHub question, and `normalize_full_name` has run, so GitHub is asked about the
#      value that would actually be stored.
#   2. Ownership, for everything that survived step 1 — one batched call, see
#      `InstallationRepositories.verify_batch`.
#   3. Save.
#
# It fails closed at every step, per name and for the whole batch: a GitHub outage registers
# nothing, because verifying-by-default during an outage reopens the squatting gap intermittently.
#
# ## Already registered is an outcome, not an error
#
# "Register all of them" is the point of the feature, and on the second run most of them are already
# registered. A uniqueness failure is therefore reported as `:already_registered` and skipped — both
# when it is known up front and when it is discovered at save time, which is what a second batch
# running concurrently looks like from here.
class BulkRegistration
  # The most repositories one action may carry.
  #
  # A bound rather than a queue: SPGD-355 scopes itself to "an honest 20–N-repo batch" and puts
  # scheduling out. What the number has to be big enough for is a real organization registered in
  # one go; what it has to be small enough for is a single request, since this does N saves inline.
  #
  # It bounds the SAVES, not the GitHub reads: `InstallationRepositories.verify_batch` answers every
  # name from one listing per installation however many names arrive, and has no per-name fallback
  # that could fan out behind it. Enforced by the caller (`BulkRegistrationsController#create`),
  # which refuses an oversized submission rather than silently registering a prefix of it.
  MAX_BATCH = 100

  # `is already registered in SpecGuard.` and friends are written as PREDICATES, so a caller renders
  # `"#{full_name} #{message}"` and gets a sentence. That is the same shape `InstallationRepositories::MESSAGES`
  # is written in — the two are read side by side in one list and must not be phrased differently.
  ALREADY_REGISTERED_MESSAGE = "is already registered in SpecGuard."
  UNKNOWN_FAILURE_MESSAGE = "could not be registered."

  # One submitted repository and what became of it. `status` is `:registered` or the reason it was
  # not, which is either `:already_registered`, `:invalid`, or one of `InstallationRepositories`' non-verified
  # statuses passed through unchanged — the vocabulary is deliberately shared, so the sentence a bulk
  # skip shows is the sentence a single registration would have shown for the same refusal.
  #
  # `repository` is the row, and it is present for two different reasons that both matter to a
  # reader: on `:registered` it is what was just created, and on `:already_registered` it is the
  # existing one — but ONLY when this user may open it. A batch that named a repository somebody else
  # registered says "already registered" and links nowhere, which is all it can honestly say.
  Outcome = Data.define(:full_name, :status, :message, :repository) do
    def initialize(message: nil, repository: nil, **) = super

    def registered? = status == :registered
    def skipped? = !registered?

    # The whole sentence, subject included. Composed here rather than in the view so the summary
    # cannot end up phrasing the same refusal differently from the registration form.
    def sentence = [full_name, message].compact_blank.join(" ")
  end

  # The order skip reasons are shown in: what the user expected and can ignore first, what they may
  # want to act on next, then the transient and the systemic. A reason with nothing in it is not
  # rendered, so this is an ordering, not a list of headings.
  SKIP_ORDER = %i[already_registered not_administered not_in_installation invalid not_installed
                  not_authorized rate_limited unavailable].freeze

  # The skips a re-submission can actually resolve, and the only ones worth carrying back to the
  # picker — exactly the three whose `InstallationRepositories::MESSAGES` sentence instructs the
  # reader to try again: "Reconnect and try once more", "Try again in a few minutes", "Try again
  # shortly". A batch that skipped for any of these was refused by something that clears on its own
  # or with one click, and the same submission run a second time is expected to land.
  #
  # It lives here, next to `SKIP_ORDER` and `SKIP_LABELS`, rather than as a status list in the
  # summary view, so the page and the service cannot end up disagreeing about which refusals are
  # temporary — the sentence that promises a retry and the button that offers one are then answers
  # to the same question.
  #
  # Everything absent from this list is terminal FOR A RE-SUBMISSION, which is not the same as
  # unfixable: `already_registered` and `invalid` need nothing and can never succeed, while
  # `not_installed` / `not_in_installation` / `not_administered` need a change on GitHub's side
  # first. Re-running the identical batch fixes none of them.
  #
  # Two of those three are offered a trip that DOES change GitHub's answer, and the third is
  # deliberately not:
  #
  #   * `not_installed` — the install button (`install?`), which installs the App.
  #   * `not_in_installation` — the "Choose repositories on GitHub" button
  #     (`choose_repositories?`), which reopens GitHub's own repository picker for an installation
  #     that already exists.
  #   * `not_administered` — NOTHING, and correctly so. The fix is somebody ELSE granting the
  #     reader admin on that repository; sending them to GitHub's picker would be sending them to
  #     fix something that is not broken, and what is actually in their way is not theirs to
  #     change. `repositories/_form` states this in full at the same decision.
  #
  # Those buttons are a different question from this list. They offer a different TRIP, not a
  # re-run: re-submitting the identical batch still resolves none of these three, which is why
  # none of them is a member here and why the retry control must not render for them.
  RETRYABLE_SKIPS = %i[not_authorized rate_limited unavailable].freeze

  # What each skip reason is called in the summary. The heading names the CATEGORY; the per-row
  # sentence carries the explanation, so these stay short enough to scan.
  SKIP_LABELS = {
    already_registered: "Already registered",
    not_administered: "You are not an administrator",
    not_in_installation: "Not connected to the SpecGuard GitHub App",
    invalid: "Not a valid repository name",
    not_installed: "SpecGuard GitHub App not installed",
    not_authorized: "SpecGuard needs to ask GitHub about you again",
    rate_limited: "GitHub rate limit reached",
    unavailable: "GitHub could not be reached"
  }.freeze

  Result = Data.define(:outcomes) do
    def registered = outcomes.select(&:registered?)
    def skipped = outcomes.select(&:skipped?)

    def registered_count = registered.length
    def skipped_count = skipped.length
    def total_count = outcomes.length

    def any_registered? = registered.any?

    # Skips grouped by reason, in `SKIP_ORDER`, as `[status, label, outcomes]`. Empty groups are
    # dropped — a heading over nothing is a reason to think something is missing.
    def skipped_groups
      grouped = skipped.group_by(&:status)

      SKIP_ORDER.filter_map do |status|
        rows = grouped[status]
        [status, SKIP_LABELS.fetch(status, status.to_s.humanize), rows] if rows.present?
      end
    end

    # The one skip a user resolves by installing the App rather than by picking something else, so
    # the summary can offer the install button. Mirrors `InstallationRepositories::Verdict#install?`,
    # and `GithubRepositoryListing#github_installation_needed?` asks either for the capability.
    def install? = skipped.any? { |outcome| outcome.status == :not_installed }

    # The other skip a button resolves, and a different button: this session had no credential to
    # ask GitHub with. Mirrors `InstallationRepositories::Verdict#authorize?`, which
    # `GithubRepositoryListing#github_authorization_needed?` asks either of for the capability.
    def authorize? = skipped.any? { |outcome| outcome.status == :not_authorized }

    # The THIRD skip a button resolves, and a third button again: the App is installed and this
    # session's credential is fine — GitHub simply was not asked to include this repository in the
    # installation. Its own sentence is already an instruction to the reader ("Add it on GitHub,
    # then pick it here."), and until now the summary gave them no way to take it.
    #
    # Deliberately NOT a mirror of anything on `InstallationRepositories::Verdict`, which is why it
    # is read straight off `@result` in the summary rather than through
    # `GithubRepositoryListing`'s `github_verdict` seam. That seam's contract is that EITHER class
    # may be returned, so a concern method asking this of it would raise on one of its two
    # documented callers.
    #
    # `not_administered` is absent on purpose and is the sibling case this must not swallow: it is
    # equally terminal for a re-submission, but its fix belongs to somebody else. Offering GitHub's
    # picker there would send the reader to change a selection that is already correct while what
    # is actually in their way — admin rights they do not hold — stays untouched.
    def choose_repositories? = skipped.any? { |outcome| outcome.status == :not_in_installation }

    # The names for THAT button, and the narrowest of the three carried lists: exactly the
    # `not_in_installation` names and nothing else.
    #
    # Narrow because the trip is narrow. Installing the App changes the answer for the transient
    # skips too (`install_retryable_names` carries them for that reason), but reopening GitHub's
    # repository picker for an installation that already exists changes the answer for one thing
    # only — whether these repositories are in it. A rate-limited name riding along would come back
    # ticked having been fixed by nothing, and `already_registered` / `invalid` / `not_administered`
    # are no more resolvable after this trip than before it.
    #
    # Names rather than outcomes for the reason `retryable_names` states: the caller puts them back
    # in the picker's `@full_names` seam, which is a list of names.
    def choose_repositories_names
      skipped.filter_map { |outcome| outcome.full_name if outcome.status == :not_in_installation }
    end

    # The names a re-submission could plausibly land — the skips whose own sentence told the reader
    # to try again (`RETRYABLE_SKIPS`), and nothing else. This is the third question of the same
    # family as `install?` and `authorize?`: which control does the summary owe this batch. The
    # other two ask whether to offer a fix ELSEWHERE (GitHub's installation, an OAuth round trip);
    # this one asks whether to offer the batch ITSELF back.
    #
    # Names rather than outcomes, because the one thing the caller does with them is put them back
    # in the picker's `@full_names` seam, which is a list of names. Registered repositories are not
    # here by construction — this reads `skipped` — and neither is any terminal skip, so a batch
    # carried back is the failed remainder rather than a re-run of the whole submission.
    def retryable_names = skipped.filter_map { |outcome| outcome.full_name if RETRYABLE_SKIPS.include?(outcome.status) }

    # The same list for the OTHER button — the one that goes and installs the App — and it is
    # deliberately WIDER than `retryable_names` by exactly the `not_installed` names.
    #
    # The difference is behavioural rather than tidy. A plain re-submission resolves nothing about
    # `not_installed`, so `retryable_names` must not carry those: re-offering them would re-offer
    # names the next submission refuses identically. But installing the App is PRECISELY the trip
    # that turns a `not_installed` skip into a registerable repository, so a list that omitted them
    # would carry back everything except the thing the button just fixed.
    #
    # The retryable names ride along too, because the install trip is a round trip like any other:
    # a mixed batch's rate-limited names are still worth putting back in the picker when the reader
    # returns, and they are the same names `retryable_names` would have carried.
    #
    # Terminal skips are still absent — `already_registered`, `invalid`, `not_administered` and
    # `not_in_installation` are not resolved by installing the App either — and registered rows are
    # absent by construction, because this reads `skipped`.
    def install_retryable_names
      skipped.filter_map do |outcome|
        outcome.full_name if RETRYABLE_SKIPS.include?(outcome.status) || outcome.status == :not_installed
      end
    end

    # Whether there is anything worth offering a retry for. Asked separately from `retryable_names`
    # so the summary reads as a question rather than as an emptiness check on a list.
    def retry? = retryable_names.any?
  end

  def self.call(...) = new(...).call

  # The batch a submission is actually asking for: normalised, blanks dropped, and de-duplicated
  # case-insensitively.
  #
  # A CLASS method because the caller has to be able to ask the same question before it decides
  # anything. `BulkRegistrationsController#create` measures `MAX_BATCH` against this rather than
  # against the raw params, so a submission of 101 names that collapses to forty is not refused with
  # "101 repositories is more than one batch can register" — a true sentence about a batch the user
  # did not submit.
  #
  # Normalisation runs BEFORE de-duplication, and the order is the point. `acme/api` and
  # `https://github.com/acme/api` are one repository; de-duplicating the raw strings keeps both,
  # registers the first, and reports the second as already-registered against a row this very batch
  # had just created. De-duplication is case-insensitive for the same reason the uniqueness rule is:
  # a repository stored as `Acme/API` is what refuses `acme/api`.
  def self.normalized_names(full_names)
    Array(full_names).filter_map { |name| Repository.normalize_full_name(name) }
                     .uniq(&:downcase)
  end

  # `user_token` is the viewer's own GitHub credential, held in their session
  # (`GithubUserSession`). It is required to answer the ownership question at all: what a user may
  # register is what they administer, and only a credential that speaks for THEM can report that.
  # A batch submitted without one is refused name by name with `:not_authorized` rather than
  # registered, which is the fail-closed reading.
  def initialize(user:, full_names:, user_token: nil)
    @user = user
    @user_token = user_token
    @names = self.class.normalized_names(full_names)
  end

  def call
    return Result.new(outcomes: []) if names.empty?

    candidates = names.map { |name| prepare(name) }
    verify(candidates)
    candidates.each { |candidate| save(candidate) }
    link_existing(candidates)

    Result.new(outcomes: candidates.map(&:to_outcome))
  end

  private

  attr_reader :user, :names, :user_token

  # One repository in flight. A mutable Struct rather than a `Data` precisely because it IS mutated
  # — three passes decide it, and each has to be able to record its answer without rebuilding the
  # rest. It never leaves this object; `#to_outcome` is the frozen thing callers see.
  Candidate = Struct.new(:record, :status, :message, :repository, keyword_init: true) do
    # Whatever the record's normalisation made of the submitted name, which is the value everything
    # downstream is about: what GitHub is asked, what is saved, and what the summary names.
    def full_name = record.github_full_name.to_s

    def undecided? = status.nil?

    def refuse(status, message)
      self.status = status
      self.message = message
      self
    end

    def to_outcome
      BulkRegistration::Outcome.new(full_name: full_name, status: status, message: message,
                                    repository: repository)
    end
  end
  private_constant :Candidate

  # Step 1 — the record's own rules, before GitHub is asked anything.
  #
  # `valid?` is what runs `normalize_full_name`, so every later step reads the normalised name; and
  # it is what separates the two ways a name can be refused without a network call. Uniqueness is
  # singled out because it is not a failure here — it is the expected state of most of a second
  # batch.
  def prepare(name)
    record = user.repositories.new(github_full_name: name)
    candidate = Candidate.new(record: record)
    return candidate if record.valid?

    return candidate.refuse(:already_registered, ALREADY_REGISTERED_MESSAGE) if taken?(record)

    candidate.refuse(:invalid, record.errors.messages_for(:github_full_name).first || UNKNOWN_FAILURE_MESSAGE)
  end

  # Step 2 — ownership, for everything the record's own rules did not already settle.
  #
  # One call for the whole batch. Names already refused are not sent: they must not cost a GitHub
  # question, and an already-registered repository the user has since lost admin on must still
  # report as already-registered rather than as not-yours.
  def verify(candidates)
    pending = candidates.select(&:undecided?)
    return if pending.empty?

    verdicts = InstallationRepositories.verify_batch(user: user, user_token: user_token,
                                                    full_names: pending.map(&:full_name))

    pending.zip(verdicts).each do |candidate, verdict|
      # A MISSING verdict refuses rather than falls through. `verify_batch` answers one verdict per
      # non-blank name and every pending candidate has a validated name, so a nil should be
      # unreachable — but "should be unreachable" is the wrong thing to rest a registration on, and
      # the failure it would produce is a repository saved without GitHub having been asked about it
      # at all. `InstallationRepositories.verify` defaults the same way for the same reason.
      next candidate.refuse(:unavailable, InstallationRepositories::MESSAGES[:unavailable]) if verdict.nil?
      next if verdict.verified?

      candidate.refuse(verdict.status, verdict.message)
    end
  end

  # Step 3 — save, one row at a time and independently, so one refusal cannot cost the rest.
  #
  # Both ways a save can lose a race are caught, because they are genuinely different: `save`
  # returning false is the uniqueness VALIDATION seeing a row that appeared since `prepare` ran, and
  # `RecordNotUnique` is the unique INDEX catching a row that appeared since the validation ran.
  # Neither is an error to report as one — a repository registered a moment ago by a concurrent
  # batch is already registered, which is the answer this feature already has words for.
  def save(candidate)
    return unless candidate.undecided?

    if candidate.record.save
      candidate.status = :registered
      candidate.repository = candidate.record
    elsif taken?(candidate.record)
      candidate.refuse(:already_registered, ALREADY_REGISTERED_MESSAGE)
    else
      candidate.refuse(:invalid, candidate.record.errors.messages_for(:github_full_name).first ||
                                 UNKNOWN_FAILURE_MESSAGE)
    end
  rescue ActiveRecord::RecordNotUnique
    candidate.refuse(:already_registered, ALREADY_REGISTERED_MESSAGE)
  end

  # Attach the existing row to every already-registered skip — but only one this user may open, so
  # the summary can link to it.
  #
  # One query for the whole batch rather than a lookup per row. A repository somebody else registered
  # is deliberately left unlinked: "already registered" is all this page may say about it, and a
  # link to a 403 says more than that.
  def link_existing(candidates)
    pending = candidates.select { |candidate| candidate.status == :already_registered }
    return if pending.empty?

    visible = visible_repositories(pending.map(&:full_name))
    pending.each { |candidate| candidate.repository = visible[candidate.full_name.downcase] }
  end

  # The repositories this user may open, narrowed to the batch — `Repository.accessible_by` is the
  # one place that set is defined, and it is exactly the set whose `show` page this user may open,
  # which is what makes it the right gate on a link.
  #
  # `LOWER(...) IN (...)` rather than a plain `IN`, matching the case-insensitive uniqueness rule
  # that produced these skips in the first place: a row registered as `Acme/API` is the row that
  # refused `acme/api`, and a case-sensitive lookup here would fail to find the very record it is
  # explaining.
  def visible_repositories(full_names)
    Repository.accessible_by(user)
              .where("LOWER(repositories.github_full_name) IN (?)", full_names.map(&:downcase))
              .index_by { |repository| repository.github_full_name.downcase }
  end

  def taken?(record) = record.errors.of_kind?(:github_full_name, :taken)
end
