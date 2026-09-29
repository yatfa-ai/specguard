# frozen_string_literal: true

# The shapes a `?near=` query string can legally parse into that are NOT a String, plus the one
# String shape no store can hold — pinned ONCE for every surface that reads the parameter.
#
# `?near[]=x` is an Array, `?near[a]=b` is an `ActionController::Parameters` and
# `?near[][a]=b` is an Array of them. None is a String, and the single guard they all land on is
# `RequestedNearParam#requested_near`.
#
# Its own file rather than a widening of `malformed_near_duplicates_param.rb`, and one file
# per parameter is the point of the split — each doc comment governs ONE parameter, and folding a
# second into the flag sibling's would make one list stand for two questions that are free to be
# answered differently. THIS parameter is not the flag's kind and not a narrowed-read sibling's:
# its value is free prose the client supplies, and the block behind it is PRICED — a billed
# provider embed per novel probe — which is why its list carries the NUL shape beside the
# non-String ones, on `malformed_branch_param.rb`'s precedent.
#
# ⭐ THE CONSEQUENCE IS THE SIBLINGS', AT THIS PARAMETER'S MEASURED COST — and the cost is the
# PAID one. `?near=` is the only parameter on the overview whose ask triggers an embedding: a
# billed provider round trip per novel probe and a live ANN read. So the hazard is not a wrong
# answer and not merely an extra block: an unguarded `params[:near].present?` would EMBED a query
# string the client did not mean to send, on every request a broken serializer makes. The flag
# sibling's same three shapes cost one stored-row read; these cost money. A value-carrying
# parameter needs the non-String guard more than the flag does, not less.
#
# The NUL shape rides this list rather than the host spec, on `malformed_branch_param.rb`'s
# precedent: a String carrying `"\u0000"` parses, answers `.presence`, and can never match —
# Postgres cannot hold a NUL in a text value — so SPGD-1470's doctrine treats it as no ask, the
# same answer the non-String shapes get. `?near=` reaches a digest and a cache key rather than a
# `WHERE`, which makes the unstoreable value worse, not better: a digest of text no row could
# ever hold is a wrong answer with a cache row behind it.
#
# A non-String is treated as no ask — the same answer an absent param gets — rather than a 400,
# because there is nothing here for a client to correct that omitting the parameter would not
# equally have. The assertion is the host's, in its own vocabulary:
#
#   describe "a near parameter that is not a probe phrase" do
#     def expect_near_param_treated_as_no_ask(query)
#       # make the request with `params: query` and assert 200 + the no-ask answer (the key
#       # present and null, zero queries and zero embeds)
#     end
#
#     it_behaves_like "a surface that treats a malformed near parameter as no ask"
#   end
#
# The host method is run as an ordinary example-group method, so its `let`s and hooks are in
# scope. It must assert the NO-ASK answer specifically, not merely a 200: a guard that swallowed
# every value would also answer 200 on all four shapes, and only the positive-path example next
# to it separates the two. Keep that example beside the host group — the pairing is load-bearing
# for exactly the reason the census sibling's comment gives: this parameter's no-ask answer and
# its "you did not send it" answer are the SAME `null`.
RSpec.shared_examples "a surface that treats a malformed near parameter as no ask" do
  [
    ["an array", { near: ["a probe phrase"] }],
    ["a nested hash", { near: { a: "b" } }],
    ["an array of hashes", { near: [{ a: "b" }] }],
    ["a string carrying a NUL", { near: "an expired card\u0000" }]
  ].each do |shape, query|
    # @intent: { entity: "RequestedNearParam", action: "treat malformed near as no ask", behavior: "a near parameter in a non-String shape or carrying a NUL answers 200 without embedding anything, matching an absent parameter", layer: "request" }
    it "answers 200 rather than embedding anything when near arrives as #{shape}" do
      expect_near_param_treated_as_no_ask(query)
    end
  end
end
