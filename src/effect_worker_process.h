#ifndef MRZ_EFFECT_WORKER_PROCESS_H
#define MRZ_EFFECT_WORKER_PROCESS_H
#include <stddef.h>
#include <stdint.h>

#define MRZ_EFFECT_PROTOCOL_FD 3
struct mrz_effect_channel {
  int fd;
  uint64_t started_ns;
  uint64_t deadline_ns;
  uint64_t remaining_bytes;
  uint64_t transferred_bytes;
};
struct mrz_effect_process {
  struct mrz_effect_channel channel;
  int pid;
  int wait_status;
};

/* All functions return zero or an errno value. No function changes the
 * process-wide SIGPIPE disposition. Caller must exclude competing child
 * reapers and SIGCHLD-disposition changes while a Process is owned. */
int mrz_effect_now_ns(uint64_t *out);
int mrz_effect_channel_init(int fd, uint64_t wall_ns, uint64_t max_bytes, struct mrz_effect_channel *out);
int mrz_effect_channel_configure(struct mrz_effect_channel *, uint64_t wall_ns, uint64_t max_bytes);
int mrz_effect_channel_read(struct mrz_effect_channel *, void *, size_t);
int mrz_effect_channel_write(struct mrz_effect_channel *, const void *, size_t);
int mrz_effect_channel_eof(struct mrz_effect_channel *);
int mrz_effect_process_spawn(const char *path, uint64_t wall_ns, uint64_t max_bytes, struct mrz_effect_process *out);
int mrz_effect_process_wait(struct mrz_effect_process *);
int mrz_effect_process_destroy(struct mrz_effect_process *);
/* Child only, after the bounded fixed startup header and before guest input,
 * VM construction, or application code. 0 address_space_bytes is unbounded;
 * nonzero is supported on Linux only. Failure must terminate the child. */
int mrz_effect_worker_confine(uint32_t cpu_seconds, uint64_t address_space_bytes);
#endif
