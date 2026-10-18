// SPDX-License-Identifier: MIT
// Copyright (c) Steppe contributors
#define GL_SILENCE_DEPRECATION 1
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl.h>
#include <OpenGL/glext.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void (*PFNGLPROGRAMUNIFORMMATRIX4FV)(GLuint, GLint, GLsizei, GLboolean, const GLfloat *);

static GLhandleARB makeProg(const char *vs, const char *fs) {
  GLhandleARB v = glCreateShaderObjectARB(GL_VERTEX_SHADER_ARB);
  glShaderSourceARB(v, 1, &vs, NULL); glCompileShaderARB(v);
  GLhandleARB f = glCreateShaderObjectARB(GL_FRAGMENT_SHADER_ARB);
  glShaderSourceARB(f, 1, &fs, NULL); glCompileShaderARB(f);
  GLhandleARB p = glCreateProgramObjectARB();
  glAttachObjectARB(p, v); glAttachObjectARB(p, f); glLinkProgramARB(p);
  GLint ok = 0; glGetObjectParameterivARB(p, GL_OBJECT_LINK_STATUS_ARB, &ok);
  if (!ok) {
    char log[2048]; glGetInfoLogARB(p, sizeof log, NULL, log);
    fprintf(stderr, "Shader link fail: %s\n", log);
    exit(2);
  }
  return p;
}

int main(void) {
  CGLPixelFormatAttribute attrs[] = {
    kCGLPFAAccelerated,
    kCGLPFAColorSize, (CGLPixelFormatAttribute)24,
    (CGLPixelFormatAttribute)0
  };
  CGLPixelFormatObj pf; GLint np;
  CGLChoosePixelFormat(attrs, &pf, &np);
  CGLContextObj ctx;
  CGLCreateContext(pf, NULL, &ctx);
  CGLSetCurrentContext(ctx);

  const char *vs1 = "void main(){ gl_Position=vec4(0,0,0,1); }\n";
  const char *fs1 = "void main(){ gl_FragColor=vec4(1,0,0,1); }\n";
  GLhandleARB prog1 = makeProg(vs1, fs1);

  const char *vs2 =
    "uniform mat4 boneMatrices[4];\n"
    "void main(){ gl_Position=boneMatrices[0]*vec4(0,0,0,1); }\n";
  const char *fs2 = "void main(){ gl_FragColor=vec4(0,1,0,1); }\n";
  GLhandleARB prog2 = makeProg(vs2, fs2);

  glUseProgramObjectARB(prog1);
  GLint cur_before = 0;
  glGetIntegerv(GL_CURRENT_PROGRAM, &cur_before);

  PFNGLPROGRAMUNIFORMMATRIX4FV pfn =
      (PFNGLPROGRAMUNIFORMMATRIX4FV)dlsym(RTLD_DEFAULT, "glProgramUniformMatrix4fv");
  if (!pfn) {
    pfn = (PFNGLPROGRAMUNIFORMMATRIX4FV)dlsym(RTLD_DEFAULT, "glProgramUniformMatrix4fvEXT");
  }
  if (!pfn) {
    fprintf(stderr, "glProgramUniformMatrix4fv not found via dlsym\n");
    return 2;
  }

  GLint loc = glGetUniformLocationARB(prog2, "boneMatrices[0]");
  GLfloat m[16] = { 1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1 };

  pfn((GLuint)(uintptr_t)prog2, loc, 1, GL_FALSE, m);

  GLint cur_after = 0;
  glGetIntegerv(GL_CURRENT_PROGRAM, &cur_after);

  printf("PROG_UNIFORM_TEST: before=%d after=%d prog1=%lu prog2=%lu\n",
         cur_before, cur_after, (unsigned long)prog1, (unsigned long)prog2);

  glDeleteObjectARB(prog1);
  glDeleteObjectARB(prog2);
  CGLSetCurrentContext(NULL);
  CGLDestroyContext(ctx);
  CGLDestroyPixelFormat(pf);

  if (cur_after != cur_before) {
    printf("RESULT: FAIL (GL_CURRENT_PROGRAM clobbered to %d instead of %d)\n", cur_after, cur_before);
    return 1;
  }

  printf("RESULT: PASS (GL_CURRENT_PROGRAM preserved at %d)\n", cur_after);
  return 0;
}
