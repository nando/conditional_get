require File.dirname(__FILE__) + '/../spec_helper'

describe 'peticiones con cache de cliente', :type => :controller do
  include ConditionalGetSpec
  fixtures :sites
  controller_name :dummy 
  integrate_views
  
  before do
    @cache_version = new_cache_version
  end
  
  it 'válida y sin mensaje personal' do
    request.env["HTTP_IF_NONE_MATCH"] = etag_for(key_for(@cache_version))
    get :cached_action, :cache_version => @cache_version
    response.body.should be_blank
    response.headers['Status'].should == '304 Not Modified'
  end

  it 'válida pero con mensaje personal' do
    key = key_for(@cache_version)
    request.env["HTTP_IF_NONE_MATCH"] = etag_for(key)
    
    cache = cache_hash(:cache_version => @cache_version)
    notice = 'Nice!'
    
    Cache.should_receive(:get).with(key).and_return(cache)

    get :cached_action, {:cache_version => @cache_version}, {}, 
      {:notice => notice}
    response.should be_success
    personal_message.index(notice).should_not be_nil
    response.headers['Cache-Control'].should == 'no-cache'
    response.headers['ETag'].should be_nil
  end
  
  it 'obsoleta' do
    etag = etag_for(key_for(@cache_version))
    old_etag = etag_for(key_for(new_cache_version))
    request.env["HTTP_IF_NONE_MATCH"] = old_etag
    get :cached_action, :cache_version => @cache_version
    response.should be_success
    response.headers['Cache-Control'].should == 'private'
    response.headers['ETag'].should == etag
  end
  
end

# Posibilidad de establecer el valor de la cabecera cache-control para resultados
# cacheables.
# 
# Ver http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.9.1
# 
# Por omisión se establece a 'private'

describe 'peticiones de acción pública', 
    :type => :controller do
    
  include ConditionalGetSpec
  fixtures :sites
  controller_name :public_dummy 
  integrate_views
  
  it 'deberían devolver "public" en la cabecera cache-control' do
    cache_version = new_cache_version
    key = key_for(cache_version)
    etag = etag_for(key)
    get :cached_action, :cache_version => cache_version
    response.should be_success
    response.headers['Cache-Control'].should == 'public'
    response.headers['ETag'].should == etag
  end

  it 'deberían devolver "public" y bla!!! en la cabecera cache-control' do
    cache_version = new_cache_version
    cache = cache_hash(:cache_version => cache_version)
    key = key_for(cache_version)
    user = stub(User, 
      :id => 1,
      :login => 'quentin',
      :cache_version => new_cache_version)
    controller.stub!(:current_user).and_return(user)
    Cache.should_receive(:get).with(key).and_return(cache)
    key = key_for(cache_version)
    etag = etag_for(key)
    get :cached_action, :cache_version => cache_version
    response.should be_success
    response.headers['Cache-Control'].should == 'public'
    response.headers['ETag'].should == etag
  end
  
end

# Posibilidad de establecer un valor TTL para la cache: independientemente
# del ETag, pasado el numero de segundos indicados la cache será expirada
describe 'peticiones de acción cacheada con TTL', 
    :type => :controller do
    
  include ConditionalGetSpec
  fixtures :sites
  controller_name :ttl_dummy 
  integrate_views
  
  before do
    @cache_version = new_cache_version
    @key = key_for(@cache_version)
    @etag = etag_for(@key)
  end
  
  it 'deberían utilizar el parámetro TTL al establecer el valor en memcached' do
    not_yield_in_progress_mocking
    Cache.should_receive(:get).with(@key).and_return(nil)
    Cache.should_receive(:get).with(dirty_key_for(@cache_version)).and_return(nil)
    Cache.should_receive(:set).with(@key, anything, 5.minutes)
    get :cached_action, :cache_version => @cache_version
    personal_message.should be_blank
    response.should have_tag('div#user', 'anonymous')
    response.should have_tag('div#cache_version', @cache_version.to_s)
    response.should be_success
    response.headers['Cache-Control'].should == 'private'
    response.headers['ETag'].should == @etag
  end

#   Deberían tener prioridad la existencia en cache sobre la validez del ETag:
#    (si el contenido existe y el ETag no ha variado debería devolver Not Modified,
#    pero si el contenido no existe deberíamos volver a procesar la petición aunque
#    el ETag sea válido)
  it 'debería volver a procesar la petición si el ETag es válido pero ha expirado su TTL' do
    request.env["HTTP_IF_NONE_MATCH"] = @etag
    get :cached_action, :cache_version => @cache_version
    response.body.should_not be_blank
    response.should be_success
    response.headers['Cache-Control'].should == 'private'
    response.headers['ETag'].should == @etag
  end

  it 'debería devolver Not Modified si el ETag es válido y no expirado su TTL' do
    cache = cache_hash(:cache_version => @cache_version)
    Cache.should_receive(:get).with(@key).and_return(cache)
    request.env["HTTP_IF_NONE_MATCH"] = @etag
    get :cached_action, :cache_version => @cache_version
    response.body.should be_blank
    response.headers['Status'].should == '304 Not Modified'
  end
  
end

# Posibilidad de establecer un valor TTS (Time To Survive) para la cache, de tal forma
# que si la cache ha expirado por sus claves pero no ha transcurrido el tiempo indicado:
# a) si el cliente facilita el ETag de la versión que se pretende conservar se le
#    devuelve un 304 Not Modified
# b) si el cliente no facilita ETag o facilita un ETag obsoleto se le envía la copia de
#    cache "base" con el ETag de la versión que se pretende mantener.
describe 'peticiones de acción cacheada con TTS', 
    :type => :controller do
    
  include ConditionalGetSpec
  fixtures :sites
  controller_name :tts_dummy 
  integrate_views
  
  before do
    @cache_version = new_cache_version
    @key = key_for(@cache_version)
    @etag = etag_for(@key)
  end
  
  it 'deberían guardar el ETag de la petición en memcached utilizando la clave ' +
     'canónica (*) para la petición y el tiempo de expiración TTS' do
  # (*) Clave canónica: clave compuesta por todas las sub-claves excepto las pasadas como parámetros a
  # conditional_get (base_keys + request_keys, en lugar de base_keys + filter_keys + request_keys).
    base_key = base_key_for(@cache_version)
    cannonical_key = base_key + ':' + request_key_for
    Cache.should_receive(:get).with(cannonical_key).and_return(nil)
    not_yield_in_progress_mocking
    Cache.should_receive(:get).with(@key).and_return(nil)
    Cache.should_receive(:get).with(dirty_key_for(@cache_version)).and_return(nil)
    Cache.should_receive(:set).with(@key, anything, 0)
    Cache.should_receive(:set).with(cannonical_key, @etag, 50.seconds)
    get :cached_action, :cache_version => @cache_version
    personal_message.should be_blank
    response.should have_tag('div#user', 'anonymous')
    response.should have_tag('div#cache_version', @cache_version.to_s)
    response.should be_success
    response.headers['Cache-Control'].should == 'private'
    response.headers['ETag'].should == @etag
  end

  it 'debería devolver Not Modified si ha cambiado ETag para la versión actual pero ' +
     ' el ETag que facilitamos se corresponde con el de la versión con TTS en curso' do
    old_version = new_cache_version
    old_etag = etag_for(key_for(old_version))
    request.env["HTTP_IF_NONE_MATCH"] = old_etag
    base_key = base_key_for(@cache_version)
    cannonical_key = base_key + ':' + request_key_for
    Cache.should_receive(:get).with(cannonical_key).and_return(old_etag)
    get :cached_action, :cache_version => @cache_version
    response.body.should be_blank
    response.headers['Status'].should == '304 Not Modified'
  end
  
  it 'debería devolver la versión en curso si el cliente no facilita ETag válido pero ' +
     'todavía no a expirado el tiempo mínimo que debe mantenerse la cache' do
    old_version = new_cache_version
    old_etag = etag_for(key_for(old_version))
    base_key = base_key_for(@cache_version)
    cannonical_key = base_key + ':' + request_key_for
    Cache.should_receive(:get).with(cannonical_key).and_return(old_etag)
    base_cache = cache_hash(:cache_version => old_version)
    Cache.should_receive(:get).with(base_key).and_return(base_cache)
    Cache.should_not_receive(:set)
    get :cached_action, :cache_version => @cache_version
    response.should have_tag('div#cache_version', old_version.to_s)
    response.should be_success
    response.headers['Cache-Control'].should == 'private'
    response.headers['ETag'].should == old_etag
  end
end

describe 'peticiones sin sesión iniciada ni cache de cliente válida', :type => :controller do
  include ConditionalGetSpec
  fixtures :sites
  controller_name :dummy 
  integrate_views
  
  before do
    @cache_version = new_cache_version
    @key = key_for(@cache_version)
    @etag = etag_for(@key)
  end

  after do  
    response.should be_success
    response.headers['Cache-Control'].should == 'private'
    response.headers['ETag'].should == @etag
  end

  it 'sin caché de ningún tipo (app)' do 
    not_yield_in_progress_mocking
    Cache.should_receive(:get).with(@key).and_return(nil)
    Cache.should_receive(:get).with(dirty_key_for(@cache_version)).and_return(nil)
    Cache.should_receive(:set).with(@key, anything, 0)
    get :cached_action, :cache_version => @cache_version
    personal_message.should be_blank
    response.should have_tag('div#user', 'anonymous')
    response.should have_tag('div#cache_version', @cache_version.to_s)
  end
  
  it 'con caché anónima (HIT!)' do
    cache = cache_hash(:cache_version => @cache_version)
    
    Cache.should_receive(:get).with(@key).and_return(cache)
    Cache.should_not_receive(:get).with(dirty_key_for(@cache_version))
    Cache.should_not_receive(:set).with(@key, anything)
    get :cached_action, :cache_version => @cache_version
    response.body.should == cache[:content]
  end

  it 'con caché sucia (semi-HIT!)' do
    cache = cache_hash(:cache_version => @cache_version, :user => 'quentin')
    
    in_progress_key = base_key_for(@cache_version, true)
    Cache.should_receive(:get).with(in_progress_key).at_least(1).and_return(nil)
    Cache.should_receive(:get).with(@key).and_return(nil)
    Cache.should_receive(:get).with(dirty_key_for(@cache_version)).and_return(cache)
    Cache.should_receive(:set).with(@key, anything, 0)
    get :cached_action, :cache_version => @cache_version
    personal_message.should be_blank
    response.should have_tag('div#user', 'anonymous')
    response.should have_tag('div#cache_version', @cache_version.to_s)
  end

end

describe 'peticiones con sesión iniciada sin cache de cliente válida', :type => :controller do
  include ConditionalGetSpec
  fixtures :sites
  controller_name :dummy 
  integrate_views
  
  before do
    @user = stub(User, 
      :id => 1,
      :login => 'quentin',
      :cache_version => new_cache_version)
    controller.stub!(:current_user).and_return(@user)
    @cache_version = new_cache_version
    @key = key_for(@cache_version, @user.id, @user.cache_version)
    @etag = etag_for(@key)
  end

  after do  
    response.should be_success
    response.headers['Cache-Control'].should == 'private'
    response.headers['ETag'].should == @etag
  end

  it 'sin caché de ningún tipo (app)' do 
    not_yield_in_progress_mocking
    dirty_key = dirty_key_for(@cache_version)
    Cache.should_receive(:get).with(@key).and_return(nil)
    Cache.should_receive(:get).with(key_for(@cache_version)).and_return(nil)
    Cache.should_receive(:get).with(dirty_key).and_return(nil)
    Cache.should_receive(:set).with(@key, anything, 0)
    Cache.should_receive(:set).with(dirty_key, anything, 0)
    get :cached_action, {:cache_version => @cache_version}, {:user => @user.id}
    personal_message.should be_blank
    response.should have_tag('div#user', @user.login)
    response.should have_tag('div#cache_version', @cache_version.to_s)
  end

  
  it 'con caché del usuario (HIT!)' do
    not_so_random = 777
    cache = cache_hash(
      :random_number => not_so_random,
      :user => @user.login,
      :cache_version => @cache_version)
    Cache.should_receive(:get).with(@key).and_return(cache)
    Cache.should_not_receive(:get).with(dirty_key_for(@cache_version))
    Cache.should_not_receive(:set).with(any_args)
    get :cached_action, {:cache_version => @cache_version}, {:user => @user.id}
    response.body.should == cache[:content]
  end
  
  it 'con caché anónima (semi-HIT!)' do
    anonymous_key = key_for(@cache_version)
    not_so_random = 777
    cache = cache_hash(
      :random_number => not_so_random,
      :cache_version => @cache_version)
    in_progress_key = base_key_for(@cache_version, true)
    Cache.should_receive(:get).with(in_progress_key).at_least(1).and_return(nil)
    Cache.should_receive(:get).with(@key).and_return(nil)
    Cache.should_receive(:get).with(anonymous_key).and_return(cache)
    Cache.should_receive(:set).with(@key, anything, 0)
    get :cached_action, {:cache_version => @cache_version}, {:user => @user.id}
    response.should have_tag('div#user', @user.login)
  end

  it 'con caché sucia (semi-HIT!)' do
    cache = cache_hash(:cache_version => @cache_version, :user => 'quentin')
    
    in_progress_key = base_key_for(@cache_version, true)
    Cache.should_receive(:get).with(in_progress_key).at_least(1).and_return(nil)
    Cache.should_receive(:get).with(@key).and_return(nil)
    Cache.should_receive(:get).with(key_for(@cache_version)).and_return(nil)
    Cache.should_receive(:get).with(dirty_key_for(@cache_version)).and_return(cache)
    Cache.should_receive(:set).with(@key, anything, 0)
    get :cached_action, {:cache_version => @cache_version}, {:user => @user.id}
    response.should have_tag('div#user', @user.login)
  end
  
end

describe 'peticiones sin cache de cliente válida con mensaje personal deberían ' +
         'generar cache de servidor (sin dicho mensaje) y solicitar que no sea ' +
         'cacheada por nadie más', :type => :controller do
  include ConditionalGetSpec
  fixtures :sites
  controller_name :dummy 
  integrate_views
  
  before do
    @cache_version = new_cache_version
    @notice = 'Nice!'
  end
  
  after do
    response.should be_success
    personal_message.index(@notice).should_not be_nil
    response.headers['Cache-Control'].should == 'no-cache'
    response.headers['ETag'].should be_nil
  end
  
  it 'sin cache de servidor de ningún tipo' do
    not_yield_in_progress_mocking(true)
    Cache.should_receive(:set).with(key_for(@cache_version), anything, 0)
    get :cached_action, {:cache_version => @cache_version}, {}, {:notice => @notice}
  end
  
  it 'con cache de servidor anónima (genérica)' do
    user = stub(User, 
      :id => 1,
      :login => 'quentin',
      :cache_version => 44)
    controller.stub!(:current_user).and_return(user)
    key = key_for(@cache_version, user.id, user.cache_version)
    not_so_random = 777
    cache = cache_hash(
      :random_number => not_so_random,
      :cache_version => @cache_version)
    in_progress_key = base_key_for(@cache_version, true)
    Cache.should_receive(:get).with(in_progress_key).at_least(1).and_return(nil)
    Cache.should_receive(:get).with(key).and_return(nil)
    Cache.should_receive(:get).with(key_for(@cache_version)).and_return(cache)
    Cache.should_receive(:set).with(key, 
      cache_hash(
        :random_number => not_so_random,
        :user => user.login,
        :cache_version => @cache_version), 0)
    get :cached_action, 
      { :cache_version => @cache_version}, 
      { :user => user.id }, 
      { :notice => @notice}
  end
end


describe 'en peticiones concurrentes tras la expiración de la cache, para la segunda y ' + 
  'siguientes peticiones que se producen durante la regeneración en curso: ' +
  'se debería utilizar la version obsoleta de la URL, no enviar ETag y enviar como ' +
  'Cache-Control "no-cache"', :type => :controller do
  include ConditionalGetSpec
  fixtures :sites
  controller_name :dummy 
  integrate_views

  after do
    response.should be_success
    response.should have_tag('div#cache_version', @cache_version.to_s)
    response.headers['Cache-Control'].should == 'no-cache'
    response.headers['ETag'].should be_nil
  end  
  
  # la versión obsoleta es sucia por definición (se guarda sin hacer referencia al 
  # usuario que la generó), por lo tanto...
  it 'la cache obsoleta debería convertirse en genérica para una petición anónima si fue generada por un usuario' do
    @cache_version = new_cache_version
    @key = key_for(@cache_version)
    @cache = cache_hash(:cache_version => @cache_version, :user => 'quentin')
    yield_in_progress_mocking
    
    Cache.should_receive(:get).with(@key).and_return(nil)
    Cache.should_receive(:get).with(dirty_key_for(@cache_version)).and_return(nil)
    Cache.should_not_receive(:set).with(@key, anything)
    get :cached_action, :cache_version => @cache_version
    response.should have_tag('div#user', 'anonymous')
  end
  
  it 'debería personalizarse si fue generada por una petición anónima' do
    user = stub(User, 
      :id => 1,
      :login => 'quentin',
      :cache_version => new_cache_version)
    controller.stub!(:current_user).and_return(user)
    @cache_version = new_cache_version
    @key = key_for(@cache_version, user.id, user.cache_version)
    @cache = cache_hash(:cache_version => @cache_version)
    yield_in_progress_mocking
    
    Cache.should_receive(:get).with(@key).and_return(nil)
    Cache.should_receive(:get).with(key_for(@cache_version)).and_return(nil)
    Cache.should_receive(:get).with(dirty_key_for(@cache_version)).and_return(nil)
    Cache.should_not_receive(:set).with(@key, anything)
    get :cached_action, {:cache_version => @cache_version}, {:user => user.id}
    response.should have_tag('div#user', user.login)
  end
end
  
describe 'escenario anterior en el que hemos perdido la cache de la version obsoleta. ' +
         'Aunque necesariamente tenemos que procesar la petición, NO debería comenzar ' + 
         ' un nuevo "yield in progress" (para evitar interferir con el que hay en curso). ', 
         :type => :controller do
  include ConditionalGetSpec
  fixtures :sites
  controller_name :dummy 
  integrate_views
  
  it do
    @cache_version = new_cache_version
    @key = key_for(@cache_version)
    etag = etag_for(@key)
    @cache = nil
    yield_in_progress_mocking
    
    Cache.should_receive(:get).with(@key).and_return(nil)
    Cache.should_receive(:get).with(dirty_key_for(@cache_version)).and_return(nil)
    Cache.should_receive(:set).with(@key, anything, 0)
    get :cached_action, :cache_version => @cache_version
    personal_message.should be_blank
    response.should have_tag('div#user', 'anonymous')
    response.should have_tag('div#cache_version', @cache_version.to_s)
    response.should be_success
    response.headers['Cache-Control'].should == 'private'
    response.headers['ETag'].should == etag
  end
end
