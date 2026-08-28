# frozen_string_literal: true

# Every SpecGuard component consumes the caller's class with a MUTATING
# `@options.delete(:class)`, memoised so the read happens exactly once. See the convention note on
# `ApplicationComponent#merge_classes` for why the memoisation is load-bearing at all 19 sites while
# the `delete` is load-bearing at only the eight that splat the remaining options onto an element.
#
# This pins both halves of that construct at once, so the 19 sites need one example group rather
# than 19 hand-written pairs:
#
#   it_behaves_like "a component that appends the caller's class",
#                   base: "space-y-1", build: ->(opts) { described_class.new(**opts) }
#
# Options:
#   build:   required. A lambda taking an options hash — either the caller's class key or empty —
#            and returning a FRESH component instance with the rest of its required arguments
#            filled in. Run via `instance_exec`, so `described_class` and the host group's `let`s
#            are in scope. It must build a NEW instance per call: these examples deliberately
#            exercise the same instance twice and would otherwise share consumed state.
#   base:    required. One class the component always writes onto its root element. A literal, and
#            never the constant the component itself reads — an assertion sourced from the subject
#            passes however the subject changes.
#   method:  the class-computing method. Defaults to `:wrapper_class`.
#   key:     the caller's slot in the constructor. Defaults to `:class`.
#   content: block content to render with. Several components render nothing without it.
RSpec.shared_examples "a component that appends the caller's class" do |options|
  build = options.fetch(:build)
  base = options.fetch(:base)
  method = options.fetch(:method, :wrapper_class)
  key = options.fetch(:key, :class)
  body = options.fetch(:content, "probe content")

  # Deliberately not a real Tailwind utility and deliberately unique: the render example counts its
  # occurrences in the raw markup, so it must not collide with anything the component, a nested
  # component, or the probe content emits on its own.
  probe = "spg-probe-caller-class"

  describe "the caller's #{key}" do
    def root_element_of(markup) = Nokogiri::HTML5.fragment(markup).element_children.first

    # The idempotence half. `delete` empties the caller's slot on the first read, so an unmemoised
    # method returns "<base> <probe>" and then "<base>" — the caller's class vanishes on the second
    # call, with nothing raised and nothing logged. Asserting only that the FIRST call contains the
    # probe would pass against the mutating form; comparing the second to the first is the point.
    # @intent: { entity: "ApplicationComponent", action: "read caller class twice", behavior: "the caller's class survives a second call to the class-computing method unchanged instead of vanishing after the mutating options delete", layer: "unit" }
    it "survives a second call to ##{method}" do
      component = instance_exec({ key => probe }, &build)

      first = component.public_send(method)
      second = component.public_send(method)

      expect(first.split).to include(base, probe)
      expect(second).to eq(first)
    end

    # The consume-once half, taken through the RENDER, because that is the only place this failure
    # shows. Two distinct regressions are covered, and `delete` -> `[]` trips one or the other at
    # the EIGHT sites that splat the remaining options onto the same element:
    #
    #   * a component that splats into `tag.attributes(html_options)` emits a SECOND `class`
    #     attribute on one element. Nokogiri keeps only the first, so the duplicate is counted on
    #     the RAW string — a parsed-DOM assertion cannot see it at all.
    #   * a component that splats `**@options` into the same tag lets the surviving `:class`
    #     override the earlier `class:` key outright (last key wins in a kwargs splat), silently
    #     dropping `base`. That one is caught by the root-element assertion.
    #
    # At the other eleven sites `@options` never reaches an element, so `delete` -> `[]` changes no
    # output and this example CANNOT go red for it — verified, not assumed: the mutation leaves the
    # render suite green at all eleven. That is a property of those components, not a gap in this
    # assertion; there is no duplicate attribute and no displaced class to observe. What this
    # example still pins at all 19 is that the caller's class lands on the root element, once,
    # without displacing `base`. See `ApplicationComponent#merge_classes` for the split.
    # @intent: { entity: "ApplicationComponent", action: "render with caller class", behavior: "the caller's class lands on the root element exactly once, as a single class attribute, without displacing the component's own base classes", layer: "integration" }
    it "lands on the root element exactly once, without displacing the component's own classes" do
      render_inline(instance_exec({ key => probe }, &build)) { body }

      expect(root_element_of(rendered_content)[:class].to_s.split).to include(base, probe)
      expect(rendered_content.scan(probe).size).to eq(1)
    end

    # @intent: { entity: "ApplicationComponent", action: "render without caller class", behavior: "rendering with an empty caller's-class slot leaves the component's own classes on the root element and emits no caller-class remnant anywhere", layer: "integration" }
    it "leaves the component's own classes intact when the caller passes none" do
      render_inline(instance_exec({}, &build)) { body }

      expect(root_element_of(rendered_content)[:class].to_s.split).to include(base)
      expect(rendered_content).not_to include(probe)
    end
  end
end
