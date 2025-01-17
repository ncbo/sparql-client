class SPARQL::Client
  class Cache
    attr_accessor :redis_cache

    def initialize(redis_cache: nil)
      @redis_cache = redis_cache if redis_cache
    end

    def add(key, value)
      cache_query_response(key, value)
    end

    def get(query, options)
      cached_query_response(query, options)
    end

    def invalidate(graphs)
      cache_invalidate_graph(graphs)
    end

    def key(query, options)
      query_cache_key(query, options)
    end

    def self.generate_cache_key(string, from)
      from = from.map { |x| x.to_s }.uniq.sort
      sorted_graphs = from.join ":"
      digest = Digest::MD5.hexdigest(string)
      from = from.map { |x| "sparql:graph:#{x}" }
      return { graphs: from, query: "sparql:#{sorted_graphs}:#{digest}" }
    end

    private

    def cache_invalidate_graph(graphs)
      return if @redis_cache.nil?
      graphs = [graphs] unless graphs.instance_of?(Array)
      graphs.each do |graph|
        attempts = 0
        begin
          graph = graph.to_s
          graph = "sparql:graph:#{graph}" unless graph.start_with?("sparql:graph:")
          if @redis_cache.exists?(graph)
            begin
              @redis_cache.del(graph)
            rescue => exception
              puts "warning: error in cache invalidation `#{exception}`"
            end
          end
        rescue Exception => e
          if attempts < 3
            attempts += 1
            sleep(5)
            retry
          end
        end
      end
    end

    def cache_query_response(keys, entry)
      # expiration = 1800 #1/2 hour
      data = Marshal.dump(entry)
      if data.length > 50e6 # 50MB of marshal object
        # avoid large entries to go in the cache
        return
      end
      keys[:graphs].each do |g|
        @redis_cache.sadd(g, keys[:query])
      end
      @redis_cache.set(keys[:query], data)
      #@redis_cache.expire(keys[:query],expiration)
    end

    def cache_key(query)
      return nil if query.options[:from].nil? || query.options[:from].empty?
      from = query.options[:from]
      from = [from] unless from.instance_of?(Array)
      SPARQL::Client::Cache.generate_cache_key(query.to_s, from)
    end

    def query_cache_key(query, options)
      if options[:graphs] || query.options[:graphs]
        cache_key = SPARQL::Client::Cache.generate_cache_key(query.to_s, options[:graphs] || query.options[:graphs])
      else
        cache_key = cache_key(query)
      end
      cache_key
    end

    def cached_query_response(query, options)
      return nil if query.respond_to?(:options) && query.options[:bypass_cache]

      if @redis_cache && (query.instance_of?(SPARQL::Client::Query) || options[:graphs])

        cache_key = query_cache_key(query, options)
        cache_response = @redis_cache.get(cache_key[:query])

        if options[:reload_cache] and options[:reload_cache] == true
          @redis_cache.del(cache_key[:query])
          cache_response = nil
        end

        if cache_response
          cache_key[:graphs].each do |g|
            unless @redis_cache.sismember(g, cache_key[:query])
              @redis_cache.del(cache_key[:query])
              cache_response = nil
              break
            end
          end

          return Marshal.load(cache_response) if cache_response
        end

        options[:cache_key] = cache_key
        nil
      end
    end
  end
end
