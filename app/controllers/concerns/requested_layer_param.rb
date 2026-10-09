# frozen_string_literal: true

# `?layer=` read as one of the five declared-layer keys — `unit`, `integration`, `request`,
# `system` or `undeclared` — or `nil` for "no ask". It narrows THREE blocks, each to the examples that
# declared that layer (or, for `undeclared`, declared none): the run-grain `slowest_examples` ranking on
# `GET /api/v1/repository`, the window-grain `slowest_tests` ranking (candidate step) and the window-grain
# `unstable_tests` ranking (candidate step: the tests that FAILED in an example of that layer — SPGD-1755),
# with their "Slowest tests" / "Tests whose outcome changed" panels on repositories#show.
#
# Deliberately its own module rather than a widening of any sibling `Requested*Param`: one module per
# parameter is the point of the split, the argument `RequestedSpecFileParam` makes for itself. What
# they share is the hazard, and the guard for it is the same lines in the same order.
#
# `is_a?(String)` FIRST: `?layer[]=request` parses to an Array and `?layer[a]=b` to
# `ActionController::Parameters`, neither of which is a layer, and an unguarded `.presence` on them is
# a 500 on an authenticated GET. A String carrying a NUL is the shape the String half alone lets
# through (`?layer=%00`); it names no layer either. `.presence` THEN, so `?layer=` — a select
# submitted at its default — is not an ask.
#
# THEN THE VOCABULARY CLAMP, on `RequestedRoleParam`'s reasoning: the vocabulary is closed
# (`SpecObservation::DECLARED_LAYER_KEYS`, the same list every per-layer aggregate is keyed by), so
# `?layer=bogus` is a stale bookmark or a typo and answers with the ordinary response. NEVER a 400 or
# a 404, and the body is the one the unasked request gets. The clamp also means the value that
# reaches `SpecObservation.declared_layer_predicate` is always a known key — nothing is spliced into
# SQL from the query string.
module RequestedLayerParam
  extend ActiveSupport::Concern

  private

  # Memoized with `defined?` rather than `||=`, because `nil` — no ask — is the common answer.
  def requested_layer
    return @requested_layer if defined?(@requested_layer)

    raw = params[:layer]
    ask = raw.presence if raw.is_a?(String) && !raw.include?("\u0000")
    @requested_layer = SpecObservation::DECLARED_LAYER_KEYS.map(&:to_s).include?(ask) ? ask : nil
  end
end
