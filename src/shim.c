/*
** shim.c - mruby-zig ABI shim
**
** mruby exposes several core operations only as macros or inline functions
** over struct layouts that Zig cannot represent (C bitfields in object
** headers, mrb_state internals). This shim compiles inside libmruby with
** the real headers and re-exports those operations as plain functions,
** keeping every layout decision on the C side where the macros live.
**
** The Zig side (src/c.zig) declares mrb_state as an opaque type and only
** uses these mrz_* entry points for anything layout-sensitive.
*/

#include <mruby.h>
#include <mruby/irep.h>
#include <mruby/internal.h>
#include <mruby/class.h>
#include <mruby/error.h>
#include <mruby/array.h>
#include <mruby/string.h>
#include <mruby/proc.h>
#include <mruby/compile.h>
#include <mruby/variable.h>
#include <string.h>

/* ---- GC arena (macros over mrb->gc.arena_idx) ---- */

int mrz_gc_arena_save(mrb_state *mrb) { return mrb_gc_arena_save(mrb); }
void mrz_gc_arena_restore(mrb_state *mrb, int idx) { mrb_gc_arena_restore(mrb, idx); }

/* ---- exceptions (mrb->exc field access) ---- */

mrb_value mrz_exc_value(mrb_state *mrb) {
  return mrb->exc ? mrb_obj_value(mrb->exc) : mrb_nil_value();
}
void mrz_exc_clear(mrb_state *mrb) { mrb->exc = NULL; }
void mrz_exc_set(mrb_state *mrb, mrb_value exc) {
  if (mrb_immediate_p(exc)) return; /* not a heap object */
  mrb->exc = mrb_obj_ptr(exc);
}

struct mrz_exception_metadata {
  mrb_value message;
  mrb_value class_name;
};

/* One private fixed-size root. Its class is cleared so ObjectSpace cannot
 * expose, freeze, share, or resize it. */
mrb_value mrz_error_root_new(mrb_state *mrb) {
  mrb_value nil = mrb_nil_value();
  mrb_value root = mrb_ary_new_from_values(mrb, 1, &nil);
  mrb_obj_ptr(root)->c = NULL;
  mrb_gc_register(mrb, root);
  return root;
}

static mrb_bool error_root_store(mrb_state *mrb, mrb_value root,
                                 mrb_value value) {
  if (!mrb_array_p(root)) return FALSE;
  struct RArray *array = mrb_ary_ptr(root);
  if (array->c != NULL || ARY_LEN(array) != 1 ||
      ARY_SHARED_P(array) || mrb_frozen_p(array)) return FALSE;
  ARY_PTR(array)[0] = value;
  mrb_field_write_barrier_value(mrb, (struct RBasic*)array, value);
  return TRUE;
}

/* Root an exception, then read its normalized message and cached real-class
 * name without method dispatch, allocation, or a raising operation. */
mrb_bool mrz_error_capture(mrb_state *mrb, mrb_value root, mrb_value exc,
                           struct mrz_exception_metadata *out) {
  if (out == NULL || !mrb_exception_p(exc) ||
      !error_root_store(mrb, root, exc)) return FALSE;

  out->class_name = mrb_nil_value();
  struct RClass *klass = mrb_obj_class(mrb, exc);
  if (klass != NULL) {
    mrb_value name = mrb_obj_iv_get(mrb, (struct RObject*)klass,
                                    MRB_SYM(__classname__));
    if (mrb_symbol_p(name) || mrb_string_p(name)) out->class_name = name;
  }

  out->message = mrb_nil_value();
  struct RException *exception = mrb_exc_ptr(exc);
  if (exception->mesg != NULL) {
    mrb_value message = mrb_obj_value(exception->mesg);
    if (mrb_string_p(message)) out->message = message;
  }
  return TRUE;
}

mrb_bool mrz_error_release(mrb_state *mrb, mrb_value root) {
  return error_root_store(mrb, root, mrb_nil_value());
}

/* Preallocate the five private policy exceptions so hook-time delivery is
 * allocation-free and cannot dispatch a guest-overridden `.exception`. */
mrb_value mrz_policy_exceptions_new(mrb_state *mrb, struct RClass *hidden) {
  static const char *names[] = {
    "ScriptTerminated", "DeadlineExceeded", "GasExhausted",
    "MemoryLimitExceeded", "CallDepthExceeded"
  };
  static const char *messages[] = {
    "mruby-zig sandbox: ScriptTerminated",
    "mruby-zig sandbox: DeadlineExceeded",
    "mruby-zig sandbox: GasExhausted",
    "mruby-zig sandbox: MemoryLimitExceeded",
    "mruby-zig sandbox: CallDepthExceeded"
  };
  mrb_value root = mrb_ary_new_capa(mrb, 5);
  for (mrb_int i = 0; i < 5; ++i) {
    struct RClass *klass = mrb_class_get_under(mrb, hidden, names[i]);
    mrb_value exc = mrb_exc_new(mrb, klass, messages[i],
                                (mrb_int)strlen(messages[i]));
    mrb_obj_freeze(mrb, exc);
    mrb_ary_push(mrb, root, exc);
  }
  mrb_obj_ptr(root)->c = NULL;
  mrb_gc_register(mrb, root);
  return root;
}

/* mrb->ud auxiliary pointer (sandbox backreference) */
void *mrz_get_ud(mrb_state *mrb) { return mrb->ud; }
void mrz_set_ud(mrb_state *mrb, void *ud) { mrb->ud = ud; }

/* irep of an irep-proc (for snapshot dump) */
const mrb_irep *mrz_proc_irep(const struct RProc *p) { return p->body.irep; }

/* parse error count */
int mrz_parse_nerr(const struct mrb_parser_state *p) { return (int)p->nerr; }

/* code fetch hook (only exists under MRB_USE_DEBUG_HOOK, same defines) */
void mrz_set_code_fetch_hook(mrb_state *mrb, void (*hook)(struct mrb_state*, const struct mrb_irep *, const mrb_code *, mrb_value *)) {
  mrb->code_fetch_hook = hook;
}

/* Would an exception raised at this program counter be caught by any
 * catch handler of this irep? Mirrors catch_handler_find's coverage rule
 * (pc must be strictly after begin and at/before end), any handler type. */
int mrz_pc_catchable(const struct mrb_irep *irep, const mrb_code *pc) {
  if (irep == NULL || irep->clen < 1) return 0;
  ptrdiff_t xpc = pc - irep->iseq;
  if (!(xpc > 0 && xpc <= (ptrdiff_t)irep->ilen)) return 0;
  const struct mrb_irep_catch_handler *e = mrb_irep_catch_handler_table(irep);
  for (uint16_t i = 0; i < irep->clen; i++, e++) {
    ptrdiff_t beg = (ptrdiff_t)((uint32_t)e->begin[0] << 24 | (uint32_t)e->begin[1] << 16 | (uint32_t)e->begin[2] << 8 | (uint32_t)e->begin[3]);
    ptrdiff_t end = (ptrdiff_t)((uint32_t)e->end[0] << 24 | (uint32_t)e->end[1] << 16 | (uint32_t)e->end[2] << 8 | (uint32_t)e->end[3]);
    if (xpc > beg && xpc <= end) return 1;
  }
  return 0;
}

/* interpreter call depth: ci - cibase */
int mrz_ci_depth(mrb_state *mrb) {
  return (int)(mrb->c->ci - mrb->c->cibase);
}

/* live object count from the GC */
size_t mrz_gc_live(mrb_state *mrb) {
  return mrb->gc.live;
}

/* instance type of a class (MRB_SET_INSTANCE_TT macro) */
void mrz_set_instance_tt(struct RClass *c, enum mrb_vtype tt) {
  MRB_SET_INSTANCE_TT(c, tt);
}


/* ---- value classification ---- */

enum mrb_vtype mrz_type(mrb_value v) { return mrb_type(v); }
mrb_bool mrz_nil_p(mrb_value v) { return mrb_nil_p(v); }
mrb_bool mrz_true_p(mrb_value v) { return mrb_true_p(v); }
mrb_bool mrz_false_p(mrb_value v) { return mrb_false_p(v); }
mrb_bool mrz_undef_p(mrb_value v) { return mrb_undef_p(v); }
mrb_bool mrz_test(mrb_value v) { return mrb_test(v); }
mrb_bool mrz_integer_p(mrb_value v) { return mrb_integer_p(v); }
mrb_bool mrz_float_p(mrb_value v) { return mrb_float_p(v); }
mrb_bool mrz_symbol_p(mrb_value v) { return mrb_symbol_p(v); }
mrb_bool mrz_string_p(mrb_value v) { return mrb_string_p(v); }
mrb_bool mrz_array_p(mrb_value v) { return mrb_array_p(v); }
mrb_bool mrz_hash_p(mrb_value v) { return mrb_hash_p(v); }
mrb_bool mrz_proc_p(mrb_value v) { return mrb_proc_p(v); }
mrb_bool mrz_exception_p(mrb_value v) { return mrb_exception_p(v); }
mrb_bool mrz_data_p(mrb_value v) { return mrb_data_p(v); }
mrb_bool mrz_class_p(mrb_value v) { return mrb_class_p(v); }
mrb_bool mrz_module_p(mrb_value v) { return mrb_module_p(v); }

/* ---- value decoding ---- */

mrb_int mrz_integer(mrb_value v) { return mrb_integer(v); }
mrb_float mrz_float_v(mrb_value v) { return mrb_float(v); }
mrb_sym mrz_symbol(mrb_value v) { return mrb_symbol(v); }
void *mrz_ptr(mrb_value v) { return mrb_ptr(v); }

/* ---- string contents (RSTRING_* macros; only valid when string_p) ---- */

const char *mrz_string_ptr(mrb_value v) { return RSTRING_PTR(v); }
mrb_int mrz_string_len(mrb_value v) { return RSTRING_LEN(v); }

/* ---- value construction (macros / boxing helpers) ---- */

mrb_value mrz_nil_value(void) { return mrb_nil_value(); }
mrb_value mrz_false_value(void) { return mrb_false_value(); }
mrb_value mrz_true_value(void) { return mrb_true_value(); }
mrb_value mrz_bool_value(mrb_bool b) { return mrb_bool_value(b); }
mrb_value mrz_int_value(mrb_state *mrb, mrb_int i) {
  mrb_value v;
  SET_INT_VALUE(mrb, v, i);
  return v;
}
mrb_value mrz_float_value(mrb_state *mrb, mrb_float f) {
  mrb_value v;
  SET_FLOAT_VALUE(mrb, v, f);
  return v;
}
mrb_value mrz_sym_value(mrb_sym s) {
  mrb_value v;
  SET_SYM_VALUE(v, s);
  return v;
}
mrb_value mrz_obj_value(void *p) {
  mrb_value v;
  SET_OBJ_VALUE(v, p);
  return v;
}
mrb_value mrz_cptr_value(mrb_state *mrb, void *p) {
  mrb_value v;
  SET_CPTR_VALUE(mrb, v, p);
  return v;
}
