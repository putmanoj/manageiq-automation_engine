require 'drb'
module MiqAeEngine
  class DrbRemoteInvoker
    attr_accessor :drb_server, :num_methods

    def initialize(workspace)
      @workspace = workspace
      @num_methods = 0
    end

    def with_server(inputs, bodies, method_name, script_info)
      setup if num_methods.zero?
      self.num_methods += 1
      svc = MiqAeMethodService::MiqAeService.new(@workspace, inputs)
      begin
        yield build_method_content(bodies, method_name, svc.object_id, script_info)
      ensure
        svc.destroy # Reset inputs to empty to avoid storing object references
      end
    ensure
      self.num_methods -= 1
      teardown if num_methods.zero?
    end

    # This method is called by the client thread that runs for each request
    # coming into the server.
    # See https://github.com/ruby/ruby/blob/trunk/lib/drb/drb.rb#L1658
    # Previously we had used DRb.front but that gets compromised when multiple
    # DRb servers are running in the same process.
    def self.workspace
      if Thread.current['DRb'] && Thread.current['DRb']['server']
        Thread.current['DRb']['server'].front.workspace
      end
    end

    private

    # invocation

    def setup
      require 'drb/timeridconv'
      global_id_conv = DRb::TimerIdConv.new(drb_cache_timeout)
      drb_front = MiqAeMethodService::MiqAeServiceFront.new(@workspace)

      require 'tmpdir'
      Dir::Tmpname.create("automation_engine", nil) do |path|
        self.drb_server = DRb.start_service("drbunix://#{path}", drb_front, :idconv => global_id_conv)
        FileUtils.chmod(0o700, path)
      end
    end

    def teardown
      global_id_conv = drb_server.config[:idconv]
      drb_server.stop_service
      self.drb_server = nil

      # This hack was done to prevent ruby from leaking the
      # TimerIdConv thread.
      # https://bugs.ruby-lang.org/issues/12342 (has been fixed in ruby 2.4.0 preview 1)
      # also fixed in ruby_2_3 branch for the 2.3.2 release: https://github.com/ruby/ruby/commit/c20b07d5357d7cb73226b149431a658cde54a697
      if RUBY_VERSION <= "2.3.1"
        thread = global_id_conv
                 .try(:instance_variable_get, '@holder')
                 .try(:instance_variable_get, '@keeper')
        return unless thread

        thread.kill
        Thread.pass while thread.alive?
      end
    end

    def drb_cache_timeout
      1.hour
    end

    # code building

    def build_method_content(bodies, method_name, miq_ae_service_token, script_info)
      [
        dynamic_preamble(method_name, miq_ae_service_token, script_info),
        RUBY_METHOD_PREAMBLE,
        bodies,
        RUBY_METHOD_POSTSCRIPT
      ].flatten.join("\n")
    end

    def dynamic_preamble(method_name, miq_ae_service_token, script_info)
      script_info_yaml = script_info.to_yaml
      <<-RUBY.chomp
MIQ_URI = '#{drb_server.uri}'
MIQ_ID = #{miq_ae_service_token}
RUBY_METHOD_NAME = '#{method_name}'
SCRIPT_INFO_YAML = '#{script_info_yaml}'
RUBY_METHOD_PREAMBLE_LINES = #{RUBY_METHOD_PREAMBLE_LINES + 5 + script_info_yaml.lines.count}
RUBY
    end

    RUBY_METHOD_PREAMBLE = <<-RUBY.chomp.freeze
class AutomateMethodException < StandardError
end

begin
  require 'date'
  require 'rubygems'
  require 'logger'
  $:.unshift("#{Gem.loaded_specs['activesupport'].full_gem_path}/lib")
  require 'active_support/all'
  require 'socket'
  Socket.do_not_reverse_lookup = true  # turn off reverse DNS resolution

  require 'drb'
  require 'yaml'

  YAML.singleton_class.prepend(
    Module.new do
      def safe_load(yaml, aliases: false, **kwargs)
        super(yaml, aliases: true, **kwargs)
      end
    end
  )

  Time.zone = 'UTC'

  MIQ_OK    = 0
  MIQ_WARN  = 4
  MIQ_ERROR = 8
  MIQ_STOP  = 8
  MIQ_ABORT = 16

  DRbObject.send(:undef_method, :inspect)
  DRbObject.send(:undef_method, :id) if DRbObject.respond_to?(:id)
  # undefine Object#display which would be called over service#display
  DRbObject.send(:undef_method, :display)

  # DRb.start_service with no URI can attempt to resolve your local hostname[1], which:
  #   * is slower than just telling it to use a local address/socket
  #   * could be wrong and in some cases, it can be a remote IP to a DNS assistance program
  # [1] https://github.com/ruby/ruby/blob/v2_6_5/lib/drb/drb.rb#L879-L884
  require 'tmpdir'
  Dir::Tmpname.create("automation_client", nil) do |path|
    DRb.start_service("drbunix://\#{path}")
    FileUtils.chmod(0o700, path)
  end

  $evmdrb = DRbObject.new_with_uri(MIQ_URI)
  raise AutomateMethodException,"Cannot create DRbObject for uri=\#{MIQ_URI}" if $evmdrb.nil?
  $evm = $evmdrb.find(MIQ_ID)
  raise AutomateMethodException,"Cannot find Service for id=\#{MIQ_ID} and uri=\#{MIQ_URI}" if $evm.nil?
  MIQ_ARGS = $evm.inputs

  # Setup stdout and stderr to go through the logger on the MiqAeService instance ($evm)
  silence_warnings { STDOUT.close; STDOUT = $stdout = $evm.stdout ; nil}
  silence_warnings { STDERR.close; STDERR = $stderr = $evm.stderr ; nil}

rescue Exception => err
  STDERR.puts('The following error occurred during inline method preamble evaluation:')
  STDERR.puts("  \#{err.class}: \#{err.message}")
  STDERR.puts("  \#{err.backtrace.join('\n')}") unless err.kind_of?(AutomateMethodException)
  raise
end

class Exception
  def filter_backtrace(callers)
    return callers unless callers.respond_to?(:collect)

    callers.collect do |c|
      file, line, context = c.split(':')
      if file == "-"
        fqname, line = get_file_info(line.to_i - RUBY_METHOD_PREAMBLE_LINES)
        [fqname, line, context].join(':')
      else
        c
      end
    end
  end

  def backtrace_with_evm
    value = backtrace_without_evm
    value ? filter_backtrace(value) : value
  end

  def get_file_info(line)
    script_info = YAML.safe_load(SCRIPT_INFO_YAML, permitted_classes: [Range])
    script_info.each do |fqname, range|
      return fqname, line - range.begin if range.cover?(line)
    end
    return RUBY_METHOD_NAME, line
  end

  alias backtrace_without_evm backtrace
  alias backtrace backtrace_with_evm
end

begin
RUBY

    RUBY_METHOD_PREAMBLE_LINES = RUBY_METHOD_PREAMBLE.lines.count

    RUBY_METHOD_POSTSCRIPT = <<-RUBY.freeze
rescue Exception => err
  unless err.kind_of?(SystemExit)
    $evm.log('error', 'The following error occurred during method evaluation:')
    $evm.log('error', "  \#{err.class}: \#{err.message}")
    $evm.log('error', "  \#{err.backtrace[0..-2].join('\n')}")
  end
  raise
ensure
  $evm.disconnect_sql
end
RUBY
  end
end
