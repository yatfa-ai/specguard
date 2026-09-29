# frozen_string_literal: true

# `?near=` read as a BEHAVIOR PHRASE — the probe text the `near` block ranks the repository's
# stored identities against — or `nil` for "no ask". The guard is the free-text siblings' —
# `is_a?(String)`, the NUL cut, `.presence` — because the shapes it refuses are the same shapes
# they refuse; what is NEW is what an admitted ask buys. `?branch=` names a branch the
# repository has and `?spec_file=` a path the run wrote; `?q=` is already free prose but reads
# rows; `?near=` is the family's first PRICED ask — its value is embedded, once per novel
# phrase, on a billed provider, and ranked through a live ANN read. That price is why the
# malformed shapes matter more here than anywhere a narrowed read is behind them, and it is the
# whole content of this module beyond the two lines every free-text sibling shares.
#
# The whole `Requested*Param` family exists so that a third reader includes the guard instead of
# writing another copy of it; this parameter extends that bargain rather than re-arguing it.
#
# == The guard is the free-text siblings', in the same two lines and the same order
#
# `is_a?(String)` FIRST: `?near[]=x` parses to an Array, `?near[a]=b` to
# `ActionController::Parameters` and `?near[][a]=b` to an Array of them — all three truthy in
# Ruby, and on THIS parameter the hazard is the PAID one: an unguarded
# `params[:near].present?` would embed a query string the client did not mean to send on every
# request a broken serializer makes — a billed provider call and an ANN read, where the flag
# sibling's same shape costs one stored-row read. Anything that is not a String is treated as no
# ask — the same answer an absent param gets, so the response is byte-for-byte what it was before
# the parameter existed: the block key present and `null`, no validation branch, no 400. There is
# nothing for a client to correct that omitting the parameter would not equally have.
#
# THE NUL GUARD IS MANDATORY, on SPGD-1470's ruling made at each of the seven free-text params
# before this one: a String carrying `"\u0000"` (`?near=card%00`) parses, answers `.presence`,
# and can never match — Postgres cannot hold a NUL in a text value, and the doctrine here is
# no-ask rather than 400 for exactly the reason the sibling params state it. The probe never
# reaches a `WHERE` in this read, but it does reach `SpecIdentity.digest_for` and a cache key
# built on it, and a digest of an unstoreable value is a wrong answer with a cache row behind it;
# the shape is cut off at the door like every free-text sibling's.
#
# `.presence` SECOND, so `?near=` — a browser's unfilled form field, a client building a query
# string off a nil variable — is not an ask. An ask has to carry a phrase rather than merely be
# present in the URL. (An ask that carries BLANK-ISH text after that — a lone space — is still an
# ask: it is a String with content, and what it embeds to is the embedder's business, not the
# guard's. The census's own convention for "the client sent a word" applies unchanged.)
#
# Memoized with `defined?` rather than `||=` on the family's reasoning made sharper by the cost:
# `||=` re-reads the params on every call whenever the memo is FALSY, and the falsy answer — no
# ask — is the only one a client that never sends the parameter can get, which is precisely the
# client the paid cost exists to protect.
module RequestedNearParam
  extend ActiveSupport::Concern

  private

  def requested_near
    return @requested_near if defined?(@requested_near)

    raw = params[:near]
    @requested_near = raw.is_a?(String) && !raw.include?("\u0000") ? raw.presence : nil
  end
end
