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

  it "weighs choices by role: the offered records first, the first primary, search secondary, cancel last" do
    view = question("near_match")

    expect(view).to be_roles
    expect(view).to be_matches
    expect(arranged(view)).to eq([["use:1", :pick, :primary], ["use", :form, :secondary], ["none", :exit, :secondary],
                                  ["cancel", :exit, :ghost]])
    expect([view.picks, view.forms, view.exits].map { |l| l.map(&:id) }).to eq([%w[use:1], %w[use], %w[none cancel]])
    expect(view).not_to be_plain
  end

  it "makes the first of a list of picks primary and the rest secondary, decline secondary, cancel a ghost" do
    expect(arranged(question("choose"))).to eq([["use:1", :pick, :primary], ["use:2", :pick, :secondary],
                                                ["none", :exit, :secondary], ["cancel", :exit, :ghost]])
    expect(arranged(question("record_search"))).to eq([["use:1", :pick, :primary], ["use:2", :pick, :secondary],
                                                       ["use:3", :pick, :secondary], ["use", :form, :secondary],
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
    expect(view.ui_text(:possible_matches)).to eq("Possible matches")
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
    expect(arranged(question("name_clash"))).to eq([["use_existing", :pick, nil], ["rename", :form, :primary],
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

  it "has at most one primary button on every storyboard question" do
    QubeRails::Storyboard::QUESTIONS.each do |key|
      expect(question(key).choices.count { |c| c.style == :primary }).to be <= 1, key
    end
  end
end
