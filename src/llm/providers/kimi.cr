# src/llm/providers/kimi.cr
module LLM
  class KimiProvider < Provider
    K3 = Capabilities.new(
      forced_tool_choice: true,
      thinking: ThinkingSupport::Always,
      reasoning_effort: true,
      reasoning_efforts: ["low", "high", "max"],
      default_effort: "max",
      preserved_thinking: PreservedThinking::Always,
      sampling: SamplingSupport::Fixed,
      max_tokens_field: "max_completion_tokens",
      prompt_cache_key: true,
      image_input: true,
      video_input: true)

    K2_7_CODE = Capabilities.new(
      forced_tool_choice: false,
      thinking: ThinkingSupport::Always,
      preserved_thinking: PreservedThinking::Always,
      sampling: SamplingSupport::Fixed,
      max_tokens_field: "max_completion_tokens",
      prompt_cache_key: true,
      image_input: true,
      video_input: true)

    K2_6 = Capabilities.new(
      forced_tool_choice: false,
      thinking: ThinkingSupport::Optional,
      default_thinking: true,
      preserved_thinking: PreservedThinking::Optional,
      sampling: SamplingSupport::Fixed,
      max_tokens_field: "max_completion_tokens",
      prompt_cache_key: true,
      image_input: true,
      video_input: true)

    K2_5 = Capabilities.new(
      forced_tool_choice: false,
      thinking: ThinkingSupport::Optional,
      default_thinking: true,
      preserved_thinking: PreservedThinking::Unsupported,
      sampling: SamplingSupport::Fixed,
      max_tokens_field: "max_completion_tokens",
      prompt_cache_key: true,
      image_input: true,
      video_input: true)

    MOONSHOT_V1_VISION = Capabilities.new(
      forced_tool_choice: false,
      max_tokens_field: "max_completion_tokens",
      prompt_cache_key: true,
      image_input: true)

    MOONSHOT_V1 = Capabilities.new(
      forced_tool_choice: false,
      max_tokens_field: "max_completion_tokens",
      prompt_cache_key: true)

    MODELS = [
      {"kimi-k3",                         K3},
      {"kimi-k2.7-code",                  K2_7_CODE},
      {"kimi-k2.6",                       K2_6},
      {"kimi-k2.5",                       K2_5},
      {"moonshot-v1-8k-vision-preview",   MOONSHOT_V1_VISION},
      {"moonshot-v1-32k-vision-preview",  MOONSHOT_V1_VISION},
      {"moonshot-v1-128k-vision-preview", MOONSHOT_V1_VISION},
      {"moonshot-v1",                     MOONSHOT_V1},
    ]

    def initialize
      super("kimi", "https://api.moonshot.ai/v1", "kimi-k3",
        ["MOONSHOT_API_KEY", "KIMI_API_KEY"], K3, MODELS)
    end
  end
end
