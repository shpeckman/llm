# src/llm/swarm.cr
class LLM::Swarm
  alias AgentConfigurator = Agent ->

  class Role
    getter name             : String
    getter system_prompt    : String
    getter model            : String?
    getter max_iterations   : Int32
    getter thinking         : Bool?
    getter reasoning_effort : String?
    getter configure        : AgentConfigurator?

    def initialize(@name : String,
                   @system_prompt : String = Agent::DEFAULT_SYSTEM_PROMPT,
                   @model : String? = nil,
                   @max_iterations : Int32 = Agent::DEFAULT_MAX_ITERATIONS,
                   @thinking : Bool? = nil,
                   @reasoning_effort : String? = nil,
                   @configure : AgentConfigurator? = nil)
    end
  end

  class Result
    getter role   : Role
    getter task   : String
    getter output : String?
    getter error  : Exception?

    def initialize(@role : Role, @task : String,
                   @output : String? = nil,
                   @error : Exception? = nil)
    end

    def success? : Bool
      @error.nil?
    end

    # Returns the output on success; re-raises the stored exception on failure.
    def output! : String
      if error = @error
        raise error
      end
      @output || ""
    end
  end

  getter roles : Array(Role)

  @on_result : (Result ->)?

  def initialize(@client : Client)
    @roles     = [] of Role
    @on_result = nil
  end

  def add_role(name : String,
               system_prompt : String = Agent::DEFAULT_SYSTEM_PROMPT,
               model : String? = nil,
               max_iterations : Int32 = Agent::DEFAULT_MAX_ITERATIONS,
               thinking : Bool? = nil,
               reasoning_effort : String? = nil,
               configure : AgentConfigurator? = nil) : Role
    register_role(Role.new(name, system_prompt, model, max_iterations,
      thinking, reasoning_effort, configure))
  end

  def add_role(name : String,
               system_prompt : String = Agent::DEFAULT_SYSTEM_PROMPT,
               model : String? = nil,
               max_iterations : Int32 = Agent::DEFAULT_MAX_ITERATIONS,
               thinking : Bool? = nil,
               reasoning_effort : String? = nil,
               &configure : Agent ->) : Role
    add_role(name, system_prompt, model, max_iterations,
      thinking, reasoning_effort, configure)
  end

  def [](name : String) : Role?
    @roles.find { |role| role.name == name }
  end

  def on_result(&block : Result ->) : Nil
    @on_result = block
  end

  # Runs the same task for every configured role, or for the named subset.
  def run(task : String, roles : Array(String)? = nil) : Array(Result)
    selected =
      if names = roles
        raise SwarmError.new("no roles selected") if names.empty?
        names.map { |name| self[name] || raise SwarmError.new("unknown role: #{name}") }
      else
        raise SwarmError.new("no roles configured") if @roles.empty?
        @roles
      end
    execute(selected.map { |role| {role, task} })
  end

  # Runs role-specific tasks. Every key must match a configured role name.
  def run(tasks : Hash(String, String)) : Array(Result)
    raise SwarmError.new("no tasks given") if tasks.empty?
    pairs = tasks.map do |name, task|
      role = self[name] || raise SwarmError.new("unknown role: #{name}")
      {role, task}
    end
    execute(pairs)
  end

  private def register_role(role : Role) : Role
    raise SwarmError.new("role name must not be blank") if role.name.blank?
    raise SwarmError.new("duplicate role: #{role.name}") if self[role.name]
    @roles << role
    role
  end

  private def execute(pairs : Array(Tuple(Role, String))) : Array(Result)
    channel = Channel(Tuple(Int32, Result)).new(pairs.size)

    pairs.each_with_index do |(role, task), index|
      spawn do
        channel.send({index, run_task(role, task)})
      end
    end

    results = Array(Result?).new(pairs.size) { nil }
    pairs.size.times do
      index, result = channel.receive
      results[index] = result
      if hook = @on_result
        hook.call result
      end
    end
    results.map(&.not_nil!)
  end

  private def run_task(role : Role, task : String) : Result
    agent = Agent.new(@client, model: role.model, system_prompt: role.system_prompt,
      max_iterations: role.max_iterations, thinking: role.thinking,
      reasoning_effort: role.reasoning_effort)
    if configure = role.configure
      configure.call agent
    end
    Result.new(role, task, output: agent.run(task))
  rescue ex
    Result.new(role, task, error: ex)
  end
end
