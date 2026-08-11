# src/llm/providers/deepseek.cr
module LLM
  class DeepSeekProvider < Provider
    V4 = Capabilities.new(
      forced_tool_choice: false,
      thinking: ThinkingSupport::Optional,
      default_thinking: true,
      reasoning_effort: true,
      default_effort: "high",
      preserved_thinking: PreservedThinking::ToolCalls,
      sampling: SamplingSupport::FreeWithoutThinking)

    MODELS = [
      {"deepseek-v4", V4},
    ]

    def initialize
      super("deepseek", "https://api.deepseek.com/v1", "deepseek-v4-flash",
        ["DEEPSEEK_API_KEY"], Capabilities::DEFAULT, MODELS)
    end
  end
end
