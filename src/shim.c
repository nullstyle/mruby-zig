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
#include <mruby/string.h>
#include <mruby/proc.h>
#include <mruby/compile.h>

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
