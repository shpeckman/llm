# src/llm/tools/search.cr
require "json"
require "../tool"
require "./workspace"

module LLM
  module SearchToolSupport
    include WorkspacePaths

    private def string_arg(arguments : JSON::Any, key : String) : String
      raw = arguments[key]?
      raise SearchArgumentError.new("missing required argument '#{key}'") if raw.nil?
      value = raw.as_s?
      raise SearchArgumentError.new("argument '#{key}' must be a string") if value.nil?
      value
    end

    private def optional_string_arg(arguments : JSON::Any, key : String) : String?
      raw = arguments[key]?
      return nil if raw.nil? || raw.raw.nil?
      value = raw.as_s?
      raise SearchArgumentError.new("argument '#{key}' must be a string") if value.nil?
      value
    end

    private def int_arg(arguments : JSON::Any, key : String, default : Int32) : Int32
      raw = arguments[key]?
      return default if raw.nil? || raw.raw.nil?
      value = raw.as_i?
      raise SearchArgumentError.new("argument '#{key}' must be an integer") if value.nil?
      value.to_i
    end
  end

  private class SearchArgumentError < Exception
  end

  class GlobTool < Tool::Custom
    include SearchToolSupport

    MAX_RESULTS = 500

    getter workspace : String

    def initialize(@workspace : String = Dir.current)
      @workspace = File.expand_path(@workspace)
    end

    def name : String
      "glob"
    end

    def description : String
      "Find files in the workspace matching a glob pattern (e.g. \"**/*.cr\"). " \
      "Returns matching paths relative to the workspace, sorted."
    end

    def parameters_schema : JSON::Any
      JSON.parse(%({
        "type": "object",
        "properties": {
          "pattern": {
            "type": "string",
            "description": "Glob pattern to match, e.g. '*.cr' or 'src/**/*.cr'."
          },
          "path": {
            "type": "string",
            "description": "Directory to search in, absolute or relative to the workspace (default: the workspace)."
          }
        },
        "required": ["pattern"],
        "additionalProperties": false
      }))
    end

    def execute(arguments : JSON::Any) : String
      begin
        pattern = string_arg(arguments, "pattern")
        path    = optional_string_arg(arguments, "path") || "."
      rescue ex : SearchArgumentError
        return "Error: #{ex.message}"
      end

      resolved = resolve_in_workspace(path)
      return escape_error(path) if resolved.nil?
      return "Error: directory not found: #{path}" unless File.directory?(resolved)

      matches = Dir.glob(File.join(resolved, pattern))
      matches.reject! { |match| escapes_workspace?(resolve_real(match)) }
      matches.map! { |match| relative_to_workspace(resolve_real(match)) }
      matches.sort!

      return "(no matches)" if matches.empty?

      shown     = matches.first(MAX_RESULTS)
      result    = shown.join('\n')
      remaining = matches.size - shown.size
      result += "\n[... #{remaining} more]" if remaining > 0
      result
    end
  end

  class GrepTool < Tool::Custom
    include SearchToolSupport

    MAX_FILE_SIZE  = 1_048_576
    MAX_LINE_CHARS =      2000

    getter workspace : String

    def initialize(@workspace : String = Dir.current)
      @workspace = File.expand_path(@workspace)
    end

    def name : String
      "grep"
    end

    def description : String
      "Search file contents in the workspace with a regular expression. " \
      "Returns matching lines as <path>:<line_number>:<line>. Hidden directories " \
      "and files larger than 1 MiB are skipped."
    end

    def parameters_schema : JSON::Any
      JSON.parse(%({
        "type": "object",
        "properties": {
          "pattern": {
            "type": "string",
            "description": "Regular expression to search for (Ruby/Crystal syntax)."
          },
          "path": {
            "type": "string",
            "description": "File or directory to search, absolute or relative to the workspace (default: the workspace)."
          },
          "glob": {
            "type": "string",
            "description": "Optional file-name filter like '*.cr'."
          },
          "max_results": {
            "type": "integer",
            "description": "Maximum number of matching lines to return (default 100)."
          }
        },
        "required": ["pattern"],
        "additionalProperties": false
      }))
    end

    def execute(arguments : JSON::Any) : String
      begin
        pattern     = string_arg(arguments, "pattern")
        path        = optional_string_arg(arguments, "path") || "."
        glob        = optional_string_arg(arguments, "glob")
        max_results = int_arg(arguments, "max_results", 100)
      rescue ex : SearchArgumentError
        return "Error: #{ex.message}"
      end
      return "Error: max_results must be >= 1" if max_results < 1

      regex = begin
        Regex.new(pattern)
      rescue ex
        return "Error: invalid regex: #{ex.message}"
      end

      resolved = resolve_in_workspace(path)
      return escape_error(path) if resolved.nil?
      return "Error: path not found: #{path}" unless File.exists?(resolved)

      files = [] of String
      collect_files(resolved, files)
      files.sort!

      matches       = [] of String
      stopped_early = false
      files.each do |file|
        relative = relative_to_workspace(file)
        next if glob && !glob_match?(glob, relative)
        if grep_file(file, relative, regex, matches, max_results)
          stopped_early = true
          break
        end
      end

      return "(no matches)" if matches.empty?

      result = matches.join('\n')
      result += "\n[... more matches]" if stopped_early
      result
    end

    private def collect_files(root : String, files : Array(String)) : Nil
      if File.file?(root)
        files << root unless File.info(root).size > MAX_FILE_SIZE
        return
      end
      Dir.each(root) do |entry|
        full = File.join(root, entry)
        if File.directory?(full)
          next if entry.starts_with?('.') || File.symlink?(full)
          collect_files(full, files)
        elsif File.file?(full) && !File.symlink?(full) && File.info(full).size <= MAX_FILE_SIZE
          files << full
        end
      end
    end

    private def glob_match?(pattern : String, relative : String) : Bool
      if pattern.includes?('/')
        File.match?(pattern, relative)
      else
        File.match?(pattern, File.basename(relative))
      end
    end

    private def grep_file(file : String, relative : String, regex : Regex,
                          matches : Array(String), limit : Int32) : Bool
      File.open(file, "r", encoding: "UTF-8", invalid: :skip) do |io|
        line_no = 0
        io.each_line do |line|
          line_no += 1
          next unless line =~ regex
          content = line.chomp
          content = content[0, MAX_LINE_CHARS] + "..." if content.size > MAX_LINE_CHARS
          matches << "#{relative}:#{line_no}:#{content}"
          return true if matches.size >= limit
        end
      end
      false
    rescue IO::Error
      false
    end
  end
end
