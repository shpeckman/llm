# examples/swarm.cr
require "../src/llm"

private def rule(title : String) : Nil
  puts
  puts "── #{title} ".ljust(72, '─')
end

client  = LLM::Client.new(LLM::Provider.deepseek)
swarm   = LLM::Swarm.new(client)
session = "llm-swarm-#{Time.utc.to_unix}"
caps    = client.capabilities

swarm.add_role("researcher",
  system_prompt: "You are a meticulous researcher. Answer with concrete, verifiable facts and keep it under 120 words.",
  options: LLM::Options.new(user_id: caps.user_id ? "#{session}-researcher" : nil,
    include_usage: true))

swarm.add_role("critic",
  system_prompt: "You are a sharp but fair critic. Point out weaknesses, risks, and counter-arguments in under 120 words.",
  max_iterations: 5,
  options: LLM::Options.new(user_id: caps.user_id ? "#{session}-critic" : nil,
    include_usage: true)) do |agent|
  agent.thinking = true
  agent.reasoning_effort = "max"
end

swarm.add_role("synthesizer",
  system_prompt: "You are a synthesizer. Combine viewpoints into one balanced, actionable summary in under 120 words.",
  options: LLM::Options.new(user_id: caps.user_id ? "#{session}-synthesizer" : nil,
    include_usage: true))

swarm.on_result do |result|
  if result.success?
    usage = result.usage
    puts "  ✓ #{result.role.name} finished (#{usage.total_tokens} tokens, #{usage.cached_tokens} cached)"
  else
    puts "  ✗ #{result.role.name} failed: #{result.error.try(&.message)}"
  end
end

topic = "Should a small startup adopt a monorepo for its Crystal services?"

rule "Swarm: role-specific tasks"
results = swarm.run({
  "researcher"  => "Research the topic: #{topic}",
  "critic"      => "Critique the proposition: #{topic}",
  "synthesizer" => "Summarize the trade-offs around: #{topic}",
})

rule "Swarm: results"
results.each do |result|
  puts "## #{result.role.name}"
  if result.success?
    puts result.output!
  else
    puts "FAILED: #{result.error.try(&.message)}"
  end
  puts
end

rule "Swarm: same task, subset of roles"
swarm.run("In one sentence: what is the biggest risk of a monorepo?", roles: ["critic"]).each do |result|
  if result.success?
    puts "#{result.role.name}: #{result.output}"
  else
    puts "#{result.role.name} failed: #{result.error.try(&.message)}"
  end
end
