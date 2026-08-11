# examples/swarm_demo.cr
require "../src/llm"

private def rule(title : String) : Nil
  puts
  puts "── #{title} ".ljust(72, '─')
end

client = LLM::Client.new(LLM::Provider.deepseek)
swarm  = LLM::Swarm.new(client)

swarm.add_role("researcher",
  system_prompt: "You are a meticulous researcher. Answer with concrete, verifiable facts and keep it under 120 words.")

swarm.add_role("critic",
  system_prompt: "You are a sharp but fair critic. Point out weaknesses, risks, and counter-arguments in under 120 words.",
  max_iterations: 5) do |agent|
  agent.thinking = true
  agent.reasoning_effort = "high"
end

swarm.add_role("synthesizer",
  system_prompt: "You are a synthesizer. Combine viewpoints into one balanced, actionable summary in under 120 words.")

swarm.on_result do |result|
  if result.success?
    puts "  ✓ #{result.role.name} finished (#{result.usage.total_tokens} tokens)"
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
