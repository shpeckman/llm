require "json"

module LLM
  struct Embedding
    getter index     : Int32
    getter embedding : Array(Float64)

    def initialize(@index : Int32, @embedding : Array(Float64))
    end
  end

  class EmbeddingResponse
    getter model      : String
    getter embeddings : Array(Embedding)
    getter usage      : Usage?

    def initialize(@model : String, @embeddings : Array(Embedding), @usage : Usage? = nil)
    end

    def vectors : Array(Array(Float64))
      @embeddings.map(&.embedding)
    end
  end
end
