# src/llm/swarm.cr
class LLM::Swarm
  alias AgentConfigurator = Agent ->

  class Blackboard
    @store : Hash(String, String)
    @mutex : Mutex

    def initialize
      @store = {} of String => String
      @mutex = Mutex.new
    end

    def get(key : String) : String?
      @mutex.synchronize { @store[key]? }
    end

    def set(key : String, value : String) : Nil
      @mutex.synchronize { @store[key] = value }
    end

    def keys : Array(String)
      @mutex.synchronize { @store.keys }
    end

    def clear : Nil
      @mutex.synchronize { @store.clear }
    end
  end

  class ReadBlackboardTool < Tool::Custom
    def initialize(@blackboard : Blackboard)
    end
    
    def name : String
      "read_blackboard"
    end

    def description : String
      "Read a string value from the shared swarm blackboard."
    end

    def parameters_schema : JSON::Any
      JSON.parse(%({
        "type": "object",
        "properties": {
          "key": {
            "type": "string",
            "description": "The key to read."
          }
        },
        "required": ["key"],
        "additionalProperties": false
      }))
    end

    def execute(arguments : JSON::Any) : String
      key = arguments["key"]?.try(&.as_s?)
      return "Error: missing or invalid 'key'" unless key

      if value = @blackboard.get(key)
        value
      else
        "Error: key '#{key}' not found on the blackboard."
      end
    end
  end

  class WriteBlackboardTool < Tool::Custom
    def initialize(@blackboard : Blackboard)
    end

    def name : String
      "write_blackboard"
    end

    def description : String
      "Write a string value to the shared swarm blackboard. Useful for sharing data between agents."
    end

    def parameters_schema : JSON::Any
      JSON.parse(%({
        "type": "object",
        "properties": {
          "key": {
            "type": "string",
            "description": "The key to write to."
          },
          "value": {
            "type": "string",
            "description": "The content to store."
          }
        },
        "required": ["key", "value"],
        "additionalProperties": false
      }))
    end

    def execute(arguments : JSON::Any) : String
      key = arguments["key"]?.try(&.as_s?)
      value = arguments["value"]?.try(&.as_s?)
      return "Error: missing or invalid 'key' or 'value'" unless key && value

      @blackboard.set(key, value)
      "Success: stored #{value.bytesize} bytes at '#{key}'."
    end
  end

  class HandoffTool < Tool::Custom
    getter target_role : String

    def initialize(@target_role : String)
    end

    def name : String
      "transfer_to_#{@target_role}"
    end

    def description : String
      "Transfer control of the conversation to the #{@target_role} role."
    end

    def parameters_schema : JSON::Any
      JSON.parse(%({"type":"object","properties":{},"required":[],"additionalProperties":false}))
    end

    def execute(arguments : JSON::Any) : String
      raise HandoffSignal.new(@target_role)
    end
  end

  class Role
    getter name           : String
    getter system_prompt  : String
    getter max_iterations : Int32
    getter options        : Options
    getter streaming      : Bool
    getter handoffs       : Array(String)
    getter configure      : AgentConfigurator?

    def initialize(@name : String,
                   @system_prompt : String = Agent::DEFAULT_SYSTEM_PROMPT,
                   @max_iterations : Int32 = Agent::DEFAULT_MAX_ITERATIONS,
                   @options : Options = Options.new,
                   @streaming : Bool = false,
                   @handoffs : Array(String) = [] of String,
                   @configure : AgentConfigurator? = nil)
    end
  end

  class Result
    getter role   : Role
    getter task   : String
    getter output : String?
    getter usage  : Usage
    getter error  : Exception?
    getter cost   : Float64

    def initialize(@role : Role, @task : String,
                   @output : String? = nil,
                   @usage : Usage = Usage.new,
                   @error : Exception? = nil,
                   @cost : Float64 = 0.0)
    end

    def success? : Bool
      @error.nil?
    end

    def output! : String
      if error = @error
        raise error
      end
      @output || ""
    end
  end

  class SequenceResult
    getter task       : String
    getter final_role : Role
    getter output     : String
    getter history    : Array(Message)
    getter usage      : Usage
    getter cost       : Float64

    def initialize(@task : String, @final_role : Role, @output : String,
                   @history : Array(Message), @usage : Usage, @cost : Float64)
    end
  end

  struct RoleFinished
    getter slot   : Int32
    getter output : String
    getter usage  : Usage
    getter cost   : Float64

    def initialize(@slot : Int32, @output : String, @usage : Usage,
                   @cost : Float64 = 0.0)
    end
  end

  struct RoleFailed
    getter slot  : Int32
    getter error : Exception
    getter usage : Usage
    getter cost  : Float64

    def initialize(@slot : Int32, @error : Exception, @usage : Usage,
                   @cost : Float64 = 0.0)
    end
  end

  struct Crashed
    getter error : Exception

    def initialize(@error : Exception)
    end
  end

  struct Cancelled
  end

  alias Event = RoleFinished | RoleFailed | Crashed | Cancelled
  alias Cmd = MVU::Cmd(Event)
  alias Sub = MVU::Sub(Event)
  alias Emit = Proc(Event, Nil)

  struct Report
    getter results   : Array(Result?)
    getter finished  : Result?
    getter remaining : Int32
    getter cancelled : Bool
    getter error     : Exception?

    def initialize(@results : Array(Result?), @finished : Result?,
                   @remaining : Int32, @cancelled : Bool, @error : Exception?)
    end

    # Total cost in USD across all settled results. Results with unknown
    # pricing contribute 0.0.
    def cost : Float64
      @results.sum(0.0) { |result| result.try(&.cost) || 0.0 }
    end
  end

  class State
    include MVU::Model(State, Event, Report)

    getter results   : Array(Result?)
    getter remaining : Int32
    getter cancelled : Bool
    getter error     : Exception?
    
    property build_hook : (Role -> Agent)?

    @client   : Client
    @pairs    : Array(Tuple(Role, String))
    @ids      : Array(MVU::SubId)
    @finished : Result?

    def initialize(@client : Client)
      @pairs     = [] of Tuple(Role, String)
      @results   = [] of Result?
      @ids       = [] of MVU::SubId
      @remaining = 0
      @cancelled = false
      @finished  = nil
      @error     = nil
    end

    def begin_run(pairs : Array(Tuple(Role, String))) : Nil
      @pairs     = pairs
      @results   = Array(Result?).new(pairs.size) { nil }
      @ids       = Array(MVU::SubId).new(pairs.size)
      @remaining = pairs.size
      @cancelled = false
      @finished  = nil
      @error     = nil
      pairs.each_index { |index| @ids << MVU::SubId.new(:role, index) }
    end

    def update(event : Event) : {State, Cmd}
      @finished = nil

      case event
      in RoleFinished
        role, task = @pairs[event.slot]
        settle(event.slot, Result.new(role, task, output: event.output, usage: event.usage, cost: event.cost))
      in RoleFailed
        role, task = @pairs[event.slot]
        settle(event.slot, Result.new(role, task, usage: event.usage, cost: event.cost, error: event.error))
      in Crashed
        @error = event.error
        @ids.clear
        @remaining = 0
      in Cancelled
        @cancelled = true
        @ids.clear
      end

      {self, Cmd.none}
    end

    def view : Report
      Report.new(@results, @finished, @remaining, @cancelled, @error)
    end

    def done? : Bool
      @cancelled || @remaining.zero? || !@error.nil?
    end

    def recover(error : Exception) : Event
      Crashed.new(error)
    end

    def subscription_ids : Array(MVU::SubId)
      @ids
    end

    def subscription(id : MVU::SubId) : Sub
      slot = id.slot
      role, task = @pairs[slot]

      Sub.new(id) { |emit, cancel| run_role(slot, role, task, emit, cancel) }
    end

    private def settle(slot : Int32, result : Result) : Nil
      @results[slot] = result
      @finished = result
      @remaining -= 1
      @ids.reject! { |id| id.slot == slot }
    end

    private def run_role(slot : Int32, role : Role, task : String,
                         emit : Emit, cancel : MVU::Cancel) : Nil
      agent = @build_hook.not_nil!.call(role)
      cancel.on_cancel { agent.cancel }

      begin
        output = agent.run(task)
        emit.call(RoleFinished.new(slot, output, agent.usage, agent.cost))
      rescue ex
        emit.call(RoleFailed.new(slot, ex, agent.usage, agent.cost))
      end
    end
  end

  getter roles      : Array(Role)
  getter blackboard : Blackboard

  property render : MVU::Render

  @middlewares : Array(MVU::Middleware(State, Event))
  @runtime     : MVU::Runtime(State, Event, Report)?
  @on_view     : Proc(Report, Nil)?
  @on_handoff  : Proc(String, String, Nil)?

  def initialize(@client : Client, @render : MVU::Render = MVU::Render::EveryEvent)
    @roles       = [] of Role
    @blackboard  = Blackboard.new
    @state       = State.new(@client)
    @state.build_hook = ->(r : Role) { build(r) }
    @middlewares = [] of MVU::Middleware(State, Event)
  end

  def add_role(name : String,
               system_prompt : String = Agent::DEFAULT_SYSTEM_PROMPT,
               max_iterations : Int32 = Agent::DEFAULT_MAX_ITERATIONS,
               options : Options = Options.new,
               streaming : Bool = false,
               handoffs : Array(String) = [] of String,
               configure : AgentConfigurator? = nil) : Role
    register_role(Role.new(name, system_prompt, max_iterations, options, streaming, handoffs, configure))
  end

  def add_role(name : String,
               system_prompt : String = Agent::DEFAULT_SYSTEM_PROMPT,
               max_iterations : Int32 = Agent::DEFAULT_MAX_ITERATIONS,
               options : Options = Options.new,
               streaming : Bool = false,
               handoffs : Array(String) = [] of String,
               &configure : Agent ->) : Role
    add_role(name, system_prompt, max_iterations, options, streaming, handoffs, configure)
  end

  def [](name : String) : Role?
    @roles.find { |role| role.name == name }
  end

  def use(middleware : MVU::Middleware(State, Event)) : Nil
    @middlewares << middleware
  end

  def on_view(&block : Report ->) : Nil
    @on_view = block
  end

  def on_handoff(&block : String, String ->) : Nil
    @on_handoff = block
  end

  def running? : Bool
    !@runtime.nil?
  end

  def cancel : Nil
    @runtime.try(&.dispatch(Cancelled.new))
  end

  def run_sequence(task : String, starting_role : String) : SequenceResult
    raise SwarmError.new("swarm is already running") if running?

    history = [] of Message
    usage = Usage.new
    cost = 0.0
    current_role_name = starting_role
    output = ""

    loop do
      role = self[current_role_name] || raise SwarmError.new("unknown role: #{current_role_name}")
      
      agent = build(role)
      agent.history = history

      input = history.empty? ? task : nil

      output = agent.run(input)

      history = agent.history
      usage += agent.usage
      cost += agent.cost

      if agent.state.phase.handoff?
        next_role = agent.state.target_role.not_nil!
        @on_handoff.try(&.call(current_role_name, next_role))
        current_role_name = next_role
      else
        return SequenceResult.new(task, role, output, history, usage, cost)
      end
    end
  end

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

  private def build(role : Role) : Agent
    agent = Agent.new(@client,
      system_prompt: role.system_prompt,
      max_iterations: role.max_iterations,
      options: role.options.dup,
      streaming: role.streaming)
    
    agent.register(ReadBlackboardTool.new(@blackboard))
    agent.register(WriteBlackboardTool.new(@blackboard))

    role.handoffs.each do |target|
      agent.register(HandoffTool.new(target))
    end

    if configure = role.configure
      configure.call agent
    end
    agent
  end

  private def execute(pairs : Array(Tuple(Role, String))) : Array(Result)
    raise SwarmError.new("swarm is already running") if running?

    @state.begin_run(pairs)

    runtime = MVU::Runtime(State, Event, Report).new(@state,
      middlewares: @middlewares, render: @render, observer: @on_view)
    @runtime = runtime

    begin
      runtime.run
    ensure
      @runtime = nil
    end

    if error = @state.error
      raise error
    end

    @state.results.compact
  end
end