# src/llm/protocols/anthropic.cr
module LLM
  # The Anthropic Messages API dialect (api.anthropic.com): x-api-key auth,
  # content blocks, top-level system prompt, tool_use/tool_result round
  # trips, and block-based SSE streaming.
  #
  # Thinking comes in two flavors:
  #   - Claude 5-series: adaptive thinking, always on, steered with
  #     output_config.effort. No thinking object is sent.
  #   - Claude Haiku 4.5: legacy extended thinking behind a switch,
  #     budgeted with thinking.budget_tokens.
  #
  # Thinking blocks are preserved across turns by passing the assistant
  # message's response_blocks back verbatim (signatures included), as
  # required during tool use.
  class AnthropicProtocol < Protocol
    VERSION = "2023-06-01"

    # Anthropic requires max_tokens on every request. When the caller does
    # not set one, default to a headroom-friendly value, capped by the
    # model's published maximum output when known.
    DEFAULT_MAX_TOKENS = 32_768

    # Budget for legacy extended-thinking models; must be >= 1024 and below
    # max_tokens.
    DEFAULT_THINKING_BUDGET = 8_192

    def headers(api_key : String) : HTTP::Headers
      HTTP::Headers{
        "x-api-key"         => api_key,
        "anthropic-version" => VERSION,
        "Content-Type"      => "application/json",
      }
    end

    def chat_path(uri : URI) : String
      "#{uri.path}/messages"
    end

    def embeddings_path(uri : URI) : String
      raise UnsupportedFeatureError.new("anthropic has no embeddings API")
    end

    def embed_body(model : String, input : String | Array(String)) : String
      raise UnsupportedFeatureError.new("anthropic has no embeddings API")
    end

    def parse_embedding_response(json : JSON::Any) : EmbeddingResponse
      raise UnsupportedFeatureError.new("anthropic has no embeddings API")
    end

    def chat_body(plan : Plan, messages : Array(Message),
                  tools : Array(Tool::Custom)?, options : Options,
                  stream : Bool) : String
      caps          = plan.caps
      max_tokens    = options.max_tokens || default_max_tokens(caps)
      tools_present = !(tools.nil? || tools.empty?)
      JSON.build do |json|
        json.object do
          json.field "model", plan.model
          json.field "max_tokens", max_tokens
          json.field "messages" do
            json.array { build_messages(json, plan, messages, tools_present) }
          end
          if system = system_prompt(messages)
            json.field "system", system
          end
          if tools && tools_present
            json.field "tools" do
              json.array do
                tools.each do |tool|
                  json.object do
                    json.field "name", tool.name
                    json.field "description", tool.description
                    json.field "input_schema", tool.parameters_schema
                  end
                end
              end
            end
          end
          if choice = options.tool_choice
            build_tool_choice(json, choice)
          end
          if caps.thinking.optional?
            resolved = plan.thinking.nil? ? caps.default_thinking : plan.thinking
            if resolved
              json.field "thinking" do
                json.object do
                  json.field "type", "enabled"
                  json.field "budget_tokens", thinking_budget(max_tokens)
                end
              end
            end
          end
          if effort = plan.effort
            json.field "output_config" do
              json.object { json.field "effort", effort }
            end
          end
          if temperature = plan.temperature
            json.field "temperature", temperature
          end
          if user_id = options.user_id
            json.field "metadata" do
              json.object { json.field "user_id", user_id }
            end
          end
          json.field "stream", stream
        end
      end
    end

    def parse_chat_response(json : JSON::Any) : ChatResponse
      message = message_from_blocks(json["content"].as_a)
      ChatResponse.new(message,
        Anthropic.stop_reason(json["stop_reason"]?.try(&.as_s?)),
        Anthropic.usage_from(json["usage"]?))
    rescue ex : KeyError | TypeCastError
      raise Error.new("malformed API response body: #{ex.message}")
    end

    def accumulator : StreamAccumulator
      AnthropicStreamAccumulator.new
    end

    # Shared by non-streamed responses; the streamed variant reassembles
    # blocks incrementally in AnthropicStreamAccumulator.
    private def message_from_blocks(content : Array(JSON::Any)) : Message
      texts    = [] of String
      thinking = [] of String
      calls    = [] of ToolCall
      blocks   = [] of JSON::Any
      content.each do |block|
        case block["type"]?.try(&.as_s?)
        when "text"
          if text = block["text"]?.try(&.as_s?)
            texts << text unless text.empty?
            blocks << block
          end
        when "thinking"
          if thought = block["thinking"]?.try(&.as_s?)
            thinking << thought unless thought.empty?
            blocks << block
          end
        when "tool_use"
          calls << ToolCall.new(
            id: block["id"]?.try(&.as_s?) || "",
            function: FunctionCall.new(
              block["name"]?.try(&.as_s?) || "",
              block["input"]?.try(&.to_json) || "{}"))
          blocks << block
        end
        # Server-tool and unknown block types are dropped.
      end
      message = Message.assistant(
        content: texts.empty? ? nil : texts.join("\n"),
        tool_calls: calls.empty? ? nil : calls,
        reasoning_content: thinking.empty? ? nil : thinking.join("\n\n"))
      message.response_blocks = blocks unless blocks.empty?
      message
    end

    private def build_messages(json : JSON::Builder, plan : Plan,
                               messages : Array(Message), tools_present : Bool) : Nil
      pending = [] of Message
      messages.each do |message|
        case message.role
        when "system"
          next # hoisted to the top-level system parameter
        when "tool"
          pending << message
          next
        end
        flush_tool_results(json, pending)
        build_message(json, plan, message, tools_present)
      end
      flush_tool_results(json, pending)
    end

    private def flush_tool_results(json : JSON::Builder, pending : Array(Message)) : Nil
      return if pending.empty?
      json.object do
        json.field "role", "user"
        json.field "content" do
          json.array do
            pending.each do |result|
              json.object do
                json.field "type", "tool_result"
                json.field "tool_use_id", result.tool_call_id || ""
                json.field "content", result.text
              end
            end
          end
        end
      end
      pending.clear
    end

    private def build_message(json : JSON::Builder, plan : Plan,
                              message : Message, tools_present : Bool) : Nil
      json.object do
        json.field "role", message.role
        json.field "content" do
          if message.role == "assistant"
            build_assistant_content(json, plan, message, tools_present)
          else
            build_user_content(json, message)
          end
        end
      end
    end

    private def build_user_content(json : JSON::Builder, message : Message) : Nil
      case content = message.content
      in String
        json.string(content)
      in Array(ContentPart)
        json.array { content.each { |part| build_part(json, part) } }
      in Nil
        json.string("")
      end
    end

    private def build_part(json : JSON::Builder, part : ContentPart) : Nil
      case part.kind
      in .text?
        json.object do
          json.field "type", "text"
          json.field "text", part.value
        end
      in .image?
        build_image(json, part.value)
      in .video?
        raise UnsupportedFeatureError.new("anthropic does not accept video input")
      end
    end

    private def build_image(json : JSON::Builder, value : String) : Nil
      json.object do
        json.field "type", "image"
        json.field "source" do
          json.object do
            if value.starts_with?("data:")
              header, _, data = value.partition(',')
              media = header.lchop("data:").rchop(";base64")
              json.field "type", "base64"
              json.field "media_type", media
              json.field "data", data
            elsif value.starts_with?("http://") || value.starts_with?("https://")
              json.field "type", "url"
              json.field "url", value
            else
              raise Error.new("image reference not supported by anthropic: " \
                              "use a URL or image_data (data URI)")
            end
          end
        end
      end
    end

    private def build_assistant_content(json : JSON::Builder, plan : Plan,
                                        message : Message, tools_present : Bool) : Nil
      preserve = plan.caps.preserve_reasoning?(message.tool_call?, tools_present, plan.preserve)
      if preserve
        if blocks = message.response_blocks
          json.array { blocks.each { |block| block.to_json(json) } }
          return
        end
      end
      json.array do
        unless (text = message.text).empty?
          json.object do
            json.field "type", "text"
            json.field "text", text
          end
        end
        if calls = message.tool_calls
          calls.each do |call|
            json.object do
              json.field "type", "tool_use"
              json.field "id", call.id
              json.field "name", call.function.name
              json.field "input" do
                arguments = call.function.arguments
                (arguments.empty? ? JSON.parse("{}") : call.parsed_arguments).to_json(json)
              end
            end
          end
        end
      end
    end

    private def build_tool_choice(json : JSON::Builder, choice : ToolChoice) : Nil
      json.field "tool_choice" do
        json.object do
          case choice.mode
          in .auto?
            json.field "type", "auto"
          in .none?
            json.field "type", "none"
          in .required?
            json.field "type", "any"
          in .function?
            json.field "type", "tool"
            json.field "name", choice.name
          end
        end
      end
    end

    private def system_prompt(messages : Array(Message)) : String?
      parts = [] of String
      messages.each do |message|
        parts << message.text if message.role == "system"
      end
      parts.empty? ? nil : parts.join("\n\n")
    end

    private def default_max_tokens(caps : Capabilities) : Int32
      max = caps.max_output_tokens
      return DEFAULT_MAX_TOKENS if max <= 0
      Math.min(max, DEFAULT_MAX_TOKENS)
    end

    private def thinking_budget(max_tokens : Int32) : Int32
      budget = DEFAULT_THINKING_BUDGET
      budget = max_tokens - 1024 if budget >= max_tokens
      Math.max(budget, 1024)
    end
  end

  # Small helpers shared with the stream accumulator.
  module Anthropic
    def self.stop_reason(reason : String?) : String
      case reason
      when "end_turn", "stop_sequence" then "stop"
      when "tool_use"                  then "tool_calls"
      when "max_tokens"                then "length"
      when nil                         then ""
      else                                  reason
      end
    end

    def self.usage_from(json : JSON::Any?) : Usage?
      return nil if json.nil? || json.raw.nil?
      input  = int_at(json, "input_tokens")
      output = int_at(json, "output_tokens")
      Usage.new(input, output, input + output, int_at(json, "cache_read_input_tokens"))
    end

    def self.int_at(json : JSON::Any, key : String) : Int32
      raw = json[key]?
      return 0 if raw.nil? || raw.raw.nil?
      raw.as_i? || 0
    end
  end

  class AnthropicStreamAccumulator < StreamAccumulator
    @finish_reason : String?
    @usage         : Usage?

    def initialize
      @partials      = {} of Int32 => PartialBlock
      @finish_reason = nil
      @usage         = nil
    end

    def add(json : JSON::Any) : StreamChunk?
      case json["type"]?.try(&.as_s?)
      when "message_start"
        if message = json["message"]?
          if usage_json = message["usage"]?
            @usage = Anthropic.usage_from(usage_json)
            return StreamChunk.new(usage: @usage)
          end
        end
        nil
      when "content_block_start"
        start_block(index_of(json), json["content_block"]?)
        nil
      when "content_block_delta"
        delta = json["delta"]?
        return nil if delta.nil? || delta.raw.nil?
        handle_delta(index_of(json), delta)
      when "content_block_stop"
        nil # blocks are assembled from partials in #response
      when "message_delta"
        handle_message_delta(json)
      when "message_stop"
        nil
      when "error"
        raise APIError.build(error_status(json), json.to_json)
      else
        nil # ping and unknown event types
      end
    end

    def response : ChatResponse
      texts    = [] of String
      thinking = [] of String
      calls    = [] of ToolCall
      blocks   = [] of JSON::Any
      @partials.keys.sort!.each do |index|
        partial = @partials[index]
        blocks << partial.to_block
        case partial.kind
        when "text"
          text = partial.final_text
          texts << text unless text.empty?
        when "thinking"
          thought = partial.final_thinking
          thinking << thought unless thought.empty?
        else
          calls << ToolCall.new(id: partial.tool_id,
            function: FunctionCall.new(partial.tool_name, partial.final_input))
        end
      end
      message = Message.assistant(
        content: texts.empty? ? nil : texts.join("\n"),
        tool_calls: calls.empty? ? nil : calls,
        reasoning_content: thinking.empty? ? nil : thinking.join("\n\n"))
      message.response_blocks = blocks unless blocks.empty?
      ChatResponse.new(message, @finish_reason || "", @usage)
    end

    private def index_of(json : JSON::Any) : Int32
      json["index"]?.try(&.as_i?) || 0
    end

    private def start_block(index : Int32, block : JSON::Any?) : Nil
      return if block.nil? || block.raw.nil?
      kind = block["type"]?.try(&.as_s?)
      return if kind.nil?
      return unless kind == "text" || kind == "thinking" || kind == "tool_use"
      partial = PartialBlock.new(kind)
      if kind == "tool_use"
        partial.tool_id = block["id"]?.try(&.as_s?) || ""
        partial.tool_name = block["name"]?.try(&.as_s?) || ""
      end
      @partials[index] = partial
    end

    private def handle_delta(index : Int32, delta : JSON::Any) : StreamChunk?
      partial = (@partials[index] ||= PartialBlock.new("text"))
      case delta["type"]?.try(&.as_s?)
      when "text_delta"
        if text = delta["text"]?.try(&.as_s?)
          partial.text << text
          return StreamChunk.new(content_delta: text)
        end
      when "thinking_delta"
        if text = delta["thinking"]?.try(&.as_s?)
          partial.thinking << text
          return StreamChunk.new(reasoning_delta: text)
        end
      when "signature_delta"
        if signature = delta["signature"]?.try(&.as_s?)
          partial.signature << signature
        end
      when "input_json_delta"
        if fragment = delta["partial_json"]?.try(&.as_s?)
          partial.input << fragment
          return StreamChunk.new(tool_call_deltas: [
            ToolCall.new(id: partial.tool_id,
              function: FunctionCall.new(partial.tool_name, fragment)),
          ])
        end
      end
      nil
    end

    private def handle_message_delta(json : JSON::Any) : StreamChunk?
      if delta = json["delta"]?
        if reason = delta["stop_reason"]?.try(&.as_s?)
          @finish_reason = Anthropic.stop_reason(reason)
        end
      end
      if usage_json = json["usage"]?
        unless usage_json.raw.nil?
          @usage = merge_usage(usage_json)
        end
      end
      return nil if @finish_reason.nil? && @usage.nil?
      StreamChunk.new(finish_reason: @finish_reason, usage: @usage)
    end

    # message_delta usage carries cumulative output tokens only; input
    # tokens arrived with message_start.
    private def merge_usage(json : JSON::Any) : Usage
      previous = @usage || Usage.new
      output   = Anthropic.int_at(json, "output_tokens")
      output   = previous.completion_tokens if output == 0
      Usage.new(previous.prompt_tokens, output,
        previous.prompt_tokens + output, previous.cached_tokens)
    end

    private def error_status(json : JSON::Any) : Int32
      case json["error"]?.try { |error| error["type"]?.try(&.as_s?) }
      when "overloaded_error" then 529
      when "rate_limit_error" then 429
      else                         500
      end
    end
  end

  private class PartialBlock
    getter kind      : String
    getter text      : String::Builder = String::Builder.new
    getter thinking  : String::Builder = String::Builder.new
    getter signature : String::Builder = String::Builder.new
    getter input     : String::Builder = String::Builder.new

    property tool_id   : String = ""
    property tool_name : String = ""

    @final_text      : String?
    @final_thinking  : String?
    @final_signature : String?
    @final_input     : String?

    def initialize(@kind : String)
    end

    def final_text : String
      @final_text ||= @text.to_s
    end

    def final_thinking : String
      @final_thinking ||= @thinking.to_s
    end

    def final_signature : String
      @final_signature ||= @signature.to_s
    end

    def final_input : String
      @final_input ||= @input.to_s
    end

    def to_block : JSON::Any
      case @kind
      when "text"
        JSON.parse({type: "text", text: final_text}.to_json)
      when "thinking"
        JSON.parse({type: "thinking", thinking: final_thinking, signature: final_signature}.to_json)
      else
        raw       = final_input
        input_any = raw.empty? ? JSON.parse("{}") : (JSON.parse(raw) rescue JSON.parse("{}"))
        JSON.parse({type: "tool_use", id: @tool_id, name: @tool_name, input: input_any}.to_json)
      end
    end
  end
end
