$strict_load_count = ($strict_load_count || 0) + 1

class StrictBox
  attr_accessor :value
end

class StrictApp
  def self.load_count
    $strict_load_count
  end

  def self.accessors
    box = StrictBox.new
    box.value = 3
    box.value
  end

  def self.run(message)
    time = Effect.perform(Clock.now)
    Effect.perform(Sink.write([time, message]))
  end

  def self.identity
    begin
      Object.new.object_id
    rescue
      "rescued"
    end
  end

  def self.inspect_object
    Object.new.inspect
  end

  def self.proc_hash
    Proc.new { 1 }.hash
  end

  def self.local_mutation
    value = [1]
    value[0] = 2
    value[0]
  end

  def self.direct_native
    begin
      Legacy.bump
    rescue
      "rescued"
    end
  end

  def self.unavailable
    [Object.const_defined?(:Time), Object.const_defined?(:Random), Object.const_defined?(:IO), Object.const_defined?(:Struct)]
  end
end
