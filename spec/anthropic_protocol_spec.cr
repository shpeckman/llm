require "./spec_helper"

private class WeatherTool < LLM::Tool::Custom
  def name : String
    "get_weather"
  end

  def description : String
    "Get the current weather for a city."
  end

  def parameters_schema : JSON::Any
    JSON.parse(%({"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}))
  end

  def execute(arguments : JSON::Any) : String
    "sunny"
  end
end

private def anthropic_protocol : LLM::AnthropicProtocol
  LLM::AnthropicProtocol.new
end

private def anthropic_plan(caps : LLM::Capabilities = LLM::Provider.anthropic.capabilities("claude-sonnet-5"),
                           thinking : Bool? = nil, effort : String? = nil) : LLM::Plan
  LLM::Plan.new("claude-sonnet-5", caps, thinking, effort, nil, nil)
end

private def anthropic_body(messages : Array(LLM::Message),
                           tools : Array(LLM::Tool::Custom)? = nil,
                           options : LLM::Options = LLM::Options.new,
                           plan : LLM::Plan = anthropic_plan) : JSON::Any
  JSON.parse(anthropic_protocol.chat_body(plan, messages, tools, options, false))
end

describe LLM::Provider do
  describe ".anthropic" do
    it "uses the anthropic protocol and Messages API defaults" do
      provider = LLM::Provider.anthropic
      provider.name.should eq "anthropic"
      provider.base_url.should eq "https://api.anthropic.com"
      provider.default_model.should eq "claude-sonnet-5"
      provider.protocol.should be_a(LLM::AnthropicProtocol)
      provider.api_key_env.should eq ["ANTHROPIC_API_KEY"]
    end

    it "resolves for_name aliases" do
      LLM::Provider.for_name("anthropic").not_nil!.name.should eq "anthropic"
      LLM::Provider.for_name("Claude").not_nil!.name.should eq "anthropic"
    end

    it "keeps the openai dialect for openai providers" do
      LLM::Provider.openai.protocol.should be_a(LLM::OpenAIProtocol)
    end
  end
end

describe LLM::AnthropicProtocol do
  describe "#chat_body" do
    it "hoists system messages to a top-level parameter" do
      body = anthropic_body([
        LLM::Message.system("be terse"),
        LLM::Message.user("hi"),
      ])
      body["system"].as_s.should eq "be terse"
      messages = body["messages"].as_a
      messages.size.should eq 1
      messages[0]["role"].as_s.should eq "user"
    end

    it "always sends max_tokens, defaulting when unset" do
      body = anthropic_body([LLM::Message.user("hi")])
      body["max_tokens"].as_i.should eq 32_768
    end

    it "honors an explicit max_tokens" do
      body = anthropic_body([LLM::Message.user("hi")], options: LLM::Options.new(max_tokens: 4096))
      body["max_tokens"].as_i.should eq 4096
    end

    it "puts effort in output_config" do
      body = anthropic_body([LLM::Message.user("hi")], plan: anthropic_plan(effort: "max"))
      body["output_config"]["effort"].as_s.should eq "max"
    end

    it "sends no thinking object for adaptive models" do
      body = anthropic_body([LLM::Message.user("hi")])
      body["thinking"]?.should be_nil
    end

    it "sends a budgeted thinking object for legacy models" do
      haiku = LLM::Provider.anthropic.capabilities("claude-haiku-4-5")
      body = anthropic_body([LLM::Message.user("hi")],
        plan: anthropic_plan(caps: haiku, thinking: true))
      body["thinking"]["type"].as_s.should eq "enabled"
      body["thinking"]["budget_tokens"].as_i.should be >= 1024
    end

    it "serializes tools with input_schema and maps tool_choice" do
      tools = [WeatherTool.new.as(LLM::Tool::Custom)]
      body = anthropic_body([LLM::Message.user("weather?")], tools,
        LLM::Options.new(tool_choice: LLM::ToolChoice.required))
      body["tools"][0]["name"].as_s.should eq "get_weather"
      body["tools"][0]["input_schema"]["type"].as_s.should eq "object"
      body["tool_choice"]["type"].as_s.should eq "any"
    end

    it "serializes assistant tool calls as tool_use blocks" do
      body = anthropic_body([
        LLM::Message.user("weather in SF?"),
        LLM::Message.assistant(tool_calls: [
          LLM::ToolCall.new(id: "toolu_1", function: LLM::FunctionCall.new("get_weather", %({"city":"SF"}))),
        ]),
        LLM::Message.tool_result("toolu_1", "sunny"),
      ])
      messages = body["messages"].as_a
      block = messages[1]["content"].as_a[0]
      block["type"].as_s.should eq "tool_use"
      block["id"].as_s.should eq "toolu_1"
      block["input"]["city"].as_s.should eq "SF"
    end

    it "groups consecutive tool results into one user message" do
      body = anthropic_body([
        LLM::Message.user("q"),
        LLM::Message.tool_result("toolu_1", "out1"),
        LLM::Message.tool_result("toolu_2", "out2"),
      ])
      messages = body["messages"].as_a
      messages.size.should eq 2
      messages[1]["role"].as_s.should eq "user"
      results = messages[1]["content"].as_a
      results.map { |r| r["type"].as_s }.should eq ["tool_result", "tool_result"]
      results[0]["tool_use_id"].as_s.should eq "toolu_1"
      results[1]["content"].as_s.should eq "out2"
    end

    it "passes preserved assistant blocks back verbatim" do
      blocks = JSON.parse(%([
        {"type":"thinking","thinking":"hmm","signature":"sig123"},
        {"type":"tool_use","id":"toolu_1","name":"get_weather","input":{"city":"SF"}}
      ])).as_a
      assistant = LLM::Message.assistant(
        tool_calls: [LLM::ToolCall.new(id: "toolu_1",
          function: LLM::FunctionCall.new("get_weather", %({"city":"SF"})))],
        reasoning_content: "hmm")
      assistant.response_blocks = blocks
      body = anthropic_body([
        LLM::Message.user("weather?"),
        assistant,
        LLM::Message.tool_result("toolu_1", "sunny"),
      ])
      content = body["messages"][1]["content"].as_a
      content[0]["type"].as_s.should eq "thinking"
      content[0]["signature"].as_s.should eq "sig123"
      content[1]["type"].as_s.should eq "tool_use"
    end
  end

  describe "#parse_chat_response" do
    it "assembles text, thinking and tool_use blocks" do
      response = anthropic_protocol.parse_chat_response(JSON.parse(%({
        "content": [
          {"type":"thinking","thinking":"let me check","signature":"sig"},
          {"type":"text","text":"checking weather"},
          {"type":"tool_use","id":"toolu_1","name":"get_weather","input":{"city":"SF"}}
        ],
        "stop_reason": "tool_use",
        "usage": {"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":4}
      })))
      response.finish_reason.should eq "tool_calls"
      response.message.text.should eq "checking weather"
      response.message.reasoning_content.should eq "let me check"
      calls = response.message.tool_calls.not_nil!
      calls.size.should eq 1
      calls[0].function.name.should eq "get_weather"
      calls[0].parsed_arguments["city"].as_s.should eq "SF"
      usage = response.usage.not_nil!
      usage.prompt_tokens.should eq 10
      usage.completion_tokens.should eq 20
      usage.total_tokens.should eq 30
      usage.cached_tokens.should eq 4
      response.message.response_blocks.not_nil!.size.should eq 3
    end
  end

  describe "stream accumulation" do
    it "rebuilds the response from SSE events" do
      acc = anthropic_protocol.accumulator
      acc.add(JSON.parse(%({"type":"message_start","message":{"usage":{"input_tokens":12,"output_tokens":1}}})))
      acc.add(JSON.parse(%({"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}})))

      chunk = acc.add(JSON.parse(%({"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}})))
      chunk.not_nil!.reasoning_delta.should eq "hmm"

      acc.add(JSON.parse(%({"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}})))
      acc.add(JSON.parse(%({"type":"content_block_stop","index":0})))
      acc.add(JSON.parse(%({"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"get_weather","input":{}}})))
      acc.add(JSON.parse(%({"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"city\":"}})))
      acc.add(JSON.parse(%({"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"SF\"}"}})))
      acc.add(JSON.parse(%({"type":"content_block_stop","index":1})))
      acc.add(JSON.parse(%({"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":30}})))
      acc.add(JSON.parse(%({"type":"message_stop"})))

      response = acc.response
      response.finish_reason.should eq "tool_calls"
      response.message.reasoning_content.should eq "hmm"
      call = response.message.tool_calls.not_nil![0]
      call.parsed_arguments["city"].as_s.should eq "SF"
      usage = response.usage.not_nil!
      usage.prompt_tokens.should eq 12
      usage.completion_tokens.should eq 30
      blocks = response.message.response_blocks.not_nil!
      blocks.size.should eq 2
      blocks[0]["signature"].as_s.should eq "sig"
    end

    it "emits content deltas" do
      acc = anthropic_protocol.accumulator
      acc.add(JSON.parse(%({"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}})))
      chunk = acc.add(JSON.parse(%({"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}})))
      chunk.not_nil!.content_delta.should eq "Hello"
    end

    it "raises a retryable ServerError on overloaded_error events" do
      acc = anthropic_protocol.accumulator
      ex = expect_raises(LLM::ServerError) do
        acc.add(JSON.parse(%({"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}})))
      end
      ex.retryable?.should be_true
    end

    it "ignores pings and unknown event types" do
      acc = anthropic_protocol.accumulator
      acc.add(JSON.parse(%({"type":"ping"}))).should be_nil
      acc.add(JSON.parse(%({"type":"future_event","data":{}}))).should be_nil
    end
  end

  describe "embeddings" do
    it "is unsupported" do
      expect_raises(LLM::UnsupportedFeatureError) do
        anthropic_protocol.embed_body("model", "input")
      end
    end
  end
end
