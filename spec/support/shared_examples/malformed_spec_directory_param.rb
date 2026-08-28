# frozen_string_literal: true

# The shapes a `?spec_directory=` query string can legally parse into that are NOT a spec directory
# path, pinned ONCE for every surface that reads the parameter.
#
# `?spec_directory[]=x` is an Array, `?spec_directory[a]=b` is an `ActionController::Parameters` and
# `?spec_directory[][a]=b` is an Array of them. None is a String, and the single guard they all land
# on is `RequestedSpecDirectoryParam#requested_spec_directory`.
#
# Its own file rather than a widening of `malformed_spec_file_param.rb` or `malformed_branch_param.rb`,
# and one file per parameter is the point of the split. Each one's doc comment governs *one parameter
# on every surface* — its list is the answer to "which shapes does `?spec_directory=` tolerate", and
# folding a second parameter into it would make one list stand for two questions that are free to be
# answered differently. What they share is a hazard, not a subject.
#
# The consequence here is the spec-file parameter's rather than the branch parameter's, and it is
# why a shape that merely "works" is not enough. `?branch[]=main` reaches a `where(branch: [...])`
# that RAISES — a 500, loud. This parameter reaches an EQUALITY comparison against
# `SpecObservation::DIRECTORY_EXPRESSION`, where an Array does not raise at all: it becomes an `IN`
# list and answers a question nobody asked, under a caption naming one directory. A silent wrong
# answer needs the guard more than a crash does, not less.
#
# A non-String is treated as no ask — the same answer an absent param gets — rather than a 400,
# because there is nothing here for a client to correct that a missing param would not equally
# have. Each surface says so in its own vocabulary, which is why the assertion is the host's:
#
#   describe "a spec-directory parameter that is not a path" do
#     def expect_spec_directory_param_treated_as_no_ask(query)
#       # make the request with `params: query` and assert 200 + the no-ask answer
#     end
#
#     it_behaves_like "a surface that treats a malformed spec-directory parameter as no ask"
#   end
#
# The host method is run as an ordinary example-group method, so its `let`s, its `before` hooks and
# its own fixture helpers are all in scope. It must assert the NO-ASK answer specifically, not
# merely a 200: a guard that swallowed every value would also answer 200 on all three shapes, and
# only the positive-path example next to it — the one that proves `?spec_directory=<path>` IS
# honoured — separates the two. Keep that example beside the host group.
RSpec.shared_examples "a surface that treats a malformed spec-directory parameter as no ask" do
  [
    ["an array", { spec_directory: ["spec/models"] }],
    ["a nested hash", { spec_directory: { a: "b" } }],
    ["an array of hashes", { spec_directory: [{ a: "b" }] }]
  ].each do |shape, query|
    # @intent: { entity: "RequestedSpecDirectoryParam", action: "treat non-string spec_directory as no ask", behavior: "a spec_directory parameter in a non-String shape answers 200 with the unscoped answer rather than 500, matching an absent parameter", layer: "request" }
    it "answers 200 rather than 500 when spec_directory arrives as #{shape}" do
      expect_spec_directory_param_treated_as_no_ask(query)
    end
  end
end
