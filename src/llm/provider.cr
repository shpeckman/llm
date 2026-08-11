# src/llm/provider.cr
class LLM::Provider
  enum ThinkingStyle
    None
    ThinkingObject
    EffortOnly
  end

  getter name             : String
  getter base_url         : String
  getter default_model    : String
  getter default_thinking : Bool?
  getter default_effort   : String?
  @api_key_env            : Array(String)

  def api_key_env : Array(String)
    @api_key_env.dup
  end

  def initialize(@name : String, @base_url : String, @default_model : String,
                 api_key_env : Array(String), @default_thinking : Bool? = nil,
                 @default_effort : String? = nil)
    @base_url    = @base_url.rstrip('/')
    @api_key_env = api_key_env.dup
  end

  def self.kimi : Provider
    KimiProvider.new
  end

  def self.deepseek : Provider
    DeepSeekProvider.new
  end

  def self.custom(name : String, base_url : String, default_model : String,
                  api_key_env : Array(String), thinking : Bool? = nil,
                  effort : String? = nil) : Provider
    new(name, base_url, default_model, api_key_env, thinking, effort)
  end

  def self.for_name(name : String) : Provider?
    case name.downcase
    when "kimi", "moonshot" then kimi
    when "deepseek"         then deepseek
    end
  end

  def supports_tools?(model : String) : Bool
    true
  end

  def thinking_style(model : String) : ThinkingStyle
    ThinkingStyle::None
  end

  def supports_reasoning_effort?(model : String) : Bool
    thinking_style(model).effort_only? || thinking_style(model).thinking_object?
  end

  def thinking_active?(model : String, thinking : Bool?) : Bool
    case thinking_style(model)
    when .none?
      false
    when .effort_only?
      true
    else
      resolved = thinking.nil? ? @default_thinking : thinking
      resolved.nil? ? false : resolved
    end
  end

  def supports_sampling_params?(model : String, thinking : Bool?) : Bool
    !thinking_active?(model, thinking)
  end

  def preserve_reasoning?(model : String, has_tool_calls : Bool) : Bool
    false
  end

  def resolve_api_key(explicit : String? = nil, env : ENV.class = ENV) : String?
    return explicit unless explicit.nil? || explicit.empty?
    @api_key_env.each do |key|
      value = env[key]?
      return value if value && !value.empty?
    end
    generic = env["LLM_API_KEY"]?
    generic unless generic.nil? || generic.empty?
  end
end

require "./providers/*"
