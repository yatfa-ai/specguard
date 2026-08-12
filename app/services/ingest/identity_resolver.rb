# frozen_string_literal: true

module Ingest
  # Maps every example one run ingested onto the durable {SpecIdentity} it belongs to, and is the
  # only thing that writes that table.
  #
  # For each unresolved observation: take the text that represents it ({SpecObservation#signal},
  # which defers to {Ingest::SpecSignal}), embed it, ask this repository's identities for the
  # nearest neighbour within {SpecIdentity::MATCH_DISTANCE}, and either re-sight the row that came
  # back or insert a new one. The observation is then pointed at whichever it was.
  #
  # Ahead of all of that sits one equality: text byte-identical to a row this repository already
  # holds is re-sighted without embedding anything at all ({#identical_text}). It answers the
  # ordinary case — an unchanged suite re-ingested — and it is a shortcut past the above rather than
  # a replacement for it, because a miss there proves nothing. It is asked once per PAGE rather than
  # once per row ({#digest_index}), so the ordinary case is ~40 digest lookups at the design point
  # rather than 20,000, and what it decides is WRITTEN once per page too ({#flush_page}), so that
  # case is ~80 `UPDATE`s rather than 40,000. The decision both of those feed is still made one row
  # at a time.
  #
  # == Why this runs in a job and not in the ingest transaction
  #
  # {Ingest::ObservationRecorder} writes inside the transaction holding the run's `FOR UPDATE` lock,
  # and its class comment explains at length why that lock is taken where it is: a delete-then-upsert
  # keyed on the shard is only atomic against a concurrent delivery if something holds the run still
  # while it happens. N shards therefore serialize there, which is affordable because the whole
  # section is one bulk statement.
  #
  # This is not one statement. At the 20,000-example design point it is 20,000 embeddings and 20,000
  # index lookups, and putting that inside the serialized section would make every other shard of
  # the run wait behind it. That is the reason the ingest endpoint answers `202` before any per-spec
  # work and the reason the `enqueue_embeddings` seam exists at all. So resolution runs afterwards,
  # out of band, against rows that are already committed.
  #
  # == Idempotency, and the two ways it is reached twice
  #
  # Every shard of a run enqueues a job for the *run*, so an N-shard delivery schedules N jobs over
  # the same rows, and a redelivered shard schedules another. Both are ordinary, and neither is
  # special-cased:
  #
  # * The work list is `SpecObservation.unresolved`, so a row already claimed is simply not in it.
  # * Two jobs that read the list at the same moment and both miss on the same text converge on one
  #   row, because the insert is an upsert onto `(repository_id, text_digest)` — see
  #   {#claim_identity} and the migration's "The conflict key" section.
  #
  # == The work list is TWO lists, and the second is what makes an unresolved row recoverable
  #
  # This run's unresolved observations, and — before them — the rows of the repository's EARLIER runs
  # that nothing else will ever revisit. Until that second list existed there was exactly one
  # `perform_later` in the whole application and its argument was the run just created, so run-1's
  # leftovers were never read again by anything: run-2's job walks run-2's rows. The identity was not
  # lost — run-2 re-creates it from the same text — but run-1's duration and outcome stayed orphaned
  # from that test's history permanently, which is the half of "nothing is permanently lost" that was
  # not true.
  #
  # That second list is itself two, because there are two ways a row is left behind and only one of
  # them leaves evidence (see {#retry_backlog}):
  #
  # * **Something was tried and it failed.** Stamped with `embed_failed_at`, bounded by
  #   {SpecObservation::EMBED_RETRY_WINDOW}, ordered so a large backlog drains fairly. Ordinarily
  #   that is the provider being asked and unable to answer; since {#claim_inherited} it is also a
  #   row of THIS list that failed some other way while the sweep held it. One stamp covers both,
  #   and {#record_resolve_failure} is where that is argued rather than assumed.
  # * **Nothing was ever tried**, because the job that would have tried never got there — an
  #   exception out of `perform`, a dropped connection, a deploy mid-job. There is no stamp, since
  #   {#record_resolve_failure} only runs where the row was actually reached, so this population
  #   was invisible to the first list and to both audit scopes: the ONE unresolved state with no
  #   query that could find it. {SpecObservation::EMBED_ATTEMPT_GRACE} is what makes it sweepable
  #   without racing the job that may still be on its way.
  #
  # The trigger is deliberately the next INGEST rather than a scheduled sweep. `config/recurring.yml`
  # has one production entry and it is Solid Queue housekeeping; adding a cron is a deployment
  # concern and a second thing that can be off. An ingest is the moment the answer can have changed
  # and the moment somebody is waiting for it, and it is already enqueuing this job.
  #
  # == What is deliberately not here
  #
  # Batching the embed calls, and caching them — the rest of the *Cost* axis, still SPGD-72's. THREE
  # of that paragraph's items ARE now here, and they are the three that do not depend on which
  # provider is installed. Skipping the re-embed when a run's text is byte-identical to a row this
  # repository already holds: {#identical_text}. Batching the lookup that answers it, so asking it
  # costs one lookup per page rather than one per row: {#digest_index}. Batching the two `UPDATE`s
  # the answer then writes, so an unchanged page costs a constant number of statements rather than
  # two per row: {#flush_page}. They shipped in that order because the first removes work rather
  # than reorganising it, and because the key both of the first two need already existed; each of
  # the later ones was worth doing once round trips rather than work were what was left. What
  # remains is the EMBED — batching it and caching it — which is a different thing entirely: it is
  # the path a CHANGED suite takes, and no equality can shortcut it. Also the ANN recall measurement
  # {#nearest} hands over by name.
  #
  # **Not** a `retry_on` / `discard_on` policy on {Ingest::IdentityResolutionJob}, and that omission
  # is now a finding rather than a deferral: `retry_on EmbeddingGenerator::Error` cannot fire.
  # {#embed} rescues that class at the single call site and returns nil, so the error never reaches
  # ActiveJob and the job always completes *successfully* having resolved nothing. The rescue is
  # deliberate — one unembeddable example must not abandon the other 19,999 — so the retry has to
  # live in the work list, which is where it now lives.
  #
  # {#claim_inherited} is the same argument applied one level out, and it is why a `retry_on` for
  # the OTHER errors is not the answer either. One inherited row that raises — an ANN lookup on a
  # dropped connection, a dimension-mismatched stored vector — used to abort the whole delivery
  # before this run's own list was reached, on every ingest of that repository forever, because the
  # backlog is walked first and a deterministic failure fails identically every time. A job retry
  # would only multiply that into N identical failed executions. Recovery lives in the work list, so
  # the containment does too: the row takes a stamp, sinks under the fairness ordering, and the
  # delivery goes on.
  class IdentityResolver
    # Rows per database round trip on the work list. A repository-scoped ANN lookup and an upsert
    # per row means a page of genuinely NEW text is round-trip bound whatever this is; what the batch
    # bounds is how many observations are held in memory at once, and 20,000 of them is the design
    # point.
    #
    # It is now also the width of every list this class puts ON THE WIRE rather than merely holds:
    # the digest short-circuit's `IN` list ({#digest_index}), and the two `VALUES` lists
    # {#flush_page} spends a page's decisions through. So on the ordinary case — an unchanged suite
    # re-ingested — the whole page's digest QUESTION is one round trip and the whole page's ANSWER
    # is two more.
    #
    # Stated as the invariant, because that is the part that survives the next slice: an unchanged
    # page costs **one digest lookup and two `UPDATE`s PER PAGE** — the identities' `last_seen`
    # touch and the observations' `spec_identity_id` — **plus a small constant for the work-list
    # reads**. Both `UPDATE`s were per ROW until SPGD-395, and that is why the resolver spec's
    # round-trip group now bounds them by their own predicate: a page cost that is O(1) in the page
    # WIDTH is a claim worth a falsifier, and it was O(N) while this comment's previous revision
    # said so.
    #
    # As an illustration and not as the claim: on this tree a 12-row unchanged page measures 11
    # round trips — 1 digest lookup, 2 UPDATEs, 4 reads (the repository, {#resolve}'s two backlog
    # lists, and the run's own page) and {#report}'s 4 counts — and a FULL page of 500 measures the
    # same 11, where it measured ~1,009. That is the whole of what this slice bought, and it is why
    # the figure is now flat in the width rather than proportional to it. Deliberately phrased as
    # the invariant plus an example, because the total is rebase-fragile in a way the invariant is
    # not: it was 28 before SPGD-379 split the backlog into two reads, 29 after, and 33 once
    # SPGD-388 added the completion report — three revisions of one number for changes to methods
    # this constant has nothing to do with.
    #
    # What it does NOT bound is a page of genuinely new text, and the paragraph above says why: the
    # embed, the ANN lookup and the upsert are still one per row, so a first run is round-trip bound
    # whatever this is. The number tuned here is what an UNCHANGED page costs, which is the ordinary
    # case; the changed one is SPGD-72's remaining embed work.
    #
    # That makes this a size worth tuning where it used not to be, but not a different KIND of
    # constant: both readings bound one page, and neither is a bound on how much work a delivery
    # inherits — that is {RETRY_SWEEP_LIMIT}, and it stays separate for the reason stated there.
    BATCH_SIZE = 500

    # **How much of an earlier run's unfinished business ONE JOB is made to pay for.** The cost
    # bound on the cross-run sweep — on BOTH of the lists {#retry_backlog} draws it from, together
    # and not each — and its own constant rather than a reuse of `BATCH_SIZE` by the rule this
    # codebase's `_LIMIT`s obey: that one bounds how many rows are held in MEMORY at once and would
    # be just as correct at 50 or 5,000, this bounds how much EXTRA WORK a delivery inherits from
    # deliveries before it. They move for different reasons and one number standing for both would
    # make that a single edit nobody meant to make.
    #
    # A bound is needed because the failure mode is the design point: a provider outage across a
    # 20,000-example run leaves 20,000 failed rows — and a job that dies mid-resolve leaves up to as
    # many unattempted ones — so an uncapped sweep would make the very next ingest do 40,000
    # embeddings, its own suite plus the whole backlog, on the one path that is already the largest
    # thing this application does. Capped, a job is at worst its own share of the suite plus 500, and
    # a backlog larger than the cap drains across the ingests that follow instead of landing on one
    # of them.
    #
    # **Across both lists and never per list**, which is what {#retry_backlog} is a method for
    # rather than a relation: two lists each capped at this number is a job inheriting `2 × 500`
    # while this comment went on claiming 500.
    #
    # == A JOB and not an INGEST, and the difference is the shard count
    #
    # Stated precisely, because the imprecise version is contradicted by this class's own comment
    # three sections up: *every shard of a run enqueues a job for the run*, so an N-shard delivery
    # runs {#retry_backlog} N times, largely over the same rows, for up to `N × RETRY_SWEEP_LIMIT`
    # backlog embeddings in one ingest. That is the same duplicate-work multiplier
    # {SpecObservation::EMBED_RETRY_WINDOW} names as fatal to an attempt cap, and it does not
    # disappear here just because this is a cost bound rather than a lifetime bound.
    #
    # It remains a bound worth having, and the reason is what it is a function OF. `N × 500` follows
    # the SHARD COUNT, which is a small constant a client picks; an uncapped sweep follows the
    # BACKLOG, which is the suite size. A 20,000-row backlog still cannot land on one delivery. What
    # would be untrue is the sentence "an ingest is at worst its own suite plus 500", so it is not
    # the sentence.
    #
    # It is a cap on ROWS and never a fraction of the run, so a small delivery cannot be made to
    # carry a large one's backlog in proportion to itself. Sized at the same order as one batch: the
    # sweep loads its rows in a single query rather than in batches, so this is also what keeps that
    # load the size of one `BATCH_SIZE` page — the coincidence of value is not a coincidence of
    # meaning, which is precisely why they are two constants.
    RETRY_SWEEP_LIMIT = 500

    def self.resolve(run) = new(run).resolve

    def initialize(run)
      @run = run
      @repository = run.repository
      # Replaced wholesale by each {#resolve_page}; `{}` here so the two methods that touch it —
      # {#identical_text} and {#claim_identity} — are total rather than conditional on a page being
      # open, and so that a page is a page's worth of entries rather than the suite's.
      @digest_index = {}
      # The page's two write buffers, emptied and refilled by every {#resolve_page} for the same
      # reason and with the same total-rather-than-conditional guarantee: {#resight} and {#claim}
      # append to them one row at a time, and {#flush_page} spends each on ONE statement. See
      # {#resolve_page} for why the decision stays per row while the write is per page.
      @sightings = []
      @links = []
    end

    # @return [Integer] how many observations now carry an identity that did not before — **across
    #   both lists**, so a rescued row of an earlier run is counted here too. Not `specs.size`, and
    #   deliberately not "observations OF THIS RUN": the number says what this invocation resolved,
    #   which is the only thing it has ever been read as and the only thing the caller could act on.
    #   A run whose own rows all resolved and which rescued four earlier ones returns the four; the
    #   alternative — counting only `@run`'s rows — would report a sweep that did real work as a
    #   no-op. `spec/services/ingest/identity_resolver_spec.rb`'s "running twice over the same run"
    #   example is unaffected either way: a repository with no failed embeds has an empty backlog.
    #
    #   An inherited row {#claim_inherited} contained contributes 0, for the same reason a row that
    #   never had an identity to find does: it does not now carry one. The count says what was
    #   resolved and never what was attempted, so containment cannot inflate it.
    def resolve
      resolved = 0

      # **The backlog first, and the order is deliberately NOT load-bearing.**
      #
      # It was, and that was the defect this rework exists for. A re-sighting moves the identity's
      # "last known path", so whichever observation is resolved LAST used to have the final word on
      # where the test was last seen — and this loop holds observations from several runs at once,
      # so "last" had to mean "newest" for that word to be true. Two axes then wanted one ordering
      # key: chronology wants oldest-first, and {#failed_embed_backlog}'s fairness wants least-tried
      # first, which is INVERSELY correlated with age because an older failed row has been swept by
      # more ingests and carries a higher count. No single key serves both, and the one that was
      # chosen served fairness while a comment here claimed it served chronology.
      #
      # So the ordering stopped being the mechanism. {SpecIdentity::SIGHTING_NOT_OLDER} refuses, in
      # SQL and on both of the two paths that re-sight a row, a sighting from a run older than the
      # one the identity already names. Monotonic by construction: these two lists may be walked in
      # any order at all — including interleaved by two concurrent jobs, which no iteration order
      # could have covered anyway — and the identity still ends on the newest run that saw the test.
      #
      # The backlog stays first because it is the older debt and a rescue is what somebody is
      # waiting for, not because anything depends on it being first.
      #
      # **Both lists are walked a PAGE at a time**, because the digest short-circuit is answered per
      # page and what it decides is written per page — see {#resolve_page}. The backlog is already
      # capped at one page by
      # {RETRY_SWEEP_LIMIT} — across BOTH of the reads {#retry_backlog} draws it from, together and
      # not each — and those reads' `order` and `limit` are load-bearing, so it is handed over as the
      # one page it already is rather than made symmetric with `find_in_batches`, which would ignore
      # both. It arrives as an Array for that budget's arithmetic and is a page all the same.
      #
      # `inherited: true` sends this page's rows through {#claim_inherited} and not {#claim}, and
      # the asymmetry is the point: a row of an earlier run is best-effort by construction, so one
      # of them failing is contained to itself rather than allowed to end the delivery. The
      # run-scoped loop below takes the default and keeps claiming bare — see {#claim_inherited} for
      # why the two halves are treated differently.
      resolved += resolve_page(retry_backlog, inherited: true)

      @run.spec_observations.unresolved.find_in_batches(batch_size: BATCH_SIZE) do |page|
        resolved += resolve_page(page)
      end

      report(resolved)

      resolved
    end

    private

    # **The one thing this pass says for itself.** Until it existed the whole asynchronous half of
    # ingest had a single voice — the per-row warn in {#embed} — and that voice can only speak about
    # rows the provider refused. So a resolve of 20,000 rows that worked perfectly and a resolve that
    # was never scheduled at all were the same observable event, while a provider outage across the
    # design point emitted 20,000 identical lines and no total. This is the complement: one line, per
    # pass, whatever happened, carrying the number {#resolve} already computes and the population it
    # left behind.
    #
    # `info` rather than `warn`, and unconditional rather than "only when something is wrong". The
    # figure an operator most needs is `resolved=0`, and a report that stays silent when there is
    # nothing to complain about cannot distinguish "nothing to complain about" from "did not run" —
    # which is the defect this method exists for, reintroduced one level up.
    #
    # Emitted from HERE and not from {Ingest::IdentityResolutionJob} because the counts are this
    # class's own vocabulary: which four scopes are the bounded ones, and why a raw `unresolved`
    # count is not among them, is the knowledge {#retry_backlog} and {SpecObservation} hold. The job
    # is thin by its own class comment's rule, and it stays thin. A run that no longer exists never
    # reaches here at all — the job returns before it resolves, and there is nothing to report.
    #
    # A single line and not four, because a log is read by grep and by eye: four lines per job would
    # have to be re-joined by whoever read them, and the joining key would be the run id they all
    # already carry.
    def report(resolved)
      counts = unresolved_bounds.map { |label, relation| "#{label}=#{relation.count}" }

      Rails.logger.info(
        "[IdentityResolver] run=#{@run.id} resolved=#{resolved} " \
        "repository=#{@repository.id} #{counts.join(' ')}"
      )
    end

    # **The repository's remaining unresolved population, as the four figures it is honest to state
    # it in** — and deliberately not as one.
    #
    # Each is `@repository.spec_observations` narrowed by a scope that already exists and had, until
    # this method, no production caller at all. Repository scoping is the caller's on all four
    # ({SpecObservation}'s scopes say so where they are defined), which is why they are narrowed here
    # and exactly as {#failed_embed_backlog} and {#unattempted_embed_backlog} narrow theirs.
    #
    # == Why four figures and never a sum
    #
    # * **"We stopped trying" and "we are still trying" are different facts**, which is the reason
    #   `.embed_abandoned` and `.embed_unattempted_abandoned` were given their own scopes:
    #   *"a bound that cannot be queried is a bound nobody can audit"*. Pooling them back into one
    #   `unresolved=N` here would spend that separation on the way out.
    # * **The two backlogs are different facts**, because the reason nobody attended to them differs
    #   — asked and refused, versus never asked — and that is the whole distinction {#retry_backlog}
    #   is two lists for.
    # * **`never_attempted_gave_up` is NOT a failure count**, and its name says so. That scope's own
    #   comment forbids the other reading outright: the set is *"rows nothing will ever attempt
    #   again"* and NOT *"rows we failed"*, because it pools rows a dead job stranded and outlived
    #   with the frozen signalless tail that is behaving exactly as it should. Labelling it a failure
    #   would ship *"an alarming number that is mostly legacy rows behaving correctly"*.
    #
    # == Why not `.unresolved.count`, which is the figure everyone reaches for first
    #
    # Because it is not bounded away from rows that are merely YOUNG. All four scopes here sit inside
    # `EMBED_RETRY_WINDOW` and outside `EMBED_ATTEMPT_GRACE`; a raw count is neither, and
    # {#unattempted_embed_backlog} states why that matters — the unattempted population *"cannot be
    # empty on a healthy repository — every row is in it between the ingest commit and the job's
    # pass"*. A raw count taken while a concurrent 20,000-row delivery is mid-flight reports that
    # delivery as a problem, on every ingest, forever. The four figures stay at zero through it.
    #
    # == What these numbers are NOT
    #
    # They are a REPOSITORY snapshot read at the end of this pass — not a tally of what this pass
    # did, which is what `resolved` is, and not a partition of anything. Every shard of a run
    # enqueues a job for the run, so an N-shard delivery emits N of these over largely the same rows
    # while other jobs are mutating them; the same distinction {#resolve}'s `@return` draws for the
    # resolved count, kept rather than re-invented.
    #
    # And they do not add up to the run, or to the repository, or to each other's complement. Rows
    # younger than the grace are outside all four, and so is the signalless tail pooled inside the
    # last of them. Four bounded figures that answer four questions is the whole claim; a total would
    # be a new vacuous figure replacing a missing one.
    def unresolved_bounds
      observations = @repository.spec_observations

      { embed_failed_retrying: observations.embed_retryable,
        embed_failed_gave_up: observations.embed_abandoned,
        never_attempted_retrying: observations.embed_unattempted_retryable,
        never_attempted_gave_up: observations.embed_unattempted_abandoned }
    end

    # **The work that is not this run's**, under one budget — the rows of the repository's EARLIER
    # runs that this ingest is entitled to attempt on their behalf. Two populations, and they are
    # two because the reason nobody attended to them is different:
    #
    # * {#failed_embed_backlog} — something was tried and it failed. Stamped with `embed_failed_at`,
    #   ordered by how often it has been tried, bounded by {SpecObservation::EMBED_RETRY_WINDOW}.
    #   Ordinarily that is the provider being asked and unable to answer; since {#claim_inherited} it
    #   is also a row of THIS list that failed some other way while the sweep held it. One stamp
    #   covers both, and {#record_resolve_failure} is where that is argued rather than assumed.
    # * {#unattempted_embed_backlog} — nothing was ever tried, because the job that would have tried
    #   never got there. Unstamped, and therefore invisible to every mechanism the first list is
    #   built on.
    #
    # The failures come first and take their share of the budget first. Not because the order is
    # load-bearing — {#resolve} explains at length why no iteration order is any more — but because
    # a stamped row is a row something has already tried and failed to rescue at least once, which
    # is a stronger claim on a scarce slot than a row nobody has tried at all.
    #
    # == ONE budget, and this is the whole reason the method exists
    #
    # `RETRY_SWEEP_LIMIT` bounds *"how much EXTRA WORK a delivery inherits from deliveries before
    # it"*, and that sentence is about the inheriting, not about any particular list. Two
    # independently `.limit(RETRY_SWEEP_LIMIT)`ed relations would quietly double what a job can
    # inherit — `N × 2 × 500` at the shard multiplicity that constant already accounts for — while
    # every word of its comment went on reading as though it had not changed. So the second list is
    # asked for the REMAINDER, and a full first list means it is not queried at all.
    #
    # An Array rather than a relation, which is what makes that arithmetic possible at all: two
    # relations over disjoint predicates with different ordering keys cannot be capped jointly in
    # one statement without a UNION whose outer ordering key neither list has. {#resolve} hands the
    # result straight to {#resolve_page} as the ONE PAGE it already is — `RETRY_SWEEP_LIMIT` is one
    # `BATCH_SIZE` — so the digest short-circuit is batched over this list exactly as it is over a
    # run's own page, and nothing downstream notices that this is an Array. `find_in_batches` was
    # never available to either half in any case: it ignores exactly the `order` and `limit` these
    # two reads are, which is why the cap is applied here and the page seam reads it rather than
    # re-deriving it.
    def retry_backlog
      failed = failed_embed_backlog.to_a
      remaining = RETRY_SWEEP_LIMIT - failed.size
      return failed if remaining <= 0

      failed + unattempted_embed_backlog(remaining).to_a
    end

    # One page of the work list: ask the database once which of these texts this repository already
    # holds, decide each row against that answer, and write what the whole page decided in two
    # statements rather than in two per row.
    #
    # This is where the page seam has to be. Both of {#resolve}'s lists run through {#claim}, and
    # {#identity_for} sees one observation at a time and cannot know what the other 499 are — so a
    # lookup driven from in there is a lookup per row however cheap the row makes it, and so is a
    # write.
    #
    # **The DECISION stays per row and only the COST is per page**, which is the same division
    # {#digest_index} introduced and is now the shape of both halves. A row the index cannot answer
    # still falls through to embed/{#nearest}/{#claim_identity} unchanged, and {#identical_text} is
    # still the method that answers one row — see it for why that seam is load-bearing rather than
    # stylistic. What changed is that {#resight} and {#claim} now RECORD what they decided instead
    # of writing it, and {#flush_page} spends the two buffers on one statement each.
    #
    # `inherited:` chooses which of the two claim seams the page's rows take, and it is a parameter
    # rather than a second method because the page itself is identical either way: the same one
    # lookup, the same per-row decision after it, the same two writes at the end. {#claim_inherited}
    # for the repository's earlier runs, {#claim} for `@run`'s own, and {#claim_inherited} is where
    # the asymmetry is argued.
    #
    # **{#digest_index} and {#flush_page} are outside that containment, deliberately and for one
    # reason.** Each is one query for the whole page, so a failure in either is not row-shaped: there
    # is no single observation it can be attributed to, stamped and demoted. Rescuing the lookup
    # would leave an empty map that silently re-embeds the entire page while reporting a clean sweep;
    # rescuing the flush would report rows as resolved that carry no identity. Both propagate, which
    # is the same line {#claim_inherited}'s stated non-promise draws.
    #
    # == The `ensure` is load-bearing, and it is what keeps a DIED pass behaving as it did
    #
    # A per-row write commits per row, so a pass that raises halfway through a page used to leave
    # the rows it had already claimed holding their identity and the rest untouched and unstamped —
    # the state "a resolve that died before it reached the rest of the run" describes at length and
    # the cross-run sweep exists to rescue. A buffer flushed only on the happy path would quietly
    # widen that: everything the page had decided would be discarded, and rows the resolver had
    # genuinely resolved would go back to looking never-attempted. So the flush runs on the way out
    # whatever the way out is, and the exception propagates after it exactly as before.
    def resolve_page(observations, inherited: false)
      @digest_index = digest_index(observations)
      @sightings = []
      @links = []
      resolved = 0

      begin
        observations.each do |observation|
          inherited ? claim_inherited(observation) : claim(observation)
        end
      ensure
        resolved = flush_page
      end

      resolved
    end

    # The page's two writes, and the whole of what this slice bought: **O(1) `UPDATE` statements per
    # page where there were two per ROW.**
    #
    # Order matters and it is the order the per-row path had. A re-sighting moves the identity;
    # linking the observation is what makes it resolved. Flushing the sightings first keeps the two
    # in the same relative order they were written in when they were written per row, so a pass that
    # dies between them leaves the same state a pass that died between two rows' UPDATEs did.
    #
    # @return [Integer] how many observations this page actually linked — see {#link_all}, which
    #   counts the rows the statement MATCHED rather than the rows it was handed.
    def flush_page
      resight_all
      link_all
    end

    # `digest => identity id`, for every text on this page that this repository already holds.
    #
    # **One `WHERE text_digest IN (…)` against the unique `(repository_id, text_digest)` index**, in
    # place of the one equality per row this used to be. On run 2 of an unchanged 20,000-example
    # suite — the ordinary case, since every run writes its own observations with a NULL identity and
    # so re-presents the WHOLE suite — that is ~40 digest lookups where it was 20,000. Nothing about
    # the work changed; SPGD-373 already removed the embed from this path. What is left is the
    # lookups, and this is them. The two `UPDATE`s a re-sighting then writes were the other O(N) on
    # this path, and they are now one statement each per page too — {#flush_page}, and see
    # {BATCH_SIZE} for what a page costs once both halves are batched.
    #
    # Digested in Ruby before anything is asked, which costs no queries: {Ingest::SpecSignal} is pure
    # over the already-loaded row, and {SpecIdentity.digest_for} is a SHA-256 of a string.
    #
    # This builds each row's signal a second time — {#identity_for} builds its own — and that is
    # deliberate rather than an oversight. {SpecObservation#signal} does not memoise, so the price
    # is one extra object per row and no extra query. Caching it would mean carrying a
    # per-observation map alongside the digest map for the width of a page, to save an allocation
    # nothing has measured; and {#identity_for} taking a pre-built signal would move the seam that
    # `resolve_as_the_loser`'s stub hangs on. Not worth either.
    #
    # `pluck` and not a relation of records: the value is an id, and {SpecIdentity::RESIGHTABLE} is
    # what a re-sighting moves — `text`, `text_digest`, `signal_source` and `embedding` are
    # deliberately absent from it, so nothing downstream of a hit ever reads the row. Loading 500
    # identities to use 500 ids would put the vectors this method exists to avoid touching straight
    # into memory.
    #
    # `uniq` because a page may carry the same text twice — two examples with identical
    # `full_description` is the case `identity_resolver_spec.rb`'s "cannot separate two tests whose
    # descriptions are identical" pins — and an `IN` list is not the place to repeat it. Empty page,
    # or a page of nothing but `:none` rows, asks nothing at all rather than issuing `IN ()`.
    # `filter_map` and not `map`: a `:none` row has no text, and `digest_for(nil)` is a perfectly
    # good SHA-256 of the empty string — so a nil left in this list becomes a real digest that no row
    # can ever hold, and a real round trip spent asking about it. That is the whole cost this method
    # exists to remove, reintroduced by one method name.
    #
    # No early return for the empty case, deliberately: `where(text_digest: [])` compiles to `1=0`
    # and Rails answers it without a round trip, so a page of nothing but `:none` rows already costs
    # nothing and a guard here would be a branch no test could reach. The property is pinned by the
    # resolver spec's "still costs nothing when a page carries no text to look up at all", which
    # asserts the ABSENCE of the query rather than the presence of the guard — so it stays honest if
    # that optimisation ever goes away.
    def digest_index(observations)
      digests = observations.filter_map { |observation| observation.signal.text }
                            .uniq.map { |text| SpecIdentity.digest_for(text) }

      @repository.spec_identities.where(text_digest: digests).pluck(:text_digest, :id).to_h
    end

    # The rows an EARLIER run of this repository was reached on and failed to resolve — the provider
    # unable to answer, or a failure {#claim_inherited} contained — and which this ingest is entitled
    # to re-attempt. Empty on a repository that has never had one, which is the normal case and costs
    # one probe of an index that is empty there — see the migration for why the index is partial.
    #
    # Scoped to the repository because identity is per repository and so is the provider outage that
    # produced these rows; `@repository` is already in hand from {#initialize}. `@run` is EXCLUDED
    # rather than left in: this run's own unresolved rows are {#resolve}'s run-scoped list, and a row
    # that appeared on both would be embedded twice in one pass — once for nothing.
    #
    # Ordered least-tried first, and — since the monotonicity guard {#resolve} describes — ordered
    # for FAIRNESS alone. Nothing about correctness rides on this key any more, which is what frees
    # it to be the one fairness actually wants: a pure `embed_failed_at` ordering re-attempts the
    # same 500 rows on every ingest until the window closes on all 20,000 at once — they failed in
    # the same outage, so they expire together and 19,500 of them never get a single retry. Ordering
    # on `embed_failure_count` makes a retried row sink below the rows that have not been tried yet,
    # so the sweep round-robins the whole backlog instead of a window into it. `embed_failed_at`
    # then `id` break the ties, so the order is total and stable rather than whatever the planner
    # returned first.
    #
    # What that counter counts is attempts BY ANYTHING — the N concurrent jobs an N-shard delivery
    # schedules over these same rows included — and {SpecObservation::EMBED_RETRY_WINDOW} reads it
    # exactly that way when it refuses it as a CAP. The two are not in tension: shard multiplicity
    # is fatal to a cap, because it spends the allowance on the failure rather than on the retrying,
    # and harmless to a ranking, because concurrent sweeps bump roughly the same top-N together and
    # leave the ORDER BETWEEN rows where it was. This wants a key that is monotone in "has been
    # tried", not a key that is calibrated in tries.
    def failed_embed_backlog
      @repository.spec_observations
                 .embed_retryable
                 .where.not(test_run_id: @run.id)
                 .order(:embed_failure_count, :embed_failed_at, :id)
                 .limit(RETRY_SWEEP_LIMIT)
    end

    # The rows of this repository's earlier runs that were never attempted at all — the population
    # `SpecObservation::EMBED_ATTEMPT_GRACE` and the migration beside it exist for, and the one that
    # had no query that could find it.
    #
    # Its whole predicate is an absence, so unlike the failure backlog it cannot be empty on a
    # healthy repository — every row is in it between the ingest commit and the job's pass. What
    # keeps it small is the grace floor, which excludes exactly the rows a live job is plausibly
    # still walking, and the fact that a row leaves by being resolved. The new partial index is what
    # keeps the probe cheap all the same; see the migration for why the failure index cannot serve
    # this predicate, which is its complement.
    #
    # `@run` is excluded for the same reason it is above — its own unresolved rows are {#resolve}'s
    # second list, and a row on both would be embedded twice in one pass. It is not redundant with
    # the grace floor: an ingest whose job is dequeued more than an hour after the commit would
    # otherwise find its own rows here.
    #
    # == Ordered NEWEST first, which is the opposite of the failure backlog and deliberate
    #
    # That list orders by attempts so a retried row sinks and the whole backlog round-robins. This
    # one has no attempt counter to sink by — nothing here has ever been attempted, and the two rows
    # this sweep cannot resolve are precisely the ones that will never acquire one: a row with no
    # intent and no name returns nil from {#identity_for} BEFORE the embed, so it takes no stamp, no
    # count, and no place in any ordering that could demote it.
    #
    # Oldest-first would therefore park that population permanently at the head of the list. A
    # repository carrying `RETRY_SWEEP_LIMIT` signalless rows inside the window would spend its
    # entire sweep budget on them on every ingest, forever, and no genuinely stranded row would ever
    # be reached — starvation by a set that is behaving correctly.
    #
    # Newest-first structurally cannot do that, and the structure is `Ingest::Payload#validate_name`:
    # it rejects "absent name and no intent", so a signalless row is one written before that
    # validator existed and is therefore older than every row written since. Sorting by age
    # descending puts the unresolvable population last by construction rather than by hope. It also
    # happens to be the order a rescue wants — the freshest stranding is the one whose run somebody
    # may still be looking at — but that is a bonus and not the argument.
    #
    # `id` breaks ties, and here the ties are the NORMAL case rather than a corner:
    # `Ingest::ObservationRecorder#record` writes a run's observations in a single bulk `upsert_all`,
    # so a whole run can share one `created_at` to the microsecond. Without the tiebreak the cap
    # would take an arbitrary and differently-chosen slice of that run on every ingest, and rows
    # could be passed over indefinitely while the count of them never moved. Both keys descend
    # together so the read is one backward walk of
    # `index_spec_observations_on_unattempted_embed_backlog`, which carries `id` for exactly this.
    #
    # `limit` is a parameter and not `RETRY_SWEEP_LIMIT`, because this list spends what the failure
    # backlog left — see {#retry_backlog} for why there is one budget and not two.
    def unattempted_embed_backlog(limit)
      @repository.spec_observations
                 .embed_unattempted_retryable
                 .where.not(test_run_id: @run.id)
                 .order(created_at: :desc, id: :desc)
                 .limit(limit)
    end

    # @return [Integer, nil] the identity this observation belongs to, once the row has been ADDED TO
    #   THE PAGE'S LINK BUFFER — nil when it has none to belong to.
    #
    # **The write moved to {#link_all} and the decision did not.** This used to be one
    # `update_column` per observation and therefore one round trip per example, which at the design
    # point is 20,000 of them for a suite that did not change. What it records is the same pair the
    # UPDATE carried, so the statement the page issues writes exactly what these writes wrote.
    #
    # It no longer returns a COUNT, and that is the visible half of the change: a row cannot know
    # whether its UPDATE matched until the statement has run, so the counting moved to {#link_all}
    # with the write. The contract it counts by is unchanged and is stated there — a row deleted by
    # a concurrent shard redelivery is still not counted.
    #
    # No `update!` and no validation either way: there is nothing to validate on a foreign key the
    # database already enforces.
    def claim(observation)
      identity = identity_for(observation)
      return if identity.nil?

      @links << [observation.id, identity]
      identity
    end

    # {#claim}, with the blast radius of ONE inherited row held to that row.
    #
    # == Why the two halves of the work list are not treated the same
    #
    # {#resolve} walks the repository's earlier runs before it walks `@run`'s own observations, and
    # the two lists have different standing. This run's rows are the delivery's own business and the
    # caller is entitled to see them fail: an exception there is a report about the thing that was
    # just asked for. An inherited row is work this delivery volunteered for on an earlier one's
    # behalf — best-effort by construction, under a budget it is only *entitled* to spend — and
    # letting one of them abort the whole pass inverts that entirely.
    #
    # It inverted it badly, which is the defect this method exists for. The backlog is walked FIRST,
    # so a row that raises killed the delivery before `@run`'s own list was reached at all. And a
    # deterministic failure — a stored vector of the wrong dimension, a row whose signal trips a
    # provider bug — fails identically on every attempt, so *every subsequent ingest of that
    # repository* re-read it, re-raised, and left its own observations unresolved and unstamped:
    # exactly the invisible population the never-attempted sweep was built to rescue, defeated by
    # the one row that kills the sweep. One row, one repository, forever.
    #
    # **`StandardError` and not a list**
    #
    # Deliberately broad, because the enumerable failures are already handled elsewhere and what is
    # left is by definition the one nobody enumerated. `EmbeddingGenerator::Error` never arrives
    # here — {#embed} consumes it at the single call site and returns nil, so the stamping path
    # below is reached through {#identity_for} rather than through this rescue, and SPGD-367's
    # behaviour is untouched. Everything else the class comment lists as "what a job-level policy
    # would have to cover" is what this catches: {#nearest}'s lookup and the upsert in
    # {#claim_identity}.
    #
    # What it can no longer catch is the row's own two `UPDATE`s, and that is not a narrowing of the
    # containment so much as a consequence of those writes no longer being the row's: they are the
    # page's now, issued once by {#flush_page}, and a failure in one of them is page-shaped for the
    # same reason {#digest_index}'s is. {#resolve_page} states that line rather than leaving it here.
    #
    # **It is not a promise that the delivery survives anything.** {#record_resolve_failure} is
    # itself an UPDATE, so a failure broad enough to take the connection with it raises from inside
    # this rescue and propagates exactly as before. That is the right answer rather than a gap: a
    # database that cannot be written to must not produce a delivery that reports a clean sweep. The
    # case this contains is the row-shaped one, and the row-shaped one is the one that recurs.
    #
    # @return [nil] always on the contained path — the row is not added to the page's link buffer,
    #   so it contributes nothing to {#flush_page}'s count. See {#resolve}'s `@return` for why a
    #   contained row counts as nothing rather than as an attempt.
    def claim_inherited(observation)
      claim(observation)
    rescue StandardError => e
      Rails.logger.error(
        "[IdentityResolver] run=#{@run.id} contained a failure on inherited observation " \
        "#{observation.id}: #{e.class}: #{e.message}"
      )
      record_resolve_failure(observation)
      nil
    end

    # @return [Integer, nil] the id of the identity this observation belongs to, or nil when it has
    #   none to belong to.
    def identity_for(observation)
      signal = observation.signal
      # `:none` — no intent and no name. `Ingest::Payload#validate_name` refuses that shape today,
      # so this is for rows written before it existed. There is no text to embed and therefore no
      # identity to have; the row stays unresolved, which is the honest answer rather than an
      # identity standing for nothing.
      #
      # Returns BEFORE the embed, so it leaves no failure stamp — which is exactly what keeps this
      # population separable from the one below it. A row with nothing to embed is permanently
      # unresolved and must never enter the retry backlog; a row whose attempt failed is temporarily
      # unresolved and must.
      #
      # Before {#identical_text} and {#nearest} too, which is what keeps that true now that
      # {#claim_inherited} can stamp a row for a failure anywhere on this path: there is no database
      # work on the `:none` path for it to catch. The signalless population takes no stamp, no count
      # and no place in any ordering, exactly as {#unattempted_embed_backlog} needs.
      return nil unless signal.present?

      # The cheap answer first, and only when it is certain — see {#identical_text} for why a miss
      # here proves nothing and must fall through to the embed rather than stand in for it.
      identical = identical_text(signal)
      return resight(identical, observation) if identical

      embedding = embed(signal.text)
      return record_resolve_failure(observation) if embedding.nil?

      match = nearest(embedding)
      return resight(match.id, observation) if match

      claim_identity(signal, embedding, observation)
    end

    # @return [Integer, nil] the id of the identity this repository already holds for text that is
    #   **byte-identical** to this signal's, found without embedding anything and — now — without
    #   asking the database anything either.
    #
    # **Still the per-row seam, and deliberately so.** What moved is where the answer comes from: the
    # page asked once ({#digest_index}, one `WHERE text_digest IN (…)` against the UNIQUE
    # `(repository_id, text_digest)` key {#claim_identity} already upserts onto), and this reads that
    # answer for one row. Keeping the seam here is what keeps the decision per row while the cost is
    # per page — and it is what `identity_resolver_spec.rb`'s `resolve_as_the_loser` stubs to
    # reproduce a race, which is a second reason not to dissolve it into {#identity_for}.
    #
    # == What it removes
    #
    # Every run writes its own observations with `spec_identity_id` NULL, so {#resolve}'s work list
    # is the WHOLE SUITE on every run rather than the part of it that changed. Run 2 of an unchanged
    # 20,000-example suite was therefore 20,000 embeddings and 20,000 approximate-index lookups to
    # rediscover 20,000 rows that this equality names outright.
    #
    # The embed costs no money on the shipped provider and it is not free:
    # `EmbeddingGenerator::LocalProvider` SHA-256s every word and every 3-character n-gram — roughly
    # 68 digests for a 60-character description, ~1.4M per ingest at the design point, on every
    # ingest forever. And the provider is swappable by design (`EmbeddingGenerator.provider=`), so a
    # deployment that installed `OpenAIProvider` pays 20,000 billed API calls per unchanged
    # re-ingest. It also narrows {#nearest}'s recall exposure by not reaching the index at all on
    # the identical-text case — which does not settle the measurement that method hands to SPGD-72,
    # only shrinks what rides on it.
    #
    # That removed the WORK. Removing the round trips is {#digest_index}, and it is the same
    # optimisation finished rather than a second one: the equality that answered a row for free still
    # cost a query to ask, so the best case — nothing changed — spent 20,000 sequential lookups to
    # rediscover 20,000 rows the database could name in ~40.
    #
    # == This is a SHORTCUT and never THE lookup
    #
    # **The digest is over the raw text; the embedding is over a normalized form of it.**
    # `LocalProvider` downcases, splits on `[[:alnum:]]+` and rejoins with single spaces, so
    # `"Order#checkout"` and `"Order  checkout"` embed *identically* while their SHA-256 digests
    # differ. A miss here is therefore not evidence that the test is new — it is evidence that the
    # cheap question cannot answer this one — and {#identity_for} falls through to today's path
    # completely unchanged.
    #
    # Reading this as the lookup and the embed as an insert-only fallback is the tempting shape and
    # it is wrong: it would start a second history for every test whose description gained a comma,
    # while every existing example about *moved* tests stayed green. The falsifier is the resolver
    # spec's "still matches text that differs only in punctuation and whitespace", which is exactly
    # that pair and which only similarity can resolve. **Batching does not touch that**: a digest
    # absent from the page's map is absent for the same reason it missed the per-row `find_by`, and
    # falls through to the same place.
    def identical_text(signal)
      @digest_index[SpecIdentity.digest_for(signal.text)]
    end

    # Writes the one fact that makes this row's absence of an identity mean something: **it was
    # reached, something was tried, and it did not land.**
    #
    # == What the stamp means, since it now has two writers
    #
    # It meant "the provider was asked and could not answer", which was the only failure that could
    # be recorded when SPGD-367 introduced the column. {#claim_inherited} is the second caller and
    # its failures are not the provider's, so the column is read here as the wider fact — and the
    # widening is stated rather than left for the next reader to infer from a name, because
    # `embed_failed_at` still says the narrower thing and cannot be renamed without a migration that
    # would move two audit scopes and the index under them.
    #
    # The widening is safe because of WHICH distinction the rest of this class actually leans on.
    # {#identity_for}'s `:none` early return is the one that matters, and its claim is *"a row with
    # nothing to embed is permanently unresolved and must never enter the retry backlog; a row whose
    # embed failed is temporarily unresolved and must"* — a split between **permanently** and
    # **temporarily** unresolved, not between the provider and everything else. A contained row is
    # squarely on the temporary side: a dropped connection is exactly the transient thing a bounded
    # retry is for, and a row that is genuinely hopeless leaves by the window rather than by being
    # recognised. That early return also still leaves no stamp of any kind — it returns before
    # {#identical_text}, before {#embed} and before {#nearest}, so there is nothing left on that path
    # for {#claim_inherited} to catch, and the signalless population stays exactly as separable as
    # it was.
    #
    # What it is NOT is a claim that a stamped row failed at the provider. Anything that needs that
    # distinction has the log line {#embed} and {#claim_inherited} each write; the column is the
    # queryable, retryable fact and never the diagnosis.
    #
    # == The mechanics, unchanged since SPGD-367
    #
    # `embed_failed_at` is `COALESCE`d so it holds the FIRST failure and no later one moves it. That
    # is what makes `SpecObservation::EMBED_RETRY_WINDOW` a window that closes rather than one every
    # retry pushes forward — a stamp refreshed on each attempt would keep a hopeless row retryable
    # for exactly as long as anything kept retrying it, which is forever.
    #
    # One UPDATE with the increment computed in SQL rather than read into Ruby and written back,
    # because N shards of a run schedule N jobs over the same rows: two of them reading `0` and both
    # writing `1` would lose an attempt, and the count is what orders the sweep.
    #
    # `updated_at` is deliberately not moved, following {#link_all} — resolution facts are written
    # below Active Record's timestamping precisely so they do not disturb the row's measurement
    # history, and `Ingest::ObservationRecorder::REMEASURABLE` keeps the two halves apart from the
    # other direction.
    #
    # == What bounds a poison row, and what deliberately does not
    #
    # Both columns do a job for {#claim_inherited} and neither is new machinery. The count demotes:
    # {#failed_embed_backlog} orders `(:embed_failure_count, :embed_failed_at, :id)`, so a contained
    # row sinks below every row that has been tried less and the sweep goes on round-robining the
    # rest of the backlog instead of spending itself on the one that cannot be rescued. The
    # timestamp ends it: seven days after its first containment the row leaves `.embed_retryable`
    # for `.embed_abandoned` and stops being swept at all, queryable as a thing that was given up on.
    #
    # **No failure-count exclusion is added**, and that is a decision rather than an omission.
    # `SpecObservation::EMBED_RETRY_WINDOW`'s own comment refuses an attempt CAP for this pipeline
    # and the argument transfers here without modification: `embed_failure_count` counts attempts by
    # ANYTHING, and an N-shard delivery schedules N jobs over these same rows, so a cap is spent by
    # the concurrency rather than by the retrying and the number that would survive it is a client's
    # shard count — which this application never sees. The same inflation is harmless to the
    # ordering, because concurrent sweeps bump roughly the same rows together and leave the order
    # BETWEEN them where it was. So the count ranks and the clock bounds, exactly as before.
    #
    # What that costs, stated: a contained row is re-attempted once per ingest for up to a week, at
    # one lookup and one embedding each — the same price a provider-failed row has always carried,
    # under a budget `RETRY_SWEEP_LIMIT` already caps, and demoted below everything with a better
    # claim on that budget. A row stranded UNSTAMPED and then contained also restarts its clock: its
    # seven days ran from `created_at` and now run from `embed_failed_at`. Bounded either way, and
    # anchoring the window to the first failure is what `embed_failed_at` has always meant.
    #
    # @return [nil] always — the callers are {#identity_for}, which still has no identity, and
    #   {#claim_inherited}, which returns 0 of its own.
    def record_resolve_failure(observation)
      SpecObservation.where(id: observation.id).update_all(
        ["embed_failed_at = COALESCE(embed_failed_at, ?), embed_failure_count = embed_failure_count + 1",
         Time.current]
      )

      nil
    end

    # The nearest existing identity in THIS repository, if one is close enough to be the same test.
    #
    # Repository-scoped because identity is per repository — two codebases sharing a test name share
    # nothing else, and the tenant boundary is not a thing similarity gets to cross. `threshold:` is
    # `neighbor`'s own, a cosine *distance*, so the comparison lands in SQL rather than being
    # re-derived from `neighbor_distance` here; `first` on an ordered relation is `LIMIT 1`.
    #
    # == The scope filter is applied AFTER the index scan, and under-recall here costs an identity
    #
    # An HNSW scan produces `hnsw.ef_search` candidates (default 40) from the whole table and only
    # then applies `repository_id`. Today `spec_identities` is small enough that the planner scans
    # it outright and the question does not arise. Once it is large enough across all tenants that
    # the index wins — the 20,000-per-repository design point multiplied by every repository — a
    # small tenant's true nearest neighbour can fall outside those 40 global candidates, and this
    # method returns nothing. A miss here is not a worse ranking, it is a second identity for a test
    # that already had one, and a history split in two. That is what makes it worth stating:
    # `spec_intents` carries the same shape and is only ever ranking.
    #
    # What it cannot cost is the identical-text case — a moved test, or the same test ingested by
    # two shards. {#identical_text} answers that one before this method is called at all, and
    # `(repository_id, text_digest)` catches it again in {#claim_identity} whatever this returns.
    # The exposure is exactly the near-identical band, the case the spec's "differs only in
    # punctuation and whitespace" example isolates: the bytes differ, so neither equality can see
    # it and only similarity can find the row.
    #
    # **Deliberately not mitigated here.** pgvector 0.8.0 is installed and `hnsw.iterative_scan`
    # addresses this directly, so the remedy is a one-line `SET` rather than an upgrade. It is left
    # off because of what it costs on the axis this slice is explicitly not allowed to touch:
    # iterative scan keeps descending until enough rows pass the filter or it hits
    # `hnsw.max_scan_tuples`, which makes every *miss* dramatically more expensive — and a
    # repository's first run is 20,000 consecutive misses. Choosing between that, a partitioned or
    # per-tenant index, and a raised `ef_search` is a measurement against the 20k design point, and
    # that is **SPGD-72's**, alongside the batching, caching and re-embed skipping it already owns.
    # Handed to it by name rather than guessed at here.
    def nearest(embedding)
      @repository.spec_identities
                 .nearest_neighbors(:embedding, embedding, distance: "cosine",
                                    threshold: SpecIdentity::MATCH_DISTANCE)
                 .first
    end

    # An existing test, seen again. Moves only where it was last seen — see
    # {SpecIdentity::RESIGHTABLE} for why the text and the vector are not in that set — and moves it
    # only FORWARD, which is {SpecIdentity::SIGHTING_NOT_OLDER}'s job.
    #
    # **Records the sighting rather than writing it**, because the write is the page's and not the
    # row's since this slice: {#resight_all} spends the buffer on one guarded statement for the whole
    # page. Nothing about WHICH identity this observation re-sights, or about what a re-sighting
    # moves, is decided anywhere but here.
    #
    # The guard still belongs in the statement and not around it, and now in the batched statement's
    # own `WHERE` rather than hoisted out of it — see {#resight_all}. This loop resolves rows of
    # several runs and two jobs run it concurrently, so a read-compare-write in Ruby would be
    # checking a value another job is free to move before the write lands.
    #
    # A guard that fails updates nothing and this still returns the identity — the observation is an
    # observation OF this test whether or not it is the most recent one, and the link is what
    # {#claim} records. No callbacks and no validation pass over a 1536 element vector that has not
    # changed, exactly as before.
    #
    # Takes an ID rather than a record, which is all either caller has now that {#identical_text}
    # answers out of a `pluck`ed map — and all this ever needed: {SpecIdentity::RESIGHTABLE} is the
    # whole of what a re-sighting writes and none of it is read off the row first.
    def resight(identity_id, observation)
      @sightings << [identity_id, observation]

      identity_id
    end

    # **The page's re-sightings, in one guarded `UPDATE`.** This was one statement per row — the
    # first of the two an unchanged re-ingest paid for every example it had already seen, and at the
    # 20,000-example design point 20,000 sequential round trips to write what the page already knew.
    #
    # `UPDATE … FROM (VALUES …)` and not an `IN` list, because every row carries its own values:
    # each identity takes ITS observation's path, line and run, so there is nothing to hoist into a
    # single `SET`. {SpecIdentity::RESIGHTABLE} builds both the `SET` and the tuple, so this
    # statement and {#sighting} and the conflict clause in {#claim_identity} stay one definition of
    # what a re-sighting moves rather than three.
    #
    # **The guard stays in the `WHERE`, per row.** {SpecIdentity.sighting_not_older_than_values} is
    # the same `SIGHTING_NOT_OLDER` the per-row path took, instantiated against the `VALUES` alias's
    # own `last_seen_test_run_id` — see that helper for why it has to be a class-level instantiation
    # on the model and not something built here. It compares each identity against the sighting
    # proposed for THAT identity, so hoisting it would be a different predicate and not an
    # optimisation of this one.
    #
    # One `Time.current` for the page rather than one per row, so a page's re-sightings share an
    # `updated_at`. They were microseconds apart before and are now equal; nothing reads that column
    # as an ordering key — {SpecIdentity::SIGHTING_NOT_OLDER} orders by the RUN's `(created_at, id)`
    # and never by this.
    def resight_all
      return if @sightings.empty?

      now = Time.current
      rows = newest_sighting_per_identity.map do |identity_id, observation|
        [identity_id, *sighting(observation, now).values_at(*SpecIdentity::RESIGHTABLE)]
      end
      table = SpecIdentity::SIGHTING_VALUES_ALIAS

      sql = <<~SQL.squish
        UPDATE spec_identities
        SET #{SpecIdentity::RESIGHTABLE.map { |column| "#{column} = #{table}.#{column}" }.join(', ')}
        FROM #{values_clause(rows, SpecIdentity, %i[identity_id] + SpecIdentity::RESIGHTABLE, table)}
        WHERE spec_identities.id = #{table}.identity_id
          AND #{SpecIdentity.sighting_not_older_than_values}
      SQL

      SpecIdentity.connection.exec_update(SpecIdentity.sanitize_sql_array([sql, *rows.flatten]))
    end

    # **A page may re-sight ONE identity from SEVERAL observations, and this is what settles which
    # of them lands.** Not a corner: two examples whose `full_description` is identical resolve to
    # one row (`SpecIdentity::MATCH_SIMILARITY` states why no threshold can separate them), and
    # {#retry_backlog} mixes runs by design, so a backlog page can hold this run's row and an
    # earlier one's for the same test.
    #
    # Sequential guarded `UPDATE`s settled it by executing: within one run last-writer-wins, which
    # is correct because two examples sharing a description have no order between them; across runs
    # the guard refused the older one whichever order they were walked in. A single statement has no
    # "last" — `UPDATE … FROM (VALUES …)` joined on a DUPLICATED key picks a row **arbitrarily** and
    # applies only that one — so the page has to arrive already deduplicated or the guard is asked
    # about a row nobody chose. Getting this wrong reintroduces exactly the backwards sighting
    # {SpecIdentity::SIGHTING_NOT_OLDER} exists to make structurally impossible, and it does it
    # silently.
    #
    # Newest run wins, by `(created_at, id)` — the ordering that guard is written in and the one
    # every recency question in this application is asked in. Ties inside one run go to the row
    # walked LAST, which is what the sequential path did and is arbitrary either way.
    #
    # The `group_by` size check is not an optimisation of the arithmetic, it is what keeps the
    # ordinary page free of the read below: a page whose identities are distinct — every page of a
    # suite with distinct descriptions — has nothing to settle and is returned untouched.
    def newest_sighting_per_identity
      by_identity = @sightings.group_by(&:first)
      return @sightings if by_identity.size == @sightings.size

      order = sighting_run_order
      by_identity.each_value.map do |group|
        group.each_with_index.max_by { |(_, observation), index| [order[observation.test_run_id], index] }.first
      end
    end

    # `test_run_id => (created_at, id)`, for the runs a duplicated page actually holds.
    #
    # One query and never one per row, and none at all on the case that produces most duplicates: a
    # page whose observations all belong to ONE run — a run's own page, always — has no cross-run
    # question to ask, so every key is equal and the tie-break by position is the whole answer.
    # `[0, 0]` rather than a real key because nothing may distinguish them; see
    # {#newest_sighting_per_identity} for why last-walked wins that tie.
    def sighting_run_order
      run_ids = @sightings.map { |(_, observation)| observation.test_run_id }.uniq
      return run_ids.index_with([0, 0]) if run_ids.one?

      TestRun.where(id: run_ids).pluck(:id, :created_at).to_h { |id, created_at| [id, [created_at, id]] }
    end

    # **The page's links, in one `UPDATE`, counted from the rows it MATCHED.** The second of the two
    # statements an unchanged re-ingest used to pay per row.
    #
    # `RETURNING` and not `@links.size`, and that is the whole of what keeps {#resolve}'s return
    # value meaning what it has always meant. A row can be gone by the time this runs — a concurrent
    # shard redelivery deletes and re-upserts this run's observations, so a read out of the work list
    # can be stale — and the per-row path did not count that row because its `update_column` matched
    # nothing. Nothing is lost when it happens (the redelivered row is unresolved, so the next job
    # picks it up), but the count says "observations that NOW carry an identity", and in that window
    # this one does not. A batched statement that assumed its page size would quietly start counting
    # them.
    #
    # Raw SQL rather than `upsert_all`: an upsert would need every `NOT NULL` column of the row and
    # would move `updated_at`, and this must move exactly one column and disturb nothing else —
    # resolution facts are written this way precisely so they do not touch the row's measurement
    # history, which is the rule {#record_resolve_failure} and `ObservationRecorder::REMEASURABLE`
    # keep from the other side.
    #
    # @return [Integer] how many of this page's observations now carry an identity.
    def link_all
      return 0 if @links.empty?

      sql = <<~SQL.squish
        UPDATE spec_observations SET spec_identity_id = link.spec_identity_id
        FROM #{values_clause(@links, SpecObservation, %i[id spec_identity_id], 'link')}
        WHERE spec_observations.id = link.id
        RETURNING spec_observations.id
      SQL

      SpecObservation.connection.exec_query(
        SpecObservation.sanitize_sql_array([sql, *@links.flatten])
      ).rows.size
    end

    # A `(VALUES …) AS alias (columns)` join source with a `?` per value, for the two statements
    # above to bind.
    #
    # **The first tuple's holes are CAST and the rest are bare**, which is the minimum that makes
    # the join sound rather than a flourish: Postgres takes an unadorned literal's type from the
    # first row of the `VALUES` list, so without this a `bigint` id would be compared against `text`
    # and an `integer` line number would be one too. Casting only the first row is enough to fix
    # every column's type, and casting all 500 of them would put four figures of redundant SQL on
    # the wire for the same result.
    #
    # The types come off the TARGET MODEL's own columns rather than from a list written here, so a
    # migration that widens a column cannot leave a cast behind naming what it used to be. `id` is
    # taken from the model too — {SpecIdentity}'s join key is its primary key under another name.
    def values_clause(rows, model, columns, table)
      types = columns.map { |column| model.columns_hash[column == :identity_id ? "id" : column.to_s].sql_type }
      tuples = rows.map.with_index do |row, index|
        holes = row.each_index.map { |column| index.zero? ? "CAST(? AS #{types[column]})" : "?" }
        "(#{holes.join(', ')})"
      end

      "(VALUES #{tuples.join(', ')}) AS #{table} (#{columns.join(', ')})"
    end

    # What "seen again" moves, and the only definition of it. Sliced through
    # {SpecIdentity::RESIGHTABLE} so this method and the conflict clause in {#claim_identity} are the
    # *same* list rather than two copies of it: the match path and the conflict path both end in a
    # re-sighting, and one of them quietly moving a column the other does not is exactly the drift a
    # shared constant is for. {SpecIdentity::SIGHTING_NOT_OLDER} is shared by both for the same
    # reason, one level down: it decides WHETHER these values land.
    #
    # `last_seen_test_run_id` comes off the OBSERVATION and never off `@run`, and the two are only
    # equal on the run-scoped half of the work list. A row rescued from the backlog was seen by an
    # EARLIER run, and stamping this ingest's id on it would have the identity claim it was last
    # seen in a run that never contained it. They were the same value until the sweep existed; this
    # is the seam where they stop being.
    #
    # That makes the value honest, which is not the same as making it win — a rescue of run-1 and a
    # rescue of run-2 both produce honest values for the same identity in one pass, and which of the
    # two the row keeps is the guard's decision rather than this method's.
    def sighting(observation, now)
      { file_path: observation.file_path, line_number: observation.line_number,
        last_seen_test_run_id: observation.test_run_id, updated_at: now }.slice(*SpecIdentity::RESIGHTABLE)
    end

    # A test nothing matched: insert it — or lose the race to insert it and take the winner.
    #
    # `upsert_all` rather than `create!` because the miss is exactly where two ingests collide. Every
    # shard of a repository's first run resolves for the first time, so two of them reaching the same
    # text and both finding nothing is the ordinary case and not a corner. `ON CONFLICT … DO UPDATE
    # … RETURNING id` makes both of them come away holding the same row: the winner inserts, the
    # loser's values land on the winner as an ordinary re-sighting — guarded exactly as the match
    # path's re-sighting is, see below — and neither raises. A `create!`-and-rescue would reach the
    # same place in two statements and a savepoint; this is one statement and needs neither.
    #
    # It is also what makes the *identical-text* case safe twice over. A test that merely moved
    # embeds to the same vector and is found by {#nearest}; if that lookup ever missed it — an
    # approximate index under-recalling, a threshold raised too far — this key would still land the
    # ingest on the row it belongs to rather than growing the table. The two mechanisms overlap on
    # purpose, and only similarity covers the case where the text is *not* byte-identical.
    #
    # `record_timestamps: false` because the row carries its own — {SpecIdentity::RESIGHTABLE} keeps
    # `created_at` out of the update list, so a row that already existed keeps when the test first
    # appeared and moves only its `updated_at`.
    #
    # `on_duplicate:` rather than `update_only:` so the conflict branch carries
    # {SpecIdentity::SIGHTING_NOT_OLDER} — the same guard {#resight} takes as a `WHERE`, spelled as
    # a `CASE` per column because `ON CONFLICT DO UPDATE` has nowhere else to put it. The clause is
    # still generated from `RESIGHTABLE`, so this is one list and one guard reaching both paths
    # rather than a second copy of either. See that constant for why the losing side of this race is
    # not the only way an OLDER sighting arrives here.
    #
    # == The row it just created is put back into the page's map
    #
    # {#digest_index} is asked once per page, so it is a SNAPSHOT — and the `find_by` it replaced was
    # not. That one saw identities committed by EARLIER ROWS OF THE SAME PAGE; a map computed up
    # front does not. The case is two observations with byte-identical text on a FIRST run — the pair
    # `identity_resolver_spec.rb`'s "cannot separate two tests whose descriptions are identical"
    # builds — where the second row would now miss the map and fall through to an embed.
    #
    # The OUTCOME would be unchanged either way (identical text embeds to an identical vector,
    # {#nearest} matches at cosine 1.0, and failing even that, this method's conflict key lands them
    # on one row), so this line is not what makes the change correct. What it preserves is the EMBED
    # COUNT, and that is worth a line: the embed is the expensive thing this whole path exists to
    # avoid, the provider is swappable for a billed one, and "batching the lookups made a first run
    # embed more" is a regression no example here would have caught — `:208` asserts identity count,
    # not embed count. So the page's map learns what the page wrote, and the snapshot is a snapshot
    # only of what was there BEFORE the page started.
    def claim_identity(signal, embedding, observation)
      now = Time.current
      digest = SpecIdentity.digest_for(signal.text)

      id = SpecIdentity.upsert_all(
        [{
          repository_id: @repository.id,
          text: signal.text,
          text_digest: digest,
          signal_source: signal.source.to_s,
          embedding: embedding
        }.merge(sighting(observation, now), created_at: now)],
        unique_by: %i[repository_id text_digest],
        on_duplicate: Arel.sql(SpecIdentity::RESIGHT_ON_CONFLICT),
        record_timestamps: false, returning: %w[id]
      ).rows.dig(0, 0)

      @digest_index[digest] = id
      id
    end

    # @return [Array<Float>, nil] nil when the provider failed, which leaves the observation
    #   unresolved and stamped — see {#record_resolve_failure}, which is what the nil now costs.
    #
    # Rescued rather than allowed to propagate so that one unembeddable example does not abandon the
    # other 19,999 — and rescued *here*, at the single call, so the rescue cannot accidentally swallow
    # a failure from the database work around it. `EmbeddingGenerator` promises this is the only class
    # its callers see, whatever the provider did.
    #
    # **This rescue is why a job-level retry policy would reach nothing.** The error is consumed
    # here, so `retry_on EmbeddingGenerator::Error` on {Ingest::IdentityResolutionJob} could never
    # fire and the job reports success having resolved zero rows. Stated at the call that does it,
    # rather than left for a future cycle to derive from an absence.
    #
    # Logged as well as stamped: the log line is what an operator watching a deploy sees, the stamp
    # is what survives to be queried and retried afterwards, and neither is the other.
    def embed(text)
      EmbeddingGenerator.call(text)
    rescue EmbeddingGenerator::Error => e
      Rails.logger.warn(
        "[IdentityResolver] run=#{@run.id} could not embed a spec signal: #{e.message}"
      )
      nil
    end
  end
end
