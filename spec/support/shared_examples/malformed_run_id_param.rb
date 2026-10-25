# frozen_string_literal: true

# The shapes a `?run=` query string can legally parse into that are NOT a run id, pinned ONCE for
# every surface that reads the parameter (SPGD-1928).
#
# All of them land on the single guard, `RequestedRunIdParam#requested_run_id`, as NO ASK — the
# same answer an absent parameter gets:
#
# * the three malformed CONTAINER shapes: `?run[]=5` is an Array, `?run[a]=b` is an
#   `ActionController::Parameters` and `?run[][a]=b` is an Array of them. None is a String, and on
#   THIS parameter the read side is a scoped `find_by(id: …)`, where a coerced container is either
#   a raise (a 500 on a URL anyone can type) or a wrong-row answer under a page claiming to have
#   honoured the ask.
# * a String carrying a NUL (`?run=5%006`) — the shape the String half alone lets through, refused
#   before any query for the same uniform reason every sibling concern refuses it.
# * the non-id STRINGS: `?run=` (a browser's unfilled form field), `?run=abc`,
#   `?run=1.5`, `?run=0`, `?run=-3`. An id is a non-negative decimal literal and nothing else:
#   `?run=0` is called out because zero is digits and the most tempting to treat as a number
#   rather than a no-ask, and it parses to an id no row can carry.
# * `?run=99999999999999999999` — a digits-only string LONGER than the `bigint` primary key can
#   hold. `Kernel#Integer` parses it fine and the bind then raises `RangeError`, a 500; the guard
#   bounds it to no ask, which is the only answer a value the column could never hold has.
#
#   NOTE the boundary of this list, as `malformed_limit_param.rb` draws it: these are the shapes
#   the guard refuses. A digits-only string INSIDE the bigint range that matches no row (`?run=42`
#   on a repository with no run 42) is a well-formed ask that MISSES — a different fact, answered
#   by the fallback notice rather than treated as no ask, and pinned beside the host group, not
#   folded into it.
#
# Its own file rather than a widening of `malformed_commit_sha_param.rb`, and one file per
# parameter is the point of the split, on the reasoning that file states in full: its list is the
# answer to "which shapes does `?commit_sha=` tolerate", and folding a second parameter into it
# would make one list stand for two questions that are free to be answered differently. The two
# disagree on purpose: a sha may be any length or spelling the reporter used, while an id is
# digits-only — so a shape list shared between them would be wrong for at least one.
#
# The host method is run as an ordinary example-group method, so its `let`s, its `before` hooks
# and its own fixture helpers are all in scope. It must assert the NO-ASK answer specifically, not
# merely a 200: a guard that swallowed every value would also answer 200 on all of these shapes,
# and only the positive-path example next to it — the one that proves `?run=<id>` IS honoured —
# separates "the guard rejects non-ids" from "the parameter does nothing". On this surface the
# no-ask answer has the same second half the sha ask's malformed family asserts: no anchor notice,
# because a page that fell back without an ask must not claim one was made.
RSpec.shared_examples "a surface that treats a malformed run-id parameter as no ask" do
  [
    ["an array", { run: ["5"] }],
    ["a nested hash", { run: { a: "b" } }],
    ["an array of hashes", { run: [{ a: "b" }] }],
    ["a string carrying a NUL", { run: "5\u00006" }],
    ["a blank string", { run: "" }],
    ["a non-integer string", { run: "abc" }],
    ["a float string", { run: "1.5" }],
    ["a sha-shaped string", { run: "0nesha00cafe0001" }],
    ["zero", { run: "0" }],
    ["a negative integer", { run: "-3" }],
    ["a positive sign", { run: "+5" }],
    ["an integer beyond the bigint ceiling", { run: "99999999999999999999" }]
  ].each do |shape, query|
    # @intent: { entity: "RequestedRunIdParam", action: "treat non-id run shapes as no ask", behavior: "a run parameter in a container shape, carrying a NUL, non-numeric, zero, signed or beyond the bigint ceiling answers 200 anchored to the newest run with no anchor notice rather than 500 or a wrong-row answer", layer: "request" }
    it "answers 200 with the newest-run fallback when run arrives as #{shape}" do
      expect_run_param_treated_as_no_ask(query)
    end
  end
end
