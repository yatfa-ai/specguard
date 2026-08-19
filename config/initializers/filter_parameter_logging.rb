# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
# `:code` is here for the GitHub App callback, which arrives as `GET /github/installation/callback
# ?code=…`. That code is single-use and short-lived, but it is exchangeable for a user-to-server
# token inside its window — so it is the one artifact the whole ownership argument rests on, and it
# has no business sitting in a request log in plaintext.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc, :code
]
