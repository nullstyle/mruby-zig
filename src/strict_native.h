#ifndef MRZ_STRICT_NATIVE_H
#define MRZ_STRICT_NATIVE_H
#include <mruby.h>
#include <mruby/data.h>
#include <stddef.h>
#include <stdint.h>

struct mrz_strict_builtin { mrb_func_t function; const char *name; mrb_bool allowed; };
/* Reason: 0 none, 1 denied builtin, 2 unknown native, 3 forbidden primitive,
 * 4 unapproved finalizer. Name is length-delimited, owned, and may be truncated. */
struct mrz_diagnostic_source {
  uint32_t line, file_len, method_len, truncated;
  char file[256], method[96];
};
mrb_bool mrz_diagnostic_source_current(mrb_state *mrb, struct mrz_diagnostic_source *out);
mrb_bool mrz_diagnostic_source_exception(mrb_state *mrb, mrb_value exc, struct mrz_diagnostic_source *out);
struct mrz_strict_diagnostic {
  uint32_t reason; uint32_t name_len; char name[96];
  struct mrz_diagnostic_source source;
};

mrb_bool mrz_strict_state_init(mrb_state *mrb);
void mrz_strict_state_deinit(mrb_state *mrb);
/* Begin is the only reset and fails during an active attempt. The first begin
 * permanently closes trusted bootstrap approvals. End retains the diagnosis. */
mrb_bool mrz_strict_begin_attempt(mrb_state *mrb);
void mrz_strict_end_attempt(mrb_state *mrb);
mrb_bool mrz_strict_violation(mrb_state *mrb, struct mrz_strict_diagnostic *out);
/* Trusted bootstrap only, immediately after defining the exact callback.
 * kind: 0 instance method, 1 singleton method. Approval stores implementation
 * identity; guest aliasing cannot change the permission of a native function. */
mrb_bool mrz_strict_approve_method(mrb_state *mrb, struct RClass *klass, const char *name, size_t length, uint8_t kind);
mrb_bool mrz_strict_approve_data_type(mrb_state *mrb, const mrb_data_type *type);
mrb_bool mrz_strict_data_type_allowed(mrb_state *mrb, const mrb_data_type *type);
void mrz_strict_data_free(mrb_state *mrb, const mrb_data_type *type, void *data);
mrb_value mrz_strict_native_call(mrb_state *mrb, mrb_func_t function, mrb_value self);
mrb_noreturn void mrz_strict_deny(mrb_state *mrb, const char *name);
#endif
