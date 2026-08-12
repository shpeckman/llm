# src/llm/providers/openai.cr
module LLM
  # OpenAI (api.openai.com). The chat-completions wire format this provider
  # uses is shared by many other endpoints; for preconfigured alternatives
  # see OpenRouterProvider, GroqProvider and OllamaProvider, and
  # Provider.custom for everything else.
  class OpenAIProvider < Provider
    # GPT-5.x reasoning models: thinking is always on and sampling is fixed;
    # depth is steered with reasoning_effort. Prices are USD per 1M tokens
    # from the public OpenRouter listing (August 2026); cached input is
    # estimated at 10% of input where not published.
    private def self.gpt5(context_window : Int32, input : Float64,
                          output : Float64) : Capabilities
      Capabilities.new(
        forced_tool_choice: true,
        thinking: ThinkingSupport::Always,
        reasoning_effort: true,
        reasoning_efforts: ["minimal", "low", "medium", "high", "xhigh"],
        default_effort: "medium",
        sampling: SamplingSupport::Fixed,
        max_tokens_field: "max_completion_tokens",
        prompt_cache_key: true,
        image_input: true,
        json_object: true,
        json_schema: true,
        context_window: context_window,
        pricing: Pricing.new(input: input, output: output, cached_input: input * 0.1))
    end

    # Non-reasoning chat models: free sampling, no thinking switch.
    GPT_5_2_CHAT = Capabilities.new(
      forced_tool_choice: true,
      max_tokens_field: "max_completion_tokens",
      prompt_cache_key: true,
      image_input: true,
      json_object: true,
      json_schema: true,
      context_window: 128_000,
      pricing: Pricing.new(input: 1.75, output: 14.0, cached_input: 0.175))

    GPT_CHAT_LATEST = Capabilities.new(
      forced_tool_choice: true,
      prompt_cache_key: true,
      image_input: true,
      json_object: true,
      json_schema: true,
      context_window: 400_000,
      pricing: Pricing.new(input: 5.0, output: 30.0, cached_input: 0.5))

    EMBEDDING = Capabilities.new(
      tools: false,
      forced_tool_choice: false,
      embeddings: true,
      context_window: 8_192)

    # Unknown future gpt-* models are assumed to be reasoning models in the
    # current generation's shape.
    FALLBACK = gpt5(1_050_000, 5.0, 30.0)

    # Prefix table: entries are matched with String#starts_with?, so longer
    # prefixes must come before shorter ones that would also match.
    MODELS = [
      {"gpt-5.6-luna",       gpt5(1_050_000, 0.10, 0.60)},
      {"gpt-5.6-terra",      gpt5(1_050_000, 1.0, 6.0)},
      {"gpt-5.6-sol",        gpt5(1_050_000, 5.0, 30.0)},
      {"gpt-5.6",            gpt5(1_050_000, 5.0, 30.0)},
      {"gpt-5.5-pro",        gpt5(1_050_000, 30.0, 180.0)},
      {"gpt-5.5",            gpt5(1_050_000, 5.0, 30.0)},
      {"gpt-5.4-nano",       gpt5(400_000, 0.20, 1.25)},
      {"gpt-5.4-mini",       gpt5(400_000, 0.75, 4.5)},
      {"gpt-5.4-pro",        gpt5(1_050_000, 30.0, 180.0)},
      {"gpt-5.4",            gpt5(1_050_000, 2.5, 15.0)},
      {"gpt-5.3-codex",      gpt5(400_000, 1.75, 14.0)},
      {"gpt-5.2-codex",      gpt5(400_000, 1.75, 14.0)},
      {"gpt-5.2-chat",       GPT_5_2_CHAT},
      {"gpt-5.2-pro",        gpt5(400_000, 21.0, 168.0)},
      {"gpt-5.2",            gpt5(400_000, 1.75, 14.0)},
      {"gpt-5.1-codex-mini", gpt5(400_000, 0.25, 2.0)},
      {"gpt-5.1-codex-max",  gpt5(400_000, 1.25, 10.0)},
      {"gpt-5.1-codex",      gpt5(400_000, 1.25, 10.0)},
      {"gpt-5.1",            gpt5(400_000, 1.25, 10.0)},
      {"gpt-chat-latest",    GPT_CHAT_LATEST},
      {"text-embedding",     EMBEDDING},
    ]

    def initialize
      super("openai", "https://api.openai.com/v1", "gpt-5.5",
        ["OPENAI_API_KEY"], FALLBACK, MODELS,
        default_embedding_model: "text-embedding-3-small")
    end
  end
end
