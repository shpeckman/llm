# src/llm/tools/workspace.cr
module LLM
  module WorkspacePaths
    private def expand_path(path : String) : String
      File.expand_path(path, @workspace)
    end

    private def real_workspace : String
      File.exists?(@workspace) ? File.realpath(@workspace) : @workspace
    end

    private def workspace_prefix : String
      workspace = real_workspace
      workspace.ends_with?(File::SEPARATOR) ? workspace : workspace + File::SEPARATOR
    end

    private def escapes_workspace?(resolved : String) : Bool
      resolved != real_workspace && !resolved.starts_with?(workspace_prefix)
    end

    private def resolve_real(expanded : String) : String
      return File.realpath(expanded) if File.exists?(expanded)
      missing = [] of String
      current = expanded
      until File.exists?(current)
        parent = File.dirname(current)
        break if parent == current
        missing.unshift(File.basename(current))
        current = parent
      end
      base = File.exists?(current) ? File.realpath(current) : current
      missing.reduce(base) { |acc, part| File.join(acc, part) }
    end

    private def resolve_in_workspace(path : String) : String?
      resolved = resolve_real(expand_path(path))
      escapes_workspace?(resolved) ? nil : resolved
    end

    private def relative_to_workspace(resolved : String) : String
      prefix = workspace_prefix
      resolved.starts_with?(prefix) ? resolved[prefix.size..] : resolved
    end

    private def escape_error(path : String) : String
      "Error: path escapes workspace: #{path}"
    end
  end
end
