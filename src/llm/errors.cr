# src/llm/errors.cr
require "http/common"
require "http/headers"
require "json"

module LLM
  class Error < Exception; end

  class ToolError < Error; end

  class SwarmError < Error; end

  class MaxIterationsError < Error; end

  class UnsupportedFeatureError < Error; end

  class APIError < Error
    getter status      : Int32
    getter body        : String
    getter type        : String?
    getter code        : String?
    getter retry_after : Time::Span?

    def initialize(@status : Int32, @body : String, @type : String? = nil,
                   @code : String? = nil, @retry_after : Time::Span? = nil,
                   message : String? = nil)
      super(message || "API error #{@status}: #{@body}")
    end

    def retryable? : Bool
      false
    end

    def self.build(status : Int32, body : String, headers : HTTP::Headers? = nil) : APIError
      type, detail, code = describe(body)
      after = retry_after_from(headers)
      message = String.build do |io|
        io << "API error " << status
        io << " (" << type << ')' if type
        io << ": " << (detail || body)
      end

      case
      when status == 400 && type == "content_filter"
        ContentFilterError.new(status, body, type, code, after, message)
      when status == 400 || status == 422
        InvalidRequestError.new(status, body, type, code, after, message)
      when status == 401
        AuthenticationError.new(status, body, type, code, after, message)
      when status == 402
        InsufficientBalanceError.new(status, body, type, code, after, message)
      when status == 403
        PermissionError.new(status, body, type, code, after, message)
      when status == 404
        NotFoundError.new(status, body, type, code, after, message)
      when status == 429 && type == "exceeded_current_quota_error"
        QuotaError.new(status, body, type, code, after, message)
      when status == 429 && type == "engine_overloaded_error"
        OverloadedError.new(status, body, type, code, after, message)
      when status == 429
        RateLimitError.new(status, body, type, code, after, message)
      when status >= 500
        ServerError.new(status, body, type, code, after, message)
      else
        new(status, body, type, code, after, message)
      end
    end

    private def self.describe(body : String) : Tuple(String?, String?, String?)
      json  = JSON.parse(body)
      error = json["error"]?
      return {nil, nil, nil} if error.nil? || error.raw.nil?
      {
        error["type"]?.try(&.as_s?),
        error["message"]?.try(&.as_s?),
        error["code"]?.try(&.as_s?),
      }
    rescue JSON::ParseException
      {nil, nil, nil}
    end

    private def self.retry_after_from(headers : HTTP::Headers?) : Time::Span?
      return nil if headers.nil?
      raw = headers["Retry-After"]?
      return nil if raw.nil? || raw.empty?
      if seconds = raw.to_i?
        return seconds.seconds if seconds >= 0
      end
      if time = HTTP.parse_time(raw)
        span = time - Time.utc
        return span if span > Time::Span.zero
      end
      nil
    end
  end

  class InvalidRequestError < APIError; end

  class ContentFilterError < APIError; end

  class AuthenticationError < APIError; end

  class InsufficientBalanceError < APIError; end

  class PermissionError < APIError; end

  class NotFoundError < APIError; end

  class QuotaError < APIError; end

  class RateLimitError < APIError
    def retryable? : Bool
      true
    end
  end

  class OverloadedError < APIError
    def retryable? : Bool
      true
    end
  end

  class ServerError < APIError
    def retryable? : Bool
      true
    end
  end
end
