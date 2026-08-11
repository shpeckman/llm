# src/llm/provider.cr
class LLM::Provider
  alias ModelTable = Array(Tuple(String, Capabilities))

  EMPTY_TABLE = ModelTable.new

  getter name          : String
  getter base_url      : String
  getter default_model : String
  @api_key_env         : Array(String)
  @fallback            : Capabilities
  @models              : ModelTable

  def api_key_env : Array(String)
    @api_key_env.dup
  end

  def initialize(@name : String, @base_url : String, @default_model : String,
                 api_key_env : Array(String),
                 fallback : Capabilities = Capabilities::DEFAULT,
                 models : ModelTable = EMPTY_TABLE)
    @base_url    = @base_url.rstrip('/')
    @api_key_env = api_key_env.dup
    @fallback    = fallback
    @models      = models
  end

  def self.kimi : Provider
    KimiProvider.new
  end

  def self.deepseek : Provider
    DeepSeekProvider.new
  end

  def self.custom(name : String, base_url : String, default_model : String,
                  api_key_env : Array(String),
                  fallback : Capabilities = Capabilities::DEFAULT,
                  models : ModelTable = EMPTY_TABLE) : Provider
    new(name, base_url, default_model, api_key_env, fallback, models)
  end

  def self.for_name(name : String) : Provider?
    case name.downcase
    when "kimi", "moonshot" then kimi
    when "deepseek"         then deepseek
    end
  end

  def capabilities(model : String) : Capabilities
    key = model.downcase
    @models.each do |entry|
      return entry[1] if key.starts_with?(entry[0])
    end
    @fallback
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
