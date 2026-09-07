begin
  Object.new.object_id
rescue
  $rescued_identity = true
end
