require "json"

module LLM
  struct ResponseFormat
    enum Kind
      Text
      JsonObject
      JsonSchema
    end

    getter kind   : Kind
    getter name   : String?
    getter schema : JSON::Any?
    getter strict : Bool

    # Private: construct via the factory methods below.
    private def initialize(@kind : Kind, @name : String? = nil,
                           @schema : JSON::Any? = nil, @strict : Bool = false)
    end

    def self.text : ResponseFormat
      new(Kind::Text)
    end

    def self.json_object : ResponseFormat
      new(Kind::JsonObject)
    end

    def self.json_schema(name : String, schema : JSON::Any, strict : Bool = true) : ResponseFormat
      new(Kind::JsonSchema, name, schema, strict)
    end

    # Derives a JSON Schema from a `JSON::Serializable` type and returns a
    # json_schema ResponseFormat. `name` defaults to the demodulized,
    # underscored type name.
    macro json_schema_for(type, name = nil, strict = true)
      {% schema_name = name || type.resolve.name.split("::").last.underscore %}
      LLM::ResponseFormat.json_schema(
        {{schema_name}},
        JSON.parse(LLM.schema_json({{type}}).to_json),
        {{strict}})
    end

    def build_json(json : JSON::Builder) : Nil
      json.object do
        case @kind
        in .text?
          json.field "type", "text"
        in .json_object?
          json.field "type", "json_object"
        in .json_schema?
          json.field "type", "json_schema"
          json.field "json_schema" do
            json.object do
              json.field "name", @name
              json.field "schema", @schema
              json.field "strict", @strict
            end
          end
        end
      end
    end
  end

  # Expands to a NamedTuple literal describing the JSON Schema for `type`
  # (which must include JSON::Serializable). Recursive for nested includers
  # and Array(T).
  #
  # Mapping:
  #   String              -> {"type": "string"}
  #   Int32 | Int64       -> {"type": "integer"}
  #   Float64             -> {"type": "number"}
  #   Bool                -> {"type": "boolean"}
  #   Array(T)            -> {"type": "array", "items": schema_json(T)}
  #   T? (nilable)        -> schema_json(T); ivar excluded from "required"
  #   any other type      -> object from its instance_vars (must include
  #                          JSON::Serializable)
  # Unsupported: unions with >1 non-Nil member, other integer/float widths,
  # Hash, Tuple — compile-time {% raise %} with a clear message.
  macro schema_json(type)
    {% resolved = type.resolve %}
    {% if resolved.nilable? %}
      {% non_nil = resolved.union_types.reject { |t| t.nilable? } %}
      {% if non_nil.size != 1 %}
        {% raise "LLM.schema_json: union type #{resolved} is not supported; only T? nilables are allowed" %}
      {% end %}
      LLM.schema_json({{non_nil.first}})
    {% elsif resolved == String %}
      {type: "string"}
    {% elsif resolved == Int32 || resolved == Int64 %}
      {type: "integer"}
    {% elsif resolved == Float64 %}
      {type: "number"}
    {% elsif resolved == Bool %}
      {type: "boolean"}
    {% elsif resolved.name.starts_with?("Array(") %}
      {type: "array", items: LLM.schema_json({{resolved.type_vars.first}})}
    {% elsif resolved == Int8 || resolved == Int16 || resolved == Int128 ||
              resolved == UInt8 || resolved == UInt16 || resolved == UInt32 ||
              resolved == UInt64 || resolved == UInt128 || resolved == Float32 %}
      {% raise "LLM.schema_json: #{resolved} is not supported; use Int32, Int64 or Float64" %}
    {% else %}
      {
        type: "object",
        properties: {
          {% has_props = false %}
          {% for ivar in resolved.instance_vars %}
            {% has_props = true %}
            {{ivar.name.stringify}}: LLM.schema_json({{ivar.type}}),
          {% end %}
        }{% unless has_props %} of String => JSON::Any{% end %},
        required: [
          {% has_required = false %}
          {% for ivar in resolved.instance_vars %}
            {% unless ivar.type.nilable? %}
              {% has_required = true %}
              {{ivar.name.stringify}},
            {% end %}
          {% end %}
        ]{% unless has_required %} of String{% end %},
        additionalProperties: false,
      }
    {% end %}
  end
end
