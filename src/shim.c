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
#include <mruby/hash.h>
#include <mruby/string.h>
#include <mruby/proc.h>
#include <mruby/compile.h>
#include <mruby/throw.h>
#include <mruby/variable.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

/* ---- GC arena (macros over mrb->gc.arena_idx) ---- */

int mrz_gc_arena_save(mrb_state *mrb) { return mrb_gc_arena_save(mrb); }
void mrz_gc_arena_restore(mrb_state *mrb, int idx) { mrb_gc_arena_restore(mrb, idx); }

/* Test seam for the post-protection OOM path in StateCapsule materialization.
 * Fill every arena slot with an existing live object without allocating; the
 * returned index lets the test restore the caller's arena afterward. */
int mrz_artifact_test_fill_arena(mrb_state *mrb) {
  int previous = mrb->gc.arena_idx;
#ifdef MRB_GC_FIXED_ARENA
  int capacity = MRB_GC_ARENA_SIZE;
#else
  int capacity = mrb->gc.arena_capa;
#endif
  while (mrb->gc.arena_idx < capacity) {
    mrb->gc.arena[mrb->gc.arena_idx++] = (struct RBasic*)mrb->object_class;
  }
  return previous;
}

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

/* ---- inert artifact graph inspection ---------------------------------- */

/* These values intentionally match the stable StateCapsule node tags. */
enum mrz_artifact_node_kind {
  MRZ_ARTIFACT_NODE_UNSUPPORTED = 0,
  MRZ_ARTIFACT_NODE_STRING = 1,
  MRZ_ARTIFACT_NODE_ARRAY = 2,
  MRZ_ARTIFACT_NODE_HASH = 3
};

struct mrz_artifact_pair {
  mrb_value key;
  mrb_value value;
};

struct mrz_artifact_hash_state {
  uint8_t has_default;
  uint8_t has_default_proc;
  uint8_t has_extra_ivars;
  uint8_t reserved;
  mrb_value default_value;
};

/* Compare the direct class pointer rather than mrb_obj_class(), which strips
 * singleton classes. This rejects subclasses and per-object singleton
 * classes without invoking Ruby code. */
uint8_t
mrz_artifact_container_kind(mrb_state *mrb, mrb_value value)
{
  if (mrb_string_p(value) && mrb_basic_ptr(value)->c == mrb->string_class) {
    return MRZ_ARTIFACT_NODE_STRING;
  }
  if (mrb_array_p(value) && mrb_basic_ptr(value)->c == mrb->array_class) {
    return MRZ_ARTIFACT_NODE_ARRAY;
  }
  if (mrb_hash_p(value) && mrb_basic_ptr(value)->c == mrb->hash_class) {
    return MRZ_ARTIFACT_NODE_HASH;
  }
  return MRZ_ARTIFACT_NODE_UNSUPPORTED;
}

mrb_bool
mrz_artifact_frozen_p(mrb_value value)
{
  return !mrb_immediate_p(value) && mrb_frozen_p(mrb_basic_ptr(value));
}

/* StateCapsule's float contract is a raw binary64 bit pattern, including
 * NaN payloads. mruby's ordinary word-boxing constructor deliberately maps
 * every NaN to one inline sentinel, so artifact import uses a heap RFloat and
 * copies its representation without a floating-point conversion. */
mrb_static_assert(sizeof(mrb_float) == sizeof(uint64_t));

mrb_bool
mrz_artifact_float_bits(mrb_value value, uint64_t *out)
{
  if (out == NULL || !mrb_float_p(value)) return FALSE;
#if defined(MRB_WORD_BOXING)
  if (!mrb_immediate_p(value)) {
    union mrb_value_ boxed;
    boxed.value = value;
# if defined(MRB_WORDBOX_NO_INLINE_FLOAT)
    memcpy(out, boxed.fp->f, sizeof(*out));
# else
    memcpy(out, &boxed.fp->f, sizeof(*out));
# endif
    return TRUE;
  }
#endif
  mrb_float floating = mrb_float(value);
  memcpy(out, &floating, sizeof(*out));
  return TRUE;
}

static mrb_value
mrz_artifact_float_from_bits(mrb_state *mrb, uint64_t bits)
{
#if defined(MRB_WORD_BOXING)
  union mrb_value_ boxed;
  boxed.p = mrb_obj_alloc(mrb, MRB_TT_FLOAT, mrb->float_class);
# if defined(MRB_WORDBOX_NO_INLINE_FLOAT)
  memcpy(boxed.fp->f, &bits, sizeof(bits));
# else
  memcpy(&boxed.fp->f, &bits, sizeof(bits));
# endif
  boxed.bp->frozen = 1;
  return boxed.value;
#else
  mrb_float floating;
  memcpy(&floating, &bits, sizeof(bits));
  return mrb_float_value(mrb, floating);
#endif
}

void *
mrz_artifact_identity(mrb_value value)
{
  return mrb_immediate_p(value) ? NULL : mrb_ptr(value);
}

size_t
mrz_artifact_array_len(mrb_value value)
{
  if (!mrb_array_p(value)) return 0;
  return (size_t)RARRAY_LEN(value);
}

const mrb_value *
mrz_artifact_array_ptr(mrb_value value)
{
  if (!mrb_array_p(value) || RARRAY_LEN(value) == 0) return NULL;
  return RARRAY_PTR(value);
}

size_t
mrz_artifact_hash_len(mrb_value value)
{
  if (!mrb_hash_p(value)) return 0;
  return (size_t)mrb_hash_size(NULL, value);
}

struct mrz_hash_copy_context {
  struct mrz_artifact_pair *pairs;
  size_t capacity;
  size_t count;
  mrb_bool overflow;
};

static int
mrz_hash_copy_pair(mrb_state *mrb, mrb_value key, mrb_value value, void *data)
{
  struct mrz_hash_copy_context *context =
    (struct mrz_hash_copy_context*)data;
  (void)mrb;
  if (context->count >= context->capacity) {
    context->overflow = TRUE;
    return 1;
  }
  context->pairs[context->count].key = key;
  context->pairs[context->count].value = value;
  context->count++;
  return 0;
}

mrb_bool
mrz_artifact_hash_copy_pairs(mrb_state *mrb, mrb_value value,
                             struct mrz_artifact_pair *pairs,
                             size_t capacity)
{
  if (!mrb_hash_p(value)) return FALSE;
  size_t expected = (size_t)mrb_hash_size(mrb, value);
  if (expected > capacity || (expected != 0 && pairs == NULL)) return FALSE;

  struct mrz_hash_copy_context context = {
    pairs, capacity, 0, FALSE
  };
  mrb_hash_foreach(mrb, mrb_hash_ptr(value), mrz_hash_copy_pair, &context);
  return !context.overflow && context.count == expected;
}

struct mrz_hash_ivar_context {
  mrb_bool has_extra;
  mrb_bool saw_ifnone;
};

static int
mrz_check_any_ivar(mrb_state *mrb, mrb_sym name, mrb_value value, void *data)
{
  struct mrz_hash_ivar_context *context =
    (struct mrz_hash_ivar_context*)data;
  (void)mrb;
  (void)name;
  (void)value;
  context->has_extra = TRUE;
  return 1;
}

static int
mrz_hash_check_ivar(mrb_state *mrb, mrb_sym name, mrb_value value, void *data)
{
  struct mrz_hash_ivar_context *context =
    (struct mrz_hash_ivar_context*)data;
  (void)mrb;
  (void)value;
  /* @ifnone is Hash's private storage for both default values and procs. */
  if (name == MRB_SYM(ifnone)) {
    context->saw_ifnone = TRUE;
  }
  else {
    context->has_extra = TRUE;
    return 1;
  }
  return 0;
}

mrb_bool
mrz_artifact_hash_state_get(mrb_state *mrb, mrb_value value,
                            struct mrz_artifact_hash_state *out)
{
  if (out == NULL || !mrb_hash_p(value)) return FALSE;

  struct mrz_hash_ivar_context context = { FALSE, FALSE };
  mrb_iv_foreach(mrb, value, mrz_hash_check_ivar, &context);
  out->has_default = MRB_RHASH_DEFAULT_P(value) ? 1 : 0;
  out->has_default_proc = MRB_RHASH_PROCDEFAULT_P(value) ? 1 : 0;
  /* Hash#default=nil and direct @ifnone mutation both leave an observable
   * ivar while clearing (or never setting) the semantic default flag. Do not
   * silently normalize that inconsistent state away. The converse mismatch
   * is invalid for the same reason. */
  out->has_extra_ivars = (context.has_extra ||
                          context.saw_ifnone != (out->has_default != 0))
    ? 1 : 0;
  out->reserved = 0;
  out->default_value = out->has_default
    ? mrb_obj_iv_get(mrb, mrb_obj_ptr(value), MRB_SYM(ifnone))
    : mrb_nil_value();
  return TRUE;
}

mrb_bool
mrz_artifact_has_extra_ivars(mrb_state *mrb, mrb_value value)
{
  struct mrz_hash_ivar_context context = { FALSE, FALSE };
  if (mrb_hash_p(value)) {
    mrb_iv_foreach(mrb, value, mrz_hash_check_ivar, &context);
    if (context.saw_ifnone != (MRB_RHASH_DEFAULT_P(value) != 0)) {
      context.has_extra = TRUE;
    }
  }
  else if (mrb_string_p(value) || mrb_array_p(value)) {
    mrb_iv_foreach(mrb, value, mrz_check_any_ivar, &context);
  }
  return context.has_extra;
}

/* ---- protected StateCapsule materialization ---------------------------- */

enum mrz_artifact_ref_tag {
  MRZ_ARTIFACT_REF_NIL = 0,
  MRZ_ARTIFACT_REF_FALSE = 1,
  MRZ_ARTIFACT_REF_TRUE = 2,
  MRZ_ARTIFACT_REF_I64 = 3,
  MRZ_ARTIFACT_REF_F64 = 4,
  MRZ_ARTIFACT_REF_SYMBOL = 5,
  MRZ_ARTIFACT_REF_NODE = 6
};

enum mrz_artifact_node_flags {
  MRZ_ARTIFACT_NODE_FROZEN = 1,
  MRZ_ARTIFACT_HASH_HAS_DEFAULT = 2
};

enum mrz_artifact_materialize_status {
  MRZ_ARTIFACT_MATERIALIZE_OK = 0,
  MRZ_ARTIFACT_MATERIALIZE_INVALID = 1,
  MRZ_ARTIFACT_MATERIALIZE_OOM = 2,
  MRZ_ARTIFACT_MATERIALIZE_UNEXPECTED = 3
};

/* Normalized, already byte-order-decoded input. Symbol payloads hold a
 * process-local byte pointer cast through uintptr_t; all other payloads are
 * scalar bits or a zero-based node ID. */
struct mrz_artifact_ref {
  uint8_t tag;
  uint8_t reserved[3];
  uint32_t length;
  uint64_t payload;
};

struct mrz_artifact_node {
  uint8_t kind;
  uint8_t flags;
  uint16_t reserved;
  uint32_t edge_offset;
  uint32_t edge_count;
  const uint8_t *bytes_ptr;
  uint32_t bytes_len;
};

struct mrz_artifact_graph {
  const struct mrz_artifact_node *nodes;
  const struct mrz_artifact_ref *edges;
  uint32_t node_count;
  uint32_t edge_count;
  struct mrz_artifact_ref root;
};

struct mrz_artifact_materialize_result {
  mrb_value value;
  uint32_t status;
  uint32_t arena_roots;
};

/* The normalized graph structs are declared manually in src/c.zig. Keep
 * their 64-bit ABI explicit on both sides so a future field edit fails at
 * compile time instead of corrupting imported graphs. */
mrb_static_assert(sizeof(struct mrz_artifact_pair) == 16);
mrb_static_assert(sizeof(struct mrz_artifact_hash_state) == 16);
mrb_static_assert(offsetof(struct mrz_artifact_hash_state, default_value) == 8);
mrb_static_assert(sizeof(struct mrz_artifact_ref) == 16);
mrb_static_assert(offsetof(struct mrz_artifact_ref, length) == 4);
mrb_static_assert(offsetof(struct mrz_artifact_ref, payload) == 8);
mrb_static_assert(sizeof(struct mrz_artifact_node) == 32);
mrb_static_assert(offsetof(struct mrz_artifact_node, edge_offset) == 4);
mrb_static_assert(offsetof(struct mrz_artifact_node, bytes_ptr) == 16);
mrb_static_assert(offsetof(struct mrz_artifact_node, bytes_len) == 24);
mrb_static_assert(sizeof(struct mrz_artifact_graph) == 40);
mrb_static_assert(offsetof(struct mrz_artifact_graph, root) == 24);
mrb_static_assert(sizeof(struct mrz_artifact_materialize_result) == 16);

static mrb_bool
mrz_artifact_ref_valid(const struct mrz_artifact_graph *graph,
                       const struct mrz_artifact_ref *ref)
{
  if (ref->reserved[0] != 0 || ref->reserved[1] != 0 ||
      ref->reserved[2] != 0) return FALSE;

  switch (ref->tag) {
  case MRZ_ARTIFACT_REF_NIL:
  case MRZ_ARTIFACT_REF_FALSE:
  case MRZ_ARTIFACT_REF_TRUE:
    return ref->length == 0 && ref->payload == 0;
  case MRZ_ARTIFACT_REF_I64:
  case MRZ_ARTIFACT_REF_F64:
    return ref->length == 0;
  case MRZ_ARTIFACT_REF_SYMBOL:
    return ref->length == 0 || ref->payload != 0;
  case MRZ_ARTIFACT_REF_NODE:
    return ref->length == 0 && ref->payload < graph->node_count;
  default:
    return FALSE;
  }
}

static mrb_bool
mrz_artifact_hash_key_valid(const struct mrz_artifact_graph *graph,
                            const struct mrz_artifact_ref *ref)
{
  switch (ref->tag) {
  case MRZ_ARTIFACT_REF_I64:
  case MRZ_ARTIFACT_REF_F64:
  case MRZ_ARTIFACT_REF_SYMBOL:
    return TRUE;
  case MRZ_ARTIFACT_REF_NODE: {
    const struct mrz_artifact_node *node = &graph->nodes[ref->payload];
    return node->kind == MRZ_ARTIFACT_NODE_STRING &&
           (node->flags & MRZ_ARTIFACT_NODE_FROZEN) != 0;
  }
  default:
    return FALSE;
  }
}

static mrb_bool
mrz_artifact_graph_valid(const struct mrz_artifact_graph *graph)
{
  if (graph == NULL) return FALSE;
  if (graph->node_count != 0 && graph->nodes == NULL) return FALSE;
  if (graph->edge_count != 0 && graph->edges == NULL) return FALSE;
  if (!mrz_artifact_ref_valid(graph, &graph->root)) return FALSE;

  for (uint32_t i = 0; i < graph->node_count; ++i) {
    const struct mrz_artifact_node *node = &graph->nodes[i];
    uint64_t edge_end = (uint64_t)node->edge_offset + node->edge_count;
    if (node->reserved != 0 || edge_end > graph->edge_count) return FALSE;

    switch (node->kind) {
    case MRZ_ARTIFACT_NODE_STRING:
      if ((node->flags & ~MRZ_ARTIFACT_NODE_FROZEN) != 0 ||
          node->edge_offset != 0 || node->edge_count != 0 ||
          (node->bytes_len != 0 && node->bytes_ptr == NULL)) return FALSE;
      break;
    case MRZ_ARTIFACT_NODE_ARRAY:
      if ((node->flags & ~MRZ_ARTIFACT_NODE_FROZEN) != 0 ||
          node->bytes_ptr != NULL || node->bytes_len != 0) return FALSE;
      break;
    case MRZ_ARTIFACT_NODE_HASH: {
      uint32_t default_edges =
        (node->flags & MRZ_ARTIFACT_HASH_HAS_DEFAULT) ? 1 : 0;
      if ((node->flags & ~(MRZ_ARTIFACT_NODE_FROZEN |
                           MRZ_ARTIFACT_HASH_HAS_DEFAULT)) != 0 ||
          node->bytes_ptr != NULL || node->bytes_len != 0 ||
          node->edge_count < default_edges ||
          ((node->edge_count - default_edges) & 1) != 0) return FALSE;
      break;
    }
    default:
      return FALSE;
    }
  }

  for (uint32_t i = 0; i < graph->edge_count; ++i) {
    if (!mrz_artifact_ref_valid(graph, &graph->edges[i])) return FALSE;
  }

  for (uint32_t i = 0; i < graph->node_count; ++i) {
    const struct mrz_artifact_node *node = &graph->nodes[i];
    if (node->kind != MRZ_ARTIFACT_NODE_HASH) continue;
    uint32_t pair_edges = node->edge_count -
      ((node->flags & MRZ_ARTIFACT_HASH_HAS_DEFAULT) ? 1 : 0);
    for (uint32_t edge = 0; edge < pair_edges; edge += 2) {
      if (!mrz_artifact_hash_key_valid(
            graph, &graph->edges[node->edge_offset + edge])) return FALSE;
    }
  }
  return TRUE;
}

struct mrz_artifact_materialize_context {
  const struct mrz_artifact_graph *graph;
  mrb_value roots;
  mrb_bool invalid;
};

static mrb_value
mrz_artifact_decode_ref(mrb_state *mrb,
                        struct mrz_artifact_materialize_context *context,
                        const struct mrz_artifact_ref *ref)
{
  switch (ref->tag) {
  case MRZ_ARTIFACT_REF_NIL:
    return mrb_nil_value();
  case MRZ_ARTIFACT_REF_FALSE:
    return mrb_false_value();
  case MRZ_ARTIFACT_REF_TRUE:
    return mrb_true_value();
  case MRZ_ARTIFACT_REF_I64: {
    mrb_int integer;
    memcpy(&integer, &ref->payload, sizeof(integer));
    return mrb_int_value(mrb, integer);
  }
  case MRZ_ARTIFACT_REF_F64: {
    return mrz_artifact_float_from_bits(mrb, ref->payload);
  }
  case MRZ_ARTIFACT_REF_SYMBOL: {
    static const char empty[] = "";
    const char *bytes = ref->length == 0
      ? empty
      : (const char*)(uintptr_t)ref->payload;
    return mrb_symbol_value(mrb_intern(mrb, bytes, ref->length));
  }
  case MRZ_ARTIFACT_REF_NODE:
    return mrb_ary_entry(context->roots, (mrb_int)ref->payload);
  default:
    context->invalid = TRUE;
    return mrb_nil_value();
  }
}

static void
mrz_artifact_trim_arena(mrb_state *mrb, int arena,
                        struct mrz_artifact_materialize_context *context)
{
  mrb_gc_arena_restore(mrb, arena);
  mrb_gc_protect(mrb, context->roots);
}

static mrb_value
mrz_artifact_materialize_body(mrb_state *mrb, void *data)
{
  struct mrz_artifact_materialize_context *context =
    (struct mrz_artifact_materialize_context*)data;
  const struct mrz_artifact_graph *graph = context->graph;

  /* An all-scalar graph does not need a temporary Ruby root table. */
  if (graph->node_count == 0) {
    context->roots = mrb_nil_value();
    return mrz_artifact_decode_ref(mrb, context, &graph->root);
  }

  int arena = mrb_gc_arena_save(mrb);
  context->roots = mrb_ary_new_capa(mrb, (mrb_int)graph->node_count);

  /* Allocate every heap shell before resolving edges so cycles and aliases
   * are ordinary table lookups. The private root array is the sole temporary
   * owner after each arena trim. */
  for (uint32_t i = 0; i < graph->node_count; ++i) {
    const struct mrz_artifact_node *node = &graph->nodes[i];
    mrb_value value;
    switch (node->kind) {
    case MRZ_ARTIFACT_NODE_STRING:
      value = mrb_str_new(mrb, (const char*)node->bytes_ptr,
                          (mrb_int)node->bytes_len);
      if ((node->flags & MRZ_ARTIFACT_NODE_FROZEN) != 0) {
        mrb_obj_freeze(mrb, value);
      }
      break;
    case MRZ_ARTIFACT_NODE_ARRAY:
      value = mrb_ary_new_capa(mrb, (mrb_int)node->edge_count);
      break;
    case MRZ_ARTIFACT_NODE_HASH: {
      uint32_t pair_edges = node->edge_count -
        ((node->flags & MRZ_ARTIFACT_HASH_HAS_DEFAULT) ? 1 : 0);
      value = mrb_hash_new_capa(mrb, (mrb_int)(pair_edges / 2));
      break;
    }
    default:
      context->invalid = TRUE;
      return mrb_nil_value();
    }
    mrb_ary_push(mrb, context->roots, value);
    mrz_artifact_trim_arena(mrb, arena, context);
  }

  for (uint32_t i = 0; i < graph->node_count; ++i) {
    const struct mrz_artifact_node *node = &graph->nodes[i];
    mrb_value value = mrb_ary_entry(context->roots, (mrb_int)i);

    if (node->kind == MRZ_ARTIFACT_NODE_ARRAY) {
      for (uint32_t edge = 0; edge < node->edge_count; ++edge) {
        mrb_value child = mrz_artifact_decode_ref(
          mrb, context, &graph->edges[node->edge_offset + edge]);
        if (context->invalid) return mrb_nil_value();
        mrb_ary_push(mrb, value, child);
        mrz_artifact_trim_arena(mrb, arena, context);
      }
    }
    else if (node->kind == MRZ_ARTIFACT_NODE_HASH) {
      uint32_t has_default =
        (node->flags & MRZ_ARTIFACT_HASH_HAS_DEFAULT) ? 1 : 0;
      uint32_t pair_edges = node->edge_count - has_default;
      for (uint32_t edge = 0; edge < pair_edges; edge += 2) {
        mrb_value key = mrz_artifact_decode_ref(
          mrb, context, &graph->edges[node->edge_offset + edge]);
        mrb_value child = mrz_artifact_decode_ref(
          mrb, context, &graph->edges[node->edge_offset + edge + 1]);
        if (context->invalid) return mrb_nil_value();
        mrb_int before = mrb_hash_size(mrb, value);
        mrb_hash_set(mrb, value, key, child);
        if (mrb_hash_size(mrb, value) != before + 1) {
          /* The pure parser rejects semantic duplicates. Keep this guard at
           * the C trust boundary so malformed normalized input cannot be
           * silently collapsed by Hash insertion. */
          context->invalid = TRUE;
          return mrb_nil_value();
        }
        mrz_artifact_trim_arena(mrb, arena, context);
      }
      if (has_default) {
        mrb_value default_value = mrz_artifact_decode_ref(
          mrb, context,
          &graph->edges[node->edge_offset + node->edge_count - 1]);
        if (context->invalid) return mrb_nil_value();
        mrb_iv_set(mrb, value, MRB_SYM(ifnone), default_value);
        RHASH(value)->flags &= ~MRB_HASH_PROC_DEFAULT;
        RHASH(value)->flags |= MRB_HASH_DEFAULT;
        mrz_artifact_trim_arena(mrb, arena, context);
      }
    }

    if (node->kind != MRZ_ARTIFACT_NODE_STRING &&
        (node->flags & MRZ_ARTIFACT_NODE_FROZEN) != 0) {
      mrb_obj_freeze(mrb, value);
    }
  }

  return mrz_artifact_decode_ref(mrb, context, &graph->root);
}

static mrb_bool
mrz_artifact_nomem_exception(mrb_state *mrb, mrb_value exception)
{
  if (mrb_immediate_p(exception)) return FALSE;
  struct RObject *object = mrb_obj_ptr(exception);
  if (object == mrb->nomem_err) return TRUE;
#ifdef MRB_GC_FIXED_ARENA
  if (object == mrb->arena_err) return TRUE;
#endif
  return FALSE;
}

void
mrz_artifact_materialize(mrb_state *mrb,
                         const struct mrz_artifact_graph *graph,
                         struct mrz_artifact_materialize_result *out)
{
  if (out == NULL) return;
  out->value = mrb_nil_value();
  out->status = MRZ_ARTIFACT_MATERIALIZE_INVALID;
  out->arena_roots = 0;
  if (mrb == NULL || !mrz_artifact_graph_valid(graph)) return;

  int entry_arena = mrb_gc_arena_save(mrb);
  struct mrz_artifact_materialize_context context = {
    graph, mrb_nil_value(), FALSE
  };
  mrb_bool raised = FALSE;
  mrb_value result = mrb_nil_value();

  /* mrb_protect_error protects its returned value *after* its internal
   * MRB_TRY. If that final arena growth is refused, a second OOM would
   * otherwise longjmp through the live Zig caller. Keep a C catch frame
   * installed around the complete call, including that postlude. */
  struct mrb_jmpbuf *prev_jmp = mrb->jmp;
  struct mrb_jmpbuf outer_jmp;
  mrb_bool outer_raised = FALSE;
  MRB_TRY(&outer_jmp) {
    mrb->jmp = &outer_jmp;
    result = mrb_protect_error(
      mrb, mrz_artifact_materialize_body, &context, &raised);
    mrb->jmp = prev_jmp;
  }
  MRB_CATCH(&outer_jmp) {
    mrb->jmp = prev_jmp;
    outer_raised = TRUE;
  }
  MRB_END_EXC(&outer_jmp);

  if (outer_raised) {
    mrb_value exception = mrb->exc == NULL
      ? mrb_nil_value()
      : mrb_obj_value(mrb->exc);
    mrb->exc = NULL;
    mrb_gc_arena_restore(mrb, entry_arena);
    out->status = mrz_artifact_nomem_exception(mrb, exception)
      ? MRZ_ARTIFACT_MATERIALIZE_OOM
      : MRZ_ARTIFACT_MATERIALIZE_UNEXPECTED;
    return;
  }

  if (raised || mrb->exc != NULL) {
    mrb_value exception = raised
      ? result
      : mrb_obj_value(mrb->exc);
    mrb->exc = NULL;
    mrb_gc_arena_restore(mrb, entry_arena);
    out->status = mrz_artifact_nomem_exception(mrb, exception)
      ? MRZ_ARTIFACT_MATERIALIZE_OOM
      : MRZ_ARTIFACT_MATERIALIZE_UNEXPECTED;
    return;
  }

  if (context.invalid) {
    /* mrb_protect_error roots a heap result after restoring its own arena.
     * Roll that slot back on all failures. */
    mrb_gc_arena_restore(mrb, entry_arena);
    out->status = MRZ_ARTIFACT_MATERIALIZE_INVALID;
    return;
  }

  out->value = result;
  out->status = MRZ_ARTIFACT_MATERIALIZE_OK;
  out->arena_roots = mrb_immediate_p(result) ? 0 : 1;
}
