// SPDX-License-Identifier: MIT
// Copyright (c) Steppe contributors
#define GL_SILENCE_DEPRECATION 1
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl.h>
#include <OpenGL/glext.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <stdlib.h>

#define NBONES 42

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
    fprintf(stderr, "link fail: %s\n", log);
    exit(2);
  }
  return p;
}

int main(int argc, char **argv) {
  FILE *out = stdout;
  if (argc > 1) {
    out = fopen(argv[1], "w");
    if (!out) { perror("fopen"); return 1; }
  }

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

  const char *vs =
    "#define NBONES 42\n"
    "uniform mat4 boneMatrices[NBONES];\n"
    "varying vec4 v;\n"
    "void main(){ v=boneMatrices[int(gl_MultiTexCoord2.x)]*gl_Vertex; gl_Position=vec4(0,0,0,1); }\n";
  const char *fs = "varying vec4 v;\nvoid main(){ gl_FragColor=vec4(v.xyz,1.0); }\n";
  GLhandleARB prog = makeProg(vs, fs);
  glUseProgramObjectARB(prog);

  GLint base = glGetUniformLocationARB(prog, "boneMatrices[0]");
  GLfloat m[NBONES][16];
  for (int i = 0; i < NBONES; i++) {
    memset(m[i], 0, sizeof m[i]);
    m[i][0]=m[i][5]=m[i][10]=m[i][15]=1.0f;
    m[i][12]=(GLfloat)(i+1)/255.0f;
    m[i][13]=(GLfloat)(255-i)/255.0f;
    m[i][14]=0.5f;
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

  fprintf(out, "idx\teR\teG\teB\trR\trG\trB\tstatus\n");
  for (int i = 0; i < NBONES; i++) {
    glClearColor(0,0,0,0);
    glClear(GL_COLOR_BUFFER_BIT);
    glBegin(GL_POINTS);
    glMultiTexCoord2f(GL_TEXTURE2, (GLfloat)i, 0.0f);
    glVertex4f(0.1f, 0.2f, 0.3f, 1.0f);
    glEnd();
    unsigned char px[4] = {0, 0, 0, 0};
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
    int eR = (int)roundf(255*(0.1f + m[i][12]));
    int eG = (int)roundf(255*fminf(1.0f, 0.2f + m[i][13]));
    int eB = (int)roundf(255*(0.3f + m[i][14]));

    int is_pass = (abs(px[0]-eR) <= 2 && abs(px[1]-eG) <= 2 && abs(px[2]-eB) <= 2);
    fprintf(out, "%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n",
            i, eR, eG, eB, px[0], px[1], px[2], is_pass ? "PASS" : (px[0]==0&&px[1]==0&&px[2]==0 ? "ZERO" : "FAIL"));
  }

  glDeleteObjectARB(prog);
  CGLSetCurrentContext(NULL);
  CGLDestroyContext(ctx);
  CGLDestroyPixelFormat(pf);
  if (argc > 1) fclose(out);
  return 0;
}
