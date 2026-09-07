class WorkerCounter
  def self.apply(state, input)
    Object.new.object_id if input["mode"] == "native"
    MissingEffects.unregistered if input["mode"] == "unknown_ruby"
    count = state["count"] + input["delta"]
    if input["mode"] == "intent_first"
      Effect.perform(Outbox.prepare([count, 1700000000]))
      observed_at = Effect.perform(Clock.now)
    else
      observed_at = Effect.perform(Clock.now)
      Effect.perform(Outbox.prepare([count, observed_at]))
    end
    raise "failure after staging" if input["mode"] == "raise"
    if input["mode"] == "loop"
      loop do
      end
    end
    contract_failure(count) if input["mode"] == "contract_failure"
    state["count"] = count
    return ["invalid result", state] if input["mode"] == "invalid_result"
    return [count, {"count" => "invalid count"}] if input["mode"] == "invalid_state"
    [count, state]
  end

  def self.contract_failure(count)
    begin
      Effect.perform(Outbox.prepare([count, "invalid clock observation"]))
    rescue
      nil
    end
  end
end
