module LLM
  # The OpenAI chat-completions dialect, spoken by OpenAI itself, Kimi,
  # DeepSeek, and most OpenAI-compatible endpoints.
  class OpenAIProtocol < Protocol
    def headers(api_key : String) : HTTP::Headers
      HTTP::Headers{
        "Authorization" => "Bearer #{api_key}",
        "Content-Type"  => "application/json",
      }
    end

    def chat_path(uri : URI) : String
      "#{uri.path}/chat/completions"
    end

    def embeddings_path(uri : URI) : String
      "#{uri.path}/embeddings"
    end

    def chat_body(plan : Plan, messages : Array(Message),
                  tools : Array(Tool::Custom)?, options : Options,
                  stream : Bool) : String
      caps          = plan.caps
      tools_present = !(tools.nil? || tools.empty?)
      JSON.build do |json|
        json.object do
          json.field "model", plan.model
          json.field "messages" do
            json.array do
              messages.each do |message|
                preserve = message.role == "assistant" &&
                           caps.preserve_reasoning?(message.tool_call?, tools_present, plan.preserve)
                message.build_json(json, preserve)
              end
            end
          end
          if tools && tools_present
            json.field "tools" do
              json.array do
                tools.each { |tool| tool.to_api_schema.to_json(json) }
              end
            end
          end
          if choice = options.tool_choice
            json.field "tool_choice" do
              choice.build_json(json)
            end
          end
          if format = options.response_format
            unless format.kind.text?
              json.field "response_format" do
                format.build_json(json)
              end
            end
          end
          if caps.thinking.optional?
            resolved = plan.thinking.nil? ? caps.default_thinking : plan.thinking
            unless resolved.nil?
              json.field "thinking" do
                json.object do
                  json.field "type", resolved ? "enabled" : "disabled"
                  json.field "keep", "all" if caps.preserved_thinking.optional? && plan.preserve
                end
              end
            end
          end
          if effort = plan.effort
            json.field "reasoning_effort", effort
          end
          if temperature = plan.temperature
            json.field "temperature", temperature
          end
          if max_tokens = options.max_tokens
            json.field caps.max_tokens_field, max_tokens
          end
          if key = options.prompt_cache_key
            json.field "prompt_cache_key", key
          end
          if user_id = options.user_id
            json.field "user_id", user_id
          end
          json.field "stream", stream
          if stream && options.include_usage
            json.field "stream_options" do
              json.object { json.field "include_usage", true }
            end
          end
        end
      end
    end

    def embed_body(model : String, input : String | Array(String)) : String
      JSON.build do |json|
        json.object do
          json.field "model", model
          json.field "input" do
            case input
            in String
              json.string(input)
            in Array(String)
              json.array { input.each { |item| json.string(item) } }
            end
          end
        end
      end
    end

    def parse_chat_response(json : JSON::Any) : ChatResponse
      choice        = json["choices"].as_a.first
      message       = Message.from_response(choice["message"])
      finish_reason = choice["finish_reason"]?.try(&.as_s?) || ""
      ChatResponse.new(message, finish_reason, usage_from(json, choice))
    rescue ex : KeyError | IndexError | TypeCastError
      raise Error.new("malformed API response body: #{ex.message}")
    end

    def parse_embedding_response(json : JSON::Any) : EmbeddingResponse
      data       = json["data"].as_a
      embeddings = data.map do |entry|
        vector = entry["embedding"].as_a.map do |value|
          value.as_f? || value.as_i?.try(&.to_f64) ||
            raise Error.new("malformed embeddings response: non-numeric vector element")
        end
        Embedding.new(entry["index"]?.try(&.as_i?) || 0, vector)
      end
      embeddings.sort_by!(&.index)
      usage = nil
      if raw = json["usage"]?
        usage = Usage.from_any(raw) unless raw.raw.nil?
      end
      EmbeddingResponse.new(json["model"]?.try(&.as_s?) || "", embeddings, usage)
    rescue ex : KeyError | IndexError | TypeCastError
      raise Error.new("malformed embeddings response body: #{ex.message}")
    end

    def accumulator : StreamAccumulator
      OpenAIStreamAccumulator.new
    end

    private def usage_from(json : JSON::Any, choice : JSON::Any) : Usage?
      if usage = json["usage"]?
        return Usage.from_any(usage) unless usage.raw.nil?
      end
      if usage = choice["usage"]?
        return Usage.from_any(usage) unless usage.raw.nil?
      end
      nil
    end
  end

  class OpenAIStreamAccumulator < StreamAccumulator
    @finish_reason : String?
    @usage         : Usage?

    def initialize
      @content       = String::Builder.new
      @has_content   = false
      @reasoning     = String::Builder.new
      @has_reasoning = false
      @tool_calls    = {} of Int32 => PartialToolCall
      @finish_reason = nil
      @usage         = nil
    end

    def add(json : JSON::Any) : StreamChunk?
      content_delta   : String? = nil
      reasoning_delta : String? = nil
      deltas = [] of ToolCall
      chunk_finish : String? = nil
      chunk_usage  : Usage?  = nil

      if choices = json["choices"]?
        if choice = choices.as_a?.try(&.first?)
          if delta = choice["delta"]?
            content_delta = delta["content"]?.try(&.as_s?)
            reasoning_delta = delta["reasoning_content"]?.try(&.as_s?) ||
                              delta["reasoning"]?.try(&.as_s?)
            if tool_calls = delta["tool_calls"]?
              if array = tool_calls.as_a?
                array.each { |call_json| deltas << accumulate_tool_call(call_json) }
              end
            end
          end
          if finish = choice["finish_reason"]?
            chunk_finish   = finish.as_s?
            @finish_reason = chunk_finish if chunk_finish
          end
          if usage_json = choice["usage"]?
            unless usage_json.raw.nil?
              chunk_usage = Usage.from_any(usage_json)
              @usage      = chunk_usage
            end
          end
        end
      end

      if usage_json = json["usage"]?
        unless usage_json.raw.nil?
          chunk_usage = Usage.from_any(usage_json)
          @usage      = chunk_usage
        end
      end

      if text = content_delta
        @content << text
        @has_content = true
      end

      if text = reasoning_delta
        @reasoning << text
        @has_reasoning = true
      end

      StreamChunk.new(content_delta: content_delta, tool_call_deltas: deltas,
        finish_reason: chunk_finish, usage: chunk_usage, reasoning_delta: reasoning_delta)
    end

    def response : ChatResponse
      calls = @tool_calls.keys.sort!.map { |index| @tool_calls[index].to_tool_call }
      message = Message.assistant(
        content: @has_content ? @content.to_s : nil,
        tool_calls: calls.empty? ? nil : calls,
        reasoning_content: @has_reasoning ? @reasoning.to_s : nil)
      ChatResponse.new(message, @finish_reason || "", @usage)
    end

    private def accumulate_tool_call(call_json : JSON::Any) : ToolCall
      index_json = call_json["index"]?
      index      = 0
      if index_json && !index_json.raw.nil?
        parsed = index_json.as_i?
        raise Error.new("malformed stream chunk: tool-call index is not an integer") if parsed.nil?
        index = parsed
      end
      partial = (@tool_calls[index] ||= PartialToolCall.new)
      if id = call_json["id"]?.try(&.as_s?)
        partial.id = id
      end
      if type = call_json["type"]?.try(&.as_s?)
        partial.type = type
      end
      if function = call_json["function"]?
        if name = function["name"]?.try(&.as_s?)
          partial.name = name
        end
        if arguments = function["arguments"]?.try(&.as_s?)
          partial.arguments << arguments
        end
      end
      ToolCall.from_any(call_json)
    rescue ex : TypeCastError | KeyError
      raise Error.new("malformed stream chunk: #{ex.message}")
    end
  end

  private class PartialToolCall
    property id      : String          = ""
    property type    : String          = "function"
    property name    : String          = ""
    getter arguments : String::Builder = String::Builder.new

    def to_tool_call : ToolCall
      ToolCall.new(id: @id, function: FunctionCall.new(@name, @arguments.to_s), type: @type)
    end
  end
end
