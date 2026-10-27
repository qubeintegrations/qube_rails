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

  it "makes a choose list's items picks, a choice with fields a form, and the rest exits" do
    view = question("near_match")

    expect(arranged(view)).to eq([["use:1", :pick, nil], ["use", :form, :primary], ["none", :exit, :secondary],
                                  ["cancel", :exit, :ghost]])
    expect([view.picks, view.forms, view.exits].map { |l| l.map(&:id) }).to eq([%w[use:1], %w[use], %w[none cancel]])
    expect(view).not_to be_plain
  end

  it "fills no button for a pick from a list: picks are rows, none of these secondary, cancel a ghost" do
    expect(arranged(question("choose"))).to eq([["use:1", :pick, nil], ["use:2", :pick, nil], ["none", :exit, :secondary],
                                                ["cancel", :exit, :ghost]])
  end

  it "shows a pick from the records there are as rows, then the search with the one filled submit" do
    expect(arranged(question("record_search"))).to eq([["use:1", :pick, nil], ["use:2", :pick, nil], ["use:3", :pick, nil],
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
