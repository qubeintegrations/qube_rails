# frozen_string_literal: true

# A connection's links after a company file change: stale and unused, then checked against the
# new file once it's connected again.
RSpec.describe QubeRails::LinkCheck do
  let(:account) { Account.create!(name: "Riverbend") }
  let(:connection) { make_connection(account, status: "pending") }
  let(:riverbend) { Customer.create!(account: account, name: "Riverbend Electric") }
  let(:northwind) { Customer.create!(account: account, name: "Northwind Builders") }
  let(:invoice) { Invoice.create!(account: account, number: "1001") }
  let(:customers_url) { %r{\A#{Regexp.escape(api_url("/connections/#{connection.qube_id}/customers"))}\?} }
  let(:invoices_url) { %r{\A#{Regexp.escape(api_url("/connections/#{connection.qube_id}/invoices"))}\?} }

  def run_event(name, changes = {})
    QubeRails::WebhookJob.new.perform("connection", connection.id.to_s, vector_body(name, changes))
    connection.reload
  end

  # The answer QuBe Sync sends a check: data, and the 500 warning QuickBooks gives for an id it lacks.
  def answer(row, data, warning: false, page_request_id: "pr-#{row.id}")
    json = { "status" => "success", "data" => data }
    json["warning"] = { "code" => 500, "message" => "could not be found" } if warning
    body = vector_body("request: an answer", "id" => row.qube_id, "page_request_id" => page_request_id,
                                             "page" => 1, "iteration_state" => "not_applicable",
                                             "state" => "response_received", "response_json" => json)
    QubeRails::WebhookJob.new.perform("request", row.id.to_s, body)
  end

  def checks(kind)
    QubeRails::QueuedRequest.where(connection: connection, operation: "qube_rails.check_links:#{kind}").order(:id)
  end

  def stub_queue(url)
    count = 0
    stub_request(:get, url).to_return { json_data("id" => "check-q-#{count += 1}", "state" => "queued") }
  end

  before do
    # A check from before a switch, asked about before another is queued: QuBe Sync failed it.
    stub_request(:get, %r{/queued-requests/[^/]+\z})
      .to_return(json_data("state" => "error", "error" => { "error_type" => "company_file_changed" }))
    run_event("connection.connected") # revision 1
    connection.link(riverbend, kind: "customer", qb_id: "80000024-1760999990", edit_sequence: "100",
                               name: "Riverbend Electric")
    connection.link(northwind, kind: "customer", qb_id: "80000025-1760999991", edit_sequence: "200",
                               name: "Northwind Builders")
    connection.link(invoice, kind: "invoice", qb_id: "1A-1760999990", edit_sequence: "300", name: "1001")
    run_event("connection.company_file_changed") # revision 5
    QuickbooksDesktop::ConnectionEvents.calls.clear
  end

  it "queues nothing while it's set up again, then a check per kind by ListID and TxnID on connected" do
    expect(a_request(:get, /qube\.example/)).not_to have_been_made

    customers = stub_queue(customers_url)
    invoices = stub_queue(invoices_url)
    run_event("connection.connected", "revision" => 6)

    expect(customers).to have_been_made.once
    expect(invoices).to have_been_made.once
    expect(checks("customer").first).to have_attributes(
      record: connection, qube_id: "check-q-1", state: "queued",
      params: { "list_id" => %w[80000024-1760999990 80000025-1760999991] }
    )
    expect(checks("invoice").first.params).to eq("txn_id" => %w[1A-1760999990])
  end

  it "queues nothing on a connected with nothing stale, and nothing again while a check is going" do
    other = make_connection(account, qube_id: "conn-q-2")
    QubeRails::WebhookJob.new.perform("connection", other.id.to_s,
                                      vector_body("connection.connected", "connection" => { "id" => "conn-q-2" },
                                                                          "revision" => 9))
    expect(a_request(:get, /qube\.example/)).not_to have_been_made

    stub_queue(customers_url)
    stub_queue(invoices_url)
    run_event("connection.connected", "revision" => 6)
    run_event("connection.connected", "revision" => 6) # retried
    run_event("connection.resumed", "revision" => 7)

    expect(a_request(:get, customers_url)).to have_been_made.once
    expect(checks("customer").count).to eq(1)
  end

  describe "an answer" do
    let(:riverbend_found) do
      { "list_id" => "80000024-1760999990", "full_name" => "Riverbend Electric", "edit_sequence" => "777" }
    end

    before do
      stub_queue(customers_url)
      stub_queue(invoices_url)
      run_event("connection.connected", "revision" => 6)
      QuickbooksDesktop::ConnectionEvents.calls.clear
    end

    it "keeps an id found with the same name, ignoring case and spacing, with its new EditSequence" do
      answer(checks("customer").first, [
        riverbend_found.merge("full_name" => " riverbend  ELECTRIC"),
        { "list_id" => "80000025-1760999991", "full_name" => "Northwind Builders", "edit_sequence" => "888" }
      ])

      expect(connection.qb_id_for(riverbend, kind: "customer")).to eq("80000024-1760999990")
      expect(connection.quickbooks_record("80000025-1760999991", kind: "customer"))
        .to have_attributes(edit_sequence: "888", name: "Northwind Builders")
      expect(QuickbooksDesktop::ConnectionEvents.calls).to eq([
        [:links_checked, "customer", 2, %w[80000024-1760999990 80000025-1760999991], [], [], 1]
      ])
    end

    it "holds an id found under another name for review: unused, reported, and its record waits" do
      connection.update!(connection_type: "realtime")
      answer(checks("customer").first, [
        riverbend_found,
        { "list_id" => "80000025-1760999991", "full_name" => "Northwind Ltd", "edit_sequence" => "888" }
      ])

      link = QubeRails::QuickbooksRecord.find_by(qb_id: "80000025-1760999991")
      expect(link).to have_attributes(review_name: "Northwind Ltd", name: "Northwind Builders")
      expect(link).to be_under_review
      expect(connection.qb_id_for(northwind, kind: "customer")).to be_nil
      expect(connection.find_linked("80000025-1760999991", kind: "customer")).to be_nil
      expect(connection.in_quickbooks(Customer.all)).to eq([riverbend])
      expect(QuickbooksDesktop::ConnectionEvents.calls).to eq([
        [:links_checked, "customer", 2, %w[80000024-1760999990], [[northwind.id, "Northwind Builders", "Northwind Ltd"]],
         [], 1]
      ])
      expect { QuickbooksDesktop::FindCustomer.queue(northwind, connection) }
        .to raise_error(QubeRails::LinkNeedsReview, /confirm_link or reject_link/)
    end

    it "confirms a link under review (current, with QuickBooks' name), or rejects it (missing)" do
      answer(checks("customer").first, [
        riverbend_found.merge("full_name" => "Riverbend Electric Co"),
        { "list_id" => "80000025-1760999991", "full_name" => "Northwind Ltd", "edit_sequence" => "888" }
      ])
      riverbend_link, northwind_link = connection.review_links.order(:qb_id).to_a

      connection.confirm_link(riverbend_link)
      expect(connection.quickbooks_record("80000024-1760999990", kind: "customer"))
        .to have_attributes(name: "Riverbend Electric Co", edit_sequence: "777", review_name: nil)
      expect(connection.link_under_review?(riverbend)).to be(false)

      connection.reject_link(northwind_link.id)
      expect(northwind_link.reload).to be_missing
      expect(connection.qb_id_for(northwind, kind: "customer")).to be_nil
      expect(connection.link_under_review?(northwind)).to be(false)

      expect { connection.confirm_link(northwind_link) }.to raise_error(ArgumentError, /isn't under review/)
    end

    it "keeps an id found when the link was kept without a name, and checks a review link again on the next switch" do
      connection.quickbooks_records.find_by(qb_id: "80000024-1760999990").update!(name: nil)
      answer(checks("customer").first, [
        riverbend_found.merge("full_name" => "Anything"),
        { "list_id" => "80000025-1760999991", "full_name" => "Northwind Ltd" }
      ])
      expect(connection.qb_id_for(riverbend, kind: "customer")).to eq("80000024-1760999990")
      link = QubeRails::QuickbooksRecord.find_by(qb_id: "80000025-1760999991")
      expect(link).to be_under_review

      run_event("connection.company_file_changed", "revision" => 7)
      expect(link.reload).to have_attributes(review_since: nil, review_name: nil)
      expect(link).to be_stale
    end

    it "keeps a transaction QuickBooks doesn't have as missing: unused, reported, and checked again on the next switch" do
      answer(checks("invoice").first, [], warning: true)

      link = QubeRails::QuickbooksRecord.find_by(qb_id: "1A-1760999990")
      expect(link).to be_missing
      expect(link).not_to be_stale
      expect(connection.qb_id_for(invoice, kind: "invoice")).to be_nil
      expect(connection.in_quickbooks(Invoice.all)).to be_empty
      expect(connection.checking_link?(invoice)).to be(false)
      expect(QuickbooksDesktop::ConnectionEvents.calls).to eq([[:links_checked, "invoice", 0, [], [], [invoice.id], 2]])

      run_event("connection.company_file_changed", "revision" => 7)
      expect(link.reload).to have_attributes(missing_since: nil)
      expect(link).to be_stale
    end

    it "gives a customer who switches back to the old file their links back" do
      answer(checks("customer").first, [], warning: true)
      expect(connection.missing_links.count).to eq(2)

      run_event("connection.company_file_changed", "revision" => 7)
      run_event("connection.connected", "revision" => 8)
      answer(checks("customer").last, [riverbend_found,
                                       { "list_id" => "80000025-1760999991", "full_name" => "Northwind Builders" }])

      expect(connection.qb_id_for(riverbend, kind: "customer")).to eq("80000024-1760999990")
      expect(connection.qb_id_for(northwind, kind: "customer")).to eq("80000025-1760999991")
      expect(connection.missing_links.where(kind: "customer")).to be_empty
    end

    # QuickBooks, 2026-11-27: a 500 warning names only the first missing id, and every id it has
    # still comes back (docs/quickbooks-findings in qube).
    it "keeps the ids a 500 answer returns and calls the rest missing, in one request" do
      answer(checks("customer").first, [riverbend_found], warning: true)

      expect(connection.qb_id_for(riverbend, kind: "customer")).to eq("80000024-1760999990")
      expect(QubeRails::QuickbooksRecord.find_by(qb_id: "80000025-1760999991")).to be_missing
      expect(checks("customer").count).to eq(1) # nothing stale left of the kind
    end

    it "calls every id missing when a 500 answer returns none of them" do
      answer(checks("customer").first, [], warning: true)

      expect(connection.stale_links.where(kind: "customer")).to be_empty
      expect(connection.missing_links.where(kind: "customer").pluck(:qb_id))
        .to contain_exactly("80000024-1760999990", "80000025-1760999991")
    end

    it "settles nothing from an answer with a row it didn't ask for, or an odd shape" do
      answer(checks("customer").first, [riverbend_found, { "list_id" => "8000FFFF-1", "full_name" => "Who" }])
      answer(checks("customer").first, { "list_id" => "80000024-1760999990" }, page_request_id: "pr-odd")

      expect(connection.stale_links.where(kind: "customer").count).to eq(2)
      expect(connection.missing_links).to be_empty
      expect(QuickbooksDesktop::ConnectionEvents.calls).to be_empty
      expect(checks("customer").count).to eq(1)
      expect(log_output).to include("customer link check answered unexpectedly; nothing settled")
    end

    it "is safe to deliver twice, and leaves a link a run linked since alone" do
      row = checks("customer").first
      connection.link(northwind, kind: "customer", qb_id: "80000099-1761000500", name: "Northwind Builders")
      answer(row, [riverbend_found])
      answer(row, [riverbend_found])

      expect(connection.qb_id_for(northwind, kind: "customer")).to eq("80000099-1761000500")
      expect(connection.qb_id_for(riverbend, kind: "customer")).to eq("80000024-1760999990")
      expect(QuickbooksDesktop::ConnectionEvents.calls.size).to eq(1)
    end

    it "queues the next batch when a kind has more than one" do
      stub_const("QubeRails::LinkCheck::BATCH", 1)
      QubeRails::QueuedRequest.delete_all
      connection.check_stale_links
      expect(checks("customer").first.params).to eq("list_id" => ["80000024-1760999990"])

      answer(checks("customer").first, [riverbend_found])

      expect(checks("customer").last.params).to eq("list_id" => ["80000025-1760999991"])
    end

    it "settles nothing from an answer to a check queued before the file changed again, and asks the new file" do
      row = checks("customer").first
      travel(1.second) do
        run_event("connection.company_file_changed", "revision" => 7)
        run_event("connection.connected", "revision" => 8)
        # The old one is ended once QuBe Sync says so, not reused, and the new file is asked at once.
        expect(checks("customer").count).to eq(2)
        expect(row.reload).to have_attributes(state: "error", error: { "error_type" => "company_file_changed" })

        answer(row, [riverbend_found])
        expect(connection.stale_links.where(kind: "customer").count).to eq(2)
        expect(QuickbooksDesktop::ConnectionEvents.calls.map(&:first)).not_to include(:links_checked)
        expect(log_output).to include("was queued before its company file changed; nothing settled")

        expect(checks("customer").count).to eq(2)
        answer(checks("customer").last, [riverbend_found])
        expect(connection.qb_id_for(riverbend, kind: "customer")).to eq("80000024-1760999990")
      end
    end

    it "queues a failed check again when a held record is sent, once RETRY_AFTER has passed" do
      connection.update!(connection_type: "realtime")
      row = checks("invoice").first
      QubeRails::WebhookJob.new.perform("request", row.id.to_s,
                                        vector_body("request: QuickBooks refused it", "id" => row.qube_id))

      expect { QuickbooksDesktop::CreateInvoice.start(invoice, connection) }.to raise_error(QubeRails::LinkBeingChecked)
      expect(checks("invoice").count).to eq(1) # too soon

      travel(QubeRails::LinkCheck::RETRY_AFTER + 1) do
        2.times do
          expect { QuickbooksDesktop::CreateInvoice.start(invoice, connection) }
            .to raise_error(QubeRails::LinkBeingChecked)
        end
      end
      expect(checks("invoice").count).to eq(2) # the second found it going
      expect(checks("invoice").last).to have_attributes(state: "queued", params: { "txn_id" => %w[1A-1760999990] })
    end

    it "still holds the record when the check can't be queued again, and sends that queue again later" do
      row = checks("invoice").first
      QubeRails::WebhookJob.new.perform("request", row.id.to_s,
                                        vector_body("request: QuickBooks refused it", "id" => row.qube_id))
      stub_request(:get, invoices_url).to_timeout

      travel(QubeRails::LinkCheck::RETRY_AFTER + 1) do
        expect { connection.wait_for_link_check!(invoice, "it") }.to raise_error(QubeRails::LinkBeingChecked)
      end
      expect(log_output).to include("couldn't queue its invoice link check again")
      expect(checks("invoice").last).to have_attributes(qube_id: nil, state: "queued")
      tried = -> { WebMock::RequestRegistry.instance.times_executed(WebMock::RequestPattern.new(:get, invoices_url)) }
      first = tried.call
      travel(2 * (QubeRails::LinkCheck::RETRY_AFTER + 1)) do # that queue, sent again
        expect { connection.wait_for_link_check!(invoice, "it") }.to raise_error(QubeRails::LinkBeingChecked)
      end
      second = tried.call
      expect(second).to be > first
      travel(2 * (QubeRails::LinkCheck::RETRY_AFTER + 1) + 1) do # too soon after that try
        expect { connection.wait_for_link_check!(invoice, "it") }.to raise_error(QubeRails::LinkBeingChecked)
      end
      expect(tried.call).to eq(second)

      stub_queue(invoices_url)
      travel(3 * (QubeRails::LinkCheck::RETRY_AFTER + 1)) do
        expect { connection.wait_for_link_check!(invoice, "it") }.to raise_error(QubeRails::LinkBeingChecked)
      end
      expect(checks("invoice").count).to eq(2)
      expect(checks("invoice").last.qube_id).to eq("check-q-1")
    end

    it "keeps the answer when the next batch can't be queued, and a held record queues it later" do
      stub_const("QubeRails::LinkCheck::BATCH", 1)
      QubeRails::QueuedRequest.delete_all
      connection.check_stale_links
      stub_request(:get, customers_url).to_timeout

      expect { answer(checks("customer").first, [riverbend_found]) }.not_to raise_error
      expect(connection.qb_id_for(riverbend, kind: "customer")).to eq("80000024-1760999990")
      expect(log_output).to include("couldn't queue its next customer link check")

      stub_queue(customers_url)
      travel(QubeRails::LinkCheck::RETRY_AFTER + 1) do
        expect { connection.wait_for_link_check!(northwind, "it") }.to raise_error(QubeRails::LinkBeingChecked)
      end
      expect(checks("customer").last).to have_attributes(qube_id: "check-q-1",
                                                         params: { "list_id" => ["80000025-1760999991"] })
    end

    def refuse(row)
      QubeRails::WebhookJob.new.perform("request", row.id.to_s,
                                        vector_body("request: QuickBooks refused it", "id" => row.qube_id))
    end

    it "keeps a kind's links as missing, and reports them, once MAX_ATTEMPTS checks since the change have failed" do
      (QubeRails::LinkCheck::MAX_ATTEMPTS - 1).times do
        refuse(checks("invoice").last)
        expect(connection.stale_links.where(kind: "invoice").count).to eq(1)
        connection.check_stale_links # the next event, or a held record, asks again
      end
      expect(checks("invoice").count).to eq(QubeRails::LinkCheck::MAX_ATTEMPTS)
      expect(QuickbooksDesktop::ConnectionEvents.calls.map(&:first)).not_to include(:links_checked)

      refuse(checks("invoice").last)

      expect(connection.stale_links.where(kind: "invoice")).to be_empty
      expect(connection.missing_links.where(kind: "invoice").pluck(:qb_id)).to eq(["1A-1760999990"])
      expect(QuickbooksDesktop::ConnectionEvents.calls.map(&:first)).to include(:links_checked)
      expect(log_output).to include("gave up on its invoice link check after #{QubeRails::LinkCheck::MAX_ATTEMPTS}")
      connection.check_stale_links
      expect(checks("invoice").count).to eq(QubeRails::LinkCheck::MAX_ATTEMPTS)
    end

    it "counts an answer it can't trust as a failed check" do
      answer(checks("customer").first, { "list_id" => "80000024-1760999990" })

      expect(checks("customer").first).to have_attributes(state: "failed")
      expect(checks("customer").first.ended_at).not_to be_nil
    end

    it "counts only checks since the last company file change" do
      (QubeRails::LinkCheck::MAX_ATTEMPTS - 1).times do
        refuse(checks("invoice").last)
        connection.check_stale_links
      end
      travel(1.second) do
        run_event("connection.company_file_changed", "revision" => 7)
        run_event("connection.connected", "revision" => 8)
        refuse(checks("invoice").last)
        expect(connection.stale_links.where(kind: "invoice").count).to eq(1)
      end
    end

    it "queues again a check that got no answer for NO_ANSWER_AFTER, when a held record is sent" do
      row = checks("invoice").first

      travel(QubeRails::LinkCheck::RETRY_AFTER + 1) do
        expect { connection.wait_for_link_check!(invoice, "it") }.to raise_error(QubeRails::LinkBeingChecked)
      end
      expect(checks("invoice").count).to eq(1) # it may still be waiting for the Web Connector

      travel(QubeRails::LinkCheck::NO_ANSWER_AFTER + 1) do
        expect { connection.wait_for_link_check!(invoice, "it") }.to raise_error(QubeRails::LinkBeingChecked)
      end
      expect(row.reload).to have_attributes(state: "failed", error: { "error_type" => "no_answer" })
      expect(checks("invoice").count).to eq(2)
      expect(checks("invoice").last).to have_attributes(state: "queued", qube_id: "check-q-2")
    end

    it "counts failures since the kind's last check that answered: a batch that got through starts again" do
      stub_const("QubeRails::LinkCheck::BATCH", 1)
      QubeRails::QueuedRequest.delete_all
      connection.check_stale_links
      (QubeRails::LinkCheck::MAX_ATTEMPTS - 1).times do
        refuse(checks("customer").last)
        connection.check_stale_links
      end
      answer(checks("customer").last, [riverbend_found]) # batch 1 answers; batch 2 goes

      refuse(checks("customer").last)

      expect(connection.stale_links.where(qb_id: "80000025-1760999991").count).to eq(1)
      expect(log_output).not_to include("gave up")
    end

    it "never counts a refused queue as a failed check, but gives up after MAX_ATTEMPTS refusals" do
      refusal = { status: 422, body: '{"errors":"no"}', headers: { "Content-Type" => "application/json" } }
      stub_request(:get, invoices_url).to_return(refusal)
      refuse(checks("invoice").first) # one failed check
      (QubeRails::LinkCheck::MAX_ATTEMPTS - 1).times { connection.check_stale_links }
      expect(checks("invoice").last.error).to eq("error_type" => "refused", "status" => 422)
      expect(connection.stale_links.where(kind: "invoice").count).to eq(1) # 1 failure, 2 refusals

      connection.check_stale_links

      expect(connection.missing_links.where(kind: "invoice").count).to eq(1)
      expect(log_output).to include("gave up on its invoice link check after #{QubeRails::LinkCheck::MAX_ATTEMPTS} refused queues")
    end

    it "reports a late answer to a check failed for no answer, and settles it" do
      row = checks("customer").first
      travel(QubeRails::LinkCheck::NO_ANSWER_AFTER + 1) do
        expect { connection.wait_for_link_check!(riverbend, "it") }.to raise_error(QubeRails::LinkBeingChecked)
        expect(row.reload.state).to eq("failed")

        answer(row, [riverbend_found, { "list_id" => "80000025-1760999991", "full_name" => "Northwind Builders" }])
      end

      expect(connection.stale_links.where(kind: "customer")).to be_empty
      checked = QuickbooksDesktop::ConnectionEvents.calls.select { |call| call.first == :links_checked }
      expect(checked.size).to eq(1)
    end

    it "finds links it gave up on when a later answer from the new file has them" do
      first = checks("customer").first
      QubeRails::LinkCheck::MAX_ATTEMPTS.times do
        refuse(checks("customer").last)
        connection.check_stale_links
      end
      expect(connection.missing_links.where(kind: "customer").count).to eq(2)

      answer(first, [riverbend_found]) # a late answer to the first try

      expect(connection.qb_id_for(riverbend, kind: "customer")).to eq("80000024-1760999990")
      expect(connection.missing_links.where(kind: "customer").pluck(:qb_id)).to eq(["80000025-1760999991"])
    end

    it "gives up on a kind once MAX_ATTEMPTS checks in a row got no answer" do
      wait = QubeRails::LinkCheck::NO_ANSWER_AFTER + 1
      (QubeRails::LinkCheck::MAX_ATTEMPTS - 1).times do |i|
        travel((i + 1) * wait) do
          expect { connection.wait_for_link_check!(invoice, "it") }.to raise_error(QubeRails::LinkBeingChecked)
        end
      end
      # The last no-answer is the third failed try: its links are kept as missing, and the record goes.
      travel(QubeRails::LinkCheck::MAX_ATTEMPTS * wait) do
        expect { connection.wait_for_link_check!(invoice, "it") }.not_to raise_error
      end

      expect(checks("invoice").pluck(:state)).to all(eq("failed"))
      expect(connection.missing_links.where(kind: "invoice").count).to eq(1)
    end

    it "doesn't count time the connection was stalled as no answer" do
      row = checks("invoice").first
      travel(2 * QubeRails::LinkCheck::NO_ANSWER_AFTER) do
        run_event("connection.stalled", "revision" => 7)
        run_event("connection.resumed", "revision" => 8)
      end
      travel(2 * QubeRails::LinkCheck::NO_ANSWER_AFTER + QubeRails::LinkCheck::RETRY_AFTER + 1) do
        expect { connection.wait_for_link_check!(invoice, "it") }.to raise_error(QubeRails::LinkBeingChecked)
      end

      expect(row.reload.state).to eq("queued")
      expect(checks("invoice").count).to eq(1)
    end

    it "leaves the links stale, unused, when the check fails" do
      row = checks("invoice").first
      body = vector_body("request: QuickBooks refused it", "id" => row.qube_id)
      QubeRails::WebhookJob.new.perform("request", row.id.to_s, body)

      expect(connection.stale_links.where(kind: "invoice").count).to eq(1)
      expect(connection.qb_id_for(invoice, kind: "invoice")).to be_nil
    end

    it "holds a start or a request for a record whose link waits for its check, and lets one with no link go" do
      connection.update!(connection_type: "realtime")
      expect { QuickbooksDesktop::CreateInvoice.start(invoice, connection) }
        .to raise_error(QubeRails::LinkBeingChecked, /Invoice #{invoice.id}'s link/)
      expect { QuickbooksDesktop::FindCustomer.queue(riverbend, connection) }.to raise_error(QubeRails::NotReady)
      expect(QubeRails::Run.count).to eq(0)

      answer(checks("invoice").first, [], warning: true) # settled: missing
      stub_request(:post, %r{/workflow-runs}).to_return(json_data("id" => "run-q-1", "state" => "running"))
      expect(QuickbooksDesktop::CreateInvoice.start(invoice, connection)).to be_a(QubeRails::Run)

      other = Invoice.create!(account: account, number: "1002")
      expect(connection.checking_link?(other)).to be(false)
    end
  end

  it "keeps a kind it can't look up by id as missing when the check starts, reports it, and never queries it" do
    acme = Customer.create!(account: account, name: "Acme")
    connection.link(account, kind: "company", qb_id: "C1")
    connection.link(acme, kind: "payment", qb_id: "P1") # a kind the app named itself
    connection.quickbooks_records.update_all(stale_since: Time.now)
    connection.update!(status: "connected")
    stub_queue(customers_url)
    stub_queue(invoices_url)

    expect(QubeRails::LinkCheck.id_param("company")).to be_nil
    expect(QubeRails::LinkCheck.id_param("made_up")).to be_nil
    connection.check_stale_links

    expect(checks("company")).to be_empty
    expect(checks("payment")).to be_empty
    expect(connection.stale_links.where(kind: %w[company payment])).to be_empty
    expect(connection.missing_links.where(kind: %w[company payment]).count).to eq(2)
    expect(connection.checking_link?(acme)).to be(false)
    expect(QuickbooksDesktop::ConnectionEvents.calls).to eq([
      [:links_checked, "company", 0, [], [], [account.id], 4],
      [:links_checked, "payment", 0, [], [], [acme.id], 3]
    ])
    expect(checks("customer").count).to eq(1)
  end

  it "takes which id each kind's query uses from the gem, and its own lists agree with it" do
    index = defined?(QubeSync::Operations::INDEX) ? QubeSync::Operations::INDEX : {}
    queries = index.select { |id, entry| id.end_with?(".query") && entry.key?(:id_param) }
    skip "this qube_sync's Operations::INDEX doesn't say which id a query takes" if queries.empty?

    kinds = ->(param) { queries.select { |_, e| e[:id_param] == param }.keys.map { |id| id.delete_suffix(".query") }.sort }
    expect(QubeRails::LinkCheck::TXN_KINDS.sort).to eq(kinds.call("txn_id"))
    expect(QubeRails::LinkCheck::LIST_KINDS.sort).to eq(kinds.call("list_id"))
    expect(QubeRails::LinkCheck.id_param("invoice")).to eq("txn_id")
    expect(QubeRails::LinkCheck.id_param("item_service")).to eq("list_id")
  end

  it "never sends a stale link's id: an input refers by name, and a run linking it on the new file makes it current" do
    run = make_run(invoice, connection)
    operation = QuickbooksDesktop::CreateInvoice.new(invoice, run)

    expect(operation.quickbooks_ref(riverbend, kind: "customer", name: "Riverbend Electric"))
      .to eq(full_name: "Riverbend Electric")

    connection.link(riverbend, kind: "customer", qb_id: "80000024-1760999990", name: "Riverbend Electric")
    expect(operation.quickbooks_ref(riverbend, kind: "customer")).to eq(list_id: "80000024-1760999990")
    expect(connection.stale_links.where(kind: "customer").count).to eq(1)
  end

  it "leaves another connection's links alone" do
    other = make_connection(account, qube_id: "conn-q-2")
    other.link(riverbend, kind: "customer", qb_id: "80000024-1760999990", name: "Riverbend Electric")
    stub_queue(customers_url)
    stub_queue(invoices_url)
    run_event("connection.connected", "revision" => 6)
    answer(checks("invoice").first, [], warning: true)

    expect(other.qb_id_for(riverbend, kind: "customer")).to eq("80000024-1760999990")
    expect(other.stale_links).to be_empty
    expect(other.missing_links).to be_empty
  end
end
