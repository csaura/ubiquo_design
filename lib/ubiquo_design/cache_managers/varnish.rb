module UbiquoDesign
  module CacheManagers
    # Varnish implementation for the cache manager
    class Varnish < UbiquoDesign::CacheManagers::Base

      class << self

        # This method is called when rendering +page+ and returns a hash where
        # the keys are the ids of the page widgets that are esi widgets,
        # and the value is an esi:include tag
        def multi_get(page, options = {})
          {}.tap do |widgets_by_id|
            request = options[:scope].request
            page.blocks.each do |block|
              block.real_block.widgets.each do |widget|
                if render_esi_widget?(widget)
                  esi_url = if widget.has_unique_url?
                    widget.url
                  else
                    new_params = request.query_parameters.merge('widget' => widget.id)
                    request.url.gsub("?#{request.query_string}", '') + "?#{new_params.to_query}"
                  end
                  widgets_by_id[widget.id] = "<esi:include src=#{esi_url.to_json} />"
                end
              end
            end
          end
        end

        # Caches the content of a widget
        # Simply return, since the real caching is done by Varnish when the request is finished
        def cache(widget_id, contents, options = {}); end

        # Returns true if a widget is a esi widget and we are rendering widgets as esi
        def render_esi_widget?(widget)
          defined?(ESI_RENDERING_ENABLED) && esi_widget?(widget)
        end

        # Returns true if the widget is an esi widget
        def esi_widget?(widget)
          !widget.respond_to?(:skip_esi?) || !widget.skip_esi?
        end

        # Expires the applicable content of a widget given its id
        # This means all the urls where the widget is cached
        # +widget+ is a Widget instance
        # +options+ are used in the absolute_url calculation, and includes at minimum
        #   the :scope of the expiration.
        #   Use :loose => true is you want the url to match loosely at the right
        #     (e.g. to expire too /my/url/extended if the page is at /my/url)
        def expire(widget, options = {})
          Rails.logger.debug "Expiring widget ##{widget.id} in Varnish"

          base_url = widget.page.absolute_url(options)
          widget_url = widget.url.gsub(/\?.*$/, '') if widget.has_unique_url?
          loose = "[^\\?]*" if options[:loose]

          # We ban all the urls of the related page that also contain the widget id
          # e.g. /url/of/page?param=4&widget=42
          widget_urls = [widget_url || base_url, "#{loose}\\?.*widget=#{widget.id}"]

          # And we also ban all the urls that do not contain the widget param
          # (i.e. the "full page", which can have different representations if
          # it has different params).
          # This is needed since else the esi fragment would be new,
          # but the page would still be cached.
          # The other cached pages with this page url and the "widget" param
          # are in fact other widgets of this page, which have not been modified
          # e.g. /url/of/page?param=4 will be expired; /url/of/page?param=4&widget=1 won't.
          page_urls = [base_url, "#{loose}($|\\?(?!.*(?<=[\\?|&])widget=))"]

          # Now do the real job. This is the correct order to avoid recaching old data
          #
          # Only expire the widget if is an esi widget (to skip unnecessary bans for skip_esi widgets)

          ban(widget_urls) if esi_widget?(widget)

          # And only expire the page if the widget is not shared (too many potential pages)

          ban(page_urls) unless widget.has_unique_url?
        end

        # Expires a +page+, with all its possibles urls and params
        def expire_page(page)
          Rails.logger.debug "Expiring page ##{page.id} in Varnish"
          expire_url(page.absolute_url)
        end

        def expire_url(url, regexp = nil)
          Rails.logger.debug "Expiring url '#{url}' in Varnish"
          # We ban the url with the given regexp, if any
          ban([url, regexp]) if regexp
          # We cannot simply ban url* since url could be a segment of
          # another page, so:
          # ban the url with params
          ban([url, "\\?"])
          # ban the exact page url, with or without trailing slash
          ban([url, "[\/]?$"])
        end

        def uhook_run_behaviour(controller)
          controller.varnish_expires_in ::Widget::WIDGET_TTL[:default] if controller.widget_request?
        end

        protected

        # Bans all urls that match +url+, which is an array with a
        # regexp-escapable part and an already escaped one that is appended
        # after the final slash.
        # Note that +url+ is strictly interpreted, as '^' is prepended
        def ban(url)
          # Get the base url from the related page, without the possible
          # trailing slash. It is appended as optional later (to expire both)
          base_url = url.first.gsub(/\/$/, '')

          # Parse the url and separate the host and the path+query
          parsed_url_for_host = URI.parse(url.first)
          host = parsed_url_for_host.host

          # delete the host from the base_url
          base_url_without_host = base_url.sub("#{parsed_url_for_host.scheme}://#{host}", '')

          # Varnish 2.1 required to double-escape in order to get it as a correct regexp
          # result_url = Regexp.escape(base_url_without_host).gsub('\\'){'\\\\'} + '/?' + url.last
          # Varnish 3 needs it only escaped once
          result_url = '^' + Regexp.escape(base_url_without_host) + '/?' + url.last

          varnish_request('BAN', result_url, host)
        end

        # Sends a request with the required +method+ to the given +url+
        # The +host+ parameter, if supplied, is used as the "Host:" header
        def varnish_request method, url, host = nil
          Rails.logger.debug "Varnish #{method} request for url #{url} and host #{host}"

          headers = {'Host' => host} if host

          begin
            VarnishServer.alive.each do |server|
              http = Net::HTTP.new(server.host, server.port)
              #http.set_debug_output($stderr)
              http.send_request(method, url, nil, headers || {})
            end
          rescue
            Rails.logger.warn "Cache is not available, impossible to delete cache: "+ $!.inspect
          end
        end

       end

    end
  end
end
