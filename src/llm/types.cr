require "base64"
require "json"
require "./pricing"

module LLM
  struct ContentPart
    enum Kind
      Text
      Image
      Video
    end

    getter kind  : Kind
    getter value : String

    def initialize(@kind : Kind, @value : String)
    end

    def self.text(text : String) : ContentPart
      new(Kind::Text, text)
    end

    def self.image(url : String) : ContentPart
      new(Kind::Image, url)
    end

    def self.image_file(file_id : String) : ContentPart
      new(Kind::Image, "ms://#{file_id}")
    end

    def self.image_data(data : Bytes, media_type : String) : ContentPart
      new(Kind::Image, data_uri(data, media_type))
    end

    def self.video(url : String) : ContentPart
      new(Kind::Video, url)
    end

    def self.video_file(file_id : String) : ContentPart
      new(Kind::Video, "ms://#{file_id}")
    end

    def self.video_data(data : Bytes, media_type : String) : ContentPart
      new(Kind::Video, data_uri(data, media_type))
    end

    private def self.data_uri(data : Bytes, media_type : String) : String
      String.build do |io|
        io << "data:" << media_type << ";base64,"
        Base64.strict_encode(data, io)
      end
    end

    def build_json(json : JSON::Builder) : Nil
      json.object do
        case @kind
        in .text?
          json.field "type", "text"
          json.field "text", @value
        in .image?
          json.field "type", "image_url"
          json.field "image_url" do
            json.object { json.field "url", @value }
          end
        in .video?
          json.field "type", "video_url"
          json.field "video_url" do
            json.object { json.field "url", @value }
          end
        end
      end
    end
  end

  alias Content = String | Array(ContentPart)

  class FunctionCall
    getter name      : String
    getter arguments : String

    def initialize(@name : String = "", @arguments : String = "")
    end
  end

  class ToolCall
    getter id       : String
    getter type     : String
    getter function : FunctionCall

    def initialize(@id : String = "", @function : FunctionCall = FunctionCall.new,
                   @type : String = "function")
    end

    def self.from_any(json : JSON::Any) : ToolCall
      name      = ""
      arguments = ""
      if function = json["function"]?
        name      = function["name"]?.try(&.as_s?) || ""
        arguments = function["arguments"]?.try(&.as_s?) || ""
      end
      new(json["id"]?.try(&.as_s?) || "",
        FunctionCall.new(name, arguments),
        json["type"]?.try(&.as_s?) || "function")
    end

    def build_json(json : JSON::Builder) : Nil
      json.object do
        json.field "id", @id
        json.field "type", @type
        json.field "function" do
          json.object do
            json.field "name", @function.name
            json.field "arguments", @function.arguments
          end
        end
      end
    end

    def parsed_arguments : JSON::Any
      return JSON.parse("{}") if @function.arguments.empty?
      JSON.parse(@function.arguments)
    rescue ex : JSON::ParseException
      raise ToolError.new("invalid tool-call arguments for '#{@function.name}': #{ex.message}")
    end
  end

  class Message
    property role              : String
    property content           : Content?
    property tool_calls        : Array(ToolCall)?
    property tool_call_id      : String?
    property reasoning_content : String?

    def initialize(@role : String, @content : Content? = nil,
                   @tool_calls : Array(ToolCall)? = nil, @tool_call_id : String? = nil,
                   @reasoning_content : String? = nil)
    end

    def self.system(content : Content) : Message
      new("system", content)
    end

    def self.user(content : Content) : Message
      new("user", content)
    end

    def self.assistant(content : Content? = nil, tool_calls : Array(ToolCall)? = nil,
                       reasoning_content : String? = nil) : Message
      new("assistant", content, tool_calls, reasoning_content: reasoning_content)
    end

    def self.tool_result(tool_call_id : String, content : String) : Message
      new("tool", content, tool_call_id: tool_call_id)
    end

    def self.from_response(json : JSON::Any) : Message
      calls = nil
      if raw = json["tool_calls"]?
        if array = raw.as_a?
          calls = array.map { |call| ToolCall.from_any(call) } unless array.empty?
        end
      end
      reasoning = json["reasoning_content"]?.try(&.as_s?) || json["reasoning"]?.try(&.as_s?)
      new(json["role"]?.try(&.as_s?) || "assistant",
        json["content"]?.try(&.as_s?), calls, reasoning_content: reasoning)
    end

    def tool_call? : Bool
      if calls = @tool_calls
        !calls.empty?
      else
        false
      end
    end

    def text : String
      case content = @content
      in String
        content
      in Array(ContentPart)
        String.build do |io|
          content.each { |part| io << part.value if part.kind.text? }
        end
      in Nil
        ""
      end
    end

    # Strictly parses the message's text content as `T` (which must support
    # `.from_json`). Raises `LLM::Error` with the type name and a content
    # snippet (≤200 chars) on malformed JSON — no fence stripping, no
    # leniency; call `T.from_json` yourself if you need that.
    def parse(type : T.class) : T forall T
      T.from_json(text)
    rescue ex : JSON::ParseException
      snippet = text
      snippet = snippet[0, 200] + "..." if snippet.size > 200
      raise Error.new("failed to parse assistant message as #{T}: #{ex.message} " \
                      "(content: #{snippet.inspect})")
    end

    def each_part(& : ContentPart ->) : Nil
      content = @content
      return unless content.is_a?(Array(ContentPart))
      content.each { |part| yield part }
    end

    def build_json(json : JSON::Builder, preserve_reasoning : Bool) : Nil
      json.object do
        json.field "role", @role
        json.field "content" do
          case content = @content
          in String
            json.string(content)
          in Array(ContentPart)
            json.array { content.each(&.build_json(json)) }
          in Nil
            json.null
          end
        end
        if calls = @tool_calls
          unless calls.empty?
            json.field "tool_calls" do
              json.array { calls.each(&.build_json(json)) }
            end
          end
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

  struct Usage
    getter prompt_tokens     : Int32
    getter completion_tokens : Int32
    getter total_tokens      : Int32
    getter cached_tokens     : Int32

    def initialize(@prompt_tokens : Int32 = 0, @completion_tokens : Int32 = 0,
                   @total_tokens : Int32 = 0, @cached_tokens : Int32 = 0)
    end

    def self.from_any(json : JSON::Any) : Usage
      cached = int_at(json, "cached_tokens")
      if cached == 0
        if details = json["prompt_tokens_details"]?
          cached = int_at(details, "cached_tokens") unless details.raw.nil?
        end
      end
      cached = int_at(json, "prompt_cache_hit_tokens") if cached == 0
      new(int_at(json, "prompt_tokens"), int_at(json, "completion_tokens"),
        int_at(json, "total_tokens"), cached)
    end

    private def self.int_at(json : JSON::Any, key : String) : Int32
      raw = json[key]?
      return 0 if raw.nil? || raw.raw.nil?
      raw.as_i? || 0
    end

    def +(other : Usage) : Usage
      Usage.new(@prompt_tokens + other.prompt_tokens,
        @completion_tokens + other.completion_tokens,
        @total_tokens + other.total_tokens,
        @cached_tokens + other.cached_tokens)
    end

    def empty? : Bool
      @prompt_tokens == 0 && @completion_tokens == 0 && @total_tokens == 0 && @cached_tokens == 0
    end

    # Cost in USD for this usage at the given per-1M-token `pricing`.
    # Returns 0.0 when the pricing is unknown (all-zero).
    def cost(pricing : Pricing) : Float64
      uncached = @prompt_tokens - @cached_tokens
      uncached = 0 if uncached < 0
      (uncached * pricing.input +
        @cached_tokens * pricing.cached_input +
        @completion_tokens * pricing.output) / 1_000_000.0
    end
  end

  class ChatResponse
    getter message       : Message
    getter finish_reason : String
    getter usage         : Usage?

    def initialize(@message : Message, @finish_reason : String, @usage : Usage? = nil)
    end

    # Strictly parses the response message's text content as `T`.
    # See `Message#parse`.
    def parse(type : T.class) : T forall T
      @message.parse(T)
    end
  end

  class StreamChunk
    getter content_delta    : String?
    getter tool_call_deltas : Array(ToolCall)
    getter finish_reason    : String?
    getter usage            : Usage?
    getter reasoning_delta  : String?

    def initialize(@content_delta : String? = nil,
                   @tool_call_deltas : Array(ToolCall) = [] of ToolCall,
                   @finish_reason : String? = nil, @usage : Usage? = nil,
                   @reasoning_delta : String? = nil)
    end
  end
end
