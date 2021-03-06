require "thread"
require "socket"
require "shellwords"
require "timeout"

module Command
  class Error < StandardError
    attr_reader :command, :result
    def initialize(command, result)
      @command = command
      @result = result
      super("#{command}: #{result}")
    end
  end

  module_function
  def detach_io
    require 'fcntl'
    [TCPSocket, ::File].each do |c|
      ObjectSpace.each_object(c) do |io|
        begin
          unless io.closed?
            io.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC)
          end
        rescue SystemCallError,IOError => e
        end
      end
    end
  end

  def run(cmd, *args)
    raise ArgumentError, "command isn't specified" if cmd.nil?
    if args.any? {|x| x.nil?}
      raise ArgumentError, "args has nil: #{args.inspect}"
    end
    in_r, in_w = IO.pipe
    out_r, out_w = IO.pipe
    err_r, err_w = IO.pipe
    pid = exit_status = nil
    Thread.exclusive do
      verbose = $VERBOSE
      # ruby(>=1.8)'s fork terminates other threads with warning messages
      $VERBOSE = nil
      pid = fork do
        $VERBOSE = verbose
        detach_io
        $stdin.reopen(in_r)
        in_r.close
        $stdout.reopen(out_w)
        $stderr.reopen(err_w)
        out_w.close
        err_w.close
        exec(cmd, *args.collect {|arg| arg.to_s})
        exit!(-1)
      end
      $VERBOSE = verbose
    end
    yield(out_r, in_w) if block_given?
    in_r.close unless in_r.closed?
    out_w.close unless out_w.closed?
    err_w.close unless err_w.closed?
    begin
      Timeout.timeout(10) do
        pid, status = Process.waitpid2(pid)
        [status.exited? && status.exitstatus.zero?, out_r.read, err_r.read]
      end
    rescue Timeout::Error
      Process.kill(:KILL, pid)
      [false, out_r.read, err_r.read, "killed"]
    end
  end
end
