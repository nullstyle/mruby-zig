# Integer64 effects profile

`-Deffects-integer64=true` adds an experimental numeric policy to the
[strict effects runtime](effects-strict.md): Ruby integers are signed 64-bit
values, and Ruby Float values are unavailable. The option requires
`-Deffects-strict=true` and a 64-bit target. Ordinary strict builds keep their
existing Float behavior. The bundled test/demo targets below require Linux or
macOS on x86_64 or aarch64, matching strict worker support.

```sh
mise x -- zig build test-effects-integer64 -Deffects-strict=true -Deffects-integer64=true
mise x -- zig build run-effects-integer64 -Deffects-strict=true -Deffects-integer64=true
```

Use both options on a downstream dependency so its CodeDB compiler and runtime
agree:

```zig
const dep = b.dependency("mruby", .{
    .target = target,
    .optimize = optimize,
    .@"effects-strict" = true,
    .@"effects-integer64" = true,
});
```

`mruby.features.effects_integer64` reports the policy. In this profile,
`integer_bits` is 64, `float_bits` is 0, and `has_float` is false. Both the
trusted build-time compiler and target runtime use `MRB_NO_FLOAT`, `MRB_INT64`,
and the pinned integer policy patches. There is no target compiler, BigInt,
Rational, Complex, or math gem. Float literals fail compilation, including
literals immediately converted to integers or placed in unreachable code.
Integer literals outside the signed 64-bit range fail compilation when they
would emit a runtime value. The optimizer may eliminate unused or unreachable
integer literals before this check; no out-of-range Integer value is constructed.
Float literal rejection happens during parsing and also covers eliminated code.
Arithmetic on valid integer operands raises at runtime when its result overflows.

The profile participates in artifact/runtime identity. Rebuild CodeDB artifacts
and application workers together when switching profiles; ordinary strict
CodeDB/RITE artifacts and receipts are not interchangeable with integer64 ones.
StateCapsules carry no runtime compatibility identity: integer-only graphs remain
transferable unchanged, while Float-bearing graphs fail execution admission.
StateCapsule framing remains unchanged.

## Arithmetic and errors

The supported integer range is `-9223372036854775808` through
`9223372036854775807`. Checked operations raise `RangeError` when their result
cannot fit; they do not silently wrap or promote to Float. Native method calls
and bytecode arithmetic follow the same policy.

| Operation | Behavior |
| --- | --- |
| Addition, subtraction, multiplication, unary minus, absolute value | Exact signed integer result or `RangeError`. |
| `/`, `div`, `divmod` | Floor division; a zero divisor raises `ZeroDivisionError`. The minimum integer divided by `-1` raises `RangeError`. |
| `%` | Remainder has the divisor's sign; minimum integer `% -1` is zero. A zero divisor raises `ZeroDivisionError`, including `0 % 0`. |
| `**` | Exact result or `RangeError`; negative exponents raise `RangeError`. `0 ** 0` is one. |
| `<<`, `>>` | Negative counts reverse direction. Right shifts sign-extend and sufficiently large right shifts give zero or minus one. Unrepresentable left shifts raise `RangeError`. |
| String `to_i(base)` | Parses the complete signed 64-bit range; overflow raises `RangeError` instead of returning a truncated numeric prefix. |
| `floor`, `ceil`, `round`, `truncate` | Decimal rounding uses integer arithmetic, including magnitudes above binary64's exact range. `round` breaks ties away from zero; an unrepresentable rounded result raises `RangeError`. |

Arithmetic exceptions remain ordinary Ruby exceptions. Code may rescue them and
continue with a valid integer result:

```ruby
begin
  total = amount + fee
rescue RangeError
  total = 0
end
```

The failing expression produces no invalid numeric value. An unrescued overflow
still aborts a turn even when later code would have returned a small integer.
An absent conversion such as `1.to_f` raises an ordinary missing-method error;
rescuing that error does not create a Float. These errors differ from sticky
native authority violations.

## Data at execution boundaries

Float values cannot enter execution through state, input, effect arguments,
adapter outcomes, or terminal result/state graphs. Admission checks the complete
inert graph, including nested arrays, Hash keys and values, and Hash defaults.
The policy applies with or without operation and whole-turn schemas; a schema
cannot relax it. Violations return `NumericPolicyViolation`.

Float starting state/input is rejected before creating a worker or beginning a
host transaction. A Float adapter result aborts the turn and discards earlier
staged work, even if Ruby attempts to rescue the effect failure. Replay applies
the same numeric checks to recorded data. `Isolate.importValue` and direct
`Vm.floatValue` also reject Float in this profile.

The structural artifact format still supports binary64 values. VM-free
`effect.data.encode` and `Document.decode` preserve them so inspectors and
migration tools can read existing data. `Document.decodeWithOptions` accepts
`.{ .limits = ..., .allow_float = false }` for explicit numeric validation.
Execution entry points impose the profile's policy independently of those
structural helpers.

## What the corpus establishes

[The numeric corpus](../examples/effects_integer64.zig) exercises integer
boundaries, full-width comparisons and sorting, native and bytecode arithmetic, signed division, shift extremes,
exponentiation, decimal rounding, formatting, safe rescue, and hidden overflowing
intermediates. The executable emits each successful case's actual canonical terminal and
effect argument/result capsule bytes as hex, or a Ruby exception class for
a failed case. Expected values are checked before output. These values can be compared across
platforms without comparing complete receipts, which include runtime and
application identities.

[Integration tests](../src/effects_integer64_tests.zig) cover Float graph
admission, staged-effect discard, worker replay without adapters, and the
separation between structural decoding and execution policy. The configured
CodeDB compiler also runs negative Float-literal tests.

This is a bounded numeric profile, not a proof that arbitrary Ruby applications
or complete receipts are identical across machines. Allocation failures,
instruction/resource limits, process scheduling, trusted adapter behavior, and
other runtime/library behavior remain relevant. Native adapters, allocators,
and raw embedding C/Zig remain trusted; they may use floating point internally.
The profile controls values admitted to the Ruby runtime, not arbitrary host
computation. [Worker containment](effects-workers.md) and deterministic adapter
contracts remain necessary for the corresponding authority and replay guarantees.
