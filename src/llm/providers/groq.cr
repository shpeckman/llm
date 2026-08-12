module LLM
  # Groq (groq.com) — fast inference for open-weight models over the OpenAI
  # chat-completions dialect.
  class GroqProvider < Provider
    def initialize
      super("groq", "https://api.groq.com/openai/v1", "llama-3.3-70b-versatile",
        ["GROQ_API_KEY"], Capabilities::DEFAULT)
    end
  end
end
