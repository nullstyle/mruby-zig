/* Linux regression: the real spawn path must kill its worker when the broker
 * exits before the worker ever reads a startup header or installs confinement.
 * Run with --test. The worker re-execs this binary without arguments. */
#define _GNU_SOURCE
#include "effect_worker_process.h"
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <unistd.h>

static int reap_with_deadline(pid_t pid, int *status) {
  uint64_t started, now;
  if (mrz_effect_now_ns(&started) != 0) return 1;
  for (;;) {
    pid_t result = waitpid(pid, status, WNOHANG);
    if (result == pid) return 0;
    if (result < 0 && errno != EINTR) return 1;
    if (mrz_effect_now_ns(&now) != 0 || now - started >= UINT64_C(2000000000)) return 1;
    (void)poll(NULL, 0, 1);
  }
}

int main(int argc, char **argv) {
  (void)argv;
  if (argc == 1) {
    /* No startup header, resource limit or confine call has occurred. */
    const char ready = 'r';
    if (write(MRZ_EFFECT_PROTOCOL_FD, &ready, 1) != 1) return 2;
    for (;;) pause();
  }
  if (prctl(PR_SET_CHILD_SUBREAPER, 1L, 0L, 0L, 0L) != 0) return 3;
  int report[2];
  if (pipe(report) != 0) return 4;
  pid_t broker = fork();
  if (broker < 0) return 5;
  if (broker == 0) {
    close(report[0]);
    struct mrz_effect_process worker;
    if (mrz_effect_process_spawn("/proc/self/exe", UINT64_C(2000000000), 4096, &worker) != 0) _exit(6);
    char ready;
    if (mrz_effect_channel_read(&worker.channel, &ready, 1) != 0 || ready != 'r') {
      mrz_effect_process_destroy(&worker);
      _exit(7);
    }
    if (write(report[1], &worker.pid, sizeof(worker.pid)) != sizeof(worker.pid)) {
      mrz_effect_process_destroy(&worker);
      _exit(8);
    }
    /* Deliberately omit worker destruction: parent death must do the killing. */
    _exit(0);
  }
  close(report[1]);
  int worker = 0, broker_status = 0, worker_status = 0;
  struct pollfd fd = {report[0], POLLIN, 0};
  int failed = poll(&fd, 1, 3000) <= 0;
  if (!failed) failed = read(report[0], &worker, sizeof(worker)) != sizeof(worker) || worker <= 0;
  close(report[0]);
  if (failed) kill(broker, SIGKILL);
  if (reap_with_deadline(broker, &broker_status) != 0) {
    kill(broker, SIGKILL);
    while (waitpid(broker, &broker_status, 0) < 0 && errno == EINTR) {}
    failed = 1;
  }
  if (!WIFEXITED(broker_status) || WEXITSTATUS(broker_status) != 0) failed = 1;
  if (worker > 0) {
    if (reap_with_deadline(worker, &worker_status) != 0) {
      kill(worker, SIGKILL);
      while (waitpid(worker, &worker_status, 0) < 0 && errno == EINTR) {}
      failed = 1;
    }
    if (!WIFSIGNALED(worker_status) || WTERMSIG(worker_status) != SIGKILL) failed = 1;
  }
  if (failed) {
    fprintf(stderr, "worker orphan regression failed: broker=%d worker=%d\n", broker_status, worker_status);
    return 1;
  }
  return 0;
}
