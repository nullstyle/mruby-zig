/* Test-only seams compiled into this repository's test binaries, never into
 * the shipped library module. Consumers of the `mruby` module do not link
 * this file. */

#include <mruby.h>
#include <mruby/gc.h>

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
