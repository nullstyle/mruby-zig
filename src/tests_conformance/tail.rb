
# mruby-zig harness tail: surface the upstream counters and any killed or
# failed assertions to the Zig test. (No Regexp in mruby core; killed
# blocks carry an "<Class>Error: " prefix and failures a "Fail: " prefix
# from assertion_string.)
problems = $asserts.select { |entry| entry.include?("Error: ") || entry.include?("Fail: ") }
"ok=#{$ok_test},ko=#{$ko_test},kill=#{$kill_test},warn=#{$warning_test},skip=#{$skip_test}|#{problems.join(';;')[0,3000]}"
