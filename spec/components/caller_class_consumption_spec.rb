# frozen_string_literal: true

require "rails_helper"

# One place where every component consuming a caller-supplied class is enumerated.
#
# The construct under test is `@x ||= merge_classes(..., @options.delete(:class))` — a MUTATING
# read, memoised so it happens exactly once. It is easy to get wrong in two opposite directions
# (drop the memoisation and a second call loses the caller's class; drop the `delete` and the class
# is either emitted twice or overrides the component's own), and neither failure raises. See
# `ApplicationComponent#merge_classes` for the convention and
# `spec/support/shared_examples/caller_class.rb` for what each example asserts.
#
# `base:` is one class the component always writes onto its root element, given as a LITERAL. It is
# not read from the component's own constants: an expectation sourced from the subject moves
# whenever the subject does and pins nothing.
RSpec.describe "caller-supplied component classes" do
  # `Forms::FormBuilder#submit_button` matches the same grep and is deliberately absent from the
  # registry below: it deletes from a LOCAL `options` hash, freshly bound on every call, so there
  # is no instance state to memoise and no second call to be idempotent across.
  exempt = ["app/components/forms/form_builder.rb"].freeze

  registry = [
    { klass: UI::AlertComponent, base: "rounded-md",
      build: ->(opts) { UI::AlertComponent.new(**opts) } },

    { klass: UI::BadgeComponent, base: "rounded-full", method: :badge_class,
      build: ->(opts) { UI::BadgeComponent.new(**opts) } },

    { klass: UI::BreadcrumbComponent, base: "text-app-content-secondary",
      build: ->(opts) { UI::BreadcrumbComponent.new(items: [{ label: "Repositories" }], **opts) } },

    { klass: UI::ButtonComponent, base: "bg-app-cta", method: :button_class,
      build: ->(opts) { UI::ButtonComponent.new(variant: :primary, **opts) } },

    # `link_to` MERGES its kwargs where `tag.button`/`tag.div` do not, so for the two components
    # that branch on `href:` the splat regression only reproduces on one of the two branches. Both
    # are enumerated rather than trusting whichever one happens to be the default.
    { klass: UI::ButtonComponent, base: "bg-app-cta", method: :button_class, suffix: "with an href",
      build: ->(opts) { UI::ButtonComponent.new(href: "/repositories", **opts) } },

    { klass: UI::CardComponent, base: "bg-app-surface-raised",
      build: ->(opts) { UI::CardComponent.new(**opts) } },

    { klass: UI::CardComponent, base: "hover:border-app-cta", suffix: "with an href",
      build: ->(opts) { UI::CardComponent.new(href: "/repositories", **opts) } },

    { klass: UI::CopyableCodeComponent, base: "items-center",
      build: ->(opts) { UI::CopyableCodeComponent.new(**opts) } },

    { klass: UI::DefListComponent, base: "divide-y",
      build: ->(opts) { UI::DefListComponent.new(rows: [%w[Suite RSpec]], **opts) } },

    { klass: UI::DropdownComponent, base: "inline-block",
      build: ->(opts) { UI::DropdownComponent.new(label: "Actions", **opts) } },

    { klass: UI::EmptyStateComponent, base: "border-dashed",
      build: ->(opts) { UI::EmptyStateComponent.new(title: "No repositories yet", **opts) } },

    { klass: UI::HeadingComponent, base: "text-app-h2", method: :heading_class,
      build: ->(opts) { UI::HeadingComponent.new(level: 2, **opts) } },

    { klass: UI::MeterComponent, base: "space-y-1",
      build: ->(opts) { UI::MeterComponent.new(value: 1, max: 2, **opts) } },

    { klass: UI::PageComponent, base: "px-6",
      build: ->(opts) { UI::PageComponent.new(**opts) } },

    { klass: UI::PageHeaderComponent, base: "flex-wrap",
      build: ->(opts) { UI::PageHeaderComponent.new(title: "Repositories", **opts) } },

    { klass: UI::PageNavComponent, base: "border-b",
      build: ->(opts) { UI::PageNavComponent.new(items: [{ label: "Runs", href: "/runs" }], **opts) } },

    { klass: UI::PanelComponent, base: "bg-app-surface",
      build: ->(opts) { UI::PanelComponent.new(**opts) } },

    { klass: UI::SparklineComponent, base: "space-y-2",
      build: lambda { |opts|
        UI::SparklineComponent.new(
          id: "trajectory", label: "Suite size", coverage: "80%", summary: "Two runs.",
          columns: %w[Commit Tests Age],
          # `formatter` is required rather than defaulted, so the component holds no opinion about
          # what it is plotting — the same refusal `columns:` already makes. This spec has no stake
          # in the unit; it asserts wrapper-class merging.
          formatter: ->(value) { value.to_s },
          points: [
            UI::SparklineComponent::Point.new(label: "abc1234", value: 10, detail: "2d ago"),
            UI::SparklineComponent::Point.new(label: "def5678", value: 12, detail: "1d ago")
          ],
          **opts
        )
      } },

    { klass: UI::StatComponent, base: "space-y-1",
      build: ->(opts) { UI::StatComponent.new(label: "Tests", value: 12, **opts) } },

    { klass: UI::TableComponent, base: "overflow-x-auto",
      build: ->(opts) { UI::TableComponent.new(columns: ["Commit"], **opts) } },

    # The one component whose caller slot is not `:class`. Same construct, same two failure modes,
    # different key — which is why the shared example takes the key as a parameter.
    { klass: Forms::FieldComponent, base: "space-y-1", key: :wrapper_class,
      build: lambda { |opts|
        Forms::FieldComponent.new(
          form: ActionView::Helpers::FormBuilder.new(
            :repository, Repository.new, vc_test_controller.view_context, {}
          ),
          attribute: :github_full_name, **opts
        )
      } }
  ].freeze

  registry.each do |entry|
    describe [entry[:klass], entry[:suffix]].compact.join(" "), type: :component do
      it_behaves_like "a component that appends the caller's class", entry
    end
  end

  # `Forms::FieldComponent` is the one component whose class-consuming method is not the only reader
  # of its options hash: `#input` splats the REMAINING `@input_options` onto the form control. If
  # `:wrapper_class` has not been consumed by the time that splat runs, it lands on the input as a
  # stray, invalid `wrapper_class="..."` HTML attribute. `#input` therefore calls `wrapper_class`
  # itself, so the guarantee is structural rather than a bet on the template reading the wrapper
  # (line 1) before the input (line 3) — the same order-bet removed from `alert` and `panel`.
  #
  # Called in the HOSTILE order on purpose. Through the template this passes either way, which is
  # precisely what makes the order-bet invisible and worth pinning here instead.
  describe "Forms::FieldComponent#input", type: :component do
    # @intent: { entity: "Forms::FieldComponent", action: "consume wrapper class", behavior: "input splat emits an input with no wrapper_class attribute or probe class when called before #wrapper_class", layer: "integration" }
    it "consumes :wrapper_class even when called before #wrapper_class" do
      component = Forms::FieldComponent.new(
        form: ActionView::Helpers::FormBuilder.new(
          :repository, Repository.new, vc_test_controller.view_context, {}
        ),
        attribute: :github_full_name, wrapper_class: "spg-probe-wrapper-slot"
      )

      markup = component.input

      expect(markup).to include("<input")
      expect(markup).not_to include("wrapper_class")
      expect(markup).not_to include("spg-probe-wrapper-slot")
    end
  end

  # A registry is only a guard while it is complete. This walks the components for the construct
  # itself and fails on any site the registry does not name, so the next component written this way
  # arrives with coverage rather than a silent gap. It also fails the other way, on a registry entry
  # whose component no longer consumes a class — a stale entry is a passing example that guards
  # nothing.
  #
  # MUTATION-RUN HAZARD, which is why this carries the `:construct_grep` tag. This example matches
  # the SOURCE TEXT of the construct, not its behaviour, so ANY textual edit to `delete(:class)`
  # fails it whether or not behaviour changed. Rewriting a site to `@options[:class]` — the exact
  # mutation you would run to check that the duplicate-attribute assertion above still bites —
  # deletes the string this greps for, so this example dies by construction at all 19 sites. At the
  # 11 non-splat sites it is the ONLY example that dies, and a run that leaves it in reads as a
  # clean behavioural sweep that never happened. Filter it out when mutating the construct:
  #
  #   bundle exec rspec spec/components --tag ~construct_grep
  #
  # @intent: { entity: "caller-class registry", action: "enumerate consuming components", behavior: "the greppable construct list and the registry match exactly in both directions, failing on new or stale sites", layer: "unit" }
  it "names every component that consumes a caller-supplied class", :construct_grep do
    consuming = Rails.root.glob("app/components/**/*.rb").filter_map { |path|
      # Whole-line comments dropped first: `ApplicationComponent` documents this very construct in
      # prose, and prose is not a site. Lines carrying code plus a trailing comment are kept, so
      # nothing real is skipped.
      code = path.read.lines.grep_v(/\A\s*#/).join
      relative = path.relative_path_from(Rails.root).to_s
      relative if code.match?(/delete\(:(?:wrapper_)?class\)/) && exempt.exclude?(relative)
    }.sort

    registered = registry.map { |entry| "app/components/#{entry[:klass].name.underscore}.rb" }.uniq.sort

    expect(consuming - registered).to eq([])
    expect(registered - consuming).to eq([])
  end
end
