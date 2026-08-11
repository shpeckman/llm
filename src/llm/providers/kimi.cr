# src/llm/providers/kimi.cr
module LLM
  class KimiProvider < Provider
    def initialize
      super("kimi", "https://api.moonshot.ai/v1", "kimi-k3",
        ["KIMI_API_KEY", "MOONSHOT_API_KEY"], default_effort: "max")
    end

    def thinking_style(model : String) : ThinkingStyle
      model.downcase.starts_with?("kimi-k3") ? ThinkingStyle::EffortOnly : ThinkingStyle::None
    end

    def preserve_reasoning?(model : String, has_tool_calls : Bool) : Bool
      thinking_style(model).effort_only?
    end
  end
end
