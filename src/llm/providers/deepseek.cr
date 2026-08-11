# src/llm/providers/deepseek.cr
module LLM
  class DeepSeekProvider < Provider
    def initialize
      super("deepseek", "https://api.deepseek.com/v1", "deepseek-v4-flash",
        ["DEEPSEEK_API_KEY"], default_thinking: true, default_effort: "high")
    end

    def thinking_style(model : String) : ThinkingStyle
      model.downcase.starts_with?("deepseek-v4") ? ThinkingStyle::ThinkingObject : ThinkingStyle::None
    end

    def preserve_reasoning?(model : String, has_tool_calls : Bool) : Bool
      thinking_style(model).thinking_object? && has_tool_calls
    end
  end
end
