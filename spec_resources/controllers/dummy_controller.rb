
class DummyController < ApplicationController
  include TheShakerConditionalGet  
  around_filter :check_dummy_cache

  def cached_action
    @random_nunber = rand(99999999)
    @notice = params[:notice] if params[:notice]
    @alert = params[:alert] if params[:alert]
    render :file => File.dirname(__FILE__) + '/../views/dummy/cached_action.rhtml', :layout => false
  end

  private
    def check_dummy_cache
      conditional_get(params[:cache_version]) { yield }
    end
end
