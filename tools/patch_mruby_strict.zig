//! Generate a strict-profile copy of the pinned core. No dependency mutation.
//! Every input is SHA-256 pinned, and every structural replacement has a fixed
//! count so upstream drift cannot silently drop an enforcement seam.
const std = @import("std");
const catalogue = @import("native_catalogue");

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, a);
    _ = args.next();
    const logical = args.next() orelse return error.MissingLogicalPath;
    const input_path = args.next() orelse return error.MissingInputPath;
    const output_path = args.next() orelse return error.MissingOutputPath;
    const mode = args.next();
    const integer_host = if (mode) |value| std.mem.eql(u8, value, "integer-host") else false;
    if ((mode != null and !integer_host) or args.next() != null) return error.UnexpectedArgument;
    const integer_codegen = std.mem.eql(u8, logical, "mrbgems/mruby-compiler/core/codegen.c");
    const integer_parser = std.mem.eql(u8, logical, "mrbgems/mruby-compiler/core/y.tab.c");
    if (integer_host and !std.mem.eql(u8, logical, "src/numeric.c") and !std.mem.eql(u8, logical, "src/string.c") and !integer_parser and !integer_codegen) return error.InvalidIntegerHostSource;
    const source_info = if (integer_host and integer_parser) catalogue.Source{
        .path = "mrbgems/mruby-compiler/core/y.tab.c",
        .sha256 = "5adc24652b99840a50e845592dd6cc1a76f3795fcb1966acf1d1b6e536fab7b4",
    } else if (integer_host and integer_codegen) catalogue.Source{
        .path = "mrbgems/mruby-compiler/core/codegen.c",
        .sha256 = "0b5efc130627ae6e48b2e790755845cbf7852dad9ebab6ea491eb24eff4f5458",
    } else catalogue.findSource(logical) orelse return error.UnreviewedSource;
    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, input_path, a, .limited(16 * 1024 * 1024));
    defer a.free(source);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, source_info.sha256)) {
        std.debug.print("strict patch: unreviewed source {s}: got {s}, expected {s}\n", .{ logical, hex, source_info.sha256 });
        return error.PinnedSourceChanged;
    }
    const output = if (integer_host and integer_parser) try patchIntegerParser(a, source) else if (integer_host and integer_codegen) try patchIntegerCodegen(a, source) else if (integer_host and std.mem.eql(u8, logical, "src/string.c")) try patchIntegerString(a, source) else if (integer_host) try patchInteger(a, source) else try patch(a, source_info, source);
    defer a.free(output);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = output });
}

fn replace(a: std.mem.Allocator, current: *[]u8, old: []const u8, new: []const u8, expected: usize) !void {
    if (std.mem.count(u8, current.*, old) != expected) {
        if (!@import("builtin").is_test) std.debug.print("strict patch: expected {d} occurrences of {s}\n", .{ expected, old });
        return error.PinnedStructureChanged;
    }
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var rest: []const u8 = current.*;
    while (std.mem.indexOf(u8, rest, old)) |index| {
        try out.writer.writeAll(rest[0..index]);
        try out.writer.writeAll(new);
        rest = rest[index + old.len ..];
    }
    try out.writer.writeAll(rest);
    const result = try a.dupe(u8, out.writer.buffer[0..out.writer.end]);
    a.free(current.*);
    current.* = result;
}

fn patch(a: std.mem.Allocator, info: catalogue.Source, source: []const u8) ![]u8 {
    var current = if (std.mem.eql(u8, info.path, "src/numeric.c")) try patchInteger(a, source) else if (std.mem.eql(u8, info.path, "src/string.c")) try patchIntegerString(a, source) else try a.dupe(u8, source);
    errdefer a.free(current);
    if (std.mem.eql(u8, info.path, "include/mruby.h")) {
        try replace(a, &current, "  void *ud; /* auxiliary data */", "#ifdef MRZ_EFFECTS_STRICT\n  struct mrz_strict_state *strict_native; /* strict-profile owned enforcement state */\n#endif\n  void *ud; /* auxiliary data */", 1);
        return current;
    }
    if (std.mem.eql(u8, info.path, "src/vm.c")) {
        try replace(a, &current, "result = OP_CMP_BODY(op,mrb_fixnum,mrb_fixnum);", "result = OP_CMP_BODY(op,mrb_integer,mrb_integer);", 1);
        try replace(a, &current, "MRB_METHOD_CFUNC(m)(mrb, self)", "mrz_strict_native_call(mrb, MRB_METHOD_CFUNC(m), self)", 1);
        try replace(a, &current, "MRB_METHOD_FUNC(m)(mrb, self)", "mrz_strict_native_call(mrb, MRB_METHOD_FUNC(m), self)", 1);
        try replace(a, &current, "MRB_METHOD_FUNC(m)(mrb, recv)", "mrz_strict_native_call(mrb, MRB_METHOD_FUNC(m), recv)", 1);
        try replace(a, &current, "MRB_PROC_CFUNC(p)(mrb, self)", "mrz_strict_native_call(mrb, MRB_PROC_CFUNC(p), self)", 5);
        try replace(a, &current, "MRB_PROC_CFUNC(p)(mrb, recv)", "mrz_strict_native_call(mrb, MRB_PROC_CFUNC(p), recv)", 3);
        try replace(a, &current, "        /* should not happen (tt:string) */\n        regs[a] = mrb_nil_value();", "#ifdef MRZ_INTEGER_ONLY\n        mrz_strict_deny(mrb, \"unsupported numeric literal\");\n#else\n        /* should not happen (tt:string) */\n        regs[a] = mrb_nil_value();\n#endif", 1);
        try replace(a, &current, "    CASE(OP_DEBUG, BBB) {", "    CASE(OP_DEBUG, BBB) {\n      mrz_strict_deny(mrb, \"native debug operation\");", 1);
    }
    if (std.mem.eql(u8, info.path, "src/array.c")) {
        // MRB_TT_FIXNUM aliases INTEGER, including heap-boxed full-width values.
        try replace(a, &current, "if (mrb_nil_p(c) || !mrb_fixnum_p(c))", "if (mrb_nil_p(c) || !mrb_integer_p(c))", 1);
        try replace(a, &current, "      cmp = mrb_fixnum(c);", "      mrb_int result = mrb_integer(c);\n      cmp = result > 0 ? 1 : result < 0 ? -1 : 0;", 1);
        try replace(a, &current, "cmp = (mrb_fixnum(a_val) > mrb_fixnum(b_val)) ? 1 : (mrb_fixnum(a_val) < mrb_fixnum(b_val)) ? -1 : 0;", "cmp = (mrb_integer(a_val) > mrb_integer(b_val)) ? 1 : (mrb_integer(a_val) < mrb_integer(b_val)) ? -1 : 0;", 1);
    }
    if (std.mem.eql(u8, info.path, "src/state.c")) {
        try replace(a, &current, "  *mrb = mrb_state_zero;", "  *mrb = mrb_state_zero;\n  if (!mrz_strict_state_init(mrb)) {\n    mrb_basic_alloc_func(mrb, 0);\n    return NULL;\n  }", 1);
        try replace(a, &current, "  mrb_free(mrb, mrb);", "  mrz_strict_state_deinit(mrb);\n  mrb_free(mrb, mrb);", 1);
        try replace(a, &current, "mrb_state_atexit(mrb_state *mrb, mrb_atexit_func f)\n{", "mrb_state_atexit(mrb_state *mrb, mrb_atexit_func f)\n{\n  mrz_strict_deny(mrb, \"native lifecycle callback\");", 1);
    }
    if (std.mem.eql(u8, info.path, "src/gc.c")) {
        try replace(a, &current, "d->type->dfree(mrb, d->data);", "mrz_strict_data_free(mrb, d->type, d->data);", 1);
    }
    if (std.mem.eql(u8, info.path, "src/kernel.c")) {
        try replace(a, &current, "mrb_obj_id_m(mrb_state *mrb, mrb_value self)\n{", "mrb_obj_id_m(mrb_state *mrb, mrb_value self)\n{\n  mrz_strict_deny(mrb, \"object identity\");", 1);
        try replace(a, &current, "mrb_obj_hash(mrb_state *mrb, mrb_value self)\n{", "mrb_obj_hash(mrb_state *mrb, mrb_value self)\n{\n  mrz_strict_deny(mrb, \"object identity hash\");", 1);
    }
    if (std.mem.eql(u8, info.path, "src/string.c")) {
        // Internal error and class formatting use this helper without Ruby
        // dispatch. Redact the address even on those internal C call paths.
        try replace(a, &current, "mrb_ptr_to_str(mrb_state *mrb, void *p)\n{", "mrb_ptr_to_str(mrb_state *mrb, void *p)\n{\n  return mrb_str_new_lit(mrb, \"identity-redacted\");", 1);
    }
    if (std.mem.eql(u8, info.path, "src/proc.c")) {
        try replace(a, &current, "proc_hash(mrb_state *mrb, mrb_value self)\n{", "proc_hash(mrb_state *mrb, mrb_value self)\n{\n  mrz_strict_deny(mrb, \"proc identity hash\");", 1);
    }
    if (std.mem.eql(u8, info.path, "src/error.c")) {
        try replace(a, &current, "mrb_warn(mrb_state *mrb, const char *fmt, ...)\n{", "mrb_warn(mrb_state *mrb, const char *fmt, ...)\n{\n  mrz_strict_deny(mrb, \"native warning output\");", 1);
    }
    if (std.mem.eql(u8, info.path, "src/print.c")) {
        try replace(a, &current, "mrb_print_m(mrb_state *mrb, mrb_value self)\n{", "mrb_print_m(mrb_state *mrb, mrb_value self)\n{\n  mrz_strict_deny(mrb, \"native stdout\");", 2);
        try replace(a, &current, "mrb_p(mrb_state *mrb, mrb_value obj)\n{", "mrb_p(mrb_state *mrb, mrb_value obj)\n{\n  mrz_strict_deny(mrb, \"native inspect output\");", 2);
    }
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try out.writer.writeAll("#include \"strict_native.h\"\n");
    try out.writer.writeAll(current);
    try appendCatalogue(a, &out.writer, info, source);
    const result = try a.dupe(u8, out.writer.buffer[0..out.writer.end]);
    a.free(current);
    return result;
}

// The host compiler shares numeric.c for literal shift folding. Apply these
// guarded changes to its pinned copy too, without strict dispatch machinery.
fn patchIntegerCodegen(a: std.mem.Allocator, source: []const u8) ![]u8 {
    var current = try a.dupe(u8, source);
    errdefer a.free(current);
    try integerFunction(a, &current, "codegen_float(codegen_scope *s, node *varnode, int val)\n{", "  (void)varnode; (void)val;\n  codegen_error(s, \"floating-point numbers are not supported\");");
    try replace(a, &current, "static int\nnew_litbint(codegen_scope *s, const char *p, int base)", "static int new_lit_int(codegen_scope *s, mrb_int num);\n\nstatic int\nnew_litbint(codegen_scope *s, const char *p, int base)", 1);
    const literal =
        \\  mrb_int number = 0;
        \\  mrb_bool negative = base < 0;
        \\  if (negative) base = -base;
        \\  if (base < 2 || base > 36 || *p == '\0')
        \\    codegen_error(s, "invalid integer literal");
        \\  for (; *p; ++p) {
        \\    unsigned char ch = (unsigned char)*p;
        \\    if (ch == '_') continue;
        \\    int digit = ch >= '0' && ch <= '9' ? ch - '0' :
        \\                ch >= 'a' && ch <= 'z' ? ch - 'a' + 10 :
        \\                ch >= 'A' && ch <= 'Z' ? ch - 'A' + 10 : -1;
        \\    if (digit < 0 || digit >= base) codegen_error(s, "invalid integer literal");
        \\    if (mrb_int_mul_overflow(number, base, &number) ||
        \\        (negative ? mrb_int_sub_overflow(number, digit, &number) :
        \\                    mrb_int_add_overflow(number, digit, &number)))
        \\      codegen_error(s, "integer literal outside int64 range");
        \\  }
        \\  return new_lit_int(s, number);
    ;
    try integerFunction(a, &current, "new_litbint(codegen_scope *s, const char *p, int base)\n{", literal);
    return current;
}

fn patchIntegerParser(a: std.mem.Allocator, source: []const u8) ![]u8 {
    var current = try a.dupe(u8, source);
    errdefer a.free(current);
    try replace(a, &current, "      yywarning_s(p, \"floating-point numbers are not supported\", tok(p));", "#ifdef MRZ_INTEGER_ONLY\n      yyerror(NULL, p, \"floating-point numbers are not supported\");\n#else\n      yywarning_s(p, \"floating-point numbers are not supported\", tok(p));\n#endif", 1);
    return current;
}

fn patchIntegerString(a: std.mem.Allocator, source: []const u8) ![]u8 {
    var current = try a.dupe(u8, source);
    errdefer a.free(current);
    const old =
        \\    if (mrb_int_mul_overflow(n, base, &n)) goto overflow;
        \\    if (MRB_INT_MAX - c < n) {
        \\      if (sign == 0 && MRB_INT_MAX - n == c - 1) {
        \\        n = MRB_INT_MIN;
        \\        sign = 1;
        \\        break;
        \\      }
        \\    overflow:
        \\#ifdef MRB_USE_BIGINT
        \\      ;
        \\      const char *p3 = p2;
        \\      while (p3 < pend) {
        \\        char c = TOLOWER(*p3);
        \\        const char *p4 = strchr(mrb_digitmap, c);
        \\        if (p4 == NULL && c != '_') break;
        \\        if (p4 - mrb_digitmap >= base) break;
        \\        p3++;
        \\      }
        \\      if (badcheck && trailingbad(str, p, pend)) goto bad;
        \\      return mrb_bint_new_str(mrb, p2, (mrb_int)(p3-p2), sign ? base : -base);
        \\#else
        \\      mrb_raisef(mrb, E_RANGE_ERROR, "string (%l) too big for integer", str, pend-str);
        \\#endif
        \\    }
        \\    n += c;
    ;
    const checked =
        \\#ifdef MRZ_INTEGER_ONLY
        \\    /* Accumulating a negative number downward includes INT64_MIN and still
        \\     * checks every following digit, instead of accepting an overflowing prefix. */
        \\    if (mrb_int_mul_overflow(n, base, &n) ||
        \\        (sign ? mrb_int_add_overflow(n, c, &n) : mrb_int_sub_overflow(n, c, &n))) {
        \\      mrb_raisef(mrb, E_RANGE_ERROR, "string (%l) too big for integer", str, pend-str);
        \\    }
        \\#else
        \\    if (mrb_int_mul_overflow(n, base, &n)) goto overflow;
        \\    if (MRB_INT_MAX - c < n) {
        \\      if (sign == 0 && MRB_INT_MAX - n == c - 1) {
        \\        n = MRB_INT_MIN;
        \\        sign = 1;
        \\        break;
        \\      }
        \\    overflow:
        \\#ifdef MRB_USE_BIGINT
        \\      ;
        \\      const char *p3 = p2;
        \\      while (p3 < pend) {
        \\        char c = TOLOWER(*p3);
        \\        const char *p4 = strchr(mrb_digitmap, c);
        \\        if (p4 == NULL && c != '_') break;
        \\        if (p4 - mrb_digitmap >= base) break;
        \\        p3++;
        \\      }
        \\      if (badcheck && trailingbad(str, p, pend)) goto bad;
        \\      return mrb_bint_new_str(mrb, p2, (mrb_int)(p3-p2), sign ? base : -base);
        \\#else
        \\      mrb_raisef(mrb, E_RANGE_ERROR, "string (%l) too big for integer", str, pend-str);
        \\#endif
        \\    }
        \\    n += c;
        \\#endif
    ;
    try replace(a, &current, old, checked, 1);
    try replace(a, &current, "  return mrb_int_value(mrb, sign ? val : -val);", "#ifdef MRZ_INTEGER_ONLY\n  return mrb_int_value(mrb, val);\n#else\n  return mrb_int_value(mrb, sign ? val : -val);\n#endif", 1);
    return current;
}

fn patchInteger(a: std.mem.Allocator, source: []const u8) ![]u8 {
    var current = try a.dupe(u8, source);
    errdefer a.free(current);
    const helpers =
        \\#ifdef MRZ_INTEGER_ONLY
        \\#include <stdint.h>
        \\#if !defined(MRB_NO_FLOAT) || !defined(MRB_INT64) || defined(MRB_USE_BIGINT) || defined(MRB_USE_RATIONAL) || defined(MRB_USE_COMPLEX)
        \\#error "integer-only execution requires fixed int64 without alternate numeric types"
        \\#endif
        \\
        \\/* Negative counts reverse direction. Reconstruct arithmetic right shifts
        \\ * without implementation-defined shifts of negative signed operands. */
        \\static mrb_bool
        \\mrz_integer_shift_bits(mrb_int value, mrb_int width, mrb_int *out)
        \\{
        \\  if (width < 0) {
        \\    if (width <= -64) {
        \\      *out = value < 0 ? -1 : 0;
        \\    }
        \\    else if (value >= 0) {
        \\      *out = (mrb_int)((uint64_t)value >> (unsigned)-width);
        \\    }
        \\    else {
        \\      uint64_t complement = (uint64_t)(-(value + 1));
        \\      *out = -1 - (mrb_int)(complement >> (unsigned)-width);
        \\    }
        \\    return TRUE;
        \\  }
        \\  if (value == 0) { *out = 0; return TRUE; }
        \\  if (width >= 64) return FALSE;
        \\  if (width == 63) {
        \\    if (value != -1) return FALSE;
        \\    *out = MRB_INT_MIN;
        \\    return TRUE;
        \\  }
        \\  return !mrb_int_mul_overflow(value, (mrb_int)1 << (unsigned)width, out);
        \\}
        \\
        \\static mrb_value
        \\mrz_integer_shift(mrb_state *mrb, mrb_value value, mrb_bool right)
        \\{
        \\  mrb_int width = mrb_as_int(mrb, mrb_get_arg1(mrb));
        \\  mrb_int number = mrb_integer(value);
        \\  if (right && width == MRB_INT_MIN) {
        \\    if (number == 0) return value;
        \\    mrb_int_overflow(mrb, "bit shift");
        \\  }
        \\  if (right) width = -width;
        \\  if (!mrz_integer_shift_bits(number, width, &number))
        \\    mrb_int_overflow(mrb, "bit shift");
        \\  return mrb_int_value(mrb, number);
        \\}
        \\
        \\/* mode: 0 ceil, 1 floor, 2 round (ties away from zero), 3 truncate.
        \\ * Unsigned magnitude also covers INT64_MIN without signed negation. */
        \\static mrb_value
        \\mrz_integer_round(mrb_state *mrb, mrb_value value, unsigned mode)
        \\{
        \\  mrb_int digits = 0;
        \\  mrb_get_args(mrb, "|i", &digits);
        \\  mrb_int number = mrb_integer(value);
        \\  if (digits >= 0 || number == 0) return value;
        \\  mrb_bool negative = number < 0;
        \\  if (digits <= -20) {
        \\    if ((mode == 0 && !negative) || (mode == 1 && negative))
        \\      mrb_int_overflow(mrb, "rounding");
        \\    return mrb_fixnum_value(0);
        \\  }
        \\  uint64_t factor = 1;
        \\  for (mrb_int i = 0; i < -digits; ++i) factor *= 10;
        \\  uint64_t magnitude = negative ? (uint64_t)(-(number + 1)) + 1 : (uint64_t)number;
        \\  uint64_t quotient = magnitude / factor;
        \\  uint64_t remainder = magnitude % factor;
        \\  if ((mode == 0 && !negative && remainder != 0) ||
        \\      (mode == 1 && negative && remainder != 0) ||
        \\      (mode == 2 && remainder >= factor / 2)) ++quotient;
        \\  magnitude = quotient * factor;
        \\  uint64_t limit = negative ? (UINT64_C(1) << 63) : (uint64_t)MRB_INT_MAX;
        \\  if (magnitude > limit) mrb_int_overflow(mrb, "rounding");
        \\  if (negative && magnitude == (UINT64_C(1) << 63)) return mrb_int_value(mrb, MRB_INT_MIN);
        \\  return mrb_int_value(mrb, negative ? -(mrb_int)magnitude : (mrb_int)magnitude);
        \\}
        \\#endif
    ;
    const marker = "mrb_bool\nmrb_num_shift(mrb_state *mrb, mrb_int val, mrb_int width, mrb_int *num)";
    const insertion = try std.mem.concat(a, u8, &.{ helpers, "\n", marker });
    defer a.free(insertion);
    try replace(a, &current, marker, insertion, 1);
    try integerFunction(a, &current, "mrb_num_shift(mrb_state *mrb, mrb_int val, mrb_int width, mrb_int *num)\n{", "  (void)mrb;\n  return mrz_integer_shift_bits(val, width, num);");
    try integerFunction(a, &current, "int_lshift(mrb_state *mrb, mrb_value x)\n{", "  return mrz_integer_shift(mrb, x, FALSE);");
    try integerFunction(a, &current, "int_rshift(mrb_state *mrb, mrb_value x)\n{", "  return mrz_integer_shift(mrb, x, TRUE);");
    try integerFunction(a, &current, "prepare_int_rounding(mrb_state *mrb, mrb_value x)\n{", "  (void)mrb; (void)x;\n  return mrb_nil_value(); /* replaced by mrz_integer_round */");
    inline for (.{ "ceil", "floor", "round", "truncate" }, 0..) |name, mode| {
        const signature = "int_" ++ name ++ "(mrb_state *mrb, mrb_value x)\n{";
        const body = try std.fmt.allocPrint(a, "  return mrz_integer_round(mrb, x, {d});", .{mode});
        defer a.free(body);
        try integerFunction(a, &current, signature, body);
    }
    try replace(a, &current, "\n  if (a == 0) return x;", "\n#ifndef MRZ_INTEGER_ONLY\n  if (a == 0) return x;\n#endif", 1);
    try replace(a, &current, "  if (!mrb_fixnum_p(v2)) {", "  if (!mrb_integer_p(v2)) {", 1);
    try replace(a, &current, "    return mrb_integer(v);", "    mrb_int result = mrb_integer(v);\n    return result > 0 ? 1 : result < 0 ? -1 : 0;", 1);
    try replace(a, &current, "      return -mrb_integer(v1);", "      mrb_int result = mrb_integer(v1);\n      return result > 0 ? -1 : result < 0 ? 1 : 0;", 2);
    try replace(a, &current, "  char buf[MRB_INT_BIT+1];", "  char buf[MRB_INT_BIT+2]; /* sign, all magnitude bits, terminator */", 1);
    try replace(a, &current, "    base = mrb_integer(mrb_get_arg1(mrb));", "#ifdef MRZ_INTEGER_ONLY\n    base = mrb_as_int(mrb, mrb_get_arg1(mrb));\n#else\n    base = mrb_integer(mrb_get_arg1(mrb));\n#endif", 1);
    return current;
}

// Definitions in this SHA-pinned source use column-zero closing braces. Keep
// the original body under #else so non-integer profiles remain unchanged.
fn integerFunction(a: std.mem.Allocator, current: *[]u8, signature: []const u8, body: []const u8) !void {
    if (std.mem.count(u8, current.*, signature) != 1) return error.PinnedStructureChanged;
    const begin = std.mem.indexOf(u8, current.*, signature).?;
    const start = begin + signature.len;
    const end = start + (std.mem.indexOf(u8, current.*[start..], "\n}\n") orelse return error.PinnedStructureChanged);
    const old = try a.dupe(u8, current.*[begin .. end + 2]);
    defer a.free(old);
    const replacement = try std.mem.concat(a, u8, &.{ signature, "\n#ifdef MRZ_INTEGER_ONLY\n", body, "\n#else", current.*[start..end], "\n#endif\n}" });
    defer a.free(replacement);
    try replace(a, current, old, replacement, 1);
}

fn appendCatalogue(a: std.mem.Allocator, out: *std.Io.Writer, info: catalogue.Source, source: []const u8) !void {
    var tables: std.ArrayList([]const u8) = .empty;
    defer tables.deinit(a);
    var lines = std.mem.splitScalar(u8, source, '\n');
    var table: ?[]const u8 = null;
    while (lines.next()) |line| {
        if (table == null) {
            const marker = "const mrb_mt_entry ";
            if (std.mem.indexOf(u8, line, marker)) |start| {
                const rest = line[start + marker.len ..];
                const end = std.mem.indexOf(u8, rest, "[] = {") orelse continue;
                const name = rest[0..end];
                table = name;
                try tables.append(a, name);
                if (std.mem.eql(u8, name, "float_rom_entries")) try out.writeAll("\n#ifndef MRB_NO_FLOAT\n");
                try out.print("\nstatic const struct mrz_strict_builtin {s}_strict[] = {{\n", .{name});
            }
            continue;
        }
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), "};")) {
            try out.writeAll("};\n");
            if (std.mem.eql(u8, table.?, "float_rom_entries")) try out.writeAll("#endif\n");
            table = null;
            continue;
        }
        const marker = "MRB_MT_ENTRY(";
        if (std.mem.indexOf(u8, line, marker)) |start| {
            const rest = line[start + marker.len ..];
            const comma = std.mem.indexOfScalar(u8, rest, ',') orelse return error.InvalidNativeTable;
            const name = std.mem.trim(u8, rest[0..comma], " \t");
            const allowed = catalogue.allowed(name) orelse return error.UnreviewedNative;
            try out.print("  {{ {s}, \"{s}\", {s} }},\n", .{ name, name, if (allowed) "TRUE" else "FALSE" });
        } else {
            try out.writeAll(line);
            try out.writeByte('\n');
        }
    }
    if (table != null) return error.UnterminatedNativeTable;
    if (info.extras.len != 0) {
        try out.writeAll("\nstatic const struct mrz_strict_builtin strict_extras[] = {\n");
        for (info.extras) |name| {
            const allowed = catalogue.allowed(name) orelse return error.UnreviewedNative;
            try out.print("  {{ {s}, \"{s}\", {s} }},\n", .{ name, name, if (allowed) "TRUE" else "FALSE" });
        }
        try out.writeAll("};\n");
    }
    if (tables.items.len == 0 and info.extras.len == 0) return;
    const stem = std.fs.path.stem(info.path);
    try out.print("\nconst struct mrz_strict_builtin *mrz_strict_{s}_lookup(mrb_func_t function)\n{{\n", .{stem});
    for (tables.items) |name| {
        if (std.mem.eql(u8, name, "float_rom_entries")) try out.writeAll("#ifndef MRB_NO_FLOAT\n");
        try out.print("  for (size_t i = 0; i < sizeof({s}_strict)/sizeof({s}_strict[0]); ++i)\n    if ({s}_strict[i].function == function) return &{s}_strict[i];\n", .{ name, name, name, name });
        if (std.mem.eql(u8, name, "float_rom_entries")) try out.writeAll("#endif\n");
    }
    if (info.extras.len != 0) try out.writeAll("  for (size_t i = 0; i < sizeof(strict_extras)/sizeof(strict_extras[0]); ++i)\n    if (strict_extras[i].function == function) return &strict_extras[i];\n");
    try out.writeAll("  return NULL;\n}\n");
}

test "strict patch rejects missing or duplicated dispatch seams" {
    const a = std.testing.allocator;
    var source = try a.dupe(u8, "call call");
    defer a.free(source);
    try std.testing.expectError(error.PinnedStructureChanged, replace(a, &source, "call", "guard", 1));
    try std.testing.expectEqualStrings("call call", source);
    try replace(a, &source, "call", "guard", 2);
    try std.testing.expectEqualStrings("guard guard", source);
}

test "strict catalogue generation rejects an unreviewed native implementation" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(error.UnreviewedNative, appendCatalogue(std.testing.allocator, &out.writer, .{ .path = "src/test.c", .sha256 = "" }, "static const mrb_mt_entry test[] = {\n MRB_MT_ENTRY(unknown_effectful_native, 0, 0),\n};\n"));
}

test "strict VM patches every pinned native dispatch form" {
    const a = std.testing.allocator;
    const source = "result = OP_CMP_BODY(op,mrb_fixnum,mrb_fixnum);\n" ++
        "MRB_METHOD_CFUNC(m)(mrb, self)\n" ++
        "MRB_METHOD_FUNC(m)(mrb, self)\n" ++
        "MRB_METHOD_FUNC(m)(mrb, recv)\n" ++
        "MRB_PROC_CFUNC(p)(mrb, self)\n" ++
        "MRB_PROC_CFUNC(p)(mrb, self)\n" ++
        "MRB_PROC_CFUNC(p)(mrb, self)\n" ++
        "MRB_PROC_CFUNC(p)(mrb, self)\n" ++
        "MRB_PROC_CFUNC(p)(mrb, self)\n" ++
        "MRB_PROC_CFUNC(p)(mrb, recv)\n" ++
        "MRB_PROC_CFUNC(p)(mrb, recv)\n" ++
        "MRB_PROC_CFUNC(p)(mrb, recv)\n" ++
        "    CASE(OP_DEBUG, BBB) {\n" ++
        "        /* should not happen (tt:string) */\n        regs[a] = mrb_nil_value();\n";
    const generated = try patch(a, .{ .path = "src/vm.c", .sha256 = "" }, source);
    defer a.free(generated);
    try std.testing.expectEqual(11, std.mem.count(u8, generated, "mrz_strict_native_call("));
    try std.testing.expectEqual(0, std.mem.count(u8, generated, ")(mrb,"));
    try std.testing.expectEqual(1, std.mem.count(u8, generated, "mrz_strict_deny(mrb, \"native debug operation\")"));
}

test "integer profile wrappers preserve default body and require one pinned definition" {
    const a = std.testing.allocator;
    var source = try a.dupe(u8, "int_case(mrb_state *mrb, mrb_value x)\n{\n  return x;\n}\n");
    defer a.free(source);
    try integerFunction(a, &source, "int_case(mrb_state *mrb, mrb_value x)\n{", "  return checked(x);");
    try std.testing.expect(std.mem.indexOf(u8, source, "#ifdef MRZ_INTEGER_ONLY\n  return checked(x);\n#else\n  return x;\n#endif") != null);
    try std.testing.expectError(error.PinnedStructureChanged, integerFunction(a, &source, "missing()\n{", ""));
}

test "integer compiler rejects float literals instead of substituting zero" {
    const source = "      yywarning_s(p, \"floating-point numbers are not supported\", tok(p));";
    const patched = try patchIntegerParser(std.testing.allocator, source);
    defer std.testing.allocator.free(patched);
    try std.testing.expect(std.mem.indexOf(u8, patched, "#ifdef MRZ_INTEGER_ONLY\n      yyerror(NULL, p,") != null);
    try std.testing.expectError(error.PinnedStructureChanged, patchIntegerParser(std.testing.allocator, ""));
}

test "strict sorting decodes full-width boxed integer values" {
    const original = "if (mrb_nil_p(c) || !mrb_fixnum_p(c))\n      cmp = mrb_fixnum(c);\n" ++
        "cmp = (mrb_fixnum(a_val) > mrb_fixnum(b_val)) ? 1 : (mrb_fixnum(a_val) < mrb_fixnum(b_val)) ? -1 : 0;";
    const generated = try patch(std.testing.allocator, .{ .path = "src/array.c", .sha256 = "" }, original);
    defer std.testing.allocator.free(generated);
    try std.testing.expect(std.mem.indexOf(u8, generated, "mrb_fixnum(") == null);
    try std.testing.expectEqual(5, std.mem.count(u8, generated, "mrb_integer("));
}
