require File.dirname(__FILE__) + '/../../../../../spec/spec_helper'
require File.dirname(__FILE__) + '/../../spec_resources/controllers/dummy_controller'

describe DummyController, 'conditional_get setup' do
  fixtures :sites
  it 'debería tener el filtro check_cache alrededor de cached_action' do
    @controller.should have_filter(:check_dummy_cache).around(:cached_action)
  end

  it 'debería llamar a conditional_get desde check_cache' do
    cache_version = rand(1000).to_s
    @controller.should_receive(:conditional_get).with(cache_version).and_return(false)
    get :cached_action, :cache_version => cache_version
  end
end
