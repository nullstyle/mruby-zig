/* Test the native OS boundary, without adding bypass methods to Ruby. */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

static int denied(void) { return errno == EPERM || errno == EACCES; }

uint8_t mrz_effect_worker_probe_authority(void) {
  uint8_t result = 0;
  int file = open("/etc/passwd", O_RDONLY);
  if (file < 0 && denied()) result |= 1;
  if (file >= 0) close(file);

  int client = socket(AF_INET, SOCK_STREAM, 0);
  if (client < 0 && denied()) {
    /* Linux denies network socket creation itself. */
    result |= 2;
  } else if (client >= 0) {
    /* macOS permits allocation but denies external network authority. */
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
#ifdef __APPLE__
    address.sin_len = sizeof(address);
#endif
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons(9);
    (void)fcntl(client, F_SETFL, O_NONBLOCK);
    if (connect(client, (const struct sockaddr *)&address, sizeof(address)) < 0 && denied()) result |= 2;
    close(client);
  }

  int listener = socket(AF_INET, SOCK_STREAM, 0);
  if (listener < 0 && denied()) {
    result |= 4;
  } else if (listener >= 0) {
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
#ifdef __APPLE__
    address.sin_len = sizeof(address);
#endif
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    if (bind(listener, (const struct sockaddr *)&address, sizeof(address)) < 0 && denied()) result |= 4;
    close(listener);
  }
  return result;
}
