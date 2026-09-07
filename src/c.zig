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

comptime {
    // The handwritten mrb_value/mrb_int ABI below intentionally targets the
    // package's supported 64-bit word-boxing configuration. Failing clearly
    // is safer than silently truncating StateCapsule integers on 32-bit mruby.
    if (@bitSizeOf(usize) != 64) {
        @compileError("mruby-zig currently requires a 64-bit target");
    }
}

pub const mrb_int = i64;
/// Binary64 shim transport type; integer64 builds reject Float construction.
pub const mrb_float = f64;
pub const mrb_sym = u32;
pub const mrb_bool = bool;
pub const mrb_aspec = u32;
pub const mrb_vtype = c_int;

/// Present only in the strict native build. Call sites must be comptime-gated.
pub const DiagnosticSource = extern struct {
    line: u32 = 0,
    file_len: u32 = 0,
    method_len: u32 = 0,
    truncated: u32 = 0,
    file: [256]u8 = @splat(0),
    method: [96]u8 = @splat(0),

    pub fn fileName(self: *const DiagnosticSource) []const u8 {
        return self.file[0..self.file_len];
    }
    pub fn methodName(self: *const DiagnosticSource) []const u8 {
        return self.method[0..self.method_len];
    }
};
pub extern fn mrz_diagnostic_source_current(mrb: *mrb_state, out: *DiagnosticSource) bool;
pub extern fn mrz_diagnostic_source_exception(mrb: *mrb_state, exc: mrb_value, out: *DiagnosticSource) bool;

/// Present only in the strict native build. Call sites must be comptime-gated.
pub const StrictDiagnostic = extern struct {
    reason: u32,
    name_len: u32,
    name: [96]u8,
    source: DiagnosticSource = .{},
};
pub extern fn mrz_strict_begin_attempt(mrb: *mrb_state) bool;
pub extern fn mrz_strict_end_attempt(mrb: *mrb_state) void;
pub extern fn mrz_strict_violation(mrb: *mrb_state, out: *StrictDiagnostic) bool;
pub extern fn mrz_strict_approve_method(mrb: *mrb_state, klass: *RClass, name: [*]const u8, length: usize, kind: u8) bool;
pub extern fn mrz_strict_approve_data_type(mrb: *mrb_state, data_type: *const mrb_data_type) bool;

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
pub extern fn mrb_gc_register(mrb: *mrb_state, obj: mrb_value) void;
pub extern fn mrb_full_gc(mrb: *mrb_state) void;
pub extern fn mrb_incremental_gc(mrb: *mrb_state) void;

// ---- compile / eval ---------------------------------------------------

pub extern fn mrb_load_string(mrb: *mrb_state, s: [*:0]const u8) mrb_value;
pub extern fn mrb_load_nstring(mrb: *mrb_state, s: [*]const u8, len: usize) mrb_value;
pub extern fn mrb_ccontext_new(mrb: *mrb_state) ?*mrb_ccontext;
pub extern fn mrb_ccontext_free(mrb: *mrb_state, context: *mrb_ccontext) void;
pub extern fn mrb_ccontext_filename(mrb: *mrb_state, context: *mrb_ccontext, filename: [*:0]const u8) ?[*:0]const u8;

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

pub const mrz_exception_metadata = extern struct {
    message: mrb_value,
    class_name: mrb_value,
};
pub extern fn mrz_error_root_new(mrb: *mrb_state) mrb_value;
pub extern fn mrz_error_capture(mrb: *mrb_state, root: mrb_value, exc: mrb_value, out: *mrz_exception_metadata) bool;
pub extern fn mrz_error_release(mrb: *mrb_state, root: mrb_value) bool;
pub extern fn mrz_policy_exceptions_new(mrb: *mrb_state, hidden: *RClass) mrb_value;

// ---- protected public operations ---------------------------------------

/// These wrappers keep mruby's setjmp/longjmp inside C and restore a raised
/// exception to `mrb->exc`. `false` therefore maps to `error.RubyException`.
pub extern fn mrz_protected_gc_register(mrb: *mrb_state, value: mrb_value) bool;
pub extern fn mrz_gc_unregister(mrb: *mrb_state, value: mrb_value) void;
pub extern fn mrz_protected_load_string(
    mrb: *mrb_state,
    source: [*:0]const u8,
    source_length: usize,
    source_name: ?[*]const u8,
    source_name_length: usize,
    out: *mrb_value,
) bool;
pub extern fn mrz_protected_load_irep(
    mrb: *mrb_state,
    bytes: [*]const u8,
    length: usize,
    out: *mrb_value,
) bool;
pub extern fn mrz_protected_funcall(
    mrb: *mrb_state,
    receiver: mrb_value,
    name: [*]const u8,
    name_length: usize,
    argc: mrb_int,
    argv: [*]const mrb_value,
    out: *mrb_value,
) bool;
pub extern fn mrz_protected_funcall_with_block(
    mrb: *mrb_state,
    receiver: mrb_value,
    name: [*]const u8,
    name_length: usize,
    argc: mrb_int,
    argv: [*]const mrb_value,
    block: mrb_value,
    out: *mrb_value,
) bool;
pub extern fn mrz_protected_funcall_preserve_error(
    mrb: *mrb_state,
    receiver: mrb_value,
    name: [*]const u8,
    name_length: usize,
    out: *mrb_value,
) bool;
pub extern fn mrz_protected_print_error(mrb: *mrb_state) void;
pub extern fn mrz_protected_string(
    mrb: *mrb_state,
    bytes: ?[*]const u8,
    length: usize,
    out: *mrb_value,
) bool;
pub extern fn mrz_protected_integer(
    mrb: *mrb_state,
    integer: mrb_int,
    out: *mrb_value,
) bool;
pub extern fn mrz_protected_float(
    mrb: *mrb_state,
    floating: mrb_float,
    out: *mrb_value,
) bool;
pub extern fn mrz_protected_array_new(
    mrb: *mrb_state,
    values: ?[*]const mrb_value,
    length: usize,
    out: *mrb_value,
) bool;
pub extern fn mrz_protected_array_get(
    mrb: *mrb_state,
    array: mrb_value,
    index: mrb_int,
    out: *mrb_value,
) bool;
pub extern fn mrz_protected_array_set(
    mrb: *mrb_state,
    array: mrb_value,
    index: mrb_int,
    value: mrb_value,
) bool;
pub extern fn mrz_protected_array_push(
    mrb: *mrb_state,
    array: mrb_value,
    value: mrb_value,
) bool;
pub const mrz_hash_entry = extern struct {
    key: mrb_value,
    value: mrb_value,
};
pub extern fn mrz_protected_hash_new(
    mrb: *mrb_state,
    entries: ?[*]const mrz_hash_entry,
    length: usize,
    out: *mrb_value,
) bool;
pub extern fn mrz_protected_hash_get(
    mrb: *mrb_state,
    hash: mrb_value,
    key: mrb_value,
    found: *bool,
    out: *mrb_value,
) bool;
pub extern fn mrz_protected_hash_set(
    mrb: *mrb_state,
    hash: mrb_value,
    key: mrb_value,
    value: mrb_value,
) bool;
pub extern fn mrz_protected_hash_keys(
    mrb: *mrb_state,
    hash: mrb_value,
    out: *mrb_value,
) bool;
pub extern fn mrz_protected_intern(
    mrb: *mrb_state,
    name: [*]const u8,
    length: usize,
    out: *mrb_sym,
) bool;
pub const MRZ_DEFINE_CLASS: u8 = 0;
pub const MRZ_DEFINE_MODULE: u8 = 1;
pub extern fn mrz_protected_define(
    mrb: *mrb_state,
    name: [*]const u8,
    name_length: usize,
    super: ?*RClass,
    kind: u8,
    out: *mrb_value,
) bool;
pub extern fn mrz_protected_define_under(
    mrb: *mrb_state,
    outer: *RClass,
    name: [*]const u8,
    name_length: usize,
    super: ?*RClass,
    kind: u8,
    out: *mrb_value,
) bool;
pub extern fn mrz_protected_lookup(
    mrb: *mrb_state,
    name: [*]const u8,
    length: usize,
    out: *mrb_value,
) bool;
pub extern fn mrz_protected_const_get(
    mrb: *mrb_state,
    outer: *RClass,
    name: [*]const u8,
    length: usize,
    found: *bool,
    out: *mrb_value,
) bool;
pub extern fn mrz_protected_global_get(
    mrb: *mrb_state,
    name: [*]const u8,
    length: usize,
    out: *mrb_value,
) bool;
pub extern fn mrz_protected_global_set(
    mrb: *mrb_state,
    name: [*]const u8,
    length: usize,
    value: mrb_value,
) bool;
pub extern fn mrz_protected_ivar_get(
    mrb: *mrb_state,
    object: mrb_value,
    name: [*]const u8,
    length: usize,
    out: *mrb_value,
) bool;
pub extern fn mrz_protected_ivar_set(
    mrb: *mrb_state,
    object: mrb_value,
    name: [*]const u8,
    length: usize,
    value: mrb_value,
) bool;
pub extern fn mrz_protected_define_const(
    mrb: *mrb_state,
    class: *RClass,
    name: [*]const u8,
    name_length: usize,
    value: mrb_value,
) bool;
pub const MRZ_METHOD_INSTANCE: u8 = 0;
pub const MRZ_METHOD_CLASS: u8 = 1;
pub const MRZ_METHOD_MODULE_FUNCTION: u8 = 2;
pub extern fn mrz_protected_define_method(
    mrb: *mrb_state,
    class: *RClass,
    name: [*]const u8,
    name_length: usize,
    function: mrb_func_t,
    aspec: mrb_aspec,
    kind: u8,
) bool;
pub extern fn mrz_protected_data(
    mrb: *mrb_state,
    class: *RClass,
    pointer: ?*anyopaque,
    data_type: *const mrb_data_type,
    out: *mrb_value,
) bool;
pub extern fn mrz_protected_get_args(
    mrb: *mrb_state,
    format: [*:0]const u8,
    slots: [*]?*anyopaque,
    out: *mrb_int,
) bool;
pub extern fn mrz_protected_set_exception(
    mrb: *mrb_state,
    class_name: [*]const u8,
    class_name_length: usize,
    message: ?[*]const u8,
    message_length: usize,
) bool;
/// Set Effect::Rejected using a saved class and inert [code, message] payload.
/// Never dispatches guest exception constructors; all raising work stays in C.
pub extern fn mrz_protected_effect_rejection(
    mrb: *mrb_state,
    class: *RClass,
    payload: mrb_value,
) bool;
/// Install an undefined method-table entry without lookup or Ruby hook
/// dispatch. This is the sandbox's policy-enforcement primitive, not Ruby's
/// observable `undef_method` operation.
pub const MRZ_MASK_INSTANCE: u8 = 0;
pub const MRZ_MASK_CLASS: u8 = 1;
pub extern fn mrz_protected_mask_method(
    mrb: *mrb_state,
    class: *RClass,
    name: [*]const u8,
    name_length: usize,
    kind: u8,
) bool;
pub extern fn mrz_protected_remove_const(
    mrb: *mrb_state,
    class: *RClass,
    name: [*]const u8,
    name_length: usize,
) bool;
pub extern fn mrz_protected_freeze(
    mrb: *mrb_state,
    value: mrb_value,
) bool;

pub const mrz_sandbox_bootstrap = extern struct {
    hidden: ?*RClass,
    error_root: mrb_value,
    policy_exceptions: mrb_value,
    random_srand: ?mrb_func_t,
};
pub extern fn mrz_protected_sandbox_bootstrap(
    mrb: *mrb_state,
    out: *mrz_sandbox_bootstrap,
) bool;

pub extern fn mrz_protected_random_seed(
    mrb: *mrb_state,
    reseed: mrb_func_t,
    seed: u32,
) bool;

pub const MRZ_COMPILE_OK: u8 = 0;
pub const MRZ_COMPILE_FAILED: u8 = 1;
pub const MRZ_COMPILE_OUT_OF_MEMORY: u8 = 2;
pub extern fn mrz_protected_compile(
    mrb: *mrb_state,
    source: [*]const u8,
    source_length: usize,
    source_name: ?[*:0]const u8,
    dump_flags: u8,
    out_bytes: *?[*]u8,
    out_length: *usize,
) u8;

// ---- misc -------------------------------------------------------------

pub extern fn mrb_obj_freeze(mrb: *mrb_state, obj: mrb_value) mrb_value;
pub extern fn mrb_undef_method(mrb: *mrb_state, cla: *RClass, name: [*:0]const u8) void;
pub extern fn mrb_undef_class_method(mrb: *mrb_state, cla: *RClass, name: [*:0]const u8) void;
pub extern fn mrb_const_remove(mrb: *mrb_state, mod: *RClass, sym: mrb_sym) void;
pub const MRB_DUMP_DEBUG_INFO: u8 = 1;
pub extern fn mrb_dump_irep(mrb: *mrb_state, irep: ?*const anyopaque, flags: u8, bin: *?[*]u8, bin_size: *usize) c_int;
pub extern fn mrb_load_irep_buf(mrb: *mrb_state, buf: [*]const u8, size: usize) mrb_value;

// ---- shim (src/shim.c): layout-safe accessors -------------------------

pub extern fn mrz_gc_arena_save(mrb: *mrb_state) c_int;
pub extern fn mrz_gc_arena_restore(mrb: *mrb_state, idx: c_int) void;
pub extern fn mrz_exc_value(mrb: *mrb_state) mrb_value;
pub extern fn mrz_exc_clear(mrb: *mrb_state) void;
pub extern fn mrz_exc_set(mrb: *mrb_state, exc: mrb_value) void;
pub extern fn mrz_set_instance_tt(cls: *RClass, tt: mrb_vtype) void;
pub const mrz_code_fetch_observer = *const fn (
    ?*mrb_state,
    ?*const anyopaque,
    ?*const anyopaque,
    ?*anyopaque,
) callconv(.c) mrb_value;
pub const mrz_sandbox_context = extern struct {
    userdata: ?*anyopaque,
    observer: mrz_code_fetch_observer,
};
pub extern fn mrz_set_sandbox_context(
    mrb: *mrb_state,
    context: ?*mrz_sandbox_context,
) void;
pub extern fn mrz_ci_depth(mrb: *mrb_state) c_int;
pub extern fn mrz_pc_catchable(irep: ?*const anyopaque, pc: ?*const anyopaque) c_int;
pub extern fn mrz_get_ud(mrb: *mrb_state) ?*anyopaque;
pub extern fn mrz_proc_irep(proc: *const anyopaque) ?*const anyopaque;
pub extern fn mrz_parse_nerr(p: ?*const anyopaque) c_int;
pub extern fn mrb_parse_nstring(mrb: *mrb_state, s: [*]const u8, len: usize, cxt: ?*mrb_ccontext) ?*anyopaque;
pub extern fn mrb_parser_free(p: ?*anyopaque) void;
pub extern fn mrb_generate_code(mrb: *mrb_state, p: ?*anyopaque) ?*anyopaque;
pub extern fn mrz_gc_live(mrb: *mrb_state) usize;

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
pub extern fn mrz_array_len(v: mrb_value) usize;

pub extern fn mrz_nil_value() mrb_value;
pub extern fn mrz_false_value() mrb_value;
pub extern fn mrz_true_value() mrb_value;
pub extern fn mrz_bool_value(b: bool) mrb_value;
pub extern fn mrz_int_value(mrb: *mrb_state, i: mrb_int) mrb_value;
pub extern fn mrz_float_value(mrb: *mrb_state, f: mrb_float) mrb_value;
pub extern fn mrz_sym_value(s: mrb_sym) mrb_value;
pub extern fn mrz_obj_value(p: *anyopaque) mrb_value;
pub extern fn mrz_cptr_value(mrb: *mrb_state, p: *anyopaque) mrb_value;

// ---- artifact graph inspection / materialization ----------------------

/// Exact-core container classifications. A subclass or an object with a
/// singleton class is intentionally reported as unsupported.
pub const MRZ_ARTIFACT_NODE_UNSUPPORTED: u8 = 0;
pub const MRZ_ARTIFACT_NODE_STRING: u8 = 1;
pub const MRZ_ARTIFACT_NODE_ARRAY: u8 = 2;
pub const MRZ_ARTIFACT_NODE_HASH: u8 = 3;

pub const mrz_artifact_pair = extern struct {
    key: mrb_value,
    value: mrb_value,
};

pub const mrz_artifact_hash_state = extern struct {
    has_default: u8,
    has_default_proc: u8,
    has_extra_ivars: u8,
    reserved: u8,
    default_value: mrb_value,
};

pub extern fn mrz_artifact_container_kind(mrb: *mrb_state, value: mrb_value) u8;
pub extern fn mrz_artifact_frozen_p(value: mrb_value) bool;
/// Copy the exact binary64 representation without routing heap NaNs through
/// a floating-point expression that may canonicalize their payload bits.
pub extern fn mrz_artifact_float_bits(value: mrb_value, out: *u64) bool;
pub extern fn mrz_artifact_identity(value: mrb_value) ?*anyopaque;
pub extern fn mrz_artifact_array_len(value: mrb_value) usize;
pub extern fn mrz_artifact_array_ptr(value: mrb_value) ?[*]const mrb_value;
pub extern fn mrz_artifact_hash_len(value: mrb_value) usize;
pub extern fn mrz_artifact_hash_copy_pairs(
    mrb: *mrb_state,
    value: mrb_value,
    pairs: ?[*]mrz_artifact_pair,
    capacity: usize,
) bool;
pub extern fn mrz_artifact_hash_state_get(
    mrb: *mrb_state,
    value: mrb_value,
    out: *mrz_artifact_hash_state,
) bool;
pub extern fn mrz_artifact_has_extra_ivars(mrb: *mrb_state, value: mrb_value) bool;

pub const MRZ_ARTIFACT_REF_NIL: u8 = 0;
pub const MRZ_ARTIFACT_REF_FALSE: u8 = 1;
pub const MRZ_ARTIFACT_REF_TRUE: u8 = 2;
pub const MRZ_ARTIFACT_REF_I64: u8 = 3;
pub const MRZ_ARTIFACT_REF_F64: u8 = 4;
pub const MRZ_ARTIFACT_REF_SYMBOL: u8 = 5;
pub const MRZ_ARTIFACT_REF_NODE: u8 = 6;

pub const MRZ_ARTIFACT_NODE_FROZEN: u8 = 1;
pub const MRZ_ARTIFACT_HASH_HAS_DEFAULT: u8 = 2;

pub const mrz_artifact_ref = extern struct {
    tag: u8,
    reserved: [3]u8,
    /// Non-zero only for symbol byte references.
    length: u32,
    /// Signed integer bits, binary64 bits, node ID, or symbol byte pointer.
    payload: u64,
};

/// Node array order is the zero-based object ID. Array edges are elements;
/// Hash edges are key/value pairs followed by an optional default edge.
pub const mrz_artifact_node = extern struct {
    kind: u8,
    flags: u8,
    reserved: u16,
    edge_offset: u32,
    edge_count: u32,
    bytes_ptr: ?[*]const u8,
    bytes_len: u32,
};

pub const mrz_artifact_graph = extern struct {
    nodes: ?[*]const mrz_artifact_node,
    edges: ?[*]const mrz_artifact_ref,
    node_count: u32,
    edge_count: u32,
    root: mrz_artifact_ref,
};

pub const MRZ_ARTIFACT_MATERIALIZE_OK: u32 = 0;
pub const MRZ_ARTIFACT_MATERIALIZE_INVALID: u32 = 1;
pub const MRZ_ARTIFACT_MATERIALIZE_OOM: u32 = 2;
pub const MRZ_ARTIFACT_MATERIALIZE_UNEXPECTED: u32 = 3;

pub const mrz_artifact_materialize_result = extern struct {
    value: mrb_value,
    status: u32,
    /// Successful heap roots leave one arena slot; immediate roots leave zero.
    arena_roots: u32,
};

comptime {
    // Keep the hand-written normalized graph ABI synchronized with shim.c.
    // This package intentionally rejects non-64-bit targets above, so these
    // sizes and offsets are part of the supported C/Zig boundary.
    if (@sizeOf(mrz_artifact_pair) != 16 or
        @sizeOf(mrz_artifact_hash_state) != 16 or
        @offsetOf(mrz_artifact_hash_state, "default_value") != 8 or
        @sizeOf(mrz_artifact_ref) != 16 or
        @offsetOf(mrz_artifact_ref, "length") != 4 or
        @offsetOf(mrz_artifact_ref, "payload") != 8 or
        @sizeOf(mrz_artifact_node) != 32 or
        @offsetOf(mrz_artifact_node, "edge_offset") != 4 or
        @offsetOf(mrz_artifact_node, "bytes_ptr") != 16 or
        @offsetOf(mrz_artifact_node, "bytes_len") != 24 or
        @sizeOf(mrz_artifact_graph) != 40 or
        @offsetOf(mrz_artifact_graph, "root") != 24 or
        @sizeOf(mrz_artifact_materialize_result) != 16)
    {
        @compileError("StateCapsule C/Zig normalized graph ABI drifted");
    }
}

/// Materialize a fully normalized graph in one C protection frame. On any
/// failure the entry arena is restored and mrb->exc is clear, so no mruby
/// longjmp can cross a live Zig frame.
pub extern fn mrz_artifact_materialize(
    mrb: *mrb_state,
    graph: *const mrz_artifact_graph,
    out: *mrz_artifact_materialize_result,
) void;
