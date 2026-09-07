class Counter
  def self.aliases(state, input)
    [state, state]
  end

  def self.reraise_rejection(state, input)
    original = nil
    cleaned = false
    begin
      begin
        Effect.perform(Intent.prepare(input))
      rescue Effect::Rejected => original
        # mruby 4.0.0 requires the explicit object when reraising.
        raise original
      ensure
        cleaned = true
      end
    rescue Exception => caught
      [[caught.equal?(original), caught.code, caught.message, cleaned], state]
    end
  end

  def self.apply(state, input)
    count = state["count"] + input["delta"]
    time = Effect.perform(Clock.now)
    begin
      receipt = Effect.perform(Intent.prepare({"topic" => "counter.updated", "count" => count, "at" => time}))
    rescue Effect::Rejected => rejection
      return [{"status" => "rejected", "code" => rejection.code}, state]
    end
    Effect.perform(Output.write("counter=#{count} at=#{time}"))
    raise "abort after preparation" if input["abort_after_prepare"]
    state["count"] = count
    state["last_at"] = time
    [{"status" => "updated", "count" => count, "receipt" => receipt}, state]
  end
end
