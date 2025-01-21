require 'benchmark'
require 'securerandom'

class SPARQL::Client
  class Logging
    attr_accessor :logger
    attr_accessor :redis
    attr_accessor :enabled

    REDIS_EXPIRY = 86_400 # 24 hours

    def initialize(redis:, redis_key: 'query_logs', redis_expiry: REDIS_EXPIRY, logger: nil)
      @redis = redis
      @logger = logger
      @redis_key = redis_key
      @redis_expiry = redis_expiry
      @enabled = !logger.nil?
    end

    def log(query, id: SecureRandom.uuid, cached: nil, user: nil, &block)
      return block.call unless @enabled

      time = Benchmark.realtime do
        result = block.call
        cached = !result.nil? if cached.nil?
      end
      info(query, id: id, cached: cached, user: user, execution_time: time)
    end

    def info(query, id: SecureRandom.uuid, cached: 'null', user: 'null', execution_time: 0)
      timestamp = Time.now.iso8601
      entry = {
        id: id,
        timestamp: timestamp,
        query: query.to_s,
        cached: cached,
        user: user,
        execution_time: execution_time.round(3).to_s
      }

      @logger&.info("SPARQL: #{query} (#{execution_time}s) | Cached: #{cached} | User: #{user}")
      return if @redis.nil?

      key = "#{@redis_key}-#{id}-#{timestamp}"
      entry = encode_data(entry)
      return if entry.nil?

      @redis.set(key, entry)
      @redis.expire(key, @redis_expiry)
    end

    def get_logs
      keys = @redis.keys("#{@redis_key}-*")
      logs = keys.map { |key| JSON.parse(Marshal.load(@redis.get(key))) }
      logs.sort_by { |log| Time.parse(log['timestamp']) }.reverse
    end

    def queries_last_n_seconds(seconds)
      current_time = Time.now
      filtered_logs = []
      cursor = '0'
      loop do
        cursor, keys = @redis.scan(cursor, match: "#{@redis_key}-*", count: 100)
        keys.each do |key|
          timestamp = key.split('-').last
          next unless timestamp && timestamp.include?('T')

          log_time = Time.parse(timestamp)
          if (current_time - log_time) <= seconds
            log = JSON.parse(Marshal.load(@redis.get(key)))
            filtered_logs << log
          end
        end

        break if cursor == '0' # Exit loop when scan cursor is back to 0
      end

      filtered_logs.sort_by { |log| Time.parse(log['timestamp']) }.reverse
    end

    def logger=(logger)
      @logger = logger
      @enabled = !logger.nil?
    end

    private

    def encode_data(entry)
      data = Marshal.dump(entry.to_json)
      if data.length > 50e6 # 50MB of marshal object
        # avoid large entries to go in the cache
        puts "Entry too large to be stored in cache"
        return nil
      end
      data
    end

    def decode_data(data)
      Marshal.load(data)
    end

  end
end
