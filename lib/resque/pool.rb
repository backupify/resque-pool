# -*- encoding: utf-8 -*-
require 'resque'
require 'resque/pool/version'
require 'resque/pool/logging'
require 'resque/pool/pooled_worker'
require 'fcntl'
require 'yaml'

module Resque
  class Pool
    SIG_QUEUE_MAX_SIZE = 5
    DEFAULT_WORKER_INTERVAL = 5
    QUEUE_SIGS = [ :QUIT, :INT, :TERM, :USR1, :USR2, :CONT, :HUP, :WINCH, ]
    CHUNK_SIZE = (16 * 1024)

    include Logging
    attr_reader :config
    attr_reader :workers

    def initialize(config)
      init_config(config)
      @workers = {}
      procline "(initialized)"
    end

    # Config: after_prefork {{{

    # The `after_prefork` hook will be run in workers if you are using the
    # preforking master worker to save memory. Use this hook to reload
    # database connections and so forth to ensure that they're not shared
    # among workers.
    #
    # Call with a block to set the hook.
    # Call with no arguments to return the hook.
    def self.after_prefork(&block)
      block ? (@after_prefork = block) : @after_prefork
    end

    # Set the after_prefork proc.
    def self.after_prefork=(after_prefork)
      @after_prefork = after_prefork
    end

    def call_after_prefork!
      self.class.after_prefork && self.class.after_prefork.call
    end

    # }}}
    # Config: class methods to start up the pool using the default config {{{

    @config_files = ["resque-pool.yml", "config/resque-pool.yml"]
    class << self; attr_accessor :config_files; end
    def self.choose_config_file
      if ENV["RESQUE_POOL_CONFIG"]
        ENV["RESQUE_POOL_CONFIG"]
      else
        @config_files.detect { |f| File.exist?(f) }
      end
    end

    def self.run
      if GC.respond_to?(:copy_on_write_friendly=)
        GC.copy_on_write_friendly = true
      end
      Resque::Pool.new(choose_config_file).start.join
    end

    # }}}
    # Config: load config and config file {{{

    def config_file
      @config_file || (!@config && ::Resque::Pool.choose_config_file)
    end

    def init_config(config)
      case config
      when String, nil
        @config_file = config
      else
        @config = config.dup
      end
      load_config
    end

    def load_config
      if config_file
        @config = YAML.load_file(config_file)
      else
        @config ||= {}
      end
      environment and @config[environment] and config.merge!(@config[environment])
      config.delete_if {|key, value| value.is_a? Hash }
    end

    def environment
      if defined? Rails
        Rails.env
      else
        ENV['RACK_ENV'] || ENV['RAILS_ENV'] || ENV['RESQUE_ENV']
      end
    end

    # }}}

    # Sig handlers and self pipe management {{{

    def self_pipe; @self_pipe ||= [] end
    def sig_queue; @sig_queue ||= [] end

    def init_self_pipe!
      self_pipe.each { |io| io.close rescue nil }
      self_pipe.replace(IO.pipe)
      self_pipe.each { |io| io.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC) }
    end

    def init_sig_handlers!
      QUEUE_SIGS.each { |sig| trap_deferred(sig) }
      trap(:CHLD)     { |_| awaken_master }
    end

    def awaken_master
      begin
        self_pipe.last.write_nonblock('.') # wakeup master process from select
      rescue Errno::EAGAIN, Errno::EINTR
        # pipe is full, master should wake up anyways
        retry
      end
    end

    class QuitNowException < Exception; end
    # defer a signal for later processing in #join (master process)
    def trap_deferred(signal)
      trap(signal) do |sig_nr|
        if @waiting_for_reaper && [:INT, :TERM].include?(signal)
          log "Recieved #{signal}: short circuiting QUIT waitpid"
          raise QuitNowException
        end
        if sig_queue.size < SIG_QUEUE_MAX_SIZE
          sig_queue << signal
          awaken_master
        else
          log "ignoring SIG#{signal}, queue=#{sig_queue.inspect}"
        end
      end
    end

    def reset_sig_handlers!
      QUEUE_SIGS.each {|sig| trap(sig, "DEFAULT") }
    end

    def handle_sig_queue!
      case signal = sig_queue.shift
      when :USR1, :USR2, :CONT
        log "#{signal}: sending to all workers"
        signal_all_workers(signal)
      when :HUP
        log "HUP: reload config file and reload logfiles"
        load_config
        Logging.reopen_logs!
        log "HUP: gracefully shutdown old children (which have old logfiles open)"
        signal_all_workers(:QUIT)
        log "HUP: new children will inherit new logfiles"
        maintain_worker_count
      when :WINCH
        log "WINCH: gracefully stopping all workers"
        @config = {}
        maintain_worker_count
      when :QUIT
        log "QUIT: graceful shutdown, waiting for children"
        signal_all_workers(:QUIT)
        reap_all_workers(0) # will hang until all workers are shutdown
        :break
      when :INT
        log "INT: immediate shutdown (graceful worker shutdown)"
        signal_all_workers(:QUIT)
        :break
      when :TERM
        log "TERM: immediate shutdown (and immediate worker shutdown)"
        signal_all_workers(:TERM)
        :break
      end
    end

    # }}}
    # start, join, and master sleep {{{

    def start
      procline("(starting)")
      init_self_pipe!
      init_sig_handlers!
      maintain_worker_count
      procline("(started)")
      log "started manager"
      report_worker_pool_pids
      self
    end

    def report_worker_pool_pids
      if workers.empty?
        log "Pool is empty"
      else
        log "Pool contains worker PIDs: #{all_pids.inspect}"
      end
    end

    def join
      loop do
        reap_all_workers
        break if handle_sig_queue! == :break
        if sig_queue.empty?
          master_sleep
          monitor_memory_usage
          maintain_worker_count
        end
        procline("managing #{all_pids.inspect}")
      end
      procline("(shutting down)")
      #stop # gracefully shutdown all workers on our way out
      log "manager finished"
      #unlink_pid_safe(pid) if pid
    end

    def master_sleep
      begin
        ready = IO.select([self_pipe.first], nil, nil, 1) or return
        ready.first && ready.first.first or return
        loop { self_pipe.first.read_nonblock(CHUNK_SIZE) }
      rescue Errno::EAGAIN, Errno::EINTR
      end
    end

    # }}}
    # worker process management {{{

    def reap_all_workers(waitpid_flags=Process::WNOHANG)
      @waiting_for_reaper = waitpid_flags == 0
      begin
        loop do
          # -1, wait for any child process
          wpid, status = Process.waitpid2(-1, waitpid_flags)
          wpid or break
          worker = delete_worker(wpid)
          # TODO: close any file descriptors connected to worker, if any
          log "Reaped resque worker[#{status.pid}] (status: #{status.exitstatus}) queues: #{worker.queues.join(",")}"
        end
      rescue Errno::EINTR
        retry
      rescue Errno::ECHILD, QuitNowException
      end
    end

    def delete_worker(pid)
      worker = nil
      workers.detect do |queues, pid_to_worker|
        worker = pid_to_worker.delete(pid)
      end
      worker
    end

    def all_pids
      workers.map {|q,workers| workers.keys }.flatten
    end

    def signal_all_workers(signal)
      all_pids.each do |pid|
        Process.kill signal, pid
      end
    end

    def memory_usage(pid)
      smaps_filename = "/proc/#{pid}/smaps"
          
      #Grab actual memory usage from proc in MB
      begin
        mem_usage = `
          if [ -f #{smaps_filename} ];
            then
              grep Private_Dirty #{smaps_filename} | awk '{s+=$2} END {printf("%d", s/1000)}'
            else echo "0"
          fi
        `.to_i
        rescue Errno::EINTR
          retry
        end
    end
    
    def process_exists?(pid)
      begin
        ps_line = `ps -p #{pid} --no-header`
      rescue Errno::EINTR
        retry
      end
      !ps_line.nil? && ps_line.strip != ''
    end

    def hard_kill_workers
      @term_workers ||= []
      #look for workers that didn't terminate
      @term_workers.delete_if {|pid| !process_exists?(pid)}
      #send the rest a -9
      @term_workers.each {|pid| `kill -9 #{pid}`}
    end

    def add_killed_worker(pid)
      @term_workers ||= []
      @term_workers << pid if pid
    end

    def monitor_memory_usage
      #only check every minute
      if @last_mem_check.nil? || @last_mem_check < Time.now - 60
        hard_kill_workers

        all_pids.each do |pid|

          total_usage = memory_usage(pid)
          child_pid = find_child_pid(pid)
          
          total_usage += memory_usage(child_pid) if child_pid
          
          if total_usage > 500
            log "Terminating worker #{pid} for using #{total_usage}MB memory"
            stop_worker(pid)
          elsif total_usage > 250
            log "Gracefully shutting down worker #{pid} for using #{total_usage}MB memory"
            stop_worker(pid, :QUIT)
          end

        end

        @last_mem_check = Time.now
      end
    end

    def hostname
      begin
        @hostname ||= `hostname`.strip
      rescue Errno::EINTR
        retry
      end
    end

    def stop_worker(pid, signal=:TERM)
      begin
        worker = Resque.working.find do |w|
          host, worker_pid, queues = w.id.split(':')
          w if worker_pid.to_i == pid.to_i && host == hostname
        end
        if worker
          encoded_job = worker.job
          verb = signal == :QUIT ? 'Graceful' : 'Forcing'
          total_time = Time.now - Time.parse(encoded_job['run_at']) rescue 0
          log "#{verb} shutdown while processing: #{encoded_job} -- ran for #{'%.2f' % total_time}s"
        end

        Process.kill signal, pid
        if signal == :TERM
          add_killed_worker(pid)
          add_killed_worker(find_child_pid(pid))
        end
      rescue Errno::EINTR
        retry
      end
    end

    def find_child_pid(parent_pid)
      begin
        p = `ps --ppid #{parent_pid} -o pid --no-header`.to_i
        p == 0 ? nil : p
      rescue Errno::EINTR
        retry
      end
    end

    def orphaned_worker_count
      if @last_orphaned_check.nil? || @last_orphaned_check < Time.now - 60
        if @orphaned_pids.nil?
            printf_line = '%d %d\n'
          begin
            pids_with_parents = `ps -Af | grep resque | grep -v grep | grep -v resque-web | grep -v master | awk '{printf("%d %d\\n", $2, $3)}'`.split("\n")
          rescue Errno::EINTR
            retry
          end
          pids = pids_with_parents.collect {|x| x.split[0].to_i}
          parents = pids_with_parents.collect {|x| x.split[1].to_i}
          pids.delete_if {|x| parents.include?(x)}
          pids.delete_if {|x| all_pids.include?(x)}
          @orphaned_pids = pids
        elsif @orphaned_pids.size > 0
          @orphaned_pids.delete_if do |pid|
            begin
              ps_out = `ps --no-heading p #{pid}`
              ps_out.nil? || ps_out.strip == ''
            rescue Errno::EINTR
              retry
            end
          end
        end
        @last_orphaned_check = Time.now
        log "Current orphaned pids: #{@orphaned_pids}" if @orphaned_pids.size > 0
      end
      @orphaned_pids.size
    end

    # }}}
    # ???: maintain_worker_count, all_known_queues {{{

    def maintain_worker_count
      orphaned_offset = orphaned_worker_count / all_known_queues.size
      all_known_queues.each do |queues|
        delta = worker_delta_for(queues) - orphaned_offset
        spawn_missing_workers_for(queues, delta) if delta > 0
        quit_excess_workers_for(queues, delta)   if delta < 0
      end
    end

    def all_known_queues
      config.keys | workers.keys
    end

    # }}}
    # methods that operate on a single grouping of queues {{{
    # perhaps this means a class is waiting to be extracted

    def spawn_missing_workers_for(queues, delta)
      delta.times { spawn_worker!(queues) } if delta > 0
    end

    def quit_excess_workers_for(queues, delta)
      if delta < 0
        queue_pids = pids_for(queues)
        if queue_pids.size >= delta.abs
          queue_pids[0...delta.abs].each {|pid| Process.kill("QUIT", pid)}
        else
          queue_pids.each {|pid| Process.kill("QUIT", pid)}
        end
      end
    end

    def worker_delta_for(queues)
      config.fetch(queues, 0) - workers.fetch(queues, []).size
    end

    def pids_for(queues)
      workers[queues].keys
    end

    def spawn_worker!(queues)
      worker = create_worker(queues)
      pid = fork do
        log_worker "Starting worker #{worker}"
        call_after_prefork!
        reset_sig_handlers!
        #self_pipe.each {|io| io.close }
        begin
          worker.work(ENV['INTERVAL'] || DEFAULT_WORKER_INTERVAL) # interval, will block
        rescue Errno::EINTR
          log "Caught interrupted system call Errno::EINTR. Retrying."
          retry
        end
      end
      workers[queues] ||= {}
      workers[queues][pid] = worker
    end

    def create_worker(queues)
      queues = queues.to_s.split(',')
      worker = PooledWorker.new(*queues)
      worker.verbose = ENV['LOGGING'] || ENV['VERBOSE']
      worker.very_verbose = ENV['VVERBOSE']
      worker
    end

    # }}}

  end
end
