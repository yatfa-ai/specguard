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
    form.public_send(@as, attribute,
                     **@input_options,
                     class: merge_classes(INPUT_CLASS, @input_options[:class]))
  end
end
