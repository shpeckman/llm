# src/llm/providers/ollama.cr
module LLM
  # Ollama (ollama.com) — locally hosted models over the OpenAI
  # chat-completions dialect. Ollama ignores the API key, so a placeholder
  # is used when no key is configured.
  class OllamaProvider < Provider
    def initialize
      super("ollama", "http://localhost:11434/v1", "llama3.2",
        ["OLLAMA_API_KEY"], Capabilities::DEFAULT,
        default_api_key: "ollama")
    end
  end
end
