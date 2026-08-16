# frozen_string_literal: true

# One authenticated `POST /api/v1/ingest` whose payload the endpoint refused.
#
# The schema-level argument — why only the authenticated family is recordable, why `details` is
# stored verbatim, why `user_agent` is on the row, why there are no `timestamps` — is in
# `CreateIngestRejections` and is not repeated here. What lives here is the retention rule and the
# two reads the surface makes.
class IngestRejection < ApplicationRecord
  belongs_to :repository

  # How many rejections one repository keeps.
  #
  # == Keyed per REPOSITORY, and that is not an oversight
  #
  # `Ingest::ObservationPruner` buckets its window per `(repository, branch)` and argues that case
  # at length: recency across a repository is interleaved, so a repository-wide bound would evict
  # `main`'s history first. ⚠️ **That reasoning cannot apply here, and this window must not be
  # "fixed" into the sibling's shape.** A rejected payload is by definition invalid — the branch it
  # names is exactly as untrustworthy as everything else in it, and `Ingest::Payload` may have
  # refused the body before any branch was parseable at all. There is no branch to key on, so the
  # bucket is the repository, and the difference between the two rules is a consequence of the
  # subject rather than an inconsistency between them.
  #
  # Bounded by ROWS and never by a date window, which is the one thing this does inherit from the
  # sibling: a repository whose CI went quiet has not stopped wanting to know why its last
  # deliveries were refused, and a time-based rule would delete that evidence for being idle.
  #
  # Five pages of `PANEL_LIMIT`. The design point is a pipeline refusing EVERY run — a version
  # floor 400s every suite over 256 KiB — so rows arrive at CI frequency and one screen of ten is
  # the last few minutes of a busy repository. Five pages is enough to show that the refusals are
  # continuous rather than a blip, and to show the RANGE of `user_agent` across them, which is what
  # turns "we are being refused" into "the old gem is being refused". It is not enough to be a log.
  REPOSITORY_RETENTION_ROWS = 50

  # How many reasons ONE row keeps.
  #
  # == Rows are not the only axis, and the other one is the dangerous one
  #
  # `REPOSITORY_RETENTION_ROWS` above bounds how many refusals a repository keeps. It says nothing
  # about how big one of them is, and `Ingest::Payload` has no cap of its own: it emits one error
  # per invalid spec — up to five, each embedding the client's own `file_path` — so the length of
  # `details` is a function of the SUITE SIZE, not of how wrong the payload is.
  #
  # ⚠️ That is not a tail case here, it is the design point. This table exists for a pipeline
  # refusing EVERY run, and the failure it was built to diagnose — a version floor, an envelope or
  # intent-schema skew — refuses every spec in the suite at once. A 20,000-example suite therefore
  # produces a ~2.5 MB row, fifty of them per repository, and the panel renders every element of
  # every one as an `<li>` on a page that loads on every visit. Bounding rows alone satisfies the
  # letter of "the table cannot grow unbounded" and none of the thing it protects; the panel would
  # render fine on one malformed spec and collapse on precisely the case it was designed for.
  #
  # Twenty because the row's job is to say WHAT the endpoint objected to, and twenty messages
  # already show the shape — a version floor repeats one message per spec, and the second one tells
  # a reader as much as the twenty-thousandth. `#omitted_reasons_count` carries what was dropped, so
  # the bound is disclosed rather than silently applied: the panel says "and 19,990 more", which is
  # itself the diagnosis (every spec, not one spec) that the full list would only have buried.
  RETAINED_REASONS_PER_ROW = 20

  # How long ONE retained reason may be.
  #
  # The count above does not bound the row on its own. Every per-spec message interpolates the
  # client's `file_path` verbatim, and a client free to send a malformed path is free to send a
  # megabyte of one — twenty of those is still a multi-megabyte row. Both halves are needed for the
  # ceiling to be arithmetic rather than a hope about well-behaved clients: 20 × ~300 characters
  # puts a row's `details` under ~6 KB, and a repository's whole retained window under ~300 KB, and
  # those are numbers that hold whatever the client sends.
  #
  # 300 characters because the longest real message this can hold is a schema violation naming a
  # file, a line and a JSON pointer, which runs to roughly a third of that — the bound is set where
  # it cannot cut a genuine message, so in practice it only ever fires on a pathological path.
  # `String#truncate` marks what it cut with an ellipsis, so a shortened reason is visibly shortened
  # rather than passing as the endpoint's whole sentence.
  MAX_REASON_LENGTH = 300

  # How many rows the repository page lists. The panel is a disclosure that this is happening and
  # what the endpoint said, not a browsable archive — the same bounded-panel shape every sibling on
  # that page uses.
  PANEL_LIMIT = 10

  # This repository's refusals, newest first, in the total ordering the recency index is built on.
  # `id` breaks the tie because a sharded run POSTs once per shard and a run refused for its
  # envelope is refused once per shard, landing several rows in one instant.
  scope :most_recent_first, -> { order(occurred_at: :desc, id: :desc) }

  # `details` is the client's own error list and is rendered as stored. jsonb, so this is already an
  # Array of Strings; the guard is for a legacy or hand-written row, not for the write path, which
  # always hands over `Ingest::Payload#errors` bounded by the two constants above.
  #
  # @return [Array<String>] at most `RETAINED_REASONS_PER_ROW` reasons
  def reasons = Array(details).map(&:to_s)

  # How many reasons the endpoint gave that this row does not hold.
  #
  # Derived rather than stored, so it cannot disagree with the list beside it — a stored copy would
  # be a second answer to a question `details` already answers half of. Floored at zero because
  # `total_reasons_count` defaults to 0 on a row that predates it, and a negative "omitted" would be
  # a worse lie than the truncation it is reporting.
  def omitted_reasons_count = [total_reasons_count - reasons.size, 0].max

  # Whether this row is showing part of what the endpoint said. The panel needs this to say so out
  # loud: a capped list that did not announce its cap would read as the complete objection, which is
  # the same class of quiet falsehood as the `Connected` stat this table exists to correct.
  def reasons_truncated? = omitted_reasons_count.positive?

  # What the request said it was. Nil when the client sent no `User-Agent` at all — the surface
  # says so rather than substituting a version nobody reported.
  def reported_client = user_agent.presence
end
