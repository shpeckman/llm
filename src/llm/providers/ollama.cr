# src/llm/providers/ollama.cr
class LLM::OllamaProvider < LLM::Provider
  def initialize
    super("ollama", "http://localhost:11434/v1", "llama3.2",
      ["OLLAMA_API_KEY"], Capabilities::DEFAULT,
      default_api_key: "ollama")
  end
end
