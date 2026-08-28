# frozen_string_literal: true

# The shapes a `?limit=` query string can carry that are NOT a widening, pinned ONCE for every
# surface that reads the parameter.
#
# Two families land on the same answer — NO ASK, the block's existing constant applies — and the
# single guard they all fall to is `RequestedLimitParam#requested_limit`:
#
# * the three malformed CONTAINER shapes: `?limit[]=x` is an Array, `?limit[a]=b` is an
#   `ActionController::Parameters` and `?limit[][a]=b` is an Array of them. None is a String, and
#   on THIS parameter the hazard is the silent WRONG SIZE: a coerced or leaked non-String answering
#   with a limit no client asked for — including no limit at all, which silently re-imposes the cap
#   the client was trying to widen past, on a URL the client did not mean to send.
# * the non-widening STRINGS: `?limit=` (a browser's unfilled form field), `?limit=abc`,
#   `?limit=1.5`, `?limit=0`, `?limit=-3`. The first is blank; the rest parse to no positive
#   integer, and `0`/`-3` are called out because a zero ask is the most tempting to treat as a
#   number rather than a no-ask: `ActiveRecord`'s `.limit(nil)` is NO limit, the opposite of what
#   a zero would be read as, and a negative one is a 500 no surface owes a client for a typo.
#
#   NOTE the boundary of this list: it is the spellings `Kernel#Integer` answers `nil` for. What
#   `Integer` DOES accept but a reader might assume falls here — a base prefix (`?limit=0xc` → 12)
#   and surrounding whitespace (`?limit= 12 ` → 12) — is a widening, not a no-ask, and is pinned
#   as a positive path beside the host group, not folded into it.
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
#   describe "a limit parameter that is not a widening" do
#     def expect_limit_param_treated_as_no_ask(query)
#       # make the request with `params: query` and assert 200 + the DEFAULT answer: the rollups'
#       # published limits equal the shipped constants and the lists are their default length
#     end
#
#     it_behaves_like "a surface that treats a non-widening limit parameter as no ask"
#   end
#
# The host method is run as an ordinary example-group method, so its `let`s and hooks are in
# scope. It must assert the NO-ASK answer specifically — the rollups back at their shipped
# constants — not merely a 200: a guard that swallowed every value into a 500 would fail that, but
# so would one that widened to some accidental default, and only the no-ask assertion tells the
# two apart. Keep the positive-path example beside the host group — the pairing is load-bearing
# for the reason `malformed_near_duplicates_param.rb` gives: the no-ask answer is the DEFAULT, so
# a broken guard and an absent parameter render the same body, and only the positive path next to
# it proves the parameter does anything at all.
RSpec.shared_examples "a surface that treats a non-widening limit parameter as no ask" do
  [
    ["an array", { limit: ["50"] }],
    ["a nested hash", { limit: { a: "b" } }],
    ["an array of hashes", { limit: [{ a: "b" }] }],
    ["a blank string", { limit: "" }],
    ["a non-integer string", { limit: "abc" }],
    ["a float string", { limit: "1.5" }],
    ["zero", { limit: "0" }],
    ["a negative integer", { limit: "-3" }]
  ].each do |shape, query|
    it "answers 200 with the default rollup size when limit arrives as #{shape}" do
      expect_limit_param_treated_as_no_ask(query)
    end
  end
end
