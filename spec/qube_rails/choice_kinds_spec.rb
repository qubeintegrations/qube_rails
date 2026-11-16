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

  it "weighs choices by role: the offered records first, the first primary, cancel last" do
    view = question("near_match")

    expect(view).to be_roles
    expect(view).to be_matches
    # The search is the next branch's: its submit primary, shown once a match is picked.
    expect(arranged(view)).to eq([["use:1", :pick, :primary], ["use", :form, :primary], ["none", :exit, :secondary],
                                  ["cancel", :exit, :ghost]])
    expect([view.picks, view.forms, view.exits].map { |l| l.map(&:id) }).to eq([%w[use:1], %w[use], %w[none cancel]])
    expect(view).not_to be_plain
  end

  it "makes offered records with a search a chain: the offered branch first, the search's after" do
    view = question("near_match")

    expect(view).to be_chain
    expect(view.branch).to eq(:offered)
    expect(view.offered_count).to eq(1)
    expect(view.joined_form.id).to eq("use")
    expect(view.joined_exits.map(&:id)).to eq(%w[none cancel])
    expect([:picks, :footer, *view.choices].map { |piece| view.branch_part(piece) })
      .to eq(["offered", "offered", nil, "search", nil, nil])
    expect(view.choices.find { |c| c.id == "use" }).to be_waits_for_pick
    expect(question("record_search").offered_count).to eq(3)
  end

  it "starts a chain on its search when the search's answer was refused" do
    prompt = QubeRails::Storyboard.find("near_match").sample["prompt"]
    refusal = ->(choice) { { "token" => prompt["token"], "choice" => choice, "message" => "No", "values" => {} } }
    view = ->(choice) { QubeRails::QuestionView.new(prompt, action_url: "/q", search_url: "/q/search", refusal: refusal.call(choice)) }

    expect(view.call("use").branch).to eq(:search)
    expect(view.call("use:1").branch).to eq(:offered)
    expect(view.call("none").branch).to eq(:offered)
  end

  it "isn't a chain without a search, or without offered records" do
    %w[choose ask_about_add name_clash rows].each do |key|
      expect(question(key)).not_to be_chain, key
      expect(question(key).branch).to be_nil
    end
    expect(without_roles("near_match")).not_to be_chain
  end

  it "shows the search as a section when nothing is offered, its submit waiting for a pick" do
    prompt = QubeRails::Storyboard.find("near_match").sample["prompt"]
    prompt = prompt.merge("choices" => prompt["choices"].reject { |c| c["role"] == "pick" })
    view = QubeRails::QuestionView.new(prompt, action_url: "/q", search_url: "/q/search")
    expect(view).not_to be_chain
    expect(view.forms.map(&:id)).to eq(%w[use])
    expect(view.forms.first.style).to eq(:primary)
    expect(view.forms.first).to be_waits_for_pick
    expect(view.joined_form.id).to eq("use")
  end

  it "makes the first of a list of picks primary and the rest secondary, decline secondary, cancel a ghost" do
    expect(arranged(question("choose"))).to eq([["use:1", :pick, :primary], ["use:2", :pick, :secondary],
                                                ["none", :exit, :secondary], ["cancel", :exit, :ghost]])
    expect(arranged(question("record_search"))).to eq([["use:1", :pick, :primary], ["use:2", :pick, :secondary],
                                                       ["use:3", :pick, :secondary], ["use", :form, :primary],
                                                       ["cancel", :exit, :ghost]])
    expect(arranged(question("ask_about_add"))).to eq([["use_existing:1", :pick, :primary], ["add_again", :exit, :secondary],
                                                       ["cancel", :exit, :ghost]])
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
    expect(view.ui_text(:none_of_these, count: 1)).to eq("Not this one")
    expect(view.ui_text(:none_of_these, count: 3)).to eq("None of these")
    expect(view.ui_text(:back_to_offered, count: 1)).to eq("← Back to the possible match")
    expect(view.ui_text(:back_to_offered, count: 3)).to eq("← Back to the 3 possible matches")
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

  it "shows a plain choice before the first form as a pick when there are none (a name clash)" do
    # Its "Use this one" is a secondary button, as an offered record's, not a bare link
    expect(arranged(question("name_clash"))).to eq([["use_existing", :pick, :secondary], ["rename", :form, :primary],
                                                    ["cancel", :exit, :ghost]])
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

  it "has at most one primary button on every storyboard question, or on each branch of a chain" do
    QubeRails::Storyboard::QUESTIONS.each do |key|
      view = question(key)
      view.choices.group_by { |c| view.branch_part(c) || view.branch_part(c.kind == :pick ? :picks : nil) }.each_value do |choices|
        expect(choices.count { |c| c.style == :primary }).to be <= 1, key
      end
    end
  end
end
