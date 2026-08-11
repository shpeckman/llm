# src/llm/client.cr
require "http/client"
require "json"
require "uri"
require "./provider"

class LLM::Client
  getter provider      : Provider
  getter api_key       : String
  getter default_model : String
  property timeout     : Time::Span

  delegate base_url, to: @provider

  def initialize(@provider : Provider = Provider.kimi, api_key : String? = nil,
                 default_model : String? = nil, @timeout : Time::Span = 120.seconds)
    resolved_key = @provider.resolve_api_key(api_key)
    if resolved_key.nil?
      checked = (@provider.api_key_env + ["LLM_API_KEY"]).join(", ")
      raise Error.new("no API key for provider '#{@provider.name}': " \
                      "pass api_key or set one of: #{checked}")
    end
    @api_key       = resolved_key
    @default_model = default_model || @provider.default_model
  end

  private def validate_tool_support!(model : String, tools : Array(Tool::Custom)?) : Nil
    if tools && !tools.empty? && !@provider.supports_tools?(model)
      raise UnsupportedFeatureError.new("provider '#{@provider.name}' model '#{model}' " \
                                        "does not support tool calling")
    end
  end

  private def resolve_effort(model : String, effort : String?) : String?
    resolved = effort.nil? ? @provider.default_effort : effort
    return nil if resolved.nil?
    return nil unless @provider.supports_reasoning_effort?(model)
    resolved
  end

  private def resolve_thinking(model : String, thinking : Bool?) : Bool?
    return nil unless @provider.thinking_style(model).thinking_object?
    thinking.nil? ? @provider.default_thinking : thinking
  end

  def chat(messages : Array(Message), tools : Array(Tool::Custom)? = nil, *,
           model : String? = nil, temperature : Float64? = nil,
           max_tokens : Int32? = nil, thinking : Bool? = nil,
           reasoning_effort : String? = nil) : ChatResponse
    model = model || @default_model
    validate_tool_support!(model, tools)
    unless @provider.supports_sampling_params?(model, thinking)
      temperature = nil
      max_tokens  = nil
    end
    effort = resolve_effort(model, reasoning_effort)
    think  = resolve_thinking(model, thinking)
    uri    = URI.parse(base_url)
    client = new_http_client(uri)
    begin
      response = client.post(completions_path(uri), headers: request_headers,
        body: request_body(messages, tools, model, temperature, max_tokens, false, think, effort))
      if response.status_code >= 400
        raise APIError.new(response.status_code, response.body)
      end
      parse_chat_response(JSON.parse(response.body))
    ensure
      client.close
    end
  end

  def chat_stream(messages : Array(Message), tools : Array(Tool::Custom)? = nil, *,
                  model : String? = nil, temperature : Float64? = nil,
                  max_tokens : Int32? = nil, thinking : Bool? = nil,
                  reasoning_effort : String? = nil, &block : StreamChunk ->) : ChatResponse
    model = model || @default_model
    validate_tool_support!(model, tools)
    unless @provider.supports_sampling_params?(model, thinking)
      temperature = nil
      max_tokens  = nil
    end
    effort      = resolve_effort(model, reasoning_effort)
    think       = resolve_thinking(model, thinking)
    uri         = URI.parse(base_url)
    client      = new_http_client(uri)
    accumulator = StreamAccumulator.new
    begin
      client.post(completions_path(uri), headers: request_headers,
        body: request_body(messages, tools, model, temperature, max_tokens, true, think, effort)) do |response|
        if response.status_code >= 400
          raise APIError.new(response.status_code, response.body_io.gets_to_end)
        end
        while line = response.body_io.gets
          line = line.chomp
          next if line.empty?
          next unless line.starts_with?("data: ")
          payload = line[6..]
          break if payload == "[DONE]"
          chunk = accumulator.add(parse_sse_payload(payload))
          block.call(chunk)
        end
      end
    ensure
      client.close
    end
    accumulator.response
  end

  private def parse_sse_payload(payload : String) : JSON::Any
    JSON.parse(payload)
  rescue ex : JSON::ParseException
    raise Error.new("malformed SSE payload: #{ex.message}")
  end

  private def new_http_client(uri : URI) : HTTP::Client
    client = HTTP::Client.new(uri)
    client.read_timeout = timeout
    client
  end

  private def completions_path(uri : URI) : String
    "#{uri.path}/chat/completions"
  end

  private def request_headers : HTTP::Headers
    HTTP::Headers{
      "Authorization" => "Bearer #{@api_key}",
      "Content-Type"  => "application/json",
    }
  end

  private def request_body(messages : Array(Message), tools : Array(Tool::Custom)?,
                           model : String, temperature : Float64?,
                           max_tokens : Int32?, stream : Bool,
                           thinking : Bool?, reasoning_effort : String?) : String
    JSON.build do |json|
      json.object do
        json.field "model", model
        json.field "messages" do
          json.array do
            messages.each do |message|
              preserve = message.role == "assistant" &&
                         @provider.preserve_reasoning?(model, message.tool_call?)
              message.build_json(json, preserve)
            end
          end
        end
        if tools
          json.field "tools" do
            json.array do
              tools.each { |tool| tool.to_api_schema.to_json(json) }
            end
          end
        end
        unless thinking.nil?
          json.field "thinking" do
            json.object do
              json.field "type", thinking ? "enabled" : "disabled"
            end
          end
        end
        json.field "reasoning_effort", reasoning_effort unless reasoning_effort.nil?
        json.field "temperature", temperature unless temperature.nil?
        json.field "max_tokens", max_tokens unless max_tokens.nil?
        json.field "stream", stream
      end
    end
  end

  private def parse_chat_response(json : JSON::Any) : ChatResponse
    choice  = json["choices"].as_a.first
    message = Message.from_json(choice["message"].to_json)
    if reasoning = choice["message"]["reasoning_content"]?.try(&.as_s?)
      message.reasoning_content = reasoning
    end
    finish_reason = choice["finish_reason"]?.try(&.as_s?) || ""
    ChatResponse.new(message, finish_reason, usage_from(json))
  rescue ex : KeyError | IndexError | TypeCastError
    raise Error.new("malformed API response body: #{ex.message}")
  end

  private def usage_from(json : JSON::Any) : Usage?
    usage = json["usage"]?
    Usage.from_json(usage.to_json) if usage && !usage.raw.nil?
  end

  private class PartialToolCall
    property id      : String          = ""
    property name    : String          = ""
    getter arguments : String::Builder = String::Builder.new

    def to_tool_call : ToolCall
      ToolCall.new(id: @id, function: FunctionCall.new(name: @name, arguments: @arguments.to_s))
    end
  end

  private class StreamAccumulator
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

    def add(json : JSON::Any) : StreamChunk
      content_delta   : String? = nil
      reasoning_delta : String? = nil
      deltas = [] of ToolCall
      chunk_finish : String? = nil
      chunk_usage  : Usage?  = nil

      if choices = json["choices"]?
        if choice = choices.as_a.first?
          if delta = choice["delta"]?
            content_delta   = delta["content"]?.try(&.as_s?)
            reasoning_delta = delta["reasoning_content"]?.try(&.as_s?)
            if tool_calls = delta["tool_calls"]?
              tool_calls.as_a.each do |call_json|
                deltas << accumulate_tool_call(call_json)
              end
            end
          end
          if finish = choice["finish_reason"]?
            chunk_finish   = finish.as_s?
            @finish_reason = chunk_finish if chunk_finish
          end
        end
      end

      if usage_json = json["usage"]?
        unless usage_json.raw.nil?
          chunk_usage = Usage.from_json(usage_json.to_json)
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
      calls = @tool_calls.keys.sort.map { |index| @tool_calls[index].to_tool_call }
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
        index = index_json.as_i?
        if index.nil?
          raise Error.new("malformed stream chunk: tool-call index is not an integer")
        end
      end
      partial = (@tool_calls[index] ||= PartialToolCall.new)
      if id = call_json["id"]?.try(&.as_s?)
        partial.id = id
      end
      if function = call_json["function"]?
        if name = function["name"]?.try(&.as_s?)
          partial.name = name
        end
        if arguments = function["arguments"]?.try(&.as_s?)
          partial.arguments << arguments
        end
      end
      ToolCall.from_json(call_json.to_json)
    rescue ex : TypeCastError | KeyError
      raise Error.new("malformed stream chunk: #{ex.message}")
    end
  end
end
