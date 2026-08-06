require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
# require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
# require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

# Not autoloadable — it is referenced while the middleware stack is being assembled, which is
# before the autoloaders are usable. `lib/middleware` is excluded from `autoload_lib` below.
require_relative "../lib/middleware/json_parse_error_responder"

module Specguard
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets middleware tasks])

    # Give the API one error shape. Inserted inside DebugExceptions on purpose — see the class.
    config.middleware.insert_after ActionDispatch::DebugExceptions, JsonParseErrorResponder

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Don't generate system test files.
    config.generators.system_tests = nil

    # A repository member who lacks one specific permission gets 403, not 404: they can already see
    # the repository, so hiding it would be a lie. Non-members still raise RecordNotFound -> 404.
    config.action_dispatch.rescue_responses["SpecGuard::NotAuthorized"] = :forbidden
  end
end
