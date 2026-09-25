# Be sure to restart your server when you modify this file.

# Add new inflection rules using the following format. Inflections
# are locale specific, and you may define rules for as many different
# locales as you wish. All of these examples are active by default:
# ActiveSupport::Inflector.inflections(:en) do |inflect|
#   inflect.plural /^(ox)$/i, "\\1en"
#   inflect.singular /^(ox)en/i, "\\1"
#   inflect.irregular "person", "people"
#   inflect.uncountable %w( fish sheep )
# end

# These inflection rules are supported but not enabled by default:
# ActiveSupport::Inflector.inflections(:en) do |inflect|
#   inflect.acronym "RESTful"
# end

# `app/components/ui.rb` defines `module UI`, and `app/components/ui/*` the primitives inside it.
# Teach the autoloader that the `ui` path segment camelizes to `UI`, not `Ui`.
Rails.autoloaders.each do |autoloader|
  autoloader.inflector.inflect("ui" => "UI")
end

# `NearDuplicateCensus` pluralizes to `near_duplicate_censuses` — the English plural the migration
# created the table under and the one the class comment uses. Rails' default inflector answers
# `censes` for `census`, which would name the model's table `near_duplicate_census` (singular) and
# miss the real one on every query. State the rule rather than override `table_name` on the model:
# an inflection is a fact about the LANGUAGE, and every future form of the word — route helpers,
# fixture names, `classify` on the table name — inherits it consistently instead of one model
# carrying a private exception.
ActiveSupport::Inflector.inflections(:en) do |inflect|
  inflect.irregular "census", "censuses"
end
