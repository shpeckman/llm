# src/llm/providers/deepseek.cr
class LLM::DeepSeekProvider < LLM::Provider
  V4 = Capabilities.new(
    forced_tool_choice_with_thinking: false,
    thinking: ThinkingSupport::Optional,
    default_thinking: true,
    reasoning_effort: true,
    reasoning_efforts: ["low", "medium", "high", "xhigh", "max"],
    default_effort: "high",
    preserved_thinking: PreservedThinking::ToolsPresent,
    sampling: SamplingSupport::FreeWithoutThinking,
    user_id: true)

  MODELS = [
    {"deepseek-v4", V4},
  ]

  def initialize
    super("deepseek", "https://api.deepseek.com", "deepseek-v4-flash",
      ["DEEPSEEK_API_KEY"], Capabilities::DEFAULT, MODELS)
  end
end
