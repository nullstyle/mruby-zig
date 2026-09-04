#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stddef.h>
#include <sys/types.h>
#include <unistd.h>

#if !defined(__linux__)
#include <pthread.h>
static pthread_mutex_t spawn_mutex = PTHREAD_MUTEX_INITIALIZER;
#endif

static void close_if_open(int fd) {
  if (fd >= 0) {
    (void)close(fd);
  }
}

static int move_above_stdio(int *fd) {
  if (*fd > STDERR_FILENO) {
    int flags = fcntl(*fd, F_GETFD);
    if (flags < 0 || fcntl(*fd, F_SETFD, flags | FD_CLOEXEC) < 0) {
      return errno;
    }
    return 0;
  }

  int replacement = fcntl(*fd, F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
  if (replacement < 0) {
    return errno;
  }
  (void)close(*fd);
  *fd = replacement;
  return 0;
}

static int make_pipe(int fds[2]) {
#if defined(__linux__)
  if (pipe2(fds, O_CLOEXEC) < 0) {
    return errno;
  }
#else
  if (pipe(fds) < 0) {
    return errno;
  }
#endif

  int rc = move_above_stdio(&fds[0]);
  if (rc == 0) {
    rc = move_above_stdio(&fds[1]);
  }
  if (rc != 0) {
    close_if_open(fds[0]);
    close_if_open(fds[1]);
    fds[0] = -1;
    fds[1] = -1;
  }
  return rc;
}

static int add_child_actions(posix_spawn_file_actions_t *actions,
                             const int stdin_pipe[2],
                             const int stdout_pipe[2]) {
  int rc = posix_spawn_file_actions_adddup2(actions, stdin_pipe[0],
                                             STDIN_FILENO);
  if (rc != 0) {
    return rc;
  }
  rc = posix_spawn_file_actions_adddup2(actions, stdout_pipe[1],
                                         STDOUT_FILENO);
  if (rc != 0) {
    return rc;
  }
  rc = posix_spawn_file_actions_addopen(actions, STDERR_FILENO, "/dev/null",
                                         O_WRONLY, 0);
  if (rc != 0) {
    return rc;
  }

  rc = posix_spawn_file_actions_addclose(actions, stdin_pipe[0]);
  if (rc != 0) {
    return rc;
  }
  rc = posix_spawn_file_actions_addclose(actions, stdin_pipe[1]);
  if (rc != 0) {
    return rc;
  }
  rc = posix_spawn_file_actions_addclose(actions, stdout_pipe[0]);
  if (rc != 0) {
    return rc;
  }
  return posix_spawn_file_actions_addclose(actions, stdout_pipe[1]);
}

int mrz_worker_spawn(const char *path, pid_t *pid_out, int *stdin_fd_out,
                     int *stdout_fd_out) {
  int rc = 0;
#if !defined(__linux__)
  rc = pthread_mutex_lock(&spawn_mutex);
  if (rc != 0) {
    return rc;
  }
#endif

  int stdin_pipe[2] = {-1, -1};
  int stdout_pipe[2] = {-1, -1};
  posix_spawn_file_actions_t actions;
  posix_spawnattr_t attributes;
  int actions_initialized = 0;
  int attributes_initialized = 0;
  rc = make_pipe(stdin_pipe);
  if (rc != 0) {
    goto done;
  }
  rc = make_pipe(stdout_pipe);
  if (rc != 0) {
    goto done;
  }

  rc = posix_spawn_file_actions_init(&actions);
  if (rc != 0) {
    goto done;
  }
  actions_initialized = 1;
  rc = add_child_actions(&actions, stdin_pipe, stdout_pipe);
  if (rc != 0) {
    goto done;
  }

  rc = posix_spawnattr_init(&attributes);
  if (rc != 0) {
    goto done;
  }
  attributes_initialized = 1;
  rc = posix_spawnattr_setpgroup(&attributes, 0);
  if (rc != 0) {
    goto done;
  }
  rc = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP);
  if (rc != 0) {
    goto done;
  }

  char *const argv[] = {(char *)path, NULL};
  char *const empty_environment[] = {NULL};
  pid_t pid = -1;
  rc = posix_spawn(&pid, path, &actions, &attributes, argv,
                   empty_environment);
  if (rc == 0) {
    *pid_out = pid;
    *stdin_fd_out = stdin_pipe[1];
    *stdout_fd_out = stdout_pipe[0];
    stdin_pipe[1] = -1;
    stdout_pipe[0] = -1;
  }

done:
  if (attributes_initialized) {
    (void)posix_spawnattr_destroy(&attributes);
  }
  if (actions_initialized) {
    (void)posix_spawn_file_actions_destroy(&actions);
  }
  close_if_open(stdin_pipe[0]);
  close_if_open(stdin_pipe[1]);
  close_if_open(stdout_pipe[0]);
  close_if_open(stdout_pipe[1]);
#if !defined(__linux__)
  (void)pthread_mutex_unlock(&spawn_mutex);
#endif
  return rc;
}
