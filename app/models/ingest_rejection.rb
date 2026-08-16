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

  # How many rows the repository page lists. The panel is a disclosure that this is happening and
  # what the endpoint said, not a browsable archive — the same bounded-panel shape every sibling on
  # that page uses.
  PANEL_LIMIT = 10

  # This repository's refusals, newest first, in the total ordering the recency index is built on.
  # `id` breaks the tie because a sharded run POSTs once per shard and a run refused for its
  # envelope is refused once per shard, landing several rows in one instant.
  scope :most_recent_first, -> { order(occurred_at: :desc, id: :desc) }

  # `details` is the client's own error list and is rendered verbatim. Stored as jsonb, so this is
  # already an Array of Strings; the guard is for a legacy or hand-written row, not for the write
  # path, which always hands over `Ingest::Payload#errors`.
  #
  # @return [Array<String>]
  def reasons = Array(details).map(&:to_s)

  # What the request said it was. Nil when the client sent no `User-Agent` at all — the surface
  # says so rather than substituting a version nobody reported.
  def reported_client = user_agent.presence
end
