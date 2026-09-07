# Builders return inert requests; only Effect.perform invokes a handler.
def self.announce(message)
  now = Effect.perform(Clock.now)
  receipt = Effect.perform(Outbox.enqueue("announcements", "#{now}: #{message}"))
  [now, receipt]
end

announce("hello from effects")
