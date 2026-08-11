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
# Every name goes through `GithubOwnership` before it is saved, exactly as a single registration
# does through `RepositoriesController#save_with_verified_ownership`, and in the same order:
#
#   1. The record's own rules (`valid?`) — shape and uniqueness. A slug that is not `org/repo` never
#      becomes a GitHub question, and `normalize_full_name` has run, so GitHub is asked about the
#      value that would actually be stored.
#   2. Ownership, for everything that survived step 1 — one batched call, see
#      `GithubOwnership.verify_batch`.
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
  # It is also the thing that bounds `GithubOwnership.verify_batch`'s per-name fallback: absent a
  # cap, a submission naming a thousand repositories not in a truncated listing would be a thousand
  # GitHub round trips. Enforced by the caller (`BulkRegistrationsController#create`), which refuses
  # an oversized submission rather than silently registering a prefix of it.
  MAX_BATCH = 100

  # `is already registered in SpecGuard.` and friends are written as PREDICATES, so a caller renders
  # `"#{full_name} #{message}"` and gets a sentence. That is the same shape `GithubOwnership::MESSAGES`
  # is written in — the two are read side by side in one list and must not be phrased differently.
  ALREADY_REGISTERED_MESSAGE = "is already registered in SpecGuard."
  UNKNOWN_FAILURE_MESSAGE = "could not be registered."

  # One submitted repository and what became of it. `status` is `:registered` or the reason it was
  # not, which is either `:already_registered`, `:invalid`, or one of `GithubOwnership`'s non-verified
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
  SKIP_ORDER = %i[already_registered not_admin not_found invalid sso_required scope_too_narrow
                  token_rejected not_connected rate_limited unavailable].freeze

  # What each skip reason is called in the summary. The heading names the CATEGORY; the per-row
  # sentence carries the explanation, so these stay short enough to scan.
  SKIP_LABELS = {
    already_registered: "Already registered",
    not_admin: "Not administered by you on GitHub",
    not_found: "Not visible to your GitHub account",
    invalid: "Not a valid repository name",
    sso_required: "Blocked by organization SSO",
    scope_too_narrow: "GitHub authorization too narrow",
    token_rejected: "GitHub authorization no longer valid",
    not_connected: "GitHub not connected",
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

    # Reasons the batch names that a *re-run* cannot fix on its own — the user has to grant, wait or
    # ask somebody. Used to decide whether the summary offers the authorize button, so a batch that
    # skipped ten repositories for a dead token says what to do about it instead of only counting.
    def reauthorize? = skipped.any? { |o| %i[not_connected token_rejected scope_too_narrow].include?(o.status) }
  end

  def self.call(...) = new(...).call

  def initialize(user:, full_names:)
    @user = user
    # Deduplicated case-insensitively before anything else: GitHub names are case-insensitive, and
    # the same repository named twice in one batch would otherwise register once and report itself
    # as already registered, which is a true sentence about a batch the user did not submit.
    @names = Array(full_names).map { |name| name.to_s.strip }
                              .reject(&:empty?)
                              .uniq { |name| name.downcase }
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

  attr_reader :user, :names

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

    verdicts = GithubOwnership.verify_batch(user: user, full_names: pending.map(&:full_name))

    pending.zip(verdicts).each do |candidate, verdict|
      next if verdict.nil? || verdict.verified?

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

  # Owned OR shared with this user — the same set `RepositoriesController#index` lists, because that
  # is exactly the set whose `show` page this user may open.
  #
  # `LOWER(...) IN (...)` rather than a plain `IN`, matching the case-insensitive uniqueness rule
  # that produced these skips in the first place: a row registered as `Acme/API` is the row that
  # refused `acme/api`, and a case-sensitive lookup here would fail to find the very record it is
  # explaining.
  def visible_repositories(full_names)
    Repository.where(user_id: user.id)
              .or(Repository.where(id: user.repository_memberships.select(:repository_id)))
              .where("LOWER(repositories.github_full_name) IN (?)", full_names.map(&:downcase))
              .index_by { |repository| repository.github_full_name.downcase }
  end

  def taken?(record) = record.errors.of_kind?(:github_full_name, :taken)
end
