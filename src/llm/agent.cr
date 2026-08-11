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
    include_usage:     "Bool",
  }

  getter client           : Client
  getter registry         : Tool::Registry
  getter history          : Array(Message)
  getter options          : Options
  getter usage            : Usage
  property system_prompt  : String
  property max_iterations : Int32

  {% for name, type in DELEGATED_OPTIONS %}
    def {{name.id}} : {{type.id}}
      @options.{{name.id}}
    end

    def {{name.id}}=(value : {{type.id}}) : {{type.id}}
      @options.{{name.id}} = value
    end
  {% end %}

  @on_assistant_message : (Message ->)?
  @on_tool_result       : (ToolCall, String ->)?
  @on_token             : (String ->)?
  @on_reasoning         : (String ->)?

  def initialize(@client : Client,
                 @system_prompt : String = DEFAULT_SYSTEM_PROMPT,
                 @max_iterations : Int32 = DEFAULT_MAX_ITERATIONS,
                 @options : Options = Options.new)
    @registry = Tool::Registry.new
    @history  = [] of Message
    @usage    = Usage.new
  end

  def register(tool : Tool::Custom) : Tool::Custom
    @registry.register(tool)
  end

  def register_workspace_tools(workspace : String = Dir.current) : Nil
    register(ReadFileTool.new(workspace))
    register(WriteFileTool.new(workspace))
    register(EditFileTool.new(workspace))
    register(ShellTool.new(workspace))
    register(GlobTool.new(workspace))
    register(GrepTool.new(workspace))
  end

  def on_assistant_message(&block : Message ->) : Nil
    @on_assistant_message = block
  end

  def on_tool_result(&block : ToolCall, String ->) : Nil
    @on_tool_result = block
  end

  def on_token(&block : String ->) : Nil
    @on_token = block
  end

  def on_reasoning(&block : String ->) : Nil
    @on_reasoning = block
  end

  def run(input : Content) : String
    ensure_system_prompt
    @history << Message.user(input)

    @max_iterations.times do
      response = chat_round
      message  = response.message
      @history << message
      if usage = response.usage
        @usage += usage
      end
      if hook = @on_assistant_message
        hook.call message
      end

      if message.tool_call?
        message.tool_calls.not_nil!.each do |call|
          result = @registry.dispatch(call)
          @history << Message.tool_result(call.id, result)
          if hook = @on_tool_result
            hook.call call, result
          end
        end
      else
        return message.text
      end
    end

    raise MaxIterationsError.new("no final answer after #{@max_iterations} iterations")
  end

  def reset : Nil
    @history.clear
    @usage = Usage.new
  end

  private def ensure_system_prompt : Nil
    @history.unshift(Message.system(@system_prompt)) if @history.empty?
  end

  private def tools_arg : Array(Tool::Custom)?
    @registry.empty? ? nil : @registry.to_a
  end

  private def chat_round : ChatResponse
    if hook = @on_token
      reasoning_hook = @on_reasoning
      @client.chat_stream(@history, tools_arg, @options) do |chunk|
        chunk.reasoning_delta.try { |delta| reasoning_hook.try(&.call(delta)) }
        chunk.content_delta.try { |delta| hook.call delta }
      end
    else
      @client.chat(@history, tools_arg, @options)
    end
  end
end
