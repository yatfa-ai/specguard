# frozen_string_literal: true

# The shapes a `?sort=` query string can carry that name no ordering, pinned ONCE for every
# surface that reads the parameter.
#
# Two families land on the same answer — NO ASK, the default `github_full_name` order — and the
# single guard they all fall to is `RequestedSortParam#requested_sort`:
#
# * the three malformed CONTAINER shapes: `?sort[]=x` is an Array, `?sort[a]=b` is an
#   `ActionController::Parameters` and `?sort[][a]=b` is an Array of them. None is a String.
# * the non-String SPELLINGS that parse and still name nothing: `?sort=` (a select submitted at
#   its default), `?sort=name` and `?sort=newest` (out-of-vocabulary strings — the first names
#   the DEFAULT, which nil already means; see `RequestedSortParam` for why admitting it would
#   invite a third word). The vocabulary clamp reads all of them as no ask, which is why they
#   live HERE beside the containers: "reads as no ask" is one behavior.
#
# Its own file rather than a widening of any sibling `malformed_*_param.rb`, and one file per
# parameter is the point of the split — each doc comment governs ONE parameter, and folding a
# second into a sibling's would make one list stand for two questions that are free to be answered
# differently.
#
# A non-ask is treated as the same answer an absent param gets — rather than a 400 — because there
# is nothing here for a client to correct that a missing param would not equally have. The
# assertion is the host's, in its own vocabulary:
#
#   describe "a sort parameter that names no ordering" do
#     def expect_sort_param_treated_as_no_ask(query)
#       # make the request with `params: query` and assert 200 + the DEFAULT answer: the cards in
#       # github_full_name order
#     end
#
#     it_behaves_like "a surface that treats a non-stale sort parameter as no ask"
#   end
#
# The host method is run as an ordinary example-group method, so its `let`s, hooks and fixture
# helpers are all in scope. It must assert the NO-ASK answer specifically — the default order, a
# claim about SEQUENCE and not merely presence — not merely a 200: a guard that swallowed every
# value would also answer 200 on every shape here, and only the positive-path example beside the
# host group — the one that proves `?sort=stale` IS honoured — separates the two. Keep that
# example beside the host group.
RSpec.shared_examples "a surface that treats a non-stale sort parameter as no ask" do
  [
    ["an array", { sort: ["stale"] }],
    ["a nested hash", { sort: { a: "b" } }],
    ["an array of hashes", { sort: [{ a: "b" }] }],
    ["a blank string", { sort: "" }],
    ["an out-of-vocabulary string that names the default", { sort: "name" }],
    ["an out-of-vocabulary string that names no ordering the page offers", { sort: "newest" }]
  ].each do |shape, query|
    # @intent: { entity: "RequestedSortParam", action: "treat non-vocabulary sort as no ask", behavior: "a sort parameter that names no ordering answers 200 with the cards in default name order rather than 500 or a silently different sequence, matching an absent parameter", layer: "request" }
    it "answers 200 with the default order when sort arrives as #{shape}" do
      expect_sort_param_treated_as_no_ask(query)
    end
  end
end
