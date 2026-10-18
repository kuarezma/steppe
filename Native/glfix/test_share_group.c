// SPDX-License-Identifier: MIT
// Copyright (c) Steppe contributors
#define GL_SILENCE_DEPRECATION 1
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl.h>
#include <OpenGL/glext.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define NBONES 42

static GLhandleARB makeProg(const char *vs, const char *fs) {
  GLhandleARB v = glCreateShaderObjectARB(GL_VERTEX_SHADER_ARB);
  glShaderSourceARB(v, 1, &vs, NULL);
  glCompileShaderARB(v);
  GLhandleARB f = glCreateShaderObjectARB(GL_FRAGMENT_SHADER_ARB);
  glShaderSourceARB(f, 1, &fs, NULL);
  glCompileShaderARB(f);
  GLhandleARB p = glCreateProgramObjectARB();
  glAttachObjectARB(p, v);
  glAttachObjectARB(p, f);
  glLinkProgramARB(p);
  GLint ok = 0;
  glGetObjectParameterivARB(p, GL_OBJECT_LINK_STATUS_ARB, &ok);
  if (!ok) {
    char log[2048];
    glGetInfoLogARB(p, sizeof log, NULL, log);
    fprintf(stderr, "link fail: %s\n", log);
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
  CGLPixelFormatObj pf;
  GLint np;
  CGLChoosePixelFormat(attrs, &pf, &np);

  CGLContextObj ctxA = NULL, ctxB = NULL, ctxC = NULL;
  CGLCreateContext(pf, NULL, &ctxA);
  CGLCreateContext(pf, ctxA, &ctxB);
  CGLCreateContext(pf, NULL, &ctxC);

  CGLShareGroupObj sgA = CGLGetShareGroup(ctxA);
  CGLShareGroupObj sgB = CGLGetShareGroup(ctxB);
  CGLShareGroupObj sgC = CGLGetShareGroup(ctxC);

  printf("SHARE_GROUP_CHECK: sgA=%p sgB=%p sgC=%p (shared: %s, independent: %s)\n",
         sgA, sgB, sgC, (sgA == sgB) ? "YES" : "NO", (sgA != sgC) ? "YES" : "NO");

  if (sgA != sgB || sgA == sgC) {
    fprintf(stderr, "FAIL: CGL share group hierarchy invalid\n");
    return 2;
  }

  CGLSetCurrentContext(ctxA);
  const char *vsA =
    "#define NBONES 42\n"
    "uniform mat4 boneMatrices[NBONES];\n"
    "varying vec4 v;\n"
    "void main(){ v=boneMatrices[int(gl_MultiTexCoord2.x)]*gl_Vertex; gl_Position=vec4(0,0,0,1); }\n";
  const char *fsA = "varying vec4 v;\nvoid main(){ gl_FragColor=vec4(v.xyz,1.0); }\n";
  GLhandleARB progA = makeProg(vsA, fsA);

  GLint base = glGetUniformLocationARB(progA, "boneMatrices[0]");
  if (base < 0) {
    fprintf(stderr, "FAIL: glGetUniformLocationARB boneMatrices[0] failed\n");
    return 2;
  }

  CGLSetCurrentContext(ctxB);
  glUseProgramObjectARB(progA);

  GLfloat m[NBONES][16];
  for (int i = 0; i < NBONES; i++) {
    memset(m[i], 0, sizeof m[i]);
    m[i][0] = m[i][5] = m[i][10] = m[i][15] = 1.0f;
    m[i][12] = (GLfloat)(i + 1) / 255.0f;
    m[i][13] = (GLfloat)(255 - i) / 255.0f;
    m[i][14] = 0.5f;
  }
  while (glGetError()) {}

  for (int i = 0; i < NBONES; i++) {
    glUniformMatrix4fvARB(base + i, 1, GL_FALSE, m[i]);
  }

  GLuint fbo, rb;
  glGenFramebuffersEXT(1, &fbo);
  glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, fbo);
  glGenRenderbuffersEXT(1, &rb);
  glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, rb);
  glRenderbufferStorageEXT(GL_RENDERBUFFER_EXT, GL_RGBA8, 1, 1);
  glFramebufferRenderbufferEXT(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT, GL_RENDERBUFFER_EXT, rb);
  glViewport(0, 0, 1, 1);

  int fail = 0;
  for (int i = 0; i < NBONES; i++) {
    glClearColor(0, 0, 0, 0);
    glClear(GL_COLOR_BUFFER_BIT);
    glBegin(GL_POINTS);
    glMultiTexCoord2f(GL_TEXTURE2, (GLfloat)i, 0.0f);
    glVertex4f(0.1f, 0.2f, 0.3f, 1.0f);
    glEnd();
    unsigned char px[4] = {0, 0, 0, 0};
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
    int eR = (int)roundf(255 * (0.1f + m[i][12]));
    int eG = (int)roundf(255 * fminf(1.0f, 0.2f + m[i][13]));
    int eB = (int)roundf(255 * (0.3f + m[i][14]));
    if (abs(px[0] - eR) > 2 || abs(px[1] - eG) > 2 || abs(px[2] - eB) > 2) {
      fail++;
    }
  }

  printf("SHARED_CONTEXT_RESULT: %d/%d bones correct across shared context (ctxA->ctxB)\n",
         NBONES - fail, NBONES);

  CGLSetCurrentContext(ctxC);
  const char *vsC =
    "uniform mat4 independentMat[4];\n"
    "void main(){ gl_Position=independentMat[0]*gl_Vertex; }\n";
  const char *fsC = "void main(){ gl_FragColor=vec4(1.0); }\n";
  GLhandleARB progC = makeProg(vsC, fsC);
  glUseProgramObjectARB(progC);

  GLint baseC = glGetUniformLocationARB(progC, "independentMat[0]");
  GLfloat dummyM[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};
  glUniformMatrix4fvARB(baseC, 1, GL_FALSE, dummyM);
  GLenum errC = glGetError();
  printf("INDEPENDENT_CONTEXT_RESULT: progC=%lu err=0x%x (isolation intact)\n",
         (unsigned long)progC, (unsigned int)errC);

  CGLSetCurrentContext(ctxA);
  glDeleteObjectARB(progA);
  CGLSetCurrentContext(ctxC);
  glDeleteObjectARB(progC);

  CGLSetCurrentContext(NULL);
  CGLDestroyContext(ctxA);
  CGLDestroyContext(ctxB);
  CGLDestroyContext(ctxC);
  CGLDestroyPixelFormat(pf);

  if (fail != 0) {
    fprintf(stderr, "FAIL: shared context test failed (%d bones incorrect)\n", fail);
    return 1;
  }
  if (errC != GL_NO_ERROR) {
    fprintf(stderr, "FAIL: independent context had GL error 0x%x\n", (unsigned int)errC);
    return 1;
  }

  printf("RESULT: PASS (share group tracking and context isolation verified)\n");
  return 0;
}
