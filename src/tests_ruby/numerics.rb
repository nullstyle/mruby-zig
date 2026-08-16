# Numerics: integer edges (including beyond the inline fixnum range, which
# exercises heap-allocated RInteger through the shim), floats, and Math.

def assert(cond, msg = "assertion failed")
  raise msg unless cond
end

assert(1 + 2 == 3, "addition")
assert(2 ** 10 == 1024, "pow small")
assert(10.divmod(3) == [3, 1], "divmod")
assert(7 % 3 == 1, "modulo")
assert(-7 / 2 == -4, "floor division")
assert(3.0 / 2 == 1.5, "float division")
assert((1 << 62).to_s == "4611686018427387904", "shift beyond inline fixnum")

# Integer literals beyond the int32 pool range are pooled as BIGINT and
# raise RangeError at load time unless the mruby-bigint gem is enabled
# (deliberately not part of this gem set); computed values are fine.
assert(2147483647 == (2 ** 31) - 1, "max int32 literal")
begin
  eval("2147483648")
  raise "expected literal RangeError"
rescue RangeError
end
big = 1 << 62
assert((big - 1).to_s == "4611686018427387903", "heap integer arithmetic")
begin
  big + big
  raise "expected overflow"
rescue RangeError
end
assert(true, "i64 overflow raises")

# floats
assert(0.1 + 0.2 - 0.3 < 1e-9, "float precision")
assert(1.0.round == 1, "round")
assert(2.5.to_i == 2, "to_i truncates")
assert(1e300 * 1e300 == Float::INFINITY, "infinity")
assert((-1.0 / 0.0) < 0, "negative infinity")

# Math module (mruby-math)
assert(Math.sqrt(144.0) == 12.0, "sqrt")
assert(Math.sin(0) == 0.0, "sin")
assert(Math::PI > 3.14 && Math::PI < 3.15, "PI constant")
assert(Math.hypot(3, 4) == 5.0, "hypot")

# bit ops
assert((0b1010 & 0b0110) == 0b0010, "and")
assert((0b1010 | 0b0110) == 0b1110, "or")
assert((0b1010 ^ 0b0110) == 0b1100, "xor")
assert((~0) == -1, "invert")

# conversions
assert("42".to_i == 42, "string to_i")
assert("3.5".to_f == 3.5, "string to_f")
assert(255.to_s(16) == "ff", "to_s base")
