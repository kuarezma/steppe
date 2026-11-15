// SPDX-License-Identifier: MIT
// Copyright (c) Steppe contributors
//
// Presses OK on the "Your video card does not support hardware acceleration" message box that
// Cossacks 3 shows on startup under Wine. The box is purely informational (the game continues on
// its supported path), but it would otherwise need one click on every launch.
//
// The helper runs inside the Wine prefix, so it needs no macOS permissions. It only touches a window
// that is the game's own message form (Delphi class TMessageForm, titled "Cossacks III") whose only
// button is "OK". Dialogs with other buttons (for example Yes/No questions) are left alone.
//
// Usage: dismiss-dialog.exe [timeout-seconds]   (default 600)
// Exit codes: 0 = dialog dismissed or main game window open >= 10s, 1 = timed out.
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0600
#endif
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct search {
    int buttons;
    HWND ok_button;
};

static int is_game_window(HWND window) {
    DWORD pid = 0;
    if (!GetWindowThreadProcessId(window, &pid) || !pid) return 0;
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!process) return 0;
    char path[32768];
    DWORD length = sizeof path;
    BOOL ok = QueryFullProcessImageNameA(process, 0, path, &length);
    CloseHandle(process);
    if (!ok || !length || length >= sizeof path) return 0;
    path[length] = '\0';
    const char *name = path;
    for (const char *p = path; *p; p++) {
        if (*p == '\\' || *p == '/') name = p + 1;
    }
    return lstrcmpiA(name, "cossacks.exe") == 0;
}

static BOOL CALLBACK inspect_child(HWND child, LPARAM param) {
    struct search *s = (struct search *)param;
    char cls[32] = {0};
    char text[32] = {0};
    GetClassNameA(child, cls, sizeof cls);
    if (lstrcmpiA(cls, "TButton") != 0 || !IsWindowVisible(child)) return TRUE;
    GetWindowTextA(child, text, sizeof text);
    s->buttons++;
    if (lstrcmpiA(text, "OK") == 0 || lstrcmpiA(text, "&OK") == 0) s->ok_button = child;
    return TRUE;
}

static BOOL CALLBACK inspect_window(HWND window, LPARAM param) {
    int *dismissed = (int *)param;
    if (!IsWindowVisible(window)) return TRUE;
    char cls[32] = {0};
    char title[128] = {0};
    GetClassNameA(window, cls, sizeof cls);
    GetWindowTextA(window, title, sizeof title);
    if (lstrcmpA(cls, "TMessageForm") != 0 || lstrcmpA(title, "Cossacks III") != 0) return TRUE;
    if (!is_game_window(window)) return TRUE;

    struct search s = {0, NULL};
    EnumChildWindows(window, inspect_child, (LPARAM)&s);
    if (s.buttons == 1 && s.ok_button) {
        // The game's Delphi button ignores BM_CLICK; a posted mouse click is what it reacts to.
        RECT r;
        GetClientRect(s.ok_button, &r);
        LPARAM center = MAKELPARAM((r.right - r.left) / 2, (r.bottom - r.top) / 2);
        PostMessageA(s.ok_button, WM_LBUTTONDOWN, MK_LBUTTON, center);
        PostMessageA(s.ok_button, WM_LBUTTONUP, 0, center);
        *dismissed = 1;
        return FALSE;
    }
    return TRUE;
}

struct poll_state {
    int dismissed;
    int main_window_visible;
};

enum { MAIN_WINDOW_STABLE_MS = 10000 };

static int is_main_game_window(HWND window) {
    if (!IsWindowVisible(window)) return 0;
    RECT r;
    if (!GetWindowRect(window, &r)) return 0;
    if ((r.right - r.left) < 640 || (r.bottom - r.top) < 480) return 0;
    char cls[32] = {0};
    GetClassNameA(window, cls, sizeof cls);
    if (lstrcmpA(cls, "TMessageForm") == 0) return 0;
    return is_game_window(window);
}

static BOOL CALLBACK inspect_poll_window(HWND window, LPARAM param) {
    struct poll_state *state = (struct poll_state *)param;
    if (!IsWindowVisible(window)) return TRUE;
    int dismissed = 0;
    if (inspect_window(window, (LPARAM)&dismissed) == FALSE && dismissed) {
        state->dismissed = 1;
        return FALSE;
    }
    if (!state->main_window_visible && is_main_game_window(window)) {
        state->main_window_visible = 1;
    }
    return TRUE;
}

static int check_main_window_stable(int visible, DWORD now_ms, DWORD *since_ms, int *tracking) {
    if (!visible) {
        *tracking = 0;
        *since_ms = 0;
        return 0;
    }
    if (!*tracking) {
        *tracking = 1;
        *since_ms = now_ms;
        return 0;
    }
    return (DWORD)(now_ms - *since_ms) >= (DWORD)MAIN_WINDOW_STABLE_MS;
}

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmd, int show) {
    (void)inst; (void)prev; (void)show;
    int timeout = (cmd && *cmd) ? atoi(cmd) : 600;
    if (timeout <= 0 || timeout > 3600) timeout = 600;
    DWORD start = GetTickCount();
    DWORD timeout_ms = (DWORD)timeout * 1000u;
    DWORD main_since = 0;
    int tracking_main = 0;
    while ((DWORD)(GetTickCount() - start) < timeout_ms) {
        struct poll_state state = {0, 0};
        EnumWindows(inspect_poll_window, (LPARAM)&state);
        if (state.dismissed) {
            puts("dismiss_dialog: dismissed startup warning");
            fflush(stdout);
            return 0;
        }
        if (check_main_window_stable(state.main_window_visible, GetTickCount(), &main_since, &tracking_main)) {
            puts("dismiss_dialog: main game window active, exiting");
            fflush(stdout);
            return 0;
        }
        Sleep(250);
    }
    puts("dismiss_dialog: timed out");
    fflush(stdout);
    return 1;
}
