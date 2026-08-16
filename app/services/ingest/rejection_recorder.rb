# frozen_string_literal: true

module Ingest
  # Writes the one row a refused delivery leaves behind, and enforces
  # `IngestRejection::REPOSITORY_RETENTION_ROWS` on the way past.
  #
  # Called from `Api::V1::IngestsController#create` on the 400 path, BEFORE `render_bad_request`
  # returns. Everything about which requests are recordable — authenticated-but-refused only, never
  # a 401 — is argued in `IngestRejection` and `CreateIngestRejections` and is not re-derived here.
  #
  # == A failed record does NOT fail the request, and that is a decision rather than a default
  #
  # Writing a row on the 400 path introduces a failure mode the path does not have today: if the
  # write raises, a clean 400 becomes a 500. {Ingest::ObservationPruner} faces the identical
  # question and answers it the other way — it lets a prune failure fail the ingest — so the
  # divergence is deliberate and the reasons are these three.
  #
  # 1. **The endpoint had already decided.** By the time this runs, the payload has been refused
  #    and the response is determined. `ObservationPruner` runs after data has ALREADY COMMITTED on
  #    a request the endpoint accepted, so its 500 tells the client "your delivery may not have
  #    landed cleanly" — a true and useful thing to say. Here nothing was going to be stored either
  #    way, so a 500 would report a platform fault in place of the client fault that actually
  #    occurred, about a request whose outcome this row does not change.
  #
  # 2. **A 500 would corrupt the very diagnosis this table exists to deliver.** The gem's
  #    `Transport::Result::ADVICE` maps 400 to *"the endpoint rejected the payload"* and 401 to
  #    *"the API key was not accepted"*, and it holds no entry for 500 — so `Result#reason` degrades
  #    to a bare `"HTTP 500"`. The one stderr line a run is allowed would stop naming the payload as
  #    the cause. Failing here would therefore make the client-side half of this story WORSE for
  #    exactly the reader the panel is being built for.
  #
  # 3. **Retrying cannot help.** `ObservationPruner` reasons that an ingest is idempotent, so a
  #    client retry is cheap and the loud failure is worth its cost. A retry of a refused payload is
  #    the same invalid payload: it is refused again, and if this write is persistently failing it
  #    500s again. There is no state a retry converges on — only a client stuck in a loop against a
  #    request that was correctly refused the first time.
  #
  # So the failure is reported to `Rails.error.report` (Rails 8, already available, no new
  # dependency and no new seam) and the endpoint answers the 400 it had already determined. This is
  # the third option `ObservationPruner`'s own class comment names and declines to take for itself;
  # the reason it fits here and not there is (1) above — that class is protecting a claim about
  # committed data, and this one is not.
  #
  # ⚠️ The cost of this choice, stated rather than glossed: a persistently failing write makes the
  # panel silently incomplete. The dashboard would show refusals stopping while they continue. That
  # is why the failure goes to the error reporter rather than into a bare `rescue` — the loss is
  # invisible on the surface by construction, so it must be loud somewhere, and the reporter is the
  # somewhere. It must not be downgraded to a swallowed exception.
  class RejectionRecorder
    def self.record(repository, errors, user_agent:, occurred_at: Time.current)
      new(repository, errors, user_agent: user_agent, occurred_at: occurred_at).record
    end

    def initialize(repository, errors, user_agent:, occurred_at:)
      @repository = repository
      @errors = errors
      @user_agent = user_agent
      @occurred_at = occurred_at
    end

    # @return [IngestRejection, nil] the row written, or nil when the write failed and was
    #   reported. The caller does not branch on it — the response is the same either way — and it
    #   is returned rather than swallowed so tests can assert the difference.
    def record
      rejection = write
      prune
      rejection
    rescue StandardError => e
      # `handled: true` because the request continues and answers normally: this is a reported
      # degradation, not an unhandled crash. The context names the repository so a burst of these
      # is attributable without re-reading the request log.
      Rails.error.report(e, handled: true, severity: :warning,
                            context: { repository_id: @repository.id,
                                       component: "Ingest::RejectionRecorder" })
      nil
    end

    private

    # `details` is `Ingest::Payload#errors` verbatim. `Array()` normalises the same way
    # `Api::BaseController#render_bad_request` does, so the row and the response body carry
    # identically-shaped lists rather than two shapes that happen to agree.
    #
    # `IngestRejection.create!` rather than `@repository.ingest_rejections.create!`: the two are
    # equivalent here — the row is built and saved either way — and going through the class gives
    # the write a single named seam. That matters because the whole point of the rescue below is a
    # failure path, and a failure path with no way to provoke it is a failure path nobody has run.
    def write
      IngestRejection.create!(
        repository: @repository,
        occurred_at: @occurred_at,
        details: Array(@errors).map(&:to_s),
        user_agent: @user_agent.presence
      )
    end

    # Enforces the retention rule for THIS repository, in one statement.
    #
    # Deliberately unbatched, unlike `Ingest::ObservationPruner`, which issues bounded batches
    # against a ceiling. That class had to: it arrived after a table had grown for the whole life of
    # a repository with nothing ever deleting a row for age, so its first invocation could meet a
    # backlog of ~920M rows. This table ships WITH its rule, and every write prunes — so the
    # candidate set is at most one row on every invocation after the first, and the first meets an
    # empty table. There is no backlog for a batch ceiling to converge on.
    #
    # The boundary is the Nth most recent row as `(occurred_at, id)`, and the delete is strictly
    # `<` so the boundary row itself is retained: it is the Nth, and N rows are kept. Nil boundary
    # means the repository holds fewer than N rejections, which is the nothing-to-do case and is
    # every repository until it has been refused that many times.
    def prune
      boundary = repository_rejections.most_recent_first
                                      .offset(IngestRejection::REPOSITORY_RETENTION_ROWS - 1)
                                      .pick(:occurred_at, :id)
      return 0 if boundary.nil?

      repository_rejections
        .where("(ingest_rejections.occurred_at, ingest_rejections.id) < (?, ?)", boundary.first, boundary.last)
        .delete_all
    end

    def repository_rejections = IngestRejection.where(repository_id: @repository.id)
  end
end
