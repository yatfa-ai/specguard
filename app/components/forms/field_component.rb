# frozen_string_literal: true

# One labelled form control. Never set a bespoke width here — layout is the caller's `.form-grid`
# plus `.form-field-full`, per the design-system layout rules.
class Forms::FieldComponent < ApplicationComponent
  INPUT_CLASS = "w-full rounded-md border border-app-border-light bg-app-surface-raised " \
                "px-3 py-2 text-sm text-app-content placeholder:text-app-muted " \
                "focus:border-app-cta focus:outline-none"

  def initialize(form:, attribute:, as: :text_field, label: nil, hint: nil, full: false, **input_options)
    @form = form
    @attribute = attribute
    @as = as
    @label = label
    @hint = hint
    @full = full
    @input_options = input_options
    super
  end

  attr_reader :form, :attribute, :hint

  def label_text
    @label || attribute.to_s.humanize
  end

  def wrapper_class
    @wrapper_class ||=
      merge_classes("space-y-1", @full ? "form-field-full" : nil, @input_options.delete(:wrapper_class))
  end

  def errors
    return [] unless form.object.respond_to?(:errors)

    form.object.errors.full_messages_for(attribute)
  end

  def input
    # `wrapper_class` is what consumes `:wrapper_class` out of `@input_options`, and the splat below
    # would otherwise emit whatever is left as a stray `wrapper_class="..."` attribute on the form
    # control. Calling it here makes that impossible structurally, instead of resting on the
    # template reading the wrapper (line 1) before the input (line 3) — the same order-bet that was
    # removed from `alert` and `panel`. Memoised, so this costs nothing and the template's own call
    # is unaffected.
    wrapper_class

    return select_input if @as == :select

    form.public_send(@as, attribute,
                     **@input_options,
                     class: merge_classes(INPUT_CLASS, @input_options[:class]))
  end

  private

  # `select` is the one control in the builder whose signature is not `(attribute, **options)` —
  # it takes choices and its select-specific options as *positional* arguments, and its HTML
  # attributes only third. Splatting the caller's options at it the way every other control is
  # handled puts `include_blank` on the `<select>` tag as a stray attribute and drops the choices
  # entirely. So it is spelled out here once, rather than at each call site or by asking callers to
  # bypass `field` and lose the label, hint and error rendering that is the point of this component.
  def select_input
    choices = @input_options.delete(:choices) || []
    select_options = @input_options.extract!(:include_blank, :prompt, :selected)

    form.select(attribute, choices, select_options,
                @input_options.merge(class: merge_classes(INPUT_CLASS, @input_options[:class])))
  end
end
