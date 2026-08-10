# syntax=docker/dockerfile:1
# check=error=true

# Multi-stage Dockerfile for the SpecGuard Rails application.
# Builds a single image shared by the web server (puma) and the Solid Queue worker.
#
# SpecGuard uses importmap (no JS bundling), so no JS bundler is needed in this
# build. Node + `npm install` ARE needed, though — assets:precompile runs
# tailwindcss:build, which resolves the `daisyui` @plugin from node_modules (see
# lib/spec_guard/stylesheet_lint.rb: "npm for DaisyUI, then the Tailwind CLI").
# SpecGuard does not use ActiveRecord Encryption, so assets:precompile needs only
# SECRET_KEY_BASE_DUMMY=1.
# Ruby matches .ruby-version (4.0.5).

ARG RUBY_VERSION=4.0.5
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages (libvips for image deps, postgresql-client for
# db:prepare, jemalloc for memory).
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
        curl libjemalloc2 libvips postgresql-client && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Production env + jemalloc for reduced memory usage and latency.
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

# Throw-away build stage to reduce size of final image
FROM base AS build

# Packages needed to build gems (pg, neighbor, nokogiri, …).
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
        build-essential git libpq-dev libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Node 20 for the CSS build: assets:precompile runs tailwindcss:build, which
# resolves the `daisyui` @plugin (app/assets/tailwind/application.css) from
# node_modules. importmap means no JS bundling — npm is here only for daisyui.
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    # -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
    bundle exec bootsnap precompile -j 1 --gemfile

# Install npm deps (daisyui) for the CSS build. No lockfile in this repo, so a
# plain install (resolves daisyui ^5.7.16). Layered before COPY . .; the
# .dockerignore keeps the host node_modules out of the context either way.
COPY package.json ./
RUN npm install

# Copy application code (incl. the committed app/assets/builds/tailwind.css,
# which assets:precompile regenerates from the tailwind sources + daisyui).
COPY . .

# Precompile bootsnap code for faster boot times.
RUN bundle exec bootsnap precompile -j 1 app/ lib/

# Precompile assets for production without requiring a real SECRET_KEY_BASE.
# SpecGuard does not use ActiveRecord::Encryption, so no dummy encryption keys
# are needed here. assets:precompile only boots the app.
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile

# Web target — the only image. The Solid Queue worker uses this same image and
# overrides the command (see bin/jobs).
FROM base AS web
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails
ENTRYPOINT ["/rails/bin/docker-entrypoint"]
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]

# Default target for backward compatibility
FROM web
