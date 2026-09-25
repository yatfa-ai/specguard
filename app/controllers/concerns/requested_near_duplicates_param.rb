# frozen_string_literal: true

# `?near_duplicates=` read as a REQUEST FOR THE BLOCK — the predicate answers `false` when there
# is no ask. NOT a boolean cast of the value: `?near_duplicates=false` opens the block like any
# other non-blank string, on the same reasoning `RequestedUnannotatedExamplesParam` gives for the
# first flag-style parameter this endpoint took — and this one restates rather than re-argues it.
# The shared hazard is the whole reason these are separate modules rather than one widening
# `Requested*Param`: each parameter means one thing and one guard answers one, and folding two
# into a module would make "which shapes does each tolerate" a single question nobody asked.
#
# == ⭐ THE COST THIS FLAG STANDS IN FRONT OF, and why there is no second spelling of the ask
#
# The block this opens is the suite-wide near-duplicate census — which, since SPGD-1474, is
# computed once per write that moves its inputs (at ingest, and on run deletion) and served STORED.
# The flag was born in front of a measured, minutes-scale
# cost: `NearDuplicateClusters` is linear in the suite, seven queries at every size, tens of seconds
# extrapolated at the 20,000-identity design point — "not an object to hang off a synchronous page
# view at that size", in its own class comment's words. SPGD-1474 moved that computation off the
# request path — the ingest path (`Ingest::NearDuplicateCensusJob`, after identity resolution) and
# the run-deletion path (`RunsController#destroy`) both request the recompute — and the stored
# artifact
# it now opens costs one row read — so what this parameter still stands in front of is the
# CONTRACT, not the milliseconds: the opt-in ask is unchanged wire behaviour, the no-ask path still
# opens no block and reads no census row, and the zero-query assertion in this block's request spec
# pins both directions (no ask: nothing; ask: the stored row, and not one `spec_identities` query —
# the computation never touches the request path any more).
#
# There is nothing for the parameter to CARRY, for the same reason `?unannotated_examples=` has
# nothing: it opens a POPULATION rather than a pick. The clustering is the repository's and there
# is exactly one stored census to serve — the census contract is parameterless from the consumer's
# side (threshold, limit and the weighed run are the server's own constants and defaults), which is
# what makes one stored artifact serve every consumer — so there is no key to restate and no value
# to compare. The predicate spelling here, `requested_near_duplicates?` rather than a
# `requested_*` reader, says "at all" at every call site the way its sibling's does.
#
# **THE VALUE IS NOT READ, AND THAT INCLUDES `false`.** `?near_duplicates=false` opens the block,
# exactly as `?near_duplicates=true` and `?near_duplicates=x` do, because what is being tested is
# that the client NAMED the parameter. A truthiness vocabulary — `"true"` and `"1"` in, everything
# else out — would be a third line of guard no flag sibling has, and would spell "I sent a word
# you do not recognise" and "I sent a shape that is not a String" the same way. A client that does
# not want the block omits the parameter; there is no "off" value and never will be.
#
# `is_a?(String)` FIRST: `?near_duplicates[]=x` parses to an Array, `?near_duplicates[a]=b` to
# `ActionController::Parameters` and `?near_duplicates[][a]=b` to an Array of them. All three are
# TRUTHY in Ruby, and on this parameter the hazard is the SILENT EXTRA ANSWER: an unguarded
# `params[:near_duplicates].present?` would open a block on a query string the client did not mean
# to send, on every request a broken serializer makes. That block is a stored-row read since
# SPGD-1474 rather than the minutes-scale census it guarded at birth, and the guard stays anyway —
# the answer to a shape the client did not mean to send is the same no-answer it has always been,
# whatever the block behind it costs. Anything that is not a String is treated as no ask — the same
# answer an absent param gets, so the response is exactly what it was before the parameter existed.
# All three shapes are pinned in `spec/support/shared_examples/malformed_near_duplicates_param.rb`.
#
# `.presence` SECOND, so `?near_duplicates=` — a browser's unfilled form field, a client building
# a query string off a nil variable — does not buy the census either. An ask has to be affirmative
# rather than merely present in the URL.
#
# No validation branch and no 400: there is no value to correct. No 404 on the empty answer: a
# repository whose every test reads differently is the SUCCESS state, and `NearDuplicateClusters`
# serves an honest empty ranking for it — with the figures that say it is a finding rather than a
# silence riding along.
module RequestedNearDuplicatesParam
  extend ActiveSupport::Concern

  private

  # Memoized with `defined?` rather than `||=`, on the sibling's reasoning made sharper by the
  # cost above: `||=` re-reads the params on every call whenever the memo is FALSY, and here the
  # falsy answer — no ask — is the only one a client that never sends the parameter can get, which
  # is precisely the client the measured cost exists to protect.
  def requested_near_duplicates?
    return @requested_near_duplicates if defined?(@requested_near_duplicates)

    raw = params[:near_duplicates]
    @requested_near_duplicates = raw.is_a?(String) && raw.present?
  end
end
