# src/llm/tool.cr
require "json"

module LLM::Tool
  NAME_PATTERN = /\A[a-zA-Z_][a-zA-Z0-9\-_]{2,63}\z/

  abstract class Custom
    @api_schema : JSON::Any?

    abstract def name : String
    abstract def description : String

    abstract def parameters_schema : JSON::Any

    abstract def execute(arguments : JSON::Any) : String

    def to_api_schema : JSON::Any
      @api_schema ||= JSON.parse({
        type:     "function",
        function: {
          name:        name,
          description: description,
          parameters:  parameters_schema,
        },
      }.to_json)
    end
  end

  class Registry
    include Enumerable(Custom)

    @tools   = [] of Custom
    @by_name = {} of String => Custom

    def initialize
    end

    def register(tool : Custom) : Custom
      name = tool.name
      unless NAME_PATTERN.matches?(name)
        raise ToolError.new("invalid tool name '#{name}': must be 3-64 characters, " \
                            "start with a letter or underscore, and contain only " \
                            "letters, digits, '-' or '_'")
      end
      if existing = @by_name[name]?
        @tools.map! { |candidate| candidate.same?(existing) ? tool : candidate }
      else
        @tools << tool
      end
      @by_name[name] = tool
      tool
    end

    def [](name : String) : Custom?
      @by_name[name]?
    end

    def each(& : Custom ->)
      @tools.each { |tool| yield tool }
    end

    def schemas : Array(JSON::Any)
      @tools.map(&.to_api_schema)
    end

    def empty? : Bool
      @tools.empty?
    end

    def dispatch(call : ToolCall) : String
      tool = @by_name[call.function.name]?
      return "Error: unknown tool '#{call.function.name}'" unless tool

      begin
        tool.execute(call.parsed_arguments)
      rescue ex : HandoffSignal
        raise ex
      rescue ex
        "Error: #{ex.class}: #{ex.message}"
      end
    end
  end
end
