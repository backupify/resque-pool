class Resque::Pool
  class PooledWorker < ::Resque::Worker

    def initialize(*args)
      @pool_master_pid = Process.pid
      super
    end

    def pool_master_has_gone_away?
      @pool_master_pid && @pool_master_pid != Process.ppid
    end

    # override +shutdown?+ method
    def shutdown?
      super || pool_master_has_gone_away?
    end


    def procline_with_pool_name(*args)
      pool_name = Resque::Pool.pool_name || 'default'

      procline_without_pool_name(*args)
      $0 += " [pool: #{pool_name}]"
    end

    alias_method :procline_without_pool_name, :procline
    alias_method :procline, :procline_with_pool_name
  end
end
