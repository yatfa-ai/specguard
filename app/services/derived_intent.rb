# frozen_string_literal: true

# THE READING A TEST'S OWN DESCRIPTION YIELDS, for a test nobody annotated.
#
# SpecGuard's first premise was that an unannotated example is an anonymous coordinate — a file, a
# line, and nothing that says what the test is *for*. That premise holds for a description that says
# nothing. It does not hold for the shape most suites are actually written in:
#
#   McpHandlers::AcceptFeatureCheckDebtHandler#call clearing revokes an existing acceptance
#   └──────────────── entity ────────────────┘ └action┘ └──────────── behavior ────────────┘
#
# The entity is there, the action is there, the behavior is there, and the layer is in the path. The
# platform already receives that string on every example (`name`, RSpec's `full_description`),
# already stores it (`spec_observations.name`), and already ranks other panels by it — and then
# reported the test as one it could not see. This class is what stops that being true.
#
# == It is a READING, never a substitute for an annotation
#
# `Ingest::SpecSignal` states the rule this obeys one grain down: *"the source travels with the
# text… a consumer that treats both alike would report a name-derived match with the same confidence
# as an intent-derived one."* Same here. What this returns is inferred from prose a human wrote for
# a test runner's output, not declared by an author against a schema. `SpecObservation::READINGS`
# keeps the two apart on every surface, and nothing here is written back to the `intent_*` columns —
# see `SpecObservation.reading_counts_in` for why the whole thing is a READ-TIME derivation.
#
# == What an authored `@intent` still buys, stated rather than implied
#
# * **`preconditions`** — not derivable from any description, at all. Absent from every reading here.
# * **`layer`** — derived from the directory a spec file sits in ({#layer}), which is a convention
#   guess and not a declaration. A request spec parked under `spec/models/` reads `unit` here and
#   would read `request` from its author.
# * **The behavior sentence itself** — an author writes what the test is *for*; a description is
#   what somebody wanted to read in the runner's output. They are often the same and are not the
#   same thing.
#
# == THE RULE IS DELIBERATELY NARROW, and the narrowness is the point
#
# Only the `Entity#action`/`Entity.action` prefix shape derives. Two shapes that look close are
# refused on purpose:
#
# * `"Checkout rejects an expired card"` — an entity and a behavior with no action between them.
#   Taking the behavior's first word as the action would read `when` as an action on the very common
#   `"Checkout when the card is expired returns 402"`, and a wrong action is worse than no reading:
#   it is a claim, made by the platform, in a field an author is supposed to own.
# * `"POST /api/v1/ingest rejects a malformed body"` — no entity token at all.
#
# Both stay in the unreadable population and are reported plainly as such. A derived reading that
# would not satisfy the OpenTestIntent schema is not a derived reading — it is absence.
#
# == One pattern, two engines
#
# The same population has to be counted in SQL (`SpecObservation::READING_EXPRESSION`, which groups
# and ranks tens of thousands of rows per run) and read field-by-field in Ruby (here, for one row a
# surface is rendering). Two hand-written rules would drift, and would drift *silently* — a panel
# saying "derived" over a row this class returns nothing for.
#
# So {PATTERN} is ONE unanchored source string, and each engine adds only its own anchors:
# {RUBY_PATTERN} wraps it in `\A…\z` with `MULTILINE` (Ruby's `.` skips newlines by default and its
# `^`/`$` are line anchors), {SQL_PATTERN} wraps it in `^…$` (Postgres ARE matches newline with `.`
# and anchors to the whole string by default). `spec/services/derived_intent_spec.rb` runs this
# class over one corpus and `spec/models/spec_observation_spec.rb` runs the SQL predicate over the
# same strings, asserting they agree row for row — so a divergence fails a test rather than
# mislabelling a panel.
#
# == ⚠️ THE WHOLE RULE HAS TO BE IN THAT STRING — a lesson, not a design note
#
# The first cut of this class NORMALISED before matching: `String#strip` here, `btrim(COALESCE(name,
# ''))` in `READING_EXPRESSION`. That is a second rule, written twice by hand, sitting OUTSIDE the
# one string the two engines share — and the two spellings are not the same operation. Postgres
# `btrim/2` trims spaces only; Ruby's `String#strip` also takes tab, newline, VT, FF, CR and NUL. A
# description ending in a newline was therefore `derived` in Ruby and `unreadable` in SQL, which is
# exactly the silent mislabelling the agreement example exists to catch — and the corpus, every
# string of it ASCII with clean bookends, never asked the question.
#
# Two repairs, and both are structural rather than a correction to one call:
#
# 1. The padding is INSIDE {PATTERN} (`SPACE*` at each end). There is no normalisation step left for
#    the two engines to spell differently, and {BEHAVIOR}'s non-space bookends mean the capture
#    comes out trimmed by construction rather than by a second `.strip` on this side only.
# 2. The whitespace is {WHITESPACE} — six ASCII characters, spelled — rather than `[[:space:]]`,
#    which is *itself* two rules: Ruby's is Unicode-aware on a UTF-8 string and Postgres's is not.
#
# `spec/support/derived_intent_corpus.rb` now carries the padded, tabbed and non-ASCII-space cases,
# and states what the corpus does and does not certify.
class DerivedIntent
  # A constant name: one capitalised segment of at least two characters, optionally namespaced.
  #
  # Two characters because `OpenTestIntent`'s `entity` is `minLength: 2` — encoded in the pattern
  # rather than left to the validator, because the SQL side has no validator and the two have to
  # agree. Requiring it of the FIRST segment is strictly stronger than the schema's requirement of
  # the whole string, which is the safe direction: everything this matches validates.
  ENTITY = "[A-Z][A-Za-z0-9_]+(?:::[A-Za-z0-9_]+)*"

  # A method name of at least two characters, with a trailing `?`, `!` or `=` allowed. Two for the
  # same reason `ENTITY` is two, and operator methods (`[]`, `<=>`) are deliberately not matched:
  # they are a small population and a permissive pattern here costs the whole rule its precision.
  ACTION = "[A-Za-z_][A-Za-z0-9_]+[?!=]?"

  # The whitespace BOTH engines recognise, spelled out rather than borrowed from `[[:space:]]`.
  #
  # ⚠️ SPELLED BECAUSE `[[:space:]]` IS NOT ONE RULE. Ruby's is Unicode-aware on a UTF-8 string;
  # Postgres's defers to the collation's `iswspace`, which under glibc says U+00A0 is not space. One
  # pattern string containing `[[:space:]]` would therefore still be two different rules, and a
  # description ending in a non-breaking space would be read by one engine and not the other. These
  # six are ASCII, are written as escapes Postgres ARE and Ruby both give their C meanings, and
  # depend on no locale. A non-breaking space is consequently an ORDINARY CHARACTER to both — it may
  # sit inside a behavior and may not separate an action from one, which is the same call twice
  # rather than an accident of two libraries.
  #
  # NUL is absent though `String#strip` removes it, and that costs nothing: Postgres `text` cannot
  # hold a NUL byte, so a row whose description carries one cannot exist to be disagreed about.
  WHITESPACE = "\\t\\n\\v\\f\\r "

  # The two derived classes. Everything below is written in terms of these, so the set above is the
  # single place the answer to "what counts as space here" is given.
  SPACE = "[#{WHITESPACE}]"
  NON_SPACE = "[^#{WHITESPACE}]"

  # The rest of the description, at least 15 characters, starting and ending on a non-space.
  #
  # Fifteen because `OpenTestIntent`'s `behavior` is `minLength: 15`. The non-space bookends are not
  # tidiness: they are what makes the capture trimmed BY CONSTRUCTION, so no engine needs a strip of
  # its own to get the same three fields. Without them the pattern would match a description whose
  # behavior is 15 characters of which the last three are spaces, and a reading the schema rejects
  # would be counted as one the schema accepts.
  BEHAVIOR = "#{NON_SPACE}.{13,}#{NON_SPACE}"

  # `#` or `.` — instance or singleton. The sigil is consumed and NOT kept in {#action}, because an
  # author writing this annotation by hand writes `action: call`, not `action: "#call"`, and a
  # derived reading that spelled its action differently from an authored one would make the two
  # incomparable on the one field they most obviously line up on.
  #
  # ⭐ THE PADDING IS PART OF THE RULE — `SPACE*` at each end rather than a trim in each engine. See
  # the class comment: a `.strip` here and a `btrim` there is one rule written twice, and those two
  # spellings do not agree about a tab or a newline. Here there is nothing to spell twice. The
  # capture groups are unaffected: {BEHAVIOR}'s trailing `NON_SPACE` forces the greedy `.` to give
  # back any trailing whitespace to the `SPACE*` that follows it.
  PATTERN = "#{SPACE}*(#{ENTITY})[#.](#{ACTION})#{SPACE}+(#{BEHAVIOR})#{SPACE}*"

  # Built with `Regexp.new` rather than a literal so the one source string above is the only place
  # the rule is written. `MULTILINE` makes `.` match a newline, which is what Postgres does with no
  # flag at all; `\A`/`\z` rather than `^`/`$`, which in Ruby are line anchors.
  RUBY_PATTERN = Regexp.new("\\A#{PATTERN}\\z", Regexp::MULTILINE)

  # The same rule for Postgres, whose `^`/`$` already anchor the whole string. Interpolated into
  # `SpecObservation::READING_EXPRESSION` as a literal; it contains no quote to escape, and
  # `spec/models/spec_observation_spec.rb` runs it against the database rather than trusting that.
  SQL_PATTERN = "^#{PATTERN}$"

  # Directory conventions that name an OpenTestIntent `layer`. Only the four the schema's enum
  # allows can be produced, so a derived reading always carries a layer the schema accepts.
  #
  # `features` maps to `system` because Capybara feature specs and system specs are the same layer
  # under two names — RSpec renamed the thing, and a suite predating the rename should not read as
  # a layer the schema has no word for.
  LAYERS = {
    "system" => "system",
    "features" => "system",
    "requests" => "request",
    "integration" => "integration"
  }.freeze

  # What a spec file under no recognised convention is read as. `unit` rather than nil because
  # `layer` is `required` by the schema — and because it is the honest default: the great majority
  # of a suite's files sit under `spec/models`, `spec/services` and the like.
  #
  # ⚠️ This is a GUESS, and the one field of a derived reading most likely to be wrong. It is why
  # {DerivedIntent} is a reading rather than an annotation. See the class comment.
  DEFAULT_LAYER = "unit"

  # @return [DerivedIntent, nil] the reading this description yields, or nil when it yields none.
  #   Nil is the ordinary answer for a great many real descriptions and is never an error.
  def self.from(name, spec_file_path: nil)
    # NO `.strip`, and its absence is load-bearing rather than an economy — see the class comment.
    # A normalisation here is one the SQL engine has to reproduce in a different language, and the
    # two spellings drifted. {PATTERN} absorbs the padding, so both engines are handed the raw
    # stored string and neither is free to tidy it differently.
    match = RUBY_PATTERN.match(name.to_s)
    return nil unless match

    reading = new(entity: match[1], action: match[2], behavior: match[3],
                  spec_file_path: spec_file_path)

    # The schema is asked rather than assumed. {PATTERN} is built to guarantee this passes, and the
    # guarantee is worth exactly as much as the last edit to those three constants — so the contract
    # is enforced at the one place a reading is minted rather than argued for in a comment.
    reading if reading.valid?
  end

  def initialize(entity:, action:, behavior:, spec_file_path: nil)
    @entity = entity
    @action = action
    @behavior = behavior
    @spec_file_path = spec_file_path
  end

  attr_reader :entity, :action, :behavior

  # The layer this test's LOCATION implies — a convention guess, not a declaration. See
  # {DEFAULT_LAYER}.
  #
  # The first recognised segment wins, scanned from the root, so `spec/system/admin/requests` reads
  # `system` (the outer directory is the one the suite organises by) rather than `request`.
  def layer
    @layer ||= @spec_file_path.to_s.split("/").filter_map { |segment| LAYERS[segment] }.first ||
               DEFAULT_LAYER
  end

  # This reading in the shape `OpenTestIntent` validates and an author would have written.
  #
  # No `preconditions` key: a derived reading has none and an empty array would claim the test
  # declares no preconditions, which is a different statement from "nobody said".
  def to_intent = { "entity" => entity, "action" => action, "behavior" => behavior, "layer" => layer }

  def valid? = OpenTestIntent.valid?(to_intent)
end
