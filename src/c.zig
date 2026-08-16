//! Hand-written extern bindings for the subset of mruby's C API used by
//! mruby-zig, plus the `mrz_*` shim entry points (src/shim.c) that expose
//! mruby's macro-only inline operations as plain functions.
//!
//! Layout notes:
//!  - `mrb_value` under the default build configuration (word boxing,
//!    `MRB_INT64` on 64-bit) is a single machine word; it is passed and
//!    returned by value. Zig never inspects its bits — all decoding goes
//!    through the shim, so boxing-internal representation changes cannot
//!    silently break these bindings.
//!  - `mrb_state` is opaque; exception/arena access goes through the shim.
//!  - The library is compiled by this package's build with fixed config
//!    flags; this file binds exactly that build.

pub const mrb_int = i64;
pub const mrb_float = f64;
pub const mrb_sym = u32;
pub const mrb_bool = bool;
pub const mrb_aspec = u32;
pub const mrb_vtype = c_int;

/// Value types, in `enum mrb_vtype` order (include/mruby/value.h).
pub const MRB_TT_FALSE: mrb_vtype = 0;
pub const MRB_TT_TRUE: mrb_vtype = 1;
pub const MRB_TT_SYMBOL: mrb_vtype = 2;
pub const MRB_TT_UNDEF: mrb_vtype = 3;
pub const MRB_TT_FREE: mrb_vtype = 4;
pub const MRB_TT_FLOAT: mrb_vtype = 5;
pub const MRB_TT_INTEGER: mrb_vtype = 6;
pub const MRB_TT_CPTR: mrb_vtype = 7;
pub const MRB_TT_OBJECT: mrb_vtype = 8;
pub const MRB_TT_CLASS: mrb_vtype = 9;
pub const MRB_TT_MODULE: mrb_vtype = 10;
pub const MRB_TT_SCLASS: mrb_vtype = 11;
pub const MRB_TT_HASH: mrb_vtype = 12;
pub const MRB_TT_CDATA: mrb_vtype = 13;
pub const MRB_TT_EXCEPTION: mrb_vtype = 14;
pub const MRB_TT_ICLASS: mrb_vtype = 15;
pub const MRB_TT_PROC: mrb_vtype = 16;
pub const MRB_TT_ARRAY: mrb_vtype = 17;
pub const MRB_TT_STRING: mrb_vtype = 18;
pub const MRB_TT_RANGE: mrb_vtype = 19;
pub const MRB_TT_ENV: mrb_vtype = 20;
pub const MRB_TT_FIBER: mrb_vtype = 21;
pub const MRB_TT_STRUCT: mrb_vtype = 22;
pub const MRB_TT_ISTRUCT: mrb_vtype = 23;
pub const MRB_TT_BREAK: mrb_vtype = 24;
pub const MRB_TT_COMPLEX: mrb_vtype = 25;
pub const MRB_TT_RATIONAL: mrb_vtype = 26;
pub const MRB_TT_BIGINT: mrb_vtype = 27;
pub const MRB_TT_BACKTRACE: mrb_vtype = 28;
pub const MRB_TT_SET: mrb_vtype = 29;

pub const mrb_value = extern struct {
    w: usize,
};

pub const mrb_state = opaque {};
pub const RClass = opaque {};
pub const RObject = opaque {};
pub const RProc = opaque {};
pub const RData = opaque {};
pub const mrb_ccontext = opaque {};
pub const mrb_data_type = extern struct {
    name: ?[*:0]const u8,
    dfree: ?*const fn (?*mrb_state, ?*anyopaque) callconv(.c) void,
};

pub const mrb_func_t = *const fn (?*mrb_state, mrb_value) callconv(.c) mrb_value;

/// Argument specifiers for mrb_define_method (mruby 4.0 bit layout):
/// REQ(n) = n<<18, OPT(n) = n<<13, REST = 1<<12, POST(n) = n<<7, BLOCK = 1.
pub const MRB_ARGS_NONE: mrb_aspec = 0;
pub const MRB_ARGS_REST: mrb_aspec = 1 << 12;
pub const MRB_ARGS_BLOCK: mrb_aspec = 1;
pub const MRB_ARGS_ANY: mrb_aspec = MRB_ARGS_REST;

// ---- state ------------------------------------------------------------

pub extern fn mrb_open() ?*mrb_state;
pub extern fn mrb_close(mrb: *mrb_state) void;

// ---- compile / eval ---------------------------------------------------

pub extern fn mrb_load_string(mrb: *mrb_state, s: [*:0]const u8) mrb_value;
pub extern fn mrb_load_nstring(mrb: *mrb_state, s: [*]const u8, len: usize) mrb_value;

// ---- classes, modules, methods ----------------------------------------

pub extern fn mrb_define_class(mrb: *mrb_state, name: [*:0]const u8, super: ?*RClass) *RClass;
pub extern fn mrb_define_module(mrb: *mrb_state, name: [*:0]const u8) *RClass;
pub extern fn mrb_define_class_under(mrb: *mrb_state, outer: *RClass, name: [*:0]const u8, super: ?*RClass) *RClass;
pub extern fn mrb_define_module_under(mrb: *mrb_state, outer: *RClass, name: [*:0]const u8) *RClass;
pub extern fn mrb_class_get(mrb: *mrb_state, name: [*:0]const u8) *RClass;
pub extern fn mrb_module_get(mrb: *mrb_state, name: [*:0]const u8) *RClass;
pub extern fn mrb_define_method(mrb: *mrb_state, cla: *RClass, name: [*:0]const u8, func: mrb_func_t, aspec: mrb_aspec) void;
pub extern fn mrb_define_class_method(mrb: *mrb_state, cla: *RClass, name: [*:0]const u8, func: mrb_func_t, aspec: mrb_aspec) void;
pub extern fn mrb_define_singleton_method(mrb: *mrb_state, cla: *RObject, name: [*:0]const u8, func: mrb_func_t, aspec: mrb_aspec) void;
pub extern fn mrb_define_module_function(mrb: *mrb_state, cla: *RClass, name: [*:0]const u8, func: mrb_func_t, aspec: mrb_aspec) void;
pub extern fn mrb_define_const(mrb: *mrb_state, cla: *RClass, name: [*:0]const u8, val: mrb_value) void;
pub extern fn mrb_define_global_const(mrb: *mrb_state, name: [*:0]const u8, val: mrb_value) void;

// ---- method arguments (variadic; see Args in the safe layer) ----------

pub extern fn mrb_get_args(mrb: *mrb_state, format: [*:0]const u8, ...) mrb_int;
pub extern fn mrb_get_args_a(mrb: *mrb_state, format: [*:0]const u8, args: [*]?*anyopaque) mrb_int;

// ---- calling ----------------------------------------------------------

pub extern fn mrb_funcall(mrb: *mrb_state, val: mrb_value, name: [*:0]const u8, argc: mrb_int, ...) mrb_value;
pub extern fn mrb_funcall_argv(mrb: *mrb_state, val: mrb_value, name: mrb_sym, argc: mrb_int, argv: [*]const mrb_value) mrb_value;
pub extern fn mrb_yield(mrb: *mrb_state, b: mrb_value, arg: mrb_value) mrb_value;
pub extern fn mrb_yield_argv(mrb: *mrb_state, b: mrb_value, argc: mrb_int, argv: [*]const mrb_value) mrb_value;
pub extern fn mrb_top_self(mrb: *mrb_state) mrb_value;

// ---- symbols ----------------------------------------------------------

pub extern fn mrb_intern(mrb: *mrb_state, s: [*]const u8, len: usize) mrb_sym;
pub extern fn mrb_intern_cstr(mrb: *mrb_state, s: [*:0]const u8) mrb_sym;
pub extern fn mrb_sym_name_len(mrb: *mrb_state, sym: mrb_sym, lenp: ?*mrb_int) ?[*]const u8;

// ---- strings ----------------------------------------------------------

pub extern fn mrb_str_new(mrb: *mrb_state, p: ?[*]const u8, len: mrb_int) mrb_value;
pub extern fn mrb_str_new_cstr(mrb: *mrb_state, s: [*:0]const u8) mrb_value;
pub extern fn mrb_str_new_static(mrb: *mrb_state, p: [*]const u8, len: mrb_int) mrb_value;

// ---- arrays -----------------------------------------------------------

pub extern fn mrb_ary_new(mrb: *mrb_state) mrb_value;
pub extern fn mrb_ary_push(mrb: *mrb_state, ary: mrb_value, val: mrb_value) void;
pub extern fn mrb_ary_entry(ary: mrb_value, offset: mrb_int) mrb_value;
pub extern fn mrb_ary_set(mrb: *mrb_state, ary: mrb_value, n: mrb_int, val: mrb_value) void;

// ---- hashes -----------------------------------------------------------

pub extern fn mrb_hash_new(mrb: *mrb_state) mrb_value;
pub extern fn mrb_hash_set(mrb: *mrb_state, hash: mrb_value, key: mrb_value, val: mrb_value) void;
pub extern fn mrb_hash_get(mrb: *mrb_state, hash: mrb_value, key: mrb_value) mrb_value;
pub extern fn mrb_hash_fetch(mrb: *mrb_state, hash: mrb_value, key: mrb_value, def: mrb_value) mrb_value;
pub extern fn mrb_hash_keys(mrb: *mrb_state, hash: mrb_value) mrb_value;
pub extern fn mrb_hash_size(mrb: *mrb_state, hash: mrb_value) mrb_int;

// ---- variables --------------------------------------------------------

pub extern fn mrb_iv_get(mrb: *mrb_state, obj: mrb_value, sym: mrb_sym) mrb_value;
pub extern fn mrb_iv_set(mrb: *mrb_state, obj: mrb_value, sym: mrb_sym, v: mrb_value) void;
pub extern fn mrb_gv_get(mrb: *mrb_state, sym: mrb_sym) mrb_value;
pub extern fn mrb_gv_set(mrb: *mrb_state, sym: mrb_sym, val: mrb_value) void;
pub extern fn mrb_mod_cv_set(mrb: *mrb_state, c: *RClass, sym: mrb_sym, v: mrb_value) void;

// ---- wrapping Zig data in Ruby objects --------------------------------

pub extern fn mrb_data_object_alloc(mrb: *mrb_state, klass: *RClass, datap: ?*anyopaque, dt: *const mrb_data_type) *RData;
pub extern fn mrb_data_get_ptr(mrb: *mrb_state, obj: mrb_value, dt: *const mrb_data_type) ?*anyopaque;
pub extern fn mrb_data_check_get_ptr(mrb: *mrb_state, obj: mrb_value, dt: *const mrb_data_type) ?*anyopaque;
pub extern fn mrb_class_get_under(mrb: *mrb_state, outer: *RClass, name: [*:0]const u8) *RClass;
pub extern fn mrb_const_get(mrb: *mrb_state, outer: mrb_value, sym: mrb_sym) mrb_value;

// ---- exceptions -------------------------------------------------------

pub extern fn mrb_exc_raise(mrb: *mrb_state, exc: mrb_value) noreturn;
pub extern fn mrb_print_error(mrb: *mrb_state) void;
pub extern fn mrb_print_backtrace(mrb: *mrb_state) void;
pub extern fn mrb_protect_error(mrb: *mrb_state, body: *const fn (*mrb_state, ?*anyopaque) callconv(.c) mrb_value, userdata: ?*anyopaque, error_out: ?*bool) mrb_value;

// ---- misc -------------------------------------------------------------

pub extern fn mrb_obj_freeze(mrb: *mrb_state, obj: mrb_value) mrb_value;

// ---- shim (src/shim.c): layout-safe accessors -------------------------

pub extern fn mrz_gc_arena_save(mrb: *mrb_state) c_int;
pub extern fn mrz_gc_arena_restore(mrb: *mrb_state, idx: c_int) void;
pub extern fn mrz_exc_value(mrb: *mrb_state) mrb_value;
pub extern fn mrz_exc_clear(mrb: *mrb_state) void;
pub extern fn mrz_exc_set(mrb: *mrb_state, exc: mrb_value) void;
pub extern fn mrz_set_instance_tt(cls: *RClass, tt: mrb_vtype) void;

pub extern fn mrz_type(v: mrb_value) mrb_vtype;
pub extern fn mrz_nil_p(v: mrb_value) bool;
pub extern fn mrz_true_p(v: mrb_value) bool;
pub extern fn mrz_false_p(v: mrb_value) bool;
pub extern fn mrz_undef_p(v: mrb_value) bool;
pub extern fn mrz_test(v: mrb_value) bool;
pub extern fn mrz_integer_p(v: mrb_value) bool;
pub extern fn mrz_float_p(v: mrb_value) bool;
pub extern fn mrz_symbol_p(v: mrb_value) bool;
pub extern fn mrz_string_p(v: mrb_value) bool;
pub extern fn mrz_array_p(v: mrb_value) bool;
pub extern fn mrz_hash_p(v: mrb_value) bool;
pub extern fn mrz_proc_p(v: mrb_value) bool;
pub extern fn mrz_exception_p(v: mrb_value) bool;
pub extern fn mrz_data_p(v: mrb_value) bool;
pub extern fn mrz_class_p(v: mrb_value) bool;
pub extern fn mrz_module_p(v: mrb_value) bool;

pub extern fn mrz_integer(v: mrb_value) mrb_int;
pub extern fn mrz_float_v(v: mrb_value) mrb_float;
pub extern fn mrz_symbol(v: mrb_value) mrb_sym;
pub extern fn mrz_ptr(v: mrb_value) ?*anyopaque;

pub extern fn mrz_string_ptr(v: mrb_value) ?[*]const u8;
pub extern fn mrz_string_len(v: mrb_value) mrb_int;

pub extern fn mrz_nil_value() mrb_value;
pub extern fn mrz_false_value() mrb_value;
pub extern fn mrz_true_value() mrb_value;
pub extern fn mrz_bool_value(b: bool) mrb_value;
pub extern fn mrz_int_value(mrb: *mrb_state, i: mrb_int) mrb_value;
pub extern fn mrz_float_value(mrb: *mrb_state, f: mrb_float) mrb_value;
pub extern fn mrz_sym_value(s: mrb_sym) mrb_value;
pub extern fn mrz_obj_value(p: *anyopaque) mrb_value;
pub extern fn mrz_cptr_value(mrb: *mrb_state, p: *anyopaque) mrb_value;
