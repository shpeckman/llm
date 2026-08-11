# src/llm/options.cr
require "json"

module LLM
  struct ToolChoice
    enum Mode
      Auto
      None
      Required
      Function
    end

    getter mode : Mode
    getter name : String?

    def initialize(@mode : Mode, @name : String? = nil)
    end

    def self.auto : ToolChoice
      new(Mode::Auto)
    end

    def self.none : ToolChoice
      new(Mode::None)
    end

    def self.required : ToolChoice
      new(Mode::Required)
    end

    def self.function(name : String) : ToolChoice
      new(Mode::Function, name)
    end

    def build_json(json : JSON::Builder) : Nil
      case @mode
      in .auto?
        json.string("auto")
      in .none?
        json.string("none")
      in .required?
        json.string("required")
      in .function?
        json.object do
          json.field "type", "function"
          json.field "function" do
            json.object { json.field "name", @name }
          end
        end
      end
    end
  end

  struct RetryPolicy
    getter max_attempts : Int32
    getter base_delay   : Time::Span
    getter max_delay    : Time::Span
    getter jitter       : Float64

    def initialize(@max_attempts : Int32 = 3,
                   @base_delay : Time::Span = 500.milliseconds,
                   @max_delay : Time::Span = 30.seconds,
                   @jitter : Float64 = 0.25)
    end

    def self.none : RetryPolicy
      new(max_attempts: 1)
    end

    def delay_for(attempt : Int32, retry_after : Time::Span?) : Time::Span
      return retry_after if retry_after
      shift   = attempt - 1
      shift   = 16 if shift > 16
      backoff = @base_delay * (1 << shift)
      backoff = @max_delay if backoff > @max_delay
      backoff + backoff * (@jitter * Random.rand)
    end
  end

  class Options
    property model            : String?
    property temperature      : Float64?
    property max_tokens       : Int32?
    property thinking         : Bool?
    property preserve_thinking : Bool?
    property reasoning_effort : String?
    property tool_choice      : ToolChoice?
    property prompt_cache_key : String?
    property include_usage    : Bool

    def initialize(@model : String? = nil, @temperature : Float64? = nil,
                   @max_tokens : Int32? = nil, @thinking : Bool? = nil,
                   @preserve_thinking : Bool? = nil, @reasoning_effort : String? = nil,
                   @tool_choice : ToolChoice? = nil, @prompt_cache_key : String? = nil,
                   @include_usage : Bool = false)
    end
  end
end
