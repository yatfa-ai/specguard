# frozen_string_literal: true

# The deliveries this repository's CI made that the endpoint REFUSED, together with the one thing
# the connection stat has to know about them.
#
# == Why the list and the stat verdict are one object
#
# The "Connection" stat on the Connect panel and the "Rejected deliveries" panel below it are two
# claims about the same fact, and before this they could not disagree because only one of them
# existed. `Api::BaseController#authenticate_api_key!` stamps `api_keys.last_used_at` on the way IN,
# so a delivery that is then refused for its payload records a use — and the stat, which reads
# exactly that column, rendered `Connected` in success tone over a pipeline whose every run was
# being thrown away. Holding the verdict beside the rows it is a verdict about is what stops the
# headline and the list under it describing different states of the same repository; `SlowestExamples`
# states the same rule for its own caption at the grain below.
#
# == What "still being refused" means, and what it deliberately does not
#
# {#refusing?} is **"the last delivery this repository is known to have completed was refused"** —
# the newest rejection is newer than the newest accepted run. That is a comparison between two
# recorded facts rather than a window in hours, and it is the rule because the failure this exists
# to catch is defined by ordering and not by age: a repository whose gzip payloads are all refused
# has its last accepted run receding into the past while refusals keep landing, which is exactly
# the arrangement this predicate reads. A repository that hit a bad payload yesterday and has
# ingested cleanly since has an accepted run on top, and reads healthy again with no window to
# expire and no threshold to pick.
#
# Two bounds on that, neither of them hidden:
#
# * **The accepted side is the newest run ROW.** A later shard delivered into a run created before
#   the rejection does not move `TestRun#created_at`, so a sharded run that is half-accepted and
#   half-refused reads as refusing. That is the reading this panel wants — a shard being refused is
#   a suite being partly thrown away — but it is a consequence worth naming rather than a claim
#   that every accepted byte is accounted for.
# * **A refusal ages out.** `IngestRejection::REPOSITORY_RETENTION_ROWS` bounds the table, so a
#   repository that was refused and then went silent forever eventually loses the row and the stat
#   returns to `Connected`. It is reporting what it can still see, and the panel says the list is
#   bounded for that reason.
#
# It says nothing about failed AUTHENTICATION. A 401 resolves no repository and writes no row (see
# `IngestRejection`), so neither this object nor the panel may imply it can see one.
class RejectedIngests
  # @param last_accepted_run_at [Time, nil] `Repository#latest_test_run`'s `created_at`, passed in
  #   rather than looked up: the page has already loaded that run for the Overview panel, and a
  #   second read here would be a second answer to "when did CI last succeed" with no structural
  #   reason to keep agreeing with the first. `nil` means no run has ever been accepted.
  def self.for(repository, last_accepted_run_at:, limit: IngestRejection::PANEL_LIMIT)
    new(rows: repository.ingest_rejections.most_recent_first.limit(limit).to_a,
        last_accepted_run_at: last_accepted_run_at)
  end

  def initialize(rows:, last_accepted_run_at:)
    @rows = rows
    @last_accepted_run_at = last_accepted_run_at
  end

  # The refusals, newest first, never longer than the limit this was built with. One query.
  attr_reader :rows

  def any? = rows.any?

  # The newest refusal, read off the head of the already-ordered list rather than as its own
  # aggregate — so the time the stat reports and the time at the top of the panel are the same row.
  def last_rejection_at = rows.first&.occurred_at

  # Whether the connection stat may still read healthy. See the class comment for the rule and for
  # both of its stated bounds.
  #
  # `nil` on the accepted side is not "no comparison" — it is a repository that has been refused and
  # has never had a run accepted at all, which is the most refusing state there is.
  def refusing?
    return false if last_rejection_at.nil?
    return true if @last_accepted_run_at.nil?

    last_rejection_at > @last_accepted_run_at
  end

  # Whether the retained list is at its bound, which is what the panel needs in order to say that
  # what it is showing is a window rather than the whole history. `>=` rather than `==` so a list
  # built with a larger limit than the panel's still reports honestly.
  def bounded? = rows.size >= IngestRejection::PANEL_LIMIT
end
