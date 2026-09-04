begin
  raise "CodeDB source trace"
rescue => error
  error.backtrace[0]
end
