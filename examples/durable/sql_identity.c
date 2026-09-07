/* Keep struct stat's platform-specific ABI in C. Zig's pinned standard
 * library deliberately does not expose it for every supported Linux target. */
#include <errno.h>
#include <sys/stat.h>

int mrz_durable_same_file(const char *first, const char *second, int allow_missing, int *same) {
  struct stat left, right;
  *same = 0;
  if (stat(first, &left) != 0) return errno;
  if (stat(second, &right) != 0) {
    if (allow_missing && errno == ENOENT) return 0;
    return errno;
  }
  *same = left.st_dev == right.st_dev && left.st_ino == right.st_ino;
  return 0;
}
