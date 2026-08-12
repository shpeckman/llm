# src/llm/providers/groq.cr
class LLM::GroqProvider < LLM::Provider
  def initialize
    super("groq", "https://api.groq.com/openai/v1", "llama-3.3-70b-versatile",
      ["GROQ_API_KEY"], Capabilities::DEFAULT)
  end
end
