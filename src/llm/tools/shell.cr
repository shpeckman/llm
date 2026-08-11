# src/llm/tools/shell.cr
require "json"
require "../tool"

lib LibC
  fun kill(pid : PidT, sig : Int) : Int
end

module LLM
  class CappedIO < IO
    getter head_limit : Int32
    getter tail_limit : Int32

    def initialize(@head_limit : Int32, @tail_limit : Int32)
      @head         = IO::Memory.new
      @tail_buf     = Bytes.new(@tail_limit)
      @tail_size    = 0
      @tail_written = 0_i64
    end

    def read(slice : Bytes) : Int32
      0
    end

    def write(slice : Bytes) : Nil
      return if slice.empty?
      head_room = @head_limit - @head.size
      if head_room > 0
        count = Math.min(head_room, slice.size)
        @head.write(slice[0, count])
        slice = slice[count..]
        return if slice.empty?
      end

      @tail_written += slice.size
      if @tail_size + slice.size <= @tail_limit
        slice.copy_to(@tail_buf + @tail_size)
        @tail_size += slice.size
      elsif slice.size >= @tail_limit
        (slice + (slice.size - @tail_limit)).copy_to(@tail_buf.to_unsafe, @tail_limit)
        @tail_size = @tail_limit
      else
        overflow = @tail_size + slice.size - @tail_limit
        @tail_buf.to_unsafe.move_from(@tail_buf.to_unsafe + overflow, @tail_size - overflow)
        slice.copy_to(@tail_buf + (@tail_size - overflow))
        @tail_size = @tail_limit
      end
    end

    def dropped_bytes : Int64
      @tail_written - @tail_size
    end

    def head : String
      @head.to_s
    end

    def tail : String
      String.new(@tail_buf[0, @tail_size])
    end
  end

  class ShellTool < Tool::Custom
    MAX_OUTPUT_CHARS  = 30_000
    TRUNCATION_MARKER = "\n...[truncated]...\n"
    HEAD_CHARS        = 15_000
    TAIL_CHARS        = MAX_OUTPUT_CHARS - HEAD_CHARS - TRUNCATION_MARKER.size
    TERM_GRACE        = 2.seconds

    getter workspace : String

    def initialize(@workspace : String = Dir.current)
      @workspace = File.expand_path(@workspace)
      @setsid    = !Process.find_executable("setsid").nil?
    end

    def name : String
      "shell"
    end

    def description : String
      "Run a shell command via /bin/sh -c inside the workspace directory. " \
      "Returns the exit code plus captured stdout and stderr."
    end

    def parameters_schema : JSON::Any
      JSON.parse(%({
        "type": "object",
        "properties": {
          "command": {
            "type": "string",
            "description": "Shell command to execute with /bin/sh -c."
          },
          "timeout_seconds": {
            "type": "integer",
            "description": "Kill the command after this many seconds (default 120)."
          }
        },
        "required": ["command"],
        "additionalProperties": false
      }))
    end

    def execute(arguments : JSON::Any) : String
      raw_command = arguments["command"]?
      return "Error: missing required argument 'command'" if raw_command.nil?
      command = raw_command.as_s?
      return "Error: argument 'command' must be a string" if command.nil?

      timeout_seconds = 120
      if raw_timeout = arguments["timeout_seconds"]?
        unless raw_timeout.raw.nil?
          parsed = raw_timeout.as_i?
          return "Error: argument 'timeout_seconds' must be an integer" if parsed.nil?
          timeout_seconds = parsed.to_i
        end
      end
      return "Error: timeout_seconds must be >= 1" if timeout_seconds < 1

      stdout = CappedIO.new(HEAD_CHARS, TAIL_CHARS)
      stderr = CappedIO.new(HEAD_CHARS, TAIL_CHARS)
      process = begin
        spawn_command(command, stdout, stderr)
      rescue ex
        return "Error: could not start command: #{ex.message}"
      end

      status    = wait_for(process, timeout_seconds.seconds)
      timed_out = status.nil?
      if timed_out
        status = terminate_with_escalation(process)
      end

      String.build do |io|
        io << "Error: command timed out after " << timeout_seconds << "s\n" if timed_out
        io << "exit_code: " << (status.try(&.exit_code?) || -1) << '\n'
        io << truncate_output(combined_output(render(stdout), render(stderr)))
      end
    end

    private def spawn_command(command : String, stdout : IO, stderr : IO) : Process
      if @setsid
        Process.new("setsid", ["/bin/sh", "-c", command],
          output: stdout, error: stderr, chdir: @workspace)
      else
        Process.new("/bin/sh", ["-c", command],
          output: stdout, error: stderr, chdir: @workspace)
      end
    end

    private def wait_for(process : Process, span : Time::Span) : Process::Status?
      deadline = Time.instant + span
      until process.terminated?
        return nil if Time.instant > deadline
        sleep 10.milliseconds
      end
      process.wait
    end

    private def terminate_with_escalation(process : Process) : Process::Status
      signal_target(process, Signal::TERM)
      status = wait_for(process, TERM_GRACE)
      return status if status
      signal_target(process, Signal::KILL)
      process.wait
    end

    private def signal_target(process : Process, signal : Signal) : Nil
      return if process.terminated?
      if @setsid
        LibC.kill(-process.pid, signal.value)
      else
        process.signal(signal)
      end
    end

    private def render(io : CappedIO) : String
      if io.dropped_bytes > 0
        io.head + TRUNCATION_MARKER + io.tail
      else
        io.head + io.tail
      end
    end

    private def combined_output(stdout : String, stderr : String) : String
      return stdout if stderr.empty?
      separator = stdout.empty? || stdout.ends_with?('\n') ? "" : "\n"
      stdout + separator + "[stderr:]\n" + stderr
    end

    private def truncate_output(text : String) : String
      return text if text.size <= MAX_OUTPUT_CHARS
      head = text[0, HEAD_CHARS]
      tail = text[text.size - TAIL_CHARS, TAIL_CHARS]
      head + TRUNCATION_MARKER + tail
    end
  end
end
