# Give existing native methods new names before the core model is sealed.
# Calls through these aliases cannot use arithmetic bytecode shortcuts.
class Integer
  alias corpus_add +
  alias corpus_sub -
  alias corpus_mul *
  alias corpus_div /
  alias corpus_neg -@
  alias corpus_lt <
  alias corpus_le <=
  alias corpus_gt >
  alias corpus_ge >=
  alias corpus_eq ==
  alias corpus_cmp <=>
end

# Operands arrive in capsules, so the compiler cannot fold the arithmetic.
class IntegerReverseComparison < Numeric
  def initialize(value)
    @value = value
  end
  def <=>(other)
    @value
  end
end

module IntegerCorpus
  def self.calculate(mode, x, y)
    case mode
    when "identity" then x
    when "less" then x < y
    when "sort" then [x, y, 0, -1, 1, x].sort
    when "sort_block" then [x, y, 0, -1, 1, x].sort { |a, b| a < b ? y : a > b ? x : 0 }
    when "array_compare" then [IntegerReverseComparison.new(x)] <=> [0]
    when "compare" then [x < y, x <= y, x > y, x >= y, x == y, x <=> y]
    when "compare_native" then [x.corpus_lt(y), x.corpus_le(y), x.corpus_gt(y), x.corpus_ge(y), x.corpus_eq(y), x.corpus_cmp(y)]
    when "literal_min" then -9223372036854775808
    when "literal_max" then 9223372036854775807
    when "literal_left" then (-1 << 63)
    when "literal_right" then (-7 >> 1)
    when "literal_negative_shift" then (-7 << -1)
    when "literal_overflow" then 9223372036854775807 + 1
    when "add" then x + y
    when "add_native" then x.corpus_add(y)
    when "sub" then x - y
    when "sub_native" then x.corpus_sub(y)
    when "mul" then x * y
    when "mul_native" then x.corpus_mul(y)
    when "div" then x / y
    when "div_native" then x.corpus_div(y)
    when "idiv" then x.div(y)
    when "mod" then x % y
    when "divmod" then x.divmod(y)
    when "neg" then -x
    when "neg_native" then x.corpus_neg
    when "abs" then x.abs
    when "left" then x << y
    when "right" then x >> y
    when "power" then x ** y
    when "floor" then x.floor(y)
    when "ceil" then x.ceil(y)
    when "round" then x.round(y)
    when "truncate" then x.truncate(y)
    when "bits" then [x & y, x | y, x ^ y, ~x]
    when "from_string_min" then "-9223372036854775808".to_i(10)
    when "to_i_min" then "-9223372036854775808".to_i
    when "from_string_binary_min" then "-1000000000000000000000000000000000000000000000000000000000000000".to_i(2)
    when "from_string_over_max" then "9223372036854775808".to_i
    when "from_string_under_min" then "-9223372036854775809".to_i
    when "to_i_min_suffix" then "-92233720368547758080".to_i
    when "decimal" then x.to_s
    when "binary" then x.to_s(2)
    when "reverse_compare" then x <=> IntegerReverseComparison.new(y)
    when "hidden_add"
      x + y
      0
    when "rescue_overflow"
      begin
        x + y
      rescue RangeError
        42
      end
    when "rescue_zero"
      begin
        x / y
      rescue ZeroDivisionError
        43
      end
    when "float_methods"
      [Object.const_defined?(:Float), x.respond_to?(:to_f), "1.25".respond_to?(:to_f)]
    when "rescue_to_f"
      begin
        x.to_f
        0
      rescue NoMethodError
        44
      end
    when "rescue_float"
      begin
        Float("1.25")
        0
      rescue NoMethodError
        45
      end
    when "adapter_float"
      begin
        Effect.perform(Source.read)
      rescue Exception
        # A Float adapter result is a fatal boundary violation, even here.
      end
      0
    else
      raise ArgumentError, "unknown corpus mode"
    end
  end

  def self.apply(state, input)
    Effect.perform(Stage.write(input[1]))
    [calculate(input[0], input[1], input[2]), state]
  end
end
