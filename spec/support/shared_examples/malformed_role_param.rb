# frozen_string_literal: true

# The shapes a `?role=` query string can carry that name no ownership state, pinned ONCE for every
# surface that reads the parameter.
#
# Two families land on the same answer — NO ASK, the whole population — and the single guard they
# all fall to is `RequestedRoleParam#requested_role`:
#
# * the three malformed CONTAINER shapes: `?role[]=x` is an Array, `?role[a]=b` is an
#   `ActionController::Parameters` and `?role[][a]=b` is an Array of them. None is a String, and
#   the hazard is the SILENT one — a coerced shape reaching a `where` would answer with a
#   population nobody asked for, under a control showing no ask, on a URL anyone can type.
# * the non-String SPELLINGS that parse and still name nothing: `?role=` (a select submitted at
#   its default), `?role=owner` and `?role=everything` (out-of-vocabulary strings — the first a
#   plausible typo of `owned`, the second a wish). The vocabulary clamp reads all of them as no
#   ask, which is why they live HERE beside the containers and not in a second family: "reads as
#   no ask" is one behavior, and `malformed_limit_param.rb` already established that a parameter
#   whose guard rejects string spellings pins those spellings in the same list as the containers.
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
#   describe "a role parameter that names no ownership state" do
#     def expect_role_param_treated_as_no_ask(query)
#       # make the request with `params: query` and assert 200 + the DEFAULT answer: every
#       # repository the viewer can open, owned and shared alike
#     end
#
#     it_behaves_like "a surface that treats a non-owned-or-shared role parameter as no ask"
#   end
#
# The host method is run as an ordinary example-group method, so its `let`s, hooks and fixture
# helpers are all in scope. It must assert the NO-ASK answer specifically — both populations
# rendered — not merely a 200: a guard that swallowed every value would also answer 200 on every
# shape here, and only the positive-path example beside the host group — the one that proves
# `?role=owned` and `?role=shared` ARE honoured — separates the two. Keep that example beside the
# host group.
RSpec.shared_examples "a surface that treats a non-owned-or-shared role parameter as no ask" do
  [
    ["an array", { role: ["owned"] }],
    ["a nested hash", { role: { a: "b" } }],
    ["an array of hashes", { role: [{ a: "b" }] }],
    ["a blank string", { role: "" }],
    ["an out-of-vocabulary string that is a plausible typo", { role: "owner" }],
    ["an out-of-vocabulary string that is none of the states", { role: "everything" }]
  ].each do |shape, query|
    # @intent: { entity: "RequestedRoleParam", action: "treat non-vocabulary role as no ask", behavior: "a role parameter that names no ownership state answers 200 with the whole accessible population rather than 500 or a silently coerced filter, matching an absent parameter", layer: "request" }
    it "answers 200 with the whole population when role arrives as #{shape}" do
      expect_role_param_treated_as_no_ask(query)
    end
  end
end
