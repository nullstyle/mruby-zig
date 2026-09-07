#define _GNU_SOURCE
#include "effect_worker_process.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#if defined(__linux__)
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#elif defined(__APPLE__)
#include <sandbox.h>
#include <pthread.h>
static pthread_mutex_t spawn_mutex = PTHREAD_MUTEX_INITIALIZER;
#endif

int mrz_effect_now_ns(uint64_t *out) {
  struct timespec time;
  if (clock_gettime(CLOCK_MONOTONIC, &time) != 0) return errno;
  *out = (uint64_t)time.tv_sec * UINT64_C(1000000000) + (uint64_t)time.tv_nsec;
  return 0;
}

int mrz_effect_channel_init(int fd, uint64_t wall_ns, uint64_t max_bytes, struct mrz_effect_channel *out) {
  uint64_t now;
  if (fd < 0 || wall_ns == 0 || max_bytes == 0) return EINVAL;
  int rc = mrz_effect_now_ns(&now);
  if (rc != 0) return rc;
  if (wall_ns > UINT64_MAX - now) return EINVAL;
  *out = (struct mrz_effect_channel){fd, now, now + wall_ns, max_bytes, 0};
  return 0;
}

int mrz_effect_channel_configure(struct mrz_effect_channel *channel, uint64_t wall_ns, uint64_t max_bytes) {
  if (wall_ns == 0 || wall_ns > UINT64_MAX - channel->started_ns ||
      channel->started_ns + wall_ns > channel->deadline_ns ||
      max_bytes < channel->transferred_bytes ||
      max_bytes - channel->transferred_bytes > channel->remaining_bytes) return EINVAL;
  channel->deadline_ns = channel->started_ns + wall_ns;
  channel->remaining_bytes = max_bytes - channel->transferred_bytes;
  uint64_t now;
  int rc = mrz_effect_now_ns(&now);
  return rc != 0 ? rc : now >= channel->deadline_ns ? ETIMEDOUT : 0;
}

static int wait_ready(struct mrz_effect_channel *channel, short events) {
  for (;;) {
    uint64_t now;
    int rc = mrz_effect_now_ns(&now);
    if (rc != 0) return rc;
    if (now >= channel->deadline_ns) return ETIMEDOUT;
    uint64_t remaining = channel->deadline_ns - now;
    uint64_t milliseconds = remaining / UINT64_C(1000000) + (remaining % UINT64_C(1000000) != 0);
    int timeout = milliseconds > INT_MAX ? INT_MAX : (int)milliseconds;
    struct pollfd fd = {channel->fd, events, 0};
    int count = poll(&fd, 1, timeout);
    if (count < 0) { if (errno == EINTR) continue; return errno; }
    if (count == 0) continue;
    if (fd.revents & POLLNVAL) return EBADF;
    /* poll rounds to milliseconds and a scheduled process can resume later
     * than requested. Ready bytes do not authorize work past the deadline. */
    if ((rc = mrz_effect_now_ns(&now)) != 0) return rc;
    if (now >= channel->deadline_ns) return ETIMEDOUT;
    return 0; /* recv/send observes EOF and socket errors without guessing. */
  }
}

static int transfer(struct mrz_effect_channel *channel, void *buffer, size_t length, int writing) {
  if ((uint64_t)length > channel->remaining_bytes) return EMSGSIZE;
  size_t offset = 0;
  while (offset < length) {
    int rc = wait_ready(channel, writing ? POLLOUT : POLLIN);
    if (rc != 0) return rc;
    int flags = MSG_DONTWAIT;
#ifdef MSG_NOSIGNAL
    flags |= MSG_NOSIGNAL;
#endif
    size_t amount = length - offset;
    if (amount > INT_MAX) amount = INT_MAX;
    ssize_t count = writing ? send(channel->fd, (const char *)buffer + offset, amount, flags)
                            : recv(channel->fd, (char *)buffer + offset, amount, MSG_DONTWAIT);
    if (count < 0) { if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue; return errno; }
    if (count == 0) return EPIPE;
    offset += (size_t)count;
    channel->remaining_bytes -= (uint64_t)count;
    channel->transferred_bytes += (uint64_t)count;
  }
  return 0;
}
int mrz_effect_channel_read(struct mrz_effect_channel *channel, void *out, size_t length) { return transfer(channel, out, length, 0); }
int mrz_effect_channel_write(struct mrz_effect_channel *channel, const void *bytes, size_t length) { return transfer(channel, (void *)bytes, length, 1); }
int mrz_effect_channel_eof(struct mrz_effect_channel *channel) {
  for (;;) {
    int rc = wait_ready(channel, POLLIN);
    if (rc != 0) return rc;
    char byte;
    ssize_t count = recv(channel->fd, &byte, 1, MSG_DONTWAIT);
    if (count < 0) { if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue; return errno; }
    return count == 0 ? 0 : EPROTO;
  }
}

static int child_wait_available(void) {
  struct sigaction action;
  if (sigaction(SIGCHLD, NULL, &action) != 0) return errno;
  return action.sa_handler == SIG_DFL && !(action.sa_flags & SA_NOCLDWAIT) ? 0 : ECHILD;
}
static int own_child(int pid) {
  siginfo_t info;
  memset(&info, 0, sizeof(info));
  while (waitid(P_PID, (id_t)pid, &info, WEXITED | WNOWAIT | WNOHANG) != 0) {
    if (errno != EINTR) return errno;
  }
  return 0;
}
static int move_private(int *fd) {
  if (*fd <= MRZ_EFFECT_PROTOCOL_FD) {
    int replacement = fcntl(*fd, F_DUPFD_CLOEXEC, MRZ_EFFECT_PROTOCOL_FD + 1);
    if (replacement < 0) return errno;
    close(*fd);
    *fd = replacement;
  } else if (fcntl(*fd, F_SETFD, FD_CLOEXEC) != 0) return errno;
#if defined(__APPLE__)
  int yes = 1;
  if (setsockopt(*fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes)) != 0) return errno;
#endif
  return 0;
}

int mrz_effect_process_spawn(const char *path, uint64_t wall_ns, uint64_t max_bytes, struct mrz_effect_process *out) {
  *out = (struct mrz_effect_process){.channel = {.fd = -1}, .pid = 0};
  int rc = child_wait_available();
  if (rc != 0) return rc;
  struct mrz_effect_channel channel;
  rc = mrz_effect_channel_init(MRZ_EFFECT_PROTOCOL_FD, wall_ns, max_bytes, &channel);
  if (rc != 0) return rc;
  int pair[2] = {-1, -1};
  pid_t pid = -1;
#if defined(__APPLE__)
  rc = pthread_mutex_lock(&spawn_mutex);
  if (rc != 0) return rc;
#endif
  if (socketpair(AF_UNIX, SOCK_STREAM
#if defined(__linux__)
      | SOCK_CLOEXEC
#endif
      , 0, pair) != 0) { rc = errno; goto done; }
  if ((rc = move_private(&pair[0])) != 0 || (rc = move_private(&pair[1])) != 0) goto done;
  char *const argv[] = {(char *)path, NULL};
  char *const environment[] = {NULL};
#if defined(__APPLE__)
  posix_spawn_file_actions_t actions;
  posix_spawnattr_t attrs;
  int actions_ready = 0, attrs_ready = 0;
  if ((rc = posix_spawn_file_actions_init(&actions)) != 0) goto done;
  actions_ready = 1;
  if ((rc = posix_spawn_file_actions_adddup2(&actions, pair[1], MRZ_EFFECT_PROTOCOL_FD)) != 0) goto mac_done;
  for (int i = 0; i < 3; ++i) if ((rc = posix_spawn_file_actions_addopen(&actions, i, "/dev/null", i == 0 ? O_RDONLY : O_WRONLY, 0)) != 0) goto mac_done;
  if ((rc = posix_spawnattr_init(&attrs)) != 0) goto mac_done;
  attrs_ready = 1;
  sigset_t empty, defaults;
  sigemptyset(&empty); sigfillset(&defaults);
  if ((rc = posix_spawnattr_setpgroup(&attrs, 0)) != 0 ||
      (rc = posix_spawnattr_setsigmask(&attrs, &empty)) != 0 ||
      (rc = posix_spawnattr_setsigdefault(&attrs, &defaults)) != 0 ||
      (rc = posix_spawnattr_setflags(&attrs, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)) != 0) goto mac_done;
  rc = posix_spawn(&pid, path, &actions, &attrs, argv, environment);
mac_done:
  if (attrs_ready) posix_spawnattr_destroy(&attrs);
  if (actions_ready) posix_spawn_file_actions_destroy(&actions);
#elif defined(__linux__)
  /* Linux libc variants differ in closefrom spawn actions. The child uses
   * only async-signal-safe operations/syscalls before exec. close_range is
   * mandatory (Linux >=5.9); failure exits before any application startup. */
  const pid_t broker_pid = getpid();
  pid = fork();
  if (pid < 0) { rc = errno; goto done; }
  if (pid == 0) {
    /* Install before exec/header parsing: capturing getppid only later can
     * mistake an already-orphaned child's reaper for its original broker.
     * no_new_privs also prevents privilege gains during executable startup. */
    if (syscall(SYS_prctl, (long)PR_SET_NO_NEW_PRIVS, 1L, 0L, 0L, 0L) != 0 ||
        syscall(SYS_prctl, (long)PR_SET_PDEATHSIG, (long)SIGKILL, 0L, 0L, 0L) != 0 ||
        getppid() != broker_pid) _exit(126);
    if (setpgid(0, 0) != 0 || dup2(pair[1], MRZ_EFFECT_PROTOCOL_FD) < 0) _exit(126);
    int null_fd = open("/dev/null", O_RDWR | O_CLOEXEC);
    if (null_fd < 0) _exit(126);
    for (int i = 0; i < 3; ++i) if (dup2(null_fd, i) < 0) _exit(126);
#ifdef SYS_close_range
    if (syscall(SYS_close_range, 4u, ~0u, 0u) != 0) _exit(126);
#else
    _exit(126);
#endif
    sigset_t empty;
    sigemptyset(&empty);
    if (sigprocmask(SIG_SETMASK, &empty, NULL) != 0) _exit(126);
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    for (int signal = 1; signal < NSIG; ++signal) (void)sigaction(signal, &action, NULL);
    execve(path, argv, environment);
    _exit(127);
  }
  rc = 0;
#else
  rc = ENOTSUP;
#endif
  if (rc == 0) {
    channel.fd = pair[0];
    *out = (struct mrz_effect_process){.channel = channel, .pid = (int)pid};
    pair[0] = -1;
  }
done:
  if (pair[0] >= 0) close(pair[0]);
  if (pair[1] >= 0) close(pair[1]);
#if defined(__APPLE__)
  pthread_mutex_unlock(&spawn_mutex);
#endif
  return rc;
}

int mrz_effect_process_destroy(struct mrz_effect_process *process) {
  if (process->channel.fd >= 0) { close(process->channel.fd); process->channel.fd = -1; }
  if (process->pid <= 0) return 0;
  int rc = own_child(process->pid);
  if (rc != 0) { process->pid = 0; return rc; }
  (void)kill(-process->pid, SIGKILL);
  (void)kill(process->pid, SIGKILL);
  while (waitpid(process->pid, &process->wait_status, 0) < 0) {
    if (errno != EINTR) { rc = errno; break; }
  }
  process->pid = 0;
  return rc;
}

int mrz_effect_process_wait(struct mrz_effect_process *process) {
  if (process->pid <= 0) return ECHILD;
  int rc = mrz_effect_channel_eof(&process->channel);
  if (rc != 0) return rc;
  for (;;) {
    uint64_t now;
    if ((rc = mrz_effect_now_ns(&now)) != 0) return rc;
    if (now >= process->channel.deadline_ns) return ETIMEDOUT;
    siginfo_t info;
    memset(&info, 0, sizeof(info));
    if (waitid(P_PID, (id_t)process->pid, &info, WEXITED | WNOWAIT | WNOHANG) != 0) {
      if (errno == EINTR) continue;
      return errno;
    }
    if (info.si_pid != 0) break;
    struct timespec pause = {0, 1000000};
    while (nanosleep(&pause, &pause) != 0 && errno == EINTR) {}
  }
  // Keep the direct child waitable until residual descendants are killed.
  (void)kill(-process->pid, SIGKILL);
  while (waitpid(process->pid, &process->wait_status, 0) < 0) if (errno != EINTR) return errno;
  process->pid = 0;
  close(process->channel.fd); process->channel.fd = -1;
  uint64_t completed;
  if ((rc = mrz_effect_now_ns(&completed)) != 0) return rc;
  if (completed >= process->channel.deadline_ns) return ETIMEDOUT;
  return WIFEXITED(process->wait_status) && WEXITSTATUS(process->wait_status) == 0 ? 0 : EIO;
}

#if defined(__linux__)
#define ALLOW_SYSCALL(number) BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, (number), 0, 1), BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW)
#define FD_SYSCALL(number) \
  BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, (number), 0, 4), \
  BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data, args[0])), \
  BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, MRZ_EFFECT_PROTOCOL_FD, 0, 1), \
  BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW), \
  BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ERRNO|EPERM)
static int linux_filter(void) {
#if defined(__x86_64__)
#define MRZ_AUDIT_ARCH AUDIT_ARCH_X86_64
#elif defined(__aarch64__)
#define MRZ_AUDIT_ARCH AUDIT_ARCH_AARCH64
#else
  return ENOTSUP;
#endif
#ifdef MRZ_AUDIT_ARCH
  struct sock_filter instructions[] = {
    BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data, arch)),
    BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, MRZ_AUDIT_ARCH, 1, 0),
    BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_KILL_PROCESS),
    BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data, nr)),
    FD_SYSCALL(SYS_read), FD_SYSCALL(SYS_write),
    FD_SYSCALL(SYS_readv), FD_SYSCALL(SYS_writev),
    FD_SYSCALL(SYS_sendto), FD_SYSCALL(SYS_recvfrom),
    ALLOW_SYSCALL(SYS_close),
#ifdef SYS_poll
    ALLOW_SYSCALL(SYS_poll),
#endif
    ALLOW_SYSCALL(SYS_ppoll), ALLOW_SYSCALL(SYS_clock_gettime),
    ALLOW_SYSCALL(SYS_clock_getres), ALLOW_SYSCALL(SYS_futex),
    ALLOW_SYSCALL(SYS_sched_yield), ALLOW_SYSCALL(SYS_sched_getaffinity),
    ALLOW_SYSCALL(SYS_getpid), ALLOW_SYSCALL(SYS_gettid),
    ALLOW_SYSCALL(SYS_rt_sigaction), ALLOW_SYSCALL(SYS_rt_sigprocmask),
    ALLOW_SYSCALL(SYS_rt_sigreturn), ALLOW_SYSCALL(SYS_sigaltstack),
    ALLOW_SYSCALL(SYS_brk), ALLOW_SYSCALL(SYS_munmap),
    ALLOW_SYSCALL(SYS_mremap), ALLOW_SYSCALL(SYS_madvise),
    ALLOW_SYSCALL(SYS_exit), ALLOW_SYSCALL(SYS_exit_group),
    /* mmap must be anonymous and non-executable; no file-backed mapping can
     * gain access to an inherited or reopened descriptor. */
    BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, SYS_mmap, 0, 6),
    BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data, args[3])),
    BPF_JUMP(BPF_JMP|BPF_JSET|BPF_K, MAP_ANONYMOUS, 0, 3),
    BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data, args[2])),
    BPF_JUMP(BPF_JMP|BPF_JSET|BPF_K, PROT_EXEC, 1, 0),
    BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW),
    BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ERRNO|EPERM),
    BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, SYS_mprotect, 0, 4),
    BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data, args[2])),
    BPF_JUMP(BPF_JMP|BPF_JSET|BPF_K, PROT_EXEC, 1, 0),
    BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW),
    BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ERRNO|EPERM),
    BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ERRNO|EPERM),
  };
  struct sock_fprog program = {(unsigned short)(sizeof(instructions) / sizeof(instructions[0])), instructions};
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) return errno;
  /* Synchronize every existing thread as well as future descendants. A
   * runtime-created helper thread must not retain an unfiltered syscall path. */
  long installed = syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER, SECCOMP_FILTER_FLAG_TSYNC, &program);
  if (installed < 0) return errno;
  if (installed != 0) return EPERM;
  return 0;
#endif
}
#endif

static int lower_limit(int resource, rlim_t requested) {
  struct rlimit prior;
  if (getrlimit(resource, &prior) != 0) return errno;
  struct rlimit next = {requested, requested};
  if (prior.rlim_cur < next.rlim_cur) next.rlim_cur = prior.rlim_cur;
  if (prior.rlim_max < next.rlim_max) next.rlim_max = prior.rlim_max;
  return setrlimit(resource, &next) == 0 ? 0 : errno;
}
int mrz_effect_worker_confine(uint32_t cpu_seconds, uint64_t address_space_bytes) {
  if (cpu_seconds == 0) return EINVAL;
  int rc;
#if defined(__APPLE__)
  if (address_space_bytes != 0) return ENOTSUP;
#elif defined(__linux__)
  if (address_space_bytes != 0) {
    if ((uint64_t)(rlim_t)address_space_bytes != address_space_bytes) return EINVAL;
    if ((rc = lower_limit(RLIMIT_AS, (rlim_t)address_space_bytes)) != 0) return rc;
  }
#else
  return ENOTSUP;
#endif
  if ((rc = lower_limit(RLIMIT_CPU, (rlim_t)cpu_seconds)) != 0 ||
      (rc = lower_limit(RLIMIT_CORE, 0)) != 0 ||
      (rc = lower_limit(RLIMIT_FSIZE, 0)) != 0) return rc;
#if defined(__linux__)
  pid_t parent = getppid();
  if (prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0) != 0) return errno;
  if (getppid() != parent) return ECHILD;
  return linux_filter();
#elif defined(__APPLE__)
  /* This is Seatbelt resource mediation, not a syscall allowlist. Existing
   * protocol socket IO and anonymous memory remain usable. New filesystem
   * access, network connect/bind, process creation/exec, and Mach lookup are
   * denied. Unconnected socket allocation itself is not blocked by Seatbelt.
   * sandbox_init is deprecated; initialization failure is fail-closed. */
  char *message = NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  int result = sandbox_init("(version 1) (deny default)", 0, &message);
  if (message != NULL) sandbox_free_error(message);
#pragma clang diagnostic pop
  return result == 0 ? 0 : EPERM;
#endif
}
