# frozen_string_literal: true

require "rails_helper"

# The "Slowest tests" panel on repositories#show — the first surface SpecGuard renders off
# `spec_observations`, and the first answer this product has ever given about a single TEST rather
# than about a shard, a run or a suite.
#
# Its own file, for the reason spec/requests/repository_suite_trajectory_spec.rb states for itself:
# the Overview/API-keys file is edited by sibling slices, and every example here needs the same
# per-example fixture.
#
# The rows are written by `Ingest::ObservationRecorder` through `Ingest::RunRecorder` rather than
# inserted by hand, with the string-keyed hashes `Ingest::Payload` hands it. The two states this
# panel turns on — a timed example and an untimed one — are states the RECORDER produces from what
# a real client sends (`result&.run_time` is nil for an example that never ran), and a hand-built
# fixture would be asserting against a shape nothing in production writes.
RSpec.describe "Repository slowest tests", type: :request do
  before { @user = sign_in_via_github }

  def panel = Capybara.string(response.body).find("#slowest-examples")

  def panel?
    Capybara.string(response.body).has_css?("#slowest-examples")
  end

  # ELEMENT-scoped, never panel-scoped: the coverage sentence has three states that share most of
  # their words, so a panel-level `have_text` passes for the wrong state with the deciding branch
  # deleted.
  def basis_line = panel.find("#slowest-examples-basis")

  # One row as a reader meets it: the label, the two coordinate lines under it, the duration, and
  # what CI reported happened to it. Whitespace-collapsed, because a label and a location assembled
  # across two ERB tags are two readings on the page whatever the source did with indentation.
  #
  # The two coordinate lines are told apart by POSITION and never by what they say: for an ordinary
  # example they read nearly the same, and telling them apart by text would pass on a cell that
  # printed one of them twice. The run-in line is ALWAYS rendered — a path, or "not reported" — so
  # it is the last span of the cell, and a definition site exists only where there are two.
  def rows
    panel.all("tbody tr").map do |row|
      label_cell, duration_cell, outcome_cell = row.all("td")
      sites = label_cell.all("span").map { |span| span.text.gsub(/\s+/, " ").strip }
      ran_in = sites.last
      location = sites.first if sites.size > 1
      label = label_cell.text.gsub(/\s+/, " ").strip
      [ran_in, location].compact.each { |site| label = label.delete_suffix(site).strip }

      { label: label, location: location, ran_in: ran_in, duration: duration_cell.text.strip,
        outcome: outcome_cell.text.strip, outcome_class: outcome_cell.find("span")[:class] }
    end
  end

  def row_labels = rows.map { |row| row[:label] }

  # The run-in line's span and the drill-in link inside it, told apart from the definition-site link
  # that shares the cell by POSITION and never by text: the run-in line is ALWAYS the last span of
  # the cell, and for an ordinary example the two coordinate lines read nearly the same, so a text
  # filter would select whichever the row happened to render first. The span is always there — a
  # path, or "not reported" — and only the path branch carries a link.
  def ran_in_cell(row) = row.all("td").first.all("span").last

  def ran_in_link(row) = ran_in_cell(row).find("a")

  # One ingested run, through the producer. `specs` are the wire hashes a client POSTs; the
  # recorder reads them by string key, which is what `Ingest::Payload` hands it after JSON parsing.
  def ingest(repository, specs, commit_sha: "feedfacecafe0001", **attrs)
    run = Ingest::RunRecorder.record(
      repository,
      { commit_sha: commit_sha, branch: "main", total_specs_count: specs.size,
        annotated_specs_count: 0, duration_seconds: 60.0 }.merge(attrs),
      specs: specs.map(&:deep_stringify_keys)
    )
    # Resolved inline: the flakiness panel on the same page groups on the durable identity
    # (SPGD-758), so an unresolved row is an exclusion there rather than a key and the fixtures
    # would render that panel empty.
    Ingest::IdentityResolver.resolve(run)
    run
  end

  # One example on the wire. `duration:` and `name:` are passed at every call site, nils included —
  # an untimed and an unnamed example are both states this file turns on, and the shared builder
  # substitutes a default for a nil `name:`, so the value is merged in rather than passed through.
  def example_spec(name:, duration:, line_number:, file_path: "spec/models/invoice_spec.rb", **attrs)
    unannotated_spec(file_path: file_path, line_number: line_number, duration: duration)
      .merge({ name: name }.merge(attrs))
  end

  describe "a run whose examples were timed" do
    # @intent: {"entity": "GET /repositories/:id", "action": "rank slowest examples", "behavior": "three timed examples render as rows ordered 9.50s, 3.00s then 0.42s, each with its duration and its spec/models/invoice_spec.rb line coordinate", "layer": "request"}
    it "ranks them slowest first, with the duration each one took" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: "Invoice finalize locks the line items",
                                       duration: 0.42, line_number: 1),
                          example_spec(name: "Ledger rebuild walks every entry",
                                       duration: 9.5, line_number: 2),
                          example_spec(name: "User signs in", duration: 3.0, line_number: 3)])

      get repository_path(repository)

      expect(row_labels).to eq(["Ledger rebuild walks every entry",
                                "User signs in",
                                "Invoice finalize locks the line items"])
      expect(rows.map { |row| row[:duration] }).to eq(["9.50s", "3.00s", "0.42s"])
      # Every named row also says where to go and look, at the coordinate the line number belongs to.
      expect(rows.map { |row| row[:location] }).to eq(["spec/models/invoice_spec.rb:2",
                                                       "spec/models/invoice_spec.rb:3",
                                                       "spec/models/invoice_spec.rb:1"])
    end

    # Bounded by `SpecObservation::SLOWEST_LIMIT`: this is a list of the worst offenders, not a
    # rendering of the suite.
    # @intent: {"entity": "GET /repositories/:id", "action": "cap slowest list", "behavior": "a 40-example run renders exactly the ten worst rows, from example 40 at the head down to example 31", "layer": "request"}
    it "lists no more than the ten slowest, however many the run recorded" do
      repository = create_repository(user: @user)
      specs = (1..40).map { |i| example_spec(name: "example #{i}", duration: i.to_f, line_number: i) }
      ingest(repository, specs)

      get repository_path(repository)

      expect(rows.size).to eq(SpecObservation::SLOWEST_LIMIT)
      expect(row_labels.first).to eq("example 40")
      expect(row_labels.last).to eq("example 31")
    end

    # `name` is nullable — the client sends `nil` for an example it could not describe, and
    # `Ingest::ObservationRecorder` stores that faithfully. A blank cell here is a row the reader
    # can neither identify nor go and find.
    # @intent: {"entity": "GET /repositories/:id", "action": "label unnamed example", "behavior": "an example recorded with no name is labelled spec/models/ledger_spec.rb:88 and the row wears no second location line", "layer": "request"}
    it "falls back to the example's file and line where the client sent no name" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: nil, duration: 4.0, line_number: 88,
                                       file_path: "spec/models/ledger_spec.rb")])

      get repository_path(repository)

      expect(row_labels).to eq(["spec/models/ledger_spec.rb:88"])
      # The fallback already IS the location, so the row is not made to wear it twice.
      expect(rows.first[:location]).to be_nil
    end

    # @intent: {"entity": "GET /repositories/:id", "action": "state ranking coverage", "behavior": "with both recorded examples timed the basis line reads that every one of the 2 examples this run recorded reported a duration", "layer": "request"}
    it "says the ranking covers everything, where every recorded example reported a duration" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: "one", duration: 1.0, line_number: 1),
                          example_spec(name: "two", duration: 2.0, line_number: 2)])

      get repository_path(repository)

      expect(basis_line).to have_text("Every one of the 2 examples this run recorded reported a duration",
                                      normalize_ws: true)
    end
  end

  # The rung these rows used to stop short of. Every row in this panel is an outlier, and the
  # reader's next question — is this ONE test slow, or is the whole file — has a panel further down
  # the same page that nothing in this cell reached. It was reachable from every other per-example
  # listing SpecGuard renders and not from the first one.
  #
  # The coordinate the panel already printed is not a workaround for that: `#location_label` is the
  # DEFINITION site and the drill-in is keyed on the INCLUDING file, so for a shared example group
  # the path on the page is not the path that opens. The examples below turn on exactly that row.
  #
  # Local methods rather than constants, for the reason
  # spec/requests/repository_drill_down_carry_spec.rb spells out: a constant assigned inside an
  # `RSpec.describe` block lands on `Object`, where a sibling file assigning the same name would
  # decide the value both files read — and spec/requests/repository_spec_file_examples_spec.rb
  # already holds `ORDER_SPEC` there.
  describe "the file each ranked example ran in" do
    def order_spec = "spec/models/order_spec.rb"

    def refund_spec = "spec/models/refund_spec.rb"

    # Two files, so a link asserted to reach one has another it could have reached instead, and the
    # second file carries two rows so "the open file is marked" cannot pass by marking one row.
    def two_file_run
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: "Order refuses a negative quantity", duration: 9.0,
                                       line_number: 1, file_path: order_spec),
                          example_spec(name: "Refund settles the original charge", duration: 4.0,
                                       line_number: 2, file_path: refund_spec),
                          example_spec(name: "Refund is valid with a charge", duration: 1.0,
                                       line_number: 3, file_path: refund_spec)])
      repository
    end

    # The drill-in link, told apart from the definition-site link that now sits in the same cell by
    # POSITION and never by text — the same rule `#rows` tells the two coordinate lines apart by.
    def links = panel.all("tbody tr").flat_map { |row| ran_in_cell(row).all("a") }

    # The rows of the destination panel, as text. Used to compare the panel reached from HERE against
    # the same panel reached from the by-file rollup, which is the only assertion that can say the
    # two entry points open the same thing rather than two links that merely look alike.
    def spec_file_panel_rows
      Capybara.string(response.body).find("#spec-file-examples").all("tbody tr")
              .map { |row| row.text.gsub(/\s+/, " ").strip }
    end

    # @intent: {"entity": "GET /repositories/:id", "action": "link file drill-down", "behavior": "the first row's run-in link href carries spec_file=spec/models/order_spec.rb and the #spec-file-examples fragment", "layer": "request"}
    it "links each row's file into the spec-file drill-down" do
      get repository_path(two_file_run)

      href = ran_in_link(panel.first("tbody tr"))[:href]

      expect(href).to include("spec_file=#{CGI.escape(order_spec)}")
      expect(href).to include("#spec-file-examples")
    end

    # The definition site is not replaced by the file that ran the example; the cell states both.
    # @intent: {"entity": "GET /repositories/:id", "action": "state definition site", "behavior": "the top row names both spec/models/order_spec.rb:1 as its definition site and spec/models/order_spec.rb as the file it ran in", "layer": "request"}
    it "still names where the example is defined, beside the file that ran it" do
      get repository_path(two_file_run)

      expect(rows.first[:location]).to eq("#{order_spec}:1")
      expect(rows.first[:ran_in]).to eq(order_spec)
    end

    # A list of choices with one of them taken — the same mark the sibling listings carry, so a
    # reader arriving back at this ranking is told which row they are already looking at.
    # @intent: {"entity": "GET /repositories/:id", "action": "mark open file rows", "behavior": "with spec_file=spec/models/refund_spec.rb open, both refund rows carry aria-current=true while the order_spec row carries none", "layer": "request"}
    it "marks the rows whose file is already open, and only those" do
      get repository_path(two_file_run, spec_file: refund_spec)

      expect(links.map { |link| [link.text, link["aria-current"]] })
        .to eq([[order_spec, nil], [refund_spec, "true"], [refund_spec, "true"]])
    end

    # THE row this link exists for, and the one the printed coordinate cannot serve. `spec_file_path`
    # is the INCLUDING file and `file_path` the definition site; they differ exactly here, so the
    # path this cell printed before is a `spec/support/` file and the file that opens is one the cell
    # never named.
    # @intent: {"entity": "GET /repositories/:id", "action": "link including file", "behavior": "a shared example defined at spec/support/shared_examples.rb:7 but run from spec/models/order_spec.rb links to spec_file=order_spec and the panel never prints order_spec:7", "layer": "request"}
    it "links the file that RAN a shared example group rather than the file defining it" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: "behaves like an auditable record", duration: 9.0,
                                       line_number: 7,
                                       file_path: "spec/support/shared_examples.rb",
                                       spec_file_path: order_spec, id: "./#{order_spec}[1:1:1]")])

      get repository_path(repository)

      expect(rows.first[:location]).to eq("spec/support/shared_examples.rb:7")
      expect(rows.first[:ran_in]).to eq(order_spec)
      expect(links.first[:href]).to include("spec_file=#{CGI.escape(order_spec)}")
      # And never the two halves of different files printed as one pair, which would point at
      # whatever sits on line 7 of the including file.
      expect(panel).to have_no_text("#{order_spec}:7")
    end

    # `spec_file_path` is NULLABLE in the schema. `Ingest::ObservationRecorder#attributes` populates
    # it by falling back to `file_path`, so neither the producer nor the fixture can write a nil —
    # which is exactly why the column is set directly here. A defensive branch nothing exercises is a
    # branch that gets deleted as dead, and the cell it guards would otherwise link to nowhere.
    # @intent: {"entity": "GET /repositories/:id", "action": "handle missing including file", "behavior": "a row with spec_file_path set to nil reads not reported with no run-in link, keeps its order_spec:1 definition link to the feedfacecafe0001 blob, and the cell holds exactly 2 links", "layer": "request"}
    it "says so rather than linking nowhere where a row has no including file" do
      repository = two_file_run
      SpecObservation.where(line_number: 1).update_all(spec_file_path: nil)

      get repository_path(repository)

      expect(rows.first[:ran_in]).to eq("not reported")
      expect(ran_in_cell(panel.first("tbody tr"))).to have_no_css("a")
      # The definition site is NOT NULL and is what such a row is read by. It is no longer the only
      # thing on the row worth following — this row is NAMED, and the name carries the per-run
      # history drill-in — so the cell holds those two and the run-in line carries none. Counted
      # here rather than left to the assertion above because the count is what says the missing
      # including file cost this row ONE link and not its whole cell.
      expect(rows.first[:location]).to eq("#{order_spec}:1")
      expect(panel.first("tbody tr").all("td").first.all("a").size).to eq(2)
      expect(panel.first("tbody tr").all("td").first.all("a").last[:href]).to eq(
        "https://github.com/acme/billing-service/blob/feedfacecafe0001/#{order_spec}#L1"
      )
    end

    # Opening a file from here is not a request to close a branch, an area or a description the
    # reader opened separately — the carry-through rule
    # spec/requests/repository_drill_down_carry_spec.rb owns, asserted at this link end-to-end:
    # the href carries the three other asks AND the page it lands on still has all three open.
    # @intent: {"entity": "GET /repositories/:id", "action": "carry asks through", "behavior": "the drill-in href carries branch=main, spec_directory and repeated_description params, and the page it opens still renders the spec-file, spec-directory and repeated-description panels", "layer": "request"}
    it "carries every other open ask through the link, and through following it" do
      description = "Order refuses a negative quantity"
      get repository_path(two_file_run, branch: "main", spec_directory: "spec/models",
                                        repeated_description: description)

      href = ran_in_link(panel.first("tbody tr"))[:href]

      expect(href).to include("branch=main")
      expect(href).to include("spec_directory=#{CGI.escape('spec/models')}")
      expect(href).to include("repeated_description=#{CGI.escape(description)}")

      get href.split("#").first

      page = Capybara.string(response.body)
      expect(page).to have_css("#spec-file-examples")
      expect(page).to have_css("#spec-directory-files")
      expect(page).to have_css("#repeated-description-examples")
    end

    # Two entry points, one destination. Asserting the href alone would pass on a link that reached a
    # panel narrowed differently from the one the by-file rollup opens; this follows both and
    # compares what the reader actually gets.
    # @intent: {"entity": "GET /repositories/:id", "action": "match rollup panel", "behavior": "following the slowest-panel row link and the by-file rollup link yields identical one-row spec-file panels", "layer": "request"}
    it "opens the same file panel the by-file rollup opens" do
      get repository_path(two_file_run)

      from_slowest = ran_in_link(panel.first("tbody tr"))[:href]
      from_rollup = Capybara.string(response.body).find("#spec-file-durations")
                            .find("a", text: order_spec)[:href]

      get from_slowest.split("#").first
      via_slowest = spec_file_panel_rows
      get from_rollup.split("#").first
      via_rollup = spec_file_panel_rows

      expect(via_slowest).to eq(via_rollup)
      # Falsifiable: two empty panels are equal to each other and prove nothing.
      expect(via_slowest.size).to eq(1)
    end
  end

  # The coordinate as a DESTINATION rather than as text, through the seam
  # spec/requests/repository_unannotated_examples_spec.rb pins on the panel that introduced it.
  # `SpecObservation#location_label`'s comment opens "Where to go and look."; until now this panel
  # printed where and stopped there, and the row it stranded hardest was the one it exists to
  # rescue — a producer that sent no name leaves the coordinate as the row's ENTIRE identity, so the
  # rows a reader could least identify were also the ones nothing could be done about.
  #
  # NOT the `?spec_file=` drill-in above under another name: that opens a panel on this page keyed
  # on the INCLUDING file, this leaves the app for the DEFINITION site, and the shared-example-group
  # example below is the row where the two are different files.
  describe "the definition site as a link" do
    def order_spec = "spec/models/order_spec.rb"

    def invoice_spec = "spec/models/invoice_spec.rb"

    # The definition-site link, told apart from the two drill-ins that share the cell by POSITION
    # and never by text — the rule the whole file reads this cell by.
    #
    # It is the LAST anchor of the cell that is not the run-in link, which is the one rule that
    # holds on BOTH label branches. It used to be the FIRST anchor, and that stopped being true the
    # moment the NAME above it became a link on the named branch: the name is now the cell's first
    # anchor there, while on a nameless row the definition site still IS the label and comes first.
    # Reading from the other end is what makes the two branches agree again — the definition site is
    # the last thing in the cell before the run-in line, whether or not a linked name precedes it.
    #
    # Excluded by IDENTITY (`Capybara::Node::Element#path`, the node's own XPath) rather than by
    # counting back a fixed number of anchors: the run-in line carries a link only when the row has
    # an including file, so a positional offset would read a different anchor on the row that has
    # none — which is a real branch this file turns on one describe block up.
    def definition_link(row)
      ran_in_paths = ran_in_cell(row).all("a").map(&:path)

      row.all("td").first.all("a").reject { |link| ran_in_paths.include?(link.path) }.last
    end

    def definition_hrefs = panel.all("tbody tr").map { |row| definition_link(row)[:href] }

    def blob(sha, path, line) = "https://github.com/acme/billing-service/blob/#{sha}/#{path}#L#{line}"

    # @intent: {"entity": "GET /repositories/:id", "action": "link coordinate to github", "behavior": "each ranked row links its coordinate to github.com/acme/billing-service/blob/feedfacecafe0001 with #L30 and #L12 anchors, the printed coordinate as the link text", "layer": "request"}
    it "links each ranked row's coordinate to that line on GitHub" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: "Order refuses a negative quantity", duration: 9.0,
                                       line_number: 30, file_path: order_spec),
                          example_spec(name: "Invoice finalize locks the line items",
                                       duration: 4.0, line_number: 12)])

      get repository_path(repository)

      expect(definition_hrefs).to eq([blob("feedfacecafe0001", order_spec, 30),
                                      blob("feedfacecafe0001", invoice_spec, 12)])
      # The link text is the coordinate the panel already printed — the same string the reader was
      # reading, not a second control bolted onto the row.
      expect(definition_link(panel.first("tbody tr")).text.strip).to eq("#{order_spec}:30")
    end

    # THE BRANCH THAT IS EASY TO MISS. `#label` is `name.presence || location_label`, so a row from
    # a producer that sent no name wears the coordinate AS its name and renders through the other
    # site entirely. Linking only the location line under a name would leave inert exactly the rows
    # the fallback exists for — the ones this panel's own comment calls a row the reader "can
    # neither identify nor go and find".
    # @intent: {"entity": "GET /repositories/:id", "action": "link coordinate label", "behavior": "a nameless row labelled spec/models/ledger_spec.rb:88 links that label to the feedfacecafe0001 blob line 88 with no second location and exactly 2 links in the cell", "layer": "request"}
    it "links the coordinate on a row that wears it as its name" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: nil, duration: 4.0, line_number: 88,
                                       file_path: "spec/models/ledger_spec.rb")])

      get repository_path(repository)

      expect(row_labels).to eq(["spec/models/ledger_spec.rb:88"])
      expect(definition_hrefs).to eq([blob("feedfacecafe0001", "spec/models/ledger_spec.rb", 88)])
      # And NOT TWICE: the fallback already IS the coordinate, so there is no second location line
      # to link, and the cell holds this link plus the drill-in and nothing else.
      expect(rows.first[:location]).to be_nil
      expect(panel.first("tbody tr").all("td").first.all("a").size).to eq(2)
    end

    # THE DEFINITION SITE, never the including file. `#location_label` pairs `file_path` with
    # `line_number` and refuses `spec_file_path` because for a shared example group the two halves
    # come from different files; the link inherits that constraint rather than reaching for the
    # column the row is drilled in by. Line 7 of `order_spec.rb` is not this example.
    # @intent: {"entity": "GET /repositories/:id", "action": "anchor definition site", "behavior": "the shared-group row's definition link targets blob feedfacecafe0001 spec/support/shared_examples.rb#L7 and never order_spec, while the drill-in beside it still carries spec_file=order_spec", "layer": "request"}
    it "builds the link from the file the example is DEFINED in, not the file that ran it" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: "behaves like an auditable record", duration: 9.0,
                                       line_number: 7,
                                       file_path: "spec/support/shared_examples.rb",
                                       spec_file_path: order_spec, id: "./#{order_spec}[1:1:1]")])

      get repository_path(repository)

      expect(definition_hrefs).to eq([blob("feedfacecafe0001", "spec/support/shared_examples.rb", 7)])
      expect(definition_hrefs.first).not_to include(order_spec)
      # And the drill-in beside it still reaches the file that RAN it, which is the whole reason the
      # row carries two links rather than one.
      expect(ran_in_link(panel.first("tbody tr"))[:href]).to include("spec_file=#{CGI.escape(order_spec)}")
    end

    # THE ANCHORED RUN'S SHA, not `main` and not the newest run. `file_path`/`line_number` are a
    # last known path rather than an identity (SPGD-114): the coordinate is accurate against the
    # tree the run that recorded it was taken from, so a page anchored on an older run via
    # `?commit_sha=` must link into THAT run's tree.
    # @intent: {"entity": "GET /repositories/:id", "action": "pin link to anchor", "behavior": "with ?commit_sha=aaaa1111bbbb2222 the definition link uses blob aaaa1111bbbb2222/order_spec#L30 and never the newer cccc3333dddd4444 sha", "layer": "request"}
    it "pins the link to the run the page is anchored on rather than the newest one" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: "Order refuses a negative quantity", duration: 9.0,
                                       line_number: 30, file_path: order_spec)],
             commit_sha: "aaaa1111bbbb2222")
      ingest(repository, [example_spec(name: "Order refuses a negative quantity", duration: 9.0,
                                       line_number: 30, file_path: order_spec)],
             commit_sha: "cccc3333dddd4444")

      get repository_path(repository, commit_sha: "aaaa1111bbbb2222")

      expect(definition_hrefs).to eq([blob("aaaa1111bbbb2222", order_spec, 30)])
      expect(definition_hrefs.first).not_to include("cccc3333dddd4444")
    end

    # The pairing that stops the assertion above from passing on a page that simply had one run.
    # @intent: {"entity": "GET /repositories/:id", "action": "link newest run sha", "behavior": "unanchored, the definition link points at the newest run's blob cccc3333dddd4444/order_spec#L30", "layer": "request"}
    it "links at the newest run's sha when no anchor was asked for" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: "Order refuses a negative quantity", duration: 9.0,
                                       line_number: 30, file_path: order_spec)],
             commit_sha: "aaaa1111bbbb2222")
      ingest(repository, [example_spec(name: "Order refuses a negative quantity", duration: 9.0,
                                       line_number: 30, file_path: order_spec)],
             commit_sha: "cccc3333dddd4444")

      get repository_path(repository)

      expect(definition_hrefs).to eq([blob("cccc3333dddd4444", order_spec, 30)])
    end

    # A NEW TAB, the convention the "Unannotated tests here" panel introduced deliberately for the
    # app's first link that leaves it. `rel` is written out rather than left to the browsers that
    # imply it. The drill-in beside it stays in the tab, which is why this reads the two apart.
    # @intent: {"entity": "GET /repositories/:id", "action": "open in new tab", "behavior": "the definition link carries target=_blank with rel=noopener noreferrer while the run-in drill-in link has no target", "layer": "request"}
    it "opens the file in a new tab, leaving the ranking where the reader had it" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: "Order refuses a negative quantity", duration: 9.0,
                                       line_number: 30, file_path: order_spec)])

      get repository_path(repository)

      link = definition_link(panel.first("tbody tr"))

      expect(link[:target]).to eq("_blank")
      expect(link[:rel]).to eq("noopener noreferrer")
      expect(ran_in_link(panel.first("tbody tr"))[:target]).to be_nil
    end

    # ZERO NEW QUERIES: `@repository` and `@latest_test_run` are both loaded before this partial
    # renders and `#github_blob_url` is string composition, so ten linked rows must cost exactly
    # what one costs.
    #
    # `count_queries` rather than the `queries_against("spec_observations")` the budget at the foot
    # of this file uses, and deliberately: the regression this guards against is a per-ROW reach for
    # `@repository` or `@latest_test_run`, which would show up against `repositories` or
    # `test_runs` and be invisible to a single-table count.
    #
    # Two SINGLE-RUN repositories rather than two runs of one, on the precedent that budget sets:
    # a second run puts the cross-run comparison panel and the run-anchor lookup on the page, so
    # the two pages would differ by more than the row count.
    # @intent: {"entity": "GET /repositories/:id", "action": "hold link query budget", "behavior": "pages rendering one linked row and ten linked rows issue the same total query count, with all ten distinct definition hrefs rendered", "layer": "request"}
    it "costs the same number of queries for ten linked rows as for one" do
      one_row = create_repository(user: @user, github_full_name: "acme/small-suite")
      ingest(one_row, [example_spec(name: "only", duration: 1.0, line_number: 1)])
      ten_rows = create_repository(user: @user, github_full_name: "acme/large-suite")
      ingest(ten_rows, (1..SpecObservation::SLOWEST_LIMIT)
                         .map { |n| example_spec(name: "example #{n}", duration: n.to_f, line_number: n) })

      get repository_path(one_row)
      one = count_queries { get repository_path(one_row) }
      get repository_path(ten_rows)
      ten = count_queries { get repository_path(ten_rows) }

      expect(rows.size).to eq(SpecObservation::SLOWEST_LIMIT)
      expect(definition_hrefs.uniq.size).to eq(SpecObservation::SLOWEST_LIMIT)
      expect(ten).to eq(one)
    end
  end

  # The row's SUBJECT as a link — the last thing in this cell that went nowhere. The coordinate
  # under the name and the file beside it were both links while the TEST, which is what the row is
  # about, was plain text.
  #
  # This panel ranks ten wall clocks against ONE run, and the question every one of those rows
  # raises — is this test always this slow, or was it slow today — is answered by "This test, run
  # by run" further down the same page, which already carries a Duration column and is already
  # keyed on the name. So this adds a CALLER and not a read: the destination, `UnstableTestRuns`
  # and `SpecObservation.outcome_sequence_in` are untouched.
  #
  # NOT gated on the flakiness ranking, which is the property that makes the reuse honest rather
  # than merely convenient: the destination keys on the name and applies no stability filter, so a
  # perfectly STABLE slow test — the ordinary row on this panel, and one the ranking above would
  # never list — resolves through it. The example below turns on exactly that row.
  describe "the test name as a link into its own run-by-run history" do
    def slow_test = "Ledger rebuild walks every entry"

    def other_test = "Invoice finalize locks the line items"

    # The name link, told apart from the two links BELOW it in the same cell by POSITION and never
    # by text — the rule this whole file reads this cell by. On a NAMED row it is the cell's first
    # anchor; this helper is used only on named rows, because on a nameless one the first anchor is
    # the definition site and there is deliberately no name link to find.
    def name_link(row) = row.all("td").first.all("a").first

    def name_links = panel.all("tbody tr").map { |row| name_link(row) }

    def history_panel? = Capybara.string(response.body).has_css?("#unstable-test-runs")

    def history_panel = Capybara.string(response.body).find("#unstable-test-runs")

    # The destination's Duration column, which is the whole reason this link points where it does.
    # Column 4 of `_unstable_test_runs.html.erb`'s header row.
    def history_durations
      history_panel.all("tbody tr").map { |row| row.all("td")[4].text.strip }
    end

    # Two runs so the destination has a SERIES to report rather than a single row, and the same
    # test timed differently in each — a panel that printed one figure twice would pass an
    # assertion that only counted rows.
    def two_run_repository
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: slow_test, duration: 3.0, line_number: 2),
                          example_spec(name: other_test, duration: 0.42, line_number: 1)],
             commit_sha: "aaaa1111bbbb2222")
      ingest(repository, [example_spec(name: slow_test, duration: 9.5, line_number: 2),
                          example_spec(name: other_test, duration: 0.42, line_number: 1)],
             commit_sha: "cccc3333dddd4444")
      repository
    end

    # ⭐ CRITERION 1 — one click from the ranking to the series.
    # @intent: {"entity": "GET /repositories/:id", "action": "link name to history", "behavior": "the first row's name link href carries unstable_test=Ledger rebuild walks every entry and the #unstable-test-runs fragment", "layer": "request"}
    it "links each named row's test to its own per-run history" do
      get repository_path(two_run_repository)

      href = name_link(panel.first("tbody tr"))[:href]

      expect(href).to include("unstable_test=#{CGI.escape(slow_test)}")
      expect(href).to include("#unstable-test-runs")
    end

    # The link TEXT is what the reader was already looking at, so following it is not a jump to
    # something they were not offered.
    # @intent: {"entity": "GET /repositories/:id", "action": "link printed label", "behavior": "the two name links read exactly Ledger rebuild walks every entry and Invoice finalize locks the line items", "layer": "request"}
    it "links the label the panel already printed" do
      get repository_path(two_run_repository)

      expect(name_links.map(&:text).map(&:strip)).to eq([slow_test, other_test])
    end

    # ⭐ CRITERION 1, followed rather than asserted at the href: the reader arrives at a panel that
    # actually reports this test's Duration series, and it is THIS test's — the second test on the
    # fixture is timed differently, so a link that keyed on the wrong row would print its figures.
    # @intent: {"entity": "GET /repositories/:id", "action": "open duration series", "behavior": "following the name link renders the history panel naming that test with its Duration series 3.00s then 9.50s", "layer": "request"}
    it "opens a panel reporting that test's duration run by run" do
      get repository_path(two_run_repository)
      href = name_link(panel.first("tbody tr"))[:href]

      get href.split("#").first

      expect(history_panel).to have_text(slow_test)
      expect(history_durations).to eq(["3.00s", "9.50s"])
    end

    # THE ROW THE REUSE HAS TO SERVE. `?unstable_test=` is named for the panel that first asked it,
    # and every test on THIS panel is ranked by wall clock with no reference to stability — so the
    # ordinary case here is a test the "Tests whose outcome changed" ranking does not list at all.
    # A destination that silently required instability would fail exactly this row and no other.
    # @intent: {"entity": "GET /repositories/:id", "action": "open stable test history", "behavior": "for a test the unstable-tests ranking lists nowhere (#unstable-tests-none), ?unstable_test= still returns 200 with its 3.00s and 9.50s duration rows", "layer": "request"}
    it "opens the history of a test the flakiness ranking never lists" do
      repository = two_run_repository

      get repository_path(repository)

      # The premise, asserted rather than assumed: this test passed in every run, so the ranking
      # above does not LIST it. Without this the example below could pass on a flaky test by
      # accident, which would prove nothing about the stable row this link has to serve.
      #
      # Not `have_no_css("#unstable-tests")`: that panel renders here. Its window IS comparable —
      # two runs that both reported outcomes — so it renders its honest zero rather than absenting
      # itself, and the fact worth pinning is that the zero is what it prints.
      ranking = Capybara.string(response.body).find("#unstable-tests")
      expect(ranking).to have_css("#unstable-tests-none")
      expect(ranking).to have_no_link(slow_test)

      get repository_path(repository, unstable_test: slow_test)

      expect(response).to have_http_status(:ok)
      expect(history_panel).to have_text(slow_test)
      expect(history_durations).to eq(["3.00s", "9.50s"])
    end

    # ⭐ CRITERION 4 — a list of choices with one of them taken, and the destination is a long way
    # down the page. Asserted across BOTH rows: "the open test is marked" cannot pass by marking
    # every row, and `aria-current` is absent rather than "false" on the others.
    # @intent: {"entity": "GET /repositories/:id", "action": "mark open test row", "behavior": "with ?unstable_test= set the open test's row link carries aria-current=true and the other row's carries none", "layer": "request"}
    it "marks the row whose test is currently open" do
      get repository_path(two_run_repository, unstable_test: slow_test)

      expect(name_links.map { |link| [link.text.strip, link["aria-current"]] })
        .to eq([[slow_test, "true"], [other_test, nil]])
    end

    # ⭐ CRITERION 2 — the nameless branch is UNCHANGED. Such a row has no name to key the ask on
    # and its label already IS the coordinate, so it keeps exactly the one link it had: the
    # definition site, in a new tab. A change that linked `#label` blindly would send this row's
    # coordinate to a destination that cannot resolve it.
    # @intent: {"entity": "GET /repositories/:id", "action": "skip nameless history link", "behavior": "a nameless row keeps exactly 2 links — the feedfacecafe0001 blob anchor at ledger_spec.rb line 88 in a new tab and the drill-in — and no href carries unstable_test=", "layer": "request"}
    it "leaves a nameless row's coordinate linked to its definition site and nothing else" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: nil, duration: 4.0, line_number: 88,
                                       file_path: "spec/models/ledger_spec.rb")])

      get repository_path(repository)

      row = panel.first("tbody tr")
      links = row.all("td").first.all("a")

      expect(row_labels).to eq(["spec/models/ledger_spec.rb:88"])
      # The definition site and the run-in drill-in, and no third link: no history ask was added.
      expect(links.size).to eq(2)
      expect(links.first[:href])
        .to eq("https://github.com/acme/billing-service/blob/feedfacecafe0001/spec/models/ledger_spec.rb#L88")
      expect(links.first[:target]).to eq("_blank")
      expect(links.map { |link| link[:href] }).to all(satisfy { |href| !href.include?("unstable_test=") })
    end

    # ⭐ CRITERION 3 — opening a test from here closes nothing the reader opened separately. The
    # carry-through rule spec/requests/repository_drill_down_carry_spec.rb owns, asserted at this
    # link end-to-end: the href carries the other asks AND the page it lands on still has them open.
    # @intent: {"entity": "GET /repositories/:id", "action": "carry asks through history", "behavior": "the name link href carries branch=main, spec_file and spec_directory, and the page it opens renders the history, spec-file and spec-directory panels", "layer": "request"}
    it "carries every other open ask through the link, and through following it" do
      repository = two_run_repository
      get repository_path(repository, branch: "main", spec_file: "spec/models/invoice_spec.rb",
                                      spec_directory: "spec/models")

      href = name_link(panel.first("tbody tr"))[:href]

      expect(href).to include("branch=main")
      expect(href).to include("spec_file=#{CGI.escape('spec/models/invoice_spec.rb')}")
      expect(href).to include("spec_directory=#{CGI.escape('spec/models')}")

      get href.split("#").first

      page = Capybara.string(response.body)
      expect(page).to have_css("#unstable-test-runs")
      expect(page).to have_css("#spec-file-examples")
      expect(page).to have_css("#spec-directory-files")
    end

    # ⭐ CRITERION 5 — the way back out, asserted at the ANCHOR the control lands on and not at the
    # presence of the panel it should land on.
    #
    # THE DISTINCTION IS THE WHOLE EXAMPLE, and the earlier version of it is why: it asserted
    # `have_css("#slowest-examples")`, which is true of that page whether or not the reader is sent
    # anywhere near it — the panel renders on every page this fixture builds. So it passed while the
    # control anchored at `#unstable-tests`, thousands of pixels away, and the criterion it claimed
    # to pin was not pinned at all. A landing assertion that cannot fail when the reader lands in
    # the wrong place is not a weaker assertion, it is a different one.
    #
    # The fragment is therefore READ rather than discarded, and it is the subject here.
    # @intent: {"entity": "GET /repositories/:id", "action": "anchor close back", "behavior": "Close test from a slowest-tests origin targets the #slowest-examples fragment, sheds unstable_test_from, closes the history panel and leaves #spec-directory-files open", "layer": "request"}
    it "anchors the reader back at THIS panel when they close the test" do
      repository = two_run_repository
      get repository_path(repository, spec_directory: "spec/models")

      open_here = name_link(panel.first("tbody tr"))[:href]
      get open_here.split("#").first

      close = Capybara.string(response.body).find("#unstable-test-runs")
                      .find("a", exact_text: "Close test")[:href]

      # The panel the reader opened the test FROM, and specifically not the flakiness ranking this
      # control anchored at while that panel was the only way in.
      expect(close.split("#").last).to eq("slowest-examples")

      get close.split("#").first

      page = Capybara.string(response.body)
      expect(page).to have_no_css("#unstable-test-runs")
      expect(page).to have_css("#slowest-examples")
      # The origin is a QUALIFIER of the test, so closing the test takes it with them: leaving it
      # behind would point this control at a panel with nothing open in it on every later link.
      expect(close).not_to include("unstable_test_from=")
      expect(page).to have_css("#spec-directory-files")
    end

    # THE ROW THE ANCHOR EXISTS FOR, stated as its own example because it is the one the old
    # hardcoded anchor failed WORST and the one a reader of this panel most often has.
    #
    # Every test on this fixture passes in every run, so the flakiness ranking renders its empty
    # state. A reader who opened such a test and closed it was returned to a panel that, BY
    # CONSTRUCTION, could not contain the row they came from — it is not that the row was hard to
    # find, it is that the panel is incapable of listing it. The premise is asserted rather than
    # assumed, so this cannot pass by accident on a flaky fixture.
    # @intent: {"entity": "GET /repositories/:id", "action": "return stable test reader", "behavior": "a stable test absent from the empty flakiness ranking closes back to #slowest-examples, which lists that test as a link", "layer": "request"}
    it "returns a stable slow test's reader to a panel that actually lists it" do
      repository = two_run_repository
      get repository_path(repository)

      ranking = Capybara.string(response.body).find("#unstable-tests")
      expect(ranking).to have_css("#unstable-tests-none")
      expect(ranking).to have_no_link(slow_test)

      open_here = name_link(panel.first("tbody tr"))[:href]
      get open_here.split("#").first
      close = Capybara.string(response.body).find("#unstable-test-runs")
                      .find("a", exact_text: "Close test")[:href]

      get close.split("#").first

      # The landing panel LISTS the test the reader was reading, which is the property that makes
      # the return useful rather than merely somewhere to go.
      expect(close.split("#").last).to eq("slowest-examples")
      expect(panel).to have_link(slow_test)
    end

    # THE OTHER ENTRY POINT IS UNMOVED. The flakiness ranking stamps its own origin, so a reader who
    # opened a test THERE still closes back there — this ticket adds a second origin rather than
    # moving the one that existed. Asserted from this file because it is this file's change that
    # could break it.
    # @intent: {"entity": "GET /repositories/:id", "action": "keep ranking origin", "behavior": "a test opened from the flakiness ranking makes Close test target the #unstable-tests fragment", "layer": "request"}
    it "leaves a test opened from the flakiness ranking closing back at that ranking" do
      repository = create_repository(user: @user)
      flaky = "Session expiry sweeps the cache"
      ingest(repository, [example_spec(name: flaky, duration: 1.0, line_number: 1, outcome: "failed")],
             commit_sha: "aaaa1111bbbb2222")
      ingest(repository, [example_spec(name: flaky, duration: 1.0, line_number: 1, outcome: "passed")],
             commit_sha: "cccc3333dddd4444")

      get repository_path(repository)
      open_there = Capybara.string(response.body).find("#unstable-tests")
                           .find("a", exact_text: flaky)[:href]
      get open_there.split("#").first

      close = Capybara.string(response.body).find("#unstable-test-runs")
                      .find("a", exact_text: "Close test")[:href]

      expect(close.split("#").last).to eq("unstable-tests")
    end

    # A reader who arrived by BOOKMARK or by typing the URL named no origin, and the control falls
    # back to the anchor it always had rather than to a blank fragment. This is the path every link
    # written before the qualifier existed still takes, so it is the compatibility pin.
    # @intent: {"entity": "GET /repositories/:id", "action": "default close origin", "behavior": "with no unstable_test_from given, Close test targets the default #unstable-tests fragment", "layer": "request"}
    it "falls back to the flakiness ranking when no origin was named" do
      get repository_path(two_run_repository, unstable_test: slow_test)

      close = Capybara.string(response.body).find("#unstable-test-runs")
                      .find("a", exact_text: "Close test")[:href]

      expect(close.split("#").last).to eq("unstable-tests")
    end

    # The origin is consumed as a URL FRAGMENT, so a value naming no panel would scroll the reader
    # nowhere — a silent wrong answer rather than a loud one. Only the ids of the panels that OFFER
    # the gesture are honoured; anything else is read as "not said" and takes the fallback above.
    # The three non-String shapes a query string can parse into are pinned the same way, because
    # `include?` against the allow-list does not answer for an Array or a Parameters the way this
    # reads it.
    # @intent: {"entity": "GET /repositories/:id", "action": "ignore bogus origins", "behavior": "for every bogus, non-panel or array/hash-shaped unstable_test_from value tried, the page answers 200 and Close test falls back to #unstable-tests without echoing the value", "layer": "request"}
    it "ignores an origin naming no panel, and every shape that is not a description" do
      repository = two_run_repository

      ["#{'a' * 40}", "javascript:alert(1)", "spec-file-examples"].each do |bogus|
        get repository_path(repository, unstable_test: slow_test, unstable_test_from: bogus)

        close = Capybara.string(response.body).find("#unstable-test-runs")
                        .find("a", exact_text: "Close test")[:href]

        expect(response).to have_http_status(:ok)
        expect(close.split("#").last).to eq("unstable-tests")
        expect(close).not_to include(CGI.escape(bogus))
      end

      ["?unstable_test_from[]=slowest-examples", "?unstable_test_from[a]=slowest-examples",
       "?unstable_test_from[][a]=slowest-examples"].each do |malformed|
        get "#{repository_path(repository)}?unstable_test=#{CGI.escape(slow_test)}&#{malformed.delete_prefix('?')}"

        close = Capybara.string(response.body).find("#unstable-test-runs")
                        .find("a", exact_text: "Close test")[:href]

        expect(response).to have_http_status(:ok)
        expect(close.split("#").last).to eq("unstable-tests")
      end
    end

    # ⭐ CRITERION 6 — the ranking is anchored to ONE run and the drill-in reports over the branch
    # window, so the two can legitimately disagree about whether a test exists. A test ranked here
    # but absent from that window is an ordinary NAMED empty answer — `UnstableTestRuns`' own class
    # comment calls it one — and not a 404 or a blank panel.
    #
    # The two windows are pulled apart with `?branch=`: the ranking follows the newest run whatever
    # branch it is on, while the trajectory is the branch the reader asked for.
    # @intent: {"entity": "GET /repositories/:id", "action": "render named empty state", "behavior": "asking under ?branch=main for a test only the release branch ran returns 200 with the history panel's named empty state quoting that test", "layer": "request"}
    it "renders the named empty state for a test outside the trajectory window" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: other_test, duration: 1.0, line_number: 1)],
             commit_sha: "aaaa1111bbbb2222", branch: "main")
      release_only = "Release smoke walks the checkout"
      ingest(repository, [example_spec(name: release_only, duration: 9.0, line_number: 5)],
             commit_sha: "cccc3333dddd4444", branch: "release")

      get repository_path(repository, branch: "main", unstable_test: release_only)

      expect(response).to have_http_status(:ok)
      expect(history_panel?).to be(true)
      # Named back rather than silently empty: the reader asked for a test and is told about THAT
      # test, which is what stops the empty panel reading as a broken one.
      expect(history_panel.find("#unstable-test-runs-none")).to have_text(release_only)
    end

    # ⭐ CRITERION 7 — this is a CALLER, not a read. The link costs the page nothing when nobody
    # follows it, and exactly one read of this table when somebody has. Pinned with
    # `queries_against` the way the budget at the foot of this file is, and as an ABSOLUTE pair
    # rather than a difference alone: equality against a control would still hold if both pages
    # regressed together.
    #
    # Ten is the page's standing budget with no test asked for — the same figure
    # "costs the same number of queries at 200 examples as at 3" pins, where every one of the ten
    # is accounted for. The ELEVENTH is `SpecObservation.outcome_sequence_in`, bounded by one
    # description's rows over the window rather than by the size of the suite.
    # @intent: {"entity": "GET /repositories/:id", "action": "price history read", "behavior": "the page with ?unstable_test= issues exactly one more spec_observations query than the same page without the ask, which still renders the test", "layer": "request"}
    it "costs nothing when no test is asked for and exactly one read when one is" do
      repository = two_run_repository

      get repository_path(repository)
      unasked = queries_against("spec_observations") { get repository_path(repository) }
      get repository_path(repository, unstable_test: slow_test)
      asked = queries_against("spec_observations") do
        get repository_path(repository, unstable_test: slow_test)
      end

      expect(asked.size).to eq(unasked.size + 1)
      expect(history_panel).to have_text(slow_test)
    end
  end

  # The outcome half of the panel — the read this slice adds. `spec_observations.outcome` is
  # written on every example row of every ingest and was, until now, read by nothing: the page
  # ranked ten wall clocks and could not say whether any of them passed. `#slowest_in` still does
  # not filter on outcome and must not — a failed example that burned sixty seconds spent that time
  # — so the whole job here is that the reader can tell the run's most expensive test from its most
  # broken one.
  describe "what the ranked examples reported" do
    def outcome_run(specs)
      repository = create_repository(user: @user)
      ingest(repository, specs)
      get repository_path(repository)
    end

    # @intent: {"entity": "GET /repositories/:id", "action": "report outcomes", "behavior": "the three ranked rows print failed, pending and passed verbatim in rank order", "layer": "request"}
    it "reports each ranked example's outcome, in the word CI sent" do
      outcome_run([example_spec(name: "blew up", duration: 9.0, line_number: 1, outcome: "failed"),
                   example_spec(name: "skipped", duration: 5.0, line_number: 2, outcome: "pending"),
                   example_spec(name: "fine", duration: 1.0, line_number: 3, outcome: "passed")])

      expect(rows.map { |row| row[:outcome] }).to eq(%w[failed pending passed])
    end

    # THE row this column exists for. `outcome` is nullable — the client sends
    # `result&.status&.to_s`, so an example that never ran carries none — and a blank cell, or one
    # silently wearing a pass's colour, is "the client said nothing" made byte-identical to "this
    # test passed" at the head of a list of the suite's slowest tests.
    # @intent: {"entity": "GET /repositories/:id", "action": "render missing outcome", "behavior": "a nil-outcome row reads not reported in the secondary text tone, distinct from the passed row's success tone", "layer": "request"}
    it "reads a row with no outcome as not-reported, and not in the colour a pass wears" do
      outcome_run([example_spec(name: "silent", duration: 9.0, line_number: 1, outcome: nil),
                   example_spec(name: "fine", duration: 1.0, line_number: 2, outcome: "passed")])

      silent, passed = rows

      expect(silent[:outcome]).to eq("not reported")
      expect(silent[:outcome_class]).not_to eq(passed[:outcome_class])
      # Named tokens, not merely "different": a nil must not land on the success tone, and the
      # difference between two rows would survive it landing on any other colour at all.
      expect(silent[:outcome_class]).to include("text-app-content-secondary")
      expect(passed[:outcome_class]).to include("text-app-success")
    end

    # @intent: {"entity": "GET /repositories/:id", "action": "colour failure", "behavior": "a failed row's outcome span carries the text-app-error class", "layer": "request"}
    it "colours a failure as a failure rather than leaving it to be read" do
      outcome_run([example_spec(name: "blew up", duration: 9.0, line_number: 1, outcome: "failed")])

      expect(rows.first[:outcome_class]).to include("text-app-error")
    end

    # Nothing platform-side validates this string — `Ingest::Payload` does not — so an
    # unrecognised value is echoed and left uncoloured rather than folded into a pass.
    # @intent: {"entity": "GET /repositories/:id", "action": "echo unknown outcome", "behavior": "an aborted outcome is echoed verbatim with no success colouring on the row", "layer": "request"}
    it "echoes an outcome it does not recognise without colouring it as a pass" do
      outcome_run([example_spec(name: "odd", duration: 9.0, line_number: 1, outcome: "aborted")])

      expect(rows.first[:outcome]).to eq("aborted")
      expect(rows.first[:outcome_class]).not_to include("text-app-success")
    end

    # One grain up: nothing on this page said whether the latest run was red, so every figure the
    # panel prints was computed off a run that may have aborted a third of the way through.
    # Counted off the rows THIS RUN wrote, never off `TestRun#total_specs_count`.
    # @intent: {"entity": "GET /repositories/:id", "action": "count outcome totals", "behavior": "the basis line reads Every one of the 4 examples this run recorded reported an outcome with 1 failed and 1 pending", "layer": "request"}
    it "states how many of the rows it recorded reported failed and pending" do
      outcome_run([example_spec(name: "one", duration: 9.0, line_number: 1, outcome: "failed"),
                   example_spec(name: "two", duration: 5.0, line_number: 2, outcome: "pending"),
                   example_spec(name: "three", duration: 3.0, line_number: 3, outcome: "passed"),
                   example_spec(name: "four", duration: 1.0, line_number: 4, outcome: "passed")])

      expect(basis_line).to have_text("Every one of the 4 examples this run recorded reported an " \
                                      "outcome: 1 failed, 1 pending", normalize_ws: true)
    end

    # The remainder is stated as neither of the two counted names and specifically not as a pass.
    # Nothing validates the string, so "2 passed" would be a verdict over a value nobody checked.
    # The `0 pending` here is an HONEST zero and is printed: it sits on a run that DID report
    # outcomes, so it counts pendings rather than silence — which is the distinction the
    # no-outcomes example below turns on.
    # @intent: {"entity": "GET /repositories/:id", "action": "word remainder", "behavior": "the basis line prints 1 failed, 0 pending, and 2 reported something other than either, and never the words 2 passed", "layer": "request"}
    it "words the remainder as something other than failed or pending, never as passes" do
      outcome_run([example_spec(name: "one", duration: 9.0, line_number: 1, outcome: "failed"),
                   example_spec(name: "two", duration: 3.0, line_number: 2, outcome: "passed"),
                   example_spec(name: "three", duration: 1.0, line_number: 3, outcome: "passed")])

      expect(basis_line).to have_text("1 failed, 0 pending, and 2 reported something other than either",
                                      normalize_ws: true)
      expect(basis_line).to have_no_text("2 passed")
    end

    # @intent: {"entity": "GET /repositories/:id", "action": "separate silent rows", "behavior": "the basis line separates 1 of the 3 examples reporting an outcome (1 failed, 0 pending) from the other 2 that reported none", "layer": "request"}
    it "counts the rows that said nothing separately from the ones that did" do
      outcome_run([example_spec(name: "one", duration: 9.0, line_number: 1, outcome: "failed"),
                   example_spec(name: "two", duration: 3.0, line_number: 2, outcome: nil),
                   example_spec(name: "three", duration: 1.0, line_number: 3, outcome: nil)])

      expect(basis_line).to have_text("1 of the 3 examples this run recorded reported an outcome: " \
                                      "1 failed and 0 pending. The other 2 reported none.",
                                      normalize_ws: true)
    end

    # VACUOUS GREEN, refused explicitly. A run whose every row carries a nil outcome has a
    # legitimate `failed_count` of 0 — and printing that zero renders "this run said nothing" in
    # the words of "everything passed". The count must not appear at all on such a run.
    # @intent: {"entity": "GET /repositories/:id", "action": "refuse vacuous green", "behavior": "an all-nil run prints Not one of the 2 examples this run recorded reported an outcome, no 0 failed string, and both rows read not reported", "layer": "request"}
    it "says a run that reported no outcome at all did not say, rather than printing zero failures" do
      outcome_run([example_spec(name: "one", duration: 9.0, line_number: 1, outcome: nil),
                   example_spec(name: "two", duration: 1.0, line_number: 2, outcome: nil)])

      expect(basis_line).to have_text("Not one of the 2 examples this run recorded reported an " \
                                      "outcome", normalize_ws: true)
      expect(basis_line).to have_no_text("0 failed")
      expect(rows.map { |row| row[:outcome] }).to eq(["not reported", "not reported"])
    end

    # The denominator is the rows this run wrote here, never the Overview's suite size.
    # @intent: {"entity": "GET /repositories/:id", "action": "count own rows", "behavior": "with total_specs_count 4000 the basis line counts the 1 recorded row (1 failed) and never prints 4,000", "layer": "request"}
    it "counts outcomes off its own rows rather than the run's suite size" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: "one", duration: 1.0, line_number: 1, outcome: "failed")],
             total_specs_count: 4_000)

      get repository_path(repository)

      expect(basis_line).to have_text("Every one of the 1 example this run recorded reported an " \
                                      "outcome: 1 failed", normalize_ws: true)
      expect(basis_line).to have_no_text("4,000")
    end
  end

  # THE hazard this slice exists to refuse. `duration_seconds` is nullable by design, and
  # `duration_seconds: :desc` is NULLS FIRST in Postgres — so the naive ranking does not merely
  # include the example that never ran, it names it as the slowest test in the suite.
  describe "a run mixing timed and untimed examples" do
    def mixed_run
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: "never ran", duration: nil, line_number: 1),
                          example_spec(name: "also never ran", duration: nil, line_number: 2),
                          example_spec(name: "slow one", duration: 8.0, line_number: 3),
                          example_spec(name: "quick one", duration: 0.25, line_number: 4)])
      repository
    end

    # Both halves are asserted because they fail differently: an ordering fixed to `NULLS LAST`
    # with no exclusion passes "not at the head" and still lists the untimed rows at the bottom of
    # a list captioned "slowest", where they read as the fastest tests in the suite.
    # @intent: {"entity": "GET /repositories/:id", "action": "exclude untimed examples", "behavior": "a run mixing 2 untimed with 2 timed examples lists only slow one and quick one, headed by the 8.0s row", "layer": "request"}
    it "leaves the untimed examples out, and specifically not at the head of the list" do
      get repository_path(mixed_run)

      expect(row_labels.first).to eq("slow one")
      expect(row_labels).to eq(["slow one", "quick one"])
    end

    # The panel states what it ranked over, because ten rows print identically whether they are the
    # worst of everything or the worst of half of it.
    # @intent: {"entity": "GET /repositories/:id", "action": "state ranked coverage", "behavior": "the basis line reads Ranked over the 2 of 4 examples this run recorded that reported a duration, and that the 2 reporting none stayed out of the ranking", "layer": "request"}
    it "states its coverage against the rows it ranked, and says what it excluded" do
      get repository_path(mixed_run)

      expect(basis_line).to have_text("Ranked over the 2 of 4 examples this run recorded that reported " \
                                      "a duration; 2 reported none and stayed out of the ranking",
                                      normalize_ws: true)
    end

    # The denominator is the rows this run wrote here, never the Overview's suite size — that
    # figure is re-derived by SUM over shard reports and the two can legitimately differ.
    # @intent: {"entity": "GET /repositories/:id", "action": "rank over own rows", "behavior": "with total_specs_count 4000 the basis line reads Ranked over the 1 of 2 examples and never prints 4,000", "layer": "request"}
    it "counts the rows it ranked rather than the run's own suite size" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: "one", duration: 1.0, line_number: 1),
                          example_spec(name: "two", duration: nil, line_number: 2)],
             total_specs_count: 4_000)

      get repository_path(repository)

      expect(basis_line).to have_text("Ranked over the 1 of 2 examples", normalize_ws: true)
      expect(basis_line).to have_no_text("4,000")
    end
  end

  describe "a run that recorded examples and timed none of them" do
    # @intent: {"entity": "GET /repositories/:id", "action": "render no-timings empty state", "behavior": "an all-untimed run prints No timings on this run recording 2 examples and a duration for none of them, with no table rows and no 0.00s", "layer": "request"}
    it "renders an empty state rather than a list of zeroes" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: "never ran", duration: nil, line_number: 1),
                          example_spec(name: "also never ran", duration: nil, line_number: 2)])

      get repository_path(repository)

      expect(panel).to have_text("No timings on this run", normalize_ws: true)
      expect(panel).to have_text("recorded 2 examples and a duration for none of them",
                                 normalize_ws: true)
      # A zero here would be the panel inventing the measurement it is missing.
      expect(panel).to have_no_css("tbody tr")
      expect(panel).to have_no_text("0.00s")
    end

    # The composition appears in THIS branch too, deliberately. There is no ranking here and so no
    # Outcome column, but "nothing was timed" is a fact about durations and says nothing whatever
    # about how those examples ended — and a delivery carrying no timings and a failure is exactly
    # the run that would otherwise disclose nothing at all.
    # @intent: {"entity": "GET /repositories/:id", "action": "report outcomes untimed", "behavior": "the untimed panel still prints Every one of the 2 examples this run recorded reported an outcome with 1 failed and 0 pending", "layer": "request"}
    it "still says what those examples reported, having nothing to rank them by" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: "never ran", duration: nil, line_number: 1, outcome: "failed"),
                          example_spec(name: "nor this", duration: nil, line_number: 2, outcome: "passed")])

      get repository_path(repository)

      expect(panel).to have_text("Every one of the 2 examples this run recorded reported an " \
                                 "outcome: 1 failed, 0 pending", normalize_ws: true)
    end

    # And the same Vacuous Green refusal as the ranked branch: no timings AND no outcomes is a run
    # that said nothing, not a run with no failures.
    # @intent: {"entity": "GET /repositories/:id", "action": "refuse untimed vacuous green", "behavior": "with no timings and no outcomes the panel prints Not one of the 2 examples this run recorded reported an outcome and never 0 failed", "layer": "request"}
    it "does not print a zero failure count where those examples reported no outcome either" do
      repository = create_repository(user: @user)
      ingest(repository, [example_spec(name: "never ran", duration: nil, line_number: 1, outcome: nil),
                          example_spec(name: "nor this", duration: nil, line_number: 2, outcome: nil)])

      get repository_path(repository)

      expect(panel).to have_text("Not one of the 2 examples this run recorded reported an outcome",
                                 normalize_ws: true)
      expect(panel).to have_no_text("0 failed")
    end
  end

  # A run with no per-example rows at all — everything ingested before those rows existed, and
  # every client that sends no per-example detail. There is no per-test grain to disclose, and an
  # empty panel on every such run would read as a finding about the suite when it is a fact about
  # the payload. The Overview's never-ingested empty state is this page's one statement of absence.
  describe "a run with nothing at this grain" do
    # @intent: {"entity": "GET /repositories/:id", "action": "omit panel without examples", "behavior": "a run with total_specs_count 900 and no example rows returns 200 with no #slowest-examples panel on the page", "layer": "request"}
    it "renders no panel for a run that recorded no examples" do
      repository = create_repository(user: @user)
      create_test_run(repository: repository, total_specs_count: 900)

      get repository_path(repository)

      expect(response).to have_http_status(:ok)
      expect(panel?).to be(false)
    end

    # @intent: {"entity": "GET /repositories/:id", "action": "omit panel without runs", "behavior": "a repository CI has never reported for returns 200 with no #slowest-examples panel on the page", "layer": "request"}
    it "renders no panel for a repository CI has never reported for" do
      get repository_path(create_repository(user: @user))

      expect(response).to have_http_status(:ok)
      expect(panel?).to be(false)
    end
  end

  # The whole point of ranking in SQL against the composite index is that the page costs the same
  # on a 20,000-example suite as on a 20-example one. A `has_many` walked in the view is exactly
  # the shape that ships green on a three-row fixture and takes the page down on a real suite.
  describe "what the panel costs" do
    # `queries_against` comes from spec/support/query_capture.rb.

    # @intent: {"entity": "GET /repositories/:id", "action": "hold page query budget", "behavior": "pages over a 3-row and a 200-row suite issue equal spec_observations query counts, with the larger page pinned at exactly 12", "layer": "request"}
    it "costs the same number of queries at 200 examples as at 3" do
      small = create_repository(user: @user, github_full_name: "acme/small-suite")
      ingest(small, (1..3).map { |i| example_spec(name: "small #{i}", duration: i.to_f, line_number: i) })
      large = create_repository(user: @user, github_full_name: "acme/large-suite")
      ingest(large, (1..200).map { |i| example_spec(name: "large #{i}", duration: i.to_f, line_number: i) },
             commit_sha: "feedfacecafe0002")

      small_queries = queries_against("spec_observations") { get repository_path(small) }
      large_queries = queries_against("spec_observations") { get repository_path(large) }

      # Both pages render the panel — the large one renders a full ten rows — and cost the same.
      expect(rows.size).to eq(SpecObservation::SLOWEST_LIMIT)
      expect(large_queries.size).to eq(small_queries.size)
      # An absolute ceiling too: equality alone would still hold if both pages regressed to a
      # fixed-but-wasteful number of passes over the same table. This panel is two of these — one
      # ranking, one aggregate — and the other two are the rollup panels below it: the "Heaviest
      # spec files" grouped read and the "Heaviest spec directories" one that takes the same rows
      # up to the code area. Both of those budgets are asserted in
      # spec/requests/repository_spec_file_durations_spec.rb. The fifth is the cross-run panel's
      # gating probe, which on this single-run fixture establishes that outcomes cannot be compared
      # and asks nothing further; its own budget is asserted in
      # spec/requests/repository_unstable_tests_spec.rb.
      #
      # RECOUNTED AT 7 by SPGD-344, which added the "Descriptions this run recorded more than once"
      # panel: TWO further reads of this table, both over this same run's rows. The first groups
      # them by DESCRIPTION — a grain no panel on this page could reach, since the only two
      # `GROUP BY name` reads in the application are narrowed to failures — and the second counts
      # the rows that carry no description, which the first has to exclude in its WHERE clause and
      # therefore cannot count for itself. Its own budget, including that the two stay two as the
      # number of repeated descriptions grows, is asserted in
      # spec/requests/repository_repeated_descriptions_spec.rb.
      # RECOUNTED AT 8 by SPGD-649, which added the by-area annotation panel: ONE
      # further read of this table, the same run's rows grouped by AREA on the ANNOTATION axis. It
      # is not the by-directory rollup counted above under another name — that one groups the
      # identical population and ranks it by WALL CLOCK, so neither ranking can be read off the
      # other. Its own budget, and that it stays one read as the number of areas grows, is asserted
      # in spec/requests/repository_unannotated_directories_spec.rb.
      # RECOUNTED AT 9 by SPGD-728, which added the "Slowest tests across the window" panel:
      # ONE further read, and it is that panel's GATING PROBE — the row/unresolved-row count over
      # the newest run of the branch window, asked before either of the two steps behind it. The
      # fixtures in this file never run `Ingest::IdentityResolver`, which is what an ingest endpoint
      # answers `202` and enqueues a job for, so every row here carries a NULL `spec_identity_id`,
      # the gate reports nothing resolved and the panel stops: one read, not three. A page whose
      # window HAS been resolved pays three, and that budget — a gate, a capped candidate step over
      # one run, and a composition over those candidates only — is asserted in
      # spec/requests/repository_window_slowest_tests_spec.rb. The added read moves with neither
      # the size of the suite nor the length of the window, since it counts one run's rows.
      # RECOUNTED AT 10 by SPGD-711, which added the run's INTENT READINGS: ONE further read of
      # this table, an ungated aggregate over the same run's rows splitting them into authored,
      # derived and unreadable. It is not the by-area annotation read counted above under another
      # name — that one GROUPS and ranks, this one does neither, and it answers the Overview's own
      # sentence rather than a panel's list. Ungated unlike every drill-in on this page, because a
      # correction a client has to opt into leaves the Overview printing the subtraction it replaced.
      # Its own budget is asserted in spec/requests/api/v1/repository_intent_readings_spec.rb.
      # RECOUNTED AT 12 by SPGD-758: this file's fixtures now resolve identities inline (the
      # flakiness panel on this page groups on the durable identity, so an unresolved row is an
      # exclusion there rather than a key), which passes the window slowest-tests panel's resolver
      # gate and pays its candidate and composition reads where these fixtures used to stop it at
      # the gate. The flakiness panel itself still costs its one gating probe here — this file's
      # examples report no outcomes, so its window is incomparable and it stops there.
      # Page-wide rather than panel-scoped on purpose: what must not grow is the number of times
      # ONE page walks this table, and only a count taken across the whole request can say that.
      expect(large_queries.size).to eq(12)
    end
  end

  # The paragraph one section up on this page used to declare this question unanswerable, in a
  # comment addressed to future authors. The rows it said did not exist are what this panel reads,
  # so the claim has to go — a stale disclosure is a live instruction not to build the thing that
  # is now built. What it must NOT lose is the rule the claim was there to justify: the shard prose
  # still may not imply a per-test fact.
  describe "the shard prose the panel sits below" do
    # @intent: {"entity": "GET /repositories/:id", "action": "retire stale claim", "behavior": "the show template no longer contains the stays-unanswerable claim or the no-schema-records sentence while still stating About SHARDS, never about tests", "layer": "request"}
    it "no longer tells its authors the schema cannot answer which tests are slow" do
      source = Rails.root.join("app/views/repositories/show.html.erb").read

      expect(source).not_to include("stays unanswerable")
      expect(source).not_to include("Nothing in the schema records how long any single")
      # The rule the retired claim existed to justify is still stated.
      expect(source).to include("About SHARDS, never about tests")
    end
  end
end
