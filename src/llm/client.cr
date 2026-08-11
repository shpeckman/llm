# src/llm/client.cr
require "http/client"
require "json"
require "uri"

class LLM::Client
  getter provider      : Provider
  getter api_key       : String
  getter default_model : String
  property timeout     : Time::Span
  property retry       : RetryPolicy

  delegate base_url, to: @provider

  def initialize(@provider : Provider = Provider.kimi, api_key : String? = nil,
                 default_model : String? = nil, @timeout : Time::Span = 600.seconds,
                 @retry : RetryPolicy = RetryPolicy.new)
    resolved_key = @provider.resolve_api_key(api_key)
    if resolved_key.nil?
      checked = (@provider.api_key_env + ["LLM_API_KEY"]).join(", ")
      raise Error.new("no API key for provider '#{@provider.name}': " \
                      "pass api_key or set one of: #{checked}")
    end
    @api_key       = resolved_key
    @default_model = default_model || @provider.default_model
  end

  def capabilities(model : String? = nil) : Capabilities
    @provider.capabilities(model || @default_model)
  end

  def chat(messages : Array(Message), tools : Array(Tool::Custom)? = nil,
           options : Options = Options.new,
           cancel : Channel(Nil)? = nil) : ChatResponse
    plan = plan_for(messages, tools, options)
    body = request_body(plan, messages, tools, options, false)
    with_retry(cancel, -> { true }) do
      uri    = URI.parse(base_url)
      client = new_http_client(uri)
      watch(client, cancel)
      begin
        response = client.post(completions_path(uri), headers: request_headers, body: body)
        raise CancelledError.new("request was cancelled") if cancelled?(cancel)
        if response.status_code >= 400
          raise APIError.build(response.status_code, response.body, response.headers)
        end
        parse_chat_response(JSON.parse(response.body))
      ensure
        client.close
      end
    end
  end

  def chat_stream(messages : Array(Message), tools : Array(Tool::Custom)? = nil,
                  options : Options = Options.new,
                  cancel : Channel(Nil)? = nil, &block : StreamChunk ->) : ChatResponse
    plan    = plan_for(messages, tools, options)
    body    = request_body(plan, messages, tools, options, true)
    emitted = false
    with_retry(cancel, -> { !emitted }) do
      accumulator = StreamAccumulator.new
      uri         = URI.parse(base_url)
      client      = new_http_client(uri)
      watch(client, cancel)
      begin
        client.post(completions_path(uri), headers: request_headers, body: body) do |response|
          if response.status_code >= 400
            raise APIError.build(response.status_code, response.body_io.gets_to_end, response.headers)
          end
          while line = response.body_io.gets
            raise CancelledError.new("request was cancelled") if cancelled?(cancel)
            line = line.chomp
            next if line.empty?
            next unless line.starts_with?("data:")
            payload = line[5..].lstrip
            break if payload == "[DONE]"
            next if payload.empty?
            chunk   = accumulator.add(parse_sse_payload(payload))
            emitted = true
            block.call(chunk)
          end
        end
      ensure
        client.close
      end
      raise CancelledError.new("request was cancelled") if cancelled?(cancel)
      accumulator.response
    end
  end

  private struct Plan
    getter model       : String
    getter caps        : Capabilities
    getter thinking    : Bool?
    getter effort      : String?
    getter temperature : Float64?
    getter preserve    : Bool?

    def initialize(@model : String, @caps : Capabilities, @thinking : Bool?,
                   @effort : String?, @temperature : Float64?, @preserve : Bool?)
    end
  end

  private def plan_for(messages : Array(Message), tools : Array(Tool::Custom)?,
                       options : Options) : Plan
    model = options.model || @default_model
    caps  = @provider.capabilities(model)

    if tools && !tools.empty? && !caps.tools
      raise UnsupportedFeatureError.new("#{@provider.name}/#{model} does not support tool calling")
    end

    thinking = options.thinking
    case caps.thinking
    in .unsupported?
      if thinking
        raise UnsupportedFeatureError.new("#{@provider.name}/#{model} does not support thinking")
      end
    in .always?
      if thinking == false
        raise UnsupportedFeatureError.new("#{@provider.name}/#{model} always thinks; " \
                                          "thinking cannot be disabled")
      end
    in .optional?
      nil
    end

    if choice = options.tool_choice
      if tools.nil? || tools.empty?
        raise UnsupportedFeatureError.new("tool_choice requires tools to be supplied")
      end
      if choice.mode.required? && !caps.forced_tool_choice
        raise UnsupportedFeatureError.new("#{@provider.name}/#{model} does not support " \
                                          "tool_choice 'required'")
      end
      if choice.mode.function? && caps.thinking_active?(thinking)
        raise UnsupportedFeatureError.new("forcing a named tool is incompatible with " \
                                          "thinking on #{@provider.name}/#{model}")
      end
      if choice.mode.required? && caps.thinking_active?(thinking) &&
         !caps.forced_tool_choice_with_thinking
        raise UnsupportedFeatureError.new("#{@provider.name}/#{model} does not support " \
                                          "tool_choice 'required' while thinking is enabled; " \
                                          "disable thinking or use 'auto'")
      end
    end

    effort = options.reasoning_effort
    if effort
      unless caps.reasoning_effort
        raise UnsupportedFeatureError.new("#{@provider.name}/#{model} does not accept " \
                                          "reasoning_effort")
      end
      unless caps.valid_effort?(effort)
        raise UnsupportedFeatureError.new("invalid reasoning_effort '#{effort}' for " \
                                          "#{@provider.name}/#{model}: expected one of " \
                                          "#{caps.reasoning_efforts.join(", ")}")
      end
    elsif caps.reasoning_effort
      effort = caps.default_effort
    end

    temperature = options.temperature
    if temperature && !caps.sampling_allowed?(thinking)
      raise UnsupportedFeatureError.new("#{@provider.name}/#{model} uses fixed sampling " \
                                        "parameters; temperature must be omitted")
    end

    preserve = options.preserve_thinking
    if !preserve.nil? && !caps.preserved_thinking.optional?
      raise UnsupportedFeatureError.new("#{@provider.name}/#{model} does not expose a " \
                                        "preserved-thinking switch")
    end

    if options.prompt_cache_key && !caps.prompt_cache_key
      raise UnsupportedFeatureError.new("#{@provider.name}/#{model} does not accept " \
                                        "prompt_cache_key")
    end

    if options.user_id && !caps.user_id
      raise UnsupportedFeatureError.new("#{@provider.name}/#{model} does not accept user_id")
    end

    validate_media!(model, caps, messages)

    Plan.new(model, caps, thinking, effort, temperature, preserve)
  end

  private def validate_media!(model : String, caps : Capabilities,
                              messages : Array(Message)) : Nil
    return unless caps.media_checked?
    messages.each do |message|
      message.each_part do |part|
        case part.kind
        in .text?
          nil
        in .image?
          unless caps.image_input
            raise UnsupportedFeatureError.new("#{@provider.name}/#{model} does not accept image input")
          end
        in .video?
          unless caps.video_input
            raise UnsupportedFeatureError.new("#{@provider.name}/#{model} does not accept video input")
          end
        end
      end
    end
  end

  private def cancelled?(cancel : Channel(Nil)?) : Bool
    !cancel.nil? && cancel.closed?
  end

  private def watch(client : HTTP::Client, cancel : Channel(Nil)?) : Nil
    return if cancel.nil?
    spawn do
      cancel.receive?
      begin
        client.close
      rescue IO::Error
      end
    end
  end

  private def with_retry(cancel : Channel(Nil)?, resumable : -> Bool,
                         &block : -> ChatResponse) : ChatResponse
    attempt = 0
    loop do
      attempt += 1
      raise CancelledError.new("request was cancelled") if cancelled?(cancel)
      begin
        return block.call
      rescue ex : APIError
        raise CancelledError.new("request was cancelled") if cancelled?(cancel)
        raise ex unless ex.retryable? && attempt < @retry.max_attempts && resumable.call
        sleep @retry.delay_for(attempt, ex.retry_after)
      rescue ex : IO::Error
        raise CancelledError.new("request was cancelled") if cancelled?(cancel)
        raise ex unless attempt < @retry.max_attempts && resumable.call
        sleep @retry.delay_for(attempt, nil)
      end
    end
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

  private def request_body(plan : Plan, messages : Array(Message),
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

  private def parse_chat_response(json : JSON::Any) : ChatResponse
    choice        = json["choices"].as_a.first
    message       = Message.from_response(choice["message"])
    finish_reason = choice["finish_reason"]?.try(&.as_s?) || ""
    ChatResponse.new(message, finish_reason, usage_from(json, choice))
  rescue ex : KeyError | IndexError | TypeCastError
    raise Error.new("malformed API response body: #{ex.message}")
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

  private class PartialToolCall
    property id      : String          = ""
    property type    : String          = "function"
    property name    : String          = ""
    getter arguments : String::Builder = String::Builder.new

    def to_tool_call : ToolCall
      ToolCall.new(id: @id, function: FunctionCall.new(@name, @arguments.to_s), type: @type)
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
end
