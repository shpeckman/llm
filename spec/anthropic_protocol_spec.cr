# spec/anthropic_protocol_spec.cr
require "./spec_helper"

private class WeatherTool < LLM::Tool::Custom
  def name : String
    "get_weather"
  end

  def description : String
    "Get the current weather for a city."
  end

  def parameters_schema : JSON::Any
    JSON.parse(LLM::SpecFixtures::ANTHROPIC[:weather_schema])
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
          LLM::ToolCall.new(id: "toolu_1", function: LLM::FunctionCall.new("get_weather", LLM::SpecFixtures::ANTHROPIC[:weather_args])),
        ]),
        LLM::Message.tool_result("toolu_1", "sunny"),
      ])
      messages = body["messages"].as_a
      block    = messages[1]["content"].as_a[0]
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
      blocks = JSON.parse(LLM::SpecFixtures::ANTHROPIC[:preserved_blocks]).as_a
      assistant = LLM::Message.assistant(
        tool_calls: [LLM::ToolCall.new(id: "toolu_1",
          function: LLM::FunctionCall.new("get_weather", LLM::SpecFixtures::ANTHROPIC[:weather_args]))],
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
      response = anthropic_protocol.parse_chat_response(JSON.parse(LLM::SpecFixtures::ANTHROPIC[:chat_response]))
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
      acc.add(JSON.parse(LLM::SpecFixtures::ANTHROPIC[:stream_message_start]))
      acc.add(JSON.parse(LLM::SpecFixtures::ANTHROPIC[:stream_thinking_start]))

      chunk = acc.add(JSON.parse(LLM::SpecFixtures::ANTHROPIC[:stream_thinking_delta]))
      chunk.not_nil!.reasoning_delta.should eq "hmm"

      acc.add(JSON.parse(LLM::SpecFixtures::ANTHROPIC[:stream_signature_delta]))
      acc.add(JSON.parse(LLM::SpecFixtures::ANTHROPIC[:stream_block_stop_0]))
      acc.add(JSON.parse(LLM::SpecFixtures::ANTHROPIC[:stream_tool_use_start]))
      acc.add(JSON.parse(LLM::SpecFixtures::ANTHROPIC[:stream_tool_use_delta_1]))
      acc.add(JSON.parse(LLM::SpecFixtures::ANTHROPIC[:stream_tool_use_delta_2]))
      acc.add(JSON.parse(LLM::SpecFixtures::ANTHROPIC[:stream_block_stop_1]))
      acc.add(JSON.parse(LLM::SpecFixtures::ANTHROPIC[:stream_message_delta]))
      acc.add(JSON.parse(LLM::SpecFixtures::ANTHROPIC[:stream_message_stop]))

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
      acc.add(JSON.parse(LLM::SpecFixtures::ANTHROPIC[:stream_text_start]))
      chunk = acc.add(JSON.parse(LLM::SpecFixtures::ANTHROPIC[:stream_text_delta]))
      chunk.not_nil!.content_delta.should eq "Hello"
    end

    it "raises a retryable ServerError on overloaded_error events" do
      acc = anthropic_protocol.accumulator
      ex = expect_raises(LLM::ServerError) do
        acc.add(JSON.parse(LLM::SpecFixtures::ANTHROPIC[:stream_error]))
      end
      ex.retryable?.should be_true
    end

    it "ignores pings and unknown event types" do
      acc = anthropic_protocol.accumulator
      acc.add(JSON.parse(LLM::SpecFixtures::ANTHROPIC[:stream_ping])).should be_nil
      acc.add(JSON.parse(LLM::SpecFixtures::ANTHROPIC[:stream_future_event])).should be_nil
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
