# examples/anthropic.cr
require "../src/llm"

# Chat with Claude over the Anthropic Messages API.
#
#   export ANTHROPIC_API_KEY=...
#   crystal run examples/anthropic.cr

client = LLM::Client.new(LLM::Provider.anthropic) # default model: claude-sonnet-5

response = client.chat([
  LLM::Message.user("In one short sentence: what is the Crystal programming language?"),
])
puts response.message.text

if usage = response.usage
  STDERR.puts "(#{usage.prompt_tokens} in / #{usage.completion_tokens} out)"
end

# Claude 5-series models think adaptively; steer depth with effort:
#
#   agent = LLM::Agent.new(client)
#   agent.reasoning_effort = "max"
#
# Claude Haiku 4.5 uses legacy budgeted thinking instead:
#
#   options = LLM::Options.new(model: "claude-haiku-4-5", thinking: true)
