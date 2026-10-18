// SPDX-License-Identifier: MIT
// Copyright (c) Steppe contributors
#ifndef STEPPE_GAME_BUILD_H
#define STEPPE_GAME_BUILD_H

#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

typedef struct {
    uint32_t va;
    uint32_t length;
    uint64_t hash;
} GameBuildRegion;

typedef struct {
    const GameBuildRegion *regions;
    size_t region_count;
} GameBuild;

static const GameBuildRegion steam_3154226_regions[] = {
    { 0x4a4000, 0x5000, UINT64_C(0x4251b6bbba49be48) },
    { 0x4d1800, 0x100,  UINT64_C(0xcbde57ca8ed08a0a) },
    { 0x571f00, 0x200,  UINT64_C(0x60e5031fe6a3b410) },
    { 0x4c32f0, 0x40,   UINT64_C(0x7ad043e46808a559) },
    { 0x8ef100, 0x40,   UINT64_C(0x2e3f22362e18bef3) }
};

static const GameBuild known_game_builds[] = {
    // Add independently verified builds here; get the values from the unknown-build line in the patch log.
    { steam_3154226_regions, sizeof steam_3154226_regions / sizeof steam_3154226_regions[0] }
};

static uint32_t pe_u32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static uint16_t pe_u16(const uint8_t *p) {
    return (uint16_t)((uint16_t)p[0] | (uint16_t)p[1] << 8);
}

static uint64_t region_fnv1a64(const uint8_t *bytes, size_t length) {
    uint64_t hash = UINT64_C(14695981039346656037);
    for (size_t i = 0; i < length; i++) {
        hash ^= bytes[i];
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

typedef struct {
    uint32_t size;
    const uint8_t *sections;
    unsigned section_count;
} GameImage;

// IsBadReadPtr is supplied by Windows (or by the portable test's memory mock).
static int read_game_image(const uint8_t *base, GameImage *image) {
    if (!base || IsBadReadPtr(base, 64) || memcmp(base, "MZ", 2)) return 0;
    uint32_t pe = pe_u32(base + 0x3c);
    if (pe < 64 || pe > 0x100000 || IsBadReadPtr(base, (size_t)pe + 24)) return 0;
    const uint8_t *nt = base + pe;
    if (memcmp(nt, "PE\0\0", 4) || pe_u16(nt + 4) != 0x14c) return 0;
    unsigned sections = pe_u16(nt + 6), optional = pe_u16(nt + 20);
    if (!sections || sections > 96 || optional < 60) return 0;
    size_t headers_end = (size_t)pe + 24 + optional + sections * 40;
    if (IsBadReadPtr(base, headers_end) || pe_u16(nt + 24) != 0x10b ||
        pe_u32(nt + 24 + 28) != 0x400000) return 0;
    uint32_t image_size = pe_u32(nt + 24 + 56);
    if (headers_end > image_size) return 0;
    image->size = image_size;
    image->sections = nt + 24 + optional;
    image->section_count = sections;
    const uint8_t *section = image->sections;
    for (unsigned i = 0; i < sections; i++, section += 40) {
        uint32_t length = pe_u32(section + 8);
        uint32_t rva = pe_u32(section + 12);
        if (length && (rva < headers_end || rva > image_size || length > image_size - rva)) return 0;
    }
    return 1;
}

// Resolve a verified VA into mapped section bytes, never raw-file offsets.
static const uint8_t *game_region_bytes(const uint8_t *base, const GameImage *image,
                                       const GameBuildRegion *region) {
    if (region->va < 0x400000 || !region->length) return NULL;
    uint32_t rva = region->va - 0x400000;
    if (rva > image->size || region->length > image->size - rva) return NULL;
    const uint8_t *section = image->sections;
    for (unsigned i = 0; i < image->section_count; i++, section += 40) {
        uint32_t start = pe_u32(section + 12), length = pe_u32(section + 8);
        if (rva >= start && rva - start <= length && region->length <= length - (rva - start)) {
            return IsBadReadPtr(base + rva, region->length) ? NULL : base + rva;
        }
    }
    return NULL;
}

static int matches_game_build(const uint8_t *base, const GameBuild *builds, size_t count) {
    GameImage image;
    if (!read_game_image(base, &image)) return 0;
    for (size_t i = 0; i < count; i++) {
        if (!builds[i].regions || !builds[i].region_count) continue;
        size_t j;
        for (j = 0; j < builds[i].region_count; j++) {
            const GameBuildRegion *region = &builds[i].regions[j];
            const uint8_t *bytes = game_region_bytes(base, &image, region);
            if (!bytes || region_fnv1a64(bytes, region->length) != region->hash) break;
        }
        if (j == builds[i].region_count) return 1;
    }
    return 0;
}

// Use the same patch coverage as the verified table; never read unchecked bytes for diagnostics.
static void describe_regions(const uint8_t *base, char *out, size_t out_size) {
    if (!out_size) return;
    out[0] = '\0';
    GameImage image;
    if (!read_game_image(base, &image)) {
        snprintf(out, out_size, "unreadable PE");
        return;
    }
    const GameBuild *build = &known_game_builds[0];
    size_t n = 0;
    for (size_t i = 0; i < build->region_count; i++) {
        const GameBuildRegion *region = &build->regions[i];
        const uint8_t *bytes = game_region_bytes(base, &image, region);
        char item[48];
        int written;
        if (bytes) {
            uint64_t hash = region_fnv1a64(bytes, region->length);
            written = snprintf(item, sizeof item, "%s%x:%08x%08x", n ? " " : "",
                               (unsigned)region->va, (unsigned)(hash >> 32), (unsigned)hash);
        } else {
            written = snprintf(item, sizeof item, "%s%x:unreadable", n ? " " : "", (unsigned)region->va);
        }
        if (written < 0 || (size_t)written >= sizeof item || (size_t)written >= out_size - n) break;
        memcpy(out + n, item, (size_t)written + 1);
        n += (size_t)written;
    }
}
#endif
