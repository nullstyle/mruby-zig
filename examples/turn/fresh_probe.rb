class FreshProbe
  def self.apply(state, input)
    $unexported_turn_count = ($unexported_turn_count || 0) + 1
    [$unexported_turn_count, state]
  end

  def self.observe_clock(state, input)
    [Effect.perform(Clock.now), state]
  end

  def self.native_violation(state, input)
    Effect.perform(Output.write("prepared"))
    begin
      Object.new.object_id
    rescue
      nil
    end
    [nil, state]
  end

  def self.not_a_pair(state, input)
    123
  end

  class DiagnosticError < StandardError
    def to_s
      Effect.perform(Output.write("unexpected diagnostic to_s"))
      "forged message"
    end

    def message
      Effect.perform(Output.write("unexpected diagnostic message"))
      "forged message"
    end

    def backtrace
      Effect.perform(Output.write("unexpected diagnostic backtrace"))
      ["forged.rb:777"]
    end
  end

  def self.ruby_failure(state, input)
    raise DiagnosticError.new("stored failure")
  end

  def self.long_failure(state, input)
    raise "x" * 1024
  end

  def self.forged_backtrace(state, input)
    error = RuntimeError.new("stored failure")
    error.set_backtrace(["forged.rb:777"])
    raise error
  end

  def self.contract_probe(state, input)
    Effect.perform(Output.write("prepared"))
    result = input == "bad_result" ? "wrong" : 7
    next_state = input == "bad_state" ? -1 : state + 1
    [result, next_state]
  end
end
