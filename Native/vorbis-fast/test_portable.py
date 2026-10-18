# SPDX-License-Identifier: MIT
# Copyright (c) Steppe contributors
"""Execute production patch policy and budget helpers with host API mocks.

Only addresses and Windows API calls are mocked. The installer, signatures,
logger and memory budget functions are extracted directly from production C.
This does not execute Windows code or validate the game's calling convention.
"""
from pathlib import Path
import os
import subprocess

source = Path('vorbisfile_fast.c').read_text()
layout = source[source.index('typedef struct {'):source.index('static PcmCacheEntry g_cache')]
Path('build/test_cached_layout.c').write_text(
    '#include <stdint.h>\n#include <stddef.h>\n#include "vorbis/vorbisfile.h"\n' + layout +
    '_Static_assert(offsetof(OggVorbis_File, datasource) == 0, "overlay base");\n'
    '_Static_assert(offsetof(VfCachedState, read_byte_offset) == 8, "i686 cursor");\n'
    '_Static_assert(offsetof(OggVorbis_File, offset) == 8, "i686 alias");\n'
    '_Static_assert(offsetof(OggVorbis_File, end) >= sizeof(VfCachedState), "end outside overlay");\n')
subprocess.run(['i686-w64-mingw32-gcc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                '-isystem', '.cache/libogg-1.3.5/include', '-isystem', '.cache/libvorbis-1.3.7/include',
                '-c', 'build/test_cached_layout.c', '-o', 'build/test_cached_layout.o'], check=True)
print('PASS i686 ABI: cached cursor aliases vf.offset at byte 8; vf.end is outside overlay', flush=True)
# Model the i686 alias on the host: the cached cursor and vf.offset share bytes.
pcm_source = source[source.index('#define VF_CACHE_MAGIC'):source.index('__attribute__((used)) static float')]
pcm_prefix = r'''
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
typedef int64_t ogg_int64_t;
typedef struct { int channels; long rate; void *codec_setup; } vorbis_info;
typedef struct { char **user_comments; int *comment_lengths; int comments; char *vendor; } vorbis_comment;
typedef struct { int unused; } ov_callbacks;
typedef struct { void *datasource; void *padding; ogg_int64_t offset, end; } OggVorbis_File;
typedef int CRITICAL_SECTION;
static void InitializeCriticalSection(CRITICAL_SECTION *p) { *p=0; }
static void EnterCriticalSection(CRITICAL_SECTION *p) { (void)p; }
static void LeaveCriticalSection(CRITICAL_SECTION *p) { (void)p; }
static int IsBadReadPtr(const void *p,size_t n) { (void)p;(void)n;return 0; }
static int real_closes, real_opens, real_reads, decode_complete, seek_failure;
static vorbis_info info = {2,48000,NULL};
static vorbis_comment comment;
static int real_ov_clear(OggVorbis_File *v) { if(v->datasource) real_closes++;return 0; }
static int real_ov_open_callbacks(void *d,OggVorbis_File *v,const char *i,long n,ov_callbacks c) {
 (void)i;(void)n;(void)c;v->datasource=d;real_opens++;return 0;
}
static ogg_int64_t real_ov_pcm_total(OggVorbis_File *v,int i) { (void)v;(void)i;return 4096; }
static int real_ov_pcm_seek(OggVorbis_File *v,ogg_int64_t p) { (void)v;(void)p;return seek_failure; }
static int real_ov_raw_seek(OggVorbis_File *v,ogg_int64_t p) { (void)v;(void)p;return 0; }
static int real_ov_time_seek(OggVorbis_File *v,double p) { (void)v;(void)p;return 0; }
static vorbis_info *real_ov_info(OggVorbis_File *v,int i) { (void)v;(void)i;return &info; }
static vorbis_comment *real_ov_comment(OggVorbis_File *v,int i) { (void)v;(void)i;return &comment; }
static long real_ov_read(OggVorbis_File *v,char *b,int n,int e,int w,int s,int *bs) {
 (void)v;(void)e;(void)w;(void)s;(void)bs;real_reads++;
 if(decode_complete) { memset(b,0x35,(size_t)n);return n; }
 return 0;
}
'''
pcm_suffix = r'''
int main(void) {
 uint8_t pcm[16384], out[4096];
 for(size_t i=0;i<sizeof pcm;i++) pcm[i]=(uint8_t)((i*13)^(i>>8));
 PcmCacheEntry entry={0};entry.channels=2;entry.rate=48000;entry.pcm_total=4096;
 entry.pcm_bytes=sizeof pcm;entry.pcm_data=pcm;
 OggVorbis_File vf={0};VfCachedState *st=(VfCachedState *)&vf.datasource;
 assert(offsetof(VfCachedState,read_byte_offset)==offsetof(OggVorbis_File,offset));
 st->magic=VF_CACHE_MAGIC;st->entry=&entry;st->read_byte_offset=0;
 int bs=-1;
 for(size_t i=0;i<sizeof pcm;i+=sizeof out) {
  assert(ov_read(&vf,(char *)out,sizeof out,0,2,1,&bs)==sizeof out);
  assert(!memcmp(out,pcm+i,sizeof out));assert(bs==0);
 }
 assert(ov_read(&vf,(char *)out,sizeof out,0,2,1,&bs)==0);
 assert(ov_read(&vf,(char *)out,sizeof out,0,2,1,&bs)==0);
 assert(ov_pcm_seek(&vf,123)==0);
 assert(ov_read(&vf,(char *)out,sizeof out,0,2,1,&bs)==sizeof out);
 assert(!memcmp(out,pcm+123*4,sizeof out));
 assert(ov_pcm_seek(&vf,-1)==0 && st->read_byte_offset==0);
 assert(ov_pcm_seek(&vf,99999)==0 && st->read_byte_offset==sizeof pcm);
 assert(ov_raw_seek(&vf,0)==0);assert(ov_time_seek(&vf,0)==0);
 assert(ov_info(&vf,-1)==&entry.vi && ov_comment(&vf,-1)==&entry.vc);
 assert(ov_pcm_total(&vf,-1)==entry.pcm_total);assert(ov_clear(&vf)==0);
 assert(!is_filename_cached(NULL));
 // Game object offsets match the production filename recognizer.
 union { max_align_t alignment; uint8_t bytes[0x400]; } object={0};
 *(const char **)(object.bytes+8)="effect.ogg";
 OggVorbis_File *game_vf=(OggVorbis_File *)(object.bytes+0x28);
 void *datasource=object.bytes+0x10;ov_callbacks callbacks={0};
 strcpy(g_cache[0].name,"effect.ogg");g_cache_count=1;
 g_skip_open_patched=0;g_cache_enabled=-1;init_cache_if_needed();
 assert(!g_cache_enabled && !is_filename_cached("effect.ogg"));
 assert(ov_open_callbacks(datasource,game_vf,NULL,0,callbacks)==0);
 assert(real_opens==1 && g_cache_count==1 && !get_cached_state(game_vf));
 g_cache_count=0;decode_complete=1;
 assert(ov_open_callbacks(datasource,game_vf,NULL,0,callbacks)==0);
 assert(real_opens==2 && real_reads==0 && g_cache_count==0);
 strcpy(g_cache[0].name,"effect.ogg");g_cache_count=1;decode_complete=0;
 puts("PASS cache disabled without file-open patch: no hit or publication");
 g_skip_open_patched=1;g_cache_enabled=-1;init_cache_if_needed();
 g_cache[0].pcm_total=4096;
 assert(ov_open_callbacks(datasource,game_vf,NULL,0,callbacks)==0);
 assert(get_cached_state(game_vf) && get_cached_state(game_vf)->read_byte_offset==0);
 assert(real_opens==2);ov_clear(game_vf);
 g_cache_count=0;seek_failure=-7;
 assert(ov_open_callbacks(datasource,game_vf,NULL,0,callbacks)==-7);
 assert(real_closes==0 && game_vf->datasource==NULL && g_pending_entries==0 && g_pcm_bytes==0);
 seek_failure=0;decode_complete=1;
 assert(ov_open_callbacks(datasource,game_vf,NULL,0,callbacks)==0);
 assert(g_cache_count==1 && real_closes==1 && get_cached_state(game_vf));
 assert(get_cached_state(game_vf)->read_byte_offset==0);
 assert(ov_read(game_vf,(char *)out,sizeof out,0,2,1,&bs)==sizeof out);
 for(size_t i=0;i<sizeof out;i++) assert(out[i]==0x35);
 ov_clear(game_vf);assert(real_closes==1);
 free(g_cache[0].pcm_data);
 puts("PASS successful miss: PCM published, cursor starts at zero, datasource closed once");
 puts("PASS failed open: datasource stays caller-owned, reservation rolled back");
 puts("PASS cached PCM: ordered 4096-byte reads, repeated EOF, seek and clear");
 return 0;
}
'''
Path('build/test_pcm.c').write_text(pcm_prefix + pcm_source + pcm_suffix)
subprocess.run([os.environ.get('HOST_CC', 'clang'), '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                'build/test_pcm.c', '-o', 'build/test_pcm'], check=True)
subprocess.run(['build/test_pcm'], check=True, timeout=10)
patches = source[source.index('static const char *g_patch_log_path;'):source.index('BOOL WINAPI DllMain')]
addresses = ['004a4af4', '004a582c', '004a5884', '004a825c', '004d1870', '00572010', '008ef125', '004a7890', '004a8078']
for index, address in enumerate(addresses):
    patches = patches.replace('0x' + address + 'u', f'(uintptr_t)sites[{index}]')
patches = patches.replace('matches_game_build(module, known_game_builds, sizeof known_game_builds / sizeof known_game_builds[0])', 'matches_game_build(mock_image, mock_builds, 1)')
patches = patches.replace('(uintptr_t)module != 0x00400000u', 'mock_module_address != 0x00400000u')
cache_init = source[source.index('static void init_cache_if_needed('):source.index('static const char *get_cossacks_vorbis_filename')]
helpers = source[source.index('static int reserve_pcm_bytes'):source.index('int ov_open_callbacks(')]
# Preserve the production signature bytes in fixtures independently of the installer.
prefix = r'''
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
typedef unsigned long DWORD;
typedef void *LPVOID;
typedef const void *LPCVOID;
typedef void *HANDLE;
#define FILE_APPEND_DATA 1
#define FILE_SHARE_READ 2
#define FILE_SHARE_WRITE 4
#define OPEN_ALWAYS 1
#define FILE_ATTRIBUTE_NORMAL 0
#define PAGE_EXECUTE_READWRITE 0x40
#define INVALID_HANDLE_VALUE ((HANDLE)-1)
static uint8_t sites[9][16];
static const uint8_t fixtures[9][16] = {
 {0x51,0xd9,0x40,0x10,0xd8,0x48,0x20},
 {0x53,0x56,0x83,0xc4,0xe4,0x8b,0xf2},
 {0x53,0x56,0x83,0xc4,0xe4,0x8b,0xf2},
 {0x55,0x8b,0xec,0x83,0xc4,0x84},
 {0x33,0xd2,0x89,0x90,0x44,0x01,0,0},
 {0xe8,0xe7,0x12,0xf5,0xff}, {0x80,0x7e,0x5c,0,0x75,0x0a},
 {0x55,0x8b,0xec,0x81,0xc4,0x6c,0xff,0xff,0xff,0x53,0x56,0x57},
 {0x55,0x8b,0xec,0x83,0xc4,0xf8,0x53,0x56,0x57,0x8b,0xf9}
};
static int unreadable, protect_fail, protect_calls, log_opens, log_lines, unknown_logs;
static int g_skip_open_patched, g_cache_enabled, g_cache_init, g_cache_cs;
static void InitializeCriticalSection(int *p) { *p=0; }
static char last_log[512];
static uint8_t mock_image[0x500000];
static uint32_t unreadable_rva;
static uintptr_t mock_module_address=0x400000;
static int IsBadReadPtr(const void *p, size_t n) {
 if(unreadable) return 1;
 uintptr_t a=(uintptr_t)p, image=(uintptr_t)mock_image, code=(uintptr_t)sites;
 if(a>=image && a-image<=sizeof mock_image) {
  size_t offset=a-image;
  return n>sizeof mock_image-offset ||
   (unreadable_rva && offset<=unreadable_rva && n>unreadable_rva-offset);
 }
 if(a>=code && a-code<=sizeof sites) return n>sizeof sites-(a-code);
 return 1;
}
static int VirtualProtect(LPVOID p, size_t n, DWORD protection, DWORD *old) {
 (void)p; (void)n; (void)protection; *old=0x20;protect_calls++;return !protect_fail;
}
static void *GetCurrentProcess(void) { return NULL; }
static void FlushInstructionCache(void *p, LPCVOID a, size_t n) { (void)p; (void)a; (void)n; }
static HANDLE CreateFileA(const char *path, int a, int b, void *c, int d, int e, void *f) {
 (void)a;(void)b;(void)c;(void)d;(void)e;(void)f;
 assert(!strcmp(path,"mock-log")); log_opens++; return (HANDLE)sites;
}
static void WriteFile(HANDLE f,const char *line,DWORD n,DWORD *written,void *o) {
 (void)f;(void)o; assert(strstr(line,"applied") || strstr(line,"skipped:"));
 assert(n<sizeof last_log && n>=2 && line[n-2]=='\r' && line[n-1]=='\n');
 assert(!memchr(line,'\n',n-1));memcpy(last_log,line,n);last_log[n]=0;
 if(strstr(line,"unknown game build")) unknown_logs++;
 *written=n;log_lines++;
}
static void CloseHandle(HANDLE f) { (void)f; }
#include "../game_build.h"
static GameBuild mock_builds[1];
static GameBuildRegion mock_regions[5];
static void *GetModuleHandleA(const char *name) { (void)name;return mock_image; }
static void put16(uint8_t *p,uint16_t v) { p[0]=v;p[1]=v>>8; }
static void put32(uint8_t *p,uint32_t v) { for(int i=0;i<4;i++) p[i]=(uint8_t)(v>>(i*8)); }
static void init_image(void) {
 memset(mock_image,0,sizeof mock_image);memcpy(mock_image,"MZ",2);
 put32(mock_image+0x3c,0x80);uint8_t *nt=mock_image+0x80;
 memcpy(nt,"PE\0\0",4);put16(nt+4,0x14c);put16(nt+6,1);put16(nt+20,0xe0);
 put16(nt+24,0x10b);put32(nt+24+28,0x400000);put32(nt+24+56,sizeof mock_image);
 uint8_t *s=nt+24+0xe0;memcpy(s,"CODE",4);
 put32(s+8,0x4f1000);put32(s+12,0x1000);put32(s+16,0x4f1000);put32(s+20,0x400);
 for(size_t i=0x1000;i<0x4f2000;i++) mock_image[i]=(uint8_t)(i^(i>>8));
 memcpy(mock_regions,known_game_builds[0].regions,sizeof mock_regions);
 for(size_t i=0;i<5;i++) {
  GameBuildRegion *r=&mock_regions[i];
  r->hash=region_fnv1a64(mock_image+(r->va-0x400000),r->length);
 }
 mock_builds[0]=(GameBuild){mock_regions,5};
 unreadable_rva=0;mock_module_address=0x400000;
}

static void detour_4a4af4(void) {}
static void detour_4a582c(void) {}
static void detour_4a825c(void) {}
static void detour_4d1870(void) {}
static void detour_572010(void) {}
#define MAX_PCM_BYTES (128u * 1024u * 1024u)
#define MAX_PCM_CACHE 512
static size_t g_pcm_bytes;
static int g_cache_count, g_pending_entries;
'''
suffix = r'''
static void assert_unknown_build(void) {
 int old_unknown=unknown_logs,old_lines=log_lines,old_protect=protect_calls;
 memcpy(sites,fixtures,sizeof sites);
 // A previous successful install must not leave the cache enabled on rejection.
 g_skip_open_patched=1;g_cache_enabled=1;
 install_cossacks_patches();init_cache_if_needed();
 assert(!memcmp(sites,fixtures,sizeof sites) && protect_calls==old_protect);
 assert(!g_skip_open_patched && !g_cache_enabled);
 assert(unknown_logs==old_unknown+1 && log_lines==old_lines+1);
 assert(strstr(last_log,"skipped: unknown game build (regions "));
 assert(!strstr(last_log,"CODE") && strstr(last_log,")\r\n"));
}

static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static void *budget_worker(void *unused) {
 (void)unused;
 for(int i=0;i<10000;i++) {
  pthread_mutex_lock(&mutex);
  if(reserve_pcm_bytes(3u*1024u*1024u)) {
   assert(g_pcm_bytes<=MAX_PCM_BYTES);
   finish_pcm_reservation(3u*1024u*1024u,0);
  }
  pthread_mutex_unlock(&mutex);
 }
 return NULL;
}
int main(void) {
 init_image();
 const GameBuildRegion expected[]={
  {0x4a4000,0x5000,UINT64_C(0x4251b6bbba49be48)},
  {0x4d1800,0x100,UINT64_C(0xcbde57ca8ed08a0a)},
  {0x571f00,0x200,UINT64_C(0x60e5031fe6a3b410)},
  {0x4c32f0,0x40,UINT64_C(0x7ad043e46808a559)},
  {0x8ef100,0x40,UINT64_C(0x2e3f22362e18bef3)}
 };
 assert(known_game_builds[0].region_count==5);
 for(size_t i=0;i<5;i++) {
  const GameBuildRegion *r=&known_game_builds[0].regions[i];
  assert(r->va==expected[i].va && r->length==expected[i].length && r->hash==expected[i].hash);
 }
 assert(matches_game_build(mock_image,mock_builds,1));
 assert(!matches_game_build(mock_image,known_game_builds,1));
 // Raw-file offsets and CODE bytes outside patch coverage do not define identity.
 mock_image[0x400]=99;assert(matches_game_build(mock_image,mock_builds,1));
 mock_image[0x1000]^=1;assert(matches_game_build(mock_image,mock_builds,1));
 GameBuild alternatives[]={{NULL,0},mock_builds[0]};
 assert(!matches_game_build(mock_image,alternatives,1));
 assert(matches_game_build(mock_image,alternatives,2));
 assert(!matches_game_build(mock_image,mock_builds,0));
 mock_image[0]='X';assert(!matches_game_build(mock_image,mock_builds,1));init_image();
 put32(mock_image+0x3c,0x10000);assert(!matches_game_build(mock_image,mock_builds,1));init_image();
 put32(mock_image+0x3c,0xffffffff);assert(!matches_game_build(mock_image,mock_builds,1));init_image();
 put32(mock_image+0x184,0xfffffff0);assert(!matches_game_build(mock_image,mock_builds,1));init_image();
 for(int invalid=0;invalid<4;invalid++) {
  if(invalid==0) mock_regions[0].va=0x3fffff;
  if(invalid==1) mock_regions[0].length=0;
  if(invalid==2) mock_regions[0].length=0xffffffff;
  if(invalid==3) mock_regions[0].va=0x8f1fff;
  assert(!matches_game_build(mock_image,mock_builds,1));init_image();
 }
 puts("PASS mapped PE: region VA/length bounds, multiple builds, malformed headers; unrelated CODE changes accepted");
 const char *values[]={NULL,"0","true","01","1"};
 unsetenv("STEPPE_PATCH_LOG");
 for(unsigned k=0;k<sizeof values/sizeof values[0];k++) {
  if(values[k]) setenv("STEPPE_MATH_PATCHES",values[k],1); else unsetenv("STEPPE_MATH_PATCHES");
  memcpy(sites,fixtures,sizeof sites); install_cossacks_patches();
  for(int i=0;i<4;i++) assert(sites[i][0]==(k==4?0xe9:fixtures[i][0]));
  assert(sites[4][0]==0xe9 && sites[5][0]==0xe8 && sites[6][4]==0xeb);
 }
 assert(log_opens==0);
 puts("PASS patch policy: unset/0/true/01 disabled; exact 1 enabled; mandatory patches always installed; logging off");
 setenv("STEPPE_MATH_PATCHES","1",1); setenv("STEPPE_PATCH_LOG","mock-log",1);
 memcpy(sites,fixtures,sizeof sites); install_cossacks_patches(); assert(log_lines==7);assert(g_skip_open_patched);
 unsetenv("C3_VORBIS_CACHE");init_cache_if_needed();assert(g_cache_enabled);
 puts("PASS region identity: all five regions match; patches installed and cache enabled");
 puts("PASS patch log: all seven sites reported");
 for(size_t i=0;i<5;i++) {
  uint32_t rva=mock_regions[i].va-0x400000;
  mock_image[rva+mock_regions[i].length-1]^=1;assert_unknown_build();
  for(size_t j=0;j<5;j++) {
   const GameBuildRegion *r=&mock_regions[j];char item[48];
   uint64_t hash=region_fnv1a64(mock_image+(r->va-0x400000),r->length);
   snprintf(item,sizeof item,"%x:%08x%08x",(unsigned)r->va,(unsigned)(hash>>32),(unsigned)hash);
   assert(strstr(last_log,item));
  }
  mock_image[rva+mock_regions[i].length-1]^=1;
 }
 puts("PASS region mismatch: one byte in each of five regions skips ALL patches and disables cache");
 for(size_t i=0;i<5;i++) {
  unreadable_rva=mock_regions[i].va-0x400000;assert_unknown_build();
  char item[48];snprintf(item,sizeof item,"%x:unreadable",(unsigned)mock_regions[i].va);
  assert(strstr(last_log,item));unreadable_rva=0;
 }
 puts("PASS unreadable region: each of five regions skips ALL patches and disables cache");
 for(int invalid=0;invalid<12;invalid++) {
  if(invalid==0) mock_image[0]='X';
  if(invalid==1) mock_image[0x80]='X';
  if(invalid==2) put16(mock_image+0x84,0x8664);
  if(invalid==3) put16(mock_image+0x86,0);
  if(invalid==4) put16(mock_image+0x86,97);
  if(invalid==5) put16(mock_image+0x94,59);
  if(invalid==6) put16(mock_image+0x98,0x20b);
  if(invalid==7) put32(mock_image+0xb4,0x500000);
  if(invalid==8) put32(mock_image+0xd0,128);
  if(invalid==9) put32(mock_image+0x184,0xfffffff0);
  if(invalid==10) put32(mock_image+0x3c,0xffffffff);
  if(invalid==11) unreadable_rva=0x180;
  assert_unknown_build();assert(strstr(last_log,"regions unreadable PE"));init_image();
 }
 mock_module_address=0x500000;assert_unknown_build();mock_module_address=0x400000;
 puts("PASS malformed PE / relocated module: ALL patches skipped and cache disabled");
 char detail[128];describe_regions(mock_image,detail,sizeof detail);
 assert(strlen(detail)==119);
 char small[4]={'x','x','x','!'};describe_regions(mock_image,small,3);
 assert(small[0]==0 && small[3]=='!');describe_regions(mock_image,NULL,0);
 puts("PASS unknown-build log: one line below 512 bytes, five hashes, unreadable markers, bounded buffers");
 for(int failure=0;failure<3;failure++) {
  memcpy(sites,fixtures,sizeof sites);
  if(failure==0) for(int i=0;i<7;i++) sites[i][0]^=1;
  unreadable=failure==1;protect_fail=failure==2;
  uint8_t before[sizeof sites]; memcpy(before,sites,sizeof sites);
  install_cossacks_patches(); assert(!memcmp(before,sites,sizeof sites));
 }
 for(int i=7;i<9;i++) {
  memcpy(sites,fixtures,sizeof sites);sites[i][0]^=1;
  unreadable=protect_fail=0;install_cossacks_patches();
  assert(sites[3][0]==fixtures[3][0] && sites[0][0]==0xe9);
 }
 memcpy(sites,fixtures,sizeof sites);sites[5][0]^=1;install_cossacks_patches();
 assert(!g_skip_open_patched);
 puts("PASS callee signatures enforced");
 puts("PASS signature mismatch, unreadable memory and protection failure leave bytes unchanged");
 assert(reserve_pcm_bytes(MAX_PCM_BYTES)); assert(!reserve_pcm_bytes(1));
 finish_pcm_reservation(MAX_PCM_BYTES,MAX_PCM_BYTES); assert(!reserve_pcm_bytes(1));
 g_pcm_bytes=0;g_cache_count=MAX_PCM_CACHE;assert(!reserve_pcm_bytes(1));g_cache_count=0;
 assert(reserve_pcm_bytes(1024));finish_pcm_reservation(1024,0);
 assert(g_pcm_bytes==0 && g_pending_entries==0);
 pthread_t threads[8];
 for(int i=0;i<8;i++) assert(!pthread_create(&threads[i],NULL,budget_worker,NULL));
 for(int i=0;i<8;i++) assert(!pthread_join(threads[i],NULL));
 assert(g_pcm_bytes==0 && g_pending_entries==0);
 puts("PASS PCM budget: 128 MiB cap, entry cap, rollback, 8 threads / 80000 reservations");
 return 0;
}
'''
Path('build/test_portable.c').write_text(prefix + cache_init + helpers + patches + suffix)
subprocess.run([os.environ.get('HOST_CC', 'clang'), '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                '-pthread', 'build/test_portable.c', '-o', 'build/test_portable'], check=True)
subprocess.run(['build/test_portable'], check=True, timeout=20)
