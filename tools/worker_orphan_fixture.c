/* Test-only supervisor -> controller -> real worker process tree.
 *
 * Transport pipes are created inside the controller, so neither supervisor
 * nor watchdog can retain a request writer or response reader. FD 5 belongs
 * only to the worker and stays open through its complete process lifetime.
 * We retain the dead controller as an unreaped process-group leader until
 * cleanup has finished; group signals cannot hit a recycled process ID.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#if defined(__linux__)
#include <sys/prctl.h>
#else
#include <sys/event.h>
#endif

enum { readiness_ms = 15000, exit_ms = 15000, watchdog_ms = 35000 };

struct observation {
  int stage;
  pid_t worker;
};

static void close_fd(int *fd) {
  if (*fd >= 0) (void)close(*fd);
  *fd = -1;
}

/* Keep all temporary descriptors above the wrapper's fixed FDs 3, 4, 5. */
static int make_pipe(int fds[2]) {
  int raw[2];
  if (pipe(raw) != 0) return -1;
  fds[0] = fcntl(raw[0], F_DUPFD_CLOEXEC, 10);
  fds[1] = fcntl(raw[1], F_DUPFD_CLOEXEC, 10);
  (void)close(raw[0]);
  (void)close(raw[1]);
  if (fds[0] >= 0 && fds[1] >= 0) return 0;
  close_fd(&fds[0]);
  close_fd(&fds[1]);
  return -1;
}

static int64_t now_ms(void) {
  struct timespec value;
  if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return -1;
  return (int64_t)value.tv_sec * 1000 + value.tv_nsec / 1000000;
}

static int readable(int fd, int timeout_ms) {
  int64_t start = now_ms();
  if (start < 0) return -1;
  int64_t deadline = start + timeout_ms;
  for (;;) {
    int64_t current = now_ms();
    if (current < 0) return -1;
    int64_t remaining = deadline - current;
    if (remaining <= 0) return 0;
    struct pollfd entry = {fd, POLLIN, 0};
    int result = poll(&entry, 1, (int)remaining);
    if (result >= 0) return result;
    if (errno != EINTR) return -1;
  }
}

static int write_all(int fd, const void *bytes, size_t length) {
  const unsigned char *cursor = bytes;
  while (length != 0) {
    ssize_t result = write(fd, cursor, length);
    if (result < 0 && errno == EINTR) continue;
    if (result <= 0) return -1;
    cursor += result;
    length -= (size_t)result;
  }
  return 0;
}

static int wait_child(pid_t child, int *status) {
  pid_t result;
  do result = waitpid(child, status, 0); while (result < 0 && errno == EINTR);
  return result == child ? 0 : -1;
}

/* Executed by the worker only at the selected real-worker boundary. */
int mrz_orphan_worker_gate(int stage, int selected) {
  if (stage != selected) return 0;
  struct observation marker = {stage, getpid()};
  if (write_all(3, &marker, sizeof(marker)) != 0) return -1;
  if (readable(4, watchdog_ms) != 1) return -1;
  unsigned char release = 0;
  ssize_t count;
  do count = read(4, &release, 1); while (count < 0 && errno == EINTR);
  return count == 1 && release == 1 ? 0 : -1;
}

static void controller(const char *executable, int phase,
                       const unsigned char *request, size_t request_len,
                       int lifetime[2], int ready[2], int release[2]) {
  if (setpgid(0, 0) != 0) _exit(101);
  close_fd(&lifetime[0]);
  close_fd(&ready[0]);
  close_fd(&release[1]);
  int input[2] = {-1, -1};
  int output[2] = {-1, -1};
  if (make_pipe(input) != 0 || make_pipe(output) != 0) _exit(102);
  pid_t worker = fork();
  if (worker < 0) _exit(103);
  if (worker == 0) {
    if (dup2(input[0], STDIN_FILENO) < 0 ||
        dup2(output[1], STDOUT_FILENO) < 0 ||
        dup2(ready[1], 3) < 0 || dup2(release[0], 4) < 0 ||
        dup2(lifetime[1], 5) < 0) _exit(104);
    close_fd(&input[0]);
    close_fd(&input[1]);
    close_fd(&output[0]);
    close_fd(&output[1]);
    close_fd(&ready[1]);
    close_fd(&release[0]);
    close_fd(&lifetime[1]);
    /* Match the production launcher's empty environment and discarded
     * stderr, including sanitizer symbolizer diagnostics from that profile. */
    int null_fd = open("/dev/null", O_WRONLY);
    if (null_fd < 0 || dup2(null_fd, STDERR_FILENO) < 0) _exit(104);
    if (null_fd != STDERR_FILENO) (void)close(null_fd);
    char selected[2] = {(char)('0' + phase), 0};
    char *const argv[] = {(char *)executable, selected, NULL};
    char *const environment[] = {NULL};
    execve(executable, argv, environment);
    _exit(105);
  }
  /* Only the worker retains the lifetime and observation descriptors. */
  close_fd(&lifetime[1]);
  close_fd(&ready[1]);
  close_fd(&release[0]);
  close_fd(&input[0]);
  close_fd(&output[1]);
  if (write_all(input[1], request, request_len) != 0) _exit(106);
  if (phase != 1) close_fd(&input[1]);
  /* Phase 1 deliberately holds an incomplete request open; all cases hold
   * the only response reader. SIGKILL, not fixture cleanup, closes them. */
  for (;;) pause();
}

static int lifetime_ended(int fd, int timeout_ms) {
  if (readable(fd, timeout_ms) != 1) return 0;
  unsigned char byte;
  ssize_t count;
  do count = read(fd, &byte, 1); while (count < 0 && errno == EINTR);
  return count == 0;
}

static int controller_dead_unreaped(pid_t child) {
  int64_t deadline = now_ms() + readiness_ms;
  while (now_ms() < deadline) {
    siginfo_t status = {0};
    int result = waitid(P_PID, (id_t)child, &status, WEXITED | WNOHANG | WNOWAIT);
    if (result < 0 && errno == EINTR) continue;
    if (result < 0) return 0;
    if (status.si_pid == child)
      return status.si_code == CLD_KILLED && status.si_status == SIGKILL;
    /* Polling waitid has no timeout interface. This bounded sleep observes
     * process teardown; it never guesses whether the worker is ready. */
    struct timespec delay = {0, 1000000};
    (void)nanosleep(&delay, NULL);
  }
  return 0;
}

int mrz_test_orphan_case(const char *executable, int phase,
                         const unsigned char *request, size_t request_len) {
  int lifetime[2] = {-1, -1};
  int ready[2] = {-1, -1};
  int release[2] = {-1, -1};
  int watchdog_done[2] = {-1, -1};
  pid_t child = -1, watchdog = -1;
  pid_t worker = -1;
  int worker_status = 0;
  int worker_reaped = 0;
  int result = 1, status = 0, observed_exit = 0;
  if (phase < 1 || phase > 3) return 2;
#if defined(__linux__)
  int prior_subreaper = 0;
  if (prctl(PR_GET_CHILD_SUBREAPER, &prior_subreaper) != 0 ||
      prctl(PR_SET_CHILD_SUBREAPER, 1) != 0) return 16;
#else
  int process_events = -1;
#endif
  if (make_pipe(lifetime) != 0 || make_pipe(ready) != 0 ||
      make_pipe(release) != 0) goto done;
  child = fork();
  if (child < 0) goto done;
  if (child == 0)
    controller(executable, phase, request, request_len, lifetime, ready, release);
  /* Both parent and child establish the private group before any cleanup
   * signal. The child cannot exec, so this cannot race an exec transition. */
  if (setpgid(child, child) != 0) { result = 3; goto done; }
  close_fd(&lifetime[1]);
  close_fd(&ready[1]);
  close_fd(&release[0]);
  if (make_pipe(watchdog_done) != 0) { result = 4; goto done; }
  watchdog = fork();
  if (watchdog < 0) { result = 5; goto done; }
  if (watchdog == 0) {
    close_fd(&watchdog_done[1]);
    close_fd(&lifetime[0]);
    close_fd(&ready[0]);
    close_fd(&release[1]);
    unsigned char finished = 0;
    if (readable(watchdog_done[0], watchdog_ms) == 1 &&
        read(watchdog_done[0], &finished, 1) == 1 && finished == 1) _exit(0);
    (void)kill(-child, SIGKILL);
    _exit(107);
  }
  close_fd(&watchdog_done[0]);
  if (readable(ready[0], readiness_ms) != 1) { result = 6; goto done; }
  struct observation marker = {0, -1};
  if (read(ready[0], &marker, sizeof(marker)) != sizeof(marker) ||
      marker.stage != phase || marker.worker <= 0) { result = 7; goto done; }
  worker = marker.worker;
  /* The marker is emitted by the exact worker, and its gate keeps it alive.
   * Death before release is a fixture failure, never an orphan-exit pass. */
  if (readable(lifetime[0], 1) != 0) { result = 8; goto done; }
#if !defined(__linux__)
  process_events = kqueue();
  if (process_events < 0) { result = 17; goto done; }
  struct kevent change;
  EV_SET(&change, (uintptr_t)worker, EVFILT_PROC, EV_ADD | EV_ONESHOT,
         NOTE_EXIT | NOTE_EXITSTATUS, 0, NULL);
  if (kevent(process_events, &change, 1, NULL, 0, NULL) != 0) {
    result = 18;
    goto done;
  }
#endif
  if (kill(child, SIGKILL) != 0) { result = 9; goto done; }
  if (!controller_dead_unreaped(child)) { result = 10; goto done; }
  unsigned char resume = 1;
  if (write_all(release[1], &resume, 1) != 0) { result = 11; goto done; }
  close_fd(&release[1]);
  observed_exit = lifetime_ended(lifetime[0], exit_ms);
  result = observed_exit ? 0 : 12;
  if (!observed_exit) goto done;
#if defined(__linux__)
  /* The isolated supervisor adopts only this fixture's killed controller's
   * worker. A dedicated lifetime pipe still supplies the exit observation;
   * waitpid supplies its cause and prevents container-init zombie leaks. */
  if (wait_child(worker, &worker_status) != 0) { result = 19; goto done; }
  worker_reaped = 1;
#else
  struct kevent event;
  struct timespec timeout = {exit_ms / 1000, 0};
  int events;
  do events = kevent(process_events, NULL, 0, &event, 1, &timeout);
  while (events < 0 && errno == EINTR);
  if (events != 1 || event.ident != (uintptr_t)worker ||
      (event.fflags & NOTE_EXIT) == 0) { result = 20; goto done; }
  worker_status = (int)event.data;
#endif
  if (phase == 2) {
    if (!WIFSIGNALED(worker_status) ||
        (WTERMSIG(worker_status) != SIGXCPU && WTERMSIG(worker_status) != SIGKILL))
      result = 21;
  } else if (!WIFEXITED(worker_status) || WEXITSTATUS(worker_status) != 1) {
    /* Production main maps EOF/BrokenPipe transport failure to exit 1. */
    result = 22;
  }

done:
  /* Kill before reaping the controller: its unreaped PID anchors group
   * identity even if the worker has already exited or become a zombie. */
  if (child > 0) {
    (void)kill(child, SIGKILL);
    (void)kill(-child, SIGKILL);
  }
  close_fd(&lifetime[1]);
  close_fd(&ready[1]);
  close_fd(&release[0]);
  close_fd(&release[1]);
  if (child > 0 && !observed_exit && lifetime[0] >= 0 &&
      !lifetime_ended(lifetime[0], exit_ms)) result = 13;
  /* Disable and reap the independent watchdog before releasing the group
   * leader's PID. No later signal can target a reused process identity. */
  if (watchdog > 0) {
    unsigned char finished = 1;
    (void)write_all(watchdog_done[1], &finished, 1);
    if (wait_child(watchdog, &status) != 0 || !WIFEXITED(status) ||
        WEXITSTATUS(status) != 0) result = 14;
  }
#if defined(__linux__)
  if (worker > 0 && !worker_reaped) (void)wait_child(worker, &worker_status);
#else
  (void)worker_reaped;
  close_fd(&process_events);
#endif
  if (child > 0 && wait_child(child, &status) != 0) result = 15;
#if defined(__linux__)
  if (child > 0) {
    /* Setup failures before a readiness marker can still leave an adopted
     * child. Reap only this fixture's process group, never unrelated tests. */
    for (;;) {
      pid_t reaped = waitpid(-child, &status, 0);
      if (reaped > 0 || (reaped < 0 && errno == EINTR)) continue;
      if (reaped < 0 && errno != ECHILD) result = 24;
      break;
    }
  }
  if (prctl(PR_SET_CHILD_SUBREAPER, prior_subreaper) != 0) result = 23;
#endif
  close_fd(&lifetime[0]);
  close_fd(&ready[0]);
  close_fd(&watchdog_done[0]);
  close_fd(&watchdog_done[1]);
  return result;
}
