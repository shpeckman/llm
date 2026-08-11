# examples/demo.cr
require "colorize"
require "../src/llm"

private class TimeTool < LLM::Tool::Custom
  def name : String
    "current_time"
  end

  def description : String
    "Get the current local date and time as an ISO 8601 string."
  end

  def parameters_schema : JSON::Any
    JSON.parse(%({"type":"object","properties":{},"required":[],"additionalProperties":false}))
  end

  def execute(arguments : JSON::Any) : String
    Time.local.to_rfc3339
  end
end

private def rule(title : String) : Nil
  puts
  puts "── #{title} ".ljust(72, '─').colorize(:cyan)
end

private def run_and_report(agent : LLM::Agent, streaming : Bool, prompt : String) : Nil
  answer = agent.run(prompt)
  if streaming
    puts
  else
    puts answer
  end
  usage = agent.usage
  unless usage.empty?
    puts "  · #{usage.prompt_tokens} in (#{usage.cached_tokens} cached) / #{usage.completion_tokens} out".colorize(:dark_gray)
  end
end

private def build_agent(provider : LLM::Provider, *, streaming : Bool = true,
                        session : String? = nil) : LLM::Agent
  client = LLM::Client.new(provider)
  agent  = LLM::Agent.new(client)
  agent.include_usage = true
  agent.prompt_cache_key = session if session && client.capabilities.prompt_cache_key
  agent.register(TimeTool.new)
  agent.register_workspace_tools(Dir.current)

  if streaming
    agent.on_reasoning { |delta| print delta.colorize(:dark_gray) }
    agent.on_token { |delta| print delta }
  end
  agent.on_tool_result do |call, result|
    preview = result.gsub('\n', ' ')
    preview = preview[0, 100] + "…" if preview.size > 100
    puts "\n  » #{call.function.name}: #{preview}".colorize(:yellow)
  end
  agent
end

rule "DeepSeek V4-Flash · thinking on · effort max"
deepseek = build_agent(LLM::Provider.deepseek)
deepseek.reasoning_effort = "max"
run_and_report(deepseek, true, "What time is it right now, and how many days until the next New Year's Day?")

rule "DeepSeek V4-Flash · thinking off"
deepseek.reset
deepseek.thinking = false
run_and_report(deepseek, true, "In one sentence, what is a Mixture-of-Experts model?")

rule "DeepSeek V4-Flash · agentic loop over the workspace"
deepseek.reset
deepseek.thinking = true
deepseek.reasoning_effort = "high"
run_and_report(deepseek, true, "List the Crystal source files under src/ and tell me which one defines the Agent class.")

if ENV["MOONSHOT_API_KEY"]? || ENV["KIMI_API_KEY"]?
  rule "Kimi K3 · always-on thinking · effort max · cached session"
  kimi = build_agent(LLM::Provider.kimi, session: "llm-demo-#{Time.utc.to_unix}")
  kimi.max_tokens = 4096
  run_and_report(kimi, true, "Greet me in exactly five words.")

  rule "Kimi K3 · agentic loop with capped output"
  kimi.reset
  run_and_report(kimi, true, "Which file defines the retry policy? Answer with just the path.")
else
  rule "Kimi skipped"
  puts "Set MOONSHOT_API_KEY (or KIMI_API_KEY) to run the Kimi comparison."
end

puts
