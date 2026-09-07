/* The strict core's native boundary. Application handlers and the embedding
 * allocator remain trusted; this is not an OS sandbox for arbitrary C/Zig. */
#include "strict_native.h"
#include <mruby/class.h>
#include <mruby/proc.h>
#include <mruby/error.h>
#include <string.h>

#define MRZ_MAX_NATIVE_APPROVALS 512
#define MRZ_MAX_DATA_APPROVALS 32
struct mrz_strict_state {
  mrb_bool active;
  mrb_bool sealed;
  struct mrz_strict_diagnostic violation;
  size_t native_count;
  mrb_func_t natives[MRZ_MAX_NATIVE_APPROVALS];
  size_t data_count;
  const mrb_data_type *data_types[MRZ_MAX_DATA_APPROVALS];
};

/* Each resolver is generated beside the original static implementations. */
#define MRZ_RESOLVER(name) extern const struct mrz_strict_builtin *mrz_strict_##name##_lookup(mrb_func_t);
MRZ_RESOLVER(array) MRZ_RESOLVER(class) MRZ_RESOLVER(enum)
MRZ_RESOLVER(error) MRZ_RESOLVER(gc) MRZ_RESOLVER(hash)
MRZ_RESOLVER(kernel) MRZ_RESOLVER(numeric) MRZ_RESOLVER(object)
MRZ_RESOLVER(proc) MRZ_RESOLVER(range) MRZ_RESOLVER(string) MRZ_RESOLVER(symbol)
#undef MRZ_RESOLVER

static const struct mrz_strict_builtin *builtin(mrb_func_t function)
{
  const struct mrz_strict_builtin *result;
#define MRZ_FIND(name) if ((result = mrz_strict_##name##_lookup(function)) != NULL) return result;
  MRZ_FIND(array) MRZ_FIND(class) MRZ_FIND(enum) MRZ_FIND(error)
  MRZ_FIND(gc) MRZ_FIND(hash) MRZ_FIND(kernel) MRZ_FIND(numeric)
  MRZ_FIND(object) MRZ_FIND(proc) MRZ_FIND(range) MRZ_FIND(string) MRZ_FIND(symbol)
#undef MRZ_FIND
  return NULL;
}

static void note(mrb_state *mrb, uint32_t reason, const char *name)
{
  struct mrz_strict_state *state = mrb->strict_native;
  if (state == NULL || state->violation.reason != 0) return;
  state->violation.reason = reason;
  size_t length = strlen(name);
  if (length > sizeof(state->violation.name)) length = sizeof(state->violation.name);
  memcpy(state->violation.name, name, length);
  state->violation.name_len = (uint32_t)length;
  /* Teardown finalizers also report violations, after live Ruby execution
   * has ended. Do not inspect partially destroyed call frames in that case. */
  if (state->active) mrz_diagnostic_source_current(mrb, &state->violation.source);
}

mrb_bool mrz_strict_state_init(mrb_state *mrb)
{
  struct mrz_strict_state *state = mrb_basic_alloc_func(NULL, sizeof(*state));
  if (state == NULL) return FALSE;
  memset(state, 0, sizeof(*state));
  mrb->strict_native = state;
  return TRUE;
}

void mrz_strict_state_deinit(mrb_state *mrb)
{
  if (mrb->strict_native != NULL) {
    mrb_basic_alloc_func(mrb->strict_native, 0);
    mrb->strict_native = NULL;
  }
}

mrb_bool mrz_strict_begin_attempt(mrb_state *mrb)
{
  struct mrz_strict_state *state = mrb->strict_native;
  if (state == NULL || state->active) return FALSE;
  memset(&state->violation, 0, sizeof(state->violation));
  state->active = TRUE;
  state->sealed = TRUE;
  return TRUE;
}

void mrz_strict_end_attempt(mrb_state *mrb)
{
  if (mrb->strict_native != NULL) mrb->strict_native->active = FALSE;
}

mrb_bool mrz_strict_violation(mrb_state *mrb, struct mrz_strict_diagnostic *out)
{
  if (mrb->strict_native == NULL || mrb->strict_native->violation.reason == 0) return FALSE;
  if (out != NULL) *out = mrb->strict_native->violation;
  return TRUE;
}

/* Registration is a trusted bootstrap operation. Lookup uses already-interned
 * symbols and existing class pointers; no allocation or Ruby callback occurs. */
mrb_bool mrz_strict_approve_method(mrb_state *mrb, struct RClass *klass, const char *name, size_t length, uint8_t kind)
{
  struct mrz_strict_state *state = mrb->strict_native;
  if (state == NULL || state->active || state->sealed || state->violation.reason != 0 || kind > 1) return FALSE;
  mrb_sym symbol = mrb_intern_check(mrb, name, length);
  if (symbol == 0) return FALSE;
  if (kind == 1) klass = mrb_basic_ptr(mrb_obj_value(klass))->c;
  mrb_method_t method = mrb_method_search_vm(mrb, &klass, symbol);
  if (MRB_METHOD_UNDEF_P(method) || !MRB_METHOD_CFUNC_P(method)) return FALSE;
  mrb_func_t function = MRB_METHOD_CFUNC(method);
  const struct mrz_strict_builtin *known = builtin(function);
  if (known != NULL) return known->allowed;
  for (size_t i = 0; i < state->native_count; ++i) if (state->natives[i] == function) return TRUE;
  if (state->native_count == MRZ_MAX_NATIVE_APPROVALS) return FALSE;
  state->natives[state->native_count++] = function;
  return TRUE;
}

mrb_bool mrz_strict_approve_data_type(mrb_state *mrb, const mrb_data_type *type)
{
  struct mrz_strict_state *state = mrb->strict_native;
  if (state == NULL || state->active || state->sealed || state->violation.reason != 0 || type == NULL) return FALSE;
  for (size_t i = 0; i < state->data_count; ++i) if (state->data_types[i] == type) return TRUE;
  if (state->data_count == MRZ_MAX_DATA_APPROVALS) return FALSE;
  state->data_types[state->data_count++] = type;
  return TRUE;
}

mrb_bool mrz_strict_data_type_allowed(mrb_state *mrb, const mrb_data_type *type)
{
  struct mrz_strict_state *state = mrb->strict_native;
  if (state == NULL || type == NULL) return FALSE;
  for (size_t i = 0; i < state->data_count; ++i) if (state->data_types[i] == type) return TRUE;
  return FALSE;
}

/* Finalizers cannot safely raise during collection/destruction. Unknown
 * descriptors are never invoked; strict data creation rejects them earlier.
 * A raw trusted C embedder bypassing that API owns its unreclaimed pointer. */
void mrz_strict_data_free(mrb_state *mrb, const mrb_data_type *type, void *data)
{
  if (!mrz_strict_data_type_allowed(mrb, type)) {
    note(mrb, 4, "unapproved data finalizer");
    return;
  }
  if (type->dfree != NULL) type->dfree(mrb, data);
}

mrb_noreturn void mrz_strict_deny(mrb_state *mrb, const char *name)
{
  note(mrb, 3, name);
  mrb_raise(mrb, E_RUNTIME_ERROR, "strict native operation denied");
}

mrb_value mrz_strict_native_call(mrb_state *mrb, mrb_func_t function, mrb_value self)
{
  struct mrz_strict_state *state = mrb->strict_native;
  if (state == NULL) mrz_strict_deny(mrb, "strict runtime unavailable");
  if (state->violation.reason != 0) mrz_strict_deny(mrb, "previous strict violation");
  const struct mrz_strict_builtin *known = builtin(function);
  if (known != NULL) {
    if (!known->allowed) {
      note(mrb, 1, known->name);
      mrz_strict_deny(mrb, known->name);
    }
    return function(mrb, self);
  }
  for (size_t i = 0; i < state->native_count; ++i) {
    if (state->natives[i] == function) return function(mrb, self);
  }
  note(mrb, 2, "unapproved native implementation");
  mrz_strict_deny(mrb, "unapproved native implementation");
}
