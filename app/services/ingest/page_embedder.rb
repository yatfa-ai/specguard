# frozen_string_literal: true

module Ingest
  # Gets a page of vectors out of the embedding provider — through the deployment-wide
  # {EmbeddingCacheEntry} cache, with a pass-scoped circuit breaker — and hands each row its own.
  #
  # **Extracted from {Ingest::IdentityResolver}, and a move rather than a redesign** (SPGD-1765).
  # The resolver keeps every identity decision: which texts a page needs vectors for
  # ({Ingest::IdentityResolver#unheld_texts}, which reads the page's digest map), what a nil vector
  # costs a row ({Ingest::IdentityResolver#record_resolve_failure}), and where the breaker is
  # reported ({Ingest::IdentityResolver#report}). This class owns only "get a page of vectors from
  # the provider, through the cache, with a pass-scoped breaker". It touches {EmbeddingGenerator}
  # and {EmbeddingCacheEntry} and never writes {SpecIdentity} or {SpecObservation}.
  #
  # **One instance per `#resolve` pass, and that is what makes the breaker pass-scoped.** The
  # resolver constructs it in its own `initialize`, so `@provider_dark` lives exactly as long as the
  # pass that earned it and is re-earned from scratch by the next.
  #
  # Every log line keeps the `[IdentityResolver] run=<id>` prefix it had when it lived on the
  # resolver: operators grep those lines by that prefix and the resolver's specs pin the text.
  class PageEmbedder
    def initialize(run)
      @run = run
      # The page's embeddings, filled by {#page_embeddings} and total rather than conditional on a
      # page being open, so that {#embedding_for} can be asked at any time: it falls back to a
      # single embed for a text no page fetched — unless `@provider_dark` below has been tripped,
      # in which case that fallback answers nil rather than asking. See {#embedding_for}, which
      # explains where the missing key comes from and why the breaker has to be re-read there.
      @embeddings = {}
      # `@provider_dark` — this pass has watched a whole page's batch request AND every one of its
      # per-signal retries fail, which is evidence about the PROVIDER rather than about any of those
      # texts, so it asks the provider nothing more. See {#embed_page} for the trip condition and
      # what a skipped text costs, and {Ingest::IdentityResolver#report} for where a tripped pass
      # says so.
      #
      # **Pass-scoped and deliberately never process-scoped**, which is the difference between this
      # and a circuit breaker. A flag that outlived its `#resolve` would make the NEXT ingest skip a
      # provider that has since recovered — silently, with no ask to discover the recovery with and
      # nothing but a deploy to end the skipping. A per-pass flag is re-earned from scratch by every
      # pass, so the cost of being wrong about an outage is one page of requests and never a
      # deployment that has stopped embedding.
      @provider_dark = false
    end

    # @return [Boolean] whether this pass has stopped asking the provider ({#stop_asking_the_provider}).
    #   What {Ingest::IdentityResolver#report} reads to emit `provider_breaker=tripped`.
    def provider_dark? = @provider_dark

    # @return [Hash{String => Array<Float>, nil}] every vector this page's rows are going to need,
    #   fetched in ONE provider request — nil for a text the provider could not answer about.
    #
    # **The third thing this page asks once instead of per row, and — with the cache below — the
    # last of the three SPGD-72's cost clause names.** {Ingest::IdentityResolver#digest_index} made the identical-text
    # answer one query per page and {Ingest::IdentityResolver#flush_page} made the writes a fixed number of statements per
    # page; what was left was the embed, which the
    # identical-text shortcut removes for an UNCHANGED suite and does nothing for a changed one. Any
    # first run, any rename, any delivery whose text is not byte-identical to a row already held
    # still reached the provider once per example — 20,000 sequential HTTPS round trips on a changed
    # 20,000-example suite, against an endpoint that takes the whole array in one request.
    #
    # There is no provider on which that is free: `EmbeddingGenerator::VoyageProvider` is the only
    # one this application ships, and every `.call` on it is a billed request over the network.
    #
    # == The cost is per page and the DECISION is still per row
    #
    # The same division {Ingest::IdentityResolver#digest_index} and {Ingest::IdentityResolver#flush_page} made. Nothing here decides anything: it
    # collects the texts the per-row path is going to ask for and puts the answers where
    # {#embedding_for} can hand each row its own. {Ingest::IdentityResolver#identity_for} runs exactly as it did — its
    # `:none` return, its {Ingest::IdentityResolver#identical_text} shortcut, its {Ingest::IdentityResolver#nearest} lookup, its upgrade and its
    # insert — and a row whose vector is nil takes the same {Ingest::IdentityResolver#record_resolve_failure} stamp it took
    # when its own embed returned nil.
    #
    # == What is deliberately NOT in the request
    #
    # `identical_text` is asked BEFORE a text joins the list, so a byte-identical re-ingest sends
    # the provider nothing at all — the shortcut's whole point, and it would be undone by a batch
    # that embedded the page indiscriminately. The list is deduped for the same reason
    # {Ingest::IdentityResolver#digest_index}'s is: two examples carrying the same description are one text to embed, and
    # the vector is a pure function of the text.
    #
    # The snapshot is taken before the first row is claimed, so a text that a LATER row of this same
    # page will create an identity for is embedded here and its duplicate is not — {Ingest::IdentityResolver#claim_identity}
    # puts the new row into `@digest_index` and the second occurrence takes the shortcut, exactly as
    # it does today.
    #
    # == The vectors this deployment already owns are not bought again
    #
    # The last of SPGD-72's three cost levers, and the one the other two cannot reach.
    # {Ingest::IdentityResolver#identical_text} answers *"is this text on one of THIS repository's identity rows"* — that
    # is what {Ingest::IdentityResolver#digest_index} is built from — so a page of genuinely new bytes gets no help from it
    # and is billed in full. But "new to this repository" is not "new to this deployment": another
    # repository's suite contains `"validates the email format"` too, and this repository's own
    # renamed test was embedded under its old text last week. {EmbeddingCacheEntry} is keyed
    # `(provider_fingerprint, text_digest)` across every repository, so those are hits, and a page
    # that hits on all of them asks the provider nothing at all.
    #
    # **Read once, embed the remainder, write what was bought.** Three page-shaped statements where
    # there were two, and the division is the one this class has made four times now: the cost is
    # per page and the DECISION is still per row. Nothing here decides anything — a row whose vector
    # came from the cache takes precisely the path a row whose vector came from the provider takes,
    # through {#embedding_for}, {Ingest::IdentityResolver#nearest} and {Ingest::IdentityResolver#claim_identity}, and a text that missed both is a
    # nil exactly as it was.
    #
    # `texts - cached.keys` is the whole of the change to what gets asked. When the provider
    # publishes no fingerprint — which the whole test suite's provider does, and which the shipped
    # `VoyageProvider` does not — `cached` is empty, the
    # subtraction is a no-op, and this method is byte-for-byte the behaviour it had before.
    def page_embeddings(texts)
      fingerprint = cache_fingerprint
      cached = cached_embeddings(fingerprint, texts)
      fresh = embed_page(texts - cached.keys)
      store_embeddings(fingerprint, fresh)

      @embeddings = cached.merge(fresh)
    end

    # @return [Array<Float>, nil] this row's vector out of the page's request — nil when the page
    #   asked for it and the provider could not answer, which is the same nil {#embed} returned when
    #   the ask was per row, and costs the same {Ingest::IdentityResolver#record_resolve_failure} stamp.
    #
    # `fetch` with a block rather than `[]`, because the two absences are different: a text the page
    # embedded and FAILED on is present with a nil value and must stay a failure, while a text no
    # page fetched at all has no answer yet and gets a single embed. Reading a missing key as a
    # failure would strand the second case; reading a nil value as a miss would re-ask the provider
    # for a text it has just refused, once per row, which is the amplification the batch exists to
    # remove. That distinction is load-bearing on the healthy path and is unchanged.
    #
    # == Where the missing key actually comes from
    #
    # **{Ingest::IdentityResolver#upgrade_from_name}, mid-page**, and it is an ordinary path rather than an exotic one. That
    # method DELETES the name entry from `@digest_index` on both `:upgraded` and `:lost_race`, so a
    # name-only sibling later in the SAME page — an example sharing a `full_description` with the
    # test that was just annotated, which its comment names outright — stops matching
    # {Ingest::IdentityResolver#identical_text} and must claim its own row. Its text was never embedded, because
    # {Ingest::IdentityResolver#unheld_texts} correctly skipped it as held when the page was built, and {Ingest::IdentityResolver#lookup_texts} put
    # it in {Ingest::IdentityResolver#digest_index} but not in `@embeddings`. So the lookup lands here with no key.
    #
    # == Why the breaker has to be re-asked here
    #
    # {#embed_page} answers a tripped page with nil-VALUED keys and never `{}` so that no text OF
    # THAT PAGE reaches this block. That bounds the page's own set and nothing else: the key above
    # is one this page never asked for, so it arrives as a miss whatever the page did. Within a
    # single page the two states cannot meet — a dark provider gives the annotated row a nil and
    # {Ingest::IdentityResolver#identity_for} returns at its `embedding.nil?` guard before any upgrade — but the breaker is
    # sited at the provider ask and NOT at {#page_embeddings}, which reads {EmbeddingCacheEntry}
    # first. A later page whose vectors this deployment already owns therefore resolves normally
    # right through an outage, upgrades, evicts the name, and drops its sibling here with the pass
    # long since dark. Unguarded, that is one provider request per such row, invisible: no page-level
    # warn line covers it and {Ingest::IdentityResolver#report} still says `provider_breaker=tripped`.
    #
    # The nil is the fully-handled answer and not a new outcome — {Ingest::IdentityResolver#identity_for} stamps through
    # {Ingest::IdentityResolver#record_resolve_failure} and the row stays retryable for the whole window, byte-identical to
    # every other text this pass skipped.
    def embedding_for(text)
      @embeddings.fetch(text) { @provider_dark ? nil : embed(text) }
    end

    private

    # @return [String, nil] the current provider's cache key, or nil for "do not cache".
    #
    # Asked once per PAGE rather than once per cache call, so that the read and the write of one
    # page cannot disagree about which provider they are talking about — and per page rather than
    # per process, because `EmbeddingGenerator.fingerprint` is required to be recomputed on every
    # call and memoizing it here would reintroduce exactly the staleness that contract exists to
    # prevent.
    #
    # Rescued because it runs provider code: `VoyageProvider.fingerprint` reads the environment
    # today and a future provider might read a config file or a socket. Whatever it does, a
    # provider that cannot say what it is must cost this ingest nothing more than the caching it
    # declines to authorise. Nil is the same answer as "no fingerprint published", and the caller
    # already treats that as "no caching".
    def cache_fingerprint
      EmbeddingGenerator.fingerprint
    rescue StandardError => e
      Rails.logger.warn(
        "[IdentityResolver] run=#{@run.id} could not read the embedding provider fingerprint: " \
        "#{e.message}; embedding this page without the cache"
      )
      nil
    end

    # @return [Hash{String => Array<Float>}] the subset of this page's texts this deployment has
    #   already embedded under `fingerprint` — one query, an `IN` list on the unique key.
    #
    # == The rescue is WIDE in class and NARROW in scope, and both halves are deliberate
    #
    # {#page_embeddings} is the one exception inside {Ingest::IdentityResolver#resolve_page}'s containment, and `:499-505`
    # argues exactly why it is allowed to be: `EmbeddingGenerator::Error` is attributable to known
    # texts that {#embed_page} re-asks one at a time, so each failure lands back on the row that
    # contributed it. **A cache failure is not that**, and this rescue must not be read as widening
    # that licence. It is a different claim on a different statement.
    #
    # *Wide in class* because the failures are not the provider's: an unrun migration is
    # `ActiveRecord::StatementInvalid`, a saturated pool is `ActiveRecord::ConnectionTimeoutError`,
    # a dropped socket is lower still. Rescuing `EmbeddingGenerator::Error` here would catch none of
    # them and a deployment that had not yet run the migration would fail every ingest — the cache
    # would have become load-bearing, which is the one thing a cache must never be. Every one of
    # those has the same correct answer, and it is not an incident: ask the provider, as this class
    # did before the table existed.
    #
    # *Narrow in scope* because it wraps this call and nothing else. The provider request, the
    # per-row decisions, {Ingest::IdentityResolver#nearest}, {Ingest::IdentityResolver#claim_identity} and {Ingest::IdentityResolver#flush_page} are all outside it and
    # every one of them fails exactly as loudly as it did before. What {#page_embeddings} is
    # permitted to swallow is unchanged: this adds a rescue AROUND A NEW STATEMENT, it does not
    # loosen the existing one.
    #
    # Logged at `warn` and not `error`: the ingest is correct and merely more expensive, which is
    # the same register {#embed_page}'s fallback line uses for the same reason.
    def cached_embeddings(fingerprint, texts)
      return {} if fingerprint.blank? || texts.empty?

      EmbeddingCacheEntry.vectors_for(fingerprint, texts)
    rescue StandardError => e
      Rails.logger.warn(
        "[IdentityResolver] run=#{@run.id} could not read #{texts.size} cached embeddings: " \
        "#{e.message}; asking the provider for the whole page"
      )
      {}
    end

    # Remember what this page just paid for — one statement, on the way out.
    #
    # Both of {#embed_page}'s paths land here, which is why the write is at this seam and not
    # inside it: the batch path and the one-at-a-time fallback return the same shape, and the
    # fallback's per-text nils are dropped by {EmbeddingCacheEntry.store} rather than remembered as
    # answers. A text the provider refused must be re-asked next time, not permanently cached as a
    # failure.
    #
    # Rescued on the same terms as the read, and with more at stake in getting it right: a write is
    # the half that can meet a unique-key conflict, a read-only replica or a full disk, and none of
    # those is a reason to fail an ingest whose rows are already resolved. The page's vectors are in
    # hand and the resolve continues with them; the only thing lost is that the next page pays again.
    #
    # **It commits on its own, and that is a property worth keeping.** {Ingest::IdentityResolver#resolve_page} holds no
    # transaction — this class runs in a job precisely so that it is out of the ingest's, and
    # {Ingest::IdentityResolver#claim_identity} commits per row — so this `upsert_all` is its own statement and its own
    # transaction. Two consequences, both wanted: a page that dies later at {Ingest::IdentityResolver#nearest} or
    # {Ingest::IdentityResolver#flush_page} still keeps the vectors it paid for, which is exactly the behaviour a cache
    # should have on a failed pass; and the row locks the upsert takes are released at the end of
    # the statement rather than held for the length of a page, so the concurrent shards of a first
    # run — the case where two ingests upsert the SAME digest at the same moment — queue for
    # microseconds instead of for each other's whole page. Wrapping the page in a transaction later
    # would quietly reverse both.
    def store_embeddings(fingerprint, fresh)
      return if fingerprint.blank? || fresh.empty?

      EmbeddingCacheEntry.store(fingerprint, fresh)
    rescue StandardError => e
      Rails.logger.warn(
        "[IdentityResolver] run=#{@run.id} could not cache #{fresh.size} fresh embeddings: " \
        "#{e.message}; this page's vectors will be bought again"
      )
      nil
    end

    # @return [Hash{String => Array<Float>, nil}] text => vector, empty when there is nothing to
    #   embed — which is the ordinary case, so it costs no call rather than an empty one. Every text
    #   is a KEY of the result whenever there was one to ask about, including on the paths that asked
    #   nothing: see the nil-versus-omitted section below, which is the one thing a caller here can
    #   get wrong.
    #
    # **The fallback is what keeps SPGD-367 true through a batch.** One unembeddable example must
    # not abandon the other 19,999, and a batch fails as a batch: `EmbeddingGenerator.embed_many`
    # raises for the whole page and cannot say which input was refused, because one bad text and a
    # dropped connection arrive identically. Nilling the whole page on that error would stamp 20,000
    # rows for one bad one — the exact regression the per-row rescue in {#embed} exists to prevent —
    # so the page falls back to asking one text at a time, and each text then fails, or does not, on
    # its own. That path is today's path unchanged, warning line and per-row nil included.
    #
    # == What the fallback costs, and the breaker that bounds it
    #
    # One wasted request on a page that fails, plus a request per text behind it — **once per PAGE,
    # and that is the part the previous revision of this comment got wrong.** It said a provider that
    # is simply down "pays it once and then behaves exactly as it does now"; it paid it once per
    # page, every page, and a full page of single-text requests each time. At {Ingest::IdentityResolver::BATCH_SIZE} = 500 a
    # first or fully-changed run at the roadmap's 20,000-example design point is 40 pages, so a
    # provider that was simply down cost 40 batch + 20,000 single requests, 20,040 `warn` lines,
    # 20,000 {Ingest::IdentityResolver#record_resolve_failure} `UPDATE`s — and zero identities. Under `VoyageProvider`, where
    # every `.call` is a serial HTTPS round trip, that is hours of a three-thread pool spent inside a
    # job holding a six-hour run-scoped semaphore, with every other shard's job queued behind it.
    # {Ingest::IdentityResolver::RETRY_SWEEP_LIMIT} bounds how much failure a delivery INHERITS; nothing bounded how much one
    # pass CREATES.
    #
    # So a page whose batch failed AND whose every per-text retry also failed, over **at least two
    # texts**, trips `@provider_dark` and the rest of the pass asks the provider nothing
    # ({#stop_asking_the_provider}). The trip condition is the fallback's own justification read
    # carefully: *"one bad text and a dropped connection arrive identically"* is true OF ONE TEXT and
    # is not true of a page. Both halves of the rule follow from that and neither is a tuning knob:
    #
    # * **Zero successes**, because one poison text among successes is evidence about that text and
    #   about nothing else — which is what keeps *"contains a failed page to the row that caused
    #   it"* green, and an over-trip there would undo SPGD-367 wholesale rather than bound anything.
    # * **At least two texts**, because a one-text page is precisely the case the two readings cannot
    #   be told apart in. It pays its ask and says nothing about the provider. Two texts each
    #   individually unembeddable is already unlikely and 500 of them is not a thing that happens; a
    #   provider being down is.
    #
    # The bound is **~501 requests where it was 20,040**, and the observable row state is identical:
    # a skipped text is stamped by {Ingest::IdentityResolver#record_resolve_failure} exactly as a refused one is and stays
    # retryable for {SpecObservation::EMBED_RETRY_WINDOW} through the cross-run sweep. Identical
    # rather than merely similar, because abandonment is TIME-based and not attempt-count-based
    # (`SpecObservation.embed_abandoned`) — `embed_failure_count` only orders the sweep's fairness —
    # so a row stamped without a fresh ask has no lifecycle side effect at all. It is also the honest
    # record: the page's batch request did carry that text.
    #
    # == A skipped text is present with a NIL VALUE and is never OMITTED
    #
    # The whole of what the tripped return has to get right, and it is not obvious from here.
    # {#embedding_for} treats the two absences differently: a MISSING KEY means "no page fetched
    # this", while a PRESENT NIL means "asked and refused" and stays a failure. So returning `{}` on
    # the tripped path — or omitting the skipped texts from it — would send every skipped row through
    # that block rather than leaving it holding this page's own answer.
    #
    # **That block is now breakered too, and this rule is still the one that matters.** SPGD-478
    # added the same `@provider_dark` check inside {#embedding_for}, for a missing key this method
    # cannot reach — {Ingest::IdentityResolver#upgrade_from_name}'s mid-page invalidation, which produces a key no page ever
    # asked for — so a tripped `{}` would today be caught one layer down rather than costing 20,000
    # requests. It is a second line and not a replacement: the per-signal FALLBACK below reaches that
    # same block with the breaker NOT tripped (a batch that failed while at least one retry succeeded
    # leaves nil values and no trip), and omitting those texts would re-ask the provider for a text
    # it has just refused, once per row. Nil-valued and never omitted is what keeps both true.
    #
    # `zip` is where the interface's ORDER CONTRACT is consumed: `texts[i]`'s vector is
    # `vectors[i]`, and `embed_many` guarantees both the order and the count (a short array is an
    # `Error` there rather than a nil here, which would attach every later vector to the wrong
    # text). Rescuing `EmbeddingGenerator::Error` and nothing wider, for the reason {#embed} gives:
    # a broader rescue at a page-level call could swallow a failure that is not the provider's.
    def embed_page(texts)
      return {} if texts.empty?
      return texts.to_h { |text| [text, nil] } if @provider_dark

      texts.zip(EmbeddingGenerator.embed_many(texts)).to_h
    rescue EmbeddingGenerator::Error => e
      Rails.logger.warn(
        "[IdentityResolver] run=#{@run.id} could not embed a page of #{texts.size} spec signals " \
        "in one request: #{e.message}; falling back to one request per signal"
      )
      embedded = texts.to_h { |text| [text, embed(text)] }
      stop_asking_the_provider(texts.size) if texts.size > 1 && embedded.values.none?
      embedded
    end

    # Trip the pass-scoped breaker: for the remainder of this `#resolve`, {#embed_page} asks the
    # provider nothing and answers every text with the nil a refusal would have produced.
    #
    # Said once and at `warn`, in the register {#embed}'s per-row line uses and for the same reason:
    # nothing here is broken on this side of the wire, and the rows this pass stops asking for are
    # stamped and retryable exactly as refused rows are. This is the line that makes the skipping
    # visible at the moment it starts, where the provider's own message still is; {Ingest::IdentityResolver#report} carries
    # the same fact to the end of the pass, where the totals are. Neither is the other, on the same
    # rule {#embed} states for its log line and its stamp.
    #
    # `asked` is the width of the page that earned the trip rather than a total, because that is the
    # evidence: this many separate per-signal requests were made and this many came back refused.
    def stop_asking_the_provider(asked)
      @provider_dark = true

      Rails.logger.warn(
        "[IdentityResolver] run=#{@run.id} stopped asking the embedding provider: a page's batch " \
        "request and all #{asked} of its per-signal retries failed, which is evidence about the " \
        "provider and not about those signals; the rest of this pass is stamped without a request " \
        "and stays retryable"
      )
    end

    # @return [Array<Float>, nil] nil when the provider failed, which leaves the observation
    #   unresolved and stamped — see {Ingest::IdentityResolver#record_resolve_failure}, which is what the nil now costs.
    #
    # Rescued rather than allowed to propagate so that one unembeddable example does not abandon the
    # other 19,999 — and rescued *here*, around the provider call and nothing else, so the rescue
    # cannot accidentally swallow a failure from the database work around it. `EmbeddingGenerator`
    # promises this is the only class its callers see, whatever the provider did.
    #
    # **The ONE-TEXT path, and it is no longer the ordinary one.** A page asks for its texts
    # together ({#embed_page}) and this is what each of them falls back to: once per text when the
    # batch request failed, and once for a text no page fetched — that second arm only while the pass
    # is not dark, because {#embedding_for} answers such a text nil instead of reaching here once
    # `@provider_dark` is set. It is unchanged in what it does, and
    # it is deliberately still the thing containment is expressed in — the batch has no way to say
    # WHICH input a failed request was refused for, and this does, one text at a time.
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
