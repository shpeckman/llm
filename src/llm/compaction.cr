# src/llm/compaction.cr
module LLM::Compaction
  CHARS_PER_TOKEN   =    4
  MESSAGE_OVERHEAD  =    4
  MEDIA_PART_TOKENS = 1024

  def self.estimate(messages : Array(Message)) : Int32
    messages.sum(0) { |message| estimate(message) }
  end

  def self.estimate(message : Message) : Int32
    chars = message.text.size
    if reasoning = message.reasoning_content
      chars += reasoning.size
    end
    if calls = message.tool_calls
      calls.each do |call|
        chars += call.function.name.size
        chars += call.function.arguments.size
      end
    end
    media = 0
    message.each_part do |part|
      media += 1 unless part.kind.text?
    end
    MESSAGE_OVERHEAD + (chars // CHARS_PER_TOKEN) + media * MEDIA_PART_TOKENS
  end

  def self.budget(context_window : Int32, threshold : Float64) : Int32
    (context_window * threshold).to_i
  end

  # Returns a compacted copy of `messages` whose estimated size fits `budget`.
  # Guarantees (in priority order):
  #   1. A leading system message is always preserved.
  #   2. The trailing "active turn" is always preserved: the last message,
  #      plus — if it is a tool result — all contiguous trailing tool results
  #      and the assistant tool-call message that initiated them.
  #   3. Older messages are dropped from the middle, newest kept first.
  #   4. The result never starts with an orphan `tool` message, nor with an
  #      assistant tool-call message whose results were dropped.
  # Guarantees 1 and 2 hold even if they alone exceed `budget` (documented;
  # callers pick a sane threshold).
  def self.compact(messages : Array(Message), budget : Int32) : Array(Message)
    return messages if estimate(messages) <= budget

    kept = [] of Message
    rest = messages
    if first = messages.first?
      if first.role == "system"
        kept << first
        rest = messages[1..]
      end
    end
    return kept if rest.empty?

    tail_start = rest.size - 1
    while tail_start > 0 && rest[tail_start].role == "tool"
      tail_start -= 1
    end

    used = kept.sum(0) { |message| estimate(message) }
    rest[tail_start..].each { |message| used += estimate(message) }

    index = tail_start
    while index > 0
      cost = estimate(rest[index - 1])
      break if used + cost > budget
      index -= 1
      used += cost
    end

    tail = rest[index..].to_a

    # Boundary repair: drop leading fragments that would produce an invalid
    # wire history.
    while first = tail.first?
      if first.role == "tool"
        tail.shift
      elsif first.role == "assistant" && first.tool_call? &&
            (tail.size < 2 || tail[1].role != "tool")
        tail.shift
      else
        break
      end
    end

    kept.concat(tail)
    kept
  end
end
