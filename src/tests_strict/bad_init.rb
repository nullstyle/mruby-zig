begin
  Effect.perform(Clock.now)
rescue
  $rescued_init = true
end
