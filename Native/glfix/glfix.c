// SPDX-License-Identifier: MIT
// Copyright (c) Steppe contributors
// Uniform compatibility hooks and injection propagation for Wine child processes.
// Mode 1 remaps array strides; mode 2 keeps the pbuffer/shader compatibility path.
#define GL_SILENCE_DEPRECATION 1
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl.h>
#include <OpenGL/glext.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <time.h>
#include <unistd.h>
#include <spawn.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <pthread.h>
#include <stdatomic.h>
#include "frametimes.h"
#ifdef GLFIX_EIPPROF_BUILD
#include "eipprof.h"
#endif

#define DYLD_INTERPOSE(_repl, _orig) \
  __attribute__((used)) static struct { const void *repl; const void *orig; } \
  _interpose_##_orig __attribute__((section("__DATA,__interpose"))) = \
  { (const void *)(uintptr_t)&_repl, (const void *)(uintptr_t)&_orig };

static FILE *g_log;
static _Atomic int g_logBudget = 6000;
static int g_remap;
static int g_doRemap; // Mode 2 retains pbuffer/shader fixes without stride remapping.
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;

static void log_impl(const char *fmt, ...) {
  if (!g_log || atomic_fetch_sub_explicit(&g_logBudget, 1, memory_order_relaxed) <= 0) return;
  va_list ap; va_start(ap, fmt);
  vfprintf(g_log, fmt, ap);
  va_end(ap);
  fputc('\n', g_log);
  fflush(g_log);
}

static void boot_trace_impl(const char *fmt, ...) {
  if (!g_log || atomic_fetch_sub_explicit(&g_logBudget, 1, memory_order_relaxed) <= 0) return;
  va_list ap; va_start(ap, fmt);
  vfprintf(g_log, fmt, ap);
  va_end(ap);
  fputc('\n', g_log);
  fflush(g_log);
}

void glfix_trace(const char *fmt, ...) {
  if (!g_log || atomic_fetch_sub_explicit(&g_logBudget, 1, memory_order_relaxed) <= 0) return;
  va_list ap; va_start(ap, fmt);
  vfprintf(g_log, fmt, ap);
  va_end(ap);
  fputc('\n', g_log);
  fflush(g_log);
}

__attribute__((visibility("hidden"))) int glfix_log_enabled(void) { return g_log != NULL; }
#define logf_(...) do { if (g_log) log_impl(__VA_ARGS__); } while (0)
#define boot_trace(...) do { if (g_log) boot_trace_impl(__VA_ARGS__); } while (0)

void *pbemu_dlsym_wrap(const char *name);
GLint pbemu_bone_loc(GLint loc, GLsizei count);
void pbemu_forget_program(uintptr_t prog);

static char g_selfPath[1024];
static char g_logPath[1024];
static char g_remapVal[8];
static char g_bushtestVal[32];

__attribute__((constructor)) static void glfix_init(void) {
  frametimes_init();
#ifdef GLFIX_EIPPROF_BUILD
  eipprof_init();
#endif
  Dl_info di;
  if (dladdr((const void *)&glfix_init, &di) && di.dli_fname)
    strlcpy(g_selfPath, di.dli_fname, sizeof g_selfPath);

  const char *p = getenv("GLFIX_LOG");
  if (p && *p) strlcpy(g_logPath, p, sizeof g_logPath);
  const char *r = getenv("GLFIX_REMAP");
  if (r && *r) strlcpy(g_remapVal, r, sizeof g_remapVal);
  const char *bt = getenv("GLFIX_BUSHTEST");
  if (bt) strlcpy(g_bushtestVal, bt, sizeof g_bushtestVal);
  if (g_logPath[0]) g_log = fopen(g_logPath, "ae");
  // Some libc versions accept "e" without setting the descriptor flag.
  if (g_log) {
    int fd = fileno(g_log);
    int flags = fcntl(fd, F_GETFD);
    if (flags < 0 || fcntl(fd, F_SETFD, flags | FD_CLOEXEC) < 0) {
      fclose(g_log);
      g_log = NULL;
    }
  }
  g_remap = g_remapVal[0] && atoi(g_remapVal) != 0;
  g_doRemap = g_remapVal[0] && atoi(g_remapVal) == 1;
  logf_("[glfix] loaded pid=%d remap=%d self=%s", getpid(), g_remap, g_selfPath);
  boot_trace("BOOT pid=%d remap=%d log=%s self=%s",
             getpid(), g_remap, g_logPath[0] ? g_logPath : "(none)", g_selfPath);
}

#define MAXPROG 512
#define MAXARR  8
#define MAXELEM 64
typedef struct {
  char  name[56];
  GLint base;
  int   n;
  GLint elem[MAXELEM];
  int   byName;
} ArrInfo;
typedef struct {
  uintptr_t shareGroup;
  uintptr_t prog;
  int narr;
  ArrInfo arr[MAXARR];
} ProgInfo;
static ProgInfo g_progs[MAXPROG];
static int g_nprogs;
static _Thread_local uintptr_t g_curProg;
uintptr_t glfix_get_cur_prog(void) {
  return g_curProg;
}

static uintptr_t getCurrentShareGroup(void) {
  CGLContextObj ctx = CGLGetCurrentContext();
  if (!ctx) return 0;
  CGLShareGroupObj sg = CGLGetShareGroup(ctx);
  return sg ? (uintptr_t)sg : (uintptr_t)ctx;
}

static ProgInfo *findProg(uintptr_t prog, int create) {
  uintptr_t sg = getCurrentShareGroup();
  for (int i = 0; i < g_nprogs; i++) {
    if (g_progs[i].prog == prog && (!g_progs[i].shareGroup || g_progs[i].shareGroup == sg)) {
      if (!g_progs[i].shareGroup) g_progs[i].shareGroup = sg;
      return &g_progs[i];
    }
  }
  if (!create || g_nprogs >= MAXPROG) return NULL;
  ProgInfo *pi = &g_progs[g_nprogs++];
  memset(pi, 0, sizeof *pi);
  pi->shareGroup = sg;
  pi->prog = prog;
  return pi;
}

static void forgetProg(uintptr_t prog) {
  uintptr_t sg = getCurrentShareGroup();
  pthread_mutex_lock(&g_mu);
  for (int i = 0; i < g_nprogs; i++) {
    if ((!g_progs[i].shareGroup || g_progs[i].shareGroup == sg) && g_progs[i].prog == prog) {
      g_progs[i] = g_progs[--g_nprogs];
      break;
    }
  }
  pthread_mutex_unlock(&g_mu);
}

static void inspectArray(uintptr_t prog, const char *name, GLint base) {
  if (base < 0 || strchr(name, '[') || strlen(name) >= sizeof(((ArrInfo *)0)->name)) return;
  ProgInfo *pi = findProg(prog, 1);
  if (!pi) return;
  for (int i = 0; i < pi->narr; i++)
    if (!strcmp(pi->arr[i].name, name)) return;
  char buf[80];
  snprintf(buf, sizeof buf, "%s[1]", name);
  GLint l1 = glGetUniformLocationARB((GLhandleARB)prog, buf);
  if (l1 < 0) return;
  if (l1 == base + 1) return;
  if (pi->narr >= MAXARR) return;
  ArrInfo *a = &pi->arr[pi->narr];
  memset(a, 0, sizeof *a);
  strlcpy(a->name, name, sizeof a->name);
  a->base = base; a->elem[0] = base; a->elem[1] = l1; a->n = 2;
  for (int i = 2; i < MAXELEM; i++) {
    snprintf(buf, sizeof buf, "%s[%d]", name, i);
    GLint li = glGetUniformLocationARB((GLhandleARB)prog, buf);
    if (li < 0) break;
    a->elem[i] = li; a->n = i + 1;
  }
  pi->narr++;
  logf_("[glfix] prog=%#lx array '%s' base=%d n=%d elem1=%d elemLast=%d NON-CONTIGUOUS(stride=%d) -> tracked",
        (unsigned long)prog, name, base, a->n, a->elem[1], a->elem[a->n - 1], a->elem[1] - a->base);
}

static void markByName(uintptr_t prog, const char *nameWithBracket) {
  ProgInfo *pi = findProg(prog, 0);
  if (!pi) return;
  size_t stem = strcspn(nameWithBracket, "[");
  for (int i = 0; i < pi->narr; i++)
    if (!strncmp(pi->arr[i].name, nameWithBracket, stem) && pi->arr[i].name[stem] == 0) {
      if (!pi->arr[i].byName)
        logf_("[glfix] prog=%#lx array '%s' queried by element name -> remap disabled",
              (unsigned long)prog, pi->arr[i].name);
      pi->arr[i].byName = 1;
    }
}

static void note_location(uintptr_t prog, const char *name, GLint loc) {
  if (!name) return;
  pthread_mutex_lock(&g_mu);
  const char *bracket = strchr(name, '[');
  if (bracket) {
    if (!strcmp(bracket, "[0]")) {
      char stem[64];
      size_t len = (size_t)(bracket - name);
      if (len < sizeof stem) {
        memcpy(stem, name, len);
        stem[len] = '\0';
        inspectArray(prog, stem, loc);
      }
    } else {
      markByName(prog, name);
    }
  } else {
    inspectArray(prog, name, loc);
  }
  if (strstr(name, "bone") || strstr(name, "Bone") || strstr(name, "Matrices"))
    logf_("[glfix] GetUniformLocation(prog=%#lx,\"%s\")=%d", (unsigned long)prog, name, loc);
  pthread_mutex_unlock(&g_mu);
}

static int g_mat4LogBudget = 500;
static _Atomic long g_remapped, g_passthrough;

static int remapMatrix4fv(GLint loc, GLsizei count, GLboolean transpose, const GLfloat *value,
                          void (*upload)(GLint, GLsizei, GLboolean, const GLfloat *)) {
  if (!g_doRemap) {
    if (g_log) g_passthrough++;
    return 0;
  }
  pthread_mutex_lock(&g_mu);
  uintptr_t curProg = g_curProg;
  if (!curProg) {
    GLint cp = 0;
    glGetIntegerv(0x8B8D , &cp);
    curProg = (uintptr_t)cp;
  }
  ProgInfo *pi = findProg(curProg, 0);
  ArrInfo *hit = NULL;
  if (pi) {
    for (int i = 0; i < pi->narr && !hit; i++)
      if (loc >= pi->arr[i].base && loc < pi->arr[i].base + pi->arr[i].n)
        hit = &pi->arr[i];
  }

  if (g_log && loc > 0 && g_mat4LogBudget > 0) {
    g_mat4LogBudget--;
    logf_("[glfix] Matrix4fv loc=%d count=%d curProg=%#lx%s%s remap=%d",
          loc, (int)count, (unsigned long)curProg, hit ? " IN-ARRAY " : " ", hit ? hit->name : "(none)", g_remap);
  }
  if (!hit || hit->byName || !g_doRemap) {
    if (g_log) g_passthrough++;
    pthread_mutex_unlock(&g_mu);
    return 0;
  }
  GLint base = hit->base; int n = hit->n;
  GLint elems[MAXELEM]; memcpy(elems, hit->elem, sizeof elems);
  if (g_log) g_remapped++;
  pthread_mutex_unlock(&g_mu);
  for (GLsizei k = 0; k < count; k++) {
    int idx = (int)(loc - base) + (int)k;
    if (idx >= 0 && idx < n) {
      upload(elems[idx], 1, transpose, value + 16 * k);
      static int s_auditBudget = 20;
      if (g_log && s_auditBudget > 0) {
        s_auditBudget--;
        GLenum err = glGetError();
        GLfloat rb[16] = {0};
        glGetUniformfv((GLuint)curProg, elems[idx], rb);
        logf_("[glfix-audit] curProg=%#lx k=%d idx=%d elem=%d t=%d err=0x%x rb_diag=(%.2f,%.2f,%.2f,%.2f) rb_pos=(%.2f,%.2f,%.2f)",
              (unsigned long)curProg, (int)k, idx, elems[idx], (int)transpose, (unsigned int)err,
              rb[0], rb[5], rb[10], rb[15], rb[12], rb[13], rb[14]);
      }
    }
  }
  return 1;
}

static void gfx_Clear(GLbitfield mask) {
  if (g_ft_path && (mask & GL_COLOR_BUFFER_BIT)) frametimes_record();
#ifdef GLFIX_EIPPROF_BUILD
  static pthread_once_t once = PTHREAD_ONCE_INIT;
  pthread_once(&once, eipprof_start);
#endif
  glClear(mask);
}
DYLD_INTERPOSE(gfx_Clear, glClear)

static GLint gfx_GetUniformLocationARB(GLhandleARB prog, const GLcharARB *name) {
  GLint loc = glGetUniformLocationARB(prog, name);
  note_location((uintptr_t)prog, name, loc);
  return loc;
}
static GLint gfx_GetUniformLocation(GLuint prog, const GLchar *name) {
  GLint loc = glGetUniformLocation(prog, name);
  note_location((uintptr_t)prog, name, loc);
  return loc;
}
static void gfx_UseProgramObjectARB(GLhandleARB prog) { g_curProg = (uintptr_t)prog; glUseProgramObjectARB(prog); }
static void gfx_UseProgram(GLuint prog)               { g_curProg = (uintptr_t)prog; glUseProgram(prog); }
static void gfx_LinkProgramARB(GLhandleARB prog) {
  pbemu_forget_program((uintptr_t)prog);
  pthread_mutex_lock(&g_mu); ProgInfo *pi = findProg((uintptr_t)prog, 0); if (pi) pi->narr = 0; pthread_mutex_unlock(&g_mu);
  glLinkProgramARB(prog);
  GLint loc = glGetUniformLocationARB(prog, "boneMatrices[0]");
  if (loc < 0) loc = glGetUniformLocationARB(prog, "boneMatrices");
  if (loc >= 0) note_location((uintptr_t)prog, "boneMatrices", loc);
}
static void gfx_LinkProgram(GLuint prog) {
  pbemu_forget_program((uintptr_t)prog);
  pthread_mutex_lock(&g_mu); ProgInfo *pi = findProg((uintptr_t)prog, 0); if (pi) pi->narr = 0; pthread_mutex_unlock(&g_mu);
  glLinkProgram(prog);
  GLint loc = glGetUniformLocation(prog, "boneMatrices[0]");
  if (loc < 0) loc = glGetUniformLocation(prog, "boneMatrices");
  if (loc >= 0) note_location((uintptr_t)prog, "boneMatrices", loc);
}
static void gfx_DeleteObjectARB(GLhandleARB object) {
  pbemu_forget_program((uintptr_t)object);
  forgetProg((uintptr_t)object);
  glDeleteObjectARB(object);
}
static void gfx_DeleteProgram(GLuint prog) {
  pbemu_forget_program((uintptr_t)prog);
  forgetProg((uintptr_t)prog);
  glDeleteProgram(prog);
}
static void gfx_UniformMatrix4fvARB(GLint loc, GLsizei count, GLboolean t, const GLfloat *v) {
  loc = pbemu_bone_loc(loc, count);
  static int s_matrixDumpCount = 5;
  if (g_log && g_doRemap && (count == 17 || count == 24 || count == 16) && s_matrixDumpCount > 0) {
    s_matrixDumpCount--;
    logf_("[glfix-measure] DUMP count=%d curProg=%#lx:", (int)count, (unsigned long)g_curProg);
    for (GLsizei k = 0; k < count; k++) {
      const GLfloat *m = v + 16 * k;
      logf_("  b[%2d] pos=(%7.2f, %7.2f, %7.2f) diag=(%.2f, %.2f, %.2f, %.2f)",
            (int)k, m[12], m[13], m[14], m[0], m[5], m[10], m[15]);
    }
  }
  if (!remapMatrix4fv(loc, count, t, v, glUniformMatrix4fvARB)) glUniformMatrix4fvARB(loc, count, t, v);
}
static void gfx_UniformMatrix4fv(GLint loc, GLsizei count, GLboolean t, const GLfloat *v) {
  loc = pbemu_bone_loc(loc, count);
  if (!remapMatrix4fv(loc, count, t, v, glUniformMatrix4fv)) glUniformMatrix4fv(loc, count, t, v);
}

static void gfx_ProgramUniformMatrix4fv(GLuint prog, GLint loc, GLsizei count, GLboolean t, const GLfloat *v) {
  GLint prevProg = 0;
  glGetIntegerv(0x8B8D , &prevProg);
  uintptr_t prevCur = g_curProg;

  g_curProg = (uintptr_t)prog;
  glUseProgram(prog);
  if (!remapMatrix4fv(loc, count, t, v, glUniformMatrix4fvARB)) {
    glUniformMatrix4fvARB(loc, count, t, v);
  }

  glUseProgram((GLuint)prevProg);
  g_curProg = prevCur ? prevCur : (uintptr_t)prevProg;
}

DYLD_INTERPOSE(gfx_GetUniformLocationARB, glGetUniformLocationARB)
DYLD_INTERPOSE(gfx_GetUniformLocation,    glGetUniformLocation)
DYLD_INTERPOSE(gfx_UseProgramObjectARB,   glUseProgramObjectARB)
DYLD_INTERPOSE(gfx_UseProgram,            glUseProgram)
DYLD_INTERPOSE(gfx_LinkProgramARB,        glLinkProgramARB)
DYLD_INTERPOSE(gfx_LinkProgram,           glLinkProgram)
DYLD_INTERPOSE(gfx_DeleteObjectARB,        glDeleteObjectARB)
DYLD_INTERPOSE(gfx_DeleteProgram,          glDeleteProgram)
DYLD_INTERPOSE(gfx_UniformMatrix4fvARB,   glUniformMatrix4fvARB)
DYLD_INTERPOSE(gfx_UniformMatrix4fv,      glUniformMatrix4fv)

static struct { const char *name; void *wrap; } g_dlhooks[] = {
  { "glGetUniformLocationARB",      (void *)gfx_GetUniformLocationARB },
  { "glGetUniformLocation",         (void *)gfx_GetUniformLocation },
  { "glUseProgramObjectARB",        (void *)gfx_UseProgramObjectARB },
  { "glUseProgram",                 (void *)gfx_UseProgram },
  { "glLinkProgramARB",             (void *)gfx_LinkProgramARB },
  { "glLinkProgram",                (void *)gfx_LinkProgram },
  { "glDeleteObjectARB",            (void *)gfx_DeleteObjectARB },
  { "glDeleteProgram",              (void *)gfx_DeleteProgram },
  { "glUniformMatrix4fvARB",        (void *)gfx_UniformMatrix4fvARB },
  { "glUniformMatrix4fv",           (void *)gfx_UniformMatrix4fv },
  { "glProgramUniformMatrix4fv",    (void *)gfx_ProgramUniformMatrix4fv },
  { "glProgramUniformMatrix4fvEXT", (void *)gfx_ProgramUniformMatrix4fv },
};
static void *my_dlsym(void *handle, const char *name) {
  void *real = dlsym(handle, name);
  if (real && name) {
    void *selected = pbemu_dlsym_wrap(name);
    if (!selected) {
      for (unsigned i = 0; i < sizeof g_dlhooks / sizeof g_dlhooks[0]; i++) {
        if (!strcmp(name, g_dlhooks[i].name)) {
          boot_trace("GLPROBE pid=%d dlsym(%s) -> wrapper ACTIVE", getpid(), name);
          selected = g_dlhooks[i].wrap;
          break;
        }
      }
    }
    if (!selected) selected = real;
    return selected;
  }
  return real;
}
DYLD_INTERPOSE(my_dlsym, dlsym)

static int has_token_in_list(const char *list, const char *sub) {
  if (!list || !sub) return 0;
  size_t sublen = strlen(sub);
  const char *p = list;
  while (*p) {
    const char *next = strchr(p, ':');
    size_t len = next ? (size_t)(next - p) : strlen(p);
    if (len == sublen && strncmp(p, sub, len) == 0) return 1;
    if (!next) break;
    p = next + 1;
  }
  return 0;
}

static char **glfix_build_env(char *const *envp) {

  if (!g_remap || !g_selfPath[0]) return NULL;

  int n = 0; while (envp && envp[n]) n++;
#ifdef GLFIX_EIPPROF_BUILD
  char **ne = malloc((size_t)(n + 12 + (g_ft_path != NULL)) * sizeof(char *));
#else
  char **ne = malloc((size_t)(n + 8 + (g_ft_path != NULL)) * sizeof(char *));
#endif
  if (!ne) return NULL;

  int j = 0;
  const char *existing_dyld = NULL;
  for (int i = 0; i < n; i++) {
    if (!strncmp(envp[i], "DYLD_INSERT_LIBRARIES=", 22)) {
      existing_dyld = envp[i] + 22;
      continue;
    }
    if (!strncmp(envp[i], "GLFIX_LOG=", 10)) continue;
    if (!strncmp(envp[i], "GLFIX_REMAP=", 12)) continue;
    if (!strncmp(envp[i], "GLFIX_BUSHTEST=", 15)) continue;
    if (g_ft_path && !strncmp(envp[i], "GLFIX_FRAMETIMES=", 17)) continue;
#ifdef GLFIX_EIPPROF_BUILD
    if (eipprof_env_key(envp[i])) continue;
#endif
    ne[j++] = envp[i];
  }

  char *s = NULL;
  if (existing_dyld && *existing_dyld) {
    if (has_token_in_list(existing_dyld, g_selfPath)) {
      if (asprintf(&s, "DYLD_INSERT_LIBRARIES=%s", existing_dyld) >= 0 && s) ne[j++] = s;
    } else {
      if (asprintf(&s, "DYLD_INSERT_LIBRARIES=%s:%s", existing_dyld, g_selfPath) >= 0 && s) ne[j++] = s;
    }
  } else {
    if (asprintf(&s, "DYLD_INSERT_LIBRARIES=%s", g_selfPath) >= 0 && s) ne[j++] = s;
  }

  s = NULL;
  if (g_logPath[0] && asprintf(&s, "GLFIX_LOG=%s", g_logPath) >= 0 && s) ne[j++] = s;
  s = NULL;
  if (g_remapVal[0] && asprintf(&s, "GLFIX_REMAP=%s", g_remapVal) >= 0 && s) ne[j++] = s;
  s = NULL;
  s = NULL;
  s = NULL;
  if (g_bushtestVal[0] && asprintf(&s, "GLFIX_BUSHTEST=%s", g_bushtestVal) >= 0 && s) ne[j++] = s;
  s = NULL;
  if (g_ft_path && asprintf(&s, "GLFIX_FRAMETIMES=%s", g_ft_path) >= 0 && s) ne[j++] = s;
#ifdef GLFIX_EIPPROF_BUILD
  j = eipprof_build_env(ne, j);
#endif
  ne[j] = NULL;
  return ne;
}

static void glfix_free_env(char **envp) {
  if (!envp) return;
  for (int i = 0; envp[i]; i++) {
    if (!strncmp(envp[i], "DYLD_INSERT_LIBRARIES=", 22) ||
        !strncmp(envp[i], "GLFIX_LOG=", 10) ||
        !strncmp(envp[i], "GLFIX_REMAP=", 12)
        || !strncmp(envp[i], "GLFIX_BUSHTEST=", 15)
        || (g_ft_path && !strncmp(envp[i], "GLFIX_FRAMETIMES=", 17))
#ifdef GLFIX_EIPPROF_BUILD
        || eipprof_env_key(envp[i])
#endif
        ) {
      free(envp[i]);
    }
  }
  free(envp);
}

static void ensure_environ_vars(void) {

  if (!g_remap || !g_selfPath[0]) return;
  const char *existing_dyld = getenv("DYLD_INSERT_LIBRARIES");
  if (!existing_dyld || !*existing_dyld) {
    setenv("DYLD_INSERT_LIBRARIES", g_selfPath, 1);
  } else if (!has_token_in_list(existing_dyld, g_selfPath)) {
    char merged[2048];
    snprintf(merged, sizeof merged, "%s:%s", existing_dyld, g_selfPath);
    setenv("DYLD_INSERT_LIBRARIES", merged, 1);
  }
  if (g_logPath[0]  && !getenv("GLFIX_LOG"))   setenv("GLFIX_LOG", g_logPath, 1);
  if (g_remapVal[0] && !getenv("GLFIX_REMAP")) setenv("GLFIX_REMAP", g_remapVal, 1);
  if (g_bushtestVal[0] && !getenv("GLFIX_BUSHTEST")) setenv("GLFIX_BUSHTEST", g_bushtestVal, 1);
  if (g_ft_path && !getenv("GLFIX_FRAMETIMES")) setenv("GLFIX_FRAMETIMES", g_ft_path, 1);
#ifdef GLFIX_EIPPROF_BUILD
  eipprof_ensure_env();
#endif
}

static int my_posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *fa,
                          const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) {
  char **ne = glfix_build_env(envp);
  int r = posix_spawn(pid, path, fa, attr, argv, ne ? ne : envp);
  glfix_free_env(ne);
  return r;
}
static int my_posix_spawnp(pid_t *pid, const char *file, const posix_spawn_file_actions_t *fa,
                           const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) {
  char **ne = glfix_build_env(envp);
  int r = posix_spawnp(pid, file, fa, attr, argv, ne ? ne : envp);
  glfix_free_env(ne);
  return r;
}
static int my_execve(const char *path, char *const argv[], char *const envp[]) {
  char **ne = glfix_build_env(envp);
  int result = execve(path, argv, ne ? ne : envp);
  int savedErrno = errno;
  glfix_free_env(ne);
  errno = savedErrno;
  return result;
}
static int my_execv(const char *path, char *const argv[])  { ensure_environ_vars(); return execv(path, argv); }
static int my_execvp(const char *file, char *const argv[]) { ensure_environ_vars(); return execvp(file, argv); }
static int my_unsetenv(const char *name) {

  if (g_remap && name && !strcmp(name, "DYLD_INSERT_LIBRARIES")) return 0;
  return unsetenv(name);
}
DYLD_INTERPOSE(my_posix_spawn,  posix_spawn)
DYLD_INTERPOSE(my_posix_spawnp, posix_spawnp)
DYLD_INTERPOSE(my_execve,       execve)
DYLD_INTERPOSE(my_execv,        execv)
DYLD_INTERPOSE(my_execvp,       execvp)
DYLD_INTERPOSE(my_unsetenv,     unsetenv)

__attribute__((destructor)) static void glfix_fini(void) {
  frametimes_fini();
  boot_trace("FINI pid=%d remapped=%ld passthrough=%ld", getpid(), g_remapped, g_passthrough);
  if (g_log) {
    fprintf(g_log, "[glfix] FINI pid=%d remapped=%ld passthrough=%ld\n", getpid(), g_remapped, g_passthrough);
    fclose(g_log);
    g_log = NULL;
  }
}
