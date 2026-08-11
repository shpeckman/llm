# src/llm/errors.cr
module LLM
  class Error < Exception; end

  class APIError < Error
    getter status : Int32
    getter body   : String

    def initialize(@status : Int32, @body : String)
      super("API error #{status}: #{body}")
    end
  end

  class ToolError < Error; end

  class SwarmError < Error; end

  class MaxIterationsError < Error; end

  class UnsupportedFeatureError < Error; end
end
