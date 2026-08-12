# src/llm/providers/openrouter.cr
module LLM
  # OpenRouter (openrouter.ai) — a gateway to many vendors' models over the
  # OpenAI chat-completions dialect. Model names look like "openai/gpt-5.5"
  # or "anthropic/claude-opus-5". Capabilities vary per model, so the table
  # is left empty and the generic fallback applies; use Provider.custom with
  # explicit capabilities if you need validation for a specific model.
  class OpenRouterProvider < Provider
    def initialize
      super("openrouter", "https://openrouter.ai/api/v1", "openai/gpt-5.5",
        ["OPENROUTER_API_KEY"], Capabilities::DEFAULT)
    end
  end
end
