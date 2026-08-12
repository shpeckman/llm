module LLM
  # USD per 1M tokens. All-zero means "unknown" — the shard never fabricates
  # prices; users supply them via Provider.custom capabilities.
  #
  # ```
  # pricing  = LLM::Pricing.new(input: 0.60, output: 2.50, cached_input: 0.10)
  # caps     = LLM::Capabilities.new(pricing: pricing) # plus any other flags
  # provider = LLM::Provider.custom("kimi", "https://api.moonshot.ai/v1", "kimi-k3",
  #   ["MOONSHOT_API_KEY"], caps)
  # ```
  struct Pricing
    getter input        : Float64
    getter output       : Float64
    getter cached_input : Float64

    def initialize(@input : Float64 = 0.0, @output : Float64 = 0.0,
                   @cached_input : Float64 = 0.0)
    end

    UNKNOWN = new

    def known? : Bool
      @input > 0.0 || @output > 0.0 || @cached_input > 0.0
    end
  end
end
