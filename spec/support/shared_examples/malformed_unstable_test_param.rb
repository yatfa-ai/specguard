# frozen_string_literal: true

# The shapes an `?unstable_test=` query string can legally parse into that are NOT a test
# description, pinned ONCE for every surface that reads the parameter.
#
# `?unstable_test[]=x` is an Array, `?unstable_test[a]=b` is an `ActionController::Parameters` and
# `?unstable_test[][a]=b` is an Array of them. None is a String, and the single guard they all land
# on is `RequestedUnstableTestParam#requested_unstable_test`.
#
# Its own file rather than a widening of `malformed_repeated_description_param.rb`, and one file per
# parameter is the point of the split. Each one's doc comment governs *one parameter on every
# surface* — its list is the answer to "which shapes does `?unstable_test=` tolerate", and folding a
# second parameter into it would make one list stand for two questions that are free to be answered
# differently. That the two parameters are both read as a `spec_observations.name` makes the
# temptation sharper here than anywhere else on the endpoint and changes nothing: one selects a run's
# rows and one selects a window's, and they are free to diverge.
#
# The consequence is the SILENT one rather than the loud one, exactly as it is for
# `?repeated_description=` and `?spec_file=` and unlike `?branch=`, whose `where(branch: [...])`
# raises. This parameter reaches `where(name: …)` on a plain text column, where an Array does not
# raise at all: it becomes an `IN` list, and the rows come back interleaved into ONE run-ordered
# sequence under a `name` restating one description. That is the worst of the five to catch by eye,
# because two tests' outcomes shuffled together look exactly like the alternation the block exists to
# show — a test that always passes merged with a test that always fails is a perfect picture of
# flakiness that nothing in the suite is doing, and the reader's next move is to hunt nondeterminism
# that was manufactured by a bracket in a URL.
#
# A non-String is treated as no ask — the same answer an absent param gets — rather than a 400,
# because there is nothing here for a client to correct that a missing param would not equally have.
# Each surface says so in its own vocabulary, which is why the assertion is the host's:
#
#   describe "an unstable-test parameter that is not a description" do
#     def expect_unstable_test_param_treated_as_no_ask(query)
#       # make the request with `params: query` and assert 200 + the no-ask answer
#     end
#
#     it_behaves_like "a surface that treats a malformed unstable-test parameter as no ask"
#   end
#
# The host method is run as an ordinary example-group method, so its `let`s, its `before` hooks and
# its own fixture helpers are all in scope. It must assert the NO-ASK answer specifically, not merely
# a 200: a guard that swallowed every value would also answer 200 on all three shapes, and only the
# positive-path example next to it — the one that proves `?unstable_test=<name>` IS honoured —
# separates the two. Keep that example beside the host group.
RSpec.shared_examples "a surface that treats a malformed unstable-test parameter as no ask" do
  [
    ["an array", { unstable_test: ["Invoice finalize locks the line items"] }],
    ["a nested hash", { unstable_test: { a: "b" } }],
    ["an array of hashes", { unstable_test: [{ a: "b" }] }]
  ].each do |shape, query|
    # @intent: { entity: "RequestedUnstableTestParam", action: "treat non-string unstable_test as no ask", behavior: "an unstable_test parameter in a non-String shape answers 200 with the unfiltered answer rather than 500, matching an absent parameter", layer: "request" }
    it "answers 200 rather than 500 when unstable_test arrives as #{shape}" do
      expect_unstable_test_param_treated_as_no_ask(query)
    end
  end
end
