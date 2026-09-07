/* Test-only host crash supervisor. The checkpoint is acknowledged over fd3;
 * SIGKILL follows only after the real host reaches the requested boundary.
 * The supervisor owns/reaps the direct host process before reopening its DB. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#if defined(__linux__)
#include <sys/syscall.h>
#endif

struct mrz_durable_test_process { int pid; int fd; };

static int64_t now_ms(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1;
  return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int readable(int fd, int milliseconds) {
  int64_t now = now_ms();
  if (now < 0) return errno;
  int64_t deadline = now + milliseconds;
  for (;;) {
    now = now_ms();
    if (now < 0) return errno;
    if (now >= deadline) return ETIMEDOUT;
    struct pollfd entry = {fd, POLLIN, 0};
    int rc = poll(&entry, 1, (int)(deadline - now));
    if (rc > 0) return 0;
    if (rc < 0 && errno != EINTR) return errno;
  }
}

static int send_byte(int fd, unsigned char value) {
  int flags = 0;
#ifdef MSG_NOSIGNAL
  flags = MSG_NOSIGNAL;
#endif
  ssize_t count;
  do count = send(fd, &value, 1, flags); while (count < 0 && errno == EINTR);
  return count == 1 ? 0 : count < 0 ? errno : EPIPE;
}

static int receive_byte(int fd, unsigned char expected, int milliseconds) {
  int rc = readable(fd, milliseconds);
  if (rc != 0) return rc;
  unsigned char value = 0;
  ssize_t count;
  do count = recv(fd, &value, 1, 0); while (count < 0 && errno == EINTR);
  return count == 1 ? value == expected ? 0 : EPROTO : count < 0 ? errno : EPIPE;
}

int mrz_durable_test_spawn(const char *executable, const char *database,
                          const char *worker, const char *worker_second,
                          const char *phase,
                          unsigned int ordinal, const char *recipient,
                          struct mrz_durable_test_process *out) {
  *out = (struct mrz_durable_test_process){0, -1};
  int sockets[2] = {-1, -1};
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) != 0) return errno;
  for (int i = 0; i < 2; ++i) {
    int moved = fcntl(sockets[i], F_DUPFD_CLOEXEC, 10);
    if (moved < 0) { int rc = errno; close(sockets[0]); close(sockets[1]); return rc; }
    close(sockets[i]);
    sockets[i] = moved;
#if defined(__APPLE__)
    int yes = 1;
    if (setsockopt(sockets[i], SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes)) != 0) {
      int rc = errno; close(sockets[0]); close(sockets[1]); return rc;
    }
#endif
  }
  char ordinal_text[16];
  snprintf(ordinal_text, sizeof(ordinal_text), "%u", ordinal);
  char *const argv[] = {(char *)executable, (char *)database, (char *)worker,
                       (char *)worker_second, (char *)phase, ordinal_text,
                       (char *)recipient, NULL};
#if !defined(__linux__) || !defined(SYS_close_range)
  long max_fd = sysconf(_SC_OPEN_MAX);
  if (max_fd < 4) max_fd = 1024;
#endif
  pid_t child = fork();
  if (child < 0) { int rc = errno; close(sockets[0]); close(sockets[1]); return rc; }
  if (child == 0) {
    if (setpgid(0, 0) != 0 || dup2(sockets[1], 3) < 0) _exit(126);
#if defined(__linux__) && defined(SYS_close_range)
    if (syscall(SYS_close_range, 4u, ~0u, 0u) != 0) _exit(126);
#else
    for (int fd = 4; fd < max_fd; ++fd) close(fd);
#endif
    sigset_t empty;
    sigemptyset(&empty);
    if (sigprocmask(SIG_SETMASK, &empty, NULL) != 0) _exit(126);
    struct sigaction reset;
    memset(&reset, 0, sizeof(reset));
    reset.sa_handler = SIG_DFL;
    sigemptyset(&reset.sa_mask);
    if (sigaction(SIGCHLD, &reset, NULL) != 0) _exit(126);
    execv(executable, argv);
    _exit(127);
  }
  close(sockets[1]);
  *out = (struct mrz_durable_test_process){child, sockets[0]};
  return 0;
}

int mrz_durable_test_ready(struct mrz_durable_test_process *process) {
  return receive_byte(process->fd, 'R', 15000);
}

int mrz_durable_test_kill(struct mrz_durable_test_process *process) {
  if (process->pid <= 0) {
    if (process->fd >= 0) { close(process->fd); process->fd = -1; }
    return 0;
  }
  int child = process->pid;
  /* Never signal a numeric PID after another reaper has removed our child. */
  siginfo_t info;
  memset(&info, 0, sizeof(info));
  int owned;
  do owned = waitid(P_PID, (id_t)child, &info, WEXITED | WNOWAIT | WNOHANG);
  while (owned != 0 && errno == EINTR);
  if (owned != 0) {
    int rc = errno;
    process->pid = 0;
    if (process->fd >= 0) { close(process->fd); process->fd = -1; }
    return rc;
  }
  if (kill(child, SIGKILL) != 0 && errno != ESRCH) return errno;
  if (process->fd >= 0) { close(process->fd); process->fd = -1; }
  int status = 0;
  pid_t waited;
  do waited = waitpid(child, &status, 0); while (waited < 0 && errno == EINTR);
  process->pid = 0;
  if (waited != child) return errno;
  return WIFSIGNALED(status) && WTERMSIG(status) == SIGKILL ? 0 : EPROTO;
}

int mrz_durable_test_resume(struct mrz_durable_test_process *process) {
  int rc = send_byte(process->fd, 'G');
  if (rc != 0) return rc;
  int64_t now = now_ms();
  if (now < 0) return errno;
  const int64_t deadline = now + 15000;
  for (;;) {
    int status = 0;
    pid_t waited = waitpid(process->pid, &status, WNOHANG);
    if (waited == process->pid) {
      process->pid = 0;
      close(process->fd); process->fd = -1;
      return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : EPROTO;
    }
    if (waited < 0 && errno != EINTR) return errno;
    now = now_ms();
    if (now < 0) return errno;
    if (now >= deadline) return ETIMEDOUT;
    struct timespec pause = {0, 1000000};
    nanosleep(&pause, NULL);
  }
}

/* Called by the trusted host fixture at exactly one selected checkpoint. */
int mrz_durable_test_checkpoint(void) {
  int rc = send_byte(3, 'R');
  return rc != 0 ? rc : receive_byte(3, 'G', 30000);
}
