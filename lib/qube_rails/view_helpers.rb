# frozen_string_literal: true

module QubeRails
  # Helpers in every view of your app (the engine includes them into ActionView).
  module ViewHelpers
    # The question's behaviour script, and with stylesheet: true the engine's opt-in stylesheet,
    # for your layout's <head>:
    #   <%= qube_rails_assets stylesheet: true %>
    # Served by your asset pipeline (Propshaft or Sprockets) as qube_rails/question.js and
    # qube_rails.css.
    def qube_rails_assets(stylesheet: false)
      tags = []
      tags << stylesheet_link_tag("qube_rails", media: "all") if stylesheet
      tags << javascript_include_tag("qube_rails/question", defer: true, nonce: true)
      safe_join(tags, "\n")
    end

    # The classes for a piece of the engine's screens: its qube- classes, then the app's
    # config.ui_classes for that piece.
    def qube_classes(piece, *base)
      extra = QubeRails.config.ui_classes[piece.to_sym]
      unless QubeRails::Configuration::UI_PIECES.include?(piece.to_sym)
        raise ArgumentError, "QuBe Sync: no ui_classes piece #{piece.inspect}"
      end

      (base.flatten.compact + [extra]).reject { |c| c.nil? || c.empty? }.join(" ")
    end
  end
end
