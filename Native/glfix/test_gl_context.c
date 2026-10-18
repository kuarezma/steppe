// SPDX-License-Identifier: MIT
// Copyright (c) Steppe contributors
#define GL_SILENCE_DEPRECATION 1
#include <OpenGL/OpenGL.h>
#include <stdio.h>
int main(void) {
  CGLPixelFormatAttribute attrs[] = {kCGLPFAAccelerated, 0};
  CGLPixelFormatObj pf = NULL;
  CGLContextObj ctx = NULL;
  GLint count = 0;
  CGLError error = CGLChoosePixelFormat(attrs, &pf, &count);
  if (error || !pf || !count) { printf("SKIP: accelerated GL pixel format unavailable (%d)\n", error); return 77; }
  error = CGLCreateContext(pf, NULL, &ctx);
  CGLDestroyPixelFormat(pf);
  if (error || !ctx) { printf("SKIP: GL context unavailable (%d)\n", error); return 77; }
  error = CGLSetCurrentContext(ctx);
  CGLSetCurrentContext(NULL);
  CGLDestroyContext(ctx);
  return error ? 77 : 0;
}
