# frozen_string_literal: true

# The shapes a `?repeated_description=` query string can legally parse into that are NOT a test
# description, pinned ONCE for every surface that reads the parameter.
#
# `?repeated_description[]=x` is an Array, `?repeated_description[a]=b` is an
# `ActionController::Parameters` and `?repeated_description[][a]=b` is an Array of them. None is a
# String, and the single guard they all land on is
# `RequestedRepeatedDescriptionParam#requested_repeated_description`.
#
# Its own file rather than a widening of `malformed_spec_file_param.rb`, and that is the point of
# all three files. Each one's doc comment governs *one parameter on every surface* — its list is the
# answer to "which shapes does `?repeated_description=` tolerate", and folding a second parameter
# into it would make one list stand for two questions that are free to be answered differently. What
# they share is a hazard, not a subject.
#
# The consequence is the SILENT one rather than the loud one, exactly as it is for `?spec_file=` and
# unlike `?branch=`, whose `where(branch: [...])` raises. This parameter reaches `where(name: …)` on
# a plain text column, where an Array does not raise at all: it becomes an `IN` list and lists the
# examples of SEVERAL descriptions under a caption and an empty state that both name one. A silent
# wrong answer needs the guard more than a crash does, not less — and at this grain the wrong answer
# is particularly hard to catch by eye, because a list of examples carrying two different
# descriptions looks exactly like the repetition the panel exists to show.
#
# A non-String is treated as no ask — the same answer an absent param gets — rather than a 400,
# because there is nothing here for a client to correct that a missing param would not equally have.
# Each surface says so in its own vocabulary, which is why the assertion is the host's:
#
#   describe "a repeated-description parameter that is not a description" do
#     def expect_repeated_description_param_treated_as_no_ask(query)
#       # make the request with `params: query` and assert 200 + the no-ask answer
#     end
#
#     it_behaves_like "a surface that treats a malformed repeated-description parameter as no ask"
#   end
#
# The host method is run as an ordinary example-group method, so its `let`s, its `before` hooks and
# its own fixture helpers are all in scope. It must assert the NO-ASK answer specifically, not merely
# a 200: a guard that swallowed every value would also answer 200 on all three shapes, and only the
# positive-path example next to it — the one that proves `?repeated_description=<name>` IS honoured —
# separates the two. Keep that example beside the host group.
RSpec.shared_examples "a surface that treats a malformed repeated-description parameter as no ask" do
  [
    ["an array", { repeated_description: ["shared across a loop"] }],
    ["a nested hash", { repeated_description: { a: "b" } }],
    ["an array of hashes", { repeated_description: [{ a: "b" }] }]
  ].each do |shape, query|
    it "answers 200 rather than 500 when repeated_description arrives as #{shape}" do
      expect_repeated_description_param_treated_as_no_ask(query)
    end
  end
end
