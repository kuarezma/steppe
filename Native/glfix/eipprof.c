// SPDX-License-Identifier: MIT
// Copyright (c) Steppe contributors
// Optional Mach instruction-pointer sampler; excluded from the production library.
#include "eipprof.h"
#include <mach/mach.h>
#include <mach/i386/thread_status.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define SAMPLE_LIMIT 20000
#define PE_LIMIT UINT64_C(0x80000000)
typedef struct {
  uint64_t rip, returns[4];
  uint32_t cs;
  kern_return_t suspend_rc, state_rc, resume_rc;
} Sample;
typedef struct { uint64_t address; unsigned count; } Bucket;
static Sample samples[SAMPLE_LIMIT];
static Bucket buckets[SAMPLE_LIMIT];
static const char *keys[] = {"GLFIX_EIPPROF", "GLFIX_EIPPROF_START", "GLFIX_EIPPROF_OUT"};
static char values[3][1024], log_path[1024];
static thread_t target;
static int enabled;

void eipprof_init(void) {
  for (unsigned i = 0; i < 3; i++) {
    const char *v = getenv(keys[i]);
    if (v) strlcpy(values[i], v, sizeof values[i]);
  }
  const char *log = getenv("GLFIX_LOG");
  if (log) strlcpy(log_path, log, sizeof log_path);
  enabled = !strcmp(values[0], "1") && values[1][0] && values[2][0];
}

int eipprof_env_key(const char *entry) {
  for (unsigned i = 0; i < 3; i++) {
    size_t length = strlen(keys[i]);
    if (!strncmp(entry, keys[i], length) && entry[length] == '=') return 1;
  }
  return 0;
}

int eipprof_build_env(char **env, int count) {
  for (unsigned i = 0; i < 3; i++) {
    char *entry = NULL;
    if (values[i][0] && asprintf(&entry, "%s=%s", keys[i], values[i]) >= 0)
      env[count++] = entry;
  }
  return count;
}

void eipprof_ensure_env(void) {
  for (unsigned i = 0; i < 3; i++)
    if (values[i][0] && !getenv(keys[i])) setenv(keys[i], values[i], 1);
}

static double monotonic(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static int valid_pe(uint64_t address) {
  return address >= 0x10000 && address < PE_LIMIT;
}

static void collect(Sample *sample) {
  sample->state_rc = KERN_FAILURE;
  sample->resume_rc = KERN_FAILURE;
  sample->suspend_rc = thread_suspend(target);
  if (sample->suspend_rc != KERN_SUCCESS) return;
#ifdef __x86_64__
  x86_thread_state64_t state;
  mach_msg_type_number_t count = x86_THREAD_STATE64_COUNT;
  sample->state_rc = thread_get_state(target, x86_THREAD_STATE64,
                                    (thread_state_t)&state, &count);
  if (sample->state_rc == KERN_SUCCESS && count == x86_THREAD_STATE64_COUNT) {
    sample->rip = state.__rip;
    sample->cs = (uint32_t)state.__cs;
    uint64_t ebp = state.__rbp;
    if (valid_pe(sample->rip)) {
      for (unsigned depth = 0; depth < 4; depth++) {
        if (!valid_pe(ebp) || ebp > PE_LIMIT - 8 || (ebp & 3)) break;
        uint32_t frame[2];
        vm_size_t bytes = 0;
        kern_return_t rc = vm_read_overwrite(mach_task_self(), (vm_address_t)ebp,
                       sizeof frame, (vm_address_t)frame, &bytes);
        if (rc != KERN_SUCCESS || bytes != sizeof frame || !valid_pe(frame[1])) break;
        sample->returns[depth] = frame[1];
        if (frame[0] <= ebp) break;
        ebp = frame[0];
      }
    }
  } else if (sample->state_rc == KERN_SUCCESS) sample->state_rc = KERN_INVALID_ARGUMENT;
#endif

  sample->resume_rc = thread_resume(target);
}

static int compare_address(const void *a, const void *b) {
  const Bucket *x = a, *y = b;
  return (x->address > y->address) - (x->address < y->address);
}
static int compare_count(const void *a, const void *b) {
  const Bucket *x = a, *y = b;
  if (x->count != y->count) return x->count < y->count ? 1 : -1;
  return compare_address(a, b);
}
static int valid_sample(const Sample *s) {
  return s->suspend_rc == KERN_SUCCESS && s->state_rc == KERN_SUCCESS
         && s->resume_rc == KERN_SUCCESS;
}
static void dump(FILE *out, unsigned count, double elapsed) {
  unsigned valid = 0, pe = 0, wide = 0;
  for (unsigned i = 0; i < count; i++) {
    if (!valid_sample(&samples[i])) continue;
    valid++;
    if (valid_pe(samples[i].rip)) pe++;
    else if (samples[i].rip >= PE_LIMIT) wide++;
  }
  fprintf(out, "EIPPROF pid=%d thread_port=%u samples=%u valid=%u pe32=%u wide64=%u other=%u elapsed=%.6f\n",
          getpid(), target, count, valid, pe, wide, valid - pe - wide, elapsed);
  fprintf(out, "RAW index rip cs ret1 ret2 ret3 ret4 suspend_rc state_rc resume_rc\n");
  for (unsigned i = 0; i < count; i++) {
    Sample *s = &samples[i];
    fprintf(out, "EIPRAW %u 0x%llx 0x%x 0x%llx 0x%llx 0x%llx 0x%llx %d %d %d\n",
        i, (unsigned long long)s->rip, s->cs, (unsigned long long)s->returns[0],
        (unsigned long long)s->returns[1], (unsigned long long)s->returns[2],
        (unsigned long long)s->returns[3], s->suspend_rc, s->state_rc, s->resume_rc);
  }
  const unsigned sizes[] = {4096, 64};
  for (unsigned pass = 0; pass < 2; pass++) {
    unsigned n = 0, unique = 0;
    for (unsigned i = 0; i < count; i++) {
      if (valid_sample(&samples[i]) && samples[i].rip) {
        buckets[n++] = (Bucket){samples[i].rip & ~((uint64_t)sizes[pass] - 1), 1};
      }
    }
    qsort(buckets, n, sizeof buckets[0], compare_address);
    for (unsigned i = 0; i < n; i++) {
      if (unique && buckets[unique - 1].address == buckets[i].address)
        buckets[unique - 1].count++;
      else buckets[unique++] = buckets[i];
    }
    qsort(buckets, unique, sizeof buckets[0], compare_count);
    for (unsigned i = 0; i < unique && i < 40; i++)
      fprintf(out, "EIPBUCKET %u 0x%llx %u %.6f\n", sizes[pass],
          (unsigned long long)buckets[i].address, buckets[i].count,
          valid ? (double)buckets[i].count / valid : 0);
  }
  fprintf(out, "EIPPROF_DONE pid=%d\n", getpid());
}

static void *sampler(void *unused) {
  (void)unused;

  for (;;) {
    FILE *trigger = fopen(values[1], "r");
    int pid = 0;
    if (trigger) { (void)fscanf(trigger, "%d", &pid); fclose(trigger); }
    if (pid == getpid()) break;
    struct timespec delay = {0, 100000000};
    nanosleep(&delay, NULL);
  }

  memset(samples, 0, sizeof samples);
  double start = monotonic(), next = start;
  unsigned count = 0;
  while (count < SAMPLE_LIMIT && monotonic() - start < 20.0) {
    collect(&samples[count]);
    if (samples[count].suspend_rc == KERN_SUCCESS && samples[count].resume_rc != KERN_SUCCESS)
      _exit(74);
    count++;
    next += 0.001;
    double now = monotonic();
    if (next < now) next = now;
    double wait = next - now;
    struct timespec delay = {0, (long)(wait * 1e9)};
    nanosleep(&delay, NULL);
  }
  double elapsed = monotonic() - start;
  FILE *out = fopen(values[2], "w");
  if (out) { dump(out, count, elapsed); fclose(out); }
  FILE *log = log_path[0] ? fopen(log_path, "a") : NULL;
  if (log) { dump(log, count, elapsed); fclose(log); }
  mach_port_deallocate(mach_task_self(), target);
  return NULL;
}

void eipprof_start(void) {
  if (!enabled) return;
  target = mach_thread_self();
  pthread_t worker;
  if (pthread_create(&worker, NULL, sampler, NULL) == 0) pthread_detach(worker);
  else mach_port_deallocate(mach_task_self(), target);
}
