# frozen_string_literal: true

# The shapes a `?branch=` query string can legally parse into that are NOT a branch name, pinned
# ONCE for every surface that reads the parameter.
#
# `?branch[]=main` is an Array, `?branch[a]=b` is an `ActionController::Parameters` and
# `?branch[][a]=b` is an Array of them. None is a String, and an unguarded `.presence` on any of
# them reaches a `where` that raises — a 500 on a URL anyone can type into the bar. The single guard
# they all land on is `RequestedBranchParam#requested_branch`.
#
# One list rather than one per surface, and that is the point of the file. Both surfaces read the
# same guard through the same module, so a shape either surface tolerates is a shape BOTH tolerate;
# two hand-written lists had already drifted (the human page pinned two of these three, the API all
# three) with no behavioural difference to justify the gap. Adding a shape here adds it everywhere,
# which is the property that stops the drift returning.
#
# A non-String is treated as no ask — the same answer an absent param gets — rather than a 400,
# because there is nothing here for a client to correct that a missing param would not equally
# have. Each surface says so in its own vocabulary, which is why the assertion is the host's:
#
#   describe "a branch parameter that is not a branch name" do
#     def expect_branch_param_treated_as_no_ask(query)
#       # make the request with `params: query` and assert 200 + the unfiltered answer
#     end
#
#     it_behaves_like "a surface that treats a malformed branch parameter as no ask"
#   end
#
# The host method is run as an ordinary example-group method, so its `let`s, its `before` hooks and
# its own fixture helpers are all in scope. It must assert the UNFILTERED answer specifically, not
# merely a 200: a guard that swallowed the parameter entirely would also answer 200, and only the
# positive-path example next to it — the one that proves `?branch=main` IS honoured — separates the
# two. Keep that example beside the host group.
RSpec.shared_examples "a surface that treats a malformed branch parameter as no ask" do
  [
    ["an array", { branch: ["main"] }],
    ["a nested hash", { branch: { a: "b" } }],
    ["an array of hashes", { branch: [{ a: "b" }] }]
  ].each do |shape, query|
    it "answers 200 rather than 500 when branch arrives as #{shape}" do
      expect_branch_param_treated_as_no_ask(query)
    end
  end
end
