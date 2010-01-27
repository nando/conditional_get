
class PublicDummyController < ApplicationController
  include TheShakerConditionalGet  
  around_filter :check_public_dummy_cache

  def cached_action
    @random_nunber = rand(99999999)
    render :file => File.dirname(__FILE__) + '/../views/dummy/cached_action.rhtml', :layout => false
  end

  private
    def check_public_dummy_cache
      conditional_get(params[:cache_version], :cache_control => 'public') { yield }
    end
end





