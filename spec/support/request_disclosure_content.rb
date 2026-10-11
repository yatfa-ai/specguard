# frozen_string_literal: true

# The console folds the prose that explains a table ("How to read this", "How the suite-size change
# is measured") behind a native <details> disclosure, and points the table's `aria-describedby` at
# it. The words are in the document either way — a screen reader reads them whether or not the
# disclosure is open — and request specs assert what the SERVER wrote, not what a browser paints.
# Capybara's string driver treats the body of a closed <details> as invisible, which would make
# every such assertion fail on a rendering choice rather than on the wording it pins. Scoped to
# request specs; system specs drive a real browser and keep Capybara's default.
RSpec.configure do |config|
  config.around(:each, type: :request) do |example|
    previous = Capybara.ignore_hidden_elements
    Capybara.ignore_hidden_elements = false
    example.run
  ensure
    Capybara.ignore_hidden_elements = previous
  end
end

# The console's table rows carry their detail (facts + the row's real destinations) in a
# <template data-drawer-body> that the drawer controller clones into the ONE overlay on click. The
# links in it are in the page the server wrote — they are what a click lands on — but a template's
# children are inert in Nokogiri's tree, so a request spec could not see them. Unwrapped here into a
# hidden cell of the same row, which is where the detail belongs in the document. Applied to request
# specs only (the helper below is mixed into nothing else) and only to markup that carries one.
module DrawerTemplateUnwrapping
  TEMPLATE = %r{<template data-drawer-body=""?>(.*?)</template>}m

  def string(html)
    super(html.is_a?(String) ? html.gsub(TEMPLATE) { "<td data-drawer-body hidden>#{Regexp.last_match(1)}</td>" } : html)
  end
end
Capybara.singleton_class.prepend(DrawerTemplateUnwrapping)
