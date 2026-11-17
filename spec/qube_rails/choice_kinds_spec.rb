# frozen_string_literal: true

# Where each choice of a question shows (QuestionView#picks, #forms, #exits) and which button is
# the one primary action.
RSpec.describe "A question's choices by kind" do
  def question(key)
    prompt = QubeRails::Storyboard.find(key).sample["prompt"]
    QubeRails::QuestionView.new(prompt, action_url: "/q/1", search_url: "/q/1/search")
  end

  def arranged(view)
    view.choices.map { |c| [c.id, c.kind, c.style] }
  end

  def without_roles(key)
    prompt = QubeRails::Storyboard.find(key).sample["prompt"]
    prompt = prompt.merge("choices" => prompt["choices"].map { |c| c.except("role") })
    QubeRails::QuestionView.new(prompt, action_url: "/q/1", search_url: "/q/1/search")
  end

  it "weighs offered records and a decline beside them the same, the search a box under them, cancel last" do
    view = question("near_match")

    expect(view).to be_roles
    expect(view).to be_matches
    # The decline says what it is as a row ("Riverbend", "Add as new"), so it's a row among the
    # records; neither is the main action.
    expect(arranged(view)).to eq([["use:1", :pick, :secondary], ["use", :form, :secondary], ["none", :pick, :secondary],
                                  ["cancel", :exit, :ghost]])
    expect(view.picks.map { |c| [c.id, c.role, c.slot?] }).to eq([["use:1", "pick", false], ["use", "search", true],
                                                                  ["none", "decline", false]])
    expect([view.searches, view.forms, view.alongside, view.disclosed, view.exits].map { |l| l.map(&:id) })
      .to eq([%w[use], [], [], [], %w[cancel]])
    expect(view.offered_count).to eq(1)
    expect(view.joined_form).to be_nil
    expect(view).not_to be_plain
  end

  it "gives the search box under offered records a slot for its pick, posting the search's choice" do
    slot = question("near_match").picks[1]

    expect([slot.id, slot.kind, slot.style, slot.label, slot.data]).to eq(["use", :pick, :secondary, "", { "data[list_id]" => "" }])
    expect(slot.action_url).to eq("/q/1")
    field = question("near_match").searches.first.fields.first
    expect([field.inline?, field.required, field.placeholder]).to eq([true, false, "Search QuickBooks…"])
  end

  it "puts a decline with no row of its own just under the offered records, with their weight" do
    expect(arranged(question("choose"))).to eq([["use:1", :pick, :secondary], ["use:2", :pick, :secondary],
                                                ["none", :exit, :secondary], ["cancel", :exit, :ghost]])
    expect(question("choose").alongside.map(&:id)).to eq(%w[none])
    expect(question("choose").exits.map(&:id)).to eq(%w[cancel])
    expect(question("ask_about_add").alongside.map(&:id)).to eq(%w[add_again])
    expect(arranged(question("ask_about_add"))).to eq([["use_existing:1", :pick, :secondary], ["add_again", :exit, :secondary],
                                                       ["cancel", :exit, :ghost]])
  end

  it "keeps the first offered record the main action without a decline, the search a box under them" do
    view = question("record_search")

    expect(arranged(view)).to eq([["use:1", :pick, :primary], ["use:2", :pick, :secondary], ["use:3", :pick, :secondary],
                                  ["use", :form, :secondary], ["cancel", :exit, :ghost]])
    expect(view.picks.map(&:id)).to eq(%w[use:1 use:2 use:3 use])
    expect(view.searches.map(&:id)).to eq(%w[use])
    expect(view.offered_count).to eq(3)
  end

  it "shows the search as a section when nothing is offered, its submit waiting for a pick" do
    prompt = QubeRails::Storyboard.find("near_match").sample["prompt"]
    prompt = prompt.merge("choices" => prompt["choices"].reject { |c| c["role"] == "pick" })
    view = QubeRails::QuestionView.new(prompt, action_url: "/q", search_url: "/q/search")
    expect(view.searches).to be_empty
    expect(view.forms.map(&:id)).to eq(%w[use])
    expect(view.forms.first.style).to eq(:primary)
    expect(view.forms.first).to be_waits_for_pick
    expect(view.forms.first.fields.first.required).to be(true)
    expect(view.joined_form.id).to eq("use")
    expect(view.exits.map(&:id)).to eq(%w[none cancel])
  end

  it "puts cancel last among the exits, whatever its place in the prompt" do
    prompt = { "token" => "t", "message" => "?", "choices" => [
      { "id" => "stop", "label" => "Stop", "fields" => [], "role" => "cancel" },
      { "id" => "none", "label" => "It's not there", "fields" => [], "role" => "decline" }
    ] }
    view = QubeRails::QuestionView.new(prompt, action_url: "/q", search_url: "/q/search")
    expect(view.exits.map(&:id)).to eq(%w[none stop])
  end

  it "looks its own words up in one place, the rows field's step line too" do
    view = question("rows")
    expect(view.ui_text(:disclose_choice, label: "add it under another name")).to eq("or add it under another name…")
    expect(view.ui_text(:search_quickbooks)).to eq("Search QuickBooks…")
    expect(view.choices.first.fields.first.rows.ui_text(:step, position: 1, count: 3)).to eq("1 of 3")
  end

  it "takes a role it doesn't know as answer" do
    prompt = { "token" => "t", "message" => "?", "choices" => [
      { "id" => "later", "label" => "Ask me later", "fields" => [], "role" => "snooze" }
    ] }
    view = QubeRails::QuestionView.new(prompt, action_url: "/q", search_url: "/q/search")
    expect(view.choices.map(&:role)).to eq(["answer"])
  end

  it "without roles, guesses from each choice's shape: picks are rows, the first form primary" do
    expect(without_roles("near_match")).not_to be_roles
    expect(arranged(without_roles("near_match"))).to eq([["use:1", :pick, nil], ["use", :form, :primary],
                                                         ["none", :exit, :secondary], ["cancel", :exit, :ghost]])
    expect(arranged(without_roles("choose"))).to eq([["use:1", :pick, nil], ["use:2", :pick, nil],
                                                     ["none", :exit, :secondary], ["cancel", :exit, :ghost]])
    expect(arranged(without_roles("record_search"))).to eq([["use:1", :pick, nil], ["use:2", :pick, nil], ["use:3", :pick, nil],
                                                            ["use", :form, :primary], ["cancel", :exit, :ghost]])
  end

  it "fills only the first form's submit" do
    field = ->(name) { [{ "name" => name, "type" => "string", "label" => name, "required" => true }] }
    prompt = { "token" => "t", "message" => "?", "choices" => [
      { "id" => "narrow", "label" => "Narrow it down", "fields" => field.call("city") },
      { "id" => "rename", "label" => "Rename it", "fields" => field.call("name") },
      { "id" => "cancel", "label" => "Cancel", "fields" => [] }
    ] }
    view = QubeRails::QuestionView.new(prompt, action_url: "/q", search_url: "/q/search")
    expect(view.choices.map { |c| [c.id, c.kind, c.style] }).to eq([["narrow", :form, :primary], ["rename", :form, :secondary],
                                                                    ["cancel", :exit, :ghost]])
  end

  it "leads a name clash with the existing record, the rename behind \"or add it under another name…\"" do
    view = question("name_clash")

    # The record is the main action; the rename's submit is primary once its disclosure opens.
    expect(arranged(view)).to eq([["use_existing", :pick, :primary], ["rename", :form, :primary], ["cancel", :exit, :ghost]])
    expect([view.picks, view.forms, view.disclosed, view.exits].map { |l| l.map(&:id) })
      .to eq([%w[use_existing], [], %w[rename], %w[cancel]])
    expect(view.mid_sentence(view.disclosed.first.label)).to eq("add it under another name")
    expect(view.joined_form).to be_nil
  end

  it "never puts a search behind the disclosure, only the forms that answer" do
    prompt = { "token" => "t", "message" => "?", "choices" => [
      { "id" => "use_existing", "label" => "Use the existing record", "role" => "answer", "title" => "RIVERBEND",
        "fields" => [] },
      { "id" => "use", "label" => "Use this one", "role" => "search",
        "fields" => [{ "name" => "list_id", "type" => "record", "kind" => "customer", "required" => true }] },
      { "id" => "rename", "label" => "Add it under another name", "role" => "answer",
        "fields" => [{ "name" => "name", "type" => "string", "required" => true }] },
      { "id" => "cancel", "label" => "Cancel", "role" => "cancel", "fields" => [] }
    ] }
    view = QubeRails::QuestionView.new(prompt, action_url: "/q", search_url: "/q/search")
    expect(view.disclosed.map(&:id)).to eq(%w[rename])
  end

  it "reads a choice about one record: its title, action, lines and facts" do
    record = question("name_clash").picks.first

    expect([record.title, record.action, record.lines]).to eq(["RIVERBEND ELECTRIC", "Use existing",
                                                               ["ap@riverbend.example · 512-555-0142 · Austin"]])
    expect(record.facts.map(&:to_a)).to eq([["Company", "Riverbend Electric LLC"], ["Balance", "1,250.00"],
                                            ["Added", "Mar 2, 2024"]])
    expect(record).to be_row
    expect(record.detail_parts(record.lines.first)).to eq(["ap@riverbend.example ·", "512-555-0142 ·", "Austin"])
    expect(question("choose").picks.first).not_to be_row
  end

  it "keeps a question of plain choices in one row, the first primary" do
    prompt = { "token" => "t", "message" => "?", "choices" => [
      { "id" => "approve", "label" => "Approve", "fields" => [] },
      { "id" => "skip", "label" => "Skip", "fields" => [] },
      { "id" => "cancel", "label" => "Cancel", "fields" => [] }
    ] }
    view = QubeRails::QuestionView.new(prompt, action_url: "/q", search_url: "/q/search")

    expect(view).to be_plain
    expect(arranged(view)).to eq([["approve", :exit, :primary], ["skip", :exit, :secondary], ["cancel", :exit, :ghost]])
  end

  it "has at most one primary button on every storyboard question, a disclosed form's aside" do
    QubeRails::Storyboard::QUESTIONS.each do |key|
      view = question(key)
      expect((view.choices - view.disclosed).count { |c| c.style == :primary }).to be <= 1, key
    end
  end
end
