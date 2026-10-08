# Build-time prelude for the mruby upstream test suite (see
# src/tests_conformance/README.md). These definitions match the drivers
# upstream's rake harness provides before loading test/assert.rb.
GEMNAME = 'mruby-test'

# The CRuby branch of assert.rb defines this; under mruby the mrbtest
# driver does. Keep output silent: the Zig harness reads the counters.
def t_print(*args)
  nil
end

# driver.c defines Mrbtest::FLOAT_TOLERANCE (1e-10 for binary64 Float,
# which is this build's pinned float configuration) and the _str_match?
# helper; the suite's assert helpers reference both.
module Mrbtest
  FLOAT_TOLERANCE = 1e-10
end

# The suite's only assert_match pattern is "#<Module:0x*>", so a plain
# *-glob suffices (upstream's driver implements a full fnmatch).
def _str_match?(pattern, str)
  # mruby's String#[] yields 1-character strings, so compare slices.
  return true if pattern == str
  return false if pattern.empty?
  return true if pattern == "*"
  head = pattern[0, 1]
  if head == "*"
    rest = pattern[1..-1]
    (0..str.size).each do |i|
      return true if _str_match?(rest, str[i..-1])
    end
    false
  else
    !str.empty? && head == str[0, 1] && _str_match?(pattern[1..-1], str[1..-1])
  end
end
