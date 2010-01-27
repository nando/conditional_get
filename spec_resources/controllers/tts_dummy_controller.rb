class TtsDummyController < ApplicationController
  include YAConditionalGet  
  around_filter :check_tts_dummy_cache

  def cached_action
    @random_nunber = rand(99999999)
    render :file => File.dirname(__FILE__) + '/../views/dummy/cached_action.rhtml', :layout => false
  end

  private
    def check_tts_dummy_cache
      conditional_get(params[:cache_version], :tts => 50.seconds) { yield }
    end
end
