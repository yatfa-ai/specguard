# frozen_string_literal: true

# The shapes a `?near_duplicates=` query string can legally parse into that are NOT a String,
# pinned ONCE for every surface that reads the parameter.
#
# `?near_duplicates[]=x` is an Array, `?near_duplicates[a]=b` is an
# `ActionController::Parameters` and `?near_duplicates[][a]=b` is an Array of them. None is a
# String, and the single guard they all land on is `RequestedNearDuplicatesParam#requested_near_duplicates?`.
#
# Its own file rather than a widening of `malformed_unannotated_examples_param.rb`, and one file
# per parameter is the point of the split — each doc comment governs ONE parameter, and folding a
# second into the flag sibling's would make one list stand for two questions that are free to be
# answered differently.
#
# ⭐ THE CONSEQUENCE IS THE SIBLING FLAG'S, AT THIS ENDPOINT'S MEASURED COST. This parameter
# reaches SQL only through `NearDuplicateClusters.for`, whose own class comment carries the
# measured cost — seven queries at every size, linear, seconds at three thousand identities. So
# the hazard is not a wrong answer and not merely an extra HUNDRED-ROW block: an unguarded
# `params[:near_duplicates].present?` would run the whole suite-wide duplicate census, on every
# request a broken serializer makes, on a query string the client did not mean to send. A flag
# whose ask is this expensive needs the non-String guard exactly as much as the value-carrying
# siblings need theirs, and the shape of the parameter is what hides the need.
#
# A non-String is treated as no ask — the same answer an absent param gets — rather than a 400,
# because there is nothing here for a client to correct that a missing param would not equally
# have. The assertion is the host's, in its own vocabulary:
#
#   describe "a near-duplicates parameter that is not a string" do
#     def expect_near_duplicates_param_treated_as_no_ask(query)
#       # make the request with `params: query` and assert 200 + the no-ask answer (the key
#       # present and null), and — on this parameter — that the census ran no query
#     end
#
#     it_behaves_like "a surface that treats a malformed near-duplicates parameter as no ask"
#   end
#
# The host method is run as an ordinary example-group method, so its `let`s and hooks are in
# scope. It must assert the NO-ASK answer specifically, not merely a 200: a guard that swallowed
# every value would also answer 200 on all three shapes, and only the positive-path example next
# to it separates the two. Keep that example beside the host group — the pairing is load-bearing
# for exactly the reason the unannotated sibling's comment gives: this parameter's no-ask answer
# and its "you did not send it" answer are the SAME `null`.
RSpec.shared_examples "a surface that treats a malformed near-duplicates parameter as no ask" do
  [
    ["an array", { near_duplicates: ["true"] }],
    ["a nested hash", { near_duplicates: { a: "b" } }],
    ["an array of hashes", { near_duplicates: [{ a: "b" }] }]
  ].each do |shape, query|
    # @intent: { entity: "RequestedNearDuplicatesParam", action: "treat non-string near_duplicates as no ask", behavior: "a near_duplicates parameter in a non-String shape answers 200 without running the duplication census rather than 500, matching an absent parameter", layer: "request" }
    it "answers 200 rather than running the census when near_duplicates arrives as #{shape}" do
      expect_near_duplicates_param_treated_as_no_ask(query)
    end
  end
end
