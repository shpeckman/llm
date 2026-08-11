# src/llm/mvu.cr
module LLM::MVU
  enum Render : UInt8
    EveryEvent
    Settled
  end

  enum Mode : UInt8
    Immediate
    Deferred
  end

  struct SubId
    getter tag  : Symbol
    getter slot : Int32

    def initialize(@tag : Symbol, @slot : Int32 = 0)
    end

    def_equals_and_hash @tag, @slot

    def to_s(io : IO) : Nil
      io << @tag
      io << '#' << @slot unless @slot.zero?
    end
  end

  NO_SUBSCRIPTIONS = [] of SubId

  class Cancel
    getter channel : Channel(Nil)

    def initialize
      @channel = Channel(Nil).new
    end

    def cancelled? : Bool
      @channel.closed?
    end

    def cancel : Nil
      @channel.close unless @channel.closed?
    end

    def wait : Nil
      @channel.receive?
    end

    def on_cancel(&block : ->) : Nil
      channel = @channel
      spawn do
        channel.receive?
        block.call
      end
    end
  end

  class Handle
    getter cancel : Cancel

    property generation : UInt64

    def initialize(@cancel : Cancel, @generation : UInt64)
    end
  end

  struct Task(E)
    getter mode : Mode
    getter run  : Proc(E)

    def initialize(@mode : Mode, @run : Proc(E))
    end
  end

  struct Cmd(E)
    getter tasks : Array(Task(E))?

    def initialize(@tasks : Array(Task(E))? = nil)
    end

    def self.none : Cmd(E)
      new
    end

    def self.now(event : E) : Cmd(E)
      single(Mode::Immediate, -> { event })
    end

    def self.sync(&block : -> E) : Cmd(E)
      single(Mode::Immediate, block)
    end

    def self.of(&block : -> E) : Cmd(E)
      single(Mode::Deferred, block)
    end

    def self.batch(cmds : Array(Cmd(E))) : Cmd(E)
      total = 0
      cmds.each { |cmd| total &+= cmd.size }

      return none if total == 0

      tasks = Array(Task(E)).new(total)
      cmds.each do |cmd|
        cmd.each { |task| tasks << task }
      end

      new(tasks)
    end

    private def self.single(mode : Mode, run : Proc(E)) : Cmd(E)
      tasks = Array(Task(E)).new(1)
      tasks << Task(E).new(mode, run)
      new(tasks)
    end

    def size : Int32
      tasks = @tasks
      tasks.nil? ? 0 : tasks.size
    end

    def empty? : Bool
      size.zero?
    end

    def each(& : Task(E) ->) : Nil
      tasks = @tasks
      return if tasks.nil?
      tasks.each { |task| yield task }
    end
  end

  struct Sub(E)
    getter id   : SubId
    getter task : Proc(Proc(E, Nil), Cancel, Nil)

    def initialize(@id : SubId, &@task : Proc(E, Nil), Cancel ->)
    end
  end

  module Model(M, E, V)
    macro included
      macro finished
        \{% names = @type.methods.map(&.name.stringify) %}
        \{% if names.includes?("subscription_ids") && !names.includes?("subscription") %}
          \{% raise "#{@type} defines `subscription_ids` but not `subscription(id)`. Provide `def subscription(id : MVU::SubId)` returning the sub for each id." %}
        \{% end %}
        \{% if names.includes?("subscription") && !names.includes?("subscription_ids") %}
          \{% raise "#{@type} defines `subscription(id)` but not `subscription_ids`. Provide `def subscription_ids : Array(MVU::SubId)` listing the active ids." %}
        \{% end %}
      end
    end

    abstract def update(event : E) : {M, Cmd(E)}
    abstract def view : V
    abstract def done? : Bool
    abstract def recover(error : Exception) : E

    def subscription_ids : Array(SubId)
      NO_SUBSCRIPTIONS
    end

    def subscription(id : SubId) : Sub(E)
      raise Error.new("#{self.class} has no subscription for #{id}")
    end
  end

  abstract class Middleware(M, E)
    abstract def call(model : M, event : E, next_fn : Proc(M, E, {M, Cmd(E)})) : {M, Cmd(E)}
  end

  class Runtime(M, E, V)
    CAPACITY = 1024

    getter model : M

    @queue      : Channel(E)
    @inbox      : Deque(E)
    @subs       : Hash(SubId, Handle)
    @generation : UInt64
    @inflight   : Atomic(Int32)
    @emit       : Proc(E, Nil)
    @update     : Proc(M, E, {M, Cmd(E)})
    @initial    : Cmd(E)
    @observer   : Proc(V, Nil)?
    @started    : Bool

    def initialize(@model : M, *, initial : Cmd(E) = Cmd(E).none,
                   middlewares : Array(Middleware(M, E)) = [] of Middleware(M, E),
                   @render : Render = Render::EveryEvent,
                   @observer : Proc(V, Nil)? = nil)
      @queue      = Channel(E).new(CAPACITY)
      @inbox      = Deque(E).new
      @subs       = Hash(SubId, Handle).new
      @generation = 0_u64
      @inflight   = Atomic(Int32).new(0)
      @initial    = initial
      @started    = false
      @emit       = ->(event : E) { dispatch(event) }

      chain = ->(model : M, event : E) { model.update(event) }

      middlewares.reverse_each do |middleware|
        next_fn = chain
        current = middleware
        chain   = ->(model : M, event : E) { current.call(model, event, next_fn) }
      end

      @update = chain
    end

    def dispatch(event : E) : Nil
      @queue.send(event)
    rescue Channel::ClosedError
    end

    def stop : Nil
      @queue.close
    end

    def run : Nil
      raise Error.new("runtime has already been started") if @started
      @started = true

      begin
        run_cmd(@initial)
        pump
        reconcile
        notify if @render.settled?

        until @model.done?
          event = poll
          if event.nil?
            break if @queue.closed?
            guard
            event = @queue.receive?
            break if event.nil?
          end

          process(event)
          drain
          reconcile
          notify if @render.settled?
        end
      ensure
        shutdown
      end
    end

    private def poll : E?
      select
      when event = @queue.receive?
        event
      else
        nil
      end
    end

    private def guard : Nil
      return unless @inflight.get.zero? && @subs.empty? && @inbox.empty?
      raise StalledError.new("model is not done but no effects are pending")
    end

    private def drain : Nil
      while event = poll
        process(event)
      end
    end

    private def process(event : E) : Nil
      deliver(event)
      pump
    end

    private def pump : Nil
      while event = @inbox.shift?
        deliver(event)
      end
    end

    private def deliver(event : E) : Nil
      @model, cmd = @update.call(@model, event)

      run_cmd(cmd)
      notify if @render.every_event?
    end

    private def notify : Nil
      observer = @observer
      return if observer.nil?
      observer.call(@model.view)
    end

    private def run_cmd(cmd : Cmd(E)) : Nil
      return if cmd.empty?

      cmd.each do |task|
        run   = task.run
        model = @model

        case task.mode
        in .immediate?
          begin
            @inbox << run.call
          rescue ex
            @inbox << model.recover(ex)
          end
        in .deferred?
          @inflight.add(1)
          spawn do
            event = begin
              run.call
            rescue ex
              model.recover(ex)
            end
            @inflight.sub(1)
            dispatch(event)
          end
        end
      end
    end

    private def reconcile : Nil
      ids = @model.subscription_ids

      return if ids.empty? && @subs.empty?

      generation  = @generation &+ 1
      @generation = generation
      active      = @subs.size
      matched     = 0

      ids.each do |id|
        if handle = @subs[id]?
          matched &+= 1 unless handle.generation == generation
          handle.generation = generation
          next
        end

        sub    = @model.subscription(id)
        cancel = Cancel.new
        task   = sub.task
        emit   = @emit
        model  = @model

        @subs[id] = Handle.new(cancel, generation)

        spawn do
          begin
            task.call(emit, cancel)
          rescue ex
            emit.call(model.recover(ex))
          end
        end
      end

      return if matched == active

      @subs.reject! do |_, handle|
        next false if handle.generation == generation

        handle.cancel.cancel
        true
      end
    end

    private def shutdown : Nil
      @subs.each_value(&.cancel.cancel)
      @subs.clear
      @inbox.clear
      @queue.close
    end
  end
end
