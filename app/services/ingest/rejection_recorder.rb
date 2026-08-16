# frozen_string_literal: true

module Ingest
  # Writes the one row a refused delivery leaves behind, bounded on every axis it can grow along —
  # `IngestRejection::RETAINED_REASONS_PER_ROW` and `MAX_REASON_LENGTH` cap what one row's `details`
  # holds, `MAX_USER_AGENT_LENGTH` caps the other client-controlled column beside it, and
  # `REPOSITORY_RETENTION_ROWS` caps how many rows a repository keeps, enforced on the way past.
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

    # @return [IngestRejection, nil] the row written, or nil when the WRITE failed and was reported.
    #   A prune that fails after a successful write still returns the row, because the row is
    #   committed and saying otherwise would make the return value the opposite of what happened.
    #   The caller does not branch on it — the response is the same either way — and it is returned
    #   rather than swallowed so tests can assert the difference.
    def record
      rejection = begin
        write
      rescue StandardError => e
        report(e, stage: "write")
        nil
      end

      # Skipped when the write failed: prune enforces a bound that nothing just pushed against, so
      # running it would only be a second chance to raise.
      return nil if rejection.nil?

      begin
        prune
      rescue StandardError => e
        # A prune failure is strictly milder than a write failure and is reported as its own stage
        # rather than sharing one. The row it should have made room for is committed, so nothing is
        # lost — the repository is temporarily over its retention bound, and the next refusal prunes
        # again from the same statement. The bound is self-healing precisely because every write
        # prunes; what is NOT self-healing is a failed write, which loses the refusal for good.
        report(e, stage: "prune")
      end

      rejection
    end

    private

    # `handled: true` because the request continues and answers normally: this is a reported
    # degradation, not an unhandled crash. The context names the repository so a burst of these is
    # attributable without re-reading the request log, and the stage so the two failures above are
    # distinguishable in the reporter — they mean different things and one of them loses data.
    def report(error, stage:)
      Rails.error.report(error, handled: true, severity: :warning,
                                context: { repository_id: @repository.id, stage: stage,
                                           component: "Ingest::RejectionRecorder" })
    end

    # `details` is `Ingest::Payload#errors` in the endpoint's own words, bounded but never re-worded
    # — see {#bounded_details}. `total_reasons_count` is the size of the list BEFORE that bound, so
    # the row can disclose what it dropped instead of passing a capped list off as the whole
    # objection.
    #
    # `user_agent` is bounded here for the same reason and by the same rule. It is the SECOND
    # client-controlled field on this row — the raw request header, handed over unmodified by
    # `Api::V1::IngestsController#create` — and the ceiling `IngestRejection::MAX_REASON_LENGTH`
    # states is a claim about the whole row, not about `details` alone. A ~100 KB header fits
    # comfortably inside Puma's allowance and would otherwise walk straight past a bound that only
    # ever measured its neighbour. `truncate` is non-mutating, exactly as in {#bounded_details}, and
    # `&.` after `.presence` preserves the nil-when-absent rule `#reported_client` reads: a client
    # that sent no header still stores NULL rather than an ellipsis or an empty string.
    #
    # `IngestRejection.create!` rather than `@repository.ingest_rejections.create!`: the two are
    # equivalent here — the row is built and saved either way — and going through the class gives
    # the write a single named seam. That matters because the whole point of the rescue above is a
    # failure path, and a failure path with no way to provoke it is a failure path nobody has run.
    def write
      reasons = Array(@errors).map(&:to_s)

      IngestRejection.create!(
        repository: @repository,
        occurred_at: @occurred_at,
        details: bounded_details(reasons),
        total_reasons_count: reasons.size,
        user_agent: @user_agent.presence&.truncate(IngestRejection::MAX_USER_AGENT_LENGTH)
      )
    end

    # The two-axis bound argued in `IngestRejection::RETAINED_REASONS_PER_ROW` and
    # `MAX_REASON_LENGTH`, applied here because this is the only thing that writes the column.
    #
    # == Why bounding is not the paraphrasing the ticket forbids
    #
    # The standing rule is that nothing platform-side re-words the endpoint's errors into a verdict.
    # This does not: every reason it keeps is the endpoint's own sentence, and what it drops is
    # dropped whole and COUNTED, not summarised. The alternative to a bound is not a more faithful
    # row — it is a row nobody can render, on the one failure this table was built for. Discarding
    # the tail and saying how long it was is the honest form of a surface that cannot show
    # everything, which is the same thing `RejectedIngests#bounded?` already says one level up.
    #
    # `first` rather than `last`: `Ingest::Payload` validates the envelope before it fans out over
    # `specs[]`, so the head of the list holds the envelope errors — the ones that describe the
    # whole delivery — while the tail is the per-spec repetition. A version floor is legible from
    # the first twenty and from a count; it is not more legible from the last twenty.
    #
    # `truncate` returns a new String and never mutates, which matters more than it looks: these
    # strings are the SAME objects `render_bad_request` is about to send, and success criterion 2
    # says the 400 body is byte-identical to `origin/main`. Truncating in place here would edit the
    # client's response from inside a bookkeeping path.
    def bounded_details(reasons)
      reasons.first(IngestRejection::RETAINED_REASONS_PER_ROW)
             .map { |reason| reason.truncate(IngestRejection::MAX_REASON_LENGTH) }
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
