// SPDX-License-Identifier: MIT
// Copyright (c) Steppe contributors
#define GL_SILENCE_DEPRECATION 1
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl.h>
#include <OpenGL/glext.h>
#include <stdio.h>
#include <dlfcn.h>
static int fails = 0;
#include <libgen.h>
static const char *dirname_of(const char *p) { static char b[1024]; snprintf(b, sizeof b, "%s", p); return dirname(b); }
#define CHECK(c, msg) do { if (c) printf("PASS %s\n", msg); else { printf("FAIL %s\n", msg); fails++; } } while (0)
int main(int argc, char **argv) {
  (void)argc;
  char shim[1024]; snprintf(shim, sizeof shim, "%s/winemac.so", dirname_of(argv[0]));
  void *shimh = dlopen(shim, RTLD_NOW);
  CGLError (*wm_setcurrent)(CGLContextObj) = shimh ? (CGLError (*)(CGLContextObj))dlsym(shimh, "wm_setcurrent") : NULL;
  if (!wm_setcurrent) { printf("FAIL shim %s\n", shim); return 2; }
  CGLPixelFormatAttribute at[] = { kCGLPFAAccelerated, kCGLPFAColorSize, 24, kCGLPFAAlphaSize, 8,
                                   kCGLPFADepthSize, 24, kCGLPFAPBuffer, 0 };
  CGLPixelFormatObj pix; GLint npix;
  if (CGLChoosePixelFormat(at, &pix, &npix) || !pix) { printf("FAIL pixelformat\n"); return 2; }
  CGLContextObj a, b;
  CGLCreateContext(pix, NULL, &a); CGLCreateContext(pix, NULL, &b);
  CGLPBufferObj pb = NULL;
  CHECK(CGLCreatePBuffer(64, 64, GL_TEXTURE_2D, GL_RGBA, 0, &pb) == kCGLNoError && pb, "create pbuffer");
  GLsizei w = 0, h = 0; GLenum t = 0, f = 0; GLint mm = -1;
  CHECK(CGLDescribePBuffer(pb, &w, &h, &t, &f, &mm) == kCGLNoError && w == 64 && h == 64 && t == GL_TEXTURE_2D, "describe");
  CHECK(CGLSetPBuffer(a, pb, 0, 0, 0) == kCGLNoError, "set pbuffer");
  wm_setcurrent(a);
  GLint fb = 0; glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fb);
  CHECK(fb != 0, "fbo bound after make-current");
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  GLint fb2 = 0; glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fb2);
  CHECK(fb2 == fb, "bind 0 redirected to fbo");
  while (glGetError()) {}
  glDrawBuffer(GL_BACK);
  CHECK(glGetError() == GL_NO_ERROR, "glDrawBuffer(GL_BACK) no error");
  glClearColor(1, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT); glFinish();
  CGLSetCurrentContext(a);
  GLint fbw = -1; glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fbw);
  CHECK(fbw == 0, "window make-current restores framebuffer 0");
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  GLint fbw2 = -1; glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fbw2);
  CHECK(fbw2 == 0, "no redirect while on window");
  wm_setcurrent(a);
  GLint fbp = 0; glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fbp);
  CHECK(fbp == fb, "pbuffer make-current re-binds fbo");
  CGLSetCurrentContext(b);
  GLuint tex; glGenTextures(1, &tex); glBindTexture(GL_TEXTURE_2D, tex);
  CHECK(CGLTexImagePBuffer(b, pb, GL_FRONT_LEFT) == kCGLNoError, "teximage pbuffer");
  unsigned char px[64 * 64 * 4] = {0};
  glGetTexImage(GL_TEXTURE_2D, 0, GL_RGBA, GL_UNSIGNED_BYTE, px);
  printf("texel0 = %u %u %u %u\n", px[0], px[1], px[2], px[3]);
  CHECK(px[0] == 255 && px[1] == 0 && px[2] == 0 && px[3] == 255, "texture holds pbuffer contents (red)");
  CHECK(CGLTexImagePBuffer(b, pb, GL_NONE) == kCGLNoError, "release teximage");
  CGLReleasePBuffer(pb); CHECK(1, "release pbuffer");
  printf("%s (%d failures)\n", fails ? "PBEMU TEST FAILED" : "PBEMU TEST PASSED", fails);
  return fails ? 1 : 0;
}
