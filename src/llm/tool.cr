# src/llm/tool.cr
require "json"

module LLM::Tool
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
      if existing = @by_name[tool.name]?
        @tools.map! { |t| t.same?(existing) ? tool : t }
      else
        @tools << tool
      end
      @by_name[tool.name] = tool
      tool
    end

    def [](name : String) : Custom?
      @by_name[name]?
    end

    def each(& : Custom ->)
      @tools.each { |t| yield t }
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
      rescue ex
        "Error: #{ex.class}: #{ex.message}"
      end
    end
  end
end
