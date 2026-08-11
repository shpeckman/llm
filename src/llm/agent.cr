# src/llm/agent.cr
class LLM::Agent
  DEFAULT_SYSTEM_PROMPT  = "You are a helpful coding assistant. You help the user with software engineering tasks: reading, writing, and editing files, running shell commands, and searching the codebase. Use the available tools to inspect the workspace before making changes, prefer small precise edits, keep your answers concise, and explain what you did."
  DEFAULT_MAX_ITERATIONS = 50

  DELEGATED_OPTIONS = {
    model:             "String?",
    temperature:       "Float64?",
    max_tokens:        "Int32?",
    thinking:          "Bool?",
    preserve_thinking: "Bool?",
    reasoning_effort:  "String?",
    tool_choice:       "ToolChoice?",
    prompt_cache_key:  "String?",
    user_id:           "String?",
    include_usage:     "Bool",
  }

  enum Phase : UInt8
    Idle
    Requesting
    Executing
    Done
    Failed
    Cancelled

    def terminal? : Bool
      done? || failed? || cancelled?
    end
  end

  struct ContentDelta
    getter text : String

    def initialize(@text : String)
    end
  end

  struct ReasoningDelta
    getter text : String

    def initialize(@text : String)
    end
  end

  struct Completed
    getter response : ChatResponse

    def initialize(@response : ChatResponse)
    end
  end

  struct ToolCompleted
    getter call   : ToolCall
    getter output : String

    def initialize(@call : ToolCall, @output : String)
    end
  end

  struct Failed
    getter error : Exception

    def initialize(@error : Exception)
    end
  end

  struct Cancelled
  end

  alias Event = ContentDelta | ReasoningDelta | Completed | ToolCompleted | Failed | Cancelled
  alias Cmd = MVU::Cmd(Event)
  alias Sub = MVU::Sub(Event)
  alias Emit = Proc(Event, Nil)

  struct Snapshot
    getter phase     : Phase
    getter iteration : Int32
    getter usage     : Usage
    getter content   : String?
    getter reasoning : String?
    getter tool      : ToolCall?
    getter output    : String?
    getter answer    : String?
    getter error     : Exception?

    def initialize(@phase : Phase, @iteration : Int32, @usage : Usage,
                   @content : String?, @reasoning : String?, @tool : ToolCall?,
                   @output : String?, @answer : String?, @error : Exception?)
    end
  end

  class State
    include MVU::Model(State, Event, Snapshot)

    getter client           : Client
    getter registry         : Tool::Registry
    getter options          : Options
    getter history          : Array(Message)
    getter usage            : Usage
    getter phase            : Phase
    getter iteration        : Int32
    getter answer           : String?
    getter error            : Exception?
    property system_prompt  : String
    property max_iterations : Int32
    property streaming      : Bool

    @calls      : Array(ToolCall)
    @cursor     : Int32
    @generation : Int32
    @ids        : Array(MVU::SubId)
    @content    : String?
    @reasoning  : String?
    @tool       : ToolCall?
    @output     : String?

    def initialize(@client : Client, @system_prompt : String, @max_iterations : Int32,
                   @options : Options, @streaming : Bool)
      @registry   = Tool::Registry.new
      @history    = [] of Message
      @usage      = Usage.new
      @phase      = Phase::Idle
      @iteration  = 0
      @generation = 0
      @calls      = [] of ToolCall
      @cursor     = 0
      @ids        = Array(MVU::SubId).new(1)
      @ids << MVU::SubId.new(:request, 0)
    end

    def begin_turn(input : Content) : Nil
      @history.unshift(Message.system(@system_prompt)) if @history.empty?
      @history << Message.user(input)
      @answer    = nil
      @error     = nil
      @iteration = 0
      @cursor    = 0
      @calls     = [] of ToolCall
      request
    end

    def reset : Nil
      @history.clear
      @usage     = Usage.new
      @phase     = Phase::Idle
      @iteration = 0
      @cursor    = 0
      @calls     = [] of ToolCall
      @answer    = nil
      @error     = nil
    end

    def update(event : Event) : {State, Cmd}
      @content   = nil
      @reasoning = nil
      @tool      = nil
      @output    = nil

      case event
      in ContentDelta
        @content = event.text
        {self, Cmd.none}
      in ReasoningDelta
        @reasoning = event.text
        {self, Cmd.none}
      in Completed
        completed(event.response)
      in ToolCompleted
        @tool   = event.call
        @output = event.output
        executed(event)
      in Failed
        @error = event.error
        @phase = Phase::Failed
        {self, Cmd.none}
      in Cancelled
        @phase = Phase::Cancelled
        {self, Cmd.none}
      end
    end

    def view : Snapshot
      Snapshot.new(@phase, @iteration, @usage, @content, @reasoning, @tool,
        @output, @answer, @error)
    end

    def done? : Bool
      @phase.terminal?
    end

    def recover(error : Exception) : Event
      Failed.new(error)
    end

    def subscription_ids : Array(MVU::SubId)
      @phase.requesting? ? @ids : MVU::NO_SUBSCRIPTIONS
    end

    def subscription(id : MVU::SubId) : Sub
      Sub.new(id) { |emit, cancel| request_turn(emit, cancel) }
    end

    private def completed(response : ChatResponse) : {State, Cmd}
      message = response.message
      @history << message
      if usage = response.usage
        @usage += usage
      end

      unless message.tool_call?
        @answer = message.text
        @phase  = Phase::Done
        return {self, Cmd.none}
      end

      @calls  = message.tool_calls.not_nil!
      @cursor = 0
      @phase  = Phase::Executing
      {self, invoke(@calls[0])}
    end

    private def executed(event : ToolCompleted) : {State, Cmd}
      @history << Message.tool_result(event.call.id, event.output)
      @cursor += 1

      return {self, invoke(@calls[@cursor])} if @cursor < @calls.size

      if @iteration >= @max_iterations
        @error = MaxIterationsError.new("no final answer after #{@max_iterations} iterations")
        @phase = Phase::Failed
        return {self, Cmd.none}
      end

      request
      {self, Cmd.none}
    end

    private def invoke(call : ToolCall) : Cmd
      registry = @registry
      Cmd.of { ToolCompleted.new(call, registry.dispatch(call)).as(Event) }
    end

    private def request : Nil
      @iteration += 1
      @generation += 1
      @ids[0] = MVU::SubId.new(:request, @generation)
      @phase = Phase::Requesting
    end

    private def request_turn(emit : Emit, cancel : MVU::Cancel) : Nil
      tools   = @registry.empty? ? nil : @registry.to_a
      channel = cancel.channel

      response =
        if @streaming
          @client.chat_stream(@history, tools, @options, channel) do |chunk|
            if text = chunk.reasoning_delta
              emit.call(ReasoningDelta.new(text))
            end
            if text = chunk.content_delta
              emit.call(ContentDelta.new(text))
            end
          end
        else
          @client.chat(@history, tools, @options, channel)
        end

      emit.call(Completed.new(response))
    rescue ex
      emit.call(Failed.new(ex))
    end
  end

  getter state : State

  property render : MVU::Render

  @middlewares : Array(MVU::Middleware(State, Event))
  @runtime     : MVU::Runtime(State, Event, Snapshot)?
  @on_view     : Proc(Snapshot, Nil)?

  delegate client, registry, history, usage, phase, answer, error, options, to: @state
  delegate system_prompt, :system_prompt=, to: @state
  delegate max_iterations, :max_iterations=, to: @state
  delegate streaming, :streaming=, to: @state

  {% for name, type in DELEGATED_OPTIONS %}
    def {{name.id}} : {{type.id}}
      @state.options.{{name.id}}
    end

    def {{name.id}}=(value : {{type.id}}) : {{type.id}}
      @state.options.{{name.id}} = value
    end
  {% end %}

  def initialize(client : Client,
                 system_prompt : String = DEFAULT_SYSTEM_PROMPT,
                 max_iterations : Int32 = DEFAULT_MAX_ITERATIONS,
                 options : Options = Options.new,
                 streaming : Bool = false,
                 @render : MVU::Render = MVU::Render::EveryEvent)
    @state       = State.new(client, system_prompt, max_iterations, options, streaming)
    @middlewares = [] of MVU::Middleware(State, Event)
  end

  def register(tool : Tool::Custom) : Tool::Custom
    @state.registry.register(tool)
  end

  def register_workspace_tools(workspace : String = Dir.current) : Nil
    register(ReadFileTool.new(workspace))
    register(WriteFileTool.new(workspace))
    register(EditFileTool.new(workspace))
    register(ShellTool.new(workspace))
    register(GlobTool.new(workspace))
    register(GrepTool.new(workspace))
  end

  def use(middleware : MVU::Middleware(State, Event)) : Nil
    @middlewares << middleware
  end

  def on_view(&block : Snapshot ->) : Nil
    @on_view = block
  end

  def running? : Bool
    !@runtime.nil?
  end

  def cancel : Nil
    @runtime.try(&.dispatch(Cancelled.new))
  end

  def reset : Nil
    @state.reset
  end

  def run(input : Content) : String
    raise Error.new("agent is already running") if running?

    @state.begin_turn(input)

    runtime = MVU::Runtime(State, Event, Snapshot).new(@state,
      middlewares: @middlewares, render: @render, observer: @on_view)
    @runtime = runtime

    begin
      runtime.run
    ensure
      @runtime = nil
    end

    case @state.phase
    when .cancelled?
      raise CancelledError.new("agent run was cancelled")
    when .failed?
      raise @state.error || Error.new("agent run failed without an error")
    end

    @state.answer || ""
  end
end
