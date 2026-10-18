// SPDX-License-Identifier: MIT
// Copyright (c) Steppe contributors
// Check the return-address boundary used by pbemu without creating a GL context.
#define GL_SILENCE_DEPRECATION 1
#include <OpenGL/OpenGL.h>
#include <dlfcn.h>
#include <stddef.h>

#ifdef TEST_CALLER_INTERPOSER
static void *caller_image;

static CGLError capture_current_caller(CGLContextObj ctx) {
  (void)ctx;
  Dl_info info;
  caller_image = dladdr(__builtin_return_address(0), &info) ? info.dli_fbase : NULL;
  return kCGLNoError;
}

__attribute__((used)) static struct { const void *replacement; const void *original; }
    caller_interpose __attribute__((section("__DATA,__interpose"))) = {
        (const void *)&capture_current_caller, (const void *)&CGLSetCurrentContext};

int test_caller_matches(const void *symbol) {
  Dl_info info;
  if (!caller_image || !dladdr(symbol, &info)) return -1;
  return caller_image == info.dli_fbase;
}
#else
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
  if (argc != 2) return 2;
  void *shim = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  CGLError (*set_current)(CGLContextObj) = shim ? dlsym(shim, "wm_setcurrent") : NULL;
  int (*matches)(const void *) = dlsym(RTLD_DEFAULT, "test_caller_matches");
  Dl_info info;
  char *expected = realpath(argv[1], NULL);
  char *loaded = set_current && dladdr((const void *)set_current, &info)
                     ? realpath(info.dli_fname, NULL) : NULL;
  int same_file = expected && loaded && !strcmp(expected, loaded);
  free(expected);
  free(loaded);
  if (!same_file || !matches) {
    puts("WINEMAC_CALLER_FAIL: fixture or interposer not loaded");
    return 2;
  }
  set_current(NULL);
  if (matches((const void *)set_current) != 1) {
    puts("WINEMAC_CALLER_FAIL: shim return address lost");
    return 1;
  }
  CGLSetCurrentContext(NULL);
  if (matches((const void *)set_current) != 0) {
    puts("WINEMAC_CALLER_FAIL: direct call misidentified");
    return 1;
  }
  puts("WINEMAC_CALLER_PASS: shim and direct callers distinguished");
  return 0;
}
#endif
