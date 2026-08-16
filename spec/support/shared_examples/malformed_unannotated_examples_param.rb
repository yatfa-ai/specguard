# frozen_string_literal: true

# The shapes a `?unannotated_examples=` query string can legally parse into that are NOT a String,
# pinned ONCE for every surface that reads the parameter.
#
# `?unannotated_examples[]=x` is an Array, `?unannotated_examples[a]=b` is an
# `ActionController::Parameters` and `?unannotated_examples[][a]=b` is an Array of them. None is a
# String, and the single guard they all land on is
# `RequestedUnannotatedExamplesParam#requested_unannotated_examples?`.
#
# Its own file rather than a widening of any sibling, and one file per parameter is the point of the
# split — the argument `malformed_spec_file_param.rb` makes for itself. Each doc comment governs ONE
# parameter on every surface, and folding a second into it would make one list stand for two questions
# that are free to be answered differently. What they share is a hazard, not a subject.
#
# ⭐ THE CONSEQUENCE IS THE MIRROR OF EVERY SIBLING'S, WHICH IS WHY THIS FILE EXISTS AT ALL RATHER
# THAN THE PARAMETER BEING "OBVIOUSLY SAFE". The others reach a `where(column: …)` where an Array
# becomes an `IN` list and silently answers a question nobody asked. This one reaches no SQL: it is a
# FLAG, tested for presence rather than compared against a column, and every one of the three shapes
# above is TRUTHY in Ruby. So an unguarded `params[:unannotated_examples].present?` does not return
# the wrong rows, it returns rows AT ALL — a capped hundred-row block, plus the query that produced
# it, opened on a query string the client never meant to send, on every request a broken serializer or
# a hand-built URL makes. A silent extra answer needs the guard exactly as much as a silent wrong one,
# and the shape of the parameter is what hides the need.
#
# A non-String is treated as no ask — the same answer an absent param gets — rather than a 400,
# because there is nothing here for a client to correct that a missing param would not equally have.
# Each surface says so in its own vocabulary, which is why the assertion is the host's:
#
#   describe "an unannotated-examples parameter that is not a string" do
#     def expect_unannotated_examples_param_treated_as_no_ask(query)
#       # make the request with `params: query` and assert 200 + the no-ask answer
#     end
#
#     it_behaves_like "a surface that treats a malformed unannotated-examples parameter as no ask"
#   end
#
# The host method is run as an ordinary example-group method, so its `let`s, its `before` hooks and
# its own fixture helpers are all in scope. It must assert the NO-ASK answer specifically, not merely
# a 200: a guard that swallowed every value would also answer 200 on all three shapes, and only the
# positive-path example next to it — the one that proves `?unannotated_examples=true` IS honoured —
# separates the two. Keep that example beside the host group. That pairing is load-bearing here in a
# way it is not for the value-carrying siblings: this parameter's no-ask answer and its "you did not
# send it" answer are the SAME `null`, so nothing inside this group can tell a working guard from an
# endpoint that ignores the parameter entirely.
RSpec.shared_examples "a surface that treats a malformed unannotated-examples parameter as no ask" do
  [
    ["an array", { unannotated_examples: ["true"] }],
    ["a nested hash", { unannotated_examples: { a: "b" } }],
    ["an array of hashes", { unannotated_examples: [{ a: "b" }] }]
  ].each do |shape, query|
    it "answers 200 rather than opening the block when unannotated_examples arrives as #{shape}" do
      expect_unannotated_examples_param_treated_as_no_ask(query)
    end
  end
end
