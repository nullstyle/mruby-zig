# Core language: classes, modules, blocks, procs, exceptions, enumerables.
# Each file is loaded by src/tests.zig; any raise (including a failed
# assertion) fails the Zig test.

def assert(cond, msg = "assertion failed")
  raise msg unless cond
end

# classes, inheritance, modules
class Greeter
  attr_accessor :name
  def initialize(name)
    @name = name
  end
  def greet
    "hello, #{@name}"
  end
end

class LoudGreeter < Greeter
  def greet
    super.upcase + "!"
  end
end

module Countable
  def count_items(items)
    items.size
  end
end

g = LoudGreeter.new("zig")
assert(g.is_a?(Greeter), "inheritance")
assert(g.greet == "HELLO, ZIG!", "super and interpolation")
g.name = "mruby"
assert(g.name == "mruby", "attr accessors")
assert(g.instance_variable_get(:@name) == "mruby", "metaprog ivar read")

class WithMixin
  include Countable
end
assert(WithMixin.new.count_items([1, 2, 3]) == 3, "module mixin")

# blocks, procs, lambdas
acc = []
[1, 2, 3].each { |x| acc << x * 10 }
assert(acc == [10, 20, 30], "each block")
double = ->(x) { x * 2 }
assert(double.call(21) == 42, "lambda")
assert([1, 2, 3].map(&:to_s) == ["1", "2", "3"], "symbol to proc")

# exceptions
begin
  raise ArgumentError, "nope"
rescue ArgumentError => e
  assert(e.message == "nope", "exception message")
else
  raise "should not reach else"
ensure
  ensured = true
end
assert(ensured, "ensure ran")

begin
  Integer("zzz")
rescue ArgumentError, TypeError
  ensured = :converted
end
assert(ensured == :converted, "conversion raises")

# enumerable / comparable (mrblib)
assert([3, 1, 2].sort == [1, 2, 3], "sort")
assert([1, 2, 3, 4].select(&:even?) == [2, 4], "select")
assert([[1, 2], [3]].flatten == [1, 2, 3], "flatten")
assert(%w[a b c].inject("") { |s, x| s + x } == "abc", "inject")
assert((1..5).include?(3), "range include")
assert((1..10).select { |x| x % 3 == 1 }.first(3) == [1, 4, 7], "range select")

# strings, symbols, arrays, hashes (core + ext gems)
assert("hello world".split == ["hello", "world"], "split")
assert("a-b-c".tr("-", "_") == "a_b_c", "tr")
assert("pad".ljust(5, ".") == "pad..", "ljust")
assert(%w[x y].join(", ") == "x, y", "join")
assert([1, [2, [3, [4]]]].flatten == [1, 2, 3, 4], "deep flatten")
assert({ a: 1, b: 2 }.map { |k, v| "#{k}#{v}" }.sort == ["a1", "b2"], "hash map pairs")

# structs
Point = Struct.new(:x, :y) do
  def magnitude
    Math.sqrt(x * x + y * y)
  end
end
p = Point.new(3, 4)
assert(p.magnitude == 5.0, "struct with method")
assert(p.to_a == [3, 4], "struct to_a")

# sets (mruby-set)
s = Set.new([1, 2, 2, 3])
assert(s.size == 3, "set dedup")
s << 1
assert(s.size == 3, "set idempotent add")

# sprintf
assert(sprintf("%05.2f", 3.14159) == "03.14", "sprintf float")
assert(sprintf("%s=%d", "n", 42) == "n=42", "sprintf mixed")

# fibers and enumerators
fiber_results = []
f = Fiber.new do
  fiber_results << 1
  Fiber.yield
  fiber_results << 2
end
f.resume
f.resume
assert(fiber_results == [1, 2], "fiber")

enum = [1, 2, 3].each
assert(enum.next == 1, "enumerator next")
assert((1..Float::INFINITY).lazy.map { |x| x * x }.first(3) == [1, 4, 9], "lazy")

# eval / binding / method objects (mruby-eval, mruby-method)
assert(eval("1 + 1") == 2, "eval")
m = 1.method(:+)
assert(m.call(2) == 3, "method object")
assert(instance_eval { 40 + 2 } == 42, "instance_eval")

# pack
assert([1, 2].pack("C*") == [1, 2].pack("C*"), "pack")
assert([65, 66].pack("C*").unpack("C*") == [65, 66], "pack/unpack roundtrip")

# random and time are functional
assert(rand(5) >= 0 && rand(5) < 5, "rand range")
assert(Time.now.year >= 2026, "time year")

# GC exercises
10.times { "garbage #{rand(100)}" }
GC.start
assert(true, "gc ran")
