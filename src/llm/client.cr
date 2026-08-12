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

  def pricing(model : String? = nil) : Pricing
    capabilities(model).pricing
  end

  def chat(messages : Array(Message), tools : Array(Tool::Custom)? = nil,
           options : Options = Options.new,
           cancel : Channel(Nil)? = nil) : ChatResponse
    plan = plan_for(messages, tools, options)
    body = protocol.chat_body(plan, messages, tools, options, false)
    with_retry(cancel, -> { true }) do
      uri    = URI.parse(base_url)
      client = new_http_client(uri, options.timeout)
      watch(client, cancel)
      begin
        response = client.post(protocol.chat_path(uri), headers: protocol.headers(@api_key), body: body)
        raise CancelledError.new("request was cancelled") if cancelled?(cancel)
        if response.status_code >= 400
          raise APIError.build(response.status_code, response.body, response.headers)
        end
        protocol.parse_chat_response(JSON.parse(response.body))
      ensure
        client.close
      end
    end
  end

  def chat_stream(messages : Array(Message), tools : Array(Tool::Custom)? = nil,
                  options : Options = Options.new,
                  cancel : Channel(Nil)? = nil, &block : StreamChunk ->) : ChatResponse
    plan    = plan_for(messages, tools, options)
    body    = protocol.chat_body(plan, messages, tools, options, true)
    emitted = false
    with_retry(cancel, -> { !emitted }) do
      accumulator = protocol.accumulator
      uri         = URI.parse(base_url)
      client      = new_http_client(uri, options.timeout)
      watch(client, cancel)
      begin
        client.post(protocol.chat_path(uri), headers: protocol.headers(@api_key), body: body) do |response|
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
            if chunk = accumulator.add(parse_sse_payload(payload))
              emitted = true
              block.call(chunk)
            end
          end
        end
      ensure
        client.close
      end
      raise CancelledError.new("request was cancelled") if cancelled?(cancel)
      accumulator.response
    end
  end

  def embed(input : String | Array(String), model : String? = nil,
            timeout : Time::Span? = nil) : EmbeddingResponse
    resolved = model || @provider.default_embedding_model
    if resolved.nil?
      raise UnsupportedFeatureError.new("#{@provider.name} has no default embedding " \
                                        "model; pass model explicitly")
    end
    unless @provider.capabilities(resolved).embeddings
      raise UnsupportedFeatureError.new("#{@provider.name}/#{resolved} does not support " \
                                        "embeddings")
    end

    body = protocol.embed_body(resolved, input)
    with_retry(nil, -> { true }) do
      uri    = URI.parse(base_url)
      client = new_http_client(uri, timeout)
      begin
        response = client.post(protocol.embeddings_path(uri), headers: protocol.headers(@api_key), body: body)
        if response.status_code >= 400
          raise APIError.build(response.status_code, response.body, response.headers)
        end
        protocol.parse_embedding_response(JSON.parse(response.body))
      ensure
        client.close
      end
    end
  end

  private def protocol : Protocol
    @provider.protocol
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

    if format = options.response_format
      case format.kind
      in .text?
        nil
      in .json_object?
        unless caps.json_object
          raise UnsupportedFeatureError.new("#{@provider.name}/#{model} does not support " \
                                            "response_format 'json_object'")
        end
      in .json_schema?
        unless caps.json_schema
          raise UnsupportedFeatureError.new("#{@provider.name}/#{model} does not support " \
                                            "response_format 'json_schema'")
        end
      end
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
                         &block : -> T) : T forall T
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

  private def new_http_client(uri : URI, timeout : Time::Span? = nil) : HTTP::Client
    client = HTTP::Client.new(uri)
    client.read_timeout = timeout || @timeout
    client
  end
end
