# frozen_string_literal: true

require "rails_helper"

# The system driver's error CLASSIFICATION, asserted directly.
#
# This is the deterministic half of the SPGD-834 fix. The failure it guards is a race — a node
# detached by a Turbo Drive `<body>` swap between being found and being acted on — and a race
# cannot be reproduced on demand: the CI run that filed the ticket hit it once in 3,430 examples,
# and the example reproduced green 15 times in a row locally. An example that drives the browser
# and hopes to lose the race would be green whether the fix were present or not, which is the one
# thing a regression guard may not be.
#
# So this asserts the MECHANISM instead, which is deterministic and is where the defect actually
# lived. `Capybara::Node::Base#synchronize` retries a failed interaction until
# `Capybara.default_max_wait_time`, but only for exceptions in `driver.invalid_element_errors`;
# anything else is re-raised on the first attempt. chromedriver reports the detached node as
# `UnknownError` ("Node with given id does not belong to the document") rather than as
# `StaleElementReferenceError`, so the wait window that exists to absorb exactly this never
# engaged.
#
# These examples fail with the driver subclass reverted, which is what makes them worth having.
RSpec.describe "System spec driver error tolerance" do
  # Built the way Capybara itself builds it — through the registered block — so this asserts what
  # the suite will actually run with. Asking the subclass directly would happily pass while the
  # registration handed out a stock `Capybara::Selenium::Driver`, which is precisely how this fix
  # would become a silent no-op.
  #
  # The driver OBJECT only; `browser` is lazy in Capybara and nothing here touches it, so no
  # Chromium process is started and these examples cost milliseconds.
  subject(:driver) { Capybara.drivers[:headless_chromium].call(nil) }

  # @intent: { entity: "System driver error tolerance", action: "register headless chromium driver", behavior: "the driver the suite actually uses treats chromedriver UnknownError as an invalid-element error so Capybara waits through it", layer: "system" }
  it "retries the detached-node error chromedriver reports as UnknownError" do
    expect(driver.invalid_element_errors).to include(Selenium::WebDriver::Error::UnknownError)
  end

  # The widening must ADD to Capybara's list rather than replace it. A subclass that returned only
  # the new class would pass the example above while silently dropping the stale-element handling
  # every other example in the suite depends on.
  # @intent: { entity: "System driver error tolerance", action: "widen invalid_element_errors", behavior: "the added UnknownError class extends rather than replaces Capybara stock stale and interactability errors", layer: "system" }
  it "keeps the errors Capybara already tolerated" do
    expect(driver.invalid_element_errors).to include(
      Selenium::WebDriver::Error::StaleElementReferenceError,
      Selenium::WebDriver::Error::ElementNotInteractableError,
      Selenium::WebDriver::Error::ElementClickInterceptedError
    )
  end

  # The retry is what the tolerance BUYS, and it is the actual claim: `synchronize` must swallow a
  # detached-node error and re-run the block, rather than re-raise it on the first attempt the way
  # it did before the fix.
  #
  # Driven through `Capybara::Node::Base#synchronize` itself, with a stub node standing in for the
  # element, so the mechanism is exercised without needing to lose a real race. The block raises
  # once and then succeeds — exactly the shape of a transient swap — and the assertion is that the
  # caller sees the SUCCESS.
  # @intent: { entity: "System driver error tolerance", action: "synchronize a node interaction", behavior: "a block raising the detached-node error once is re-run and its second-attempt success is returned to the caller", layer: "system" }
  it "recovers when a detached-node error is raised once and the retry succeeds" do
    session = Capybara::Session.new(:headless_chromium, nil)
    node = Capybara::Node::Base.new(session, driver)

    attempts = 0
    result = node.synchronize(1) do
      attempts += 1
      if attempts == 1
        raise Selenium::WebDriver::Error::UnknownError,
              'unhandled inspector error: {"code":-32000,' \
              '"message":"Node with given id does not belong to the document"}'
      end
      :registered
    end

    expect(result).to eq(:registered)
    expect(attempts).to eq(2)
  end
end
