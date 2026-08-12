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

# ==============================================================================
# 1. PARALLEL / BATCH EXECUTION
# ==============================================================================

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

swarm.on_view do |report|
  if result = report.finished
    if result.success?
      usage = result.usage
      puts "  ✓ #{result.role.name} finished (#{usage.total_tokens} tokens, #{usage.cached_tokens} cached), #{report.remaining} left"
    else
      puts "  ✗ #{result.role.name} failed: #{result.error.try(&.message)}"
    end
  end
end

topic = "Should a small startup adopt a monorepo for its Crystal services?"

rule "Swarm: role-specific tasks (Parallel Execution)"
results = swarm.run({
  "researcher"  => "Research the topic: #{topic}",
  "critic"      => "Critique the proposition: #{topic}",
  "synthesizer" => "Summarize the trade-offs around: #{topic}",
})

rule "Swarm: parallel results"
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

# ==============================================================================
# 2. SEQUENTIAL EXECUTION WITH HANDOFFS
# ==============================================================================

# Configure roles that have the authority to transfer control
swarm.add_role("triage",
  system_prompt: "You are a routing agent. Determine if the user's request is about 'pricing' or 'engineering'. Use the provided tools to transfer the conversation to the appropriate specialist ('sales' or 'engineering'). Do not answer the user's question yourself.",
  handoffs: ["sales", "engineering"])

swarm.add_role("sales",
  system_prompt: "You are a sales specialist. Answer the user's question focusing on costs, tiers, and billing. Keep it to one short sentence.")

swarm.add_role("engineering",
  system_prompt: "You are a senior engineer. Answer the user's question focusing on technical implementation and architecture. Keep it to one short sentence.")

# Watch the handoffs happen in real-time
swarm.on_handoff do |from_role, to_role|
  puts "  » Handoff triggered: #{from_role} -> #{to_role}"
end

rule "Swarm: Sequential Handoff (Sales)"
puts "Task: How much does the enterprise tier cost?"
puts
sequence_result = swarm.run_sequence("How much does the enterprise tier cost?", starting_role: "triage")
puts
puts "Final Role: #{sequence_result.final_role.name}"
puts "Final Output: #{sequence_result.output}"
puts "Total Tokens: #{sequence_result.usage.total_tokens}"

rule "Swarm: Sequential Handoff (Engineering)"
puts "Task: How do I configure the Redis cache?"
puts
sequence_result2 = swarm.run_sequence("How do I configure the Redis cache?", starting_role: "triage")
puts
puts "Final Role: #{sequence_result2.final_role.name}"
puts "Final Output: #{sequence_result2.output}"
puts "Total Tokens: #{sequence_result2.usage.total_tokens}"

