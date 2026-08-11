# src/llm/capabilities.cr
module LLM
  enum ThinkingSupport
    Unsupported
    Optional
    Always
  end

  enum PreservedThinking
    Unsupported
    ToolCalls
    ToolsPresent
    Optional
    Always
  end

  enum SamplingSupport
    Free
    Fixed
    FreeWithoutThinking
  end

  struct Capabilities
    ANY_EFFORT = [] of String

    getter tools                          : Bool
    getter forced_tool_choice             : Bool
    getter forced_tool_choice_with_thinking : Bool
    getter thinking                       : ThinkingSupport
    getter default_thinking               : Bool?
    getter reasoning_effort               : Bool
    getter reasoning_efforts              : Array(String)
    getter default_effort                 : String?
    getter preserved_thinking             : PreservedThinking
    getter sampling                       : SamplingSupport
    getter max_tokens_field               : String
    getter prompt_cache_key               : Bool
    getter user_id                        : Bool
    getter image_input                    : Bool
    getter video_input                    : Bool

    def initialize(*, @tools : Bool = true,
                   @forced_tool_choice : Bool = true,
                   @forced_tool_choice_with_thinking : Bool = true,
                   @thinking : ThinkingSupport = ThinkingSupport::Unsupported,
                   @default_thinking : Bool? = nil,
                   @reasoning_effort : Bool = false,
                   @reasoning_efforts : Array(String) = ANY_EFFORT,
                   @default_effort : String? = nil,
                   @preserved_thinking : PreservedThinking = PreservedThinking::Unsupported,
                   @sampling : SamplingSupport = SamplingSupport::Free,
                   @max_tokens_field : String = "max_tokens",
                   @prompt_cache_key : Bool = false,
                   @user_id : Bool = false,
                   @image_input : Bool = false,
                   @video_input : Bool = false)
    end

    DEFAULT = new

    def thinking_active?(thinking : Bool?) : Bool
      case @thinking
      in .unsupported?
        false
      in .always?
        true
      in .optional?
        resolved = thinking.nil? ? @default_thinking : thinking
        resolved.nil? ? false : resolved
      end
    end

    def sampling_allowed?(thinking : Bool?) : Bool
      case @sampling
      in .free?                  then true
      in .fixed?                 then false
      in .free_without_thinking? then !thinking_active?(thinking)
      end
    end

    def preserve_reasoning?(has_tool_calls : Bool, tools_present : Bool, preserve : Bool?) : Bool
      case @preserved_thinking
      in .unsupported?   then false
      in .always?        then true
      in .tool_calls?    then has_tool_calls
      in .tools_present? then tools_present
      in .optional?      then preserve == true
      end
    end

    def valid_effort?(effort : String) : Bool
      @reasoning_efforts.empty? || @reasoning_efforts.includes?(effort)
    end

    def media_checked? : Bool
      !(@image_input && @video_input)
    end
  end
end
