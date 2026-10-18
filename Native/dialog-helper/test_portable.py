# SPDX-License-Identifier: MIT
# Copyright (c) Steppe contributors
"""Run the production dialog selector against process/window API mocks."""
from pathlib import Path
import os
import subprocess

source = Path('dismiss_dialog.c').read_text()
body = source[source.index('struct search {'):source.index('int WINAPI WinMain(')]
prefix = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
typedef void *HWND;
typedef void *HANDLE;
typedef intptr_t LPARAM;
typedef unsigned long DWORD;
typedef int BOOL;
typedef struct { int left,top,right,bottom; } RECT;
#define CALLBACK
#define TRUE 1
#define FALSE 0
#define PROCESS_QUERY_LIMITED_INFORMATION 0x1000
#define WM_LBUTTONDOWN 1
#define WM_LBUTTONUP 2
#define MK_LBUTTON 1
#define MAKELPARAM(x,y) ((LPARAM)((x)|((y)<<16)))
static const char *image="C:\\games\\cossacks.exe";
static int owner_ok=1,open_ok=1,query_ok=1,posts,closes,buttons=1;
static DWORD GetWindowThreadProcessId(HWND w,DWORD *pid) { (void)w;*pid=owner_ok?123:0;return owner_ok; }
static HANDLE OpenProcess(DWORD access,BOOL inherit,DWORD pid) {
 assert(access==PROCESS_QUERY_LIMITED_INFORMATION && !inherit && pid==123);
 return open_ok?(HANDLE)(uintptr_t)3:NULL;
}
static BOOL QueryFullProcessImageNameA(HANDLE h,DWORD flags,char *path,DWORD *n) {
 (void)h;assert(!flags);if(!query_ok)return FALSE;
 assert(*n>strlen(image));strcpy(path,image);*n=(DWORD)strlen(image);return TRUE;
}
static BOOL CloseHandle(HANDLE h) { (void)h;closes++;return TRUE; }
static int lstrcmpA(const char *a,const char *b) { return strcmp(a,b); }
static int lstrcmpiA(const char *a,const char *b) { return strcasecmp(a,b); }
static BOOL IsWindowVisible(HWND w) { (void)w;return TRUE; }
static void GetClassNameA(HWND w,char *s,int n) { snprintf(s,(size_t)n,"%s",w==(HWND)(uintptr_t)1?"TMessageForm":"TButton"); }
static void GetWindowTextA(HWND w,char *s,int n) { snprintf(s,(size_t)n,"%s",w==(HWND)(uintptr_t)1?"Cossacks III":"OK"); }
static void EnumChildWindows(HWND w,BOOL (*callback)(HWND,LPARAM),LPARAM p) {
 (void)w;for(int i=0;i<buttons;i++)callback((HWND)(uintptr_t)2,p);
}
static void GetClientRect(HWND w,RECT *r) { (void)w;*r=(RECT){0,0,100,30}; }
static void PostMessageA(HWND w,int msg,int key,LPARAM pos) { (void)w;(void)msg;(void)key;(void)pos;posts++; }
'''
suffix = r'''
int main(void) {
 int dismissed=0;
 image="C:\\other\\editor.exe";
 assert(inspect_window((HWND)(uintptr_t)1,(LPARAM)&dismissed)==TRUE && !dismissed && !posts);
 image="C:\\games\\COSSACKS.EXE";
 assert(inspect_window((HWND)(uintptr_t)1,(LPARAM)&dismissed)==FALSE && dismissed && posts==2);
 assert(closes==2);posts=0;dismissed=0;
 for(int i=0;i<3;i++) {
  owner_ok=i!=0;open_ok=i!=1;query_ok=i!=2;
  assert(inspect_window((HWND)(uintptr_t)1,(LPARAM)&dismissed)==TRUE && !dismissed && !posts);
 }
 owner_ok=open_ok=query_ok=1;buttons=2;
 assert(inspect_window((HWND)(uintptr_t)1,(LPARAM)&dismissed)==TRUE && !posts);
 buttons=1;image="C:\\games\\cossacks.exe.backup";
 assert(inspect_window((HWND)(uintptr_t)1,(LPARAM)&dismissed)==TRUE && !posts);
 puts("PASS dialog ownership: foreign process ignored, case-insensitive executable, API failures, first-close exit");
 return 0;
}
'''
Path('build').mkdir(exist_ok=True)
Path('build/test_portable.c').write_text(prefix + body + suffix)
subprocess.run([os.environ.get('HOST_CC', 'clang'), '-std=c11', '-Wall', '-Wextra', '-Werror',
                'build/test_portable.c', '-o', 'build/test_portable'], check=True)
subprocess.run(['build/test_portable'], check=True, timeout=10)
