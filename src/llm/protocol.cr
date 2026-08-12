require "http/headers"
require "json"
require "uri"

module LLM
  # Resolved request plan: the model, its capabilities, and the
  # capability-checked option values for a single call.
  struct Plan
    getter model       : String
    getter caps        : Capabilities
    getter thinking    : Bool?
    getter effort      : String?
    getter temperature : Float64?
    getter preserve    : Bool?

    def initialize(@model : String, @caps : Capabilities, @thinking : Bool?,
                   @effort : String?, @temperature : Float64?, @preserve : Bool?)
    end
  end

  # A protocol translates between the shard's types and a provider's wire
  # format: request headers and paths, request bodies, response parsing,
  # and stream-event accumulation. Client owns HTTP, retries and
  # cancellation; protocols own everything that differs per API dialect.
  abstract class Protocol
    abstract def headers(api_key : String) : HTTP::Headers
    abstract def chat_path(uri : URI) : String
    abstract def embeddings_path(uri : URI) : String

    abstract def chat_body(plan : Plan, messages : Array(Message),
                           tools : Array(Tool::Custom)?, options : Options,
                           stream : Bool) : String

    abstract def embed_body(model : String, input : String | Array(String)) : String

    abstract def parse_chat_response(json : JSON::Any) : ChatResponse
    abstract def parse_embedding_response(json : JSON::Any) : EmbeddingResponse

    abstract def accumulator : StreamAccumulator
  end

  # Reassembles a complete ChatResponse from a provider's streamed events.
  # `add` returns a chunk to forward to the caller, or nil for events that
  # carry nothing user-visible (pings, block boundaries, unknown types).
  abstract class StreamAccumulator
    abstract def add(json : JSON::Any) : StreamChunk?
    abstract def response : ChatResponse
  end
end

require "./protocols/*"
