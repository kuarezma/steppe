// SPDX-License-Identifier: MIT
// Copyright (c) Steppe contributors
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include <xmmintrin.h>
#include "vorbis/vorbisfile.h"
#include "game_build.h"

extern int real_ov_clear(OggVorbis_File *vf);
extern int real_ov_open_callbacks(void *datasource, OggVorbis_File *vf, const char *initial, long ibytes, ov_callbacks callbacks);
extern ogg_int64_t real_ov_pcm_total(OggVorbis_File *vf, int i);
extern int real_ov_pcm_seek(OggVorbis_File *vf, ogg_int64_t pos);
extern int real_ov_raw_seek(OggVorbis_File *vf, ogg_int64_t pos);
extern int real_ov_time_seek(OggVorbis_File *vf, double pos);
extern vorbis_info *real_ov_info(OggVorbis_File *vf, int link);
extern vorbis_comment *real_ov_comment(OggVorbis_File *vf, int link);
extern long real_ov_read(OggVorbis_File *vf, char *buffer, int length, int bigendianp, int word, int sgned, int *bitstream);

#define VF_CACHE_MAGIC 0x43335646u
#define MAX_PCM_CACHE 512
#define MAX_PCM_BYTES (128u * 1024u * 1024u)
static size_t g_pcm_bytes;
static int g_pending_entries;

typedef struct {
    char name[256];
    int channels;
    long rate;
    ogg_int64_t pcm_total;
    size_t pcm_bytes;
    uint8_t *pcm_data;
    vorbis_info vi;
    vorbis_comment vc;
} PcmCacheEntry;

typedef struct {
    uint32_t magic;
    PcmCacheEntry *entry;
    size_t read_byte_offset;
} VfCachedState;

_Static_assert(sizeof(VfCachedState) <= sizeof(OggVorbis_File), "cached state must fit");
// This overlays vf->datasource: on i686 the cursor aliases vf->offset at byte 8.
// Cached streams must never write vf->offset (nor use the real decoder state).

static PcmCacheEntry g_cache[MAX_PCM_CACHE];
static int g_cache_count = 0;
static CRITICAL_SECTION g_cache_cs;
static int g_cache_init = 0;
static int g_cache_enabled = -1;
static int g_skip_open_patched;
static long g_cache_hits = 0;
static long g_cache_misses = 0;

static void init_cache_if_needed(void) {
    if (!g_cache_init) {
        InitializeCriticalSection(&g_cache_cs);
        g_cache_init = 1;
    }
    if (g_cache_enabled < 0) {
        const char *env = getenv("C3_VORBIS_CACHE");
        g_cache_enabled = g_skip_open_patched && (!env || strcmp(env, "0") != 0);
    }
}

static const char *get_cossacks_vorbis_filename(void *datasource, OggVorbis_File *vf, int *out_streaming) {
    *out_streaming = -1;
    if (!datasource || !vf) return NULL;
    uintptr_t ds_addr = (uintptr_t)datasource;
    uintptr_t vf_addr = (uintptr_t)vf;
    if (vf_addr != ds_addr + 0x18) return NULL;
    uintptr_t obj_addr = vf_addr - 0x28;
    if (IsBadReadPtr((const void *)obj_addr, 0x330)) return NULL;
    const char *fname = *(const char **)(obj_addr + 0x08);
    uint8_t streaming = *(const uint8_t *)(obj_addr + 0x328);
    *out_streaming = (int)streaming;
    if (!fname || IsBadReadPtr(fname, 4)) return NULL;
    if (fname[0] == '\0') return NULL;
    return fname;
}

static int is_filename_cached(const char *fname) {
    if (!fname || fname[0] == '\0') return 0;
    init_cache_if_needed();
    if (!g_cache_enabled) return 0;
    int hit = 0;
    EnterCriticalSection(&g_cache_cs);
    for (int i = 0; i < g_cache_count; i++) {
        if (strcmp(g_cache[i].name, fname) == 0) {
            hit = 1;
            break;
        }
    }
    LeaveCriticalSection(&g_cache_cs);
    return hit;
}

// Caller holds g_cache_cs. Reservations include in-flight decodes.
static int reserve_pcm_bytes(size_t bytes) {
    if (g_cache_count + g_pending_entries >= MAX_PCM_CACHE || bytes > MAX_PCM_BYTES - g_pcm_bytes) return 0;
    g_pcm_bytes += bytes;
    g_pending_entries++;
    return 1;
}

static void finish_pcm_reservation(size_t reserved, size_t retained) {
    g_pending_entries--;
    g_pcm_bytes -= reserved;
    g_pcm_bytes += retained;
}

int ov_open_callbacks(void *datasource, OggVorbis_File *vf, const char *initial, long ibytes, ov_callbacks callbacks) {
    init_cache_if_needed();
    if (g_cache_enabled && initial == NULL && ibytes == 0) {
        int streaming = -1;
        const char *fname = get_cossacks_vorbis_filename(datasource, vf, &streaming);

        if (fname && streaming == 0 && strstr(fname, "ambient") == NULL && strstr(fname, "AMBIENT") == NULL) {
            EnterCriticalSection(&g_cache_cs);
            PcmCacheEntry *found = NULL;
            for (int i = 0; i < g_cache_count; i++) {
                if (strcmp(g_cache[i].name, fname) == 0) {
                    found = &g_cache[i];
                    break;
                }
            }
            if (found) {
                g_cache_hits++;
                LeaveCriticalSection(&g_cache_cs);
                memset(vf, 0, sizeof(OggVorbis_File));
                VfCachedState *st = (VfCachedState *)&vf->datasource;
                st->magic = VF_CACHE_MAGIC;
                st->entry = found;
                st->read_byte_offset = 0;
                vf->end = found->pcm_total;
                return 0;
            }
            LeaveCriticalSection(&g_cache_cs);

            int rc = real_ov_open_callbacks(datasource, vf, initial, ibytes, callbacks);
            if (rc != 0) return rc;

            vorbis_info *vi = real_ov_info(vf, -1);
            vorbis_comment *vc = real_ov_comment(vf, -1);
            ogg_int64_t total_samples = real_ov_pcm_total(vf, -1);
            if (vi && vc && total_samples > 0 && vi->channels > 0 && total_samples <= (3 * 1024 * 1024) / (vi->channels * (ogg_int64_t)2)) {
                vorbis_info vi_copy = *vi;
                vorbis_comment vc_copy = *vc;
                vc_copy.user_comments = NULL;
                vc_copy.comment_lengths = NULL;
                vc_copy.comments = 0;
                vc_copy.vendor = NULL;
                size_t total_bytes = (size_t)(total_samples * vi_copy.channels * 2);
                // Reserve capacity before decoding; concurrent misses share the same budget.
                EnterCriticalSection(&g_cache_cs);
                int reserved = reserve_pcm_bytes(total_bytes);
                LeaveCriticalSection(&g_cache_cs);
                if (!reserved) return rc;
                uint8_t *buf = (uint8_t *)malloc(total_bytes);
                if (!buf) {
                    EnterCriticalSection(&g_cache_cs);
                    finish_pcm_reservation(total_bytes, 0);
                    LeaveCriticalSection(&g_cache_cs);
                    return rc;
                }
                if (buf) {
                    size_t got = 0;
                    int bs = 0;
                    while (got < total_bytes) {
                        long r = real_ov_read(vf, (char *)(buf + got), (int)(total_bytes - got), 0, 2, 1, &bs);
                        if (r <= 0) break;
                        got += (size_t)r;
                    }

                    EnterCriticalSection(&g_cache_cs);
                    PcmCacheEntry *entry = NULL;
                    for (int i = 0; i < g_cache_count; i++) {
                        if (strcmp(g_cache[i].name, fname) == 0) {
                            entry = &g_cache[i];
                            break;
                        }
                    }
                    int publish = !entry && got == total_bytes && g_cache_count < MAX_PCM_CACHE;
                    if (!publish) { free(buf); buf = NULL; }
                    finish_pcm_reservation(total_bytes, publish ? total_bytes : 0);
                    if (publish) {
                        entry = &g_cache[g_cache_count++];
                        strncpy(entry->name, fname, sizeof(entry->name) - 1);
                        entry->name[sizeof(entry->name) - 1] = '\0';
                        entry->channels = vi_copy.channels;
                        entry->rate = vi_copy.rate;
                        entry->pcm_total = (ogg_int64_t)(got / (size_t)(vi_copy.channels * 2));
                        entry->pcm_bytes = got;
                        entry->pcm_data = buf;
                        entry->vi = vi_copy;
                        entry->vi.codec_setup = NULL;
                        entry->vc = vc_copy;
                        buf = NULL;
                        g_cache_misses++;
                    }
                    LeaveCriticalSection(&g_cache_cs);

                    if (entry) {
                        real_ov_clear(vf);
                        memset(vf, 0, sizeof(OggVorbis_File));
                        VfCachedState *st = (VfCachedState *)&vf->datasource;
                        st->magic = VF_CACHE_MAGIC;
                        st->entry = entry;
                        st->read_byte_offset = 0;
                        vf->end = entry->pcm_total;
                        return 0;
                    }
                    // Keep the real stream usable when decoding is incomplete.
                    int seek_rc = real_ov_pcm_seek(vf, 0);
                    if (seek_rc != 0) {
                        // Failed open leaves ownership of the game datasource with the caller.
                        vf->datasource = NULL;
                        real_ov_clear(vf);
                        return seek_rc;
                    }
                }
            }
            return rc;
        }
    }
    return real_ov_open_callbacks(datasource, vf, initial, ibytes, callbacks);
}

static inline VfCachedState *get_cached_state(OggVorbis_File *vf) {
    if (!vf) return NULL;
    VfCachedState *st = (VfCachedState *)&vf->datasource;
    return (st->magic == VF_CACHE_MAGIC && st->entry != NULL) ? st : NULL;
}

vorbis_info *ov_info(OggVorbis_File *vf, int link) {
    VfCachedState *st = get_cached_state(vf);
    if (st) return &st->entry->vi;
    return real_ov_info(vf, link);
}

vorbis_comment *ov_comment(OggVorbis_File *vf, int link) {
    VfCachedState *st = get_cached_state(vf);
    if (st) return &st->entry->vc;
    return real_ov_comment(vf, link);
}

ogg_int64_t ov_pcm_total(OggVorbis_File *vf, int i) {
    VfCachedState *st = get_cached_state(vf);
    if (st) return st->entry->pcm_total;
    return real_ov_pcm_total(vf, i);
}

long ov_read(OggVorbis_File *vf, char *buffer, int length, int bigendianp, int word, int sgned, int *bitstream) {
    VfCachedState *st = get_cached_state(vf);
    if (st) {
        if (bitstream) *bitstream = 0;
        if (st->read_byte_offset >= st->entry->pcm_bytes || length <= 0) {
            return 0;
        }
        size_t rem = st->entry->pcm_bytes - st->read_byte_offset;
        size_t to_copy = (size_t)length < rem ? (size_t)length : rem;
        memcpy(buffer, st->entry->pcm_data + st->read_byte_offset, to_copy);
        st->read_byte_offset += to_copy;
        return (long)to_copy;
    }
    return real_ov_read(vf, buffer, length, bigendianp, word, sgned, bitstream);
}

int ov_pcm_seek(OggVorbis_File *vf, ogg_int64_t pos) {
    VfCachedState *st = get_cached_state(vf);
    if (st) {
        if (pos < 0) pos = 0;
        if (pos > st->entry->pcm_total) pos = st->entry->pcm_total;
        st->read_byte_offset = (size_t)pos * (size_t)(st->entry->channels * 2);
        return 0;
    }
    return real_ov_pcm_seek(vf, pos);
}

int ov_raw_seek(OggVorbis_File *vf, ogg_int64_t pos) {
    VfCachedState *st = get_cached_state(vf);
    if (st) return ov_pcm_seek(vf, pos);
    return real_ov_raw_seek(vf, pos);
}

int ov_time_seek(OggVorbis_File *vf, double pos) {
    VfCachedState *st = get_cached_state(vf);
    if (st) {
        ogg_int64_t sample_pos = (ogg_int64_t)(pos * (double)st->entry->rate);
        return ov_pcm_seek(vf, sample_pos);
    }
    return real_ov_time_seek(vf, pos);
}

int ov_clear(OggVorbis_File *vf) {
    VfCachedState *st = get_cached_state(vf);
    if (st) {
        memset(vf, 0, sizeof(OggVorbis_File));
        return 0;
    }
    return real_ov_clear(vf);
}

__attribute__((used)) static float __cdecl fast_det3x3_sse(const float *m) {
    return m[0] * (m[4] * m[8] - m[7] * m[5])
         - m[1] * (m[3] * m[8] - m[6] * m[5])
         + m[2] * (m[3] * m[7] - m[6] * m[4]);
}

__attribute__((naked)) static void detour_4a4af4(void) {
    __asm__ volatile (
        "pushl %%eax\n\t"
        "call _fast_det3x3_sse\n\t"
        "addl $4, %%esp\n\t"
        "ret\n\t"
        ::: "memory"
    );
}

__attribute__((used)) static float __cdecl fast_plane_dist_sse(const float *plane, const float *pt) {
    float nx = plane[0], ny = plane[1], nz = plane[2], d = plane[3];
    float len2 = nx * nx + ny * ny + nz * nz;
    float dot = nx * pt[0] + ny * pt[1] + nz * pt[2] + d;
    float len;
    __m128 v = _mm_set_ss(len2);
    v = _mm_sqrt_ss(v);
    _mm_store_ss(&len, v);
    return dot / len;
}

__attribute__((naked)) static void detour_4a582c(void) {
    __asm__ volatile (
        "pushl %%edx\n\t"
        "pushl %%eax\n\t"
        "call _fast_plane_dist_sse\n\t"
        "addl $8, %%esp\n\t"
        "ret\n\t"
        ::: "memory"
    );
}

static inline void call_orig_4a7890(const float *p1, const float *p2, const float *p3, float *out_pt) {
    uint32_t fn = 0x004a7890u;
    __asm__ volatile (
        "pushl %[out_pt]\n\t"
        "call *%[fn]\n\t"
        : "+a"(p1), "+d"(p2), "+c"(p3)
        : [out_pt] "r"(out_pt), [fn] "r"(fn)
        : "cc", "memory"
    );
}

static inline float call_orig_4a8078(const float *center, const float *corners_near, const float *corners_far) {
    uint32_t fn = 0x004a8078u;
    float res;
    __asm__ volatile (
        "call *%[fn]\n\t"
        "fstps %[res]\n\t"
        : "+a"(center), "+d"(corners_near), "+c"(corners_far), [res] "=m"(res)
        : [fn] "r"(fn)
        : "cc", "memory"
    );
    return res;
}

__attribute__((used)) static int __cdecl fast_is_volume_clipped(const float *center, const uint8_t *frustum, float radius) {
    static const int plane_offsets[6] = { 0x28, 0x48, 0x38, 0x58, 0x68, 0x78 };
    float neg_radius = -radius;
    float dists[6];

    for (int i = 0; i < 6; i++) {
        const float *plane = (const float *)(frustum + plane_offsets[i]);
        float dist = fast_plane_dist_sse(plane, center);
        if (!(dist > neg_radius)) {
            return 0;
        }
        dists[i] = dist;
    }

    int neg_count = 0;
    for (int i = 0; i < 6; i++) {
        if (dists[i] < 0.0f) {
            neg_count++;
        }
    }
    if (neg_count <= 1) {
        return 1;
    }

    float corners_far[12];
    float corners_near[12];
    const float *p28 = (const float *)(frustum + 0x28);
    const float *p38 = (const float *)(frustum + 0x38);
    const float *p48 = (const float *)(frustum + 0x48);
    const float *p58 = (const float *)(frustum + 0x58);
    const float *p68 = (const float *)(frustum + 0x68);
    const float *p78 = (const float *)(frustum + 0x78);

    call_orig_4a7890(p68, p58, p28, &corners_near[0]);
    call_orig_4a7890(p68, p38, p28, &corners_near[3]);
    call_orig_4a7890(p68, p38, p48, &corners_near[6]);
    call_orig_4a7890(p68, p58, p48, &corners_near[9]);

    call_orig_4a7890(p78, p58, p28, &corners_far[0]);
    call_orig_4a7890(p78, p38, p28, &corners_far[3]);
    call_orig_4a7890(p78, p38, p48, &corners_far[6]);
    call_orig_4a7890(p78, p58, p48, &corners_far[9]);

    float edge_dist = call_orig_4a8078(center, corners_near, corners_far);
    if (edge_dist > radius) {
        return 0;
    }
    return 1;
}

__attribute__((naked)) static void detour_4a825c(void) {
    __asm__ volatile (
        "pushl 4(%%esp)\n\t"
        "pushl %%edx\n\t"
        "pushl %%eax\n\t"
        "call _fast_is_volume_clipped\n\t"
        "addl $12, %%esp\n\t"
        "ret $4\n\t"
        ::: "memory"
    );
}

__attribute__((used)) static void __cdecl fast_reset_perf_monitor(uint8_t *self) {
    if (!self) return;
    int32_t count = *(int32_t *)(self + 0x140);
    int64_t first_t = *(int64_t *)(self + 0x148);
    if (count < 2 || first_t <= 0) {
        return;
    }
    LARGE_INTEGER now;
    QueryPerformanceCounter(&now);
    int64_t delta = now.QuadPart - first_t;
    if (delta > 0) {
        *(int64_t *)(self + 0x148) = first_t + (delta >> 1);
        *(int32_t *)(self + 0x140) = count >> 1;
    }
}

__attribute__((naked)) static void detour_4d1870(void) {
    __asm__ volatile (
        "pushl %%eax\n\t"
        "call _fast_reset_perf_monitor\n\t"
        "addl $4, %%esp\n\t"
        "ret\n\t"
        ::: "memory"
    );
}

__attribute__((used)) static int __cdecl fast_check_vorbis_stream_skip(uintptr_t ebp_val, const char *fname_eax) {
    if (!ebp_val || IsBadReadPtr((const void *)(ebp_val - 4), 4)) return 0;
    uintptr_t self = *(const uintptr_t *)(ebp_val - 4);
    if (!self || IsBadReadPtr((const void *)self, 0x330)) return 0;
    uint8_t streaming = *(const uint8_t *)(self + 0x328);
    if (streaming != 0) return 0;
    const char *fname = *(const char **)(self + 0x08);
    if (!fname) fname = fname_eax;
    if (fname && !IsBadReadPtr(fname, 4) && is_filename_cached(fname)) {
        return 1;
    }
    return 0;
}

__attribute__((naked)) static void detour_572010(void) {
    __asm__ volatile (
        "pushl %%ecx\n\t"
        "pushl %%edx\n\t"
        "pushl %%eax\n\t"
        "pushl %%eax\n\t"
        "pushl %%ebp\n\t"
        "call _fast_check_vorbis_stream_skip\n\t"
        "addl $8, %%esp\n\t"
        "testl %%eax, %%eax\n\t"
        "popl %%eax\n\t"
        "popl %%edx\n\t"
        "popl %%ecx\n\t"
        "jz 1f\n\t"
        "xorl %%eax, %%eax\n\t"
        "ret\n\t"
        "1:\n\t"
        "pushl $0x004c32fc\n\t"
        "ret\n\t"
        ::: "memory"
    );
}

static const char *g_patch_log_path;

static void patch_log(uintptr_t address, const char *status) {
    if (!g_patch_log_path || !*g_patch_log_path) return;
    HANDLE file = CreateFileA(g_patch_log_path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
                              NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return;
    char line[512];
    int n = snprintf(line, sizeof line, "0x%08lx %s\r\n", (unsigned long)address, status);
    DWORD written;
    if (n > 0 && (size_t)n < sizeof line) WriteFile(file, line, (DWORD)n, &written, NULL);
    CloseHandle(file);
}

static int write_rel32_detour(uintptr_t addr, uint8_t opcode, void *target, const uint8_t *expected_bytes, size_t expected_len) {
    if (IsBadReadPtr((const void *)addr, expected_len)) { patch_log(addr, "skipped: unreadable"); return 0; }
    if (memcmp((const void *)addr, expected_bytes, expected_len) != 0) { patch_log(addr, "skipped: signature mismatch"); return 0; }
    DWORD old_prot = 0;
    if (VirtualProtect((LPVOID)addr, 8, PAGE_EXECUTE_READWRITE, &old_prot)) {
        uint8_t patch[5];
        patch[0] = opcode;
        int32_t rel = (int32_t)((uintptr_t)target - (addr + 5));
        memcpy(&patch[1], &rel, 4);
        memcpy((void *)addr, patch, 5);
        FlushInstructionCache(GetCurrentProcess(), (LPCVOID)addr, 8);
        VirtualProtect((LPVOID)addr, 8, old_prot, &old_prot);
        patch_log(addr, "applied");
        return 1;
    } else { patch_log(addr, "skipped: protection failure"); }
    return 0;
}

static void install_cossacks_patches(void) {
    g_patch_log_path = getenv("STEPPE_PATCH_LOG");
    g_skip_open_patched = 0;
    g_cache_enabled = -1;
    const uint8_t *module = (const uint8_t *)GetModuleHandleA(NULL);
    // Detours use absolute game addresses, so relocated modules are unsupported.
    if ((uintptr_t)module != 0x00400000u ||
        !matches_game_build(module, known_game_builds, sizeof known_game_builds / sizeof known_game_builds[0])) {
        char regions[384], line[448];
        describe_regions(module, regions, sizeof regions);
        snprintf(line, sizeof line, "skipped: unknown game build (regions %s)", regions);
        patch_log(0, line);
        return;
    }
    const char *env = getenv("STEPPE_MATH_PATCHES");
    int math_enabled = env && strcmp(env, "1") == 0;

    static const uint8_t sig_4a4af4[7] = { 0x51, 0xD9, 0x40, 0x10, 0xD8, 0x48, 0x20 };
    static const uint8_t sig_4a582c[7] = { 0x53, 0x56, 0x83, 0xC4, 0xE4, 0x8B, 0xF2 };
    static const uint8_t sig_4a5884[7] = { 0x53, 0x56, 0x83, 0xC4, 0xE4, 0x8B, 0xF2 };
    static const uint8_t sig_4a825c[6] = { 0x55, 0x8B, 0xEC, 0x83, 0xC4, 0x84 };
    static const uint8_t sig_4d1870[8] = { 0x33, 0xD2, 0x89, 0x90, 0x44, 0x01, 0x00, 0x00 };
    static const uint8_t sig_572010[5] = { 0xE8, 0xE7, 0x12, 0xF5, 0xFF };
    static const uint8_t sig_4a7890[] = { 0x55, 0x8B, 0xEC, 0x81, 0xC4, 0x6C, 0xFF, 0xFF, 0xFF, 0x53, 0x56, 0x57 };
    static const uint8_t sig_4a8078[] = { 0x55, 0x8B, 0xEC, 0x83, 0xC4, 0xF8, 0x53, 0x56, 0x57, 0x8B, 0xF9 };

    if (math_enabled) {
        write_rel32_detour(0x004a4af4u, 0xE9, (void *)detour_4a4af4, sig_4a4af4, sizeof(sig_4a4af4));
        write_rel32_detour(0x004a582cu, 0xE9, (void *)detour_4a582c, sig_4a582c, sizeof(sig_4a582c));
        write_rel32_detour(0x004a5884u, 0xE9, (void *)detour_4a582c, sig_4a5884, sizeof(sig_4a5884));
        if (!IsBadReadPtr((const void *)0x004a7890u, sizeof sig_4a7890) &&
            !IsBadReadPtr((const void *)0x004a8078u, sizeof sig_4a8078) &&
            !memcmp((const void *)0x004a7890u, sig_4a7890, sizeof sig_4a7890) &&
            !memcmp((const void *)0x004a8078u, sig_4a8078, sizeof sig_4a8078)) {
            write_rel32_detour(0x004a825cu, 0xE9, (void *)detour_4a825c, sig_4a825c, sizeof(sig_4a825c));
        } else { patch_log(0x004a825cu, "skipped: callee signature mismatch or unreadable"); }

    } else {
        patch_log(0x004a4af4u, "skipped: math disabled");
        patch_log(0x004a582cu, "skipped: math disabled");
        patch_log(0x004a5884u, "skipped: math disabled");
        patch_log(0x004a825cu, "skipped: math disabled");
    }
    write_rel32_detour(0x004d1870u, 0xE9, (void *)detour_4d1870, sig_4d1870, sizeof(sig_4d1870));

    g_skip_open_patched = write_rel32_detour(0x00572010u, 0xE8, (void *)detour_572010, sig_572010, sizeof(sig_572010));

    static const uint8_t sig_8ef125[6] = { 0x80, 0x7E, 0x5C, 0x00, 0x75, 0x0A };
    uintptr_t hw_msg_addr = 0x008ef125u;
    if (!IsBadReadPtr((const void *)hw_msg_addr, sizeof(sig_8ef125)) &&
        memcmp((const void *)hw_msg_addr, sig_8ef125, sizeof(sig_8ef125)) == 0) {
        DWORD old_prot = 0;
        if (VirtualProtect((LPVOID)hw_msg_addr, 8, PAGE_EXECUTE_READWRITE, &old_prot)) {
            *(uint8_t *)(hw_msg_addr + 4) = 0xEB;
            FlushInstructionCache(GetCurrentProcess(), (LPCVOID)hw_msg_addr, 8);
            VirtualProtect((LPVOID)hw_msg_addr, 8, old_prot, &old_prot);
            patch_log(hw_msg_addr, "applied");
        } else { patch_log(hw_msg_addr, "skipped: protection failure"); }
    } else { patch_log(hw_msg_addr, "skipped: signature mismatch or unreadable"); }
}

BOOL WINAPI DllMain(HINSTANCE hinstDLL, DWORD fdwReason, LPVOID lpvReserved) {
    (void)hinstDLL; (void)lpvReserved;
    if (fdwReason == DLL_PROCESS_ATTACH) {
        install_cossacks_patches();
        init_cache_if_needed();
    }
    return TRUE;
}
