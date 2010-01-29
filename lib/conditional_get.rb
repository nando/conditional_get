require 'digest/md5'

module YAConditionalGet
  private
    def conditional_get(*filter_keys)
      @conditional_get_options = if filter_keys.last.is_a? Hash
        filter_keys.pop 
      else
        {}
      end
      if cg_tts_etag_not_expired?
        head :not_modified
      elsif (tts_etag = cg_tts_etag) and
            (data = cg_cache_content(cg_base_keys))
        headers['ETag'] = tts_etag
        headers['Cache-Control'] = @conditional_get_options[:cache_control] || 'private'
        headers['Content-Type'] = data[:content_type]
        cg_replace_dynamic_caches!(data[:content])
        render :text => data[:content]
      else  
        keys = cg_base_keys + filter_keys
        key = (keys  + cg_request_keys) * ':'
        @conditional_get_ttl, data = if @conditional_get_options[:ttl]
          [ @conditional_get_options[:ttl], cg_cache.get(key) ]
        else
          [ 0, :get_pending ]
        end
        @conditional_get_current_etag = Digest::MD5.hexdigest(key)
        if (request.env['HTTP_IF_NONE_MATCH'] == @conditional_get_current_etag) and 
           cg_without_personal_message? and 
           ((@conditional_get_ttl == 0) or data)
          head :not_modified
        else
          if cg_without_personal_message?
            headers['ETag'] = @conditional_get_current_etag 
            headers['Cache-Control'] = @conditional_get_options[:cache_control] || 'private'
          else
            headers['Cache-Control'] = 'no-cache'
          end
          data = cg_cache.get(key) if data == :get_pending
          if data
            cg_replace_personal_message!(data[:content], 'message')
            headers['Content-Type'] = data[:content_type]
            render :text => data[:content]
          else
            cg_set_cache(key, keys) { yield }
          end
        end
      end      
    end  
    
    def cg_set_cache(key, keys)
      unless cg_public_page?
        cache = (cg_logged_in? ? cg_cache_content(keys + cg_anonymous_keys) : nil)
        cache ||= cg_cache_content(keys + cg_dirty_cache_keys)
      end
      cache ||= cg_cache_content(cg_base_keys) if cache.nil? && cg_yield_in_progress?
      cache_or_response = if cache
        cg_replace_dynamic_caches!(cache[:content])
        render :text => cache[:content]
        if cg_yield_in_progress?
          headers['Cache-Control'] = 'no-cache' 
          headers.delete('ETag')
          nil
        else
          cache
        end
      else
        cg_cache.set(cg_yield_in_progress_key, true, 5.minutes) unless cg_yield_in_progress?
        yield
        base_cache = { 
          :content => response.body,
          :content_type => response.content_type || "text/html; charset=UTF-8" }
        unless cg_yield_in_progress?
          cg_cache.set((cg_base_keys * ':'), headers, 400)
          cg_cache.set(cg_yield_in_progress_key, false)
        end
        base_cache
      end
      if cache_or_response # && (headers["Status"].to_i == 200)
        content = cache_or_response[:content].clone
        cg_replace_personal_message!(content)
        cg_cache.set(key, {
          :content       => content, 
          :content_type  => cache_or_response[:content_type]}, @conditional_get_ttl)
        if @conditional_get_options[:tts]
          cg_cache.set(cg_cannonical_key, @conditional_get_current_etag, 
            @conditional_get_options[:tts])
        end
        if cache.nil? and cg_logged_in? and !cg_public_page?
          dirty_key = (keys + cg_dirty_cache_keys) * ':'
          cg_cache.set(dirty_key, { 
            :content      => content, 
            :content_type => cache_or_response[:content_type]}, @conditional_get_ttl)
        end
      end
    end

    def cg_request_keys
      if cg_public_page?
        cg_anonymous_keys
      else
        [session[:user], (cg_logged_in? && current_user.cache_version) || 0]
      end
    end
    
    def cg_anonymous_keys;   [nil           ,                                               0] end
    def cg_dirty_cache_keys; [0             ,                                               0] end
    
    def cg_base_keys
      @conditional_get_base_keys ||= [request.host, "#{request.path}?#{request.query_string}"]
    end
    
    def cg_cannonical_key
      @conditional_get_cannonical_key ||= (cg_base_keys + cg_request_keys) * ':'
    end
    
    def cg_yield_in_progress_key
      @conditional_get_yield_in_progress_key ||= (cg_base_keys + ['yield_in_progress']) * ':'
    end

    def cg_without_personal_message?
      @request_without_personal_message ||= 
        (@alert || @notice || flash[:alert] || flash[:notice]).nil?       
    end

    def cg_yield_in_progress?
      @conditional_get_yield_in_progress ||= if cg_cache.get(cg_yield_in_progress_key)
        :true
      else
        :false
      end
      @conditional_get_yield_in_progress == :true
    end

    def cg_replace_dynamic_caches!(cache)
      unless cg_public_page?
        cache.scan(/<!-- begin::cache::(\w+) -->/m).each do |block|
          name = block.first
          cache.gsub!(/<!-- begin::cache::#{name} -->.+<!-- end::cache::#{name} -->\n?/m, 
            cg_render_dynamic_partial(name))
        end
      end
    end
    
    def cg_replace_personal_message!(cache, partial=nil)
      unless cg_without_personal_message? or cg_public_page?
        replacement = if partial
          cg_render_dynamic_partial(partial)
        else
          nil
        end
        cache.gsub!(/<!-- begin::cache::message -->.+<!-- end::cache::message -->/m, 
            "<!-- begin::cache::message -->\n#{replacement}\n<!-- end::cache::message -->")
      end
    end
    
    def cg_render_dynamic_partial(name)
      render_to_string(:partial => 
        "../../public/#{public_directory}/templates/#{current_template}/views/#{name}")
    end
    
    def cg_cache_content(keys)
      cg_cache.get(keys * ':')
    end
    
    def cg_tts_etag_not_expired?
      request.env['HTTP_IF_NONE_MATCH'] and 
        (request.env['HTTP_IF_NONE_MATCH'] == cg_tts_etag)
    end

    def cg_tts_etag
      @cg_tts_etag ||= (@conditional_get_options[:tts] and cg_cache.get(cg_cannonical_key)) || 0
      (@cg_tts_etag == 0 ? nil : @cg_tts_etag)
    end
    
    def cg_public_page?
      @conditional_get_options[:cache_control] &&
        @conditional_get_options[:cache_control] == 'public'
    end
    
    def cg_cache
      Cache
    end

    def cg_logged_in?
      respond_to?(:logged_in?) && logged_in?
    end
end
