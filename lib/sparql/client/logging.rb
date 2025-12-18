require 'benchmark'
require 'securerandom'

class SPARQL::Client
  class Logging
    attr_accessor :logger
    attr_accessor :redis
    attr_accessor :enabled

    REDIS_EXPIRY = 86_400 # 24 hours
    REDIS_USER_EXPIRY = 2_592_000 # 30 days

    def initialize(redis:, redis_key: 'query_logs', redis_expiry: REDIS_EXPIRY, logger: nil, max_logs: 1000)
      @redis = redis
      @logger = logger
      @redis_key = redis_key
      @redis_expiry = redis_expiry
      @enabled = !logger.nil?
      @max_logs = max_logs
      @count_key = "count-#{@redis_key}"
      @user_count_key = "user-count-#{@redis_key}"
    end

    def log(query, id: SecureRandom.uuid, cached: nil, user: nil, &block)
      return block.call unless @enabled

      cached_nil = cached.nil?
      time = Benchmark.realtime do
        result = block.call
        cached = !result.nil? if cached_nil
      end
      info(query, id: id, cached: cached, user: user, execution_time: time) if !cached_nil || cached
    end

    def info(query, id: SecureRandom.uuid, cached: 'null', user: nil, execution_time: 0)
      timestamp = Time.now.iso8601
      user = Thread.current[:remote_user]&.id.to_s || user
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

      save_log(entry)
      update_user_count(user)
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
          timestamp = extract_timestamp_from_key(key)
          next if timestamp.nil?

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

    def users_query_count
      keys = @redis.keys("#{@user_count_key}-*")
      keys.map do |key|
        user = key.split('-').last
        count = @redis.get(key).to_i
        { user: user, count: count }
      end
    end

    def logger=(logger)
      @logger = logger
      @enabled = !logger.nil?
    end

    private

    def save_log(entry)
      key = "#{@redis_key}-#{entry[:id]}-#{entry[:timestamp]}"
      entry = encode_data(entry)
      return if entry.nil?

      @redis.set(key, entry)
      @redis.expire(key, @redis_expiry)
      @redis.incr(@count_key)

      enforce_log_limit(@redis.get(@count_key).to_i)
    end

    def extract_timestamp_from_key(key)
      # Extract the ISO8601 timestamp regardless of dashes in the UUID portion
      match = key.match(/\d{4}-\d{2}-\d{2}T[0-9:\.\+\-]+/)
      return nil unless match

      match[0]
    end

    def enforce_log_limit(log_count)
      return unless log_count >= @max_logs * 2

      keys = @redis.keys("#{@redis_key}-*")
      keys_with_timestamps = keys.map do |key|
        timestamp = extract_timestamp_from_key(key)
        [key, Time.parse(timestamp)] if timestamp
      end.compact

      keys_with_timestamps.sort_by! { |_, time| time }

      old_logs = keys_with_timestamps.first(keys_with_timestamps.size - @max_logs).map(&:first)

      @redis.del(*old_logs) unless old_logs.empty?

      if old_logs.any?
        old_count = @redis.get(@count_key).to_i
        @redis.set(@count_key, old_count - old_logs.size)
      end
    end

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

    def update_user_count(user)
      return if user.nil?
      user_key = "#{@user_count_key}-#{user}"
      user_count = @redis.get(user_key)
      user_count = user_count.nil? ? 1 : user_count.to_i + 1
      @redis.set(user_key, user_count)
      @redis.expire(user_key, REDIS_USER_EXPIRY)
    end

  end
end
