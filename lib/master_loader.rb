class DelayedResult
  def initialize(&resolver)
    @resolver = resolver
  end

  def then(&block)
    DelayedResult.new do
      block.call(value!)
    end
  end

  def self.zip(*results, &block)
    DelayedResult.new do
      results = results.map(&:value!)
      block.call(*results)
    end
  end

  def value!
    @value ||= @resolver.call.yield_self do |val|
      if val&.is_a?(DelayedResult)
        val.value!
      else
        val
      end
    end
  end

  def value
    value!
  end
end

class MasterLoader
  class Cache < ::Hash
    def compute_if_absent(key, &block)
      if self.has_key?(key)
        self.fetch(key)
      else
        self[key] = block.call(key)
      end
    end
  end

  class NoCache
    def compute_if_absent(_key)
      yield
    end
  end

  class Batch
    attr_accessor :name, :fulfilled

    def initialize(loader_block, name: nil, max_batch_size: Float::INFINITY)
      @name = name
      @queue = []
      @loader_block = loader_block
      @max_batch_size = max_batch_size
      @fulfilled = false
      @results = nil
    end

    def queue(key)
      @queue << key

      DelayedResult.new do
        results = if @fulfilled
                    @results
                  else
                    @fulfilled = true
                    r = @loader_block.call(@queue)
                    @results = if r.is_a?(DelayedResult)
                                 normalize_results(r.value!)
                               else
                                 normalize_results(r)
                               end
                  end

        unless results.key?(key)
          raise StandardError, "Batch loader didn't resolve a key: #{key}. Resolved keys: #{results.keys}"
        end

        results[key]
      end
    end

    def fulfilled?
      @fulfilled
    end

    private

    def normalize_results(results)
      unless results.is_a?(Array) || results.is_a?(Hash)
        raise TypeError, "Batch loader must return an Array or Hash, but returned: #{results.class.name}"
      end

      if @queue.size != results.size
        raise StandardError, "Batch loader must be instantiated with function that returns Array or Hash " \
          "of the same size as provided to it Array of keys" \
          "\n\nProvided keys:\n#{@queue}" \
          "\n\nReturned values:\n#{results}"
      end

      if results.is_a?(Array)
        Hash[@queue.zip(results)]
      elsif results.is_a?(Hash)
        results
      end
    end
  end

  attr_accessor :cache

  def initialize(**options, &block)
    unless block_given?
      raise TypeError, "Dataloader must be constructed with a block which accepts " \
        "Array and returns either Array or Hash of the same size (or Promise)"
    end

    @name = options.delete(:name)
    @cache = if options.has_key?(:cache)
               options.delete(:cache) || NoCache.new
             else
               Cache.new
             end
    @max_batch_size = options.fetch(:max_batch_size, Float::INFINITY)

    @interceptor = options.delete(:interceptor) || lambda { |n|
      lambda { |ids|
        n.call(ids)
      }
    }

    @loader_block = @interceptor.call(block)
  end

  def load(key)
    raise TypeError, "#load must be called with a key, but got: nil" if key.nil?

    result = retrieve_from_cache(key) do
      batch.queue(key)
    end

    if result.is_a?(DelayedResult)
      result
    else
      DelayedResult.new { result }
    end
  end

  def load_many(keys)
    raise TypeError, "#load_many must be called with an Array, but got: #{keys.class.name}" unless keys.is_a?(Array)

    delayed_results = keys.map(&method(:load))
    DelayedResult.new do
      delayed_results.map(&:value!)
    end
  end

  def batch
    if @batch.nil? || @batch.fulfilled?
      @batch = Batch.new(@loader_block, name: @name, max_batch_size: @max_batch_size)
    else
      @batch
    end
  end

  def retrieve_from_cache(key, &block)
    @cache.compute_if_absent(key, &block)
  end
end
