# src/llm/tools/files.cr
require "json"
require "../tool"
require "./workspace"

module LLM
  module FileToolSupport
    include WorkspacePaths

    private def string_arg(arguments : JSON::Any, key : String) : String
      raw = arguments[key]?
      raise ToolArgumentError.new("missing required argument '#{key}'") if raw.nil?
      value = raw.as_s?
      raise ToolArgumentError.new("argument '#{key}' must be a string") if value.nil?
      value
    end

    private def int_arg(arguments : JSON::Any, key : String, default : Int32) : Int32
      raw = arguments[key]?
      return default if raw.nil? || raw.raw.nil?
      value = raw.as_i?
      raise ToolArgumentError.new("argument '#{key}' must be an integer") if value.nil?
      value.to_i
    end

    private def bool_arg(arguments : JSON::Any, key : String, default : Bool) : Bool
      raw = arguments[key]?
      return default if raw.nil? || raw.raw.nil?
      value = raw.as_bool?
      raise ToolArgumentError.new("argument '#{key}' must be a boolean") if value.nil?
      value
    end
  end

  private class ToolArgumentError < Exception
  end

  class ReadFileTool < Tool::Custom
    include FileToolSupport

    MAX_LINE_CHARS = 2000

    getter workspace : String

    def initialize(@workspace : String = Dir.current)
      @workspace = File.expand_path(@workspace)
    end

    def name : String
      "read_file"
    end

    def description : String
      "Read a file from the workspace with line numbers (like cat -n). " \
      "Lines are numbered from 1; use offset/limit to page through large files."
    end

    def parameters_schema : JSON::Any
      JSON.parse(%({
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "Path to the file, absolute or relative to the workspace."
          },
          "offset": {
            "type": "integer",
            "description": "1-based line number to start reading from (default 1)."
          },
          "limit": {
            "type": "integer",
            "description": "Maximum number of lines to return (default 2000)."
          }
        },
        "required": ["path"],
        "additionalProperties": false
      }))
    end

    def execute(arguments : JSON::Any) : String
      begin
        path   = string_arg(arguments, "path")
        offset = int_arg(arguments, "offset", 1)
        limit  = int_arg(arguments, "limit", 2000)
      rescue ex : ToolArgumentError
        return "Error: #{ex.message}"
      end
      return "Error: offset must be >= 1" if offset < 1
      return "Error: limit must be >= 1" if limit < 1

      resolved = resolve_in_workspace(path)
      return escape_error(path) if resolved.nil?
      return "Error: file not found: #{path}" unless File.exists?(resolved)
      return "Error: path is a directory: #{path}" if File.directory?(resolved)

      lines     = [] of String
      truncated = false
      File.open(resolved) do |file|
        line_no = 0
        file.each_line do |line|
          line_no += 1
          next if line_no < offset
          if lines.size >= limit
            truncated = true
            break
          end
          lines << "#{line_no}\t#{truncate_line(line.chomp)}"
        end
      end

      result = lines.join("\n")
      result += "\n[truncated at #{limit} lines]" if truncated
      result
    end

    private def truncate_line(line : String) : String
      line.size > MAX_LINE_CHARS ? line[0, MAX_LINE_CHARS] + "..." : line
    end
  end

  class WriteFileTool < Tool::Custom
    include FileToolSupport

    getter workspace : String

    def initialize(@workspace : String = Dir.current)
      @workspace = File.expand_path(@workspace)
    end

    def name : String
      "write_file"
    end

    def description : String
      "Write content to a file in the workspace, creating parent directories " \
      "as needed and overwriting any existing file."
    end

    def parameters_schema : JSON::Any
      JSON.parse(%({
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "Path to the file, absolute or relative to the workspace."
          },
          "content": {
            "type": "string",
            "description": "Full content to write to the file."
          }
        },
        "required": ["path", "content"],
        "additionalProperties": false
      }))
    end

    def execute(arguments : JSON::Any) : String
      begin
        path    = string_arg(arguments, "path")
        content = string_arg(arguments, "content")
      rescue ex : ToolArgumentError
        return "Error: #{ex.message}"
      end

      resolved = resolve_in_workspace(path)
      return escape_error(path) if resolved.nil?

      begin
        Dir.mkdir_p(File.dirname(resolved))
        File.write(resolved, content)
      rescue ex
        return "Error: could not write #{path}: #{ex.message}"
      end
      "wrote #{content.bytesize} bytes to #{path}"
    end
  end

  class EditFileTool < Tool::Custom
    include FileToolSupport

    getter workspace : String

    def initialize(@workspace : String = Dir.current)
      @workspace = File.expand_path(@workspace)
    end

    def name : String
      "edit_file"
    end

    def description : String
      "Replace exact text in a workspace file. By default the old_string must " \
      "occur exactly once; set replace_all to replace every occurrence."
    end

    def parameters_schema : JSON::Any
      JSON.parse(%({
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "Path to the file, absolute or relative to the workspace."
          },
          "old_string": {
            "type": "string",
            "description": "Exact text to find; must be non-empty."
          },
          "new_string": {
            "type": "string",
            "description": "Replacement text."
          },
          "replace_all": {
            "type": "boolean",
            "description": "Replace all occurrences instead of requiring a unique match (default false)."
          }
        },
        "required": ["path", "old_string", "new_string"],
        "additionalProperties": false
      }))
    end

    def execute(arguments : JSON::Any) : String
      begin
        path        = string_arg(arguments, "path")
        old_string  = string_arg(arguments, "old_string")
        new_string  = string_arg(arguments, "new_string")
        replace_all = bool_arg(arguments, "replace_all", false)
      rescue ex : ToolArgumentError
        return "Error: #{ex.message}"
      end
      return "Error: old_string must not be empty" if old_string.empty?

      resolved = resolve_in_workspace(path)
      return escape_error(path) if resolved.nil?
      return "Error: file not found: #{path}" unless File.exists?(resolved)
      return "Error: path is a directory: #{path}" if File.directory?(resolved)

      content = File.read(resolved)
      count   = count_occurrences(content, old_string)
      return "Error: old_string not found in #{path}" if count == 0
      if count > 1 && !replace_all
        return "Error: old_string occurs #{count} times in #{path}; use replace_all to replace all"
      end

      replaced = replace_all ? content.gsub(old_string, new_string) : content.sub(old_string, new_string)
      begin
        File.write(resolved, replaced)
      rescue ex
        return "Error: could not write #{path}: #{ex.message}"
      end
      "replaced #{count} occurrence(s) in #{path}"
    end

    private def count_occurrences(haystack : String, needle : String) : Int32
      count = 0
      start = 0
      while idx = haystack.index(needle, start)
        count += 1
        start = idx + needle.size
      end
      count
    end
  end
end
