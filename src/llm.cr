# src/llm.cr
require "./llm/errors"
require "./llm/types"
require "./llm/tool"
require "./llm/client"
require "./llm/tools/files"
require "./llm/tools/shell"
require "./llm/tools/search"
require "./llm/agent"
require "./llm/swarm"

module LLM
  VERSION = {{ `shards version "#{__DIR__}"`.chomp.stringify }}
end
