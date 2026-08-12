# examples/openai.cr
require "../src/llm"

# Chat with OpenAI, or any OpenAI-compatible endpoint.
#
#   export OPENAI_API_KEY=...
#   crystal run examples/openai.cr

client = LLM::Client.new(LLM::Provider.openai) # default model: gpt-5.5

response = client.chat([
  LLM::Message.user("In one short sentence: what is the Crystal programming language?"),
])
puts response.message.text

if usage = response.usage
  STDERR.puts "(#{usage.prompt_tokens} in / #{usage.completion_tokens} out)"
end

# Other compatible endpoints work the same way — only the factory changes:
#
#   LLM::Provider.openrouter  # openrouter.ai — OPENROUTER_API_KEY, many vendors
#   LLM::Provider.groq        # groq.com      — GROQ_API_KEY, fast open weights
#   LLM::Provider.ollama      # localhost     — no key needed
#
# Anything else goes through LLM::Provider.custom with an explicit base URL
# and capability set.
