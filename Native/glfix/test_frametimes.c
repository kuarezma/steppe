// SPDX-License-Identifier: MIT
// Copyright (c) Steppe contributors
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include "frametimes.h"

__attribute__((destructor)) static void finish(void) { frametimes_fini(); }

static void *worker(void *unused) {
  (void)unused;
  for (int i = 0; i < 1000; i++) frametimes_record();
  return NULL;
}

int main(void) {
  frametimes_init();
  if (!g_ft_path) {
    puts("FRAMETIMES_OFF_PASS");
    return 0;
  }
  errno = EDOM;
  frametimes_record();
  assert(errno == EDOM);
  if (g_ft_fd < 0) {
    puts("FRAMETIMES_OPEN_FAILURE_SAFE");
    return 0;
  }
  struct stat state;
  assert(!fstat(g_ft_fd, &state) && state.st_size == 0);
  pid_t child = fork();
  assert(child >= 0);
  if (!child) {
    frametimes_record();
    frametimes_fini();
    _exit(0);
  }
  int status;
  assert(waitpid(child, &status, 0) == child && status == 0);
  pthread_t threads[4];
  for (int i = 0; i < 4; i++) assert(!pthread_create(&threads[i], NULL, worker, NULL));
  for (int i = 0; i < 4; i++) assert(!pthread_join(threads[i], NULL));
  assert(!fstat(g_ft_fd, &state));
  assert(state.st_size > 0 && state.st_size % 4096 == 0);
  assert(g_ft_used > 0 && g_ft_used < 4096);
  puts("FRAMETIMES_PASS: 4001 events, 4 threads, 4096-byte blocks, fork isolation, errno");
  return 0;
}
