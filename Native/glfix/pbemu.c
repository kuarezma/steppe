// SPDX-License-Identifier: MIT
// Copyright (c) Steppe contributors
// Emulate CGL pbuffers with per-context FBOs and shared color/depth storage.
// Window make-current restores framebuffer zero; Wine make-current selects the FBO.
// Shader version and zero-normal repairs preserve the game lighting path.
#define GL_SILENCE_DEPRECATION 1
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl.h>
#include <OpenGL/glext.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>

#define DYLD_INTERPOSE(_repl, _orig) \
  __attribute__((used)) static struct { const void *r; const void *o; } \
  _pbemu_interpose_##_orig __attribute__((section("__DATA,__interpose"))) = \
  { (const void *)(unsigned long)&_repl, (const void *)(unsigned long)&_orig };

void glfix_trace(const char *fmt, ...);
int glfix_log_enabled(void);
#define glfix_trace(...) do { if (glfix_log_enabled()) glfix_trace(__VA_ARGS__); } while (0)
uintptr_t glfix_get_cur_prog(void);

#define PB_MAGIC 0x50424d55u
#define MAXASSOC 64

typedef struct PBuf {
  uint32_t magic;
  int refs;
  GLsizei w, h;
  GLenum target, ifmt;
  GLint maxlvl;
  GLuint tex, rb;
  uintptr_t sharegroup;
} PBuf;

typedef struct Assoc {
  CGLContextObj ctx;
  PBuf *pb;
  GLuint fbo;
  int ready;
  int viewport_done;
  int active;
} Assoc;

static Assoc g_assoc[MAXASSOC];
static pthread_mutex_t g_pmu = PTHREAD_MUTEX_INITIALIZER;

#define MAXPB 4096
static PBuf *g_pbs[MAXPB];
static int g_npbs;

static int is_pb(CGLPBufferObj p) {
  if (!p) return 0;
  for (int i = 0; i < g_npbs; i++)
    if (g_pbs[i] == (PBuf *)p) return 1;
  return 0;
}

static Assoc *assoc_for_ctx(CGLContextObj ctx) {
  for (int i = 0; i < MAXASSOC; i++)
    if (g_assoc[i].ctx && g_assoc[i].ctx == ctx) return &g_assoc[i];
  return NULL;
}

static Assoc *assoc_for_pb(PBuf *pb) {
  for (int i = 0; i < MAXASSOC; i++)
    if (g_assoc[i].ctx && g_assoc[i].pb == pb) return &g_assoc[i];
  return NULL;
}

static void ensure_objects(Assoc *a) {
  if (a->ready) return;
  PBuf *pb = a->pb;
  uintptr_t sg = (uintptr_t)CGLGetShareGroup(a->ctx);
  GLint prevTex = 0, prevRb = 0;
  glGetIntegerv(GL_TEXTURE_BINDING_2D, &prevTex);
  glGetIntegerv(GL_RENDERBUFFER_BINDING, &prevRb);
  if (!pb->tex) {
    glGenTextures(1, &pb->tex);
    glBindTexture(GL_TEXTURE_2D, pb->tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, pb->w, pb->h, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glGenRenderbuffers(1, &pb->rb);
    glBindRenderbuffer(GL_RENDERBUFFER, pb->rb);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, pb->w, pb->h);
    pb->sharegroup = sg;
  } else if (pb->sharegroup != sg) {
    glfix_trace("PBEMU WARNING ctx=%p not in pbuffer share group; contents not visible", (void *)a->ctx);
  }
  glGenFramebuffers(1, &a->fbo);
  glBindFramebuffer(GL_FRAMEBUFFER, a->fbo);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, pb->tex, 0);
  glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, pb->rb);
  glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER, pb->rb);
  GLenum st = glCheckFramebufferStatus(GL_FRAMEBUFFER);
  glBindTexture(GL_TEXTURE_2D, (GLuint)prevTex);
  glBindRenderbuffer(GL_RENDERBUFFER, (GLuint)prevRb);
  glDrawBuffer(GL_COLOR_ATTACHMENT0);
  glReadBuffer(GL_COLOR_ATTACHMENT0);
  if (!a->viewport_done) { glViewport(0, 0, pb->w, pb->h); a->viewport_done = 1; }
  a->ready = 1;
  a->active = 1;
  glfix_trace("PBEMU fbo ctx=%p pb=%p %dx%d fbo=%u tex=%u sg=%p status=0x%x", (void *)a->ctx, (void *)pb,
              pb->w, pb->h, a->fbo, pb->tex, (void *)sg, st);
}

static CGLError pb_CGLCreatePBuffer(GLsizei w, GLsizei h, GLenum target, GLenum ifmt, GLint maxlvl,
                                    CGLPBufferObj *obj) {
  if (!obj || w <= 0 || h <= 0) return kCGLBadValue;
  PBuf *pb = calloc(1, sizeof *pb);
  if (!pb) return kCGLBadAlloc;
  pb->magic = PB_MAGIC; pb->refs = 1; pb->w = w; pb->h = h;
  pb->target = target; pb->ifmt = ifmt; pb->maxlvl = maxlvl;
  pthread_mutex_lock(&g_pmu);
  if (g_npbs < MAXPB) g_pbs[g_npbs++] = pb;
  pthread_mutex_unlock(&g_pmu);
  *obj = (CGLPBufferObj)pb;
  glfix_trace("PBEMU create pb=%p %dx%d target=0x%x ifmt=0x%x", (void *)pb, w, h, target, ifmt);
  return kCGLNoError;
}
DYLD_INTERPOSE(pb_CGLCreatePBuffer, CGLCreatePBuffer)

static CGLError pb_CGLDescribePBuffer(CGLPBufferObj obj, GLsizei *w, GLsizei *h, GLenum *target,
                                      GLenum *ifmt, GLint *mipmap) {
  if (!is_pb(obj)) return kCGLBadValue;
  PBuf *pb = (PBuf *)obj;
  if (w) *w = pb->w;
  if (h) *h = pb->h;
  if (target) *target = pb->target;
  if (ifmt) *ifmt = pb->ifmt;
  if (mipmap) *mipmap = pb->maxlvl;
  return kCGLNoError;
}
DYLD_INTERPOSE(pb_CGLDescribePBuffer, CGLDescribePBuffer)

static void pb_CGLReleasePBuffer(CGLPBufferObj obj) {
  if (!is_pb(obj)) { glfix_trace("PBEMU release ignored unknown %p", (void *)obj); return; }

  PBuf *pb = (PBuf *)obj;
  pthread_mutex_lock(&g_pmu);
  pb->refs--;
  pthread_mutex_unlock(&g_pmu);
}
DYLD_INTERPOSE(pb_CGLReleasePBuffer, CGLReleasePBuffer)

static CGLError pb_CGLSetPBuffer(CGLContextObj ctx, CGLPBufferObj obj, GLenum face, GLint level, GLint screen) {
  (void)face; (void)level; (void)screen;
  if (obj && !is_pb(obj)) return kCGLBadValue;
  pthread_mutex_lock(&g_pmu);
  Assoc *a = assoc_for_ctx(ctx);
  if (!obj) { if (a) memset(a, 0, sizeof *a); pthread_mutex_unlock(&g_pmu); return kCGLNoError; }
  if (a && a->pb != (PBuf *)obj) memset(a, 0, sizeof *a), a = NULL;
  if (!a)
    for (int i = 0; i < MAXASSOC; i++)
      if (!g_assoc[i].ctx) { a = &g_assoc[i]; a->ctx = ctx; a->pb = (PBuf *)obj; break; }
  pthread_mutex_unlock(&g_pmu);
  return a ? kCGLNoError : kCGLBadAlloc;
}
DYLD_INTERPOSE(pb_CGLSetPBuffer, CGLSetPBuffer)

static int caller_is_winemac(const void *ra) {
  Dl_info di;
  if (!ra || !dladdr(ra, &di) || !di.dli_fname) return 0;
  size_t n = strlen(di.dli_fname);
  return n >= 10 && !strcmp(di.dli_fname + n - 10, "winemac.so");
}

static CGLError pb_CGLSetCurrentContext(CGLContextObj ctx) {
  const void *ra = __builtin_return_address(0);
  CGLError err = CGLSetCurrentContext(ctx);
  if (err != kCGLNoError || !ctx) return err;
  pthread_mutex_lock(&g_pmu);
  Assoc *a = assoc_for_ctx(ctx);
  if (a) {
    GLint cur = 0;
    if (caller_is_winemac(ra)) {
      if (!a->ready) ensure_objects(a);
      glGetIntegerv(GL_FRAMEBUFFER_BINDING, &cur);
      if (!a->active && cur == 0) glBindFramebuffer(GL_FRAMEBUFFER, a->fbo);
      { static int nt; if (nt++ < 20) glfix_trace("PBEMU current pbuffer ctx=%p fb_before=%d", (void *)ctx, cur); }
      a->active = 1;
    } else if (a->active) {
      glGetIntegerv(GL_FRAMEBUFFER_BINDING, &cur);
      if ((GLuint)cur == a->fbo) {
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glDrawBuffer(GL_BACK);
        glReadBuffer(GL_BACK);
      }
      a->active = 0;
    }
  }
  pthread_mutex_unlock(&g_pmu);
  return err;
}
DYLD_INTERPOSE(pb_CGLSetCurrentContext, CGLSetCurrentContext)

static CGLError pb_CGLTexImagePBuffer(CGLContextObj ctx, CGLPBufferObj obj, GLenum source) {
  (void)ctx;
  if (!is_pb(obj)) return kCGLBadValue;
  if (source == GL_NONE) return kCGLNoError;
  PBuf *pb = (PBuf *)obj;
  pthread_mutex_lock(&g_pmu);
  Assoc *a = assoc_for_pb(pb);
  if (!a || !a->ready) { pthread_mutex_unlock(&g_pmu); return kCGLNoError; }
  size_t n = (size_t)pb->w * (size_t)pb->h * 4;
  unsigned char *px = malloc(n);
  if (!px) { pthread_mutex_unlock(&g_pmu); return kCGLBadAlloc; }
  CGLContextObj cur = CGLGetCurrentContext();
  if (a->ctx != cur) CGLSetCurrentContext(a->ctx);
  GLint prevRead = 0;
  glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &prevRead);
  glBindFramebuffer(GL_READ_FRAMEBUFFER, a->fbo);
  glReadBuffer(GL_COLOR_ATTACHMENT0);
  glPixelStorei(GL_PACK_ALIGNMENT, 1);
  glReadPixels(0, 0, pb->w, pb->h, GL_RGBA, GL_UNSIGNED_BYTE, px);
  glBindFramebuffer(GL_READ_FRAMEBUFFER, (GLuint)prevRead);
  if (a->ctx != cur) CGLSetCurrentContext(cur);
  pthread_mutex_unlock(&g_pmu);
  GLint prevUnpack = 4;
  glGetIntegerv(GL_UNPACK_ALIGNMENT, &prevUnpack);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glTexImage2D(pb->target, 0, pb->ifmt, pb->w, pb->h, 0, GL_RGBA, GL_UNSIGNED_BYTE, px);
  glPixelStorei(GL_UNPACK_ALIGNMENT, prevUnpack);
  free(px);
  return kCGLNoError;
}
DYLD_INTERPOSE(pb_CGLTexImagePBuffer, CGLTexImagePBuffer)

static GLuint pb_fbo_for_current(void) {
  if (!g_npbs) return 0;
  CGLContextObj cur = CGLGetCurrentContext();
  if (!cur) return 0;
  pthread_mutex_lock(&g_pmu);
  Assoc *a = assoc_for_ctx(cur);
  GLuint f = (a && a->ready && a->active) ? a->fbo : 0;
  pthread_mutex_unlock(&g_pmu);
  return f;
}

static int is_default_buffer(GLenum mode) {
  return mode == GL_FRONT || mode == GL_BACK || mode == GL_FRONT_LEFT || mode == GL_BACK_LEFT ||
         mode == GL_FRONT_AND_BACK || mode == GL_LEFT;
}

static int fbo_is_bound(GLenum which, GLuint fbo) {
  GLint cur = 0;
  glGetIntegerv(which, &cur);
  return fbo && (GLuint)cur == fbo;
}

static void pb_BindFramebuffer(GLenum target, GLuint fb) {
  if (fb == 0) { GLuint f = pb_fbo_for_current(); if (f) fb = f; }
  glBindFramebuffer(target, fb);
}
static void pb_BindFramebufferEXT(GLenum target, GLuint fb) {
  if (fb == 0) { GLuint f = pb_fbo_for_current(); if (f) fb = f; }
  glBindFramebufferEXT(target, fb);
}
static void pb_DrawBuffer(GLenum mode) {
  GLuint f = pb_fbo_for_current();
  if (f && is_default_buffer(mode) && fbo_is_bound(GL_DRAW_FRAMEBUFFER_BINDING, f)) mode = GL_COLOR_ATTACHMENT0;
  glDrawBuffer(mode);
}
static void pb_ReadBuffer(GLenum mode) {
  GLuint f = pb_fbo_for_current();
  if (f && is_default_buffer(mode) && fbo_is_bound(GL_READ_FRAMEBUFFER_BINDING, f)) mode = GL_COLOR_ATTACHMENT0;
  glReadBuffer(mode);
}
DYLD_INTERPOSE(pb_BindFramebuffer, glBindFramebuffer)
DYLD_INTERPOSE(pb_BindFramebufferEXT, glBindFramebufferEXT)
DYLD_INTERPOSE(pb_DrawBuffer, glDrawBuffer)
DYLD_INTERPOSE(pb_ReadBuffer, glReadBuffer)

static void pb_ShaderSourceARB(GLhandleARB sh, GLsizei count, const GLcharARB **str, const GLint *len);
static void pb_ShaderSource(GLuint sh, GLsizei count, const GLchar *const *str, const GLint *len);
static void pb_LinkProgram(GLuint p);
static void pb_LinkProgramARB(GLhandleARB p);
void *pbemu_dlsym_wrap(const char *name) {
  if (!name) return NULL;
  if (!strcmp(name, "glBindFramebuffer")) return (void *)pb_BindFramebuffer;
  if (!strcmp(name, "glBindFramebufferEXT")) return (void *)pb_BindFramebufferEXT;
  if (!strcmp(name, "glDrawBuffer")) return (void *)pb_DrawBuffer;
  if (!strcmp(name, "glReadBuffer")) return (void *)pb_ReadBuffer;
  if (!strcmp(name, "glShaderSourceARB")) return (void *)pb_ShaderSourceARB;
  if (!strcmp(name, "glShaderSource")) return (void *)pb_ShaderSource;
  if (!strcmp(name, "glLinkProgramARB")) return (void *)pb_LinkProgramARB;
  if (!strcmp(name, "glLinkProgram")) return (void *)pb_LinkProgram;
  return NULL;
}

static const char k_ver[] = "#version 120\n";
static int source_has_version(GLsizei count, const GLchar *const *str, const GLint *len) {
  for (GLsizei i = 0; i < count; i++) {
    if (!str[i]) continue;
    size_t n = (len && len[i] >= 0) ? (size_t)len[i] : strlen(str[i]);
    const char *s = str[i];
    for (size_t k = 0; k + 8 <= n; k++)
      if (s[k] == '#' && !strncmp(s + k, "#version", 8)) return 1;
  }
  return 0;
}

static char *patch_bush_shader(GLsizei count, const GLchar *const *str, const GLint *len, int *out_len) {
  if (count <= 0 || !str) return NULL;

  const char *bt = getenv("GLFIX_BUSHTEST");
  if (!bt || !*bt) bt = "nanguard";
  if (strcmp(bt, "nanguard")) return NULL;
  size_t total = 0;
  for (GLsizei i = 0; i < count; i++) {
    if (!str[i]) continue;
    size_t n = (len && len[i] >= 0) ? (size_t)len[i] : strlen((const char *)str[i]);
    total += n;
  }
  if (total == 0) return NULL;
  char *buf = (char *)malloc(total + 1024);
  if (!buf) return NULL;
  size_t pos = 0;
  for (GLsizei i = 0; i < count; i++) {
    if (!str[i]) continue;
    size_t n = (len && len[i] >= 0) ? (size_t)len[i] : strlen((const char *)str[i]);
    memcpy(buf + pos, str[i], n);
    pos += n;
  }
  buf[pos] = '\0';

  if (!strcmp(bt, "nanguard")) {
    static const char *const from[] = { "vec3 n=normalize(gl_NormalMatrix*gl_Normal);",
                                         "vec3 n=normalize(gl_NormalMatrix*anorm.xyz);" };
    static const char *const to[] = { "vec3 n=gl_NormalMatrix*gl_Normal; n=dot(n,n)>1e-20?normalize(n):vec3(0.0);",
                                       "vec3 n=gl_NormalMatrix*anorm.xyz; n=dot(n,n)>1e-20?normalize(n):vec3(0.0);" };
    int hits = 0;
    for (int k = 0; k < 2; k++) {
      char *p = strstr(buf, from[k]);
      if (!p) continue;
      size_t fl = strlen(from[k]), tl = strlen(to[k]), tail = strlen(p + fl);
      memmove(p + tl, p + fl, tail + 1);
      memcpy(p, to[k], tl);
      hits++;
    }
    if (!hits) { free(buf); return NULL; }
    glfix_trace("NANGUARD normal guard applied len=%zu", strlen(buf));
    *out_len = (int)strlen(buf);
    return buf;
  }

  free(buf);
  return NULL;
}

static void pb_ShaderSourceARB(GLhandleARB sh, GLsizei count, const GLcharARB **str, const GLint *len) {
  int patched_len = 0;
  char *patched = patch_bush_shader(count, (const GLchar *const *)str, len, &patched_len);
  if (patched) {
    const GLcharARB *pstr = (const GLcharARB *)patched;
    GLint plen = patched_len;
    if (!source_has_version(1, (const GLchar *const *)&pstr, &plen)) {
      const GLcharARB *s2[2] = { k_ver, pstr };
      GLint l2[2] = { (GLint)(sizeof k_ver - 1), plen };
      glShaderSourceARB(sh, 2, s2, l2);
    } else {
      glShaderSourceARB(sh, 1, &pstr, &plen);
    }
    free(patched);
    return;
  }
  if (count <= 0 || !str || source_has_version(count, (const GLchar *const *)str, len) || count > 62) {
    glShaderSourceARB(sh, count, str, len); return;
  }
  const GLcharARB *s2[64]; GLint l2[64];
  s2[0] = k_ver; l2[0] = (GLint)(sizeof k_ver - 1);
  for (GLsizei i = 0; i < count; i++) { s2[i + 1] = str[i]; l2[i + 1] = len ? len[i] : -1; }
  glShaderSourceARB(sh, count + 1, s2, l2);
}
static void pb_ShaderSource(GLuint sh, GLsizei count, const GLchar *const *str, const GLint *len) {
  int patched_len = 0;
  char *patched = patch_bush_shader(count, str, len, &patched_len);
  if (patched) {
    const GLchar *pstr = patched;
    GLint plen = patched_len;
    if (!source_has_version(1, &pstr, &plen)) {
      const GLchar *s2[2] = { k_ver, pstr };
      GLint l2[2] = { (GLint)(sizeof k_ver - 1), plen };
      glShaderSource(sh, 2, s2, l2);
    } else {
      glShaderSource(sh, 1, &pstr, &plen);
    }
    free(patched);
    return;
  }
  if (count <= 0 || !str || source_has_version(count, str, len) || count > 62) {
    glShaderSource(sh, count, str, len); return;
  }
  const GLchar *s2[64]; GLint l2[64];
  s2[0] = k_ver; l2[0] = (GLint)(sizeof k_ver - 1);
  for (GLsizei i = 0; i < count; i++) { s2[i + 1] = str[i]; l2[i + 1] = len ? len[i] : -1; }
  glShaderSource(sh, count + 1, s2, l2);
}
DYLD_INTERPOSE(pb_ShaderSourceARB, glShaderSourceARB)
DYLD_INTERPOSE(pb_ShaderSource, glShaderSource)

void pbemu_forget_program(uintptr_t p);
static void pb_LinkProgram(GLuint p) { pbemu_forget_program(p); glLinkProgram(p); }
static void pb_LinkProgramARB(GLhandleARB p) { pbemu_forget_program((uintptr_t)p); glLinkProgramARB(p); }

#define MAXBP 8192
static int16_t g_boneLoc[MAXBP];
void pbemu_forget_program(uintptr_t p) { if (p < MAXBP) g_boneLoc[p] = 0; }

GLint pbemu_bone_loc(GLint loc, GLsizei count) {
  if (loc >= 0 && count > 1) {
    GLint prog = (GLint)glfix_get_cur_prog();
    if (prog <= 0) {
      glGetIntegerv(GL_CURRENT_PROGRAM, &prog);
    }
    if (prog > 0 && prog < MAXBP) {
      if (!g_boneLoc[prog]) {
        GLint b = glGetUniformLocation((GLuint)prog, "boneMatrices");
        g_boneLoc[prog] = (int16_t)(b >= 0 ? b + 1 : -1);
      }
      GLint b = g_boneLoc[prog] - 1;
      if (b >= 0 && loc != b) {
        static int nlog;
        if (nlog++ < 5) glfix_trace("BONEFIX prog=%d loc=%d -> %d count=%d", prog, loc, b, count);
        loc = b;
      }
    }
  }
  return loc;
}
