# frozen_string_literal: true

module QubeRails
  # GET qube/storyboard (and qube/storyboard/<screen>): every screen the engine's partials show,
  # from sample data (QubeRails::Storyboard), in your app's layout, so your CSS and
  # config.ui_classes apply and each piece's override path is beside it. Only when
  # config.storyboard is true (by default, in development), behind your sign-in as the other
  # routes are. Its searches answer from the samples and its forms post to a no-op: nothing
  # reaches QuBe Sync or the database.
  class StoryboardController < QubeRails.config.parent_controller.constantize
    NOTHING_SENT = "Storyboard: nothing was sent."

    # Your layout's own route helpers (root_path) resolve as on your pages; the engine's are
    # qube_rails.*.
    include Rails.application.routes.url_helpers
    helper Rails.application.routes.url_helpers

    prepend_before_action :require_storyboard
    before_action :find_screen, except: :index

    def index
      @screens = Storyboard.screens
      render :show
    end

    def show
      @screens = [@screen]
    end

    def search
      render json: Storyboard.matches(@screen, params[:field], params[:q])
    end

    def answer
      flash[:qube_rails_storyboard] = NOTHING_SENT
      redirect_to qube_rails.storyboard_screen_path(@screen.key), status: :see_other
    end

    private

    def require_storyboard
      head :not_found unless QubeRails.config.storyboard == true
    end

    def find_screen
      @screen = Storyboard.find(params[:screen])
      head :not_found unless @screen
    end
  end
end
