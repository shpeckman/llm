# examples/provider_spec.cr
require "./spec_helper"

describe LLM::Provider do
  describe "factories" do
    it "builds the openai provider" do
      provider = LLM::Provider.openai
      provider.name.should eq "openai"
      provider.base_url.should eq "https://api.openai.com/v1"
      provider.default_model.should eq "gpt-5.5"
      provider.default_embedding_model.should eq "text-embedding-3-small"
      provider.api_key_env.should eq ["OPENAI_API_KEY"]
    end

    it "builds compatible-endpoint providers" do
      LLM::Provider.openrouter.base_url.should eq "https://openrouter.ai/api/v1"
      LLM::Provider.groq.base_url.should eq "https://api.groq.com/openai/v1"
      LLM::Provider.ollama.base_url.should eq "http://localhost:11434/v1"
    end
  end

  describe ".for_name" do
    it "resolves known names and aliases" do
      LLM::Provider.for_name("kimi").not_nil!.name.should eq "kimi"
      LLM::Provider.for_name("deepseek").not_nil!.name.should eq "deepseek"
      LLM::Provider.for_name("openai").not_nil!.name.should eq "openai"
      LLM::Provider.for_name("GPT").not_nil!.name.should eq "openai"
      LLM::Provider.for_name("openrouter").not_nil!.name.should eq "openrouter"
      LLM::Provider.for_name("groq").not_nil!.name.should eq "groq"
      LLM::Provider.for_name("ollama").not_nil!.name.should eq "ollama"
    end

    it "returns nil for unknown names" do
      LLM::Provider.for_name("bogus").should be_nil
    end
  end

  describe "#capabilities with the openai model table" do
    it "matches longer prefixes before shorter ones" do
      provider = LLM::Provider.openai
      provider.capabilities("gpt-5.1-codex-mini").pricing.input.should eq 0.25
      provider.capabilities("gpt-5.1-codex-max").pricing.input.should eq 1.25
      provider.capabilities("gpt-5.1-codex").pricing.input.should eq 1.25
    end

    it "matches variant suffixes" do
      caps = LLM::Provider.openai.capabilities("gpt-5.6-luna-pro")
      caps.pricing.input.should eq 0.10
      caps.context_window.should eq 1_050_000
    end

    it "treats gpt-5 reasoning models as always-thinking, fixed sampling" do
      caps = LLM::Provider.openai.capabilities("gpt-5.5")
      caps.thinking.should eq LLM::ThinkingSupport::Always
      caps.sampling.should eq LLM::SamplingSupport::Fixed
      caps.max_tokens_field.should eq "max_completion_tokens"
      caps.default_effort.should eq "medium"
      caps.valid_effort?("xhigh").should be_true
    end

    it "treats chat models as free-sampling without thinking" do
      caps = LLM::Provider.openai.capabilities("gpt-5.2-chat")
      caps.thinking.should eq LLM::ThinkingSupport::Unsupported
      caps.sampling.should eq LLM::SamplingSupport::Free
    end

    it "enables embeddings on text-embedding models only" do
      provider = LLM::Provider.openai
      provider.capabilities("text-embedding-3-large").embeddings.should be_true
      provider.capabilities("gpt-5.5").embeddings.should be_false
    end
  end

  describe "#resolve_api_key" do
    it "prefers an explicit key" do
      LLM::Provider.openai.resolve_api_key("sk-test").should eq "sk-test"
    end

    it "ignores a blank explicit key" do
      LLM::Provider.openai.resolve_api_key("").should_not eq ""
    end

    it "falls back to the provider default key when no env is set" do
      if ENV["OLLAMA_API_KEY"]?.nil? && ENV["LLM_API_KEY"]?.nil?
        LLM::Provider.ollama.resolve_api_key.should eq "ollama"
      end
    end
  end
end
