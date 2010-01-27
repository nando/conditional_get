require File.dirname(__FILE__) + '/../../../../spec/spec_helper'
# ATENCIÓN: requires necesarios si lanzamos las specs directamente con "ruby path_to_spec"
#   y problemáticos si las lanzanmos con rake (lanza dos veces su around_filter)
path = File.join(File.dirname(__FILE__), '..', 'spec_resources', 'controllers')
$LOAD_PATH << path
Dependencies.load_paths << path
Dependencies.load_once_paths.delete(path)
#require File.dirname(__FILE__) + '/../spec_resources/controllers/dummy_controller'  
#require File.dirname(__FILE__) + '/../spec_resources/controllers/public_dummy_controller'  
#require File.dirname(__FILE__) + '/../spec_resources/controllers/ttl_dummy_controller'  
#require File.dirname(__FILE__) + '/../spec_resources/controllers/tts_dummy_controller'  



module ConditionalGetSpec
  require 'digest/md5'
  
  def new_cache_version
    if $conditional_get_new_cache_version
      $conditional_get_new_cache_version += 1
    else
      $conditional_get_new_cache_version = Time.now.to_i
    end
  end
  
  def request_url(cache_version)
    "/ap/#{controller.controller_name}/cached_action?cache_version=#{cache_version}"
  end
  
  def base_key_for(cache_version, yield_in_progress = false)
    key = "test.host:#{request_url(cache_version)}"
    if yield_in_progress
      key += ':yield_in_progress'
    else
      key
    end
  end
  
  def request_key_for(session_user = nil, user_cache_version = 0)
    "#{session_user}:#{user_cache_version}"
  end
  
  def key_for(cache_version, session_user = nil, user_cache_version = 0)
    base_key_for(cache_version) + ":#{cache_version}:" + request_key_for(session_user,user_cache_version)
  end
  
  def etag_for(key)
    Digest::MD5.hexdigest(key)
  end
  
  def dirty_key_for(cache_version)
    key_for(cache_version, 0)
  end
  
  def personal_message
    response.body.scan(
      /<!-- begin::cache::message -->(.+)<!-- end::cache::message -->/m)[0].first
  end
  
  def cache_hash(values = {})
    content = File.open(File.dirname(__FILE__) + 
      '/../spec_resources/views/dummy/cached_action.rhtml').read
  
    values[:random_number] ||= rand(999999)
    values[:personal_message] = "<!-- begin::cache::message -->\n" +
      "#{values[:personal_message]}\n<!-- end::cache::message -->\n"
    values[:user] ||= 'anonymous'
    values[:cache_version] ||= Time.now.to_i
    
    values.each_key do |id|
      content.gsub!(/<div id="#{id}">.+<\/div>/, "<div id=\"#{id}\">#{values[id]}<\/div>")
    end
    { :content_type => 'text/html; charset=UTF-8', :content => content }
  end
  
  def not_yield_in_progress_mocking(skip_get = false)
    in_progress_key = base_key_for(@cache_version, true)
    Cache.should_receive(:get).with(in_progress_key).at_least(1).and_return(nil) unless skip_get
    Cache.should_receive(:set).with(in_progress_key, true, anything)
    Cache.should_receive(:set).with(base_key_for(@cache_version), anything)
    Cache.should_receive(:set).with(in_progress_key, false)
  end
  
  def yield_in_progress_mocking
    in_progress_key = base_key_for(@cache_version, true)
    Cache.should_receive(:get).with(in_progress_key).at_least(1).and_return(true)
    Cache.should_not_receive(:set).with(in_progress_key)
    Cache.should_not_receive(:set).with(base_key_for(@cache_version), anything)
    Cache.should_receive(:get).with(base_key_for(@cache_version)).and_return(@cache)
  end
end
