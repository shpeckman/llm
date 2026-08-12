# src/llm/providers/openrouter.cr
class LLM::OpenRouterProvider < LLM::Provider
  def initialize
    super("openrouter", "https://openrouter.ai/api/v1", "openai/gpt-5.5",
      ["OPENROUTER_API_KEY"], Capabilities::DEFAULT)
  end
end