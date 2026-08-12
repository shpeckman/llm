# spec/fixtures.cr
require "json"

module LLM::SpecFixtures
  # A NamedTuple containing all the raw JSON snippets used across the specs.
  # This provides a clean, type-safe mapping without cluttering the test cases.
  ANTHROPIC = {
    weather_schema: %({"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}),

    weather_args: %({"city":"SF"}),

    preserved_blocks: %([
      {"type":"thinking","thinking":"hmm","signature":"sig123"},
      {"type":"tool_use","id":"toolu_1","name":"get_weather","input":{"city":"SF"}}
    ]),

    chat_response: %({
      "content": [
        {"type":"thinking","thinking":"let me check","signature":"sig"},
        {"type":"text","text":"checking weather"},
        {"type":"tool_use","id":"toolu_1","name":"get_weather","input":{"city":"SF"}}
      ],
      "stop_reason": "tool_use",
      "usage": {"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":4}
    }),

    stream_message_start: %({"type":"message_start","message":{"usage":{"input_tokens":12,"output_tokens":1}}}),

    stream_thinking_start: %({"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}),

    stream_thinking_delta: %({"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}),

    stream_signature_delta: %({"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}),

    stream_block_stop_0: %({"type":"content_block_stop","index":0}),

    stream_tool_use_start: %({"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"get_weather","input":{}}}),

    # Writing the exact JSON strings natively avoids compiler confusion with .to_json in NamedTuple literals
    stream_tool_use_delta_1: %({"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"city\\":"}}),

    stream_tool_use_delta_2: %({"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\\"SF\\"}"}}),

    stream_block_stop_1: %({"type":"content_block_stop","index":1}),

    stream_message_delta: %({"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":30}}),

    stream_message_stop: %({"type":"message_stop"}),

    stream_text_start: %({"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}),

    stream_text_delta: %({"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}),

    stream_error: %({"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}),

    stream_ping: %({"type":"ping"}),

    stream_future_event: %({"type":"future_event","data":{}}),
  }
end
