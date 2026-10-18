// SPDX-License-Identifier: MIT
// Copyright (c) Steppe contributors
// Buffered color-clear timestamps; disabled without an explicit output prefix.
#include <mach/mach_time.h>
#include <inttypes.h>

static char *g_ft_path;
static int g_ft_fd = -1;
static char g_ft_buffer[4096];
static size_t g_ft_used;
static mach_timebase_info_data_t g_ft_timebase;
static pthread_mutex_t g_ft_mu = PTHREAD_MUTEX_INITIALIZER;

static int frametimes_write(size_t bytes) {
  size_t offset = 0;
  while (offset < bytes) {
    ssize_t n = write(g_ft_fd, g_ft_buffer + offset, bytes - offset);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) {
      fprintf(stderr, "[glfix] Cannot write frame timing log: %s\n", strerror(errno));
      close(g_ft_fd);
      g_ft_fd = -2;
      g_ft_used = 0;
      return 0;
    }
    offset += (size_t)n;
  }
  g_ft_used = 0;
  return 1;
}

static void frametimes_fork_prepare(void) { pthread_mutex_lock(&g_ft_mu); }
static void frametimes_fork_parent(void) { pthread_mutex_unlock(&g_ft_mu); }
static void frametimes_fork_child(void) {

  if (g_ft_fd >= 0) close(g_ft_fd);
  g_ft_fd = -2;
  g_ft_used = 0;
  pthread_mutex_unlock(&g_ft_mu);
}

static void frametimes_init(void) {
  const char *path = getenv("GLFIX_FRAMETIMES");
  if (!path || !*path) return;
  if (mach_timebase_info(&g_ft_timebase) != KERN_SUCCESS || !g_ft_timebase.denom) return;
  g_ft_path = strdup(path);
  if (g_ft_path && pthread_atfork(frametimes_fork_prepare, frametimes_fork_parent,
                                frametimes_fork_child)) {
    free(g_ft_path);
    g_ft_path = NULL;
  }
}

static void frametimes_record(void) {
  int saved_errno = errno;
  pthread_mutex_lock(&g_ft_mu);
  if (g_ft_fd == -1) {

    char pid_path[1024];
    snprintf(pid_path, sizeof pid_path, "%s.%d", g_ft_path, (int)getpid());
    g_ft_fd = open(pid_path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (g_ft_fd < 0) {
      fprintf(stderr, "[glfix] Cannot open frame timing file: %s\n", strerror(errno));
      g_ft_fd = -2;
    }
  }
  if (g_ft_fd >= 0) {
    uint64_t ns = (uint64_t)(((__uint128_t)mach_absolute_time() *
                             g_ft_timebase.numer) / g_ft_timebase.denom);
    char line[32];
    size_t length = (size_t)snprintf(line, sizeof line, "%" PRIu64 "\n", ns);
    size_t copied = 0;
    while (copied < length) {
      size_t bytes = sizeof g_ft_buffer - g_ft_used;
      if (bytes > length - copied) bytes = length - copied;
      memcpy(g_ft_buffer + g_ft_used, line + copied, bytes);
      g_ft_used += bytes;
      copied += bytes;
      if (g_ft_used == sizeof g_ft_buffer && !frametimes_write(g_ft_used)) break;
    }
  }
  pthread_mutex_unlock(&g_ft_mu);
  errno = saved_errno;
}

static void frametimes_fini(void) {
  if (!g_ft_path) return;
  pthread_mutex_lock(&g_ft_mu);
  if (g_ft_fd >= 0) {
    if (g_ft_used) frametimes_write(g_ft_used);
    if (g_ft_fd >= 0) close(g_ft_fd);
  }
  g_ft_fd = -2;
  pthread_mutex_unlock(&g_ft_mu);
}
