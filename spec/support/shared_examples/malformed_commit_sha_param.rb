# frozen_string_literal: true

# The shapes a `?commit_sha=` query string can legally parse into that are NOT a commit sha, pinned
# ONCE for every surface that reads the parameter.
#
# `?commit_sha[]=x` is an Array, `?commit_sha[a]=b` is an `ActionController::Parameters` and
# `?commit_sha[][a]=b` is an Array of them. None is a String, and the single guard they all land on
# is `RequestedCommitShaParam#requested_commit_sha`.
#
# Its own file rather than a widening of `malformed_spec_file_param.rb`, and one file per parameter
# is the point of the split, on the reasoning that file states in full: its list is the answer to
# "which shapes does `?spec_file=` tolerate", and folding a second parameter into it would make one
# list stand for two questions that are free to be answered differently. What they share is a hazard,
# not a subject.
#
# THE CONSEQUENCE IS THE WIDEST OF THE SIX, and it is why a shape that merely "works" is not enough
# here. `?branch[]=main` reaches a `where(branch: [...])` that RAISES — a 500, loud. `?spec_file[]=x`
# reaches a plain string column where an Array does not raise: it becomes an `IN` list and answers a
# question nobody asked, under a caption naming one file. This parameter reaches the same silent
# `IN` list, but at the position that CHOOSES THE RUN rather than at one that opens a panel of it —
# so the wrong answer is not one block's, it is the response's. Every rollup, every drill-in and both
# growth windows would describe whichever of several unrelated commits sorted newest, under a
# `run_anchor` naming the sha the client asked for. The malformed ask would be the most convincing
# wrong answer the endpoint can give.
#
# A non-String is treated as no ask — the same answer an absent param gets — rather than a 400,
# because there is nothing here for a client to correct that a missing param would not equally have.
# Each surface says so in its own vocabulary, which is why the assertion is the host's:
#
#   describe "a commit-sha parameter that is not a sha" do
#     def expect_commit_sha_param_treated_as_no_ask(query)
#       # make the request with `params: query` and assert 200 + the no-ask answer
#     end
#
#     it_behaves_like "a surface that treats a malformed commit-sha parameter as no ask"
#   end
#
# The host method is run as an ordinary example-group method, so its `let`s, its `before` hooks and
# its own fixture helpers are all in scope. It must assert the NO-ASK answer specifically, not merely
# a 200: a guard that swallowed every value would also answer 200 on all three shapes, and only the
# positive-path example next to it — the one that proves `?commit_sha=<sha>` IS honoured — separates
# the two. Keep that example beside the host group.
#
# On this endpoint the no-ask answer has a second half worth asserting beyond the anchor itself:
# `run_anchor.source` must read `"default"` and `requested_commit_sha` must be `null`. A guard that
# dropped the ask but left the disclosure claiming one would be a response asserting it had honoured
# a request it ignored — which is the failure the block exists to prevent, arriving through the door
# the block was added by.
RSpec.shared_examples "a surface that treats a malformed commit-sha parameter as no ask" do
  [
    ["an array", { commit_sha: %w[a1b2c3d4e5f6] }],
    ["a nested hash", { commit_sha: { a: "b" } }],
    ["an array of hashes", { commit_sha: [{ a: "b" }] }]
  ].each do |shape, query|
    it "answers 200 rather than 500 when commit_sha arrives as #{shape}" do
      expect_commit_sha_param_treated_as_no_ask(query)
    end
  end
end
