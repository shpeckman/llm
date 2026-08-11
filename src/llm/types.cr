# src/llm/types.cr
require "json"

module LLM
  class FunctionCall
    include JSON::Serializable

    getter name      : String = ""
    getter arguments : String = ""

    def initialize(@name : String = "", @arguments : String = "")
    end
  end

  class ToolCall
    include JSON::Serializable

    getter id       : String       = ""
    getter type     : String       = "function"
    getter function : FunctionCall = FunctionCall.new

    def initialize(@id : String = "", @function : FunctionCall = FunctionCall.new, @type : String = "function")
    end

    def parsed_arguments : JSON::Any
      JSON.parse(function.arguments)
    rescue ex : JSON::ParseException
      raise ToolError.new("invalid tool-call arguments for '#{function.name}': #{ex.message}")
    end
  end

  class Message
    include JSON::Serializable

    property role : String
    @[JSON::Field(emit_null: true)]
    property content : String?
    @[JSON::Field(emit_null: false)]
    property tool_calls : Array(ToolCall)?
    @[JSON::Field(emit_null: false)]
    property tool_call_id : String?
    @[JSON::Field(ignore: true)]
    property reasoning_content : String?

    def initialize(@role : String, @content : String? = nil,
                   @tool_calls : Array(ToolCall)? = nil, @tool_call_id : String? = nil,
                   @reasoning_content : String? = nil)
    end

    def self.system(content : String) : Message
      new("system", content)
    end

    def self.user(content : String) : Message
      new("user", content)
    end

    def self.assistant(content : String? = nil, tool_calls : Array(ToolCall)? = nil,
                       reasoning_content : String? = nil) : Message
      new("assistant", content, tool_calls, reasoning_content: reasoning_content)
    end

    def self.tool_result(tool_call_id : String, content : String) : Message
      new("tool", content, tool_call_id: tool_call_id)
    end

    def tool_call? : Bool
      if calls = @tool_calls
        !calls.empty?
      else
        false
      end
    end

    def build_json(json : JSON::Builder, preserve_reasoning : Bool) : Nil
      json.object do
        json.field "role", @role
        json.field "content", @content
        if calls = @tool_calls
          json.field "tool_calls", calls unless calls.empty?
        end
        if id = @tool_call_id
          json.field "tool_call_id", id
        end
        if preserve_reasoning
          if reasoning = @reasoning_content
            json.field "reasoning_content", reasoning
          end
        end
      end
    end
  end

  class Usage
    include JSON::Serializable

    getter prompt_tokens     : Int32 = 0
    getter completion_tokens : Int32 = 0
    getter total_tokens      : Int32 = 0
  end

  class ChatResponse
    getter message       : Message
    getter finish_reason : String
    getter usage         : Usage?

    def initialize(@message : Message, @finish_reason : String, @usage : Usage? = nil)
    end
  end

  class StreamChunk
    getter content_delta    : String?
    getter tool_call_deltas : Array(ToolCall)
    getter finish_reason    : String?
    getter usage            : Usage?
    getter reasoning_delta  : String?

    def initialize(@content_delta : String? = nil, @tool_call_deltas : Array(ToolCall) = [] of ToolCall,
                   @finish_reason : String? = nil, @usage : Usage? = nil,
                   @reasoning_delta : String? = nil)
    end
  end
end
