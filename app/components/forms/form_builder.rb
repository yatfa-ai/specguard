# frozen_string_literal: true

# The app-wide form builder. `field` is the only sanctioned way to render a labelled control,
# so no view has to know the input class list.
#
#   <%= form_with model: repository, builder: Forms::FormBuilder do |f| %>
#     <div class="form-grid">
#       <%= f.field :github_full_name, label: "GitHub repository", full: true %>
#     </div>
#   <% end %>
class Forms::FormBuilder < ActionView::Helpers::FormBuilder
  def field(attribute, as: :text_field, **options)
    @template.render(Forms::FieldComponent.new(form: self, attribute: attribute, as: as, **options))
  end

  def submit_button(label, variant: :primary, size: :md, **options)
    @template.submit_tag(
      label,
      class: UI::ButtonComponent.classes(variant: variant, size: size, extra: options.delete(:class)),
      **options
    )
  end
end
