module LLM
  # Anthropic (api.anthropic.com) — Claude models over the Messages API.
  class AnthropicProvider < Provider
    # Claude 5-series: adaptive thinking, always on, steered with
    # output_config.effort. Thinking blocks are keep-all by default, so
    # assistant blocks are passed back verbatim. Prices USD per 1M tokens
    # (Anthropic pricing, August 2026); cache reads at 10% of input.
    private def self.claude5(input : Float64, output : Float64) : Capabilities
      Capabilities.new(
        forced_tool_choice: true,
        thinking: ThinkingSupport::Always,
        reasoning_effort: true,
        reasoning_efforts: ["low", "medium", "high", "xhigh", "max"],
        default_effort: "high",
        preserved_thinking: PreservedThinking::Always,
        sampling: SamplingSupport::Fixed,
        user_id: true,
        image_input: true,
        context_window: 1_000_000,
        max_output_tokens: 128_000,
        pricing: Pricing.new(input: input, output: output, cached_input: input * 0.1))
    end

    # Claude Haiku 4.5: legacy extended thinking behind a switch with a
    # token budget; free sampling while thinking is off. Thinking blocks
    # are preserved on tool-calling turns, where the API requires them.
    HAIKU_4_5 = Capabilities.new(
      forced_tool_choice: true,
      thinking: ThinkingSupport::Optional,
      default_thinking: false,
      preserved_thinking: PreservedThinking::ToolCalls,
      sampling: SamplingSupport::FreeWithoutThinking,
      user_id: true,
      image_input: true,
      context_window: 200_000,
      max_output_tokens: 64_000,
      pricing: Pricing.new(input: 1.0, output: 5.0, cached_input: 0.1))

    FALLBACK = claude5(5.0, 25.0)

    MODELS = [
      {"claude-fable-5", claude5(10.0, 50.0)},
      {"claude-opus-5", claude5(5.0, 25.0)},
      {"claude-sonnet-5", claude5(2.0, 10.0)},
      {"claude-haiku-4-5", HAIKU_4_5},
    ]

    def initialize
      super("anthropic", "https://api.anthropic.com", "claude-sonnet-5",
        ["ANTHROPIC_API_KEY"], FALLBACK, MODELS,
        protocol: AnthropicProtocol.new)
    end
  end
end
