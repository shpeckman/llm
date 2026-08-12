require "./llm/errors"
require "./llm/capabilities"
require "./llm/types"
require "./llm/options"
require "./llm/tool"
require "./llm/provider"
require "./llm/client"
require "./llm/tools/workspace"
require "./llm/tools/files"
require "./llm/tools/shell"
require "./llm/tools/search"
require "./llm/mvu"
require "./llm/agent"
require "./llm/swarm"

module LLM
  VERSION = {{ `shards version "#{__DIR__}"`.chomp.stringify }}
end
