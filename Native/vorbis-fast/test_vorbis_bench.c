// SPDX-License-Identifier: MIT
// Copyright (c) Steppe contributors
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include "vorbis/vorbisfile.h"

typedef int (__cdecl *pfn_ov_open_callbacks)(void *datasource, OggVorbis_File *vf, const char *initial, long ibytes, ov_callbacks callbacks);
typedef vorbis_info *(__cdecl *pfn_ov_info)(OggVorbis_File *vf, int link);
typedef vorbis_comment *(__cdecl *pfn_ov_comment)(OggVorbis_File *vf, int link);
typedef ogg_int64_t (__cdecl *pfn_ov_pcm_total)(OggVorbis_File *vf, int i);
typedef long (__cdecl *pfn_ov_read)(OggVorbis_File *vf, char *buffer, int length, int bigendianp, int word, int sgned, int *bitstream);
typedef int (__cdecl *pfn_ov_clear)(OggVorbis_File *vf);

typedef struct {
    const uint8_t *data;
    size_t size;
    size_t pos;
} MemStream;

static size_t mem_read(void *ptr, size_t size, size_t nmemb, void *datasource) {
    MemStream *ms = *(MemStream **)datasource;
    size_t rem = ms->size - ms->pos;
    size_t bytes = size * nmemb;
    if (bytes > rem) bytes = rem;
    if (bytes > 0) {
        memcpy(ptr, ms->data + ms->pos, bytes);
        ms->pos += bytes;
    }
    return size ? (bytes / size) : 0;
}
static int mem_seek(void *datasource, ogg_int64_t offset, int whence) {
    MemStream *ms = *(MemStream **)datasource;
    ogg_int64_t np = 0;
    if (whence == SEEK_SET) np = offset;
    else if (whence == SEEK_CUR) np = (ogg_int64_t)ms->pos + offset;
    else if (whence == SEEK_END) np = (ogg_int64_t)ms->size + offset;
    if (np < 0 || np > (ogg_int64_t)ms->size) return -1;
    ms->pos = (size_t)np;
    return 0;
}
static int mem_close(void *datasource) { (void)datasource; return 0; }
static long mem_tell(void *datasource) {
    MemStream *ms = *(MemStream **)datasource;
    return (long)ms->pos;
}

#pragma pack(push, 1)
typedef struct {
    uint8_t pad0[0x08];
    const char *FFileName;
    uint32_t pad0c;
    MemStream *FStream;
    uint8_t pad14[0x14];
    OggVorbis_File FVorbisFile;
    vorbis_info FInfo;
    vorbis_comment FComment;
    uint8_t FStreaming;
    uint8_t pad_end[32];
} FakeCossacksVorbisObj;
#pragma pack(pop)

int main(int argc, char **argv) {
    if (argc < 5) return 1;
    const char *ogg_path = argv[1];
    const char *vorbis_path = argv[2];
    const char *vf_path = argv[3];
    const char *ogg_file = argv[4];
    int iters = (argc > 5) ? atoi(argv[5]) : 20;
    const char *dump_pcm = (argc > 6) ? argv[6] : NULL;

    HMODULE hOgg = LoadLibraryA(ogg_path);
    HMODULE hVorbis = LoadLibraryA(vorbis_path);
    HMODULE hVf = LoadLibraryA(vf_path);
    if (!hOgg || !hVorbis || !hVf) return 2;

    pfn_ov_open_callbacks fn_open = (pfn_ov_open_callbacks)(void *)GetProcAddress(hVf, "ov_open_callbacks");
    pfn_ov_info fn_info = (pfn_ov_info)(void *)GetProcAddress(hVf, "ov_info");
    pfn_ov_pcm_total fn_total = (pfn_ov_pcm_total)(void *)GetProcAddress(hVf, "ov_pcm_total");
    pfn_ov_read fn_read = (pfn_ov_read)(void *)GetProcAddress(hVf, "ov_read");
    pfn_ov_clear fn_clear = (pfn_ov_clear)(void *)GetProcAddress(hVf, "ov_clear");

    FILE *f = fopen(ogg_file, "rb");
    if (!f) return 3;
    fseek(f, 0, SEEK_END);
    size_t fsz = (size_t)ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *fdata = (uint8_t *)malloc(fsz);
    fread(fdata, 1, fsz, f);
    fclose(f);

    ov_callbacks cb = { mem_read, mem_seek, mem_close, mem_tell };
    FakeCossacksVorbisObj obj;
    memset(&obj, 0, sizeof(obj));
    obj.FFileName = ogg_file;
    obj.FStreaming = 0;

    LARGE_INTEGER freq, t0, t1, t2;
    QueryPerformanceFrequency(&freq);

    int16_t *out_pcm = NULL;
    size_t out_bytes = 0;
    int channels = 0;
    long rate = 0;
    ogg_int64_t total_samples = 0;

    QueryPerformanceCounter(&t0);
    for (int i = 0; i < iters; i++) {
        MemStream ms = { fdata, fsz, 0 };
        obj.FStream = &ms;
        if (fn_open(&obj.FStream, &obj.FVorbisFile, NULL, 0, cb) != 0) return 4;
        vorbis_info *vi = fn_info(&obj.FVorbisFile, -1);
        channels = vi->channels;
        rate = vi->rate;
        total_samples = fn_total(&obj.FVorbisFile, -1);
        size_t bytes = (size_t)(total_samples * channels * 2);
        if (!out_pcm) {
            out_pcm = (int16_t *)malloc(bytes);
            out_bytes = bytes;
        }
        size_t got = 0;
        int bs = 0;
        while (got < bytes) {
            long r = fn_read(&obj.FVorbisFile, (char *)out_pcm + got, (int)(bytes - got), 0, 2, 1, &bs);
            if (r <= 0) break;
            got += (size_t)r;
        }
        fn_clear(&obj.FVorbisFile);
        if (i == 0) QueryPerformanceCounter(&t1);
    }
    QueryPerformanceCounter(&t2);

    if (dump_pcm && out_pcm) {
        FILE *pf = fopen(dump_pcm, "wb");
        if (pf) { fwrite(out_pcm, 1, out_bytes, pf); fclose(pf); }
    }

    double first_ms = (double)(t1.QuadPart - t0.QuadPart) * 1000.0 / (double)freq.QuadPart;
    double total_ms = (double)(t2.QuadPart - t0.QuadPart) * 1000.0 / (double)freq.QuadPart;
    double subseq_avg_ms = (iters > 1) ? ((total_ms - first_ms) / (iters - 1)) : first_ms;
    uint32_t hash = 2166136261u;
    for (size_t i = 0; i < out_bytes; i++) {
        hash ^= ((const uint8_t *)out_pcm)[i];
        hash *= 16777619u;
    }
    FILE *rf = stdout;
    if (rf) {
        fprintf(rf, "RESULT dll=%s rate=%ld ch=%d samples=%lld bytes=%zu first_ms=%.3f subseq_avg_ms=%.4f total_%d_ms=%.3f fnv1a=0x%08x\n",
                vf_path, rate, channels, (long long)total_samples, out_bytes, first_ms, subseq_avg_ms, iters, total_ms, hash);

    }
    return 0;
}
