// SPDX-License-Identifier: MIT
// Copyright (c) Steppe contributors
#define GL_SILENCE_DEPRECATION 1
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

int main(void) {
  CGLPixelFormatAttribute attrs[] = {kCGLPFAAccelerated, (CGLPixelFormatAttribute)0};
  CGLPixelFormatObj format;
  CGLContextObj context;
  GLint count;
  if (CGLChoosePixelFormat(attrs, &format, &count) != kCGLNoError) return 3;
  if (CGLCreateContext(format, NULL, &context) != kCGLNoError) return 4;
  CGLDestroyPixelFormat(format);
  if (CGLSetCurrentContext(context) != kCGLNoError) return 5;
  const char *trigger = getenv("GLFIX_EIPPROF_START");
  if (!trigger) return 1;
  FILE *out = fopen(trigger, "w");
  if (!out) return 2;
  fprintf(out, "%d\n", getpid());
  fclose(out);
  glClear(GL_COLOR_BUFFER_BIT);

  struct timespec begin, now;
  clock_gettime(CLOCK_MONOTONIC, &begin);
  volatile unsigned counter = 0;
  do {
    counter++;
    clock_gettime(CLOCK_MONOTONIC, &now);
  } while (now.tv_sec - begin.tv_sec < 22);
  puts("EIPPROF_NATIVE_TARGET_RESUMED");
  return counter == 0;
}
