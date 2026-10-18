# SPDX-License-Identifier: MIT
# Copyright (c) Steppe contributors
"""Execute production shader and program lifecycle helpers with GL API mocks."""
from pathlib import Path
import os
import subprocess

pb = Path('pbemu.c').read_text()
gfx = Path('glfix.c').read_text()
shader = pb[pb.index('static char *patch_bush_shader('):pb.index('static void pb_ShaderSourceARB(GLhandleARB sh, GLsizei count, const GLcharARB **str, const GLint *len) {')]
bone = pb[pb.index('void pbemu_forget_program(uintptr_t p);'):]
lifecycle = gfx[gfx.index('static void gfx_LinkProgramARB('):gfx.index('static void gfx_UniformMatrix4fvARB(')]
prefix = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
typedef int GLint;
typedef int GLsizei;
typedef unsigned GLuint;
typedef uintptr_t GLhandleARB;
typedef char GLchar;
#define GL_CURRENT_PROGRAM 1
#define glfix_trace(...) ((void)0)
#define DYLD_INTERPOSE(a,b)
static GLint queried_location=7;
static int queries,links,deletes;
static uintptr_t glfix_get_cur_prog(void) { return 42; }
static void glGetIntegerv(int name,GLint *v) { (void)name;*v=42; }
static GLint glGetUniformLocation(GLuint p,const char *name) { (void)p;(void)name;queries++;return queried_location; }
static GLint glGetUniformLocationARB(GLhandleARB p,const char *name) { return glGetUniformLocation((GLuint)p,name); }
static void glLinkProgram(GLuint p) { (void)p;links++; }
static void glLinkProgramARB(GLhandleARB p) { (void)p;links++; }
static void glDeleteProgram(GLuint p) { (void)p;deletes++; }
static void glDeleteObjectARB(GLhandleARB p) { (void)p;deletes++; }
typedef struct { int narr; } ProgInfo;
static ProgInfo pi;
static pthread_mutex_t g_mu=PTHREAD_MUTEX_INITIALIZER;
static ProgInfo *findProg(uintptr_t p,int create) { (void)p;(void)create;return &pi; }
static void forgetProg(uintptr_t p) { (void)p; }
static void note_location(uintptr_t p,const char *name,GLint loc) { (void)p;(void)name;(void)loc; }
'''
suffix = r'''
int main(int argc,char **argv) {
 (void)argv;
 if(argc>1) {
  int n=0;assert(patch_bush_shader(1,NULL,NULL,&n)==NULL);
  assert(patch_bush_shader(0,NULL,NULL,&n)==NULL);
  const char *src="vec3 n=normalize(gl_NormalMatrix*gl_Normal);";
  char *patched=patch_bush_shader(1,&src,NULL,&n);
  assert(patched && strstr(patched,"dot(n,n)>1e-20") && n==(int)strlen(patched));free(patched);
  puts("PASS shader: NULL input, empty input and normal guard");return 0;
 }
 assert(pbemu_bone_loc(-1,42)==-1 && queries==0);
 assert(pbemu_bone_loc(3,42)==7);
 queried_location=9;pb_LinkProgram(42);assert(pbemu_bone_loc(3,42)==9);
 queried_location=11;pb_LinkProgramARB(42);assert(pbemu_bone_loc(3,42)==11);
 queried_location=13;gfx_LinkProgram(42);assert(pbemu_bone_loc(3,42)==13);
 queried_location=15;gfx_LinkProgramARB(42);assert(pbemu_bone_loc(3,42)==15);
 queried_location=17;gfx_DeleteProgram(42);assert(pbemu_bone_loc(3,42)==17);
 queried_location=19;gfx_DeleteObjectARB(42);assert(pbemu_bone_loc(3,42)==19);
 queried_location=-1;pb_LinkProgram(42);assert(pbemu_bone_loc(3,42)==3);
 assert(links==5 && deletes==2);
 puts("PASS BONEFIX: negative location, relink and delete via core/ARB and direct/resolved paths");
 return 0;
}
'''
Path('build/test_safety.c').write_text(prefix + shader + bone + lifecycle + suffix)
subprocess.run([os.environ.get('HOST_CC', 'clang'), '-std=c11', '-Wall', '-Wextra', '-Werror',
                '-pthread', 'build/test_safety.c', '-o', 'build/test_safety'], check=True)
results = [subprocess.run(['build/test_safety'] + args, timeout=10) for args in [[], ['shader']]]
raise SystemExit(any(result.returncode for result in results))
