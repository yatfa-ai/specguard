# Be sure to restart your server when you modify this file.

# Version of your assets, change this if you want to expire all your assets.
Rails.application.config.assets.version = "1.0"

# Add additional assets to the asset load path.
# Rails.application.config.assets.paths << Emoji.images_path

# Keep the Tailwind ENTRY out of the served assets.
#
# Propshaft's railtie unshifts every existent directory under app/assets onto the load path, so
# without this `app/assets/tailwind/application.css` — `@plugin`, `@source`, and the whole `@theme`
# token block — is compiled into public/assets and downloadable. It is an input to the build, not
# an asset.
#
# This line used to come from tailwindcss-rails (engine.rb: `excluded_paths << app/assets/tailwind`).
# That gem was dropped for an npm-pinned build, so the exclusion is stated here instead. It has to
# be a DIRECTORY: `excluded_paths` subtracts whole paths from `assets.paths`, so a single file
# inside a kept directory cannot be excluded — which is why the entry lives in its own directory
# rather than beside the built stylesheet.
Rails.application.config.assets.excluded_paths << Rails.root.join("app/assets/tailwind")
